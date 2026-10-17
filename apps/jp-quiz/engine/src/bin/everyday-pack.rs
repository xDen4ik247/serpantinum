//! everyday-pack — puts the everyday words (assets/jlpt/everyday.tsv: slang, tech, brands, cars, food,
//! daily life; 90 % 常用 kanji · 7.5 % kana · 2.5 % other kanji) into the quiz as real questions:
//!   * "Word in context" (vocab): a Tatoeba sentence with the word blanked, four words to choose from
//!   * "Kanji reading" (kread): the word highlighted in a sentence, four readings to choose from
//! Items are added to content.db next to the ones the main content build made, with keys ev:/er:, so
//! running it again replaces them (idempotent). install.sh runs it whenever data/raw/ is there.
//!
//!   cargo run --release --bin everyday-pack -- <data/raw> <data/content.db>
//!
//! Sentences: Tatoeba (CC BY 2.0 FR), each item keeps its sentence ids. Words: see jlpt-syllabus.
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Command, Stdio};

const EVERYDAY: &str = include_str!("../../../assets/jlpt/everyday.tsv");
const VOCAB: &str = include_str!("../../../assets/jlpt/vocab.tsv");
const PER_WORD_VOCAB: usize = 2;
const PER_WORD_READ: usize = 2;
const MAX_SENT_USES: usize = 2;
/// What may follow a kana word (particles, copula) without making it part of a longer word.
const PARTICLES: &str = "はがをにでともへやかよねだ";

struct W {
    tier: i64,
    rank: usize,
    form: String,
    reading: String,
    pos: String,
    en: String,
    ru: String,
}

fn is_kanji(c: char) -> bool {
    ('\u{4e00}'..='\u{9fff}').contains(&c) || ('\u{3400}'..='\u{4dbf}').contains(&c) || c == '々'
}
fn is_hira(c: char) -> bool {
    ('\u{3041}'..='\u{309f}').contains(&c)
}
fn is_kata(c: char) -> bool {
    ('\u{30a0}'..='\u{30ff}').contains(&c)
}
fn all_kata(s: &str) -> bool {
    s.chars().all(|c| is_kata(c) || c == 'ー')
}

/// Lines of a bzip2'd TSV, streamed.
fn bz_lines(path: &Path, mut f: impl FnMut(&str)) {
    let mut child = Command::new("bzip2").arg("-dc").arg(path).stdout(Stdio::piped()).spawn().unwrap_or_else(|e| panic!("bzip2 {}: {e}", path.display()));
    let out = child.stdout.take().unwrap();
    for line in BufReader::with_capacity(1 << 20, out).lines() {
        let Ok(line) = line else { break };
        f(&line);
    }
    let _ = child.wait();
}

/// Small deterministic generator (xorshift64*), so a rebuild gives the same items.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545F4914F6CDD1D)
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }
    fn shuffle<T>(&mut self, v: &mut [T]) {
        for i in (1..v.len()).rev() {
            v.swap(i, self.below(i + 1));
        }
    }
}

fn pos_group(pos: &str) -> &'static str {
    let ps: Vec<&str> = pos.split(',').collect();
    if ps.iter().any(|p| p.starts_with('v') && *p != "vs" && !p.starts_with("vs-")) && !ps.contains(&"n") {
        "verb"
    } else if ps.first() == Some(&"adj-i") {
        "adj-i"
    } else if ps.contains(&"adj-na") {
        "adj-na"
    } else if ps.iter().any(|p| matches!(*p, "n" | "vs" | "n-suf" | "n-pref")) {
        "noun"
    } else {
        "other"
    }
}

/// Wrong but plausible readings: long/short vowels, small っ, voicing, and a similar real reading.
fn wrong_readings(r: &str, others: &[&str], rng: &mut Rng) -> Vec<String> {
    let chars: Vec<char> = r.chars().collect();
    let mut out: Vec<String> = vec![];
    let mut push = |s: String| {
        if s != r && !s.is_empty() && !out.contains(&s) {
            out.push(s);
        }
    };
    const VOICE: [(char, char); 20] = [
        ('か', 'が'), ('き', 'ぎ'), ('く', 'ぐ'), ('け', 'げ'), ('こ', 'ご'), ('さ', 'ざ'), ('し', 'じ'), ('す', 'ず'), ('せ', 'ぜ'), ('そ', 'ぞ'),
        ('た', 'だ'), ('ち', 'ぢ'), ('つ', 'づ'), ('て', 'で'), ('と', 'ど'), ('は', 'ば'), ('ひ', 'び'), ('ふ', 'ぶ'), ('へ', 'べ'), ('ほ', 'ぼ'),
    ];
    for (i, &c) in chars.iter().enumerate() {
        // long vowel: drop a う / い, or add a う after an o-row kana
        if i > 0 && i + 1 < chars.len() && (chars[i + 1] == 'う' || chars[i + 1] == 'い') {
            let mut v = chars.clone();
            v.remove(i + 1);
            push(v.iter().collect());
        }
        if "こそとのほもよろごぞどぼぽょ".contains(c) && chars.get(i + 1) != Some(&'う') {
            let mut v = chars.clone();
            v.insert(i + 1, 'う');
            push(v.iter().collect());
        }
        // small っ
        if c == 'っ' {
            let mut v = chars.clone();
            v.remove(i);
            push(v.iter().collect());
        } else if i > 0 && i + 1 < chars.len() && "かきくけこさしすせそたちつてとぱぴぷぺぽ".contains(chars[i + 1]) && !"っんー".contains(c) {
            let mut v = chars.clone();
            v.insert(i + 1, 'っ');
            push(v.iter().collect());
        }
        // voicing
        for (a, b) in VOICE {
            if c == a || c == b {
                let mut v = chars.clone();
                v[i] = if c == a { b } else { a };
                push(v.iter().collect());
            }
        }
    }
    rng.shuffle(&mut out);
    out.truncate(2);
    // one reading of a real word that starts or ends alike, so not every wrong choice is a one-kana edit
    let mut tries = 0;
    while out.len() < 3 && tries < 4000 && !others.is_empty() {
        tries += 1;
        let o = others[rng.below(others.len())];
        let oc: Vec<char> = o.chars().collect();
        let alike = oc.first() == chars.first() || oc.last() == chars.last();
        if o != r && alike && !out.iter().any(|x| x == o) && oc.len().abs_diff(chars.len()) <= 1 {
            out.push(o.to_string());
        }
    }
    out.truncate(3);
    out
}

/// Is the match of a word at cs[i..i+len] a whole word (not part of a longer word)?
fn whole_word(w: &W, cs: &[char], i: usize, len: usize) -> bool {
    let before = if i > 0 { Some(cs[i - 1]) } else { None };
    let after = cs.get(i + len).copied();
    let (first, last) = (cs[i], cs[i + len - 1]);
    if all_kata(&w.form) {
        !before.is_some_and(is_kata) && !after.is_some_and(|c| is_kata(c) || c == 'ー')
    } else if w.form.chars().all(is_hira) {
        // kana words: not after kana, followed by a particle or by no kana at all (やつ, not やつれる)
        !before.is_some_and(is_hira) && !after.is_some_and(|c| is_hira(c) && !PARTICLES.contains(c))
    } else {
        // kanji words: not inside a longer compound; a noun with okurigana (推し) not inside a verb (推し進める)
        let compound = (is_kanji(first) && before.is_some_and(is_kanji)) || (is_kanji(last) && after.is_some_and(is_kanji));
        let verb_inside = is_hira(last) && pos_group(&w.pos) == "noun" && after.is_some_and(|c| is_kanji(c) || (is_hira(c) && !PARTICLES.contains(c)));
        !compound && !verb_inside
    }
}

type Row = (String, &'static str, i64, String, Vec<String>, &'static str, f64, i64, i64, Value);

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() != 2 {
        eprintln!("usage: everyday-pack <data/raw> <data/content.db>");
        std::process::exit(2);
    }
    let (raw, db_path) = (Path::new(&args[0]), Path::new(&args[1]));

    // ---- words
    let rows = |t: &'static str| t.lines().filter(|l| !l.starts_with('#') && !l.trim().is_empty()).map(|l| l.split('\t').collect::<Vec<&str>>());
    let words: Vec<W> = rows(EVERYDAY)
        .map(|r| W {
            tier: r[0].parse().unwrap_or(0),
            rank: r[1].parse().unwrap_or(0),
            form: r[3].to_string(),
            reading: r[4].to_string(),
            pos: r.get(7).unwrap_or(&"").to_string(),
            en: r.get(8).unwrap_or(&"").to_string(),
            ru: r.get(9).unwrap_or(&"").to_string(),
        })
        .collect();
    // glosses of other words a sentence contains (everyday + JLPT), for the result's word list
    let mut gloss: HashMap<String, (String, String, String)> = HashMap::new();
    for r in rows(VOCAB) {
        let form = if r[2].is_empty() { r[3] } else { r[2] };
        if form.chars().any(is_kanji) && form.chars().count() >= 2 {
            gloss.insert(form.to_string(), (r[3].to_string(), r.get(4).unwrap_or(&"").to_string(), String::new()));
        }
    }
    for w in &words {
        gloss.insert(w.form.clone(), (w.reading.clone(), w.en.clone(), w.ru.clone()));
    }
    let by_form: HashMap<&str, usize> = words.iter().enumerate().map(|(i, w)| (w.form.as_str(), i)).collect();
    let max_len = words.iter().map(|w| w.form.chars().count()).max().unwrap_or(1).min(12);

    // ---- sentences that have an English translation
    let mut ja: Vec<(i64, String)> = vec![];
    bz_lines(&raw.join("jpn_sentences_detailed.tsv.bz2"), |l| {
        let mut f = l.split('\t');
        if let (Some(id), Some(_), Some(t)) = (f.next(), f.next(), f.next()) {
            let n = t.chars().count();
            if (5..=40).contains(&n) && !t.chars().any(|c| c.is_ascii_alphanumeric() || ('Ａ'..='ｚ').contains(&c)) {
                if let Ok(id) = id.parse() {
                    ja.push((id, t.to_string()));
                }
            }
        }
    });
    let ja_ids: HashSet<i64> = ja.iter().map(|s| s.0).collect();
    let links = |file: &str| -> HashMap<i64, i64> {
        let mut m = HashMap::new();
        bz_lines(&raw.join(file), |l| {
            let mut f = l.split('\t');
            if let (Some(a), Some(b)) = (f.next().and_then(|x| x.parse().ok()), f.next().and_then(|x| x.parse().ok())) {
                if ja_ids.contains(&a) {
                    m.entry(a).or_insert(b);
                }
            }
        });
        m
    };
    let (en_link, ru_link) = (links("jpn-eng_links.tsv.bz2"), links("jpn-rus_links.tsv.bz2"));
    let texts = |file: &str, want: &HashSet<i64>| -> HashMap<i64, String> {
        let mut m = HashMap::new();
        bz_lines(&raw.join(file), |l| {
            let mut f = l.split('\t');
            if let (Some(id), Some(_), Some(t)) = (f.next().and_then(|x| x.parse::<i64>().ok()), f.next(), f.next()) {
                if want.contains(&id) {
                    m.insert(id, t.to_string());
                }
            }
        });
        m
    };
    let en_text = texts("eng_sentences.tsv.bz2", &en_link.values().copied().collect());
    let ru_text = texts("rus_sentences.tsv.bz2", &ru_link.values().copied().collect());
    eprintln!("sentences: {} japanese, {} with english", ja.len(), en_link.len());

    // ---- where each word occurs as a whole word (longest match at each position)
    let mut hits: Vec<Vec<(usize, usize)>> = vec![vec![]; words.len()];
    for (si, (id, t)) in ja.iter().enumerate() {
        if !en_link.get(id).is_some_and(|e| en_text.contains_key(e)) {
            continue;
        }
        let cs: Vec<char> = t.chars().collect();
        for i in 0..cs.len() {
            for len in (1..=max_len.min(cs.len() - i)).rev() {
                let s: String = cs[i..i + len].iter().collect();
                let Some(&wi) = by_form.get(s.as_str()) else { continue };
                if whole_word(&words[wi], &cs, i, len) {
                    hits[wi].push((si, i));
                }
                break;
            }
        }
    }

    // ---- items
    let mut rng = Rng(0x9E3779B97F4A7C15);
    let mut uses: HashMap<usize, usize> = HashMap::new();
    let mut items: Vec<Row> = vec![];
    let group_of = |w: &W| if all_kata(&w.form) { "kata" } else { pos_group(&w.pos) };
    let mut groups: HashMap<&str, Vec<usize>> = HashMap::new();
    for (i, w) in words.iter().enumerate() {
        groups.entry(group_of(w)).or_default().push(i);
    }
    let kanji_readings: Vec<&str> = words.iter().filter(|w| w.form.chars().any(is_kanji)).map(|w| w.reading.as_str()).collect();
    let level_of = |tier: i64| -> i64 { if tier >= 3 { tier } else { 3 } };
    let seed_of = |tier: i64, rank: usize| -> f64 {
        let base = match tier { 5 => -0.6, 4 => -0.1, 3 => 0.5, 2 => 0.9, 1 => 1.3, _ => 1.7 };
        ((base + (rank as f64 / 40000.0).min(0.3)) * 100.0).round() / 100.0
    };
    let head = |s: &str| s.split([',', ';', '(']).next().unwrap_or("").trim().to_lowercase();
    let (mut n_vocab, mut n_read, mut n_words) = (0, 0, 0);
    for (wi, w) in words.iter().enumerate() {
        let mut hs = hits[wi].clone();
        // sentences of about 16 characters first (easy to read); each sentence used at most twice overall
        hs.sort_by_key(|&(si, _)| (ja[si].1.chars().count().abs_diff(16), ja[si].0));
        hs.dedup_by_key(|h| h.0);
        let kanji_word = w.form.chars().any(is_kanji);
        let want = PER_WORD_VOCAB + if kanji_word { PER_WORD_READ } else { 0 };
        let mut chosen = vec![];
        for h in hs {
            if chosen.len() >= want {
                break;
            }
            if uses.get(&h.0).copied().unwrap_or(0) < MAX_SENT_USES {
                *uses.entry(h.0).or_default() += 1;
                chosen.push(h);
            }
        }
        if chosen.is_empty() {
            continue;
        }
        n_words += 1;
        for (k, &(si, pos)) in chosen.iter().enumerate() {
            let (sid, text) = (ja[si].0, &ja[si].1);
            let cs: Vec<char> = text.chars().collect();
            let len = w.form.chars().count();
            let before: String = cs[..pos].iter().collect();
            let after: String = cs[pos + len..].iter().collect();
            let en_id = en_link[&sid];
            let en = en_text.get(&en_id).cloned().unwrap_or_default();
            let ru_id = ru_link.get(&sid).copied();
            let ru = ru_id.and_then(|r| ru_text.get(&r).cloned());
            let mut src = json!({"ja": sid, "en": en_id});
            if let Some(r) = ru_id {
                src["ru"] = json!(r);
            }
            // the sentence's other list words, glossed
            let mut glossed: Vec<Value> = vec![json!({"w": w.form, "r": if kanji_word { w.reading.clone() } else { String::new() }, "g": w.en, "gr": w.ru})];
            let mut i = 0;
            while i < cs.len() {
                let mut step = 1;
                for l in (2..=8.min(cs.len() - i)).rev() {
                    let s: String = cs[i..i + l].iter().collect();
                    if s == w.form {
                        step = l;
                        break;
                    }
                    if let Some((r, g, gr)) = gloss.get(&s) {
                        if !glossed.iter().any(|x| x["w"] == s.as_str()) {
                            glossed.push(json!({"w": s, "r": if s.chars().any(is_kanji) { r.clone() } else { String::new() }, "g": g, "gr": gr}));
                        }
                        step = l;
                        break;
                    }
                }
                i += step;
            }
            let flags = i64::from(text.contains("トム") || text.contains("メアリ"));
            let ru_gloss = if w.ru.is_empty() { &w.en } else { &w.ru };
            let mut sent = vec![];
            if !before.is_empty() {
                sent.push(json!({"t": before}));
            }
            let reading_q = kanji_word && k >= PER_WORD_VOCAB;
            sent.push(if reading_q { json!({"hl": true, "t": w.form}) } else { json!({"blank": true}) });
            if !after.is_empty() {
                sent.push(json!({"t": after}));
            }
            let mut payload = json!({"sent": sent, "en": en});
            if let Some(r) = &ru {
                payload["ru"] = json!(r);
            }
            let extra = if !reading_q {
                // distractors: same kind of word, similar frequency, different meaning, not in the sentence
                let pool = &groups[group_of(w)];
                let at = pool.iter().position(|&x| x == wi).unwrap_or(0);
                let mut cands: Vec<usize> = pool[at.saturating_sub(120)..(at + 120).min(pool.len())].to_vec();
                rng.shuffle(&mut cands);
                let mut ds: Vec<&str> = vec![];
                for c in cands {
                    let o = &words[c];
                    if c == wi || o.reading == w.reading || head(&o.en) == head(&w.en) || ds.contains(&o.form.as_str()) || text.contains(o.form.as_str()) {
                        continue;
                    }
                    ds.push(&o.form);
                    if ds.len() == 3 {
                        break;
                    }
                }
                if ds.len() < 3 {
                    continue;
                }
                let choices: Vec<&str> = std::iter::once(w.form.as_str()).chain(ds).collect();
                json!({"choices": choices, "word": w.form, "gloss": w.en, "gloss_ru": w.ru,
                       "explain": format!("{}: {}.", w.form, w.en.trim_end_matches('.')),
                       "explain_ru": format!("{}: {}.", w.form, ru_gloss.trim_end_matches('.')),
                       "full": text, "src": src, "words": glossed})
            } else {
                let wrong = wrong_readings(&w.reading, &kanji_readings, &mut rng);
                if wrong.len() < 3 {
                    continue;
                }
                let choices: Vec<String> = std::iter::once(w.reading.clone()).chain(wrong).collect();
                json!({"choices": choices, "word": w.form, "accept": [w.reading], "gloss": w.en, "gloss_ru": w.ru,
                       "explain": format!("{} is read 「{}」 here.", w.form, w.reading),
                       "explain_ru": format!("{} читается здесь как 「{}」.", w.form, w.reading),
                       "full": text, "src": src, "words": glossed})
            };
            for (kk, v) in extra.as_object().unwrap() {
                payload[kk] = v.clone();
            }
            if reading_q {
                let mut tags: Vec<String> = vec![];
                for c in w.form.chars().filter(|&c| is_kanji(c) && c != '々') {
                    let t = format!("k:{c}");
                    if !tags.contains(&t) {
                        tags.push(t);
                    }
                }
                tags.push(format!("w:{}", w.form));
                items.push((format!("er:{sid}:{wi}"), "kread", level_of(w.tier), format!("read:{}", w.form), tags, "kanji",
                            seed_of(w.tier, w.rank) - 0.2, sid, flags, payload));
                n_read += 1;
            } else {
                items.push((format!("ev:{sid}:{wi}"), "vocab", level_of(w.tier), format!("use:{}", w.form), vec![format!("w:{}", w.form)], "vocab",
                            seed_of(w.tier, w.rank), sid, flags, payload));
                n_vocab += 1;
            }
        }
    }

    // ---- write (replacing an earlier pack)
    let mut db = Connection::open(db_path).expect("open content.db");
    let tx = db.transaction().expect("transaction");
    tx.execute("DELETE FROM items WHERE key LIKE 'ev:%' OR key LIKE 'er:%'", []).unwrap();
    tx.execute("DELETE FROM kcs WHERE kc NOT IN (SELECT DISTINCT kc FROM items)", []).unwrap();
    {
        let mut ins = tx.prepare("INSERT INTO items(key,kind,level,kc,tags,cat,seed,sid,flags,payload) VALUES (?,?,?,?,?,?,?,?,?,?)").unwrap();
        let mut kc = tx.prepare("INSERT OR IGNORE INTO kcs VALUES (?,?,?,?,0)").unwrap();
        for (key, kind, level, kcn, tags, cat, seed, sid, flags, payload) in &items {
            ins.execute(params![key, kind, level, kcn, serde_json::to_string(tags).unwrap(), cat, seed, sid, flags, serde_json::to_string(payload).unwrap()])
                .unwrap();
            let w = kcn.split_once(':').map_or("", |x| x.1);
            let (lab, lab_ru) = if kcn.starts_with("read:") { (format!("reading of {w}"), format!("чтение {w}")) } else { (format!("word {w}"), format!("слово {w}")) };
            kc.execute(params![kcn, lab, lab_ru, level]).unwrap();
        }
    }
    tx.execute("UPDATE kcs SET n_items = (SELECT COUNT(*) FROM items WHERE items.kc = kcs.kc)", []).unwrap();
    tx.execute("INSERT OR REPLACE INTO meta VALUES ('everyday_pack', ?)", [format!("{n_vocab} vocab + {n_read} reading items for {n_words} everyday words")])
        .unwrap();
    tx.commit().unwrap();
    println!("everyday pack: {n_vocab} word-in-context + {n_read} reading questions for {n_words} of {} everyday words", words.len());
}
