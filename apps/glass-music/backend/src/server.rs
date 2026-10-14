//! glass-music backend (port of server.py): JSON lines on stdin (commands) / stdout (events) for
//! the QML window. The stdin reader and the MPD idle watcher feed one queue; the main loop handles
//! everything serially on a command connection (reconnected on demand: MPD drops idle command
//! clients). Nothing polls: playback state arrives through MPD's `idle`.
use crate::library;
use crate::lyrics;
use crate::lyricsfetch::{self, Resolver};
use crate::mpd::{self, Mpd, Pairs};
use crate::pyjson;
use crate::pystr;
use crate::removal;
use crate::search::Index;
use crate::thumbs::Thumbs;
use serde_json::{json, Map, Value};
use std::collections::{HashMap, VecDeque};
use std::io::{BufRead, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

const FAV: &str = "favourite"; // MPD sticker shared with music-smart

fn home() -> String {
    pystr::home()
}

fn env_or(k: &str, d: String) -> String {
    std::env::var(k).unwrap_or(d)
}

fn cache_dir() -> &'static str {
    static C: OnceLock<String> = OnceLock::new();
    C.get_or_init(|| {
        env_or("GLASS_MUSIC_CACHE", format!("{}/glass-music", env_or("XDG_CACHE_HOME", format!("{}/.cache", home()))))
    })
}

fn history() -> String {
    env_or("GLASS_MUSIC_HISTORY", format!("{}/.local/share/music-smart/history.sqlite", home()))
}

fn smart_state() -> String {
    env_or("GLASS_MUSIC_SMART_STATE", format!("{}/.local/state/music-smart/state.json", home()))
}

/// The app's own settings (~/.config/glass-music/settings.json); only "autoplay" so far.
fn settings_path() -> String {
    env_or("GLASS_MUSIC_SETTINGS", format!("{}/glass-music/settings.json", env_or("XDG_CONFIG_HOME", format!("{}/.config", home()))))
}

fn settings() -> Value {
    std::fs::read_to_string(settings_path()).ok().and_then(|t| serde_json::from_str(&t).ok()).filter(Value::is_object).unwrap_or(json!({}))
}

/// Continuous play: when the queue runs out, My Vibe takes over. On unless switched off.
fn autoplay_on() -> bool {
    settings()["autoplay"] != false
}

fn set_autoplay(on: bool) {
    let mut s = settings();
    s["autoplay"] = json!(on);
    let p = settings_path();
    let _ = std::fs::create_dir_all(pystr::dirname(&p));
    let tmp = format!("{p}.tmp");
    if std::fs::write(&tmp, pyjson::dumps(&s, false) + "\n").is_ok() {
        let _ = std::fs::rename(&tmp, &p);
    }
}

fn smart_active() -> bool {
    std::fs::read_to_string(smart_state()).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok()).is_some_and(|v| truthy(&v["active"]))
}

fn ym_temp() -> String {
    env_or("GLASS_MUSIC_YM_TEMP", format!("{}/yandex-temp", cache_dir()))
}

fn ym_python() -> String {
    env_or("GLASS_MUSIC_YM_PYTHON", format!("{}/.local/share/glass-music/yandex-venv/bin/python", home()))
}

/// Where the glassmusic Python package lives (for the Yandex worker): the window starts us with
/// PYTHONPATH and the working directory set to the app folder.
fn py_root() -> String {
    if let Ok(p) = std::env::var("PYTHONPATH") {
        if let Some(first) = p.split(':').find(|x| !x.is_empty()) {
            return pystr::abspath(first);
        }
    }
    std::env::current_dir().map(|d| d.to_string_lossy().into_owned()).unwrap_or_default()
}

static OUT: Mutex<()> = Mutex::new(());

pub fn emit(obj: &Value) {
    let data = pyjson::dumps_compact(obj, false);
    let _g = OUT.lock().unwrap();
    let mut o = std::io::stdout().lock();
    let _ = o.write_all(data.as_bytes());
    let _ = o.write_all(b"\n");
    let _ = o.flush();
}

fn toast(icon: &str, text: &str) {
    emit(&json!({"type": "toast", "icon": icon, "text": text}));
}

fn strerror(n: i32) -> String {
    unsafe { std::ffi::CStr::from_ptr(libc::strerror(n)).to_string_lossy().into_owned() }
}

/// str(OSError) the way Python shows it
pub fn io_str(e: &std::io::Error) -> String {
    if let Some(n) = e.raw_os_error() {
        return format!("[Errno {n}] {}", strerror(n));
    }
    match e.kind() {
        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut => "timed out".into(),
        _ => e.to_string(),
    }
}

fn err_str(e: &mpd::Error) -> String {
    match e {
        mpd::Error::Io(e) => io_str(e),
        mpd::Error::Ack(s) => s.clone(),
    }
}

/// str(x) for a JSON value the way Python prints it
fn pystr_of(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Null => "None".into(),
        Value::Bool(b) => if *b { "True" } else { "False" }.into(),
        Value::Number(n) => n.as_i64().map(|i| i.to_string()).unwrap_or_else(|| pyjson::float_repr(n.as_f64().unwrap_or(0.0))),
        other => other.to_string(),
    }
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

/// int(x) for a JSON value (None for what Python's int() would refuse)
fn py_int(v: &Value) -> Option<i64> {
    match v {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().filter(|f| f.is_finite()).map(|f| f.trunc() as i64)),
        Value::Bool(b) => Some(*b as i64),
        Value::String(s) => pystr::strip(s).replace('_', "").parse().ok(),
        _ => None,
    }
}

fn py_float(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::Bool(b) => Some(*b as i64 as f64),
        Value::String(s) => pystr::strip(s).replace('_', "").parse().ok(),
        _ => None,
    }
}

/// float(s) / int(s) of an MPD field
fn f_of(s: &str) -> f64 {
    pystr::strip(s).parse().unwrap_or(0.0)
}

fn i_of(s: &str) -> i64 {
    pystr::strip(s).parse().unwrap_or(0)
}

/// dict(pairs): the last value of a key wins
fn last_dict(p: &Pairs) -> HashMap<String, String> {
    p.iter().cloned().collect()
}

/// The command connection (reconnected on demand: MPD drops idle command clients).
pub struct CmdConn {
    address: String,
    pub mpd: Option<Mpd>,
}

impl CmdConn {
    pub fn new(address: &str) -> CmdConn {
        CmdConn { address: address.to_string(), mpd: None }
    }

    pub fn conn(&mut self) -> mpd::Result<&mut Mpd> {
        if self.mpd.as_ref().is_some_and(|m| m.stale()) {
            self.drop_conn(); // MPD timed the idle command connection out: reconnect before sending
        }
        if self.mpd.is_none() {
            self.mpd = Some(Mpd::connect(&self.address)?);
        }
        Ok(self.mpd.as_mut().unwrap())
    }

    pub fn drop_conn(&mut self) {
        if let Some(m) = self.mpd.take() {
            m.shutdown();
        }
    }

    /// fn(mpd) on the command connection, reconnecting once on a connection error. The retry
    /// re-runs fn only if it is safe: a pure read (idempotent), or nothing reached the socket.
    /// A command list like clear+add that was already sent may have run, so it is never sent twice.
    pub fn call<T>(&mut self, idempotent: bool, mut f: impl FnMut(&mut Mpd) -> mpd::Result<T>) -> mpd::Result<T> {
        for attempt in 0..2 {
            let (r, before, after) = match self.conn() {
                Ok(m) => {
                    let before = m.sent;
                    let r = f(m);
                    let after = self.mpd.as_ref().map(|m| m.sent).unwrap_or(before);
                    (r, Some(before), after)
                }
                Err(e) => (Err(e), None, 0),
            };
            match r {
                Err(mpd::Error::Io(e)) => {
                    let sent = before.is_some_and(|b| b != after);
                    self.drop_conn();
                    if attempt == 1 || (sent && !idempotent) {
                        return Err(mpd::Error::Io(e));
                    }
                }
                other => return other,
            }
        }
        unreachable!()
    }
}

pub enum Msg {
    Cmd(Value),
    Event(Vec<String>),
    Home,
    Ym(Value),
    Quit,
}

/// Raised in a handler: MPD / OS trouble ("error") or anything else ("error" + trace)
pub enum Fail {
    Mpd(mpd::Error),
    Other(String),
}

impl From<mpd::Error> for Fail {
    fn from(e: mpd::Error) -> Self {
        Fail::Mpd(e)
    }
}

type R<T> = Result<T, Fail>;

struct Shared {
    music_dir: Mutex<String>,
    lyr_view: Mutex<String>,
    address: String,
    tx: Sender<Msg>,
    ym: Mutex<Option<(Child, ChildStdin)>>,
    lyr: OnceLock<Arc<Resolver>>,
    index_tx: Mutex<Option<Sender<Value>>>,
}

pub struct Server {
    sh: Arc<Shared>,
    rx: Receiver<Msg>,
    cc: CmdConn,
    lib: Option<Value>,
    index: Option<Index>,
    files: HashMap<String, usize>,
    album_of: HashMap<String, Value>,
    last_songid: Option<i64>,
    thumbs: Arc<Thumbs>,
    queue_files: Vec<String>,
    backlog: VecDeque<Msg>,
    ym_play: Option<(Value, i64)>, // the Yandex play job that owns the queue: (job, before)
    ym_next: HashMap<String, i64>, // job -> tracks already inserted after the current one
    lyr_meta: HashMap<String, Value>,
    playing: Option<(Instant, f64, f64)>, // last "play" status: (when, elapsed, duration)
}

impl Server {
    pub fn new() -> Server {
        let (tx, rx) = channel();
        Server {
            sh: Arc::new(Shared {
                music_dir: Mutex::new(std::env::var("GLASS_MUSIC_DIR").unwrap_or_default()),
                lyr_view: Mutex::new(String::new()),
                address: mpd::default_address(),
                tx,
                ym: Mutex::new(None),
                lyr: OnceLock::new(),
                index_tx: Mutex::new(None),
            }),
            rx,
            cc: CmdConn::new(&mpd::default_address()),
            lib: None,
            index: None,
            files: HashMap::new(),
            album_of: HashMap::new(),
            last_songid: None,
            thumbs: Thumbs::new(cache_dir(), Box::new(|v| emit(&v))),
            queue_files: vec![],
            backlog: VecDeque::new(),
            ym_play: None,
            ym_next: HashMap::new(),
            lyr_meta: HashMap::new(),
            playing: None,
        }
    }

    fn music_dir(&self) -> String {
        self.sh.music_dir.lock().unwrap().clone()
    }

    fn call<T>(&mut self, idempotent: bool, f: impl FnMut(&mut Mpd) -> mpd::Result<T>) -> mpd::Result<T> {
        self.cc.call(idempotent, f)
    }

    fn cmd(&mut self, idem: bool, name: &str, args: &[&str]) -> mpd::Result<Pairs> {
        self.call(idem, |m| m.cmd(name, args))
    }

    fn dict(&mut self, name: &str) -> mpd::Result<indexmap::IndexMap<String, String>> {
        self.call(true, |m| m.dict(name, &[]))
    }

    fn batch(&mut self, cmds: Vec<Vec<String>>) -> mpd::Result<Vec<Pairs>> {
        self.call(false, |m| m.batch(&cmds))
    }

    fn idle_thread(sh: Arc<Shared>) {
        let mut backoff = 1;
        loop {
            let r: mpd::Result<()> = (|| {
                let mut m = Mpd::connect(&sh.address)?;
                let _ = sh.tx.send(Msg::Event(vec!["reconnect".into()]));
                backoff = 1;
                loop {
                    let changed = m.idle(&["player", "playlist", "mixer", "options", "database", "stored_playlist", "sticker", "update"])?;
                    let _ = sh.tx.send(Msg::Event(changed));
                }
            })();
            if let Err(e) = r {
                emit(&json!({"type": "mpd", "ok": false, "error": err_str(&e)}));
                std::thread::sleep(Duration::from_secs(backoff));
                backoff = (backoff * 2).min(30);
            }
        }
    }

    fn stdin_thread(tx: Sender<Msg>) {
        let stdin = std::io::stdin();
        let mut buf = vec![];
        let mut lock = stdin.lock();
        loop {
            buf.clear();
            match lock.read_until(b'\n', &mut buf) {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
            let line = String::from_utf8_lossy(&buf);
            let line = pystr::strip(&line);
            if line.is_empty() {
                continue;
            }
            if let Ok(v @ Value::Object(_)) = serde_json::from_str::<Value>(line) {
                let _ = tx.send(Msg::Cmd(v));
            }
        }
        let _ = tx.send(Msg::Quit);
    }

    // ── data senders ─────────────────────────────────────────────────────────
    fn send_library(&mut self, force: bool) -> R<()> {
        let t0 = Instant::now();
        if self.music_dir().is_empty() {
            match self.dict("config") {
                Ok(d) => *self.sh.music_dir.lock().unwrap() = d.get("music_directory").cloned().unwrap_or_default(),
                Err(mpd::Error::Ack(_)) => {}
                Err(e) => return Err(e.into()),
            }
            if self.music_dir().is_empty() {
                *self.sh.music_dir.lock().unwrap() = format!("{}/Music", home());
            }
        }
        let md = self.music_dir();
        let (lib, cached) = self.call(true, |m| library::load(m, &md, cache_dir(), force))?;
        self.files = lib["tracks"].as_array().map(|a| a.iter().enumerate().map(|(i, t)| (t["f"].as_str().unwrap_or("").to_string(), i)).collect()).unwrap_or_default();
        self.album_of = lib["albums"].as_array().map(|a| a.iter().map(|x| (x["k"].as_str().unwrap_or("").to_string(), x.clone())).collect()).unwrap_or_default();
        self.index = Some(Index::new(&lib));
        let known = self.thumbs.known(lib["albums"].as_array().map(Vec::as_slice).unwrap_or(&[]));
        emit(&json!({"type": "library", "lib": lib, "thumbs": known, "cached": cached, "ms": pyjson::round_i(t0.elapsed().as_secs_f64() * 1000.0)}));
        self.lib = Some(lib);
        Ok(())
    }

    fn send_status(&mut self) -> R<()> {
        let r = self.call(true, |m| m.batch(&[vec!["status".into()], vec!["currentsong".into()]]))?;
        let st = r.first().map(last_dict).unwrap_or_default();
        let cur = r.get(1).map(|p| Mpd::songs(p)).and_then(|s| s.into_iter().next()).unwrap_or_default();
        let g = |k: &str| st.get(k).map(String::as_str);
        fn truth(s: Option<&str>) -> Option<&str> {
            s.filter(|x| !x.is_empty())
        }
        let f = cur.file.clone();
        let out = json!({
            "type": "status", "state": g("state").unwrap_or("stop"),
            "elapsed": pyjson::f(truth(g("elapsed")).map(f_of).unwrap_or(0.0)),
            "duration": pyjson::f(truth(g("duration")).or(truth(cur.get("duration"))).map(f_of).unwrap_or(0.0)),
            "volume": truth(g("volume")).map(i_of).unwrap_or(-1),
            "random": g("random") == Some("1"), "repeat": g("repeat") == Some("1"),
            "single": g("single").unwrap_or("0") != "0", "consume": g("consume") == Some("1"),
            "pos": g("song").map(i_of).unwrap_or(-1), "id": g("songid").map(i_of).unwrap_or(-1),
            "len": g("playlistlength").map(i_of).unwrap_or(0), "file": f,
            "title": cur.get("Title").unwrap_or(""), "artist": cur.list("Artist").join("; "),
            "album": cur.get("Album").unwrap_or(""), "updating": st.contains_key("updating_db"),
            "error": g("error").unwrap_or(""),
        });
        emit(&out);
        self.autoplay_check(&out);
        let id = out["id"].as_i64().unwrap_or(-1);
        if Some(id) != self.last_songid {
            if self.last_songid.is_some() {
                // music-smart logs the finished play on this same event; read history a bit later
                let tx = self.sh.tx.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_secs(2));
                    let _ = tx.send(Msg::Home);
                });
            }
            self.last_songid = Some(id);
            let _ = self.lyr_prefetch(&out);
        }
        Ok(())
    }

    // ── lyrics: own files first, the resolver looks further in the background ────
    fn lyr_init(&self) -> Arc<Resolver> {
        let sh = self.sh.clone();
        self.sh
            .lyr
            .get_or_init(|| {
                let md = { let m = sh.music_dir.lock().unwrap().clone(); if m.is_empty() { format!("{}/Music", home()) } else { m } };
                let sh1 = sh.clone();
                let sh2 = sh.clone();
                let mut r = Resolver::new(
                    &md,
                    cache_dir(),
                    Some(Box::new(move |path, result, _changed| {
                        // resolver thread: a lookup ended; refresh the window if it shows that song
                        let view = sh1.lyr_view.lock().unwrap().clone();
                        let md = sh1.music_dir.lock().unwrap().clone();
                        if !view.is_empty() && lyrics::song_path(&md, &view) == path {
                            let mut v = result;
                            v["type"] = json!("lyrics");
                            v["file"] = json!(view);
                            emit(&v);
                        }
                    })),
                    // via the main loop
                    Some(Box::new(move |c| {
                        let _ = sh2.tx.send(Msg::Cmd(json!({"cmd": "ym", "ym": c})));
                    })),
                    Box::new(|msg| emit(&json!({"type": "log", "msg": msg}))),
                );
                Arc::get_mut(&mut r).unwrap().ym_ok = Box::new(|| pystr::exists(&ym_python()) && lyricsfetch::signed_in());
                r
            })
            .clone()
    }

    fn lyr_meta_of(&self, f: &str) -> Value {
        if let (Some(&i), Some(lib)) = (self.files.get(f), &self.lib) {
            let t = &lib["tracks"][i];
            let g = |k: &str, d: Value| t.get(k).cloned().unwrap_or(d);
            return json!({"artist": g("a", json!("")), "title": g("t", json!("")), "album": g("al", json!("")), "duration": g("d", json!(0))});
        }
        self.lyr_meta.get(f).cloned().unwrap_or(Value::Null)
    }

    /// Continuous play: the last song played to its end and MPD stopped (no repeat / single,
    /// My Vibe not running), so My Vibe carries on instead of silence. A stop pressed by hand
    /// mid-song doesn't count: the song must have reached (about) its end.
    fn autoplay_check(&mut self, st: &Value) {
        let state = st["state"].as_str().unwrap_or("");
        if state == "play" {
            self.playing = Some((Instant::now(), st["elapsed"].as_f64().unwrap_or(0.0), st["duration"].as_f64().unwrap_or(0.0)));
            return;
        }
        let Some((at, elapsed, duration)) = self.playing.take() else { return };
        let reached_end = duration > 0.0 && elapsed + at.elapsed().as_secs_f64() >= duration - 2.0;
        if state == "stop" && reached_end && st["repeat"] != true && st["single"] != true && autoplay_on() && !smart_active() {
            toast("vibe", "Queue finished · My Vibe keeps playing");
            self.smart("start", "");
        }
    }

    /// A new song started: look up lyrics for it and the next two (each song once, cached).
    fn lyr_prefetch(&mut self, st: &Value) -> R<()> {
        let f = st["file"].as_str().unwrap_or("").to_string();
        if f.is_empty() {
            return Ok(());
        }
        if !self.files.contains_key(&f) {
            self.lyr_meta.insert(f.clone(), json!({"artist": st["artist"], "title": st["title"], "album": st["album"], "duration": st["duration"]}));
        }
        let r = self.lyr_init();
        let md = self.music_dir();
        r.want(&lyrics::song_path(&md, &f), &self.lyr_meta_of(&f), false, false);
        let p = st["pos"].as_i64().unwrap_or(-1);
        if p >= 0 {
            let range = format!("{}:{}", p + 1, p + 3);
            let items = self.cmd(true, "playlistinfo", &[&range])?;
            for s in Mpd::songs(&items) {
                if self.files.contains_key(&s.file) {
                    r.want(&lyrics::song_path(&md, &s.file), &self.lyr_meta_of(&s.file), false, false);
                }
            }
        }
        Ok(())
    }

    fn send_lyrics(&mut self, f: &str, look: bool, force: bool) {
        let r = self.lyr_init();
        let path = lyrics::song_path(&self.music_dir(), f);
        *self.sh.lyr_view.lock().unwrap() = f.to_string();
        if look && !path.is_empty() {
            r.want(&path, &self.lyr_meta_of(f), true, force);
        }
        let mut v = r.load(&path);
        v["type"] = json!("lyrics");
        v["file"] = json!(f);
        emit(&v);
    }

    fn send_queue(&mut self) -> R<()> {
        let items = Mpd::songs(&self.cmd(true, "playlistinfo", &[])?);
        let mut out = vec![];
        for s in &items {
            let i = self.files.get(&s.file).map(|&i| i as i64).unwrap_or(-1);
            let mut e = Map::new();
            e.insert("id".into(), json!(s.get("Id").map(i_of).unwrap_or(-1)));
            e.insert("i".into(), json!(i));
            if i < 0 {
                e.insert("f".into(), json!(s.file));
                e.insert("t".into(), json!(s.get("Title").unwrap_or(pystr::basename(&s.file))));
                e.insert("a".into(), json!(s.list("Artist").join("; ")));
                e.insert("d".into(), pyjson::f(s.get("duration").filter(|d| !d.is_empty()).map(f_of).unwrap_or(0.0)));
            }
            out.push(Value::Object(e));
        }
        self.queue_files = items.iter().map(|s| s.file.clone()).collect();
        emit(&json!({"type": "queue", "items": out}));
        Ok(())
    }

    fn stickers(&mut self, name: &str) -> R<Vec<String>> {
        let mut files = vec![];
        match self.cmd(true, "sticker", &["find", "song", "", name]) {
            Ok(pairs) => {
                let mut cur: Option<String> = None;
                for (k, v) in pairs {
                    if k == "file" {
                        cur = Some(v);
                    } else if k == "sticker" {
                        if let Some(c) = cur.as_ref().filter(|c| !c.is_empty()) {
                            let (key, val) = v.split_once('=').unwrap_or((&v, ""));
                            if key == name && !val.is_empty() && val != "0" {
                                files.push(c.clone());
                            }
                        }
                    }
                }
            }
            Err(mpd::Error::Ack(_)) => {}
            Err(e) => return Err(e.into()),
        }
        Ok(files)
    }

    fn send_likes(&mut self) -> R<()> {
        // The whole library counts as liked. Favourites play more often in My Vibe; "ban" = never.
        let mut favs: Vec<String> = self.stickers(FAV)?;
        favs.extend(self.stickers("love")?);
        favs.sort();
        favs.dedup();
        let bans = self.stickers("ban")?;
        emit(&json!({"type": "likes", "files": favs, "bans": bans}));
        Ok(())
    }

    fn send_playlists(&mut self) -> R<()> {
        let mut names = vec![];
        match self.cmd(true, "listplaylists", &[]) {
            Ok(p) => names.extend(p.into_iter().filter(|(k, _)| k == "playlist").map(|(_, v)| v)),
            Err(mpd::Error::Ack(_)) => {}
            Err(e) => return Err(e.into()),
        }
        names.sort_by_cached_key(|n| pystr::casefold(n));
        let mut pls = vec![];
        for n in names {
            let files: Vec<String> = match self.cmd(true, "listplaylist", &[&n]) {
                Ok(p) => p.into_iter().filter(|(k, _)| k == "file").map(|(_, v)| v).collect(),
                Err(mpd::Error::Ack(_)) => vec![],
                Err(e) => return Err(e.into()),
            };
            pls.push(json!({"n": n, "files": files}));
        }
        emit(&json!({"type": "playlists", "items": pls}));
        Ok(())
    }

    fn send_home(&mut self) {
        let (mut recent, mut most, mut counts) = (vec![], vec![], Map::new());
        let h = history();
        if pystr::exists(&h) {
            let r: rusqlite::Result<()> = (|| {
                let db = rusqlite::Connection::open_with_flags(&h, rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE | rusqlite::OpenFlags::SQLITE_OPEN_CREATE)?;
                db.busy_timeout(Duration::from_secs(2))?;
                db.execute_batch("PRAGMA query_only=1")?;
                let mut q = db.prepare("SELECT file, MAX(started) s FROM plays WHERE outcome != 'replaced' GROUP BY file ORDER BY s DESC LIMIT 60")?;
                let mut rows = q.query([])?;
                while let Some(row) = rows.next()? {
                    let f: Option<String> = row.get(0).ok();
                    if let Some(f) = f.filter(|f| self.files.contains_key(f)) {
                        recent.push(f);
                    }
                }
                let mut q = db.prepare("SELECT file, COUNT(*) n FROM plays WHERE outcome IN ('full','partial','seed') GROUP BY file ORDER BY n DESC, MAX(started) DESC")?;
                let mut rows = q.query([])?;
                while let Some(row) = rows.next()? {
                    let f: Option<String> = row.get(0).ok();
                    let n: i64 = row.get(1)?;
                    if let Some(f) = f.filter(|f| self.files.contains_key(f)) {
                        counts.insert(f.clone(), json!(n));
                        if most.len() < 40 {
                            most.push(f);
                        }
                    }
                }
                Ok(())
            })();
            if let Err(e) = r {
                let msg = match &e {
                    rusqlite::Error::SqliteFailure(_, Some(m)) => m.clone(),
                    other => other.to_string(),
                };
                emit(&json!({"type": "log", "msg": format!("history: {msg}")}));
            }
        }
        emit(&json!({"type": "home", "recent": recent, "most": most, "counts": counts}));
    }

    // ── playback helpers ─────────────────────────────────────────────────────
    fn play_files(&mut self, files: &[Value], index: i64, shuffle: bool) -> R<()> {
        let files: Vec<String> = files.iter().filter(|f| truthy(f)).map(pystr_of).collect();
        if files.is_empty() {
            return Ok(());
        }
        self.ym_cancel_play();
        // Like Spotify: the shuffle toggle (MPD random) is global; the Shuffle button turns it on
        // and starts anywhere. If the queue already is this context, just jump.
        let index = if shuffle { (rand_below(files.len() as u64)) as i64 } else { index.clamp(0, files.len() as i64 - 1) };
        let mut cmds: Vec<Vec<String>> = vec![];
        if files != self.queue_files {
            cmds.push(vec!["clear".into()]);
            cmds.extend(files.iter().map(|f| vec!["add".into(), f.clone()]));
            self.queue_files = files.clone();
        }
        if shuffle {
            cmds.push(vec!["random".into(), "1".into()]);
        }
        cmds.push(vec!["play".into(), index.to_string()]);
        self.batch(cmds)?;
        Ok(())
    }

    fn add_files(&mut self, files: &[Value], next: bool) -> R<()> {
        let files: Vec<String> = files.iter().map(pystr_of).collect();
        let cmds: Vec<Vec<String>> = if next && self.dict("status")?.contains_key("song") {
            files.iter().rev().map(|f| vec!["addid".into(), f.clone(), "+0".into()]).collect()
        } else {
            files.iter().map(|f| vec!["addid".into(), f.clone()]).collect()
        };
        self.batch(cmds)?;
        Ok(())
    }

    /// My Vibe lives in music-smart: start [style] / reroll / stop (it keeps the queue topped up).
    fn smart(&self, action: &str, style: &str) {
        let bin = library::music_smart_bin();
        let mut c = Command::new(&bin);
        c.arg(action);
        let ok_style = !style.is_empty() && {
            let b = style.as_bytes();
            (b[0].is_ascii_lowercase() || b[0].is_ascii_digit()) && b.iter().all(|x| x.is_ascii_lowercase() || x.is_ascii_digit() || *x == b'_' || *x == b'-')
        };
        if ok_style {
            c.arg(style);
        }
        if let Ok(extra) = std::env::var("GLASS_MUSIC_SMART_ENV") {
            if let Ok(Value::Object(m)) = serde_json::from_str::<Value>(&extra) {
                for (k, v) in m {
                    c.env(k, pystr_of(&v));
                }
            }
        }
        use std::os::unix::process::CommandExt;
        c.stdout(Stdio::null()).stderr(Stdio::null()).process_group(0);
        match c.spawn() {
            Ok(mut ch) => {
                std::thread::spawn(move || ch.wait()); // reap it (no zombies)
            }
            Err(e) => toast("warn", &format!("music-smart: {}: '{bin}'", io_str(&e))),
        }
    }

    // ── Yandex Music (glassmusic.yandex worker) ──────────────────────────────
    fn ym_start(&self) -> bool {
        {
            let mut ym = self.sh.ym.lock().unwrap();
            if let Some((ch, _)) = ym.as_mut() {
                if matches!(ch.try_wait(), Ok(None)) {
                    return true;
                }
            }
        }
        let py = ym_python();
        if !pystr::exists(&py) {
            emit(&json!({"type": "ym-status", "available": false, "signed": false, "error": "Yandex Music support is not installed (run install.sh)"}));
            return false;
        }
        let spawned = Command::new(&py)
            .args(["-m", "glassmusic.yandex", "serve"])
            .env("PYTHONPATH", py_root())
            .env("PYTHONUNBUFFERED", "1")
            .env("GLASS_MUSIC_DIR", self.music_dir())
            .env("GLASS_MUSIC_CACHE", cache_dir())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn();
        let mut ch = match spawned {
            Ok(c) => c,
            Err(e) => {
                toast("warn", &format!("Yandex Music: {}", io_str(&e)));
                return false;
            }
        };
        let stdin = ch.stdin.take().unwrap();
        let stdout = ch.stdout.take().unwrap();
        *self.sh.ym.lock().unwrap() = Some((ch, stdin));
        let sh = self.sh.clone();
        std::thread::spawn(move || ym_reader(sh, stdout));
        self.ensure_indexer();
        true
    }

    fn ensure_indexer(&self) {
        let mut itx = self.sh.index_tx.lock().unwrap();
        if itx.is_none() {
            let (tx, rx) = channel();
            *itx = Some(tx);
            let sh = self.sh.clone();
            std::thread::spawn(move || ym_indexer(sh, rx));
        }
    }

    fn index_put(&self, m: Value) {
        if let Some(tx) = self.sh.index_tx.lock().unwrap().as_ref() {
            let _ = tx.send(m);
        }
    }

    fn ym_send(&self, c: &Value) {
        if !self.ym_start() {
            return;
        }
        let line = pyjson::dumps(c, false) + "\n";
        let mut ym = self.sh.ym.lock().unwrap();
        let ok = ym.as_mut().is_some_and(|(_, si)| si.write_all(line.as_bytes()).and_then(|_| si.flush()).is_ok());
        if !ok {
            *ym = None;
            drop(ym);
            toast("warn", "The Yandex Music worker stopped; try again");
        }
    }

    /// Remove songs from disk: library ones to the Trash, temp-cache ones deleted; with unlike,
    /// the worker first removes them from the Yandex likes (or the daily sync brings them back).
    fn remove_songs(&mut self, files: &[String], unlike: bool, ids: &Value) -> R<()> {
        let md = self.music_dir();
        let temp = ym_temp();
        let (mut paths, mut idmap) = (vec![], Map::new());
        for f in files {
            let p = if let Some(x) = f.strip_prefix("file://") { x.to_string() } else if f.starts_with('/') { f.clone() } else { pystr::join(&md, f) };
            if removal::inside(&p, &[&md, &temp]) {
                if truthy(ids) && truthy(&ids[f.as_str()]) {
                    idmap.insert(p.clone(), json!(pystr_of(&ids[f.as_str()])));
                }
                paths.push(p);
            }
        }
        if paths.is_empty() {
            return Ok(());
        }
        // take them out of the queue first (MPD names temp songs by their plain path)
        let mut gone: std::collections::HashSet<String> = paths.iter().cloned().collect();
        gone.extend(paths.iter().map(|p| pystr::relpath(p, &md)));
        let items = Mpd::songs(&self.cmd(true, "playlistinfo", &[])?);
        let ids_q: Vec<String> = items
            .iter()
            .filter(|s| gone.contains(&s.file) || gone.contains(s.file.strip_prefix("file://").unwrap_or(&s.file)))
            .filter_map(|s| s.get("Id").filter(|i| !i.is_empty()).map(String::from))
            .collect();
        if !ids_q.is_empty() {
            self.batch(ids_q.into_iter().map(|i| vec!["deleteid".into(), i]).collect())?;
        }
        if unlike && self.ym_start() {
            self.ym_send(&json!({"cmd": "remove", "paths": paths, "unlike": true, "ids": idmap}));
            return Ok(());
        }
        let (removed, failed, rescan) = removal::remove(&paths, &[&md, &temp], &[&md]);
        self.ensure_indexer();
        self.index_put(json!({"type": "ym-index", "dirs": rescan}));
        emit(&json!({"type": "removed", "paths": removed, "failed": failed, "unliked": 0, "notFound": 0}));
        Ok(())
    }

    fn ym_cancel_play(&mut self) {
        if let Some((job, _)) = self.ym_play.take() {
            self.ym_send(&json!({"cmd": "cancel", "job": job}));
        }
    }

    /// A downloaded track for a play / next / add job: put it where it belongs in the queue.
    fn ym_ready(&mut self, m: &Value) -> R<()> {
        let uri = pystr_of(m.get("uri").ok_or_else(|| Fail::Other("'uri'".into()))?);
        let (mode, job) = (m.get("mode").cloned().unwrap_or(Value::Null), m.get("job").cloned().unwrap_or(Value::Null));
        if std::env::var("GLASS_MUSIC_DEBUG").is_ok_and(|v| !v.is_empty()) {
            emit(&json!({"type": "log", "msg": format!("ym_ready job={} mode={} idx={} at={} uri={uri} own={:?}", pystr_of(&job), pystr_of(&mode),
                pystr_of(m.get("idx").unwrap_or(&Value::Null)), pystr_of(m.get("at").unwrap_or(&Value::Null)), self.ym_play)}));
        }
        match mode.as_str() {
            Some("play") => {
                let Some((pj, before)) = self.ym_play.clone() else { return Ok(()) };
                if pj != job {
                    return Ok(()); // superseded by another play
                }
                if m.get("idx") == m.get("at") {
                    let r = self.batch(vec![vec!["clear".into()], vec!["add".into(), uri.clone()], vec!["play".into(), "0".into()]])?;
                    self.queue_files = vec![uri];
                    if r.len() < 3 {
                        toast("warn", "MPD couldn’t play the downloaded file");
                    }
                } else {
                    let (idx, at) = (py_float(&m["idx"]).unwrap_or(0.0), py_float(&m["at"]).unwrap_or(0.0));
                    if idx < at {
                        // tracks before the clicked one go in front of it, in order
                        self.cmd(false, "addid", &[&uri, &before.to_string()])?;
                        self.ym_play = Some((pj, before + 1));
                    } else {
                        self.cmd(false, "addid", &[&uri])?;
                    }
                    self.queue_files = vec![];
                }
            }
            Some("next") => {
                let key = job.to_string();
                let k = self.ym_next.get(&key).copied().unwrap_or(0);
                let has_song = self.dict("status")?.contains_key("song");
                if has_song {
                    self.cmd(false, "addid", &[&uri, &format!("+{k}")])?;
                } else {
                    self.cmd(false, "addid", &[&uri])?;
                }
                self.ym_next.insert(key, k + 1);
            }
            Some("add") => {
                self.cmd(false, "addid", &[&uri])?;
            }
            _ => {}
        }
        Ok(())
    }

    // ── commands ─────────────────────────────────────────────────────────────
    fn handle(&mut self, c: &Value) -> R<()> {
        let cmd = c["cmd"].as_str().unwrap_or("").to_string();
        let gs = |k: &str| c.get(k).map(pystr_of).unwrap_or_default();
        let on = c.get("on").map(truthy).unwrap_or(true);
        match cmd.as_str() {
            "hello" => {
                let ss = smart_state();
                emit(&json!({"type": "hello", "smartState": ss, "smartStyles": pystr::join(pystr::dirname(&ss), "styles.json"), "mpd": self.sh.address, "autoplay": autoplay_on()}));
                self.send_library(false)?;
                self.send_status()?;
                self.send_queue()?;
                self.send_likes()?;
                self.send_playlists()?;
                self.send_home();
            }
            "search" => {
                let q = c.get("q").cloned().unwrap_or(json!(""));
                let mut r = match &self.index {
                    Some(ix) => ix.search(q.as_str().unwrap_or("")),
                    None => json!({}),
                };
                r["type"] = json!("search");
                r["q"] = q;
                r["rid"] = c.get("rid").cloned().unwrap_or(json!(0));
                emit(&r);
            }
            "thumbs" => {
                let mut items = vec![];
                for k in c["keys"].as_array().cloned().unwrap_or_default() {
                    let k = pystr_of(&k);
                    if let Some(a) = self.album_of.get(&k) {
                        let cover = a["c"].as_str().unwrap_or("");
                        if !cover.is_empty() {
                            items.push((k.clone(), cover.to_string()));
                        }
                    }
                }
                self.thumbs.request(items);
            }
            "lyrics" => self.send_lyrics(&gs("file"), true, false),
            "lyricsfind" => self.send_lyrics(&gs("file"), true, true), // "Find lyrics" / "Look again"
            "lyricswrong" => {
                // "These lyrics are wrong": next source / candidate
                let f = gs("file");
                let path = lyrics::song_path(&self.music_dir(), &f);
                if !path.is_empty() && self.lyr_init().reject(&path, &self.lyr_meta_of(&f)) {
                    toast("lyrics", "Looking for other lyrics…");
                }
                self.send_lyrics(&f, false, false);
            }
            "play" => {
                let index = match c.get("index") {
                    None => 0,
                    Some(v) => py_int(v).ok_or_else(|| Fail::Other(format!("invalid literal for int(): {}", pystr_of(v))))?,
                };
                let files = c["files"].as_array().cloned().unwrap_or_default();
                self.play_files(&files, index, c.get("shuffle").is_some_and(truthy))?;
            }
            "add" => {
                let files = c["files"].as_array().cloned().unwrap_or_default();
                let next = c.get("next").is_some_and(truthy);
                self.add_files(&files, next)?;
                let n = files.len();
                toast("queue", &format!("{}{}", if next { "Playing next" } else { "Added to queue" }, if n > 1 { format!(" · {n} tracks") } else { String::new() }));
            }
            "toggle" => {
                let st = self.dict("status")?.get("state").cloned().unwrap_or_default();
                if st == "stop" {
                    self.cmd(false, "play", &[])?;
                } else {
                    self.cmd(false, "pause", &[if st == "play" { "1" } else { "0" }])?;
                }
            }
            "next" | "previous" | "stop" => {
                self.cmd(false, &cmd, &[])?;
            }
            "seek" => {
                let pos = c.get("pos").map(|v| py_float(v).unwrap_or(0.0)).unwrap_or(0.0).max(0.0);
                self.cmd(false, "seekcur", &[&format!("{pos:.2}")])?;
            }
            "volume" => {
                let v = c.get("value").map(|v| py_int(v).unwrap_or(50)).unwrap_or(50).clamp(0, 100);
                self.cmd(false, "setvol", &[&v.to_string()])?;
            }
            "random" => {
                self.cmd(false, "random", &[if c.get("on").is_some_and(truthy) { "1" } else { "0" }])?;
            }
            "repeat" => {
                let mode = c.get("mode").map(pystr_of).unwrap_or_else(|| "off".into()); // off | all | one
                self.batch(vec![
                    vec!["repeat".into(), if mode == "off" { "0" } else { "1" }.into()],
                    vec!["single".into(), if mode == "one" { "1" } else { "0" }.into()],
                ])?;
            }
            "playid" | "deleteid" => {
                let id = pystr_of(c.get("id").ok_or_else(|| Fail::Other("'id'".into()))?);
                self.cmd(false, &cmd, &[&id])?;
            }
            "moveid" => {
                let id = pystr_of(c.get("id").ok_or_else(|| Fail::Other("'id'".into()))?);
                let to = pystr_of(c.get("to").ok_or_else(|| Fail::Other("'to'".into()))?);
                self.cmd(false, "moveid", &[&id, &to])?;
            }
            "clearqueue" => {
                let st = self.dict("status")?;
                if let Some(song) = st.get("song") {
                    // keep the current track, drop the rest
                    let pos = i_of(song);
                    let n = st.get("playlistlength").map(|x| i_of(x)).unwrap_or(0);
                    let mut cmds = vec![];
                    if pos + 1 < n {
                        cmds.push(vec!["delete".into(), format!("{}:{n}", pos + 1)]);
                    }
                    if pos > 0 {
                        cmds.push(vec!["delete".into(), format!("0:{pos}")]);
                    }
                    self.batch(cmds)?;
                } else {
                    self.cmd(false, "clear", &[])?;
                }
            }
            "fav" | "love" => {
                let f = c.get("file").cloned().unwrap_or(Value::Null);
                if truthy(&f) {
                    let f = pystr_of(&f);
                    if on {
                        self.cmd(false, "sticker", &["set", "song", &f, FAV, "1"])?;
                    } else {
                        for name in [FAV, "love"] {
                            match self.cmd(false, "sticker", &["delete", "song", &f, name]) {
                                Ok(_) | Err(mpd::Error::Ack(_)) => {}
                                Err(e) => return Err(e.into()),
                            }
                        }
                    }
                    if on {
                        toast("star", "Favourite · My Vibe plays it more often");
                    } else {
                        toast("star-outline", "No longer a favourite");
                    }
                }
            }
            "ban" => {
                let f = c.get("file").cloned().unwrap_or(Value::Null);
                if truthy(&f) {
                    let f = pystr_of(&f);
                    if on {
                        self.cmd(false, "sticker", &["set", "song", &f, "ban", "1"])?;
                    } else {
                        match self.cmd(false, "sticker", &["delete", "song", &f, "ban"]) {
                            Ok(_) | Err(mpd::Error::Ack(_)) => {}
                            Err(e) => return Err(e.into()),
                        }
                    }
                    if on {
                        toast("cancel", "My Vibe will never play this song");
                    } else {
                        toast("vibe", "Back in My Vibe");
                    }
                }
            }
            "mix" => self.smart("start", &gs("mood")), // old name: a style's endless My Vibe queue
            "autoplay" => {
                set_autoplay(on);
                emit(&json!({"type": "autoplay", "on": on}));
            }
            "smart" => {
                let action = c.get("action").map(pystr_of).unwrap_or_else(|| "start".into());
                self.smart(&action, &gs("style"));
            }
            "playlistadd" => {
                let name = pystr::strip(&gs("name")).to_string();
                let files: Vec<String> = c["files"].as_array().map(|a| a.iter().map(pystr_of).collect()).unwrap_or_default();
                if !name.is_empty() && !files.is_empty() {
                    self.batch(files.iter().map(|f| vec!["playlistadd".into(), name.clone(), f.clone()]).collect())?;
                    toast("playlist", &format!("Added to {name}"));
                }
            }
            "savequeue" => {
                let name = pystr::strip(&gs("name")).to_string();
                if !name.is_empty() {
                    match self.cmd(false, "save", &[&name]) {
                        Ok(_) => toast("playlist", &format!("Saved queue as {name}")),
                        Err(mpd::Error::Ack(e)) => toast("warn", e.rsplit("} ").next().unwrap_or(&e)),
                        Err(e) => return Err(e.into()),
                    }
                }
            }
            "playlistdelete" => match self.cmd(false, "rm", &[&gs("name")]) {
                Ok(_) | Err(mpd::Error::Ack(_)) => {}
                Err(e) => return Err(e.into()),
            },
            "rescan" => {
                self.cmd(false, "update", &[])?;
            }
            "home" => self.send_home(),
            "remove" => {
                let files: Vec<String> = c["files"].as_array().map(|a| a.iter().filter_map(|f| f.as_str().map(String::from)).collect()).unwrap_or_default();
                self.remove_songs(&files, c.get("unlike").is_some_and(truthy), c.get("ids").unwrap_or(&Value::Null))?;
            }
            "ym" => {
                let inner = c.get("ym").filter(|x| truthy(x)).cloned().unwrap_or(json!({}));
                if inner["cmd"] == "fetch" && inner["mode"] == "play" {
                    self.ym_cancel_play();
                    self.ym_play = Some((inner.get("job").cloned().unwrap_or(Value::Null), 0));
                }
                self.ym_send(&inner);
            }
            "spawn" if c["what"] == "terminal" => {
                let p = format!("{}/.local/bin/music-player", home());
                use std::os::unix::process::CommandExt;
                match Command::new(&p).stdout(Stdio::null()).stderr(Stdio::null()).process_group(0).spawn() {
                    Ok(mut ch) => {
                        std::thread::spawn(move || ch.wait());
                    }
                    Err(e) => return Err(Fail::Mpd(mpd::Error::Io(std::io::Error::other(format!("{}: '{p}'", io_str(&e)))))),
                }
            }
            _ => {}
        }
        Ok(())
    }

    fn on_event(&mut self, ch: &std::collections::HashSet<String>) -> R<()> {
        // "reconnect" (the idle watcher (re)connected: changes during the gap are unknown) needs a
        // fresh status + queue; it can come in the same burst as real changes, which still count.
        let reconnect = ch.contains("reconnect");
        if ch.contains("database") {
            self.send_library(false)?;
            self.send_queue()?;
            self.send_home();
        } else if ch.contains("playlist") || reconnect {
            self.send_queue()?;
        }
        if reconnect || ["player", "mixer", "options", "playlist", "update"].iter().any(|k| ch.contains(*k)) {
            self.send_status()?;
        }
        if ch.contains("sticker") {
            self.send_likes()?;
        }
        if ch.contains("stored_playlist") {
            self.send_playlists()?;
        }
        Ok(())
    }

    pub fn run(mut self) {
        let tx = self.sh.tx.clone();
        std::thread::spawn(move || Server::stdin_thread(tx));
        let mut started_idle = false;
        loop {
            let msg = match self.backlog.pop_front() {
                Some(m) => m,
                None => match self.rx.recv() {
                    Ok(m) => m,
                    Err(_) => break,
                },
            };
            if matches!(msg, Msg::Quit) || matches!(&msg, Msg::Cmd(c) if c["cmd"] == "quit") {
                if let Some((mut ch, si)) = self.sh.ym.lock().unwrap().take() {
                    drop(si); // the worker ends at EOF
                    std::thread::spawn(move || ch.wait());
                }
                break;
            }
            let r = match msg {
                Msg::Cmd(c) => {
                    let r = self.handle(&c);
                    if c["cmd"] == "hello" && !started_idle {
                        started_idle = true;
                        let sh = self.sh.clone();
                        std::thread::spawn(move || Server::idle_thread(sh));
                    }
                    r
                }
                Msg::Event(d) if self.lib.is_some() => {
                    // coalesce bursts (a context play fires playlist+player+options at once)
                    let mut changed: std::collections::HashSet<String> = d.into_iter().collect();
                    std::thread::sleep(Duration::from_millis(30));
                    while let Ok(m) = self.rx.try_recv() {
                        match m {
                            Msg::Event(d2) => changed.extend(d2),
                            other => {
                                self.backlog.push_back(other);
                                break;
                            }
                        }
                    }
                    self.on_event(&changed)
                }
                Msg::Home if self.lib.is_some() => {
                    self.send_home();
                    Ok(())
                }
                Msg::Ym(m) => self.ym_ready(&m),
                _ => Ok(()),
            };
            match r {
                Ok(()) => {}
                Err(Fail::Mpd(e)) => emit(&json!({"type": "error", "error": err_str(&e)})),
                Err(Fail::Other(e)) => emit(&json!({"type": "error", "error": e, "trace": ""})),
            }
        }
    }
}

fn rand_below(n: u64) -> u64 {
    let mut b = [0u8; 8];
    unsafe { libc::getrandom(b.as_mut_ptr() as *mut libc::c_void, 8, 0) };
    u64::from_ne_bytes(b) % n.max(1)
}

fn ym_reader(sh: Arc<Shared>, stdout: std::process::ChildStdout) {
    let r = std::io::BufReader::new(stdout);
    for line in r.split(b'\n').map_while(Result::ok) {
        let Ok(mut m) = serde_json::from_slice::<Value>(&line) else { continue };
        let t = m["type"].as_str().unwrap_or("").to_string();
        if t == "ym-lyrics" || (t == "ym-error" && m["cmd"] == "lyrics") {
            if let Some(l) = sh.lyr.get() {
                l.on_ym(&m); // an answer for the lyrics resolver
            }
            continue;
        }
        let put = |v: Value| {
            if let Some(tx) = sh.index_tx.lock().unwrap().as_ref() {
                let _ = tx.send(v);
            }
        };
        if t == "ym-ready" {
            put(m.clone()); // new library files are indexed by MPD first
        } else if t == "ym-removed" {
            put(json!({"type": "ym-index", "dirs": m.get("rescan").cloned().unwrap_or(json!([]))}));
            m["type"] = json!("removed");
            emit(&m);
            continue;
        } else if t == "ym-done" && m.get("paths").is_some_and(truthy) {
            let mut v = m.clone();
            v["type"] = json!("ym-index");
            put(v);
        }
        emit(&m);
    }
}

/// Library downloads must be in MPD's database before they can be queued: run `update` on the new
/// file's folder and wait for that update job, then hand it to the main loop.
fn ym_indexer(sh: Arc<Shared>, rx: Receiver<Value>) {
    let mut m: Option<Mpd> = None;
    while let Ok(mut msg) = rx.recv() {
        let md = sh.music_dir.lock().unwrap().clone();
        let base = format!("{}/", md.trim_end_matches('/'));
        let ready = msg["type"] == "ym-ready";
        let paths: Vec<String> = if ready {
            vec![pystr_of(&msg["path"])]
        } else {
            msg["paths"].as_array().map(|a| a.iter().map(pystr_of).collect()).unwrap_or_default()
        };
        let rels: Vec<String> = paths.iter().filter(|p| !md.is_empty() && p.starts_with(&base)).map(|p| pystr::relpath(p, &md)).collect();
        let mut dirs: std::collections::BTreeSet<String> = rels.iter().map(|r| pystr::dirname(r).to_string()).collect();
        if let Some(d) = msg.get("dirs") {
            // removals: the folders that changed or disappeared
            dirs = d.as_array().map(|a| a.iter().map(pystr_of).filter(|d| !md.is_empty() && d.starts_with(&base)).map(|d| pystr::relpath(&d, &md)).collect()).unwrap_or_default();
        }
        if !dirs.is_empty() {
            let r: mpd::Result<()> = (|| {
                if m.as_ref().is_none_or(|c| c.stale()) {
                    m = Some(Mpd::connect(&sh.address)?);
                }
                let c = m.as_mut().unwrap();
                let mut job = 0;
                // update the album folder: MPD skips a file path whose folder it doesn't know yet
                for d in &dirs {
                    job = job.max(c.dict("update", &[d])?.get("updating_db").map(|x| i_of(x)).unwrap_or(0));
                }
                // a short poll, only while this update job runs
                let deadline = Instant::now() + Duration::from_secs(60);
                while Instant::now() < deadline {
                    let cur = c.dict("status", &[])?.get("updating_db").map(|x| i_of(x)).unwrap_or(0);
                    if cur == 0 || cur > job {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
                Ok(())
            })();
            if let Err(e) = r {
                m = None;
                emit(&json!({"type": "log", "msg": format!("mpd update: {}", err_str(&e))}));
            }
        }
        if ready {
            msg["uri"] = json!(rels.first().cloned().unwrap_or_else(|| format!("file://{}", pystr_of(&msg["path"]))));
            let _ = sh.tx.send(Msg::Ym(msg));
        }
    }
}

#[cfg(test)]
mod tests {
    //! Port of tests/test_server.py's CallRetryTest: call() retry safety against a scripted fake MPD.
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixListener;

    /// One behaviour per accepted connection: "ok", "drop" (run the first command / list, then hang
    /// up without replying), "idle-close" (hang up right after the greeting).
    struct Fake {
        path: String,
        executed: Arc<Mutex<Vec<String>>>,
        closed_idle: Arc<Mutex<bool>>,
    }

    fn fake(script: &[&str]) -> Fake {
        let dir = std::env::temp_dir().join(format!("gm-fake-mpd-{}-{}", std::process::id(), rand_below(1 << 40)));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("socket").to_string_lossy().into_owned();
        let l = UnixListener::bind(&path).unwrap();
        let executed = Arc::new(Mutex::new(vec![]));
        let closed_idle = Arc::new(Mutex::new(false));
        let mut script: VecDeque<String> = script.iter().map(|s| s.to_string()).collect();
        let (ex, ci) = (executed.clone(), closed_idle.clone());
        std::thread::spawn(move || {
            for c in l.incoming().flatten() {
                let mode = script.pop_front().unwrap_or_else(|| "ok".into());
                let (ex, ci) = (ex.clone(), ci.clone());
                std::thread::spawn(move || {
                    let mut w = c.try_clone().unwrap();
                    w.write_all(b"OK MPD 0.24.0\n").unwrap();
                    if mode == "idle-close" {
                        let _ = c.shutdown(std::net::Shutdown::Both);
                        *ci.lock().unwrap() = true;
                        return;
                    }
                    let mut list: Option<Vec<String>> = None;
                    for line in BufReader::new(c.try_clone().unwrap()).lines().map_while(Result::ok) {
                        if line == "command_list_ok_begin" || line == "command_list_begin" {
                            list = Some(vec![]);
                            continue;
                        }
                        if let Some(l) = list.as_mut() {
                            if line != "command_list_end" {
                                l.push(line);
                                continue;
                            }
                        }
                        let cmds = list.take().map(|l| (l, true)).unwrap_or((vec![line], false));
                        ex.lock().unwrap().extend(cmds.0.iter().cloned());
                        if mode == "drop" {
                            let _ = c.shutdown(std::net::Shutdown::Both);
                            return;
                        }
                        let mut out = String::new();
                        for cmd in &cmds.0 {
                            if cmd == "status" {
                                out.push_str("state: play\n");
                            }
                            if cmds.1 {
                                out.push_str("list_OK\n");
                            }
                        }
                        out.push_str("OK\n");
                        let _ = w.write_all(out.as_bytes());
                    }
                });
            }
        });
        Fake { path, executed, closed_idle }
    }

    fn v(cmds: &[&[&str]]) -> Vec<Vec<String>> {
        cmds.iter().map(|c| c.iter().map(|s| s.to_string()).collect()).collect()
    }

    #[test]
    fn command_list_not_resent_after_drop() {
        // MPD runs clear+add, then the connection dies before the reply: never send it twice.
        let f = fake(&["drop"]);
        let mut cc = CmdConn::new(&f.path);
        let cmds = v(&[&["clear"], &["add", "a.m4a"], &["add", "b.m4a"]]);
        assert!(matches!(cc.call(false, |m| m.batch(&cmds)), Err(mpd::Error::Io(_))));
        assert_eq!(*f.executed.lock().unwrap(), vec!["clear", "add \"a.m4a\"", "add \"b.m4a\""]);
        assert!(cc.mpd.is_none());
        cc.call(false, |m| m.cmd("ping", &[])).unwrap(); // the next call reconnects cleanly
        assert_eq!(f.executed.lock().unwrap().last().unwrap(), "ping");
    }

    #[test]
    fn idempotent_read_is_retried() {
        let f = fake(&["drop"]);
        let mut cc = CmdConn::new(&f.path);
        let st = cc.call(true, |m| m.dict("status", &[])).unwrap();
        assert_eq!(st.get("state").map(String::as_str), Some("play"));
        assert_eq!(*f.executed.lock().unwrap(), vec!["status", "status"]);
    }

    #[test]
    fn timed_out_idle_connection_reconnects_before_sending() {
        // The common case: MPD closed the idle command connection; a write must still go out once.
        let f = fake(&["idle-close"]);
        let mut cc = CmdConn::new(&f.path);
        cc.conn().unwrap();
        for _ in 0..200 {
            if *f.closed_idle.lock().unwrap() && cc.mpd.as_ref().unwrap().stale() {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        cc.call(false, |m| m.batch(&v(&[&["clear"], &["add", "a.m4a"]]))).unwrap();
        assert_eq!(*f.executed.lock().unwrap(), vec!["clear", "add \"a.m4a\""]);
    }

    #[test]
    fn connect_failure_is_retried() {
        let f = fake(&[]);
        let mut cc = CmdConn::new(&format!("{}.missing", f.path));
        // nothing was ever sent: two connect attempts, then the error
        assert!(matches!(cc.call(false, |m| m.cmd("clear", &[])), Err(mpd::Error::Io(_))));
    }

    #[test]
    fn last_value_wins_in_status() {
        let p: Pairs = vec![("a".into(), "1".into()), ("a".into(), "2".into())];
        assert_eq!(last_dict(&p)["a"], "2");
    }
}
