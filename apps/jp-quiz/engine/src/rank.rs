//! Rank: how much of real Japanese you know, as a ladder of tiers — JLPT N5 → N1, then 常用漢字 — measured
//! against full lists, not against what the quiz happens to contain.
//!
//! Each tier has four parts:
//!   * words     the JLPT vocabulary list of that level (J. Waller)
//!   * everyday  words people actually use beyond the JLPT lists (web, subtitles, social media; slang,
//!               tech, brands, cars, food), most frequent first: 90 % 常用 kanji · 7.5 % kana · 2.5 % other kanji
//!   * kanji     the JLPT kanji of that level; the 常用 tier adds the rest of the 2136 常用漢字
//!   * grammar   the grammar commonly taught for that level
//! A tier is *reached* when you know at least 80 % of every part of it and of all tiers below it.
//! Known = remembered for at least three weeks (memory stability ≥ 21 days, Anki's "mature"), from the
//! quiz's spaced-repetition cards or from a synced Anki card (interval ≥ 21 days).
//! A quick placement test (calibration) estimates what you already know per tier, so the rank starts where
//! you are instead of at zero; real memory data replaces the estimate as soon as it is higher.
use super::{Engine, R};
use crate::pyjson::{f, round_n};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

/// Share of every part that a tier asks for.
pub const REACH: f64 = 0.8;
/// Memory stability (days) from which a card counts as known.
pub const KNOWN_S: f64 = 21.0;
/// Tiers, easiest first: JLPT level, or 0 for the 常用漢字 tier.
pub const TIERS: [i64; 6] = [5, 4, 3, 2, 1, 0];
const PARTS: [&str; 4] = ["words", "everyday", "kanji", "grammar"];

pub fn tier_label(t: i64) -> String {
    if t == 0 { "常用".into() } else { format!("N{t}") }
}

// ------------------------------------------------------------------ the lists (compiled in)
struct Word {
    tier: i64,
    form: String,          // how it is written (kanji, or kana for kana words)
    kana: String,          // reading
    everyday: bool,
    tag: String,
    en: String,
    ru: String,
}

struct Kanji {
    tier: i64,
    ch: char,
}

struct Gram {
    tier: i64,
    pattern: String,
    links: Vec<String>,
    alts: Vec<String>, // spellings to match an Anki card against
    en: String,
    ru: String,
}

struct Syllabus {
    words: Vec<Word>,
    kanji: Vec<Kanji>,
    grammar: Vec<Gram>,
}

fn rows(text: &'static str) -> impl Iterator<Item = Vec<&'static str>> {
    text.lines().filter(|l| !l.starts_with('#') && !l.trim().is_empty()).map(|l| l.split('\t').collect())
}

fn syllabus() -> &'static Syllabus {
    static S: OnceLock<Syllabus> = OnceLock::new();
    S.get_or_init(|| {
        let mut words = vec![];
        for r in rows(include_str!("../../assets/jlpt/vocab.tsv")) {
            let (kanji, kana) = (r[2].to_string(), r[3].to_string());
            words.push(Word {
                tier: r[0].parse().unwrap_or(1),
                form: if kanji.is_empty() { kana.clone() } else { kanji },
                kana,
                everyday: false,
                tag: String::new(),
                en: r.get(4).map_or(String::new(), |s| s.to_string()),
                ru: String::new(),
            });
        }
        for r in rows(include_str!("../../assets/jlpt/everyday.tsv")) {
            let g = |i: usize| r.get(i).copied().unwrap_or("").to_string();
            words.push(Word { tier: r[0].parse().unwrap_or(0), form: g(3), kana: g(4), everyday: true, tag: g(6), en: g(8), ru: g(9) });
        }
        let kanji = rows(include_str!("../../assets/jlpt/kanji.tsv"))
            .filter_map(|r| Some(Kanji { tier: r[0].parse().ok()?, ch: r.get(2)?.chars().next()? }))
            .collect();
        let grammar = rows(include_str!("../../assets/jlpt/grammar.tsv"))
            .map(|r| {
                let g = |i: usize| r.get(i).copied().unwrap_or("").trim().to_string();
                let pattern = g(1);
                let mut alts = vec![];
                for alt in pattern.split(" / ") {
                    let alt = alt.split(" (").next().unwrap_or("").replace(['〜', ' '], "");
                    let short = alt.split('(').next().unwrap_or("").to_string() + alt.split(')').nth(1).unwrap_or("");
                    let long = alt.replace(['(', ')'], "");
                    alts.extend([short, long].into_iter().filter(|s| s.chars().count() >= 2));
                }
                Gram {
                    tier: g(0).parse().unwrap_or(1),
                    links: g(2).split(',').map(str::trim).filter(|s| !s.is_empty()).map(String::from).collect(),
                    pattern,
                    alts,
                    en: g(3),
                    ru: g(4),
                }
            })
            .collect();
        Syllabus { words, kanji, grammar }
    })
}

// ------------------------------------------------------------------ links into the quiz content
/// Which quiz knowledge components teach each list entry (built once from the content database).
#[derive(Default)]
pub struct Index {
    word_kcs: Vec<Vec<String>>,
    gram_kcs: Vec<Vec<String>>,
    kanji_in_quiz: HashSet<char>,
}

impl Index {
    pub fn build(kcs: &[&String], tags: &HashSet<&str>) -> Index {
        let s = syllabus();
        let kc_set: HashSet<&str> = kcs.iter().map(|k| k.as_str()).collect();
        let word_kcs = s
            .words
            .iter()
            .map(|w| ["use", "read", "write"].iter().map(|fam| format!("{fam}:{}", w.form)).filter(|k| kc_set.contains(k.as_str())).collect())
            .collect();
        let gram_kcs = s
            .grammar
            .iter()
            .map(|g| {
                let mut out: Vec<String> = vec![];
                for l in &g.links {
                    // pt:<particle> = every usage of it; anything else names one component
                    if l.starts_with("pt:") && l.matches(':').count() == 1 {
                        let p = format!("{l}:");
                        out.extend(kcs.iter().filter(|k| k.starts_with(&p)).map(|k| k.to_string()));
                    } else if kc_set.contains(l.as_str()) {
                        out.push(l.clone());
                    }
                }
                out
            })
            .collect();
        let kanji_in_quiz = tags.iter().filter_map(|t| t.strip_prefix("k:")).filter_map(|k| k.chars().next()).collect();
        Index { word_kcs, gram_kcs, kanji_in_quiz }
    }
}

/// Words the user's Anki decks know (interval ≥ 21 days) or are learning, saved by the last Anki sync.
#[derive(Default)]
pub struct AnkiWords {
    pub known: HashSet<String>,
    pub learning: HashSet<String>,
}

impl AnkiWords {
    pub fn from_json(v: &str) -> AnkiWords {
        let parsed: Value = serde_json::from_str(v).unwrap_or(Value::Null);
        let set = |k: &str| parsed.get(k).and_then(Value::as_array).map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
        AnkiWords { known: set("known"), learning: set("learning") }
    }
}

// ------------------------------------------------------------------ status
/// 0 = not met yet, 1 = learning (seen), 2 = known.
type St = u8;

#[derive(Clone, Copy, Default)]
struct Count {
    total: usize,
    known: usize,
    seen: usize,
    in_quiz: usize,
}

impl Count {
    fn add(&mut self, st: St, q: bool) {
        self.total += 1;
        self.known += usize::from(st == 2);
        self.seen += usize::from(st >= 1);
        self.in_quiz += usize::from(q);
    }
    fn plus(self, o: Count) -> Count {
        Count { total: self.total + o.total, known: self.known + o.known, seen: self.seen + o.seen, in_quiz: self.in_quiz + o.in_quiz }
    }
    fn json(&self) -> Value {
        json!({"total": self.total, "known": self.known, "learning": self.seen - self.known, "in_quiz": self.in_quiz})
    }
}

fn need(total: usize, share: f64) -> usize {
    (total as f64 * share - 1e-9).ceil() as usize
}

pub struct State {
    word_st: Vec<St>,
    kanji_st: Vec<St>,
    gram_st: Vec<St>,
    /// per tier (TIERS order), per part (PARTS order)
    counts: [[Count; 4]; 6],
}

impl State {
    fn cum(&self, upto: usize) -> [Count; 4] {
        let mut c = [Count::default(); 4];
        for t in 0..=upto {
            for p in 0..4 {
                c[p] = c[p].plus(self.counts[t][p]);
            }
        }
        c
    }
    fn reached(&self, upto: usize) -> bool {
        self.cum(upto).iter().all(|c| c.known >= need(c.total, REACH))
    }
    /// (step, progress 0..1 toward the next step, items still to learn, target tier index).
    /// step 0..5 = working toward TIERS[step]; 6 = every tier reached, working toward 100 %; 7 = everything known.
    pub fn step(&self) -> (usize, f64, usize, usize) {
        let mut m = 0;
        while m < TIERS.len() && self.reached(m) {
            m += 1;
        }
        let all = self.cum(TIERS.len() - 1);
        let (progress, to_go) = if m < TIERS.len() {
            let c = self.cum(m);
            let target: usize = c.iter().map(|c| need(c.total, REACH)).sum();
            let got: usize = c.iter().map(|c| c.known.min(need(c.total, REACH))).sum();
            (got as f64 / target.max(1) as f64, target - got)
        } else {
            let lo: usize = all.iter().map(|c| need(c.total, REACH)).sum();
            let hi: usize = all.iter().map(|c| c.total).sum();
            let got: usize = all.iter().map(|c| c.known).sum();
            (((got as f64 - lo as f64) / (hi - lo).max(1) as f64).clamp(0.0, 1.0), hi - got)
        };
        let step = if m < TIERS.len() { m } else if to_go == 0 { 7 } else { 6 };
        (step, progress, to_go, m.min(TIERS.len() - 1))
    }

    /// Label of the last tier reached (None before N5).
    pub fn reached_label(step: usize) -> Option<String> {
        (step >= 1).then(|| tier_label(TIERS[(step - 1).min(TIERS.len() - 1)]))
    }
}

impl Engine {
    fn card_st(&self, kc: &str, now: f64) -> St {
        let _ = now;
        match self.cards.get(kc) {
            Some(c) if c.state == "review" && c.s >= KNOWN_S => 2,
            Some(c) if c.state != "new" => 1,
            _ => 0,
        }
    }

    pub(super) fn rank_state(&self) -> State {
        let s = syllabus();
        let now = (self.now)();
        let ix = &self.rank_ix;
        let anki = &self.anki_words;
        let anki_st = |w: &str| -> St {
            if anki.known.contains(w) { 2 } else if anki.learning.contains(w) { 1 } else { 0 }
        };
        // every word you know or are learning, for the kanji written in it
        let mut kanji_st: HashMap<char, St> = HashMap::new();
        let mut mark = |w: &str, st: St| {
            if st == 0 {
                return;
            }
            for ch in w.chars().filter(|c| ('\u{4e00}'..='\u{9fff}').contains(c) || ('\u{3400}'..='\u{4dbf}').contains(c)) {
                let e = kanji_st.entry(ch).or_default();
                *e = (*e).max(st);
            }
        };
        for kc in self.cards.keys() {
            if let Some((fam, w)) = kc.split_once(':') {
                if matches!(fam, "use" | "read" | "write") {
                    mark(w, self.card_st(kc, now));
                }
            }
        }
        for w in &anki.known {
            mark(w, 2);
        }
        for w in &anki.learning {
            mark(w, 1);
        }
        let mut counts = [[Count::default(); 4]; 6];
        let tier_ix = |t: i64| TIERS.iter().position(|&x| x == t).unwrap_or(5);
        let word_st: Vec<St> = s
            .words
            .iter()
            .enumerate()
            .map(|(i, w)| {
                let quiz = ix.word_kcs[i].iter().map(|kc| self.card_st(kc, now)).max().unwrap_or(0);
                let mut st = quiz.max(anki_st(&w.form));
                if w.form == w.kana || w.form.chars().all(|c| !('\u{4e00}'..='\u{9fff}').contains(&c)) {
                    st = st.max(anki_st(&w.kana));
                }
                counts[tier_ix(w.tier)][if w.everyday { 1 } else { 0 }].add(st, !ix.word_kcs[i].is_empty());
                st
            })
            .collect();
        let kanji: Vec<St> = s
            .kanji
            .iter()
            .map(|k| {
                let st = kanji_st.get(&k.ch).copied().unwrap_or(0);
                counts[tier_ix(k.tier)][2].add(st, ix.kanji_in_quiz.contains(&k.ch));
                st
            })
            .collect();
        let gram_st: Vec<St> = s
            .grammar
            .iter()
            .enumerate()
            .map(|(i, g)| {
                let kcs = &ix.gram_kcs[i];
                let sts: Vec<St> = kcs.iter().map(|kc| self.card_st(kc, now)).collect();
                let quiz = if sts.is_empty() { 0 } else if sts.iter().all(|&x| x == 2) { 2 } else { u8::from(sts.iter().any(|&x| x >= 1)) };
                let st = g.alts.iter().map(|a| anki_st(a)).max().unwrap_or(0).max(quiz);
                counts[tier_ix(g.tier)][3].add(st, !kcs.is_empty());
                st
            })
            .collect();
        // the placement test's estimate counts until your own memory data shows more
        for t in 0..TIERS.len() {
            for p in 0..4 {
                let est = (self.calib_est[t][p] * counts[t][p].total as f64).round() as usize;
                counts[t][p].known = counts[t][p].known.max(est.min(counts[t][p].total));
                counts[t][p].seen = counts[t][p].seen.max(counts[t][p].known);
            }
        }
        State { word_st, kanji_st: kanji, gram_st, counts }
    }

    /// The step on the ladder, for promotion events after an answer.
    pub(super) fn tier_key(&self) -> usize {
        self.rank_state().step().0
    }

    pub(super) fn tier_event(&self, before: usize) -> Option<Value> {
        let step = self.tier_key();
        (step > before).then(|| json!({"type": "tier", "step": step, "reached": State::reached_label(step)}))
    }

    /// Short rank summary for the HUD: last tier reached, the one you are working toward, progress.
    pub(super) fn rank_brief(&self) -> Value {
        let (step, progress, _, target) = self.rank_state().step();
        json!({"step": step, "reached": State::reached_label(step), "target": tier_label(TIERS[target]),
               "progress": f(round_n(progress, 3))})
    }

    /// The Rank tab: medal, every tier's parts, and what is left for the next one.
    pub fn rank(&self) -> R<Value> {
        let s = syllabus();
        let st = self.rank_state();
        let (step, progress, to_go, target) = st.step();
        let tiers: Vec<Value> = TIERS
            .iter()
            .enumerate()
            .map(|(t, &lv)| {
                let own = &st.counts[t];
                let cum = st.cum(t);
                let mut parts = serde_json::Map::new();
                for (p, name) in PARTS.iter().enumerate() {
                    let mut v = own[p].json();
                    v["cum_total"] = json!(cum[p].total);
                    v["cum_known"] = json!(cum[p].known);
                    v["cum_need"] = json!(need(cum[p].total, REACH));
                    v["estimated"] = json!(self.calib_est[t][p] > 0.0);
                    parts.insert(name.to_string(), v);
                }
                let tgt: usize = cum.iter().map(|c| need(c.total, REACH)).sum();
                let got: usize = cum.iter().map(|c| c.known.min(need(c.total, REACH))).sum();
                let full_total: usize = cum.iter().map(|c| c.total).sum();
                let full_known: usize = cum.iter().map(|c| c.known).sum();
                json!({"tier": lv, "label": tier_label(lv), "reached": st.reached(t), "parts": parts,
                       "progress": f(round_n(got as f64 / tgt.max(1) as f64, 4)), "to_go": tgt - got,
                       "coverage": f(round_n(full_known as f64 / full_total.max(1) as f64, 4))})
            })
            .collect();
        // what is left in the tier you are working on: its kanji (all), grammar (all), and the next words to learn
        let tl = TIERS[target];
        let kanji: Vec<Value> = s
            .kanji
            .iter()
            .zip(&st.kanji_st)
            .filter(|(k, _)| k.tier == tl)
            .map(|(k, &x)| json!([k.ch.to_string(), x, self.rank_ix.kanji_in_quiz.contains(&k.ch)]))
            .collect();
        let grammar: Vec<Value> = s
            .grammar
            .iter()
            .enumerate()
            .filter(|(_, g)| g.tier == tl)
            .map(|(i, g)| json!({"p": g.pattern, "en": g.en, "ru": g.ru, "s": st.gram_st[i], "q": !self.rank_ix.gram_kcs[i].is_empty()}))
            .collect();
        // next words: unknown ones of this tier (and below), the quiz's own first, everyday by frequency
        let mut next_words: Vec<Value> = vec![];
        for pass in 0..2 {
            for (i, w) in s.words.iter().enumerate() {
                if next_words.len() >= 60 {
                    break;
                }
                let tier_ok = TIERS.iter().position(|&x| x == w.tier).is_some_and(|p| p <= target);
                let q = !self.rank_ix.word_kcs[i].is_empty();
                if !tier_ok || st.word_st[i] == 2 || (pass == 0) != q {
                    continue;
                }
                next_words.push(json!({"w": w.form, "r": w.kana, "e": w.everyday, "tag": w.tag, "en": w.en, "ru": w.ru,
                                       "s": st.word_st[i], "q": q, "tier": tier_label(w.tier)}));
            }
        }
        let anki_n = self.anki_words.known.len() + self.anki_words.learning.len();
        let known_all: usize = st.cum(TIERS.len() - 1).iter().map(|c| c.known).sum();
        let plan = self.study_plan(to_go, known_all)?;
        let calib: Value = serde_json::from_str(&self.kv_get("calib").unwrap_or_else(|| "null".into())).unwrap_or(Value::Null);
        Ok(json!({
            "type": "rank",
            "step": {"index": step, "progress": f(round_n(progress, 4)), "to_go": to_go, "target": tier_label(tl),
                     "reached": State::reached_label(step)},
            "tiers": tiers, "reach": REACH, "known_days": KNOWN_S,
            "next": {"tier": tl, "label": tier_label(tl), "kanji": kanji, "grammar": grammar, "words": next_words},
            "anki_words": anki_n, "plan": plan, "daily_auto": self.daily_auto(), "goal": self.daily_goal(),
            "calib": calib.get("ts").cloned().unwrap_or(Value::Null),
        }))
    }

    fn kv_get(&self, key: &str) -> Option<String> {
        self.pdb.query_row("SELECT value FROM kv WHERE key=?", [key], |r| r.get(0)).ok()
    }

    pub(super) fn daily_auto(&self) -> bool {
        self.settings.get("daily_auto").map_or(true, super::truthy)
    }

    /// The daily goal in questions: chosen automatically from the study plan (the time per day that
    /// reaches the next step in about three months), or the number you set when automatic is off.
    pub(super) fn daily_goal(&self) -> i64 {
        let manual = self.settings.get("daily_goal").and_then(Value::as_i64).unwrap_or(30);
        if !self.daily_auto() {
            return manual;
        }
        let st = self.rank_state();
        let (_, _, to_go, _) = st.step();
        let known_all: usize = st.cum(TIERS.len() - 1).iter().map(|c| c.known).sum();
        self.study_plan(to_go, known_all).ok().and_then(|p| p["suggest_questions"].as_i64()).unwrap_or(manual)
    }

    // ------------------------------------------------------------------ placement test
    /// Start (or restart) the quick placement test: a few words and grammar points per tier, from N5 up,
    /// until you stop knowing most of them. "Don't know" is an answer, and guessing is corrected for.
    pub fn calib_start(&mut self) -> R<Value> {
        self.calib = Some(Calib { tier: 0, block: vec![], done: vec![], current: None });
        self.calib_fill_block();
        self.calib_next()
    }

    fn calib_fill_block(&mut self) {
        let s = syllabus();
        let Some(c) = self.calib.as_mut() else { return };
        let tl = TIERS[c.tier];
        let mut block = vec![];
        let pick = |rng: &mut crate::pyrand::PyRandom, pool: &[usize], k: usize| -> Vec<usize> {
            let idx = rng.sample_idx(pool.len(), k.min(pool.len()));
            idx.into_iter().map(|i| pool[i]).collect()
        };
        let jlpt: Vec<usize> = s.words.iter().enumerate().filter(|(_, w)| w.tier == tl && !w.everyday && !w.en.is_empty()).map(|(i, _)| i).collect();
        let every: Vec<usize> = s.words.iter().enumerate().filter(|(_, w)| w.tier == tl && w.everyday && !w.en.is_empty()).map(|(i, _)| i).collect();
        let gram: Vec<usize> = s.grammar.iter().enumerate().filter(|(_, g)| g.tier == tl && !g.en.is_empty()).map(|(i, _)| i).collect();
        let (nj, ne, ng) = if tl == 0 { (0, 6, 0) } else { (3, 2, 2) };
        for i in pick(&mut self.rng, &jlpt, nj) {
            block.push((0usize, i));
        }
        for i in pick(&mut self.rng, &every, ne) {
            block.push((1, i));
        }
        for i in pick(&mut self.rng, &gram, ng) {
            block.push((3, i));
        }
        self.rng.shuffle(&mut block);
        if let Some(c) = self.calib.as_mut() {
            c.block = block;
        }
    }

    /// The next test question, or the result when the test is over.
    fn calib_next(&mut self) -> R<Value> {
        let s = syllabus();
        let ru = self.settings.get("lang").and_then(Value::as_str) == Some("ru");
        let Some(c) = self.calib.as_mut() else { return Ok(json!({"type": "error", "error": "no test running"})) };
        let Some((part, i)) = c.block.pop() else { return self.calib_finish_block() };
        let tl = TIERS[c.tier];
        let head = |s: &str| s.split([';', ',', '(']).next().unwrap_or("").trim().to_string();
        let (prompt, reading, right, pool): (String, String, String, Vec<String>) = if part == 3 {
            let g = &s.grammar[i];
            let mean = |g: &Gram| if ru && !g.ru.is_empty() { g.ru.clone() } else { g.en.clone() };
            let pool = s.grammar.iter().filter(|o| o.tier == tl && o.pattern != g.pattern).map(mean).collect();
            (g.pattern.clone(), String::new(), mean(g), pool)
        } else {
            let w = &s.words[i];
            let mean = |w: &Word| head(if ru && !w.ru.is_empty() { &w.ru } else { &w.en });
            let pool = s.words.iter().filter(|o| o.tier == tl && o.everyday == w.everyday && !o.en.is_empty() && o.form != w.form).map(mean).collect();
            (w.form.clone(), if w.kana != w.form { w.kana.clone() } else { String::new() }, mean(w), pool)
        };
        let mut choices = vec![right.clone()];
        let mut tries = 0;
        while choices.len() < 4 && tries < 200 && !pool.is_empty() {
            tries += 1;
            let o = &pool[self.rng.randbelow(pool.len())];
            if !o.is_empty() && !choices.iter().any(|x| x.to_lowercase() == o.to_lowercase()) {
                choices.push(o.clone());
            }
        }
        let mut order: Vec<usize> = (0..choices.len()).collect();
        self.rng.shuffle(&mut order);
        let shown: Vec<String> = order.iter().map(|&k| choices[k].clone()).collect();
        let correct = order.iter().position(|&k| k == 0).unwrap_or(0);
        let c = self.calib.as_mut().unwrap();
        c.current = Some((part, correct, reading.clone()));
        let asked = c.done.len() + 1;
        Ok(json!({"type": "calib_q", "tier": tier_label(tl), "kind": if part == 3 { "grammar" } else { "word" },
                  "prompt": prompt, "choices": shown, "n": asked, "of_about": CALIB_EXPECT}))
    }

    /// An answer: a choice index, or null for "don't know". Returns the next question or the result.
    pub fn calib_answer(&mut self, choice: Option<i64>) -> R<Value> {
        let Some(c) = self.calib.as_mut() else { return Ok(json!({"type": "error", "error": "no test running"})) };
        let Some((part, correct, reading)) = c.current.take() else { return self.calib_next() };
        let tier = c.tier;
        let res = choice.map(|x| x as usize == correct);
        c.done.push((tier, part, res));
        let mut next = self.calib_next()?;
        next["last"] = json!({"ok": res, "answer": correct, "reading": reading});
        Ok(next)
    }

    pub fn calib_cancel(&mut self) -> Value {
        self.calib = None;
        json!({"type": "calib_cancelled"})
    }

    /// End of a tier's block: go on to the next tier while you know most of it, else finish.
    fn calib_finish_block(&mut self) -> R<Value> {
        let c = self.calib.as_ref().unwrap();
        let tier = c.tier;
        let score = calib_score(c.done.iter().filter(|d| d.0 == tier).map(|d| d.2));
        if score >= CALIB_GO_ON && tier + 1 < TIERS.len() {
            self.calib.as_mut().unwrap().tier += 1;
            self.calib_fill_block();
            return self.calib_next();
        }
        // estimates per tier and part: a part's own score, pulled toward the tier's overall score
        let c = self.calib.take().unwrap();
        let mut est = [[0.0f64; 4]; 6];
        let mut tiers_out = vec![];
        for t in 0..TIERS.len() {
            let all: Vec<Option<bool>> = c.done.iter().filter(|d| d.0 == t).map(|d| d.2).collect();
            if all.is_empty() {
                continue;
            }
            let tier_score = calib_score(all.iter().copied());
            for p in [0usize, 1, 3] {
                let mine: Vec<Option<bool>> = c.done.iter().filter(|d| d.0 == t && d.1 == p).map(|d| d.2).collect();
                let n = mine.len() as f64;
                est[t][p] = ((calib_score(mine.into_iter()) * n + tier_score * 2.0) / (n + 2.0)).clamp(0.0, CALIB_CAP);
            }
            // kanji: no questions of their own; the JLPT words of the tier stand for them, a little lower
            est[t][2] = (est[t][0] * 0.9).clamp(0.0, CALIB_CAP);
            if TIERS[t] == 0 {
                est[t][2] = (est[t][1] * 0.8).clamp(0.0, CALIB_CAP);
            }
            tiers_out.push(json!({"tier": tier_label(TIERS[t]), "score": f(round_n(tier_score, 3)),
                                  "words": f(round_n(est[t][0], 3)), "everyday": f(round_n(est[t][1], 3)),
                                  "kanji": f(round_n(est[t][2], 3)), "grammar": f(round_n(est[t][3], 3))}));
        }
        self.calib_est = est;
        let now = (self.now)();
        let saved = json!({"ts": f(now), "est": est.iter().map(|r| r.iter().map(|x| f(round_n(*x, 4))).collect::<Vec<_>>()).collect::<Vec<_>>(),
                           "tiers": tiers_out, "answers": c.done.len()});
        self.pdb.execute("INSERT OR REPLACE INTO kv VALUES ('calib', ?)", [crate::pyjson::dumps(&saved, false)]).map_err(|e| e.to_string())?;
        let brief = self.rank_brief();
        Ok(json!({"type": "calib_done", "tiers": saved["tiers"], "answers": c.done.len(), "rank": brief}))
    }

    pub(super) fn load_calib(&mut self) {
        let v: Value = serde_json::from_str(&self.kv_get("calib").unwrap_or_else(|| "null".into())).unwrap_or(Value::Null);
        if let Some(rows) = v.get("est").and_then(Value::as_array) {
            for (t, row) in rows.iter().enumerate().take(TIERS.len()) {
                for (p, x) in row.as_array().into_iter().flatten().enumerate().take(4) {
                    self.calib_est[t][p] = x.as_f64().unwrap_or(0.0);
                }
            }
        }
    }

    /// How long the next step takes at a few daily study times, from your own pace:
    ///   seconds per question = your average answer time + a few seconds reading the result;
    ///   reviews to make one new item known (≥ 21 days) ≈ 4 good reviews ÷ your accuracy;
    ///   upkeep = the items you know come back about every 40 days;
    ///   a new item needs about 3 weeks of spaced reviews before it counts as known.
    fn study_plan(&self, to_go: usize, known_all: usize) -> R<Value> {
        let (n, ms, correct): (i64, f64, i64) = self
            .pdb
            .query_row("SELECT COUNT(*), COALESCE(SUM(MIN(MAX(ms, 0), 120000)), 0), COALESCE(SUM(correct), 0) FROM answers", [], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .map_err(|e| e.to_string())?;
        let since = (self.now)() - 14.0 * 86400.0;
        let recent_ms: f64 = self
            .pdb
            .query_row("SELECT COALESCE(SUM(MIN(MAX(ms, 0), 120000)), 0) FROM answers WHERE ts >= ?", [since], |r| r.get(0))
            .map_err(|e| e.to_string())?;
        let sec_per_q = if n > 0 { (ms / 1000.0 / n as f64 + PLAN_READ_S).clamp(6.0, 60.0) } else { 15.0 };
        let acc = if n > 0 { (correct as f64 / n as f64).max(0.5) } else { 0.75 };
        let reviews_per_new = PLAN_REVIEWS / acc;
        let upkeep = known_all as f64 / PLAN_UPKEEP_DAYS;
        let days_for = |minutes: f64| -> Option<f64> {
            let q = minutes * 60.0 / sec_per_q;
            let new_per_day = (q - upkeep) / reviews_per_new;
            if to_go == 0 {
                Some(0.0)
            } else if new_per_day <= 0.05 {
                None
            } else {
                Some(to_go as f64 / new_per_day + PLAN_LATENCY_DAYS)
            }
        };
        let options: Vec<Value> = [10.0, 20.0, 30.0, 45.0, 60.0]
            .iter()
            .map(|&m| json!({"min": m as i64, "days": days_for(m).map(|d| d.round() as i64), "questions": (m * 60.0 / sec_per_q).round() as i64}))
            .collect();
        // the time per day that gets you there in about three months
        let per_day_new = to_go as f64 / (PLAN_HORIZON_DAYS - PLAN_LATENCY_DAYS);
        let need_q = per_day_new * reviews_per_new + upkeep;
        let suggest = ((need_q * sec_per_q / 60.0 / 5.0).ceil() * 5.0).clamp(10.0, 240.0);
        Ok(json!({
            "sec_per_q": f(round_n(sec_per_q, 1)), "accuracy": f(round_n(acc, 3)), "reviews_per_new": f(round_n(reviews_per_new, 1)),
            "upkeep_per_day": upkeep.round() as i64, "recent_min_per_day": (recent_ms / 60000.0 / 14.0).round() as i64,
            "options": options, "suggest_min": suggest as i64, "suggest_days": PLAN_HORIZON_DAYS as i64,
            "suggest_questions": (suggest * 60.0 / sec_per_q).round() as i64,
            "pace_days": days_for((recent_ms / 60000.0 / 14.0).max(1.0)).map(|d| d.round() as i64),
        }))
    }
}

/// Study plan model (see study_plan).
const PLAN_READ_S: f64 = 4.0;
const PLAN_REVIEWS: f64 = 4.0;
const PLAN_UPKEEP_DAYS: f64 = 40.0;
const PLAN_LATENCY_DAYS: f64 = 21.0;
const PLAN_HORIZON_DAYS: f64 = 90.0;

// ------------------------------------------------------------------ placement test state
/// A running placement test.
pub struct Calib {
    tier: usize,                              // index into TIERS being tested
    block: Vec<(usize, usize)>,               // questions left in this tier: (part, list index)
    done: Vec<(usize, usize, Option<bool>)>,  // (tier, part, right / wrong / None = "don't know")
    current: Option<(usize, usize, String)>,  // (part, correct choice, reading to show after)
}

/// Share known from a block of answers, corrected for guessing (4 choices: right − wrong/3).
fn calib_score(answers: impl Iterator<Item = Option<bool>>) -> f64 {
    let (mut n, mut right, mut wrong) = (0.0f64, 0.0f64, 0.0f64);
    for a in answers {
        n += 1.0;
        match a {
            Some(true) => right += 1.0,
            Some(false) => wrong += 1.0,
            None => {}
        }
    }
    if n == 0.0 { 0.0 } else { ((right - wrong / 3.0) / n).clamp(0.0, 1.0) }
}

/// Go on to the next tier when at least this share of a block is known.
const CALIB_GO_ON: f64 = 0.55;
/// An estimate never claims a whole part; the last bit has to come from real practice.
const CALIB_CAP: f64 = 0.95;
/// Roughly how many questions the test takes (3 tiers × 7).
const CALIB_EXPECT: usize = 21;
