//! Anki integration (port of jpquiz/anki.py).
//! * Adding cards: through the shared helper ~/.local/bin/anki-add (JSON on stdin); notes wait in
//!   <data>/anki-queue.jsonl until it is there.
//! * Reading: AnkiConnect on 127.0.0.1:8770, strictly read-only (only READ_ACTIONS are ever sent).
use crate::pyjson::dumps;
use regex::Regex;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

const READ_ACTIONS: [&str; 4] = ["version", "deckNames", "findCards", "cardsInfo"];
const WORD_FIELDS: [&str; 11] = ["word", "expression", "vocab", "vocabulary", "kanji", "term", "japanese", "単語", "語彙", "front", "key"];

pub fn deck() -> String {
    std::env::var("JPQUIZ_ANKI_DECK").unwrap_or_else(|_| "Japanese::Quiz".into())
}

fn anki_url() -> String {
    std::env::var("JPQUIZ_ANKI_URL").unwrap_or_else(|_| "http://127.0.0.1:8770".into())
}

pub struct Unavailable(#[allow(dead_code)] pub String);

/// Minimal HTTP/1.1 POST of a JSON body (AnkiConnect is plain HTTP on localhost).
fn http_post(url: &str, body: &str, timeout: Duration) -> Result<String, String> {
    let rest = url.strip_prefix("http://").ok_or("only http:// URLs")?;
    let (hostport, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    let addr = if hostport.contains(':') { hostport.to_string() } else { format!("{hostport}:80") };
    use std::net::ToSocketAddrs;
    let sa = addr.to_socket_addrs().map_err(|e| e.to_string())?.next().ok_or("no address")?;
    let mut s = std::net::TcpStream::connect_timeout(&sa, timeout).map_err(|e| e.to_string())?;
    s.set_read_timeout(Some(timeout)).ok();
    s.set_write_timeout(Some(timeout)).ok();
    let req = format!(
        "POST {path} HTTP/1.1\r\nHost: {hostport}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    s.write_all(req.as_bytes()).map_err(|e| e.to_string())?;
    let mut raw = vec![];
    s.read_to_end(&mut raw).map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&raw).into_owned();
    let (head, body) = text.split_once("\r\n\r\n").ok_or("bad HTTP response")?;
    let status: u16 = head.split_whitespace().nth(1).and_then(|x| x.parse().ok()).ok_or("bad status")?;
    if !(200..300).contains(&status) {
        return Err(format!("HTTP Error {status}"));
    }
    if head.to_ascii_lowercase().contains("transfer-encoding: chunked") {
        let mut out = String::new();
        let mut rest = body;
        while let Some((len, tail)) = rest.split_once("\r\n") {
            let n = usize::from_str_radix(len.trim(), 16).map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            out.push_str(&tail[..n.min(tail.len())]);
            rest = tail.get(n + 2..).unwrap_or("");
        }
        return Ok(out);
    }
    Ok(body.to_string())
}

pub fn invoke(action: &str, params: Value, timeout: f64) -> Result<Value, Unavailable> {
    assert!(READ_ACTIONS.contains(&action), "jp-quiz never sends the write action {action:?} to AnkiConnect");
    let body = dumps(&json!({"action": action, "version": 6, "params": params}), true);
    let text = http_post(&anki_url(), &body, Duration::from_secs_f64(timeout)).map_err(Unavailable)?;
    let res: Value = serde_json::from_str(&text).map_err(|e| Unavailable(e.to_string()))?;
    if let Value::Object(m) = &res {
        if m.get("error").is_some_and(crate::engine::truthy) {
            return Err(Unavailable(m["error"].to_string()));
        }
        return Ok(m.get("result").cloned().unwrap_or(Value::Null));
    }
    Ok(res)
}

#[derive(Clone, Debug)]
pub struct CardInfo {
    pub word: String,
    pub interval: i64,
    pub lapses: i64,
}

pub struct Cards {
    pub decks: Vec<String>,
    pub cards: Vec<CardInfo>,
}

fn strip_html(html: &str) -> String {
    static RE: OnceLock<(Regex, Regex, Regex)> = OnceLock::new();
    let (tags, furi, ws) = RE.get_or_init(|| (Regex::new(r"<[^>]+>").unwrap(), Regex::new(r"\[[^\]]*\]").unwrap(), Regex::new(r"\s+").unwrap()));
    let s = tags.replace_all(html, "");
    let s = furi.replace_all(&s, "");
    let s = s.replace("&nbsp;", " ");
    ws.replace_all(s.trim(), "").into_owned()
}

/// The Japanese headword of a note: a named word field, else the first short Japanese field.
pub fn card_word(fields: &Value) -> Option<String> {
    static RE: OnceLock<(Regex, Regex)> = OnceLock::new();
    let (jp, latin) = RE.get_or_init(|| (Regex::new(r"[぀-ヿ一-鿿]").unwrap(), Regex::new(r"[A-Za-z]").unwrap()));
    let mut items: Vec<(&String, &Value)> = fields.as_object()?.iter().collect();
    items.sort_by(|a, b| {
        let o = |v: &Value| v.get("order").and_then(Value::as_f64).unwrap_or(0.0);
        o(a.1).total_cmp(&o(b.1))
    });
    let named: Vec<(&String, &Value)> = items.iter().filter(|(k, _)| WORD_FIELDS.contains(&k.to_lowercase().trim())).cloned().collect();
    for (_, v) in named.iter().chain(items.iter()) {
        let w = strip_html(v.get("value").and_then(Value::as_str).unwrap_or(""));
        let n = w.chars().count();
        if (1..=12).contains(&n) && jp.is_match(&w) && !latin.is_match(&w) {
            return Some(w);
        }
    }
    None
}

/// Review data of the user's Japanese decks. Err when Anki is closed.
pub fn read_cards() -> Result<Cards, Unavailable> {
    invoke("version", json!({}), 2.0)?;
    let own = deck();
    let exclude = [own.as_str(), "Japanese::Quiz", "Default"];
    let decks: Vec<String> = invoke("deckNames", json!({}), 3.0)?
        .as_array()
        .cloned()
        .unwrap_or_default()
        .iter()
        .filter_map(|d| d.as_str().map(String::from))
        .filter(|d| !exclude.iter().any(|x| d == x || d.starts_with(&format!("{x}::"))))
        .collect();
    if decks.is_empty() {
        return Ok(Cards { decks, cards: vec![] });
    }
    let query = decks.iter().map(|d| format!("\"deck:{d}\"")).collect::<Vec<_>>().join(" OR ");
    let ids = invoke("findCards", json!({"query": format!("({query}) -is:new")}), 3.0)?.as_array().cloned().unwrap_or_default();
    let mut cards = vec![];
    for chunk in ids.chunks(400) {
        for c in invoke("cardsInfo", json!({"cards": chunk}), 15.0)?.as_array().cloned().unwrap_or_default() {
            let Some(w) = card_word(c.get("fields").unwrap_or(&json!({}))) else { continue };
            let gi = |k: &str| c.get(k).and_then(Value::as_i64).unwrap_or(0);
            cards.push(CardInfo { word: w, interval: gi("interval"), lapses: gi("lapses") });
        }
    }
    Ok(Cards { decks, cards })
}

/// known / weak / learning from Anki's own review data (interval and lapses; ease is ignored).
pub fn classify(c: &CardInfo) -> &'static str {
    if c.lapses >= 6 || (c.lapses >= 4 && c.interval < 21) {
        "weak"
    } else if c.interval >= 21 {
        "known"
    } else {
        "learning"
    }
}

fn helper_path() -> PathBuf {
    match std::env::var_os("JPQUIZ_ANKI_ADD") {
        Some(p) => PathBuf::from(p),
        None => PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".local/bin/anki-add"),
    }
}

/// Local queue in front of the shared anki-add helper.
pub struct Outbox {
    path: PathBuf,
}

impl Outbox {
    pub fn new(data_dir: &Path) -> Outbox {
        Outbox { path: data_dir.join("anki-queue.jsonl") }
    }

    pub fn pending(&self) -> Vec<Value> {
        std::fs::read_to_string(&self.path)
            .map(|t| t.lines().map(str::trim).filter(|l| !l.is_empty()).filter_map(|l| serde_json::from_str(l).ok()).collect())
            .unwrap_or_default()
    }

    fn write(&self, notes: &[Value]) {
        if !notes.is_empty() {
            let text: String = notes.iter().map(|n| dumps(n, false) + "\n").collect();
            let _ = std::fs::write(&self.path, text);
        } else if self.path.exists() {
            let _ = std::fs::remove_file(&self.path);
        }
    }

    pub fn add(&self, note: &Value) -> Value {
        let mut notes = self.pending();
        notes.push(note.clone());
        self.write(&notes);
        self.flush()
    }

    pub fn flush(&self) -> Value {
        let notes = self.pending();
        let helper = helper_path();
        if notes.is_empty() {
            return json!({"status": "empty", "sent": 0, "queued": 0});
        }
        let executable = std::fs::metadata(&helper).is_ok_and(|m| {
            use std::os::unix::fs::PermissionsExt;
            m.is_file() && m.permissions().mode() & 0o111 != 0
        });
        if !executable {
            return json!({"status": "queued", "sent": 0, "queued": notes.len(),
                          "message": "anki-add helper not installed yet; kept in the quiz's queue"});
        }
        let (mut left, mut sent, mut err, mut last) = (vec![], 0, String::new(), String::new());
        for n in notes {
            match run_helper(&helper, &dumps(&n, false)) {
                Err(e) => {
                    left.push(n);
                    err = e;
                }
                Ok((code, out, stderr)) => {
                    if [0, 2, 3].contains(&code) {
                        sent += 1;
                        last = out
                            .trim()
                            .lines()
                            .last()
                            .and_then(|l| serde_json::from_str::<Value>(l).ok())
                            .and_then(|v| v.as_object().map(|o| o.get("status").and_then(Value::as_str).unwrap_or("").to_string()))
                            .unwrap_or_else(|| "added".into());
                    } else {
                        left.push(n);
                        let src = if !stderr.is_empty() { stderr } else { out };
                        let t: Vec<char> = src.trim().chars().collect();
                        err = t[t.len().saturating_sub(200)..].iter().collect();
                    }
                }
            }
        }
        self.write(&left);
        let mut status = if left.is_empty() { "sent".to_string() } else { "partial".to_string() };
        if status == "sent" && (last == "duplicate" || last == "queued") {
            status = last;
        }
        json!({"status": status, "sent": sent, "queued": left.len(), "message": err})
    }
}

fn run_helper(helper: &Path, input: &str) -> Result<(i32, String, String), String> {
    let mut child = Command::new(helper).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().map_err(|e| e.to_string())?;
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(input.as_bytes());
    }
    let mut out = child.stdout.take().unwrap();
    let mut errp = child.stderr.take().unwrap();
    let to = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = out.read_to_string(&mut s);
        s
    });
    let te = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = errp.read_to_string(&mut s);
        s
    });
    let t0 = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(st)) => {
                return Ok((st.code().unwrap_or(-1), to.join().unwrap_or_default(), te.join().unwrap_or_default()));
            }
            Ok(None) if t0.elapsed() < Duration::from_secs(20) => std::thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("Command '{}' timed out after 20 seconds", helper.display()));
            }
        }
    }
}
