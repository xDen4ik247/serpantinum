//! Anki reviews inside the quiz (setting `anki_reviews`, off by default): due cards of the user's own decks
//! come up as multiple-choice questions mixed into the stream, and the answer is sent back to Anki as a real
//! review (right → Pass/Good, ease 3; wrong → Fail/Again, ease 1).
//! Two kinds: `anki_read` (kana reading of the highlighted word) and `anki_mean` (what it means).
//! This module builds the questions; the engine owns timing, the game layer and the write-back.
use crate::anki::{furi_kana, strip_html, ReviewCard};
use crate::pyrand::PyRandom;
use regex::Regex;
use serde_json::{json, Map, Value};
use std::collections::{HashSet, VecDeque};
use std::sync::OnceLock;

/// One Anki question in every ANKI_EVERY while cards are due.
pub const ANKI_EVERY: i64 = 3;
/// Most cards held at once (most urgent first).
pub const POOL_MAX: usize = 300;
/// Look for newly due cards this often (seconds) …
pub const REFETCH: f64 = 600.0;
/// … and wait this long after Anki was found closed.
pub const OFFLINE_PAUSE: f64 = 300.0;

#[derive(Default)]
pub struct Reviews {
    pub pool: VecDeque<ReviewCard>,
    /// every card seen this session: meanings/readings to draw distractors from
    pub bank: Vec<ReviewCard>,
    pub fetched_at: Option<f64>,
    pub paused_until: f64,
    /// answers Anki has not taken yet (Anki closed meanwhile): (card id, ease)
    pub pending: Vec<(i64, i64)>,
    pub turn: i64,
    pub offline_told: bool,
    /// an event for the next result (e.g. "Anki is closed")
    pub notice: Option<Value>,
}

impl Reviews {
    pub fn set_pool(&mut self, cards: Vec<ReviewCard>) {
        let known: HashSet<i64> = self.bank.iter().map(|c| c.card_id).collect();
        for c in &cards {
            if !known.contains(&c.card_id) {
                self.bank.push(c.clone());
            }
        }
        self.pool = cards.into();
    }
}

pub fn has_kanji(s: &str) -> bool {
    s.chars().any(|c| ('\u{4e00}'..='\u{9fff}').contains(&c) || ('\u{3400}'..='\u{4dbf}').contains(&c) || c == '々')
}

fn is_kana(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| ('\u{3041}'..='\u{309f}').contains(&c) || ('\u{30a0}'..='\u{30ff}').contains(&c))
}

/// FNV-1a, so a card's question kind changes from one review to the next but not at random.
fn hash(id: i64, reps: i64) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in id.to_le_bytes().iter().chain(reps.to_le_bytes().iter()) {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

// ---------------------------------------------------------------------------------------------- sentence

/// One ruby unit `base[reading]`, trimmed to the kanji part: 食べる[たべる] → (食, た) + べる.
fn push_ruby(out: &mut Vec<Value>, base: &str, reading: &str) {
    let b: Vec<char> = base.chars().collect();
    let r: Vec<char> = reading.chars().collect();
    let (mut lo, mut bh, mut rh) = (0, b.len(), r.len());
    while lo < bh && lo < rh && b[lo] == r[lo] {
        lo += 1;
    }
    while bh > lo && rh > lo && b[bh - 1] == r[rh - 1] {
        bh -= 1;
        rh -= 1;
    }
    push_plain(out, &b[..lo].iter().collect::<String>());
    if bh > lo {
        let t: String = b[lo..bh].iter().collect();
        let rd: String = r[lo..rh].iter().collect();
        if rd.is_empty() || !has_kanji(&t) {
            push_plain(out, &t);
        } else {
            out.push(json!({"t": t, "r": rd}));
        }
    }
    push_plain(out, &b[bh..].iter().collect::<String>());
}

fn push_plain(out: &mut Vec<Value>, t: &str) {
    if t.is_empty() {
        return;
    }
    if let Some(last) = out.last_mut() {
        if last.get("r").is_none() && last.get("hl").is_none() {
            let s = format!("{}{t}", last["t"].as_str().unwrap_or(""));
            last["t"] = json!(s);
            return;
        }
    }
    out.push(json!({"t": t}));
}

/// Plain text in Anki furigana syntax → tokens; a space only separates ruby units.
fn furi_tokens(out: &mut Vec<Value>, s: &str) {
    let mut buf = String::new();
    let mut chars = s.chars();
    while let Some(ch) = chars.next() {
        match ch {
            ' ' => {
                push_plain(out, &buf);
                buf.clear();
            }
            '[' => {
                let reading: String = chars.by_ref().take_while(|&c| c != ']').collect();
                push_ruby(out, &buf, reading.trim());
                buf.clear();
            }
            _ => buf.push(ch),
        }
    }
    push_plain(out, &buf);
}

/// Note HTML → plain text runs, `<b>`/`<strong>` runs marked (text, bold).
fn runs(html: &str) -> Vec<(String, bool)> {
    static RE: OnceLock<(Regex, Regex, Regex)> = OnceLock::new();
    let (bold, tags, sound) = RE.get_or_init(|| {
        (
            Regex::new(r"(?is)<(?:b|strong)\b[^>]*>(.*?)</(?:b|strong)>").unwrap(),
            Regex::new(r"<[^>]+>").unwrap(),
            Regex::new(r"\[sound:[^\]]*\]").unwrap(),
        )
    });
    let html = sound.replace_all(html, "");
    let clean = |s: &str| tags.replace_all(s, "").replace("&nbsp;", " ").replace("&amp;", "&").trim_matches('\n').to_string();
    let mut out = vec![];
    let mut at = 0;
    for m in bold.captures_iter(&html) {
        let all = m.get(0).unwrap();
        out.push((clean(&html[at..all.start()]), false));
        out.push((clean(&m[1]), true));
        at = all.end();
    }
    out.push((clean(&html[at..]), false));
    out.retain(|(t, _)| !t.trim().is_empty());
    out
}

pub struct Sent {
    pub tokens: Vec<Value>,
    pub full: String,
    /// the highlighted text and its kana reading (from the furigana field), when there is one
    pub hl: Option<(String, String)>,
}

/// The card's example sentence as `Sentence.qml` tokens: `{t}`, `{t, r}` (furigana) and `{t, hl: true}`.
/// Without bold in the note, the first occurrence of the word is highlighted.
pub fn sentence(card: &ReviewCard) -> Sent {
    let src = if !card.sentence_furi.is_empty() { &card.sentence_furi } else { &card.sentence };
    let mut tokens = vec![];
    let mut hl = None;
    for (text, bold) in runs(src) {
        if bold && hl.is_none() {
            let t = strip_html(&furi_kana_base(&text));
            hl = Some((t.clone(), furi_kana(&text)));
            tokens.push(json!({"t": t, "hl": true}));
        } else {
            furi_tokens(&mut tokens, &text);
        }
    }
    if hl.is_none() && !card.word.is_empty() {
        for k in 0..tokens.len() {
            let t = tokens[k]["t"].as_str().unwrap_or("").to_string();
            if tokens[k].get("r").is_none() {
                if let Some(at) = t.find(&card.word) {
                    let (pre, post) = (&t[..at], &t[at + card.word.len()..]);
                    let mut mid = vec![];
                    if !pre.is_empty() {
                        mid.push(json!({"t": pre}));
                    }
                    mid.push(json!({"t": card.word, "hl": true}));
                    if !post.is_empty() {
                        mid.push(json!({"t": post}));
                    }
                    tokens.splice(k..=k, mid);
                    hl = Some((card.word.clone(), card.reading.clone()));
                    break;
                }
            }
        }
    }
    let full: String = tokens.iter().map(|t| t["t"].as_str().unwrap_or("")).collect();
    Sent { tokens, full, hl }
}

/// `お 茶[ちゃ]` → お茶 (the written form, readings dropped).
fn furi_kana_base(s: &str) -> String {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r"\[[^\]]*\]").unwrap());
    re.replace_all(s, "").replace(' ', "")
}

// ---------------------------------------------------------------------------------------------- distractors

const VOICING: [&str; 25] = [
    "かが", "きぎ", "くぐ", "けげ", "こご", "さざ", "しじ", "すず", "せぜ", "そぞ", "ただ", "ちぢ", "つづ", "てで", "とど", "はばぱ", "ひびぴ",
    "ふぶぷ", "へべぺ", "ほぼぽ", "ゃや", "ゅゆ", "ょよ", "っつ", "じぢ",
];
const O_ROW: &str = "おこごそぞとどのほぼぽもよょろを";
const E_ROW: &str = "えけげせぜてでねへべぺめれ";
const SOKUON_OK: &str = "かきくけこさしすせそたちつてとぱぴぷぺぽ";

/// Plausible wrong readings: one voicing / small-kana / long-vowel / っ / ん change of the answer.
pub fn kana_fakes(answer: &str, rng: &mut PyRandom, n: usize) -> Vec<String> {
    let a: Vec<char> = answer.chars().collect();
    let mut set: Vec<String> = vec![];
    let mut add = |v: Vec<char>| {
        let s: String = v.into_iter().collect();
        if s != answer && !s.is_empty() && !s.starts_with(['っ', 'ん', 'ゃ', 'ゅ', 'ょ']) && !set.contains(&s) {
            set.push(s);
        }
    };
    for i in 0..a.len() {
        // voicing and small/large kana
        for group in VOICING {
            if group.contains(a[i]) {
                for c in group.chars().filter(|&c| c != a[i]) {
                    let mut v = a.clone();
                    v[i] = c;
                    add(v);
                }
            }
        }
        // long vowels: drop a lengthening う/い, or add one
        if i > 0 && (a[i] == 'う' || a[i] == 'い') && (O_ROW.contains(a[i - 1]) || E_ROW.contains(a[i - 1]) || a[i - 1] == 'ゅ') {
            let mut v = a.clone();
            v.remove(i);
            add(v);
        }
        let next_long = a.get(i + 1).is_some_and(|&c| c == 'う' || c == 'い');
        if !next_long && (O_ROW.contains(a[i]) || a[i] == 'ゅ') {
            let mut v = a.clone();
            v.insert(i + 1, 'う');
            add(v);
        }
        if !next_long && E_ROW.contains(a[i]) {
            let mut v = a.clone();
            v.insert(i + 1, 'い');
            add(v);
        }
        // っ and ん
        if a[i] == 'っ' || a[i] == 'ん' {
            let mut v = a.clone();
            v.remove(i);
            add(v);
        } else if i > 0 && SOKUON_OK.contains(a[i]) && a[i - 1] != 'っ' && a[i - 1] != 'ん' {
            let mut v = a.clone();
            v.insert(i, 'っ');
            add(v);
        }
    }
    // single changes first (shuffled), at most n
    rng.shuffle(&mut set);
    set.truncate(n);
    set
}

/// Pick `n` wrong meanings from the bank: not this word's, distinct, of a similar length, and from the same
/// deck family (a grammar deck explains in Japanese, a vocab deck glosses in English: mixed, the answer shows).
pub fn meaning_fakes(card: &ReviewCard, bank: &[ReviewCard], rng: &mut PyRandom, n: usize) -> Vec<String> {
    let norm = |s: &str| s.to_lowercase().trim().to_string();
    let family = |d: &str| d.split("::").next().unwrap_or(d).to_string();
    let mine = norm(&card.meaning);
    let fam = family(&card.deck);
    let mut seen: HashSet<String> = HashSet::from([mine.clone()]);
    let mut cands: Vec<(f64, String)> = vec![];
    for c in bank {
        let m = norm(&c.meaning);
        if c.word == card.word || c.meaning.is_empty() || family(&c.deck) != fam || !seen.insert(m.clone()) {
            continue;
        }
        let d = (c.meaning.chars().count() as f64 - card.meaning.chars().count() as f64).abs();
        cands.push((d + rng.random() * 12.0, c.meaning.clone()));
    }
    cands.sort_by(|a, b| a.0.total_cmp(&b.0));
    cands.into_iter().take(n).map(|x| x.1).collect()
}

/// Wrong readings borrowed from other cards: same length first.
pub fn pool_readings(card: &ReviewCard, answer: &str, bank: &[ReviewCard], rng: &mut PyRandom, n: usize) -> Vec<String> {
    let len = answer.chars().count() as f64;
    let mut cands: Vec<(f64, String)> = bank
        .iter()
        .filter(|c| c.word != card.word && is_kana(&c.reading) && c.reading != answer)
        .map(|c| ((c.reading.chars().count() as f64 - len).abs() + rng.random(), c.reading.clone()))
        .collect();
    cands.sort_by(|a, b| a.0.total_cmp(&b.0));
    let mut out: Vec<String> = vec![];
    for (_, r) in cands {
        if !out.contains(&r) {
            out.push(r);
        }
        if out.len() == n {
            break;
        }
    }
    out
}

// ---------------------------------------------------------------------------------------------- question

pub struct Built {
    pub kind: &'static str,
    /// choices, the right one first (the engine shuffles them)
    pub choices: Vec<String>,
    pub ui: Map<String, Value>,
    pub explain: String,
    pub full: String,
    pub en: String,
    pub words: Value,
}

/// The question for one card, or None when there is nothing fair to ask (too few distractors).
/// `known_fakes`: hand-made wrong readings for this word from the quiz's own content, if any.
pub fn build(card: &ReviewCard, bank: &[ReviewCard], known_fakes: &[String], rng: &mut PyRandom) -> Option<Built> {
    let sent = sentence(card);
    // what the reading question asks: the word itself, or the inflected form highlighted in the sentence
    let (mut target, mut answer) = (card.word.clone(), card.reading.clone());
    let mut tokens = sent.tokens.clone();
    let mut full = sent.full.clone();
    let mut en = card.sentence_en.clone();
    match &sent.hl {
        Some((t, r)) if *t != card.word && has_kanji(t) && is_kana(r) && r != t => {
            target = t.clone();
            answer = r.clone();
        }
        Some((t, _)) if *t == card.word => {}
        _ => {
            // no usable highlight: ask about the word on its own
            tokens = vec![json!({"t": card.word, "hl": true})];
            full = card.word.clone();
            en = String::new();
        }
    }
    let can_read = has_kanji(&target) && is_kana(&answer) && answer != target;
    let can_mean = !card.meaning.is_empty();
    let want_read = can_read && (!can_mean || hash(card.card_id, card.reps) % 2 == 0);
    let gloss = json!([{"w": card.word, "r": if card.reading != card.word { card.reading.as_str() } else { "" }, "g": card.meaning}]);
    let reading_note = if card.reading.is_empty() || card.reading == card.word { String::new() } else { format!("【{}】", card.reading) };
    let try_read = |rng: &mut PyRandom| -> Option<Built> {
        let mut fakes: Vec<String> = vec![];
        if target == card.word {
            for f in known_fakes {
                if *f != answer && is_kana(f) && !fakes.contains(f) && fakes.len() < 3 {
                    fakes.push(f.clone());
                }
            }
        }
        for f in kana_fakes(&answer, rng, 6) {
            if !fakes.contains(&f) && fakes.len() < 3 {
                fakes.push(f);
            }
        }
        for f in pool_readings(card, &answer, bank, rng, 3) {
            if !fakes.contains(&f) && fakes.len() < 3 {
                fakes.push(f);
            }
        }
        if fakes.len() < 3 {
            return None;
        }
        let mut choices = vec![answer.clone()];
        choices.extend(fakes);
        let mut explain = format!("{target} is read 「{answer}」 here.");
        if !card.meaning.is_empty() {
            explain += &format!("  {}{reading_note} — {}", card.word, card.meaning);
        }
        Some(Built { kind: "anki_read", choices, ui: Map::new(), explain, full: full.clone(), en: en.clone(), words: gloss.clone() })
    };
    let built = if want_read {
        try_read(rng)
    } else {
        let fakes = meaning_fakes(card, bank, rng, 3);
        if fakes.len() == 3 {
            let mut choices = vec![card.meaning.clone()];
            choices.extend(fakes);
            Some(Built {
                kind: "anki_mean",
                choices,
                ui: Map::new(),
                explain: format!("{}{reading_note} — {}", card.word, card.meaning),
                full: full.clone(),
                en: en.clone(),
                words: gloss.clone(),
            })
        } else if can_read {
            try_read(rng)
        } else {
            None
        }
    };
    let mut b = built?;
    b.ui.insert("sent".into(), Value::Array(tokens));
    b.ui.insert("full".into(), json!(b.full));
    b.ui.insert("word".into(), json!(target));
    if b.kind == "anki_read" && !b.en.is_empty() {
        b.ui.insert("en".into(), json!(b.en));
    }
    b.ui.insert("deck".into(), json!(card.deck.rsplit("::").next().unwrap_or(&card.deck)));
    Some(b)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::anki::review_card;

    fn kaishi(id: i64, word: &str, reading: &str, meaning: &str, furi: &str, sent: &str, sent_furi: &str, sent_en: &str) -> Value {
        let f = |v: &str, o: i64| json!({"value": v, "order": o});
        json!({"cardId": id, "deckName": "i will do this::kaishi", "reps": 4, "queue": 2, "due": 100,
               "fields": {"Word": f(word, 0), "Word Reading": f(reading, 1), "Word Meaning": f(meaning, 2),
                          "Word Furigana": f(furi, 3), "Word Audio": f("[sound:x.mp3]", 4), "Sentence": f(sent, 5),
                          "Sentence Meaning": f(sent_en, 6), "Sentence Furigana": f(sent_furi, 7),
                          "Sentence Audio": f("[sound:y.mp3]", 8), "Notes": f("Can also be read わたくし.", 9)}})
    }

    fn watashi() -> ReviewCard {
        review_card(&kaishi(1, "私", "わたし", "I (polite, general)", "私[わたし]", "<b>私</b>はアンです。", "<b>私[わたし]</b>はアンです。", "I am Ann."))
            .unwrap()
    }

    #[test]
    fn field_roles_of_a_kaishi_card() {
        let c = watashi();
        assert_eq!(c.word, "私");
        assert_eq!(c.reading, "わたし");
        assert_eq!(c.meaning, "I (polite, general)");
        assert_eq!(c.sentence_en, "I am Ann.");
        assert_eq!(c.sentence_furi, "<b>私[わたし]</b>はアンです。");
        assert_eq!(c.deck, "i will do this::kaishi");
    }

    #[test]
    fn reading_from_furigana_when_the_reading_field_is_missing() {
        let mut v = kaishi(2, "彼", "", "he, him", "彼[かれ]", "<b>彼</b>はトムさんです。", "", "He is Tom-san.");
        v["fields"]["Word Reading"]["value"] = json!("");
        assert_eq!(review_card(&v).unwrap().reading, "かれ");
        assert_eq!(furi_kana("お 茶[ちゃ]"), "おちゃ");
        assert_eq!(furi_kana("私[わたし]"), "わたし");
    }

    #[test]
    fn sentence_tokens_with_highlight_and_furigana() {
        let mut c = watashi();
        c.sentence_furi = "<b>私[わたし]</b>は 毎日[まいにち] 学校[がっこう]に 行[い]きます。".into();
        let s = sentence(&c);
        assert_eq!(s.full, "私は毎日学校に行きます。");
        assert_eq!(s.tokens[0], json!({"t": "私", "hl": true}));
        assert_eq!(s.hl, Some(("私".into(), "わたし".into())));
        assert!(s.tokens.contains(&json!({"t": "毎日", "r": "まいにち"})));
        assert!(s.tokens.contains(&json!({"t": "行", "r": "い"})));
        assert!(s.tokens.contains(&json!({"t": "きます。"})));
    }

    #[test]
    fn okurigana_is_trimmed_off_the_ruby() {
        let mut out = vec![];
        furi_tokens(&mut out, "食べる[たべる]");
        assert_eq!(out, vec![json!({"t": "食", "r": "た"}), json!({"t": "べる"})]);
    }

    #[test]
    fn highlight_falls_back_to_the_word() {
        let mut c = watashi();
        c.sentence_furi = String::new();
        c.sentence = "これは私の本です。".into();
        let s = sentence(&c);
        assert_eq!(s.tokens, vec![json!({"t": "これは"}), json!({"t": "私", "hl": true}), json!({"t": "の本です。"})]);
    }

    #[test]
    fn kana_fakes_are_distinct_and_never_the_answer() {
        let mut rng = PyRandom::new(7);
        for ans in ["わたし", "がっこう", "おおきい", "けいかく", "せんせい", "りょこう", "め"] {
            let f = kana_fakes(ans, &mut rng, 3);
            assert!(!f.contains(&ans.to_string()), "{ans}: {f:?}");
            let set: HashSet<&String> = f.iter().collect();
            assert_eq!(set.len(), f.len());
            if ans.chars().count() >= 3 {
                assert_eq!(f.len(), 3, "{ans}: {f:?}");
            }
        }
    }

    #[test]
    fn meaning_question_has_distinct_choices() {
        let mut rng = PyRandom::new(3);
        let bank: Vec<ReviewCard> = [("彼", "かれ", "he, him"), ("本", "ほん", "book"), ("猫", "ねこ", "cat"), ("犬", "いぬ", "dog"), ("私", "わたし", "I (polite, general)")]
            .iter()
            .enumerate()
            .map(|(i, (w, r, m))| ReviewCard { card_id: i as i64 + 10, word: w.to_string(), reading: r.to_string(), meaning: m.to_string(), ..watashi() })
            .collect();
        let f = meaning_fakes(&watashi(), &bank, &mut rng, 3);
        assert_eq!(f.len(), 3);
        assert!(!f.iter().any(|m| m.starts_with("I (")));
        let set: HashSet<&String> = f.iter().collect();
        assert_eq!(set.len(), 3);
        // another deck family's meanings are not used
        let grammar: Vec<ReviewCard> = bank.iter().map(|c| ReviewCard { deck: "文法::2. N5".into(), ..c.clone() }).collect();
        assert!(meaning_fakes(&watashi(), &grammar, &mut rng, 3).is_empty());
    }

    #[test]
    fn built_questions_are_well_formed() {
        let mut rng = PyRandom::new(11);
        let bank: Vec<ReviewCard> = (0..8)
            .map(|i| ReviewCard { card_id: 100 + i, word: format!("語{i}"), reading: "ごい".into(), meaning: format!("meaning {i}"), ..watashi() })
            .collect();
        let mut kinds = HashSet::new();
        for reps in 0..12 {
            let c = ReviewCard { reps, ..watashi() };
            let b = build(&c, &bank, &["わたくし".into(), "わだし".into()], &mut rng).unwrap();
            kinds.insert(b.kind);
            assert_eq!(b.choices.len(), 4);
            let set: HashSet<&String> = b.choices.iter().collect();
            assert_eq!(set.len(), 4);
            if b.kind == "anki_read" {
                assert_eq!(b.choices[0], "わたし");
                assert!(b.choices.contains(&"わたくし".to_string()));
                assert_eq!(b.ui["en"], json!("I am Ann."));
            } else {
                assert_eq!(b.choices[0], "I (polite, general)");
                assert!(b.ui.get("en").is_none(), "the translation would give the meaning away");
            }
            assert_eq!(b.ui["deck"], json!("kaishi"));
        }
        assert_eq!(kinds.len(), 2, "both kinds come up across reviews");
    }

    #[test]
    fn inflected_highlight_asks_its_own_reading() {
        let mut rng = PyRandom::new(5);
        let mut c = watashi();
        c.word = "食べる".into();
        c.reading = "たべる".into();
        c.meaning = String::new();
        c.sentence_furi = "パンを<b>食[た]べて</b>います。".into();
        let b = build(&c, &[], &[], &mut rng).unwrap();
        assert_eq!(b.kind, "anki_read");
        assert_eq!(b.choices[0], "たべて");
        assert_eq!(b.ui["word"], json!("食べて"));
    }

    #[test]
    fn kana_only_word_without_meaning_is_skipped() {
        let mut rng = PyRandom::new(5);
        let mut c = watashi();
        c.word = "あなた".into();
        c.reading = "あなた".into();
        c.meaning = String::new();
        c.sentence_furi = "<b>あなた</b>はトムさんですか。".into();
        assert!(build(&c, &[], &[], &mut rng).is_none());
    }
}
