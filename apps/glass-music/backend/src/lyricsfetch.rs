//! Lyrics resolver (port of lyricsfetch.py): finds lyrics for songs that have none (or only plain
//! ones), once, in the background. Chain: the song's own lyrics -> Yandex Music (through the
//! signed-in worker) -> LRCLIB -> plain lyrics from any of them. Synced beats plain; nothing is
//! made up. Results go next to the song (<song>.lrc / .txt, marked "[re:Glass Music · <source>]"),
//! never over an existing file (else into the cache).
use crate::http;
use crate::lyrics;
use crate::pyjson;
use crate::pystr;
use regex::Regex;
use serde_json::{json, Map, Value};
use std::collections::{BinaryHeap, HashMap, HashSet};
use std::sync::mpsc::{sync_channel, SyncSender};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::Duration;
use unicode_normalization::UnicodeNormalization;

const UA: &str = "GlassMusic/1.0 (+https://github.com/xDen4ik247/serpantinum)";
const RETRY_MISS: f64 = 14.0 * 86400.0; // nothing found: ask again after two weeks
const RETRY_PLAIN: f64 = 30.0 * 86400.0; // only plain lyrics: look for synced ones again after a month
const YM_TIMEOUT: u64 = 25;

fn lrclib_base() -> String {
    std::env::var("GLASS_MUSIC_LRCLIB").unwrap_or_else(|_| "https://lrclib.net/api".into())
}

struct Res {
    paren: Regex,
    dash: Regex,
    feat: Regex,
    nonword: Regex,
    split: Regex,
}

fn res() -> &'static Res {
    static R: OnceLock<Res> = OnceLock::new();
    R.get_or_init(|| {
        let s = r"[\s\x1c-\x1f]";
        let mut w = String::from("[");
        for (a, b) in crate::pytables::WORD {
            w.push_str(&format!("\\x{{{a:x}}}-\\x{{{b:x}}}"));
        }
        w.push(']');
        let nw = format!("[^{}]+", &w[1..w.len() - 1]);
        Res {
            paren: Regex::new(&format!(r"{s}*[\(\[][^\)\]]*(feat|ft\.|with|prod|remaster|version|edit|live|explicit|bonus)[^\)\]]*[\)\]]")).unwrap(),
            dash: Regex::new(&format!(r"{s}+-{s}+.*(remaster|version|edit|mix|live).*\n?\z")).unwrap(),
            feat: Regex::new(&format!(r"{s}+(feat\.?|ft\.){s}.*\n?\z")).unwrap(),
            nonword: Regex::new(&nw).unwrap(),
            split: Regex::new(&format!(r"{s}*(?:,|&|;|/| x | feat\.? | ft\. | и | and ){s}*")).unwrap(),
        }
    })
}

pub fn norm(s: &str) -> String {
    let r = res();
    let s: String = s.nfkc().collect();
    let s = pystr::lower(&s).replace('ё', "е");
    let s = r.paren.replace_all(&s, "");
    let s = r.dash.replace_all(&s, "");
    let s = r.feat.replace_all(&s, "");
    r.nonword.replace_all(&s, "").into_owned()
}

fn artists(s: &str) -> HashSet<String> {
    res().split.split(&pystr::lower(s)).map(norm).filter(|p| !p.is_empty()).collect()
}

fn vstr(v: &Value) -> String {
    v.as_str().map(String::from).unwrap_or_default()
}

fn truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().is_some_and(|x| x != 0.0),
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
    }
}

/// Is a catalogue hit the same song as meta (title, an artist in common, duration ±3 s)?
pub fn matches(meta: &Value, title: &Value, artist: &Value, duration: &Value) -> bool {
    let nt = norm(&vstr(title));
    if nt != norm(&vstr(&meta["title"])) || nt.is_empty() {
        return false;
    }
    let (a, b) = (artists(&vstr(&meta["artist"])), artists(&vstr(artist)));
    if !a.is_empty() && !b.is_empty() && a.is_disjoint(&b) && norm(&vstr(&meta["artist"])) != norm(&vstr(artist)) {
        return false;
    }
    let d = &meta["duration"];
    !(truthy(d) && truthy(duration) && (duration.as_f64().unwrap_or(0.0) - d.as_f64().unwrap_or(0.0)).abs() > 3.0)
}

fn key(path: &str) -> String {
    sha1_smol::Sha1::from(path.as_bytes()).digest().to_string()[..16].to_string()
}

fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

#[derive(PartialEq, Eq, PartialOrd, Ord)]
struct Job {
    prio: std::cmp::Reverse<(u8, u64)>,
    path: String,
    meta: String,
}

type Found = Box<dyn Fn(&str, Value, bool) + Send + Sync>;

pub struct Resolver {
    dir: String,
    state_path: String,
    pub state: Mutex<Map<String, Value>>,
    on_found: Option<Found>,
    pub ym_send: Option<Box<dyn Fn(Value) + Send + Sync>>,
    log: Box<dyn Fn(&str) + Send + Sync>,
    pub ym_ok: Box<dyn Fn() -> bool + Send + Sync>,
    q: Mutex<(BinaryHeap<Job>, HashSet<String>, Option<String>, u64, bool)>, // heap, queued, busy, n, thread alive
    cv: Condvar,
    ym_waits: Mutex<(u64, HashMap<u64, SyncSender<Option<Value>>>)>,
}

impl Resolver {
    pub fn new(_music_dir: &str, cache_dir: &str, on_found: Option<Found>, ym_send: Option<Box<dyn Fn(Value) + Send + Sync>>, log: Box<dyn Fn(&str) + Send + Sync>) -> Arc<Resolver> {
        let dir = format!("{cache_dir}/lyrics");
        let state_path = format!("{dir}/state.json");
        let state = std::fs::read_to_string(&state_path).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok()).and_then(|v| v.as_object().cloned()).unwrap_or_default();
        Arc::new(Resolver {
            dir,
            state_path,
            state: Mutex::new(state),
            on_found,
            ym_send,
            log,
            ym_ok: Box::new(|| true),
            q: Mutex::new((BinaryHeap::new(), HashSet::new(), None, 0, false)),
            cv: Condvar::new(),
            ym_waits: Mutex::new((0, HashMap::new())),
        })
    }

    // ── state ────────────────────────────────────────────────────────────
    fn save(&self) {
        let _ = std::fs::create_dir_all(&self.dir);
        let tmp = format!("{}.tmp", self.state_path);
        let text = pyjson::dumps(&Value::Object(self.state.lock().unwrap().clone()), false);
        if std::fs::write(&tmp, text).is_ok() {
            let _ = std::fs::rename(&tmp, &self.state_path);
        }
    }

    pub fn rejected(&self, path: &str) -> HashSet<String> {
        let st = self.state.lock().unwrap();
        st.get(path).and_then(|s| s["rej"].as_array()).map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default()
    }

    /// A replacement kept in the cache (song folder read-only, or the user's own file rejected).
    pub fn override_(&self, path: &str) -> String {
        let k = key(path);
        for ext in [".lrc", ".txt"] {
            let p = format!("{}/over/{k}{ext}", self.dir);
            if pystr::exists(&p) {
                return p;
            }
        }
        String::new()
    }

    // ── what the UI shows ────────────────────────────────────────────────
    pub fn load(&self, path: &str) -> Value {
        let skip = self.rejected(path);
        let mut r = lyrics::load_path(path, &skip);
        let ov = self.override_(path);
        if !ov.is_empty() && r["synced"] != true {
            let text = lyrics::read(&ov).unwrap_or_default();
            let (lines, synced) = lyrics::parse_any(&text);
            if !lines.is_empty() && !skip.contains(&lyrics::text_hash(&lines)) && (synced || r["lines"].as_array().is_none_or(|a| a.is_empty())) {
                let h = lyrics::text_hash(&lines);
                r = json!({"lines": lines, "synced": synced, "source": "cache", "origin": lyrics::origin_of(&text), "hash": h});
            }
        }
        let st = self.state.lock().unwrap().get(path).cloned().unwrap_or(json!({}));
        let no_lines = r["lines"].as_array().is_none_or(|a| a.is_empty());
        r["instrumental"] = json!(no_lines && st["res"] == "instrumental");
        let q = self.q.lock().unwrap();
        r["pending"] = json!(q.1.contains(path) || q.2.as_deref() == Some(path));
        r["looked"] = json!(truthy(&st["t"]));
        r
    }

    // ── queueing ─────────────────────────────────────────────────────────
    /// Should a lookup run for this song now? (no synced lyrics, not asked recently)
    pub fn due(&self, path: &str) -> bool {
        if path.is_empty() || !pystr::exists(path) {
            return false;
        }
        let cur = self.load(path);
        if cur["synced"] == true {
            return false;
        }
        let t = self.state.lock().unwrap().get(path).and_then(|s| s["t"].as_f64()).unwrap_or(0.0);
        let age = now() - t;
        age > if cur["lines"].as_array().is_some_and(|a| !a.is_empty()) { RETRY_PLAIN } else { RETRY_MISS }
    }

    /// Queue a lookup (front: the song on screen; force: the user asked).
    pub fn want(self: &Arc<Self>, path: &str, meta: &Value, front: bool, force: bool) -> bool {
        if path.is_empty() || !truthy(meta) || !truthy(&meta["title"]) {
            return false;
        }
        if !force && !self.due(path) {
            return false;
        }
        let mut q = self.q.lock().unwrap();
        if q.1.contains(path) || q.2.as_deref() == Some(path) {
            return true;
        }
        q.3 += 1;
        let n = q.3;
        q.1.insert(path.to_string());
        q.0.push(Job { prio: std::cmp::Reverse((if front { 0 } else { 1 }, n)), path: path.to_string(), meta: meta.to_string() });
        if !q.4 {
            q.4 = true;
            let me = self.clone();
            std::thread::Builder::new().name("lyrics".into()).spawn(move || me.run()).ok();
        }
        self.cv.notify_one();
        true
    }

    /// The shown lyrics are wrong: remember their hash, drop our own copy, look again.
    pub fn reject(self: &Arc<Self>, path: &str, meta: &Value) -> bool {
        let cur = self.load(path);
        let h = cur["hash"].as_str().unwrap_or("").to_string();
        if h.is_empty() {
            return false;
        }
        {
            let mut st = self.state.lock().unwrap();
            let e = st.entry(path.to_string()).or_insert(json!({}));
            let mut rej: Vec<String> = e["rej"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
            rej.push(h.clone());
            rej.sort();
            rej.dedup();
            e["rej"] = json!(rej);
            if let Some(o) = e.as_object_mut() {
                o.shift_remove("t");
            }
        }
        // a file we wrote goes to the cache (recoverable); the user's own files stay untouched
        let stem = pystr::splitext(path).0.to_string();
        for p in [format!("{stem}.lrc"), format!("{stem}.txt"), self.override_(path)] {
            if p.is_empty() || !pystr::exists(&p) {
                continue;
            }
            let text = lyrics::read(&p).unwrap_or_default();
            if lyrics::origin_of(&text).is_empty() {
                continue;
            }
            let (lines, _) = lyrics::parse_any(&text);
            if lyrics::text_hash(&lines) == h {
                let _ = std::fs::create_dir_all(format!("{}/rejected", self.dir));
                let _ = std::fs::rename(&p, format!("{}/rejected/{}-{h}{}", self.dir, key(path), pystr::splitext(&p).1));
            }
        }
        self.save();
        self.want(path, meta, true, true);
        true
    }

    fn run(self: Arc<Self>) {
        loop {
            let job = {
                let mut q = self.q.lock().unwrap();
                if q.0.is_empty() {
                    let (g, _) = self.cv.wait_timeout_while(q, Duration::from_secs(60), |q| q.0.is_empty()).unwrap();
                    q = g;
                }
                match q.0.pop() {
                    None => {
                        q.4 = false; // idle: the thread ends, the next want() starts one
                        return;
                    }
                    Some(j) => {
                        q.1.remove(&j.path);
                        q.2 = Some(j.path.clone());
                        j
                    }
                }
            };
            let meta: Value = serde_json::from_str(&job.meta).unwrap_or(json!({}));
            let changed = match self.resolve(&job.path, &meta) {
                Ok(c) => c,
                Err(e) => {
                    (self.log)(&format!("lyrics lookup failed: {e}"));
                    false
                }
            };
            self.q.lock().unwrap().2 = None;
            if let Some(f) = &self.on_found {
                f(&job.path, self.load(&job.path), changed);
            }
        }
    }

    // ── the chain ────────────────────────────────────────────────────────
    pub fn resolve(&self, path: &str, meta: &Value) -> Result<bool, String> {
        let cur = self.load(path);
        let skip = self.rejected(path);
        let cur_hash = cur["hash"].as_str().unwrap_or("").to_string();
        let cur_lines = cur["lines"].as_array().is_some_and(|a| !a.is_empty());
        self.state.lock().unwrap().entry(path.to_string()).or_insert(json!({}));
        let mut found: Option<(String, String, Option<bool>)> = None;
        // one candidate: false = stop looking
        let take = |src: &str, text: &str, synced: Option<bool>, found: &mut Option<(String, String, Option<bool>)>| -> bool {
            if synced.is_none() {
                if !cur_lines && found.is_none() {
                    *found = Some((src.into(), String::new(), None));
                }
                return false;
            }
            let (lines, really) = lyrics::parse_any(text);
            let h = lyrics::text_hash(&lines);
            if lines.is_empty() || skip.contains(&h) || h == cur_hash {
                return true;
            }
            if really || !(cur_lines || found.is_some()) {
                *found = Some((src.into(), text.into(), Some(really)));
                if really {
                    return false;
                }
            }
            true
        };
        'chain: {
            let mut plain: Vec<(String, String)> = vec![];
            if self.ym_send.is_some() && (self.ym_ok)() {
                let r = self.ask_ym(json!({"cmd": "lyrics", "path": path, "artist": meta.get("artist").cloned().unwrap_or(json!("")),
                                           "title": meta.get("title").cloned().unwrap_or(json!("")), "duration": meta.get("duration").cloned().unwrap_or(json!(0))}));
                if let Some(r) = r {
                    if truthy(&r["lrc"]) && !take("Yandex Music", &vstr(&r["lrc"]), Some(true), &mut found) {
                        break 'chain;
                    }
                    if truthy(&r["text"]) {
                        plain.push(("Yandex Music".into(), vstr(&r["text"])));
                    }
                }
            }
            let hits = self.lrclib(meta)?;
            for h in &hits {
                if truthy(&h["syncedLyrics"]) && !take("LRCLIB", &vstr(&h["syncedLyrics"]), Some(true), &mut found) {
                    break 'chain;
                }
            }
            for h in &hits {
                if truthy(&h["plainLyrics"]) {
                    plain.push(("LRCLIB".into(), vstr(&h["plainLyrics"])));
                }
            }
            for (src, text) in &plain {
                if !take(src, text, Some(false), &mut found) {
                    break 'chain;
                }
            }
            if hits.iter().any(|h| truthy(&h["instrumental"])) {
                take("LRCLIB", "", None, &mut found);
            }
        }
        let mut st = self.state.lock().unwrap();
        let e = st.entry(path.to_string()).or_insert(json!({}));
        e["t"] = json!(now() as i64);
        let Some((src, text, synced)) = found else {
            e["res"] = json!(if cur["synced"] == true { "synced" } else if cur_lines { "plain" } else { "none" });
            drop(st);
            self.save();
            return Ok(false);
        };
        let Some(synced) = synced else {
            e["res"] = json!("instrumental");
            drop(st);
            self.save();
            return Ok(true);
        };
        drop(st);
        self.write(path, &src, &text, synced).map_err(|e| e.to_string())?;
        let mut st = self.state.lock().unwrap();
        let e = st.entry(path.to_string()).or_insert(json!({}));
        e["res"] = json!(if synced { "synced" } else { "plain" });
        e["src"] = json!(src);
        drop(st);
        self.save();
        Ok(true)
    }

    /// <song>.lrc / .txt next to the song when free, else the cache (never overwrite).
    fn write(&self, path: &str, src: &str, text: &str, synced: bool) -> std::io::Result<()> {
        let body = format!("[re:{} · {src}]\n{}\n", lyrics::MARK, pystr::strip(text));
        let ext = if synced { ".lrc" } else { ".txt" };
        let mut target = format!("{}{ext}", pystr::splitext(path).0);
        let dir = pystr::dirname(path);
        let writable = std::ffi::CString::new(if dir.is_empty() { "." } else { dir }).map(|c| unsafe { libc::access(c.as_ptr(), libc::W_OK) } == 0).unwrap_or(false);
        if pystr::exists(&target) || !writable {
            target = format!("{}/over/{}{ext}", self.dir, key(path));
            std::fs::create_dir_all(format!("{}/over", self.dir))?;
            let other = format!("{}/over/{}{}", self.dir, key(path), if synced { ".txt" } else { ".lrc" });
            if synced && pystr::exists(&other) {
                std::fs::remove_file(&other)?; // our cached plain copy is superseded
            }
        }
        let tmp = format!("{target}.part");
        std::fs::write(&tmp, body)?;
        std::fs::rename(&tmp, &target)?;
        (self.log)(&format!("lyrics: {} from {src} -> {}", if synced { "synced" } else { "plain" }, pystr::basename(&target)));
        Ok(())
    }

    // ── sources ──────────────────────────────────────────────────────────
    /// LRCLIB hits for the song: the exact signature first, then search results that match.
    fn lrclib(&self, meta: &Value) -> Result<Vec<Value>, String> {
        let q = vec![("artist_name", vstr(&meta["artist"])), ("track_name", vstr(&meta["title"]))];
        let mut out = vec![];
        if truthy(&meta["album"]) && truthy(&meta["duration"]) {
            let d = meta["duration"].as_f64().unwrap_or(0.0);
            let mut q2 = q.clone();
            q2.push(("album_name", vstr(&meta["album"])));
            q2.push(("duration", pyjson::round_i(d).to_string()));
            if let Some(r) = get(&format!("{}/get?{}", lrclib_base(), http::urlencode(&q2)))? {
                if truthy(&r) {
                    out.push(r);
                }
            }
        }
        let res = get(&format!("{}/search?{}", lrclib_base(), http::urlencode(&q)))?.unwrap_or(json!([]));
        let seen: Vec<Value> = out.iter().map(|r| r.get("id").cloned().unwrap_or(Value::Null)).collect();
        for r in res.as_array().cloned().unwrap_or_default() {
            let id = r.get("id").cloned().unwrap_or(Value::Null);
            if !seen.contains(&id) && matches(meta, r.get("trackName").unwrap_or(&Value::Null), r.get("artistName").unwrap_or(&Value::Null), r.get("duration").unwrap_or(&Value::Null)) {
                out.push(r);
            }
        }
        Ok(out)
    }

    fn ask_ym(&self, mut req: Value) -> Option<Value> {
        let (tx, rx) = sync_channel(1);
        let rid = {
            let mut w = self.ym_waits.lock().unwrap();
            w.0 += 1;
            let rid = w.0;
            w.1.insert(rid, tx);
            rid
        };
        req["rid"] = json!(format!("lyr{rid}"));
        (self.ym_send.as_ref()?)(req);
        let r = rx.recv_timeout(Duration::from_secs(YM_TIMEOUT)).ok().flatten();
        self.ym_waits.lock().unwrap().1.remove(&rid);
        r
    }

    /// A reply from the Yandex worker (ym-lyrics, or ym-error for a lyrics request).
    pub fn on_ym(&self, m: &Value) {
        let rid = match &m["rid"] {
            Value::String(s) => s.clone(),
            Value::Null => String::new(),
            other => other.to_string(),
        };
        let Some(n) = rid.strip_prefix("lyr").and_then(|n| n.parse::<u64>().ok()) else { return };
        if let Some(tx) = self.ym_waits.lock().unwrap().1.get(&n) {
            let _ = tx.try_send(if m["type"] == "ym-lyrics" { Some(m.clone()) } else { None });
        }
    }
}

/// GET + JSON with LRCLIB's retry rules: None for 404.
fn get(url: &str) -> Result<Option<Value>, String> {
    let tries = 3;
    for i in 0..tries {
        match http::get(url, UA, Duration::from_secs(15)) {
            Ok(body) => return serde_json::from_slice(&body).map(Some).map_err(|e| format!("JSONDecodeError: {e}")),
            Err(http::Error::Status(404)) => return Ok(None),
            Err(http::Error::Status(c)) if c < 500 && c != 429 => return Err(format!("HTTPError: HTTP Error {c}")),
            Err(http::Error::Status(_)) => {}
            Err(http::Error::Net(e)) => {
                if i == tries - 1 {
                    return Err(format!("URLError: {e}"));
                }
            }
        }
        std::thread::sleep(Duration::from_secs_f64(1.5 * (i + 1) as f64));
    }
    Err("ConnectionError: LRCLIB unavailable".into())
}

pub fn signed_in() -> bool {
    let base = std::env::var("XDG_CONFIG_HOME").unwrap_or_else(|_| format!("{}/.config", pystr::home()));
    std::fs::read_to_string(format!("{base}/glass-music/yandex.json"))
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .is_some_and(|v| truthy(&v["token"]))
}
