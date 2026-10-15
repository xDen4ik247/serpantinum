//! Anki reviews end to end: the real engine binary against a fake AnkiConnect on a local port.
//! Needs the built content (apps/jp-quiz/data/content.db, or JPQUIZ_CONTENT); skipped without it.
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{Arc, Mutex};

#[derive(Default)]
struct Fake {
    log: Vec<Value>,
    /// reply HTTP 500 to everything (Anki "gone")
    down: bool,
    answered: Vec<i64>,
}

fn card(id: i64, word: &str, reading: &str, meaning: &str, sent_furi: &str, sent_en: &str) -> Value {
    let f = |v: &str, o: i64| json!({"value": v, "order": o});
    json!({"cardId": id, "deckName": "i will do this::kaishi", "reps": id % 5, "queue": 2, "due": id,
           "interval": 3, "lapses": 0,
           "fields": {"Word": f(word, 0), "Word Reading": f(reading, 1), "Word Meaning": f(meaning, 2),
                      "Word Furigana": f("", 3), "Word Audio": f("[sound:a.mp3]", 4),
                      "Sentence": f(&sent_furi.replace(|c: char| c == ' ', ""), 5), "Sentence Meaning": f(sent_en, 6),
                      "Sentence Furigana": f(sent_furi, 7), "Sentence Audio": f("", 8), "Notes": f("", 9)}})
}

fn cards() -> Vec<Value> {
    vec![
        card(101, "私", "わたし", "I (polite, general)", "<b>私[わたし]</b>はアンです。", "I am Ann."),
        card(102, "彼", "かれ", "he, him", "<b>彼[かれ]</b>はトムさんです。", "He is Tom-san."),
        card(103, "大きい", "おおきい", "big, large", "この 車[くるま]は<b>大[おお]きい</b>。", "This car is big."),
        card(104, "学校", "がっこう", "school", "<b>学校[がっこう]</b>に 行[い]きます。", "I go to school."),
        card(105, "先生", "せんせい", "teacher", "<b>先生[せんせい]</b>は 優[やさ]しい。", "The teacher is kind."),
        card(106, "猫", "ねこ", "cat", "<b>猫[ねこ]</b>がいます。", "There is a cat."),
        card(107, "水", "みず", "water", "<b>水[みず]</b>をください。", "Water, please."),
    ]
}

fn serve(fake: Arc<Mutex<Fake>>) -> u16 {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = l.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for s in l.incoming() {
            let Ok(mut s) = s else { continue };
            let mut r = BufReader::new(s.try_clone().unwrap());
            let mut len = 0;
            loop {
                let mut h = String::new();
                if r.read_line(&mut h).unwrap_or(0) == 0 || h == "\r\n" {
                    break;
                }
                if let Some(v) = h.to_ascii_lowercase().strip_prefix("content-length:") {
                    len = v.trim().parse().unwrap_or(0);
                }
            }
            let mut body = vec![0; len];
            r.read_exact(&mut body).unwrap();
            let req: Value = serde_json::from_slice(&body).unwrap();
            let mut f = fake.lock().unwrap();
            f.log.push(req.clone());
            if f.down {
                let _ = s.write_all(b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                continue;
            }
            let p = &req["params"];
            let all = cards();
            let result = match req["action"].as_str().unwrap() {
                "version" => json!(6),
                "deckNames" => json!(["Default", "i will do this::kaishi"]),
                "findCards" => json!(all.iter().map(|c| c["cardId"].clone()).filter(|id| !f.answered.contains(&id.as_i64().unwrap())).collect::<Vec<_>>()),
                "cardsInfo" => json!(all.iter().filter(|c| p["cards"].as_array().unwrap().contains(&c["cardId"])).cloned().collect::<Vec<_>>()),
                "areDue" => json!(p["cards"].as_array().unwrap().iter().map(|id| !f.answered.contains(&id.as_i64().unwrap())).collect::<Vec<_>>()),
                "answerCards" => {
                    let ids: Vec<i64> = p["answers"].as_array().unwrap().iter().map(|a| a["cardId"].as_i64().unwrap()).collect();
                    f.answered.extend(&ids);
                    json!(ids.iter().map(|_| true).collect::<Vec<_>>())
                }
                other => panic!("unexpected AnkiConnect action {other}"),
            };
            let out = json!({"result": result, "error": null}).to_string();
            let _ = write!(s, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{out}", out.len());
        }
    });
    port
}

fn content() -> Option<PathBuf> {
    let p = std::env::var_os("JPQUIZ_CONTENT")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../data/content.db"));
    p.exists().then_some(p)
}

struct Eng {
    child: Child,
    stdin: ChildStdin,
    out: BufReader<ChildStdout>,
    now: f64,
    _dir: TempDir,
}

struct TempDir(PathBuf);
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

impl Eng {
    fn start(content: &PathBuf, anki_url: &str, tag: &str) -> Eng {
        let dir = std::env::temp_dir().join(format!("jpquiz-anki-test-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        if let Some(p) = std::env::var_os("JPQUIZ_LIVE_PROGRESS").filter(|_| tag == "live") {
            std::fs::copy(p, dir.join("progress.db")).unwrap();
        }
        let mut child = Command::new(env!("CARGO_BIN_EXE_jp-quiz-engine"))
            .env("JPQUIZ_DATA", &dir)
            .env("JPQUIZ_CONTENT", content)
            .env("JPQUIZ_ANKI_URL", anki_url)
            .env("JPQUIZ_ANKI_ADD", dir.join("no-helper"))
            .env("JPQUIZ_SEED", "42")
            .env("JPQUIZ_TEST_CLOCK", "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take().unwrap();
        let out = BufReader::new(child.stdout.take().unwrap());
        Eng { child, stdin, out, now: 1_790_000_000.0, _dir: TempDir(dir) }
    }

    fn call(&mut self, mut req: Value) -> Value {
        req["_now"] = json!(self.now);
        writeln!(self.stdin, "{req}").unwrap();
        let mut line = String::new();
        self.out.read_line(&mut line).unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        assert_ne!(v["type"], "error", "{v}");
        v
    }

    /// next question (intro cards are passed over)
    fn question(&mut self) -> Value {
        loop {
            self.now += 20.0;
            let q = self.call(json!({"cmd": "next"}));
            if q["type"] == "question" {
                return q;
            }
        }
    }

    fn answer(&mut self, q: &Value, right: bool) -> Value {
        let peek = self.call(json!({"cmd": "peek"}));
        if q["kind"] == "order" {
            return self.call(json!({"cmd": "answer", "qid": q["qid"], "order": peek["correct"], "ms": 3000}));
        }
        let c = peek["correct"].as_i64().unwrap();
        let n = q["ui"]["choices"].as_array().unwrap().len() as i64;
        self.call(json!({"cmd": "answer", "qid": q["qid"], "choice": if right { c } else { (c + 1) % n }, "ms": 3000}))
    }

    fn past_placement(&mut self) {
        for _ in 0..12 {
            let q = self.question();
            self.call(json!({"cmd": "skip", "qid": q["qid"]}));
        }
    }
}

impl Drop for Eng {
    fn drop(&mut self) {
        let _ = writeln!(self.stdin, "{}", json!({"cmd": "quit"}));
        let _ = self.child.wait();
    }
}

fn is_anki(q: &Value) -> bool {
    q["kind"].as_str().unwrap().starts_with("anki_")
}

#[test]
fn off_by_default_and_never_talks_to_anki() {
    let Some(content) = content() else { return eprintln!("no content.db, skipped") };
    let fake = Arc::new(Mutex::new(Fake::default()));
    let port = serve(fake.clone());
    let mut e = Eng::start(&content, &format!("http://127.0.0.1:{port}"), "off");
    assert_eq!(e.call(json!({"cmd": "hello"}))["settings"]["anki_reviews"], json!(false));
    e.past_placement();
    for _ in 0..9 {
        let q = e.question();
        assert!(!is_anki(&q));
        e.answer(&q, true);
    }
    assert!(fake.lock().unwrap().log.is_empty(), "the setting is off: no AnkiConnect traffic at all");
}

#[test]
fn every_third_question_is_an_anki_review_and_goes_back_to_anki() {
    let Some(content) = content() else { return eprintln!("no content.db, skipped") };
    let fake = Arc::new(Mutex::new(Fake::default()));
    let port = serve(fake.clone());
    let mut e = Eng::start(&content, &format!("http://127.0.0.1:{port}"), "on");
    e.past_placement();
    e.call(json!({"cmd": "settings", "set": {"anki_reviews": true}}));
    let mut kinds = vec![];
    let mut eases = vec![];
    for i in 0..9 {
        let q = e.question();
        kinds.push(q["kind"].as_str().unwrap().to_string());
        assert_eq!(is_anki(&q), i % 3 == 2, "question {i}: {}", q["kind"]);
        if is_anki(&q) {
            assert_eq!(q["ui"]["choices"].as_array().unwrap().len(), 4);
            assert_eq!(q["ui"]["deck"], json!("kaishi"));
            assert!(q["ui"]["sent"].as_array().unwrap().iter().any(|t| t["hl"] == json!(true)));
            let right = i != 5;
            let r = e.answer(&q, right);
            assert_eq!(r["correct"], json!(right));
            assert_eq!(r["anki"]["status"], json!("sent"));
            assert_eq!(r["anki"]["ease"], json!(if right { 3 } else { 1 }));
            assert_eq!(r["points"].as_i64().unwrap() > 0, right);
            eases.push((q["anki"]["card_id"].as_i64().unwrap(), if right { 3 } else { 1 }));
        } else {
            e.answer(&q, true);
        }
    }
    let f = fake.lock().unwrap();
    let sent: Vec<(i64, i64)> = f
        .log
        .iter()
        .filter(|r| r["action"] == "answerCards")
        .flat_map(|r| r["params"]["answers"].as_array().unwrap().iter().map(|a| (a["cardId"].as_i64().unwrap(), a["ease"].as_i64().unwrap())).collect::<Vec<_>>())
        .collect();
    assert_eq!(sent, eases);
    // only these actions are ever sent
    for r in &f.log {
        assert!(["version", "deckNames", "findCards", "cardsInfo", "areDue", "answerCards"].contains(&r["action"].as_str().unwrap()));
    }
    drop(f);
    let st = e.call(json!({"cmd": "stats"}));
    assert_eq!(st["anki"]["reviews"]["done_today"], json!(3));
    assert_eq!(st["anki"]["reviews"]["pending"], json!(0));
}

#[test]
fn skip_sends_nothing() {
    let Some(content) = content() else { return eprintln!("no content.db, skipped") };
    let fake = Arc::new(Mutex::new(Fake::default()));
    let port = serve(fake.clone());
    let mut e = Eng::start(&content, &format!("http://127.0.0.1:{port}"), "skip");
    e.past_placement();
    e.call(json!({"cmd": "settings", "set": {"anki_reviews": true}}));
    for _ in 0..2 {
        let q = e.question();
        e.answer(&q, true);
    }
    let q = e.question();
    assert!(is_anki(&q));
    let r = e.call(json!({"cmd": "skip", "qid": q["qid"]}));
    assert_eq!(r["anki"]["status"], json!("skipped"));
    assert!(!fake.lock().unwrap().log.iter().any(|r| r["action"] == "answerCards"));
}

#[test]
fn anki_closed_pauses_reviews_and_answers_wait_until_it_is_back() {
    let Some(content) = content() else { return eprintln!("no content.db, skipped") };
    let fake = Arc::new(Mutex::new(Fake::default()));
    let port = serve(fake.clone());
    let mut e = Eng::start(&content, &format!("http://127.0.0.1:{port}"), "offline");
    e.past_placement();
    e.call(json!({"cmd": "settings", "set": {"anki_reviews": true}}));
    for _ in 0..2 {
        let q = e.question();
        e.answer(&q, true);
    }
    let q = e.question();
    assert!(is_anki(&q));
    // Anki closes while the question is on screen
    fake.lock().unwrap().down = true;
    let r = e.answer(&q, true);
    assert_eq!(r["anki"]["status"], json!("queued"));
    let offline: Vec<&Value> = r["events"].as_array().unwrap().iter().filter(|v| v["type"] == "anki_review").collect();
    assert_eq!(offline.len(), 1);
    assert_eq!(offline[0]["status"], json!("offline"));
    // paused: plain quiz questions only, and no second notice
    for _ in 0..6 {
        let q = e.question();
        assert!(!is_anki(&q));
        let r = e.answer(&q, true);
        assert!(!r["events"].as_array().unwrap().iter().any(|v| v["type"] == "anki_review"));
    }
    assert_eq!(e.call(json!({"cmd": "stats"}))["anki"]["reviews"]["pending"], json!(1));
    // Anki is back after the pause: the waiting answer goes out with the next one
    fake.lock().unwrap().down = false;
    e.now += 400.0;
    let mut got = None;
    for _ in 0..3 {
        let q = e.question();
        if is_anki(&q) {
            got = Some(e.answer(&q, false));
            break;
        }
        e.answer(&q, true);
    }
    let r = got.expect("an Anki question once Anki is back");
    assert_eq!(r["anki"]["status"], json!("sent"));
    let f = fake.lock().unwrap();
    let last = f.log.iter().rev().find(|r| r["action"] == "answerCards").unwrap();
    let eases: Vec<i64> = last["params"]["answers"].as_array().unwrap().iter().map(|a| a["ease"].as_i64().unwrap()).collect();
    assert_eq!(eases, vec![3, 1]);
}

#[test]
fn anki_not_running_at_all() {
    let Some(content) = content() else { return eprintln!("no content.db, skipped") };
    // a port nobody listens on
    let port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let mut e = Eng::start(&content, &format!("http://127.0.0.1:{port}"), "closed");
    e.past_placement();
    e.call(json!({"cmd": "settings", "set": {"anki_reviews": true}}));
    let mut notices = 0;
    for _ in 0..9 {
        let q = e.question();
        assert!(!is_anki(&q));
        let r = e.answer(&q, true);
        notices += r["events"].as_array().unwrap().iter().filter(|v| v["type"] == "anki_review").count();
    }
    assert_eq!(notices, 1, "told once that Anki is closed");
}

/// By hand, against the real Anki (open, AnkiConnect on 8770), on a copy of your progress:
///   JPQUIZ_LIVE_PROGRESS=~/.local/share/jp-quiz/progress.db cargo test --release --test anki_reviews live -- --ignored --nocapture
/// Prints the Anki questions it would ask and skips them (nothing is written to Anki).
/// JPQUIZ_LIVE_ANSWER=<n> answers the first n of them for real (right answer → Pass).
#[test]
#[ignore]
fn live() {
    let Some(content) = content() else { return eprintln!("no content.db, skipped") };
    let answer_n: usize = std::env::var("JPQUIZ_LIVE_ANSWER").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
    let mut e = Eng::start(&content, "http://127.0.0.1:8770", "live");
    e.now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64();
    if e.call(json!({"cmd": "hello"}))["placement"] == json!(true) {
        e.past_placement();
    }
    e.call(json!({"cmd": "settings", "set": {"anki_reviews": true}}));
    let (mut shown, mut answered) = (0, 0);
    for _ in 0..60 {
        let q = e.question();
        if !is_anki(&q) {
            e.call(json!({"cmd": "skip", "qid": q["qid"]}));
            continue;
        }
        shown += 1;
        let sent: String = q["ui"]["sent"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| {
                let s = t["t"].as_str().unwrap().to_string();
                if t["hl"] == json!(true) {
                    format!("[{s}]")
                } else if let Some(r) = t["r"].as_str() {
                    format!("{s}({r})")
                } else {
                    s
                }
            })
            .collect();
        println!("{} {} card {}  {sent}\n   choices {}  en {}", q["kind"], q["ui"]["deck"], q["anki"]["card_id"], q["ui"]["choices"], q["ui"]["en"]);
        let r = if answered < answer_n {
            answered += 1;
            e.answer(&q, true)
        } else {
            e.call(json!({"cmd": "skip", "qid": q["qid"]}))
        };
        println!("   -> correct {} anki {}  explain {}", r["correct"], r["anki"], r["explain"]);
        if shown == 15 {
            break;
        }
    }
    println!("stats: {}", e.call(json!({"cmd": "stats"}))["anki"]);
    assert!(shown > 0, "no Anki questions: is Anki open?");
}
