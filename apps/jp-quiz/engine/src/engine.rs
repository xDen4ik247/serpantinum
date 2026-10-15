//! The quiz engine (port of jpquiz/engine.py): matchmaking, spaced repetition, unlocks, game layer,
//! persistence. Same database schema, same JSON replies, same random choices for the same seed.
use crate::anki::{self, Outbox};
use crate::clock;
use crate::memory::{grade_from, memory_shift, review, Card, DAY};
use crate::model::{guess, logit, to_rating, Comp, Model, Terms};
use crate::pyjson::{dumps, f, round_i, round_n};
use crate::pyrand::PyRandom;
use crate::review::{self, Reviews};
use indexmap::IndexMap;
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet, VecDeque};

#[path = "rank.rs"]
mod rank;

pub const CATS: [&str; 5] = ["particles", "grammar", "kanji", "vocab", "reading"];

fn cat_name(c: &str) -> Value {
    let (a, b) = match c {
        "particles" => ("Particles", "Частицы"),
        "grammar" => ("Grammar", "Грамматика"),
        "kanji" => ("Kanji", "Кандзи"),
        "vocab" => ("Vocabulary", "Лексика"),
        _ => ("Reading", "Чтение"),
    };
    json!([a, b])
}

fn level_base(lv: i64) -> f64 {
    match lv {
        5 => -1.0,
        4 => 0.0,
        _ => 1.0,
    }
}

fn fast(kind: &str) -> f64 {
    match kind {
        "particle" => 4.0,
        "conj" => 5.0,
        "gmean" => 7.0,
        "voice" => 6.0,
        "form" => 5.0,
        "order" => 12.0,
        "odd" => 10.0,
        "kread" => 4.0,
        "kwrite" => 4.0,
        "vocab" => 5.0,
        "meaning" => 8.0,
        "produce" => 9.0,
        _ => panic!("KeyError: {kind:?}"),
    }
}

fn budget_base(kind: &str) -> f64 {
    match kind {
        "particle" => 22.0,
        "conj" => 26.0,
        "gmean" => 34.0,
        "voice" => 30.0,
        "form" => 26.0,
        "order" => 55.0,
        "odd" => 40.0,
        "kread" => 22.0,
        "kwrite" => 22.0,
        "vocab" => 28.0,
        "meaning" => 40.0,
        "produce" => 45.0,
        _ => 30.0,
    }
}

const OVERTIME_XP: f64 = 0.6;
/// Shown rating: share of a drop that shows, how far below the recent best it may fall, and "recent".
const LOSS_DAMP: f64 = 0.35;
const FLOOR_GAP: f64 = 60.0;
/// While the shown rating is above the model: share of a gain that shows, and the largest gap allowed.
const ABOVE_GAIN: f64 = 0.7;
const MAX_ABOVE: f64 = 90.0;
const PEAK_DAYS: i64 = 7;
/// Score bonus for a not-yet-met everyday word (everyday-pack items), so new daily vocabulary keeps coming.
const EVERYDAY_NEW: f64 = 3.0;
const KIND_MIX: [(&str, f64); 12] = [
    ("particle", 1.3),
    ("conj", 1.2),
    ("gmean", 1.0),
    ("voice", 0.5),
    ("form", 0.4),
    ("order", 0.8),
    ("odd", 0.4),
    ("kread", 1.0),
    ("kwrite", 0.8),
    ("vocab", 1.0),
    ("meaning", 0.9),
    ("produce", 0.7),
];

fn kind_mix(k: &str) -> f64 {
    KIND_MIX.iter().find(|(n, _)| *n == k).map(|(_, w)| *w).unwrap_or(0.5)
}

fn kind_name(k: &str) -> Option<Value> {
    let (a, b) = match k {
        "particle" => ("Particle", "Частица"),
        "conj" => ("Conjugation", "Спряжение"),
        "gmean" => ("Grammar meaning", "Значение грамматики"),
        "voice" => ("Voice", "Залог"),
        "form" => ("Tense & polarity", "Время и отрицание"),
        "order" => ("並べ替え · word order", "並べ替え · порядок слов"),
        "odd" => ("Spot the mistake", "Найди ошибку"),
        "kread" => ("Kanji reading", "Чтение кандзи"),
        "kwrite" => ("Kanji writing", "Написание кандзи"),
        "vocab" => ("Word in context", "Слово в контексте"),
        "meaning" => ("What does it mean?", "Что это значит?"),
        "produce" => ("Say it in Japanese", "Как сказать по-японски?"),
        "anki_read" => ("Anki · reading", "Anki · чтение"),
        "anki_mean" => ("Anki · meaning", "Anki · значение"),
        _ => return None,
    };
    Some(json!([a, b]))
}

const PLACEMENT_N: i64 = 12;
const PLACEMENT_KINDS: [&str; 7] = ["particle", "conj", "gmean", "kread", "kwrite", "vocab", "meaning"];
const RANKS: [(f64, &str); 5] = [(-99.0, "N5…"), (-0.49, "N5"), (0.51, "N4"), (1.51, "N3"), (2.4, "N3+")];

fn default_settings() -> Map<String, Value> {
    let v = json!({"target": 0.75, "lang": "en", "furigana": false, "sound": true, "auto_advance": true,
                   "daily_goal": 30, "anki_auto": false, "focus_gp": null, "daily_auto": true,
                   "anki_reviews": false});
    v.as_object().unwrap().clone()
}

fn xp_for_level(level: i64) -> i64 {
    round_i(100.0 * crate::pymath::pow((level - 1) as f64, 1.6))
}

fn level_for_xp(xp: i64) -> i64 {
    let mut lv = 1;
    while xp_for_level(lv + 1) <= xp {
        lv += 1;
    }
    lv
}

fn rank_for(theta: f64) -> &'static str {
    let mut name = RANKS[0].1;
    for (th, n) in RANKS {
        if theta >= th {
            name = n;
        }
    }
    name
}

/// Python truthiness of a JSON value.
pub fn truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().is_some_and(|x| x != 0.0),
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
    }
}

/// `a or b` on JSON values.
fn or(a: Option<&Value>, b: Value) -> Value {
    match a {
        Some(v) if truthy(v) => v.clone(),
        _ => b,
    }
}

fn get<'a>(m: &'a Value, k: &str) -> Option<&'a Value> {
    m.get(k)
}

fn get_or(m: &Value, k: &str, d: Value) -> Value {
    m.get(k).cloned().unwrap_or(d)
}

/// str() of a JSON value inside an f-string.
fn py_str(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Null => "None".into(),
        Value::Bool(b) => if *b { "True" } else { "False" }.into(),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                i.to_string()
            } else {
                crate::pyjson::float_repr(n.as_f64().unwrap_or(0.0))
            }
        }
        other => dumps(other, false),
    }
}

fn as_str(v: Option<&Value>) -> String {
    v.map(py_str).unwrap_or_default()
}

/// s[:n] in code points.
fn head(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

#[derive(Clone, Debug)]
pub struct Item {
    pub id: i64,
    pub key: String,
    pub kind: String,
    pub level: i64,
    pub kc: String,
    pub tags: Vec<String>,
    pub cat: String,
    pub seed: f64,
    pub sid: Option<i64>,
    pub flags: i64,
    pub gps: Vec<String>,
}

#[derive(Clone, Debug)]
struct Grammar {
    id: String,
    level: i64,
    ord: i64,
    name: String,
    en: String,
    ru: String,
    explain_en: String,
    explain_ru: String,
    diff: f64,
}

#[derive(Clone)]
enum Correct {
    Idx(i64),
    Joined(String),
}

/// A question made from a due Anki card (see review.rs).
struct AnkiQ {
    card: anki::ReviewCard,
    kind: &'static str,
    explain: String,
    full: String,
    en: String,
    words: Value,
    budget: i64,
}

struct Current {
    qid: i64,
    /// an index into `items`; meaningless when `anki` is set
    item: usize,
    anki: Option<Box<AnkiQ>>,
    payload: Value,
    correct: Correct,
    p: f64,
    target: f64,
    why: String,
}

struct Recent {
    item: String,
    kind: String,
    kc: String,
    sid: Option<i64>,
}

pub struct Engine {
    pub now: Box<dyn Fn() -> f64>,
    rng: PyRandom,
    cdb: Connection,
    pdb: Connection,
    items: Vec<Item>,
    by_key: HashMap<String, usize>,
    by_kc: IndexMap<String, Vec<usize>>,
    kc_label: HashMap<String, (String, String)>,
    grammar: IndexMap<String, Grammar>,
    gp_items: HashMap<String, i64>,
    model: Model,
    cards: IndexMap<String, Card>,
    card_item: HashMap<String, Option<String>>,
    unlocked: HashSet<String>,
    settings: Map<String, Value>,
    game: Map<String, Value>,
    recent: VecDeque<Recent>,
    seen_items: HashSet<String>,
    history: VecDeque<String>,
    kc_misses: HashMap<String, i64>,
    anki_added: HashSet<String>,
    gp_answers: HashMap<String, i64>,
    gp_correct: HashMap<String, i64>,
    pool_by_kind: IndexMap<String, Vec<usize>>,
    current: Option<Current>,
    last_answered: Option<(usize, Value)>,
    intro_queue: VecDeque<Value>,
    outbox: Outbox,
    rank_ix: rank::Index,
    anki_words: rank::AnkiWords,
    calib: Option<rank::Calib>,
    calib_est: [[f64; 4]; 6],
    reviews: Reviews,
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS comp(key TEXT PRIMARY KEY, mu REAL, var REAL, n INTEGER, t REAL);
CREATE TABLE IF NOT EXISTS card(kc TEXT PRIMARY KEY, s REAL, d REAL, last REAL, reps INTEGER, lapses INTEGER,
                                state TEXT, due REAL, short_due REAL, last_q INTEGER, last_item TEXT);
CREATE TABLE IF NOT EXISTS answers(id INTEGER PRIMARY KEY, ts REAL, item TEXT, kind TEXT, kc TEXT, cat TEXT,
                                   level INTEGER, correct INTEGER, ms INTEGER, p REAL, target REAL, points INTEGER,
                                   mode TEXT, snap TEXT);
CREATE TABLE IF NOT EXISTS unlock(key TEXT PRIMARY KEY, ts REAL, how TEXT);
CREATE TABLE IF NOT EXISTS days(day TEXT PRIMARY KEY, n INTEGER, correct INTEGER, xp INTEGER);
CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT);
";

type R<T> = Result<T, String>;

fn e<E: std::fmt::Display>(x: E) -> String {
    x.to_string()
}

impl Engine {
    pub fn new(content_path: &str, progress_path: &str, now: Box<dyn Fn() -> f64>, seed: Option<u128>) -> R<Engine> {
        let cdb = Connection::open_with_flags(
            format!("file:{content_path}?mode=ro"),
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
        )
        .map_err(e)?;
        let pdb = Connection::open(progress_path).map_err(e)?;
        pdb.execute_batch(SCHEMA).map_err(e)?;
        let data_dir = std::path::Path::new(progress_path).parent().map(|p| p.to_path_buf()).unwrap_or_default();
        let mut eng = Engine {
            now,
            rng: seed.map(PyRandom::new).unwrap_or_else(PyRandom::from_os),
            cdb,
            pdb,
            items: vec![],
            by_key: HashMap::new(),
            by_kc: IndexMap::new(),
            kc_label: HashMap::new(),
            grammar: IndexMap::new(),
            gp_items: HashMap::new(),
            model: Model::default(),
            cards: IndexMap::new(),
            card_item: HashMap::new(),
            unlocked: HashSet::new(),
            settings: Map::new(),
            game: Map::new(),
            recent: VecDeque::new(),
            seen_items: HashSet::new(),
            history: VecDeque::new(),
            kc_misses: HashMap::new(),
            anki_added: HashSet::new(),
            gp_answers: HashMap::new(),
            gp_correct: HashMap::new(),
            pool_by_kind: IndexMap::new(),
            current: None,
            last_answered: None,
            intro_queue: VecDeque::new(),
            outbox: Outbox::new(&data_dir),
            rank_ix: rank::Index::default(),
            calib: None,
            calib_est: [[0.0; 4]; 6],
            anki_words: rank::AnkiWords::default(),
            reviews: Reviews::default(),
        };
        eng.load_content()?;
        eng.load_progress()?;
        Ok(eng)
    }

    // ------------------------------------------------------------------ loading
    fn load_content(&mut self) -> R<()> {
        let mut st = self.cdb.prepare("SELECT id,key,kind,level,kc,tags,cat,seed,sid,flags FROM items").map_err(e)?;
        let rows = st
            .query_map([], |r| {
                let tags: String = r.get(5)?;
                Ok(Item {
                    id: r.get(0)?,
                    key: r.get(1)?,
                    kind: r.get(2)?,
                    level: r.get(3)?,
                    kc: r.get(4)?,
                    tags: serde_json::from_str::<Vec<String>>(&tags).unwrap_or_default(),
                    cat: r.get(6)?,
                    seed: r.get(7)?,
                    sid: r.get(8)?,
                    flags: r.get(9)?,
                    gps: vec![],
                })
            })
            .map_err(e)?;
        for it in rows {
            let mut it = it.map_err(e)?;
            it.gps = it.tags.iter().filter_map(|t| t.strip_prefix("gp:").map(String::from)).collect();
            self.items.push(it);
        }
        drop(st);
        for (i, it) in self.items.iter().enumerate() {
            self.by_key.insert(it.key.clone(), i);
            self.by_kc.entry(it.kc.clone()).or_default().push(i);
            for g in &it.gps {
                *self.gp_items.entry(g.clone()).or_default() += 1;
            }
        }
        let mut st = self.cdb.prepare("SELECT kc,label,label_ru FROM kcs").map_err(e)?;
        let labels = st
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, Option<String>>(2)?)))
            .map_err(e)?;
        for l in labels {
            let (kc, a, b) = l.map_err(e)?;
            self.kc_label.insert(kc, (a.unwrap_or_default(), b.unwrap_or_default()));
        }
        drop(st);
        let mut st = self.cdb.prepare("SELECT id,level,ord,name,en,ru,explain_en,explain_ru,diff FROM grammar ORDER BY ord").map_err(e)?;
        let gs = st
            .query_map([], |r| {
                Ok(Grammar {
                    id: r.get(0)?,
                    level: r.get(1)?,
                    ord: r.get(2)?,
                    name: r.get(3)?,
                    en: r.get(4)?,
                    ru: r.get(5)?,
                    explain_en: r.get(6)?,
                    explain_ru: r.get(7)?,
                    diff: r.get(8)?,
                })
            })
            .map_err(e)?;
        for g in gs {
            let g = g.map_err(e)?;
            self.grammar.insert(g.id.clone(), g);
        }
        drop(st);
        let kcs: Vec<&String> = self.by_kc.keys().collect();
        let tags: HashSet<&str> = self.items.iter().flat_map(|it| it.tags.iter().map(String::as_str)).collect();
        self.rank_ix = rank::Index::build(&kcs, &tags);
        Ok(())
    }

    fn kv(&self) -> HashMap<String, String> {
        let mut st = self.pdb.prepare("SELECT key,value FROM kv").unwrap();
        st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?.unwrap_or_default())))
            .unwrap()
            .flatten()
            .collect()
    }

    fn load_progress(&mut self) -> R<()> {
        {
            let mut st = self.pdb.prepare("SELECT key,mu,var,n,t FROM comp").map_err(e)?;
            let rows = st
                .query_map([], |r| Ok((r.get::<_, String>(0)?, Comp { mu: r.get(1)?, var: r.get(2)?, n: r.get(3)?, t: r.get(4)? })))
                .map_err(e)?;
            for r in rows {
                let (k, c) = r.map_err(e)?;
                self.model.comps.insert(k, c);
            }
            let mut st = self.pdb.prepare("SELECT kc,s,d,last,reps,lapses,state,due,short_due,last_q,last_item FROM card").map_err(e)?;
            let rows = st
                .query_map([], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        Card {
                            s: r.get(1)?,
                            d: r.get(2)?,
                            last: r.get(3)?,
                            reps: r.get(4)?,
                            lapses: r.get(5)?,
                            state: r.get(6)?,
                            due: r.get(7)?,
                            short_due: r.get(8)?,
                            last_q: r.get(9)?,
                        },
                        r.get::<_, Option<String>>(10)?,
                    ))
                })
                .map_err(e)?;
            for r in rows {
                let (kc, c, li) = r.map_err(e)?;
                self.cards.insert(kc.clone(), c);
                self.card_item.insert(kc, li);
            }
            let mut st = self.pdb.prepare("SELECT key FROM unlock").map_err(e)?;
            self.unlocked = st.query_map([], |r| r.get::<_, String>(0)).map_err(e)?.flatten().collect();
        }
        let kv = self.kv();
        self.settings = default_settings();
        if let Ok(Value::Object(m)) = serde_json::from_str::<Value>(kv.get("settings").map(String::as_str).unwrap_or("{}")) {
            for (k, v) in m {
                self.settings.insert(k, v);
            }
        }
        let mut game = json!({"xp": 0, "streak": 0, "best_streak": 0, "qn": 0, "answered": 0, "correct": 0}).as_object().unwrap().clone();
        game.insert("ewma".into(), self.settings["target"].clone());
        game.insert("last_gp_unlock_q".into(), json!(0));
        if let Ok(Value::Object(m)) = serde_json::from_str::<Value>(kv.get("game").map(String::as_str).unwrap_or("{}")) {
            for (k, v) in m {
                game.insert(k, v);
            }
        }
        self.game = game;
        let recent_rows: Vec<(String, String, String)> = {
            let mut st = self.pdb.prepare("SELECT item,kind,kc,correct FROM answers ORDER BY id DESC LIMIT 80").map_err(e)?;
            let mut rows: Vec<(String, String, String)> =
                st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).map_err(e)?.flatten().collect();
            rows.reverse();
            rows
        };
        for (item, kind, kc) in recent_rows {
            let sid = self.by_key.get(&item).and_then(|&i| self.items[i].sid);
            self.push_recent(Recent { item, kind, kc, sid });
        }
        let history_rows: Vec<String> = {
            let mut st = self.pdb.prepare("SELECT DISTINCT item FROM answers").map_err(e)?;
            self.seen_items = st.query_map([], |r| r.get::<_, String>(0)).map_err(e)?.flatten().collect();
            let mut st = self.pdb.prepare("SELECT item FROM answers ORDER BY id DESC LIMIT 40").map_err(e)?;
            let mut rows: Vec<String> = st.query_map([], |r| r.get(0)).map_err(e)?.flatten().collect();
            rows.reverse();
            let mut st = self.pdb.prepare("SELECT kc, COUNT(*) FROM answers WHERE correct=0 GROUP BY kc").map_err(e)?;
            self.kc_misses = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))).map_err(e)?.flatten().collect();
            rows
        };
        for item in history_rows {
            if self.by_key.contains_key(&item) {
                self.push_history(item);
            }
        }
        if let Ok(Value::Array(a)) = serde_json::from_str::<Value>(kv.get("anki_added").map(String::as_str).unwrap_or("[]")) {
            self.anki_added = a.iter().filter_map(|x| x.as_str().map(String::from)).collect();
        }
        self.anki_words = rank::AnkiWords::from_json(kv.get("anki_words").map(String::as_str).unwrap_or("{}"));
        if let Ok(Value::Array(a)) = serde_json::from_str::<Value>(kv.get("anki_pending").map(String::as_str).unwrap_or("[]")) {
            self.reviews.pending = a.iter().filter_map(|x| Some((x.get(0)?.as_i64()?, x.get(1)?.as_i64()?))).collect();
        }
        self.load_calib();
        if !self.game.contains_key("shown") {
            self.seed_shown()?;
        }
        {
            let mut st = self.pdb.prepare("SELECT item, correct FROM answers").map_err(e)?;
            let rows: Vec<(String, i64)> = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?))).map_err(e)?.flatten().collect();
            for (item, correct) in rows {
                if let Some(&i) = self.by_key.get(&item) {
                    for g in &self.items[i].gps {
                        *self.gp_answers.entry(g.clone()).or_default() += 1;
                        *self.gp_correct.entry(g.clone()).or_default() += correct;
                    }
                }
            }
        }
        if self.unlocked.is_empty() {
            let now = (self.now)();
            for cat in CATS {
                self.unlock(&format!("band:{cat}:5"), now, "start");
            }
            let first: Vec<String> = self.grammar.values().filter(|g| g.level == 5 && g.ord <= 7).map(|g| g.id.clone()).collect();
            for g in first {
                self.unlock(&format!("gp:{g}"), now, "start");
            }
        }
        self.rebuild_pools();
        Ok(())
    }

    fn push_recent(&mut self, r: Recent) {
        if self.recent.len() == 80 {
            self.recent.pop_front();
        }
        self.recent.push_back(r);
    }

    fn push_history(&mut self, k: String) {
        if self.history.len() == 40 {
            self.history.pop_front();
        }
        self.history.push_back(k);
    }

    // ------------------------------------------------------------------ helpers
    fn gi(&self, k: &str) -> i64 {
        self.game.get(k).and_then(Value::as_i64).unwrap_or(0)
    }

    fn unlock(&mut self, key: &str, now: f64, how: &str) {
        self.unlocked.insert(key.to_string());
        let _ = self.pdb.execute("INSERT OR IGNORE INTO unlock VALUES (?,?,?)", params![key, now, how]);
    }

    fn eligible(&self, it: &Item) -> bool {
        if !self.unlocked.contains(&format!("band:{}:{}", it.cat, it.level)) {
            return false;
        }
        it.gps.iter().all(|g| !self.grammar.contains_key(g) || self.unlocked.contains(&format!("gp:{g}")))
    }

    fn rebuild_pools(&mut self) {
        let mut pools: IndexMap<String, Vec<usize>> = IndexMap::new();
        for (i, it) in self.items.iter().enumerate() {
            if self.eligible(it) {
                pools.entry(it.kind.clone()).or_default().push(i);
            }
        }
        self.pool_by_kind = pools;
    }

    fn in_placement(&self) -> bool {
        self.game.get("placement_done").is_none_or(Value::is_null) && self.gi("answered") < PLACEMENT_N
    }

    fn target(&self) -> f64 {
        let t = self.settings["target"].as_f64().unwrap_or(0.75);
        if self.in_placement() {
            return 0.6;
        }
        let adj = 0.8 * (t - self.game["ewma"].as_f64().unwrap_or(t));
        (t + adj).max(t - 0.12).min(0.93f64.min(t + 0.12))
    }

    fn predict(&self, i: usize, now: f64) -> (f64, Terms) {
        let it = &self.items[i];
        let terms = Model::design(&it.cat, &it.kind, &it.tags, &it.key);
        let shift = memory_shift(self.cards.get(&it.kc), now, &it.kc);
        let p = self.model.predict(&terms, it.seed, guess(&it.kind), shift);
        (p, terms)
    }

    fn focus(&self) -> Option<String> {
        match self.settings.get("focus_gp") {
            Some(Value::String(g)) if self.grammar.contains_key(g) && !self.in_placement() => Some(g.clone()),
            _ => None,
        }
    }

    fn budget(&self, i: usize, payload: &Value) -> i64 {
        let s = or(get(payload, "full"), or(get(payload, "fixed"), json!("")));
        let n = match &s {
            Value::String(x) => x.chars().count(),
            Value::Array(a) => a.len(),
            _ => 0,
        };
        round_i(budget_base(&self.items[i].kind) + 0.35 * n as f64)
    }

    // ------------------------------------------------------------------ selection
    fn candidates(&mut self, now: f64) -> IndexMap<String, (usize, &'static str)> {
        let qn = self.gi("qn");
        let mut out: IndexMap<String, (usize, &'static str)> = IndexMap::new();
        if self.in_placement() {
            let allk: Vec<usize> = (0..self.items.len()).filter(|&i| PLACEMENT_KINDS.contains(&self.items[i].kind.as_str())).collect();
            let k = allk.len().min(240);
            for i in self.rng.sample(&allk, k) {
                out.insert(self.items[i].key.clone(), (i, "place"));
            }
            return out;
        }
        if let Some(focus) = self.focus() {
            let ok = |it: &Item| {
                it.gps.iter().all(|g| *g == focus || !self.grammar.contains_key(g) || self.unlocked.contains(&format!("gp:{g}")))
            };
            let items: Vec<usize> = (0..self.items.len()).filter(|&i| self.items[i].gps.contains(&focus) && ok(&self.items[i])).collect();
            let k = items.len().min(160);
            for i in self.rng.sample(&items, k) {
                out.insert(self.items[i].key.clone(), (i, "focus"));
            }
            if out.len() >= 4 {
                return out;
            }
        }
        // relearning cards
        let relearn: Vec<(String, i64)> = self
            .cards
            .iter()
            .filter(|(_, c)| c.state == "relearning" && (now >= c.short_due || qn - c.last_q >= 7) && qn - c.last_q >= 3)
            .map(|(kc, c)| (kc.clone(), c.last_q))
            .collect();
        for (kc, last_q) in relearn {
            let items: Vec<usize> = self.by_kc.get(&kc).map(|v| v.iter().copied().filter(|&i| self.eligible(&self.items[i])).collect()).unwrap_or_default();
            if let Some(Some(failed)) = self.card_item.get(&kc) {
                if let Some(&fi) = self.by_key.get(failed) {
                    if qn - last_q >= 6 {
                        out.insert(failed.clone(), (fi, "relearn"));
                    }
                }
            }
            let k = items.len().min(3);
            for i in self.rng.sample(&items, k) {
                out.entry(self.items[i].key.clone()).or_insert((i, "relearn"));
            }
        }
        // due reviews
        let mut due: Vec<(f64, String)> =
            self.cards.iter().filter(|(_, c)| c.state == "review" && c.due <= now).map(|(kc, c)| (c.r(now), kc.clone())).collect();
        due.sort_by(|a, b| a.0.total_cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
        for (_, kc) in due.into_iter().take(24) {
            let items: Vec<usize> = self.by_kc.get(&kc).map(|v| v.iter().copied().filter(|&i| self.eligible(&self.items[i])).collect()).unwrap_or_default();
            let k = items.len().min(2);
            for i in self.rng.sample(&items, k) {
                out.entry(self.items[i].key.clone()).or_insert((i, "due"));
            }
        }
        // fresh practice, stratified by question type
        let kinds: Vec<String> = self.pool_by_kind.iter().filter(|(_, v)| !v.is_empty()).map(|(k, _)| k.clone()).collect();
        if !kinds.is_empty() {
            let weights: Vec<f64> = kinds.iter().map(|k| kind_mix(k)).collect();
            for _ in 0..160 {
                let k = &kinds[self.rng.choices_idx(&weights)];
                let pool = &self.pool_by_kind[k];
                let i = pool[self.rng.choice_idx(pool.len())];
                out.entry(self.items[i].key.clone()).or_insert((i, "fresh"));
            }
        }
        out
    }

    fn score(&mut self, i: usize, why: &str, p: f64, target: f64, now: f64) -> f64 {
        let it = &self.items[i];
        let fit = -crate::pymath::pow(logit(p) - logit(target), 2.0) / (2.0 * crate::pymath::pow(0.55f64, 2.0));
        let mut s = fit;
        let n = self.recent.len();
        let tail = |k: usize| self.recent.iter().skip(n.saturating_sub(k));
        if tail(60).any(|r| r.item == it.key) {
            s -= 4.0;
        }
        if tail(4).any(|r| r.kc == it.kc) {
            s -= 2.5;
        }
        if it.sid.is_some_and(|x| x != 0) && tail(30).any(|r| r.sid == it.sid) {
            s -= 3.0;
        }
        if n >= 1 && self.recent[n - 1].kind == it.kind {
            s -= 0.6;
        }
        if n >= 2 && self.recent[n - 2].kind == it.kind {
            s -= 0.4;
        }
        match why {
            "focus" => {
                s += if !self.seen_items.contains(&it.key) { 0.3 } else { 0.0 };
            }
            "relearn" => s += 2.5,
            "due" => {
                let c = self.cards.get(&it.kc);
                s += 1.0 + c.map_or(0.0, |c| 1.5f64.min((0.9 - c.r(now)) * 5.0));
            }
            "fresh" => {
                let c = self.cards.get(&it.kc);
                if let Some(c) = c {
                    if c.state == "review" && c.due > now {
                        s -= 0.7;
                    }
                }
                if !self.seen_items.contains(&it.key) {
                    s += 0.2;
                }
                let learning = self.cards.values().filter(|c| c.state == "relearning").count();
                if c.is_none() && learning > 12 {
                    s -= 1.5;
                }
                // a word of everyday Japanese you haven't met yet: about one in every six questions, even
                // while reviews are due (more once they are done)
                if c.is_none() && (it.key.starts_with("ev:") || it.key.starts_with("er:")) {
                    let recent_new = self.recent.iter().rev().take(5).any(|r| r.item.starts_with("ev:") || r.item.starts_with("er:"));
                    s += if recent_new { 0.3 } else { EVERYDAY_NEW };
                }
            }
            _ => {}
        }
        if why != "focus" {
            let tot = crate::pymath::sum(KIND_MIX.iter().map(|(_, w)| *w));
            let want = kind_mix(&it.kind) / tot;
            let share = tail(30).filter(|r| r.kind == it.kind).count() as f64 / 1.max(30.min(n)) as f64;
            s += 1.5 * (-1.0f64).max(1.0f64.min((want - share) / want));
        }
        if it.flags & 1 != 0 {
            s -= 0.3;
        }
        s + self.rng.gauss(0.0, 0.3)
    }

    fn placement_pick(&mut self, cands: &IndexMap<String, (usize, &'static str)>) -> Option<usize> {
        let n = self.recent.len();
        let recent_cats: Vec<String> = self
            .recent
            .iter()
            .skip(n.saturating_sub(2))
            .filter_map(|r| self.by_key.get(&r.item).map(|&i| self.items[i].cat.clone()))
            .collect();
        let (mut best, mut best_s) = (None, -1e9);
        for (_, &(i, _)) in cands {
            let it = &self.items[i];
            if self.seen_items.contains(&it.key) {
                continue;
            }
            let terms = Model::design(&it.cat, &it.kind, &it.tags, &it.key);
            let inf = self.model.info(&terms, it.seed, guess(&it.kind));
            let pen = if recent_cats.contains(&it.cat) { 0.15 } else { 0.0 };
            let s = inf - pen + self.rng.gauss(0.0, 0.02);
            if s > best_s {
                best = Some(i);
                best_s = s;
            }
        }
        best
    }

    pub fn next(&mut self) -> R<Value> {
        if let Some(q) = self.intro_queue.pop_front() {
            return Ok(q);
        }
        let now = (self.now)();
        if let Some(q) = self.anki_question(now)? {
            return Ok(q);
        }
        let target = self.target();
        let cands = self.candidates(now);
        let (it, why) = if self.in_placement() {
            (self.placement_pick(&cands), "place")
        } else {
            let (mut best, mut best_s, mut why) = (None, -1e9, "");
            for (_, &(i, w)) in &cands {
                let (p, _) = self.predict(i, now);
                let sc = self.score(i, w, p, target, now);
                if sc > best_s {
                    best = Some(i);
                    best_s = sc;
                    why = w;
                }
            }
            (best, why)
        };
        let it = it.ok_or("AttributeError: 'NoneType' object has no attribute 'id'")?;
        self.make_question(it, why, target, now)
    }

    fn payload(&self, i: usize) -> R<Value> {
        let s: String = self.cdb.query_row("SELECT payload FROM items WHERE id=?", [self.items[i].id], |r| r.get(0)).map_err(e)?;
        serde_json::from_str(&s).map_err(e)
    }

    fn make_question(&mut self, i: usize, why: &str, target: f64, now: f64) -> R<Value> {
        let payload = self.payload(i)?;
        let (p, _) = self.predict(i, now);
        let qid = self.gi("qn") + 1;
        self.game.insert("qn".into(), json!(qid));
        let it = self.items[i].clone();
        let tag_avg = crate::pymath::sum(it.tags.iter().map(|t| self.model.theta(&format!("tag:{t}")))) / 1.max(it.tags.len()) as f64;
        let skill_tag = it.tags.first().cloned().unwrap_or_else(|| it.kc.clone());
        let mut q = json!({
            "type": "question", "qid": qid, "kind": it.kind, "level": it.level, "cat": it.cat,
            "mode": if why == "place" { "placement" } else { "normal" }, "why": why,
            "new": !self.seen_items.contains(&it.key), "p": f(round_n(p, 3)), "target": f(round_n(target, 3)),
            "budget": self.budget(i, &payload), "focus": self.focus(),
            "kind_name": kind_name(&it.kind), "cat_name": cat_name(&it.cat), "skill": self.tag_label(Some(&skill_tag), &it.kc),
            "your": round_i(to_rating(self.model.skill_theta(Some(&it.cat), None, Some(&it.kind)) + tag_avg)),
            "item_rating": round_i(to_rating(self.model.peek(&format!("item:{}", it.key), Some(it.seed)).0)),
        });
        const HIDE: [&str; 12] = ["explain", "explain_ru", "accept", "src", "others_src", "wrong", "right", "fixed", "others_en", "words", "gloss", "gloss_ru"];
        let mut ui: Map<String, Value> = payload.as_object().cloned().unwrap_or_default();
        ui.retain(|k, _| !HIDE.contains(&k.as_str()));
        let correct;
        if it.kind == "order" {
            let tiles: Vec<Value> = payload["tiles"].as_array().cloned().unwrap_or_default();
            let mut order: Vec<usize> = (0..tiles.len()).collect();
            for _ in 0..10 {
                self.rng.shuffle(&mut order);
                if order.windows(2).any(|w| w[0] > w[1]) {
                    break;
                }
            }
            ui.insert("tiles".into(), Value::Array(order.iter().map(|&k| tiles[k].clone()).collect()));
            correct = Correct::Joined(tiles.iter().map(py_str).collect());
        } else {
            let choices: Vec<Value> = payload["choices"].as_array().cloned().unwrap_or_default();
            let mut order: Vec<usize> = (0..choices.len()).collect();
            self.rng.shuffle(&mut order);
            ui.insert("choices".into(), Value::Array(order.iter().map(|&k| choices[k].clone()).collect()));
            if let Some(ru) = payload.get("choices_ru").and_then(Value::as_array) {
                ui.insert("choices_ru".into(), Value::Array(order.iter().map(|&k| ru.get(k).cloned().unwrap_or(Value::Null)).collect()));
            }
            correct = Correct::Idx(order.iter().position(|&k| k == 0).unwrap_or(0) as i64);
        }
        q["ui"] = Value::Object(ui);
        self.current = Some(Current { qid, item: i, anki: None, payload, correct, p, target, why: why.to_string() });
        Ok(q)
    }

    // ------------------------------------------------------------------ answering
    pub fn peek(&self) -> Value {
        match &self.current {
            None => json!({"type": "peek", "correct": null}),
            Some(cur) => {
                if cur.anki.is_none() && self.items[cur.item].kind == "order" {
                    json!({"type": "peek", "correct": cur.payload["tiles"], "order": true})
                } else {
                    let c = match &cur.correct {
                        Correct::Idx(i) => json!(i),
                        Correct::Joined(s) => json!(s),
                    };
                    json!({"type": "peek", "correct": c})
                }
            }
        }
    }

    pub fn answer(&mut self, qid: i64, choice: Option<&Value>, order: Option<&Value>, skip: bool, ms: i64) -> R<Value> {
        match &self.current {
            Some(c) if c.qid == qid => {}
            _ => return Ok(json!({"type": "error", "error": "stale question"})),
        }
        let cur = self.current.take().unwrap();
        if cur.anki.is_some() {
            return self.answer_anki(cur, choice, skip, ms);
        }
        let i = cur.item;
        let it = self.items[i].clone();
        let payload = cur.payload.clone();
        let now = (self.now)();
        let correct = if skip {
            false
        } else if it.kind == "order" {
            match (order, &cur.correct) {
                (Some(Value::Array(parts)), Correct::Joined(want)) => {
                    let mut s = String::new();
                    for p in parts {
                        match p {
                            Value::String(x) => s.push_str(x),
                            _ => return Err("TypeError: sequence item: expected str instance".into()),
                        }
                    }
                    &s == want
                }
                (Some(Value::Null) | None, _) => false,
                _ => return Err("TypeError: can only join an iterable".into()),
            }
        } else {
            match choice {
                None | Some(Value::Null) => false,
                Some(v) => {
                    let c = py_int(v)?;
                    matches!(cur.correct, Correct::Idx(k) if k == c)
                }
            }
        };
        let y: i64 = if correct { 1 } else { 0 };
        let secs = (ms as f64 / 1000.0).max(0.0);
        // ---- ratings
        let cat_before: Vec<f64> = CATS.iter().map(|c| self.model.rating(Some(c), None, None)).collect();
        let terms = Model::design(&it.cat, &it.kind, &it.tags, &it.key);
        let shift = memory_shift(self.cards.get(&it.kc), now, &it.kc);
        let p = cur.p;
        self.model.update(&terms, it.seed, guess(&it.kind), y, now, shift);
        let cat_after: Vec<f64> = CATS.iter().map(|c| self.model.rating(Some(c), None, None)).collect();
        let g_after = self.model.rating(None, None, None);
        // ---- memory
        let budget = self.budget(i, &payload);
        let overtime = secs > budget as f64 + 0.5;
        let mut grade = if !skip { grade_from(correct, secs, fast(&it.kind)) } else { 1 };
        if correct && overtime {
            grade = 2;
        }
        let qn = self.gi("qn");
        let tier_before = self.tier_key();
        review(self.cards.entry(it.kc.clone()).or_default(), grade, now, qn);
        self.card_item.insert(it.kc.clone(), Some(it.key.clone()));
        // ---- game
        let answered = self.gi("answered") + 1;
        self.game.insert("answered".into(), json!(answered));
        let ewma = 0.9 * self.game["ewma"].as_f64().unwrap_or(0.0) + 0.1 * y as f64;
        self.game.insert("ewma".into(), f(ewma));
        let level_before = level_for_xp(self.gi("xp"));
        let rank_before = rank_for(self.model.skill_theta(None, None, None));
        let mut points = 0i64;
        let combo;
        if correct {
            let streak = self.gi("streak") + 1;
            self.game.insert("streak".into(), json!(streak));
            self.game.insert("correct".into(), json!(self.gi("correct") + 1));
            self.game.insert("best_streak".into(), json!(self.gi("best_streak").max(streak)));
            combo = 3.0f64.min(1.0 + 0.25 * (streak - 1).div_euclid(3) as f64);
            points = round_i((15.0 + 30.0 * (1.0 - p)) * combo * if overtime { OVERTIME_XP } else { 1.0 });
            self.game.insert("xp".into(), json!(self.gi("xp") + points));
        } else {
            combo = 1.0;
            self.game.insert("streak".into(), json!(0));
        }
        let time_bonus = 0.0;
        for gp in &it.gps {
            *self.gp_answers.entry(gp.clone()).or_default() += 1;
            *self.gp_correct.entry(gp.clone()).or_default() += y;
        }
        let day = clock::date_str(now);
        self.pdb
            .execute(
                "INSERT INTO days VALUES (?,1,?,?) ON CONFLICT(day) DO UPDATE SET n=n+1, correct=correct+?, xp=xp+?",
                params![day, y, points, y, points],
            )
            .map_err(e)?;
        let mut events: Vec<Value> = vec![];
        let level_after = level_for_xp(self.gi("xp"));
        if level_after > level_before {
            events.push(json!({"type": "levelup", "level": level_after}));
        }
        let mode = if cur.why == "place" { "placement" } else { "normal" };
        let (shown_before, shown_after) = self.update_shown(g_after, now, mode == "placement");
        let bulk = mode == "placement" && answered >= PLACEMENT_N;
        if bulk {
            self.game.insert("placement_done".into(), f(now));
            events.push(self.placement_summary());
        }
        events.extend(self.check_unlocks(now, bulk));
        let th = self.model.skill_theta(None, None, None);
        let rank_after = rank_for(th);
        if rank_after != rank_before && mode != "placement" && th > -99.0 {
            let pos = |n: &str| RANKS.iter().position(|(_, x)| *x == n).unwrap_or(0);
            if pos(rank_after) > pos(rank_before) {
                events.push(json!({"type": "rank", "rank": rank_after}));
            }
        }
        events.extend(self.tier_event(tier_before));
        events.extend(self.reviews.notice.take());
        self.push_recent(Recent { item: it.key.clone(), kind: it.kind.clone(), kc: it.kc.clone(), sid: it.sid });
        self.seen_items.insert(it.key.clone());
        let mut snap = Map::new();
        for (k, c) in CATS.iter().enumerate() {
            snap.insert(c.to_string(), f(round_n(cat_after[k], 1)));
        }
        snap.insert("g".into(), f(round_n(g_after, 1)));
        self.pdb
            .execute(
                "INSERT INTO answers(ts,item,kind,kc,cat,level,correct,ms,p,target,points,mode,snap) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                params![now, it.key, it.kind, it.kc, it.cat, it.level, y, ms, p, cur.target, points, mode, dumps(&Value::Object(snap), true)],
            )
            .map_err(e)?;
        self.save(&terms, &it.kc)?;
        self.last_answered = Some((i, payload.clone()));
        self.push_history(it.key.clone());
        if !correct {
            let m = self.kc_misses.entry(it.kc.clone()).or_default();
            *m += 1;
            let misses = *m;
            if self.settings.get("anki_auto").is_some_and(truthy) && misses >= 2 && !self.anki_added.contains(&it.kc) {
                let r = self.anki_add_last(true, None)?;
                let mut ev = json!({"type": "anki", "auto": true}).as_object().unwrap().clone();
                for (k, v) in r.as_object().unwrap() {
                    ev.insert(k.clone(), v.clone());
                }
                events.push(Value::Object(ev));
            }
        }
        let tag_key = it.tags.first().cloned();
        let cat_idx = CATS.iter().position(|c| *c == it.cat).unwrap_or(0);
        let answer = match &cur.correct {
            Correct::Idx(k) if it.kind != "order" => json!(k),
            _ => payload["tiles"].clone(),
        };
        let en = or(payload.get("en"), if it.kind == "meaning" { payload["choices"][0].clone() } else { Value::Null });
        let ru = or(
            payload.get("ru"),
            if it.kind == "meaning" { or(payload.get("choices_ru"), json!([null]))[0].clone() } else { Value::Null },
        );
        let mut res = json!({
            "type": "result", "qid": qid, "correct": correct, "skipped": skip,
            "answer": answer,
            "explain": get_or(&payload, "explain", json!("")), "explain_ru": get_or(&payload, "explain_ru", json!("")),
            "full": or(payload.get("full"), get_or(&payload, "fixed", Value::Null)),
            "en": en, "ru": ru,
            "points": points, "combo": f(combo), "streak": self.gi("streak"), "best_streak": self.gi("best_streak"),
            "time_bonus": f(round_n(time_bonus, 2)), "xp": self.gi("xp"), "level": level_after,
            "level_progress": self.level_progress(),
            "rating": {"before": round_i(shown_before), "after": round_i(shown_after), "model": round_i(g_after)},
            "cat": {"name": cat_name(&it.cat), "before": round_i(cat_before[cat_idx]), "after": round_i(cat_after[cat_idx])},
            "skill": {"label": self.tag_label(tag_key.as_deref(), &it.kc),
                      "rating": tag_key.as_ref().map(|t| round_i(self.model.rating(Some(&it.cat), Some(t), None)))},
            "p": f(round_n(p, 3)), "events": events, "today": self.today(), "rank_brief": self.rank_brief(),
            "overtime": overtime, "secs": f(round_n(secs, 1)), "budget": budget,
            "words": get_or(&payload, "words", json!([])), "word": get_or(&payload, "word", Value::Null),
            "gloss": get_or(&payload, "gloss", Value::Null),
            "gloss_ru": get_or(&payload, "gloss_ru", Value::Null), "key": it.key, "in_anki": self.anki_added.contains(&it.kc),
        });
        if it.kind == "odd" {
            res["fixed"] = get_or(&payload, "fixed", Value::Null);
            res["wrong"] = get_or(&payload, "wrong", Value::Null);
            res["right"] = get_or(&payload, "right", Value::Null);
        }
        if it.kind == "produce" {
            res["others_en"] = get_or(&payload, "others_en", Value::Null);
        }
        Ok(res)
    }

    fn placement_summary(&self) -> Value {
        let th = self.model.skill_theta(None, None, None);
        let cats: Vec<Value> =
            CATS.iter().map(|c| json!({"name": cat_name(c), "rating": round_i(self.model.rating(Some(c), None, None))})).collect();
        json!({"type": "placement", "rating": round_i(to_rating(th)), "rank": rank_for(th), "cats": cats})
    }

    fn check_unlocks(&mut self, now: f64, bulk: bool) -> Vec<Value> {
        let mut events = vec![];
        let mut changed = false;
        if self.in_placement() && !bulk {
            return events;
        }
        for cat in CATS {
            let th = self.model.skill_theta(Some(cat), None, None);
            for lv in [4i64, 3] {
                let key = format!("band:{cat}:{lv}");
                if self.unlocked.contains(&key) || !self.unlocked.contains(&format!("band:{cat}:{}", lv + 1)) {
                    continue;
                }
                if th >= level_base(lv) - 0.35 {
                    self.unlock(&key, now, if bulk { "placement" } else { "rating" });
                    events.push(json!({"type": "unlock", "what": "band", "cat": cat, "cat_name": cat_name(cat), "level": lv}));
                    changed = true;
                }
            }
        }
        let th_g = self.model.skill_theta(Some("grammar"), None, None);
        let mut fresh = self
            .grammar
            .keys()
            .filter(|gid| {
                self.unlocked.contains(&format!("gp:{gid}"))
                    && self.gp_items.get(*gid).copied().unwrap_or(0) != 0
                    && self.gp_answers.get(*gid).copied().unwrap_or(0) < 4
            })
            .count();
        let mut intros = 0;
        let mut newly: Vec<Grammar> = vec![];
        let qn = self.gi("qn");
        let mut gs: Vec<Grammar> = self.grammar.values().cloned().collect();
        gs.sort_by_key(|g| g.ord);
        for g in gs {
            let key = format!("gp:{}", g.id);
            if self.unlocked.contains(&key) || !self.unlocked.contains(&format!("band:grammar:{}", g.level)) {
                continue;
            }
            let by_rating = th_g >= level_base(g.level) + g.diff - 0.2;
            let by_trickle = !bulk && !self.in_placement() && fresh < 2 && newly.is_empty() && qn - self.gi("last_gp_unlock_q") >= 12;
            if self.in_placement() && !bulk {
                continue;
            }
            if by_rating || by_trickle {
                self.unlock(&key, now, if bulk { "placement" } else if by_rating { "rating" } else { "next" });
                changed = true;
                self.game.insert("last_gp_unlock_q".into(), json!(qn));
                if !bulk && intros < 2 && self.gp_items.get(&g.id).copied().unwrap_or(0) != 0 {
                    let intro = self.intro(&g);
                    self.intro_queue.push_back(intro);
                    intros += 1;
                    fresh += 1;
                }
                newly.push(g);
            }
        }
        if !newly.is_empty() {
            let items: Vec<Value> = newly.iter().map(|g| json!({"id": g.id, "name": g.name, "en": g.en, "ru": g.ru})).collect();
            events.push(json!({"type": "unlock", "what": "grammar", "bulk": bulk, "items": items}));
        }
        if changed {
            self.rebuild_pools();
        }
        events
    }

    fn intro(&mut self, g: &Grammar) -> Value {
        let cands: Vec<usize> = (0..self.items.len())
            .filter(|&i| self.items[i].gps.contains(&g.id) && ["conj", "gmean", "order", "form", "voice"].contains(&self.items[i].kind.as_str()))
            .collect();
        let mut ex = Value::Null;
        if !cands.is_empty() {
            let i = cands[self.rng.choice_idx(cands.len())];
            if let Ok(pl) = self.payload(i) {
                ex = json!({"ja": get_or(&pl, "full", Value::Null), "en": get_or(&pl, "en", Value::Null), "ru": get_or(&pl, "ru", Value::Null)});
            }
        }
        json!({"type": "intro", "gp": g.id, "name": g.name, "en": g.en, "ru": g.ru,
               "explain_en": g.explain_en, "explain_ru": g.explain_ru, "level": g.level, "example": ex})
    }

    fn save(&mut self, terms: &Terms, kc: &str) -> R<()> {
        let tx = self.pdb.unchecked_transaction().map_err(e)?;
        for (key, _) in terms {
            if let Some(c) = self.model.comps.get(key) {
                tx.execute("INSERT OR REPLACE INTO comp VALUES (?,?,?,?,?)", params![key, c.mu, c.var, c.n, c.t]).map_err(e)?;
            }
        }
        let c = &self.cards[kc];
        tx.execute(
            "INSERT OR REPLACE INTO card VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            params![kc, c.s, c.d, c.last, c.reps, c.lapses, c.state, c.due, c.short_due, c.last_q, self.card_item.get(kc).cloned().flatten()],
        )
        .map_err(e)?;
        tx.execute("INSERT OR REPLACE INTO kv VALUES ('game', ?)", [dumps(&Value::Object(self.game.clone()), true)]).map_err(e)?;
        tx.commit().map_err(e)
    }

    // ------------------------------------------------------------------ info for the UI
    fn tag_label(&self, tag: Option<&str>, kc: &str) -> Value {
        if let Some((a, b)) = self.kc_label.get(kc) {
            if tag.is_none_or(|t| !(t.starts_with("k:") || t.starts_with("w:"))) {
                return json!([a, b]);
            }
        }
        let tag = match tag {
            Some(t) if !t.is_empty() => t,
            _ => return json!([kc, kc]),
        };
        let (fam, rest) = tag.split_once(':').unwrap_or((tag, ""));
        match fam {
            "gp" if self.grammar.contains_key(rest) => {
                let g = &self.grammar[rest];
                json!([format!("{} — {}", g.name, g.en), format!("{} — {}", g.name, g.ru)])
            }
            "pt" => json!([format!("particle {rest}"), format!("частица {rest}")]),
            "k" => json!([format!("kanji {rest}"), format!("кандзи {rest}")]),
            "w" => json!([format!("word {rest}"), format!("слово {rest}")]),
            "conj" => match self.kc_label.get(tag) {
                Some((a, b)) => json!([a, b]),
                None => json!([tag, tag]),
            },
            _ => json!([tag, tag]),
        }
    }

    /// The rating the HUD shows. Matchmaking keeps the honest model; the number you see is protected from
    /// streaky drops: gains count in full, drops at LOSS_DAMP, and it never falls more than FLOOR_GAP below
    /// your best of the last PEAK_DAYS days (a real decline still shows once those peaks expire).
    fn shown_rating(&self) -> f64 {
        self.game.get("shown").and_then(Value::as_f64).unwrap_or_else(|| self.model.rating(None, None, None))
    }

    /// First start with a shown rating: replay the last PEAK_DAYS days of answers, so the protection
    /// covers the history you already have.
    fn seed_shown(&mut self) -> R<()> {
        let since = (self.now)() - PEAK_DAYS as f64 * 86400.0;
        let rows: Vec<(f64, String, String)> = {
            let mut st = self.pdb.prepare("SELECT ts, snap, mode FROM answers WHERE ts >= ? ORDER BY id").map_err(e)?;
            let v: Vec<(f64, String, String)> = st.query_map([since], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).map_err(e)?.flatten().collect();
            v
        };
        if rows.is_empty() {
            return Ok(());
        }
        if let Some(g) = serde_json::from_str::<Value>(&rows[0].1).ok().and_then(|v| v["g"].as_f64()) {
            self.game.insert("shown".into(), f(g));
        }
        for (ts, snap, mode) in rows {
            if let Some(g) = serde_json::from_str::<Value>(&snap).ok().and_then(|v| v["g"].as_f64()) {
                self.update_shown(g, ts, mode == "placement");
            }
        }
        // the latest model value moves on from here; the next answer saves it
        Ok(())
    }

    fn update_shown(&mut self, model_r: f64, now: f64, placement: bool) -> (f64, f64) {
        let before = self.shown_rating();
        // follow the model's change of this answer: every answer moves the number
        let prev_model = self.game.get("shown_model").and_then(Value::as_f64).unwrap_or(model_r);
        let d = model_r - prev_model;
        let mut shown = if placement || model_r >= before {
            model_r
        } else if d >= 0.0 {
            before + d * ABOVE_GAIN // shown is above the model: gains count a bit less, so the gap closes
        } else {
            before + d * LOSS_DAMP
        };
        shown = shown.min(model_r + MAX_ABOVE);
        self.game.insert("shown_model".into(), f(round_n(model_r, 2)));
        let today = clock::Date::of(now);
        let oldest = today.add(-(PEAK_DAYS - 1)).iso();
        let mut peaks = self.game.get("peaks").and_then(Value::as_object).cloned().unwrap_or_default();
        peaks.retain(|d, _| d.as_str() >= oldest.as_str());
        let best = peaks.values().filter_map(Value::as_f64).fold(f64::NEG_INFINITY, f64::max);
        if !placement && best.is_finite() {
            shown = shown.max((best - FLOOR_GAP).min(before));
        }
        let day = today.iso();
        let peak = peaks.get(&day).and_then(Value::as_f64).unwrap_or(f64::NEG_INFINITY).max(shown);
        peaks.insert(day, f(round_n(peak, 1)));
        self.game.insert("peaks".into(), Value::Object(peaks));
        self.game.insert("shown".into(), f(round_n(shown, 2)));
        (before, shown)
    }

    fn level_progress(&self) -> Value {
        let xp = self.gi("xp");
        let lv = level_for_xp(xp);
        let (lo, hi) = (xp_for_level(lv), xp_for_level(lv + 1));
        json!({"level": lv, "xp": xp, "into": xp - lo, "need": hi - lo})
    }

    fn today(&self) -> Value {
        let day = clock::date_str((self.now)());
        let row: Option<(i64, i64, i64)> =
            self.pdb.query_row("SELECT n, correct, xp FROM days WHERE day=?", [day], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).optional().ok().flatten();
        let (n, c, xp) = row.unwrap_or((0, 0, 0));
        json!({"n": n, "correct": c, "xp": xp, "goal": self.daily_goal(), "auto": self.daily_auto(), "streak_days": self.streak_days()})
    }

    fn streak_days(&self) -> i64 {
        let mut st = self.pdb.prepare("SELECT day FROM days WHERE n >= 10").unwrap();
        let days: HashSet<String> = st.query_map([], |r| r.get::<_, String>(0)).unwrap().flatten().collect();
        let mut d = clock::Date::of((self.now)());
        let mut n = 0;
        if !days.contains(&d.iso()) {
            d = d.add(-1);
        }
        while days.contains(&d.iso()) {
            n += 1;
            d = d.add(-1);
        }
        n
    }

    pub fn hello(&self) -> Value {
        let th = self.model.skill_theta(None, None, None);
        let mut cats = Map::new();
        for c in CATS {
            cats.insert(c.into(), json!({"name": cat_name(c), "rating": round_i(self.model.rating(Some(c), None, None))}));
        }
        json!({"type": "hello", "settings": self.settings, "rating": round_i(self.shown_rating()), "rank": rank_for(th),
               "level_progress": self.level_progress(), "streak": self.game["streak"],
               "best_streak": self.game["best_streak"], "today": self.today(),
               "placement": self.in_placement(), "placement_left": 0.max(PLACEMENT_N - self.gi("answered")),
               "answered": self.game["answered"], "cats": cats, "rank_brief": self.rank_brief()})
    }

    pub fn set_settings(&mut self, new: &Value) -> R<Value> {
        let m = new.as_object().ok_or("AttributeError: object has no attribute 'items'")?;
        let defaults = default_settings();
        for (k, v) in m {
            if defaults.contains_key(k) {
                self.settings.insert(k.clone(), v.clone());
            }
        }
        let t = py_float(&self.settings["target"])?;
        self.settings.insert("target".into(), f(0.9f64.min(0.6f64.max(t))));
        let mut fg = self.settings.get("focus_gp").cloned().unwrap_or(Value::Null);
        if m.contains_key("anki_reviews") {
            // switched on (or off and on again): look for due cards right away
            self.reviews.paused_until = 0.0;
            self.reviews.fetched_at = None;
            self.reviews.offline_told = false;
        }
        if !fg.is_null() && !fg.as_str().is_some_and(|g| self.grammar.contains_key(g)) {
            self.settings.insert("focus_gp".into(), Value::Null);
            fg = Value::Null;
        }
        if truthy(&fg) {
            let key = format!("gp:{}", fg.as_str().unwrap_or(""));
            if !self.unlocked.contains(&key) {
                self.unlock(&key, (self.now)(), "drill");
                self.rebuild_pools();
            }
        }
        self.pdb.execute("INSERT OR REPLACE INTO kv VALUES ('settings', ?)", [dumps(&Value::Object(self.settings.clone()), true)]).map_err(e)?;
        Ok(json!({"type": "settings", "settings": self.settings}))
    }

    // ------------------------------------------------------------------ Anki
    fn note_for(&self, i: usize, payload: &Value) -> Value {
        let it = &self.items[i];
        let full = as_str(Some(&or(payload.get("full"), or(payload.get("fixed"), json!("")))));
        let en = as_str(Some(&or(payload.get("en"), if it.kind == "meaning" { payload["choices"][0].clone() } else { json!("") })));
        let expl = as_str(Some(&get_or(payload, "explain", json!(""))));
        let at_blank = |fill: &str| -> String {
            payload
                .get("sent")
                .and_then(Value::as_array)
                .map(|segs| {
                    segs.iter()
                        .map(|sg| if sg.get("blank").is_some_and(truthy) { format!("<b>{fill}</b>") } else { as_str(Some(&get_or(sg, "t", json!("")))) })
                        .collect()
                })
                .unwrap_or_default()
        };
        let mark = |sub: &str| -> String {
            if !sub.is_empty() && full.contains(sub) {
                full.replacen(sub, &format!("<b>{sub}</b>"), 1)
            } else {
                full.clone()
            }
        };
        let (mut word, mut reading, meaning, mut meaning_ru, mut sentence, mut sentence_card);
        (word, reading, meaning_ru, sentence, sentence_card) = (String::new(), String::new(), String::new(), full.clone(), false);
        let choice0 = as_str(payload.get("choices").and_then(|c| c.get(0)));
        match it.kind.as_str() {
            "kread" | "kwrite" => {
                word = as_str(Some(&get_or(payload, "word", json!(""))));
                reading = if it.kind == "kread" { choice0.clone() } else { as_str(Some(&get_or(payload, "reading", json!("")))) };
                meaning = as_str(Some(&get_or(payload, "gloss", json!(""))));
                meaning_ru = as_str(Some(&get_or(payload, "gloss_ru", json!(""))));
                sentence = mark(&word);
            }
            "vocab" => {
                word = as_str(Some(&get_or(payload, "word", json!(""))));
                meaning = as_str(Some(&get_or(payload, "gloss", json!(""))));
                meaning_ru = as_str(Some(&get_or(payload, "gloss_ru", json!(""))));
                sentence = at_blank(&choice0);
            }
            "particle" => {
                word = choice0.clone();
                meaning = expl.clone();
                meaning_ru = as_str(Some(&get_or(payload, "explain_ru", json!(""))));
                sentence = at_blank(&choice0);
                sentence_card = true;
            }
            "conj" | "gmean" | "voice" | "form" | "order" | "odd" => {
                let gid = or(payload.get("gp"), json!(it.gps.first().cloned().unwrap_or_default()));
                let g = gid.as_str().and_then(|x| self.grammar.get(x));
                word = match g {
                    Some(g) => g.name.clone(),
                    None => as_str(Some(&or(payload.get("gp_name"), json!("")))),
                };
                meaning = match g {
                    Some(g) => format!("{}. {}", g.en, g.explain_en),
                    None => expl.clone(),
                };
                meaning_ru = match g {
                    Some(g) => format!("{}. {}", g.ru, g.explain_ru),
                    None => as_str(Some(&get_or(payload, "explain_ru", json!("")))),
                };
                sentence = if it.kind == "order" {
                    let tiles: String = payload["tiles"].as_array().map(|a| a.iter().map(py_str).collect()).unwrap_or_default();
                    mark(&tiles)
                } else if it.kind == "odd" {
                    let right = as_str(payload.get("right"));
                    as_str(payload.get("fixed")).replacen(&right, &format!("<b>{right}</b>"), 1)
                } else {
                    at_blank(&choice0)
                };
                sentence_card = true;
            }
            _ => {
                meaning = en.clone();
                sentence_card = true;
            }
        }
        let ru = as_str(Some(&get_or(payload, "ru", json!(""))));
        let reading_f = if (it.kind == "kread" || it.kind == "kwrite") && !reading.is_empty() {
            format!("{word}[{reading}]")
        } else {
            word.clone()
        };
        let expression = if !sentence_card {
            word.clone()
        } else if !word.is_empty() {
            format!("{word}【{}】", head(&full, 24))
        } else {
            head(&full, 40)
        };
        let mut back = meaning.clone();
        if !meaning_ru.is_empty() && meaning_ru != meaning {
            back += &format!("<br><span style='opacity:.75'>{meaning_ru}</span>");
        }
        if !expl.is_empty() && !meaning.contains(&expl) {
            back += &format!("<br><small>{expl}</small>");
        }
        let src_ja = payload.get("src").and_then(|s| s.get("ja")).map(py_str).unwrap_or_default();
        json!({"deck": anki::deck(), "expression": expression, "word": if !sentence_card { word.clone() } else { String::new() },
               "reading": reading_f, "meaning": back, "sentence": sentence,
               "sentence_translation": en.clone() + &if !ru.is_empty() { format!("<br>{ru}") } else { String::new() },
               "source": format!("jp-quiz · Tatoeba #{src_ja}"),
               "tags": ["jp-quiz", it.kind, format!("N{}", it.level)]})
    }

    pub fn anki_add(&mut self, key: Option<&Value>) -> R<Value> {
        let key = match key {
            None | Some(Value::Null) => return self.anki_add_last(false, None),
            Some(k) => py_str(k),
        };
        let Some(&i) = self.by_key.get(&key) else {
            return Ok(json!({"type": "anki", "status": "nothing", "message": "That question no longer exists."}));
        };
        let pl = self.payload(i)?;
        self.anki_add_last(false, Some((i, pl)))
    }

    fn anki_add_last(&mut self, _auto: bool, item: Option<(usize, Value)>) -> R<Value> {
        let (i, payload) = match item.or_else(|| self.last_answered.clone()) {
            Some(x) => x,
            None => return Ok(json!({"type": "anki", "status": "nothing", "message": "Answer a question first."})),
        };
        let note = self.note_for(i, &payload);
        let r = self.outbox.add(&note);
        let kc = self.items[i].kc.clone();
        self.anki_added.insert(kc);
        let mut sorted: Vec<&String> = self.anki_added.iter().collect();
        sorted.sort();
        self.pdb.execute("INSERT OR REPLACE INTO kv VALUES ('anki_added', ?)", [dumps(&json!(sorted), true)]).map_err(e)?;
        let word = [&note["word"], &note["reading"]].iter().map(|v| as_str(Some(v))).find(|s| !s.is_empty()).unwrap_or_else(|| head(&as_str(Some(&note["expression"])), 16));
        let mut out = json!({"type": "anki", "key": self.items[i].key, "word": word}).as_object().unwrap().clone();
        for (k, v) in r.as_object().unwrap() {
            out.insert(k.clone(), v.clone());
        }
        Ok(Value::Object(out))
    }

    pub fn anki_sync(&mut self) -> R<Value> {
        let data = match anki::read_cards() {
            Ok(d) => d,
            Err(_) => return Ok(json!({"type": "anki_sync", "ok": false, "message": "Anki is not running, so there was nothing to read."})),
        };
        let now = (self.now)();
        let mut word_kcs: HashMap<String, Vec<String>> = HashMap::new();
        for kc in self.by_kc.keys() {
            let (fam, w) = kc.split_once(':').unwrap_or((kc, ""));
            if ["read", "write", "use"].contains(&fam) {
                let v = word_kcs.entry(w.to_string()).or_default();
                if !v.contains(kc) {
                    v.push(kc.clone());
                }
            }
        }
        // every word of the decks, for the Rank tab (it measures against full lists, not only the quiz's words)
        let mut aw = rank::AnkiWords::default();
        for c in &data.cards {
            if anki::classify(c) == "known" {
                aw.known.insert(c.word.clone());
            } else {
                aw.learning.insert(c.word.clone());
            }
        }
        aw.learning.retain(|w| !aw.known.contains(w));
        let mut kn: Vec<&String> = aw.known.iter().collect();
        let mut le: Vec<&String> = aw.learning.iter().collect();
        kn.sort();
        le.sort();
        self.pdb.execute("INSERT OR REPLACE INTO kv VALUES ('anki_words', ?)", [dumps(&json!({"known": kn, "learning": le}), false)]).map_err(e)?;
        self.anki_words = aw;
        let tag_words: HashSet<String> = self.items.iter().flat_map(|it| it.tags.iter().filter_map(|t| t.strip_prefix("w:").map(String::from))).collect();
        let mut best: IndexMap<String, anki::CardInfo> = IndexMap::new();
        for c in &data.cards {
            if !word_kcs.contains_key(&c.word) && !tag_words.contains(&c.word) {
                continue;
            }
            match best.get(&c.word) {
                Some(prev) if (c.lapses, c.interval) <= (prev.lapses, prev.interval) => {}
                _ => {
                    best.insert(c.word.clone(), c.clone());
                }
            }
        }
        let (mut known, mut weak) = (0, 0);
        let mut touched_comps: IndexMap<String, ()> = IndexMap::new();
        let mut touched_kcs: IndexMap<String, ()> = IndexMap::new();
        for (w, c) in &best {
            let verdict = anki::classify(c);
            if verdict == "learning" {
                continue;
            }
            let wkey = format!("tag:w:{w}");
            if verdict == "known" {
                known += 1;
                let comp = self.model.get(&wkey, None);
                comp.mu = comp.mu.max(0.7);
                comp.var = comp.var.min(0.15);
                for ch in w.chars() {
                    if ('\u{4e00}'..='\u{9fff}').contains(&ch) {
                        let k = format!("tag:k:{ch}");
                        let kc_ = self.model.get(&k, None);
                        kc_.mu = kc_.mu.max(0.35);
                        touched_comps.insert(k, ());
                    }
                }
            } else {
                weak += 1;
                let comp = self.model.get(&wkey, None);
                comp.mu = comp.mu.min(-0.3);
            }
            touched_comps.insert(wkey, ());
            for kc in word_kcs.get(w).cloned().unwrap_or_default() {
                let mut card = self.cards.get(&kc).cloned().unwrap_or_default();
                if verdict == "known" {
                    let iv = c.interval;
                    if card.state == "new" || card.s < iv as f64 {
                        card.state = "review".into();
                        card.s = iv.min(365) as f64;
                        card.d = 4.0;
                        card.last = now;
                        card.due = now + iv.min(365) as f64 * DAY;
                        card.reps = card.reps.max(1);
                    }
                } else {
                    card.state = "review".into();
                    card.s = 0.5;
                    card.d = 8.0;
                    card.last = now - DAY;
                    card.due = now - 60.0;
                    card.lapses = card.lapses.max(c.lapses);
                }
                self.cards.insert(kc.clone(), card);
                touched_kcs.insert(kc, ());
            }
        }
        for k in touched_comps.keys() {
            let c = &self.model.comps[k];
            self.pdb.execute("INSERT OR REPLACE INTO comp VALUES (?,?,?,?,?)", params![k, c.mu, c.var, c.n, c.t]).map_err(e)?;
        }
        for kc in touched_kcs.keys() {
            let c = &self.cards[kc];
            self.pdb
                .execute(
                    "INSERT OR REPLACE INTO card VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                    params![kc, c.s, c.d, c.last, c.reps, c.lapses, c.state, c.due, c.short_due, c.last_q, self.card_item.get(kc).cloned().flatten()],
                )
                .map_err(e)?;
        }
        let summary = json!({"ts": f(now), "decks": data.decks, "cards": data.cards.len(), "matched": best.len(), "known": known, "weak": weak});
        self.pdb.execute("INSERT OR REPLACE INTO kv VALUES ('anki_sync', ?)", [dumps(&summary, false)]).map_err(e)?;
        let mut out = json!({"type": "anki_sync", "ok": true}).as_object().unwrap().clone();
        for (k, v) in summary.as_object().unwrap() {
            out.insert(k.clone(), v.clone());
        }
        out.insert(
            "message".into(),
            json!(format!("Read {} cards from {} decks: {known} known, {weak} weak words matched.", data.cards.len(), data.decks.len())),
        );
        Ok(Value::Object(out))
    }

    // ------------------------------------------------------------------ Anki reviews (review.rs)
    fn anki_reviews_on(&self) -> bool {
        self.settings.get("anki_reviews").is_some_and(truthy) && !self.in_placement() && self.focus().is_none()
    }

    /// Every ANKI_EVERY-th question while the setting is on and Anki has due cards: one of them.
    fn anki_question(&mut self, now: f64) -> R<Option<Value>> {
        if !self.anki_reviews_on() {
            return Ok(None);
        }
        self.reviews.turn += 1;
        if self.reviews.turn % review::ANKI_EVERY != 0 || now < self.reviews.paused_until {
            return Ok(None);
        }
        let stale = |t: Option<f64>, age: f64| t.is_none_or(|t| now - t >= age);
        if (self.reviews.pool.is_empty() && stale(self.reviews.fetched_at, review::REFETCH)) || stale(self.reviews.fetched_at, 3.0 * review::REFETCH) {
            self.flush_reviews()?;
            match anki::fetch_due(review::POOL_MAX) {
                Ok(cards) => {
                    self.reviews.set_pool(cards);
                    self.reviews.fetched_at = Some(now);
                    self.reviews.offline_told = false;
                }
                Err(_) => {
                    self.anki_offline(now);
                    return Ok(None);
                }
            }
        }
        while let Some(card) = self.reviews.pool.pop_front() {
            let fakes = self.known_reading_fakes(&card.word);
            // nothing fair to ask (e.g. a grammar card): left to Anki
            let Some(b) = review::build(&card, &self.reviews.bank, &fakes, &mut self.rng) else { continue };
            // reviewed elsewhere since the fetch (Anki itself, the phone)? then it is not ours to answer
            match anki::are_due(&[card.card_id]) {
                Ok(d) if d.first() == Some(&true) => {}
                Ok(_) => continue,
                Err(_) => {
                    self.reviews.pool.push_front(card);
                    self.anki_offline(now);
                    return Ok(None);
                }
            }
            return Ok(Some(self.make_anki_question(card, b)));
        }
        Ok(None)
    }

    fn anki_offline(&mut self, now: f64) {
        self.reviews.paused_until = now + review::OFFLINE_PAUSE;
        if !self.reviews.offline_told {
            self.reviews.offline_told = true;
            self.reviews.notice = Some(json!({"type": "anki_review", "status": "offline", "pending": self.reviews.pending.len()}));
        }
    }

    /// The quiz's own wrong readings for a word (kread items carry hand-checked kana fakes).
    fn known_reading_fakes(&self, word: &str) -> Vec<String> {
        for &i in self.by_kc.get(&format!("read:{word}")).map(Vec::as_slice).unwrap_or(&[]) {
            if self.items[i].kind == "kread" {
                if let Ok(p) = self.payload(i) {
                    let ch: Vec<String> = p["choices"].as_array().map(|a| a.iter().skip(1).filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
                    if !ch.is_empty() {
                        return ch;
                    }
                }
            }
        }
        vec![]
    }

    fn make_anki_question(&mut self, card: anki::ReviewCard, b: review::Built) -> Value {
        let qid = self.gi("qn") + 1;
        self.game.insert("qn".into(), json!(qid));
        let mut order: Vec<usize> = (0..b.choices.len()).collect();
        self.rng.shuffle(&mut order);
        let mut ui = b.ui;
        ui.insert("choices".into(), Value::Array(order.iter().map(|&k| json!(b.choices[k])).collect()));
        let correct = order.iter().position(|&k| k == 0).unwrap_or(0) as i64;
        let budget = round_i(if b.kind == "anki_read" { 22.0 } else { 34.0 } + 0.35 * b.full.chars().count() as f64);
        // the chip shows the deck's leaf name; the header line the whole path
        let deck_path = json!(card.deck.replace("::", " › "));
        let q = json!({
            "type": "question", "qid": qid, "kind": b.kind, "level": null, "cat": "vocab", "mode": "anki", "why": "anki",
            "new": false, "p": null, "target": null, "budget": budget, "focus": null,
            "kind_name": kind_name(b.kind), "cat_name": [deck_path, deck_path], "skill": null, "your": null, "item_rating": null,
            "anki": {"card_id": card.card_id, "deck": card.deck}, "ui": Value::Object(ui),
        });
        let aq = AnkiQ { card, kind: b.kind, explain: b.explain, full: b.full, en: b.en, words: b.words, budget };
        self.current = Some(Current { qid, item: 0, anki: Some(Box::new(aq)), payload: Value::Null, correct: Correct::Idx(correct), p: 0.0, target: 0.0, why: "anki".into() });
        q
    }

    /// Send the queued answers to Anki; true when nothing is left waiting.
    fn flush_reviews(&mut self) -> R<bool> {
        if self.reviews.pending.is_empty() {
            return Ok(true);
        }
        // Anki up but refusing (a deleted card): drop it rather than retry forever
        let sent = anki::answer_cards(&self.reviews.pending).is_ok() || anki::invoke("version", json!({}), 2.0).is_ok();
        if sent {
            // a false entry means Anki no longer has the card; nothing to retry either way
            self.reviews.pending.clear();
        }
        let list: Vec<Value> = self.reviews.pending.iter().map(|(id, ease)| json!([id, ease])).collect();
        self.pdb.execute("INSERT OR REPLACE INTO kv VALUES ('anki_pending', ?)", [dumps(&json!(list), false)]).map_err(e)?;
        Ok(sent)
    }

    fn answer_anki(&mut self, cur: Current, choice: Option<&Value>, skip: bool, ms: i64) -> R<Value> {
        let a = *cur.anki.unwrap();
        let qid = cur.qid;
        let now = (self.now)();
        let right = match cur.correct {
            Correct::Idx(k) => k,
            Correct::Joined(_) => -1,
        };
        let correct = !skip
            && match choice {
                None | Some(Value::Null) => false,
                Some(v) => py_int(v)? == right,
            };
        let secs = (ms as f64 / 1000.0).max(0.0);
        let overtime = secs > a.budget as f64 + 0.5;
        let mut events: Vec<Value> = vec![];
        // ---- Anki: Pass (3) / Fail (1); a skip leaves the card due and sends nothing
        let status = if skip {
            self.reviews.pool.push_back(a.card.clone());
            "skipped"
        } else {
            self.reviews.pending.push((a.card.card_id, if correct { 3 } else { 1 }));
            if self.flush_reviews()? {
                self.reviews.offline_told = false;
                "sent"
            } else {
                self.anki_offline(now);
                "queued"
            }
        };
        // ---- game layer: XP, streak and today's count like any question (no item rating: this is Anki's card)
        let level_before = level_for_xp(self.gi("xp"));
        let (mut points, mut combo) = (0i64, 1.0);
        if correct {
            let streak = self.gi("streak") + 1;
            self.game.insert("streak".into(), json!(streak));
            self.game.insert("best_streak".into(), json!(self.gi("best_streak").max(streak)));
            combo = 3.0f64.min(1.0 + 0.25 * (streak - 1).div_euclid(3) as f64);
            points = round_i(20.0 * combo * if overtime { OVERTIME_XP } else { 1.0 });
            self.game.insert("xp".into(), json!(self.gi("xp") + points));
        } else {
            self.game.insert("streak".into(), json!(0));
        }
        let day = clock::date_str(now);
        if !skip {
            let y = correct as i64;
            self.pdb
                .execute(
                    "INSERT INTO days VALUES (?,1,?,?) ON CONFLICT(day) DO UPDATE SET n=n+1, correct=correct+?, xp=xp+?",
                    params![day, y, points, y, points],
                )
                .map_err(e)?;
            let n = if self.game.get("anki_day").and_then(Value::as_str) == Some(day.as_str()) { self.gi("anki_today") } else { 0 };
            self.game.insert("anki_day".into(), json!(day));
            self.game.insert("anki_today".into(), json!(n + 1));
            // the quiz's own estimate of the word learns from the review too
            let w = &a.card.word;
            let wkey = format!("tag:w:{w}");
            if self.model.comps.contains_key(&wkey) || ["read", "write", "use"].iter().any(|f| self.by_kc.contains_key(&format!("{f}:{w}"))) {
                let c = self.model.get(&wkey, None);
                if correct {
                    if c.mu < 1.5 {
                        c.mu = (c.mu + 0.1).min(1.5);
                    }
                } else {
                    c.mu = (c.mu - 0.2).max(-2.0);
                }
                let c = &self.model.comps[&wkey];
                self.pdb.execute("INSERT OR REPLACE INTO comp VALUES (?,?,?,?,?)", params![wkey, c.mu, c.var, c.n, c.t]).map_err(e)?;
            }
        }
        self.pdb.execute("INSERT OR REPLACE INTO kv VALUES ('game', ?)", [dumps(&Value::Object(self.game.clone()), true)]).map_err(e)?;
        let level_after = level_for_xp(self.gi("xp"));
        if level_after > level_before {
            events.push(json!({"type": "levelup", "level": level_after}));
        }
        events.extend(self.reviews.notice.take());
        let shown = round_i(self.shown_rating());
        let vocab = round_i(self.model.rating(Some("vocab"), None, None));
        Ok(json!({
            "type": "result", "qid": qid, "correct": correct, "skipped": skip, "answer": right,
            "explain": a.explain, "explain_ru": "", "full": a.full, "en": a.en, "ru": null,
            "points": points, "combo": f(combo), "streak": self.gi("streak"), "best_streak": self.gi("best_streak"),
            "time_bonus": f(0.0), "xp": self.gi("xp"), "level": level_after, "level_progress": self.level_progress(),
            "rating": {"before": shown, "after": shown, "model": round_i(self.model.rating(None, None, None))},
            "cat": {"name": cat_name("vocab"), "before": vocab, "after": vocab}, "skill": null,
            "p": null, "events": events, "today": self.today(), "rank_brief": self.rank_brief(),
            "overtime": overtime, "secs": f(round_n(secs, 1)), "budget": a.budget,
            "words": a.words, "word": a.card.word, "gloss": a.card.meaning, "gloss_ru": null, "key": null, "in_anki": true,
            "anki": {"card_id": a.card.card_id, "deck": a.card.deck, "kind": a.kind, "status": status,
                     "ease": if skip { Value::Null } else { json!(if correct { 3 } else { 1 }) }},
        }))
    }

    fn reviews_brief(&self, now: f64) -> Value {
        let today = clock::date_str(now);
        let done = if self.game.get("anki_day").and_then(Value::as_str) == Some(today.as_str()) { self.gi("anki_today") } else { 0 };
        json!({"on": self.settings.get("anki_reviews").is_some_and(truthy), "due": self.reviews.pool.len(),
               "fetched": self.reviews.fetched_at.is_some(), "done_today": done, "pending": self.reviews.pending.len(),
               "paused": now < self.reviews.paused_until})
    }

    // ------------------------------------------------------------------ grammar tab
    pub fn grammar_list(&self) -> Value {
        let now = (self.now)();
        let mut gs: Vec<&Grammar> = self.grammar.values().collect();
        gs.sort_by_key(|g| (-g.level, g.ord));
        let points: Vec<Value> = gs
            .iter()
            .map(|g| {
                let gid = &g.id;
                let comp = self.model.comps.get(&format!("tag:gp:{gid}"));
                let card = self.cards.get(&format!("gp:{gid}"));
                let n = self.gp_answers.get(gid).copied().unwrap_or(0);
                json!({
                    "id": gid, "level": g.level, "name": g.name, "en": g.en, "ru": g.ru,
                    "explain_en": g.explain_en, "explain_ru": g.explain_ru,
                    "unlocked": self.unlocked.contains(&format!("gp:{gid}")), "items": self.gp_items.get(gid).copied().unwrap_or(0),
                    "n": n, "acc": if n != 0 { f(round_n(self.gp_correct.get(gid).copied().unwrap_or(0) as f64 / n as f64, 3)) } else { Value::Null },
                    "rating": if comp.is_some_and(|c| c.n != 0) { json!(round_i(self.model.rating(Some("grammar"), Some(&format!("gp:{gid}")), None))) } else { Value::Null },
                    "sure": comp.is_some_and(|c| c.var < 0.15),
                    "r": match card { Some(c) if c.state != "new" => f(round_n(c.r(now), 2)), _ => Value::Null },
                    "due": card.is_some_and(|c| c.state == "review" && c.due <= now),
                    "lapses": card.map_or(0, |c| c.lapses),
                })
            })
            .collect();
        json!({"type": "grammar", "points": points, "focus": self.focus()})
    }

    pub fn grammar_example(&mut self, gid: &str) -> R<Value> {
        let its: Vec<usize> = (0..self.items.len())
            .filter(|&i| self.items[i].gps.iter().any(|g| g == gid) && ["conj", "gmean", "form", "voice", "order"].contains(&self.items[i].kind.as_str()))
            .collect();
        let k = its.len().min(3);
        let mut ex = vec![];
        for i in self.rng.sample(&its, k) {
            let pl = self.payload(i)?;
            ex.push(json!({"ja": get_or(&pl, "full", Value::Null), "en": get_or(&pl, "en", Value::Null), "ru": get_or(&pl, "ru", Value::Null)}));
        }
        Ok(json!({"type": "grammar_example", "id": gid, "examples": ex}))
    }

    fn recent_answers(&self, n: usize) -> Vec<Value> {
        let mut st = self.pdb.prepare("SELECT item, correct, ts FROM answers ORDER BY id DESC LIMIT ?").unwrap();
        let rows: Vec<(String, i64, f64)> = st.query_map([n as i64 * 2], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap().flatten().collect();
        let (mut out, mut seen) = (vec![], HashSet::new());
        for (key, correct, ts) in rows {
            let Some(&i) = self.by_key.get(&key) else { continue };
            if seen.contains(&key) {
                continue;
            }
            seen.insert(key.clone());
            let it = &self.items[i];
            let pl = self.payload(i).unwrap_or(Value::Null);
            out.push(json!({"key": key, "kind": it.kind, "kind_name": kind_name(&it.kind).unwrap_or(json!([it.kind, it.kind])),
                            "correct": correct != 0, "ts": f(ts), "full": or(pl.get("full"), or(pl.get("fixed"), json!(""))),
                            "en": or(pl.get("en"), if it.kind == "meaning" { pl["choices"][0].clone() } else { json!("") }),
                            "word": or(pl.get("word"), or(pl.get("gp_name"), json!(""))), "in_anki": self.anki_added.contains(&it.kc)}));
            if out.len() >= n {
                break;
            }
        }
        out
    }

    fn more_stats(&self, now: f64) -> Value {
        let mut st = self.pdb.prepare("SELECT ts, kind, level, correct, ms, p, mode FROM answers").unwrap();
        type Row = (f64, String, i64, i64, Option<i64>, Option<f64>);
        let rows: Vec<Row> = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?))).unwrap().flatten().collect();
        let mut by_kind: IndexMap<String, (i64, i64)> = IndexMap::new();
        let mut by_level: IndexMap<i64, (i64, i64)> = [(5, (0, 0)), (4, (0, 0)), (3, (0, 0))].into_iter().collect();
        let mut hours = vec![(0i64, 0i64); 24];
        let mut calib = vec![(0i64, 0.0f64, 0i64); 5];
        let (mut total_ms, mut today_ms) = (0i64, 0i64);
        let day0 = clock::local_midnight(now);
        let mut times: HashMap<String, Vec<f64>> = HashMap::new();
        for (ts, kind, level, correct, ms, p) in &rows {
            let k = by_kind.entry(kind.clone()).or_insert((0, 0));
            k.0 += 1;
            k.1 += correct;
            if let Some(l) = by_level.get_mut(level) {
                l.0 += 1;
                l.1 += correct;
            }
            let h = clock::hour(*ts) as usize;
            hours[h].0 += 1;
            hours[h].1 += correct;
            if let Some(p) = p {
                let b = 4i64.min(0i64.max(((p - 0.2) / 0.16) as i64)) as usize;
                calib[b].0 += 1;
                calib[b].1 += p;
                calib[b].2 += correct;
            }
            let ms_c = ms.unwrap_or(0).max(0).min(120000);
            total_ms += ms_c;
            if *ts >= day0 {
                today_ms += ms_c;
            }
            times.entry(kind.clone()).or_default().push(ms_c as f64 / 1000.0);
        }
        let mut kinds: Vec<Value> = vec![];
        for (kind, (n, c)) in &by_kind {
            let Some(name) = kind_name(kind) else { continue };
            let mut ts_ = times.get(kind).cloned().unwrap_or_default();
            ts_.sort_by(|a, b| a.total_cmp(b));
            kinds.push(json!({"kind": kind, "name": name, "n": n, "acc": f(round_n(*c as f64 / *n as f64, 3)),
                              "median_s": if ts_.is_empty() { Value::Null } else { f(round_n(ts_[ts_.len() / 2], 1)) },
                              "rating": round_i(self.model.rating(None, None, Some(kind))), "active": kind != "odd"}));
        }
        kinds.sort_by_key(|k| -k["n"].as_i64().unwrap_or(0));
        let (mut learning, mut young, mut mature) = (0, 0, 0);
        let mut forecast = [0i64; 7];
        let mut known_words: HashSet<String> = HashSet::new();
        for (kc, c) in &self.cards {
            if c.state == "relearning" {
                learning += 1;
            } else if c.state == "review" {
                if c.s >= 21.0 {
                    mature += 1;
                } else {
                    young += 1;
                }
                let d = ((c.due - day0) / 86400.0).floor() as i64;
                if d < 7 {
                    forecast[0.max(d) as usize] += 1;
                }
                if c.s >= 7.0 && (kc.starts_with("use:") || kc.starts_with("read:") || kc.starts_with("write:")) {
                    known_words.insert(kc.split_once(':').unwrap().1.to_string());
                }
            }
        }
        let mut st = self.pdb.prepare("SELECT day, n, correct FROM days ORDER BY day DESC LIMIT 14").unwrap();
        let mut days: Vec<(String, i64, i64)> = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap().flatten().collect();
        days.reverse();
        let acc = |c: i64, n: i64| if n != 0 { f(round_n(c as f64 / n as f64, 3)) } else { Value::Null };
        json!({
            "kinds": kinds,
            "levels": by_level.iter().map(|(lv, (n, c))| json!({"level": lv, "n": n, "acc": acc(*c, *n)})).collect::<Vec<_>>(),
            "hours": hours.iter().map(|(n, c)| json!({"n": n, "acc": acc(*c, *n)})).collect::<Vec<_>>(),
            "calibration": calib.iter().filter(|x| x.0 != 0).map(|(n, sp, c)| json!({"p": f(round_n(sp / *n as f64, 3)), "acc": f(round_n(*c as f64 / *n as f64, 3)), "n": n})).collect::<Vec<_>>(),
            "time": {"total_min": round_i(total_ms as f64 / 60000.0), "today_min": round_i(today_ms as f64 / 60000.0),
                     "per_q_s": f(round_n(total_ms as f64 / 1000.0 / 1.max(rows.len()) as f64, 1))},
            "cards": {"learning": learning, "young": young, "mature": mature, "words_known": known_words.len()},
            "forecast": forecast,
            "days14": days.iter().map(|(d, n, c)| json!({"day": d, "n": n, "acc": acc(*c, *n)})).collect::<Vec<_>>(),
            "recent": self.recent_answers(14),
        })
    }

    pub fn stats(&self) -> Value {
        let now = (self.now)();
        let mut st = self.pdb.prepare("SELECT id, ts, correct, snap, mode FROM answers ORDER BY id DESC LIMIT 600").unwrap();
        let mut rows: Vec<(i64, String)> = st.query_map([], |r| Ok((r.get(2)?, r.get(3)?))).unwrap().flatten().collect();
        rows.reverse();
        let keys = ["g", "particles", "grammar", "kanji", "vocab", "reading"];
        let mut series: Map<String, Value> = keys.iter().map(|k| (k.to_string(), json!([]))).collect();
        for (_, snap) in &rows {
            let sn: Value = serde_json::from_str(snap).unwrap_or(Value::Null);
            for k in keys {
                if let Some(v) = sn.get(k) {
                    series[k].as_array_mut().unwrap().push(v.clone());
                }
            }
        }
        let acc: Vec<i64> = rows.iter().map(|r| r.0).collect();
        let roll: Vec<Value> = (0..acc.len())
            .map(|i| {
                let w = &acc[i.saturating_sub(19)..=i];
                f(round_n(w.iter().sum::<i64>() as f64 / w.len() as f64, 3))
            })
            .collect();
        let mut cats = Map::new();
        for c in CATS {
            let levels: Vec<i64> = [5, 4, 3].into_iter().filter(|lv| self.unlocked.contains(&format!("band:{c}:{lv}"))).collect();
            cats.insert(c.into(), json!({"name": cat_name(c), "rating": round_i(self.model.rating(Some(c), None, None)),
                                          "n": self.model.comps.get(&format!("cat:{c}")).map_or(0, |x| x.n), "levels": levels}));
        }
        let mut tags: Vec<Value> = vec![];
        for (key, comp) in &self.model.comps {
            if let Some(tag) = key.strip_prefix("tag:") {
                if comp.n >= 2 {
                    let cat = match tag.split(':').next().unwrap_or("") {
                        "pt" => "particles",
                        "gp" | "conj" => "grammar",
                        "k" => "kanji",
                        "w" => "vocab",
                        _ => "reading",
                    };
                    tags.push(json!({"tag": tag, "label": self.tag_label(Some(tag), tag), "n": comp.n,
                                     "rating": round_i(self.model.rating(Some(cat), Some(tag), None)), "sd": round_i(crate::pymath::sqrt(comp.var) * 173.7)}));
                }
            }
        }
        let rating = |t: &Value| t["rating"].as_i64().unwrap_or(0);
        let mut particles: Vec<Value> = tags.iter().filter(|t| t["tag"].as_str().unwrap().starts_with("pt:")).cloned().collect();
        particles.sort_by_key(|t| -rating(t));
        let mut grammar: Vec<Value> =
            tags.iter().filter(|t| { let s = t["tag"].as_str().unwrap(); s.starts_with("gp:") || s.starts_with("conj:") }).cloned().collect();
        grammar.sort_by_key(rating);
        let mut weak: Vec<(f64, Value)> = vec![];
        for (kc, c) in &self.cards {
            if c.reps >= 1 && (c.lapses > 0 || c.r(now) < 0.85) {
                let lab = self.kc_label.get(kc).cloned().unwrap_or((kc.clone(), kc.clone()));
                let r = round_n(c.r(now), 2);
                weak.push((r - 0.15 * c.lapses as f64, json!({"kc": kc, "label": [lab.0, lab.1], "lapses": c.lapses, "reps": c.reps,
                                    "r": f(r), "due_in_h": f(round_n((c.due - now) / 3600.0, 1))})));
            }
        }
        weak.sort_by(|a, b| a.0.total_cmp(&b.0));
        let mut st = self.pdb.prepare("SELECT day, n, correct, xp FROM days ORDER BY day DESC LIMIT 140").unwrap();
        let cal: Vec<Value> = st
            .query_map([], |r| Ok(json!({"day": r.get::<_, String>(0)?, "n": r.get::<_, i64>(1)?, "correct": r.get::<_, i64>(2)?, "xp": r.get::<_, i64>(3)?})))
            .unwrap()
            .flatten()
            .collect();
        let n_due = self.cards.values().filter(|c| c.state == "review" && c.due <= now).count();
        let th = self.model.skill_theta(None, None, None);
        let kv = self.kv();
        let last_sync: Value = serde_json::from_str(kv.get("anki_sync").map(String::as_str).unwrap_or("null")).unwrap_or(Value::Null);
        json!({"type": "stats", "rating": round_i(self.shown_rating()), "model_rating": round_i(to_rating(th)), "rank": rank_for(th), "series": series, "rolling": roll,
               "target": self.settings["target"], "cats": cats,
               "particles": particles.into_iter().take(16).collect::<Vec<_>>(), "grammar": grammar.into_iter().take(14).collect::<Vec<_>>(),
               "weak": weak.into_iter().take(10).map(|w| w.1).collect::<Vec<_>>(), "calendar": cal,
               "totals": {"answered": self.game["answered"], "correct": self.game["correct"], "xp": self.game["xp"],
                          "best_streak": self.game["best_streak"], "cards": self.cards.len(), "due": n_due,
                          "unlocked_gp": self.unlocked.iter().filter(|k| k.starts_with("gp:")).count(),
                          "total_gp": self.grammar.len()},
               "level_progress": self.level_progress(), "today": self.today(), "more": self.more_stats(now),
               "anki": {"queued": self.outbox.pending().len(), "last_sync": last_sync, "reviews": self.reviews_brief(now)}})
    }
}

/// int(x) for a JSON value (int, float, numeric string).
pub fn py_int(v: &Value) -> R<i64> {
    match v {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|x| x.trunc() as i64)).ok_or_else(|| "ValueError".into()),
        Value::String(s) => s.trim().parse::<i64>().map_err(|_| format!("ValueError: invalid literal for int() with base 10: {s:?}")),
        Value::Bool(b) => Ok(*b as i64),
        _ => Err("TypeError: int() argument must be a string or a number".into()),
    }
}

fn py_float(v: &Value) -> R<f64> {
    match v {
        Value::Number(n) => n.as_f64().ok_or_else(|| "ValueError".into()),
        Value::String(s) => s.trim().parse::<f64>().map_err(|_| format!("ValueError: could not convert string to float: {s:?}")),
        Value::Bool(b) => Ok(*b as i64 as f64),
        _ => Err("TypeError: float() argument must be a string or a real number".into()),
    }
}
