//! One mail account (port of engine.py): IMAP sync into the cache, actions, sending.
//!
//! Each account runs three threads, each with its own IMAP connection and Store:
//!   fg   — what you are waiting for: opening a message, actions, search, older pages
//!   bg   — folder list, counts, syncing folders, snippets, prefetching bodies
//!   idle — IMAP IDLE on the inbox; wakes bg the moment mail arrives (polls if no IDLE)
use crate::accounts;
use crate::codes;
use crate::hub::Hub;
use crate::imapparse::{self as ip, Fetch, S};
use crate::mime;
use crate::net::{Arg, Done, Imap, ImapError, Smtp, SmtpError};
use crate::store::{body_path, Store};
use regex::Regex;
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
use std::net::{Shutdown, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::Duration;

pub const INITIAL: usize = 150;
pub const PAGE: usize = 100;
pub const BATCH: usize = 80;
pub const PREFETCH: i64 = 25;
pub const HEADER_FIELDS: &str = "FROM TO CC SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES LIST-UNSUBSCRIBE";

fn role_name(role: &str) -> Option<&'static str> {
    Some(match role {
        "inbox" => "Inbox",
        "flagged" => "Starred",
        "sent" => "Sent",
        "drafts" => "Drafts",
        "archive" => "Archive",
        "all" => "All mail",
        "junk" => "Spam",
        "trash" => "Trash",
        "important" => "Important",
        _ => return None,
    })
}

fn name_roles() -> &'static Vec<(&'static str, Regex)> {
    static R: OnceLock<Vec<(&str, Regex)>> = OnceLock::new();
    R.get_or_init(|| {
        vec![
            ("sent", Regex::new(r"(?i)^(sent|sent items|sent messages|sent mail|отправленные)$").unwrap()),
            ("drafts", Regex::new(r"(?i)^(drafts?|черновики)$").unwrap()),
            ("trash", Regex::new(r"(?i)^(trash|deleted|deleted items|deleted messages|bin|корзина|удаленные|удалённые)$").unwrap()),
            ("junk", Regex::new(r"(?i)^(spam|junk|junk e-?mail|bulk mail|спам)$").unwrap()),
            ("archive", Regex::new(r"(?i)^(archives?|архив)$").unwrap()),
        ]
    })
}

/// What can go wrong in an operation (AuthError / ConnectionError / anything else in the Python).
#[derive(Debug)]
pub enum OpErr {
    Auth(String),
    Conn(String),
    Other(String),
}

impl std::fmt::Display for OpErr {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            OpErr::Auth(s) | OpErr::Conn(s) | OpErr::Other(s) => write!(f, "{s}"),
        }
    }
}

impl From<ImapError> for OpErr {
    fn from(e: ImapError) -> Self {
        match e {
            ImapError::Io(e) => OpErr::Conn(crate::net::py_io(&e)),
            ImapError::No(s) => OpErr::Other(s),
        }
    }
}

impl From<std::io::Error> for OpErr {
    fn from(e: std::io::Error) -> Self {
        OpErr::Other(e.to_string())
    }
}

pub type OResult<T> = Result<T, OpErr>;

pub fn login_hint(conf: &Value, err: &str) -> String {
    static Q: OnceLock<Regex> = OnceLock::new();
    let err = Q.get_or_init(|| Regex::new(r#"^b?['"]|['"]$"#).unwrap()).replace_all(err.trim(), "").into_owned();
    match conf["provider"].as_str().unwrap_or("") {
        "gmail" => "Gmail refused the password. Use an app password (Google Account → Security → 2-Step Verification → App passwords), not your normal password.".into(),
        "yandex" => "Yandex refused the password. Create an app password for Mail (id.yandex.ru → Security → App passwords) and allow IMAP in Yandex Mail settings → Mail clients.".into(),
        "mailru" => "Mail.ru refused the password. Use a password for external apps (Mail.ru account → Security → Passwords for external applications).".into(),
        _ => format!("The server refused the login: {}.", if err.is_empty() { "wrong user name or password".to_string() } else { err }),
    }
}

pub fn imap_connect(conf: &Value, timeout: u64) -> OResult<Imap> {
    let host = conf["imap"]["host"].as_str().unwrap_or("").to_string();
    let port = conf["imap"]["port"].as_u64().filter(|p| *p != 0).unwrap_or(993) as u16;
    let starttls = port == 143 || conf["imap"]["security"] == "starttls";
    let mut c = Imap::connect(&host, port, starttls, Duration::from_secs(timeout)).map_err(|e| OpErr::Conn(format!("Can't reach {host}:{port} ({e})")))?;
    let user = conf["user"].as_str().filter(|u| !u.is_empty()).or(conf["email"].as_str()).unwrap_or("").to_string();
    if let Err(e) = c.login(&user, conf["password"].as_str().unwrap_or("")) {
        return Err(match e {
            ImapError::No(s) => {
                c.logout();
                // imaplib raises with the text after the status
                let text = match s.split_once(' ') {
                    Some(("NO", t)) => t.to_string(),
                    Some(("BAD", t)) => format!("LOGIN command error: BAD [b'{t}']"),
                    _ => s,
                };
                OpErr::Auth(login_hint(conf, &text))
            }
            ImapError::Io(e) => OpErr::Conn(format!("Can't reach {host}:{port} ({})", crate::net::py_io(&e))),
        });
    }
    if c.has("ENABLE") && c.has("CONDSTORE") {
        let _ = c.simple("ENABLE CONDSTORE");
    }
    Ok(c)
}

pub fn smtp_connect(conf: &Value) -> OResult<Smtp> {
    let s = &conf["smtp"];
    let host = s["host"].as_str().unwrap_or("").to_string();
    let port = s["port"].as_u64().filter(|p| *p != 0).unwrap_or(465) as u16;
    let sec = s["security"].as_str().filter(|x| !x.is_empty()).map(String::from).unwrap_or_else(|| if port == 465 { "ssl".into() } else { "starttls".into() });
    let mut c = Smtp::connect(&host, port, &sec, Duration::from_secs(30)).map_err(|e| OpErr::Conn(format!("Can't reach the outgoing server {host}:{port} ({e})")))?;
    let pass = conf["password"].as_str().unwrap_or("");
    if !pass.is_empty() && c.has_auth() {
        let user = s["user"].as_str().filter(|u| !u.is_empty()).or(conf["user"].as_str().filter(|u| !u.is_empty())).or(conf["email"].as_str()).unwrap_or("");
        if let Err(e) = c.login(user, pass) {
            c.quit();
            return Err(match e {
                SmtpError::Auth(t) => OpErr::Auth(login_hint(conf, &t)),
                other => OpErr::Conn(other.to_string()),
            });
        }
    }
    Ok(c)
}

/// Sign-in check for the account page: IMAP login + folder list, SMTP login.
pub fn test_account(conf: &Value) -> OResult<usize> {
    let mut c = imap_connect(conf, 30)?;
    let n = c.simple("LIST \"\" *").map(|d| ip::parse_list(&Imap::list_lines(&d)).len()).unwrap_or(0);
    c.logout();
    let mut s = smtp_connect(conf)?;
    s.quit();
    Ok(n)
}

/// [1,2,3,7,9,10] -> "1:3,7,9:10"
pub fn uidset(uids: &[i64]) -> String {
    let mut u: Vec<i64> = uids.to_vec();
    u.sort();
    u.dedup();
    let mut out = vec![];
    let mut i = 0;
    while i < u.len() {
        let mut j = i;
        while j + 1 < u.len() && u[j + 1] == u[j] + 1 {
            j += 1;
        }
        out.push(if i == j { u[i].to_string() } else { format!("{}:{}", u[i], u[j]) });
        i = j + 1;
    }
    out.join(",")
}

/// "12-Oct-2026 10:00:00 +0300" -> unix time
pub fn internaldate(s: &str) -> f64 {
    let p: Vec<&str> = s.split_whitespace().collect();
    if p.len() != 3 {
        return 0.0;
    }
    let d: Vec<&str> = p[0].split('-').collect();
    let t: Vec<&str> = p[1].split(':').collect();
    if d.len() != 3 || t.len() != 3 {
        return 0.0;
    }
    const M: [&str; 12] = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
    let Some(m) = M.iter().position(|x| x.eq_ignore_ascii_case(d[1])) else { return 0.0 };
    let n = |x: &str| x.trim().parse::<i64>().unwrap_or(0);
    let z = p[2];
    let zs = if z.starts_with('-') { -1 } else { 1 };
    let zn = n(z.trim_start_matches(['+', '-']));
    let off = zs * ((zn / 100) * 3600 + (zn % 100) * 60);
    let fake = format!("{} {} {} {}:{}:{} +0000", n(d[0]), M[m], n(d[2]), n(t[0]), n(t[1]), n(t[2]));
    let ts = crate::pyemail::date_timestamp(&fake);
    if ts == 0.0 {
        0.0
    } else {
        ts - off as f64
    }
}

/// imaplib.Time2Internaldate(now) without the quotes
pub fn time2internaldate(t: f64) -> String {
    let tt = t as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&tt, &mut tm) };
    const M: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    let off = tm.tm_gmtoff / 60;
    format!(
        "{:02}-{}-{} {:02}:{:02}:{:02} {}{:02}{:02}",
        tm.tm_mday,
        M[tm.tm_mon as usize],
        tm.tm_year + 1900,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec,
        if off < 0 { '-' } else { '+' },
        off.abs() / 60,
        off.abs() % 60
    )
}

fn chunks(v: &[i64], n: usize) -> Vec<Vec<i64>> {
    v.chunks(n).map(|c| c.to_vec()).collect()
}

fn s(v: &Map<String, Value>, k: &str) -> String {
    v.get(k).and_then(Value::as_str).unwrap_or("").to_string()
}

fn i(v: &Map<String, Value>, k: &str) -> i64 {
    v.get(k).map(|x| x.as_i64().or_else(|| x.as_f64().map(|f| f as i64)).unwrap_or(0)).unwrap_or(0)
}

/// An IMAP connection that reconnects, remembers the selected folder and retries once.
pub struct Conn {
    pub conf: Value,
    pub c: Option<Imap>,
    pub selected: Option<String>,
    pub sel_info: (i64, i64, i64, i64), // exists, uidvalidity, uidnext, highestmodseq
}

impl Conn {
    pub fn new(conf: &Value) -> Conn {
        Conn { conf: conf.clone(), c: None, selected: None, sel_info: (0, 0, 0, 0) }
    }

    pub fn open(&mut self) -> OResult<&mut Imap> {
        if self.c.is_none() {
            self.c = Some(imap_connect(&self.conf, 30)?);
            self.selected = None;
        }
        Ok(self.c.as_mut().unwrap())
    }

    pub fn close(&mut self) {
        if let Some(mut c) = self.c.take() {
            c.logout();
        }
        self.selected = None;
    }

    pub fn has(&self, cap: &str) -> bool {
        self.c.as_ref().is_some_and(|c| c.has(cap))
    }

    pub fn im(&mut self) -> OResult<&mut Imap> {
        self.c.as_mut().ok_or_else(|| OpErr::Conn("not connected".into()))
    }

    /// fn(conn) with one reconnect on a dropped connection
    pub fn run<T>(&mut self, mut f: impl FnMut(&mut Conn) -> OResult<T>) -> OResult<T> {
        for attempt in 0..2 {
            if let Err(e) = self.open() {
                if attempt == 1 || !matches!(e, OpErr::Conn(_)) {
                    return Err(e);
                }
                self.close();
                continue;
            }
            match f(self) {
                Err(OpErr::Conn(e)) => {
                    self.close();
                    if attempt == 1 {
                        return Err(OpErr::Conn(e));
                    }
                }
                other => return other,
            }
        }
        Err(OpErr::Conn("connection lost".into()))
    }

    pub fn select(&mut self, path: &str, force: bool) -> OResult<(i64, i64, i64, i64)> {
        if self.selected.as_deref() == Some(path) && !force {
            return Ok(self.sel_info);
        }
        let q = ip::quote(path);
        match self.im()?.select(&q, false) {
            Ok(info) => {
                self.selected = Some(path.to_string());
                self.sel_info = info;
                Ok(info)
            }
            Err(ImapError::No(e)) => {
                self.selected = None;
                Err(OpErr::Other(format!("select {path}: {e}")))
            }
            Err(e) => Err(e.into()),
        }
    }

    pub fn uid(&mut self, args: &str) -> OResult<Done> {
        Ok(self.im()?.simple(&format!("UID {args}"))?)
    }

    pub fn fetch(&mut self, set: &str, items: &str) -> OResult<Vec<Fetch>> {
        let d = self.uid(&format!("FETCH {set} {items}"))?;
        let (buf, lits) = Imap::fetch_buf(&d);
        Ok(ip::parse_fetch(&buf, &lits))
    }

    pub fn search(&mut self, criteria: &str) -> OResult<Vec<i64>> {
        Ok(Imap::search_nums(&self.uid(&format!("SEARCH {criteria}"))?))
    }

    pub fn search_lit(&mut self, head: &str, lit: &[u8]) -> OResult<Vec<i64>> {
        let d = self.im()?.command(&[Arg::Text(&format!("UID SEARCH {head}")), Arg::Lit(lit)])?;
        Ok(Imap::search_nums(&d))
    }
}

pub enum Op {
    Refresh { full: bool },
    Sync { path: String },
    Older { path: String },
    Open { path: String, uid: i64, rid: Value, mark: bool },
    FetchRaw { path: String, uid: i64, then: Box<dyn FnOnce(Option<Vec<u8>>) + Send> },
    Act { op: String, path: String, uids: Vec<i64>, rid: Value, dest: Option<String>, msgids: Vec<String> },
    Undo { src: String, dest: String, msgids: Vec<String>, rid: Value },
    Search { q: String, rid: Value, path: Option<String> },
    Send { draft: Value, attachments: Vec<String>, rid: Value, forward: Option<Value> },
    Counts,
}

impl Op {
    fn name(&self) -> &'static str {
        match self {
            Op::Refresh { .. } => "refresh",
            Op::Sync { .. } => "sync",
            Op::Older { .. } => "older",
            Op::Open { .. } => "open",
            Op::FetchRaw { .. } => "fetchraw",
            Op::Act { .. } => "act",
            Op::Undo { .. } => "undo",
            Op::Search { .. } => "search",
            Op::Send { .. } => "send",
            Op::Counts => "counts",
        }
    }
    fn rid(&self) -> Value {
        match self {
            Op::Open { rid, .. } | Op::Act { rid, .. } | Op::Undo { rid, .. } | Op::Search { rid, .. } | Op::Send { rid, .. } => rid.clone(),
            _ => Value::Null,
        }
    }
}

pub struct Account {
    pub conf: Mutex<Value>,
    pub id: String,
    pub hub: Arc<Hub>,
    pub gmail: bool,
    fgq: Mutex<Option<Sender<Option<Op>>>>,
    bgq: Mutex<Option<Sender<Option<Op>>>>,
    pub stopped: AtomicBool,
    wake: (Mutex<bool>, Condvar),
    pub watch: Mutex<HashSet<String>>,
    pub auth_failed: AtomicBool,
    pub status: Mutex<(String, String)>,
    idle_sock: Mutex<Option<TcpStream>>,
}

impl Account {
    pub fn new(conf: &Value, hub: Arc<Hub>) -> Arc<Account> {
        Arc::new(Account {
            conf: Mutex::new(conf.clone()),
            id: conf["id"].as_str().unwrap_or("").to_string(),
            hub,
            gmail: accounts::is_gmail(conf),
            fgq: Mutex::new(None),
            bgq: Mutex::new(None),
            stopped: AtomicBool::new(false),
            wake: (Mutex::new(false), Condvar::new()),
            watch: Mutex::new(HashSet::new()),
            auth_failed: AtomicBool::new(false),
            status: Mutex::new(("connecting".into(), String::new())),
            idle_sock: Mutex::new(None),
        })
    }

    pub fn conf(&self) -> Value {
        self.conf.lock().unwrap().clone()
    }

    // ---------------------------------------------------------------- plumbing
    pub fn start(self: &Arc<Self>) {
        let (ftx, frx) = channel();
        let (btx, brx) = channel();
        *self.fgq.lock().unwrap() = Some(ftx);
        *self.bgq.lock().unwrap() = Some(btx);
        for (rx, name) in [(frx, "fg"), (brx, "bg")] {
            let me = self.clone();
            std::thread::Builder::new().name(format!("{}-{name}", self.id)).spawn(move || me.loop_(rx, name)).ok();
        }
        let me = self.clone();
        std::thread::Builder::new().name(format!("{}-idle", self.id)).spawn(move || me.idle_loop()).ok();
        self.bg(Op::Refresh { full: true });
    }

    pub fn stop(&self) {
        self.stopped.store(true, Ordering::SeqCst);
        self.wake_up();
        for q in [&self.fgq, &self.bgq] {
            if let Some(tx) = q.lock().unwrap().as_ref() {
                let _ = tx.send(None);
            }
        }
        if let Some(s) = self.idle_sock.lock().unwrap().take() {
            let _ = s.shutdown(Shutdown::Both);
        }
    }

    fn wake_up(&self) {
        let (m, cv) = &self.wake;
        *m.lock().unwrap() = true;
        cv.notify_all();
    }

    /// stopped.wait(t) / wake.wait(t): returns early when woken
    fn wait(&self, secs: u64, use_wake: bool) {
        let (m, cv) = &self.wake;
        let g = m.lock().unwrap();
        let _ = cv.wait_timeout_while(g, Duration::from_secs(secs), |w| !(*w && use_wake) && !self.stopped.load(Ordering::SeqCst));
        if use_wake {
            *m.lock().unwrap() = false;
        }
    }

    pub fn fg(&self, op: Op) {
        if let Some(tx) = self.fgq.lock().unwrap().as_ref() {
            let _ = tx.send(Some(op));
        }
    }

    pub fn bg(&self, op: Op) {
        if let Some(tx) = self.bgq.lock().unwrap().as_ref() {
            let _ = tx.send(Some(op));
        }
    }

    pub fn emit(&self, typ: &str, kw: Value) {
        let mut m = Map::new();
        m.insert("type".into(), json!(typ));
        m.insert("acc".into(), json!(self.id));
        if let Value::Object(o) = kw {
            for (k, v) in o {
                m.insert(k, v);
            }
        }
        self.hub.emit(Value::Object(m));
    }

    pub fn set_status(&self, state: &str, text: &str) {
        let mut st = self.status.lock().unwrap();
        if st.0 != state || st.1 != text {
            *st = (state.into(), text.into());
            drop(st);
            self.emit("acc-status", json!({"state": state, "text": text}));
        }
    }

    pub fn status_json(&self) -> Value {
        let st = self.status.lock().unwrap();
        json!({"state": st.0, "text": st.1})
    }

    fn loop_(self: Arc<Self>, rx: Receiver<Option<Op>>, name: &str) {
        let mut conn = Conn::new(&self.conf());
        let store = Store::open();
        while !self.stopped.load(Ordering::SeqCst) {
            let Ok(Some(op)) = rx.recv() else { break };
            let (opname, rid) = (op.name(), op.rid());
            if self.auth_failed.load(Ordering::SeqCst) {
                let text = self.status.lock().unwrap().1.clone();
                self.emit("op-failed", json!({"op": opname, "rid": rid, "text": text}));
                continue;
            }
            conn.conf = self.conf();
            match self.dispatch(&mut conn, &store, op) {
                Ok(()) => {
                    let state = self.status.lock().unwrap().0.clone();
                    if name == "bg" && (state == "offline" || state == "connecting") {
                        self.set_status("online", "");
                    }
                }
                Err(OpErr::Auth(e)) => {
                    self.auth_failed.store(true, Ordering::SeqCst);
                    self.set_status("auth", &e);
                    self.emit("op-failed", json!({"op": opname, "rid": rid, "text": e}));
                }
                Err(OpErr::Conn(e)) => {
                    self.set_status("offline", &e);
                    self.emit("op-failed", json!({"op": opname, "rid": rid, "text": format!("Offline: {e}")}));
                    if name == "bg" {
                        self.wait(20, false);
                    }
                }
                Err(OpErr::Other(e)) => {
                    self.hub.log(&format!("{} {opname}: {e}", self.id));
                    self.emit("op-failed", json!({"op": opname, "rid": rid, "text": e}));
                    conn.close();
                }
            }
        }
        conn.close();
    }

    fn dispatch(&self, conn: &mut Conn, store: &Store, op: Op) -> OResult<()> {
        match op {
            Op::Refresh { full } => self.do_refresh(conn, store, full),
            Op::Sync { path } => self.do_sync(conn, store, &path),
            Op::Older { path } => self.do_older(conn, store, &path),
            Op::Open { path, uid, rid, mark } => self.do_open(conn, store, &path, uid, rid, mark),
            Op::FetchRaw { path, uid, then } => self.do_fetchraw(conn, store, &path, uid, then),
            Op::Act { op, path, uids, rid, dest, msgids } => self.do_act(conn, store, &op, &path, &uids, rid, dest, msgids),
            Op::Undo { src, dest, msgids, rid } => self.do_undo(conn, store, &src, &dest, &msgids, rid),
            Op::Search { q, rid, path } => self.do_search(conn, store, &q, rid, path),
            Op::Send { draft, attachments, rid, forward } => self.do_send(conn, store, &draft, &attachments, rid, forward),
            Op::Counts => self.do_counts(conn, store),
        }
    }

    // ---------------------------------------------------------------- folders
    fn do_refresh(&self, conn: &mut Conn, store: &Store, full: bool) -> OResult<()> {
        conn.run(|c| self.sync_folder_list(c, store))?;
        self.set_status("online", "");
        let inbox = store.folder_by_role(&self.id, "inbox");
        let mut todo: Vec<String> = inbox.as_ref().map(|f| vec![s(f, "path")]).unwrap_or_default();
        for p in self.watch.lock().unwrap().iter() {
            if !todo.contains(p) {
                todo.push(p.clone());
            }
        }
        for p in todo {
            if store.folder(&self.id, &p).is_some() {
                conn.run(|c| self.sync_folder(c, store, &p, INITIAL).map(|_| ()))?;
            }
        }
        self.emit_folders(store);
        if let Some(inbox) = &inbox {
            let p = s(inbox, "path");
            conn.run(|c| self.prefetch(c, store, &p))?;
        }
        if full {
            conn.run(|c| self.all_snippets(c, store))?;
        }
        self.hub.write_unread(store);
        Ok(())
    }

    fn do_sync(&self, conn: &mut Conn, store: &Store, path: &str) -> OResult<()> {
        if store.folder(&self.id, path).is_none() {
            conn.run(|c| self.sync_folder_list(c, store))?;
        }
        if store.folder(&self.id, path).is_some() {
            conn.run(|c| self.sync_folder(c, store, path, INITIAL).map(|_| ()))?;
            self.emit_folders(store);
            self.hub.write_unread(store);
        }
        Ok(())
    }

    pub fn sync_folder_list(&self, conn: &mut Conn, store: &Store) -> OResult<()> {
        let d = conn.im()?.simple("LIST \"\" *").map_err(|e| match e {
            ImapError::No(s) => OpErr::Other(format!("LIST failed: {s}")),
            e => e.into(),
        })?;
        let mut items: Vec<Value> = vec![];
        for (flags, delim, name, raw) in ip::parse_list(&Imap::list_lines(&d)) {
            if flags.iter().any(|f| f == "\\noselect" || f == "\\nonexistent") {
                continue;
            }
            let mut role = String::new();
            if raw.eq_ignore_ascii_case("INBOX") {
                role = "inbox".into();
            } else {
                for (f, r) in [
                    ("\\sent", "sent"),
                    ("\\drafts", "drafts"),
                    ("\\trash", "trash"),
                    ("\\junk", "junk"),
                    ("\\archive", "archive"),
                    ("\\all", "all"),
                    ("\\flagged", "flagged"),
                    ("\\important", "important"),
                ] {
                    if flags.iter().any(|x| x == f) {
                        role = r.into();
                        break;
                    }
                }
            }
            let leaf = match &delim {
                Some(dl) if !dl.is_empty() => name.split(dl.as_str()).last().unwrap_or(&name).to_string(),
                _ => name.clone(),
            };
            if role.is_empty() {
                for (r, rx) in name_roles() {
                    if rx.is_match(crate::htmlparser::py_strip(&leaf)) {
                        role = r.to_string();
                        break;
                    }
                }
            }
            let mut fl = flags.clone();
            fl.sort();
            fl.dedup();
            items.push(json!({"path": raw, "name": leaf, "role": role, "delim": delim.unwrap_or_default(), "flags": fl.join(" ")}));
        }
        // one folder per role (the first wins)
        let mut seen = HashSet::new();
        for it in items.iter_mut() {
            let role = it["role"].as_str().unwrap_or("").to_string();
            if !role.is_empty() && !seen.insert(role) {
                it["role"] = json!("");
            }
        }
        store.set_folders(&self.id, &items);
        static STATUS: OnceLock<Regex> = OnceLock::new();
        let sre = STATUS.get_or_init(|| Regex::new(r"(MESSAGES|UNSEEN|UIDNEXT|UIDVALIDITY) (\d+)").unwrap());
        for f in store.folders(&self.id) {
            if s(&f, "role") == "important" {
                continue;
            }
            let path = s(&f, "path");
            let Ok(d) = conn.im()?.simple(&format!("STATUS {} (MESSAGES UNSEEN UIDNEXT UIDVALIDITY)", ip::quote(&path))) else { continue };
            let Some(u) = d.untagged.iter().find(|u| u.kind == "STATUS") else { continue };
            let raw = String::from_utf8_lossy(&u.data).into_owned();
            let m: HashMap<String, i64> = sre.captures_iter(&raw).map(|c| (c[1].to_string(), c[2].parse().unwrap_or(0))).collect();
            store.update_folder(&self.id, &path, &[("total", json!(m.get("MESSAGES").copied().unwrap_or(0))), ("unread", json!(m.get("UNSEEN").copied().unwrap_or(0)))]);
        }
        Ok(())
    }

    pub fn emit_folders(&self, store: &Store) {
        let mut out = vec![];
        for f in store.folders(&self.id) {
            let role = s(&f, "role");
            if role == "important" {
                continue;
            }
            let path = s(&f, "path");
            let delim = s(&f, "delim");
            let mut depth = if delim.is_empty() { 0 } else { path.matches(delim.as_str()).count() };
            let name = role_name(&role).map(String::from).unwrap_or_else(|| s(&f, "name"));
            if (self.gmail && path.starts_with("[Gmail]") && role.is_empty()) || !role.is_empty() {
                depth = 0;
            }
            out.push(json!({"path": path, "name": name, "role": role, "depth": depth, "unread": i(&f, "unread"), "total": i(&f, "total")}));
        }
        self.emit("folders", json!({"items": out}));
    }

    /// New messages, flag changes and deletions for one folder.
    pub fn sync_folder(&self, conn: &mut Conn, store: &Store, path: &str, initial: usize) -> OResult<bool> {
        let mut f = store.folder(&self.id, path).ok_or_else(|| OpErr::Other(format!("no folder {path}")))?;
        let (exists, uidvalidity, uidnext, hms) = conn.select(path, true)?;
        if i(&f, "uidvalidity") != 0 && uidvalidity != 0 && i(&f, "uidvalidity") != uidvalidity {
            store.reset_folder(&self.id, path);
            f = store.folder(&self.id, path).unwrap_or(f);
        }
        let cached = store.uids(&self.id, path);
        let mut changed = false;
        let want: Vec<i64>;
        let server: HashSet<i64>;
        if cached.is_empty() {
            let uids = if exists != 0 { conn.search("ALL")? } else { vec![] };
            want = uids[uids.len().saturating_sub(initial)..].to_vec();
            server = want.iter().copied().collect();
        } else {
            let lo = *cached.iter().min().unwrap();
            server = if exists != 0 { conn.search(&format!("UID {lo}:*"))?.into_iter().collect() } else { HashSet::new() };
            let hi = *cached.iter().max().unwrap();
            let mut w: Vec<i64> = server.iter().copied().filter(|u| *u > hi).collect();
            w.sort();
            want = w;
            let gone: Vec<i64> = cached.difference(&server).copied().collect();
            if !gone.is_empty() {
                store.delete(&self.id, path, &gone);
                changed = true;
            }
            let keep: HashSet<i64> = cached.intersection(&server).copied().collect();
            if !keep.is_empty() {
                let fh = i(&f, "highestmodseq");
                if fh != 0 && hms != 0 {
                    if hms != fh {
                        let rows = conn.fetch(&format!("{lo}:*"), &format!("(UID FLAGS) (CHANGEDSINCE {fh})"))?;
                        changed |= self.apply_flags(store, path, &rows, &keep);
                    }
                } else {
                    let mut k: Vec<i64> = keep.iter().copied().collect();
                    k.sort();
                    for part in chunks(&k, 2000) {
                        let rows = conn.fetch(&uidset(&part), "(UID FLAGS)")?;
                        changed |= self.apply_flags(store, path, &rows, &keep);
                    }
                }
            }
        }
        if !want.is_empty() {
            self.fetch_headers(conn, store, path, &want, true)?;
            changed = true;
        }
        let complete = if (cached.is_empty() && want.len() == server.len() && exists <= want.len() as i64) || i(&f, "complete") != 0 { 1 } else { 0 };
        let mut kw: Vec<(&str, Value)> = vec![("uidvalidity", json!(uidvalidity)), ("uidnext", json!(uidnext)), ("synced", crate::pyjson::f(mime::now())), ("total", json!(exists))];
        if hms != 0 {
            kw.push(("highestmodseq", json!(hms)));
        }
        if cached.is_empty() {
            kw.push(("complete", json!(complete)));
        }
        let unread = match conn.search("UNSEEN") {
            Ok(u) => u.len() as i64,
            Err(OpErr::Other(_)) => store.recount(&self.id, path).1,
            Err(e) => return Err(e),
        };
        kw.push(("unread", json!(unread)));
        store.update_folder(&self.id, path, &kw);
        if s(&f, "role") == "inbox" {
            let copied = self.notify_new(store, path, cached.is_empty() && i(&f, "notified") == 0);
            let mode = self.hub.code_trash_mode();
            if !copied.is_empty() && mode == "now" {
                self.trash_codes(conn, store, path, &copied)?;
            } else if mode == "day" {
                self.cleanup_codes(conn, store, path)?;
            }
        }
        if changed {
            self.emit("changed", json!({"folder": path}));
        }
        Ok(changed)
    }

    /// The code is on the clipboard: its mail goes to the Trash at once (read).
    fn trash_codes(&self, conn: &mut Conn, store: &Store, path: &str, uids: &[i64]) -> OResult<()> {
        let Some(trash) = store.folder_by_role(&self.id, "trash") else { return Ok(()) };
        conn.select(path, false)?;
        conn.uid(&format!("STORE {} +FLAGS.SILENT (\\Seen)", uidset(uids)))?;
        self.move_(conn, path, uids, &s(&trash, "path"))?;
        store.delete(&self.id, path, uids);
        conn.select(path, true)?;
        if let Some(f) = store.folder(&self.id, path) {
            store.update_folder(&self.id, path, &[("unread", json!((i(&f, "unread") - uids.len() as i64).max(0)))]);
        }
        self.emit("changed", json!({"folder": path}));
        self.emit_folders(store);
        self.hub.write_unread(store);
        Ok(())
    }

    /// Login-code mails older than a day go to the Trash.
    fn cleanup_codes(&self, conn: &mut Conn, store: &Store, path: &str) -> OResult<()> {
        let old: Vec<i64> = store
            .db
            .prepare("SELECT uid FROM messages WHERE acc=? AND folder=? AND code!='' AND flagged=0 AND seen=1 AND date<?")
            .and_then(|mut st| st.query_map(rusqlite::params![self.id, path, mime::now() - 86400.0], |r| r.get(0)).map(|it| it.flatten().collect()))
            .unwrap_or_default();
        let trash = store.folder_by_role(&self.id, "trash");
        if let (false, Some(t)) = (old.is_empty(), trash) {
            self.move_(conn, path, &old, &s(&t, "path"))?;
            store.delete(&self.id, path, &old);
            conn.select(path, true)?;
            self.emit("changed", json!({"folder": path}));
        }
        Ok(())
    }

    fn apply_flags(&self, store: &Store, path: &str, rows: &[Fetch], keep: &HashSet<i64>) -> bool {
        let mut upd: Vec<(i64, [bool; 4])> = vec![];
        for r in rows {
            let uid = ip::num_of(r.get(&b"UID".to_vec()));
            let Some(fl) = r.get(&b"FLAGS".to_vec()) else { continue };
            if !keep.contains(&uid) {
                continue;
            }
            let fl: Vec<String> = fl.list().map(|l| l.iter().map(|x| x.text().to_lowercase()).collect()).unwrap_or_default();
            let has = |x: &str| fl.iter().any(|f| f == x);
            upd.push((uid, [has("\\seen"), has("\\flagged"), has("\\answered"), has("\\draft")]));
        }
        if upd.is_empty() {
            return false;
        }
        let before: Vec<Option<Value>> = upd.iter().map(|(u, _)| store.message(&self.id, path, *u)).collect();
        store.set_flags(&self.id, path, &upd);
        upd.iter().zip(before).any(|((_, f), b)| {
            b.is_some_and(|b| b["seen"] != f[0] || b["flagged"] != f[1] || b["answered"] != f[2])
        })
    }

    pub fn fetch_headers(&self, conn: &mut Conn, store: &Store, path: &str, uids: &[i64], snippets: bool) -> OResult<()> {
        let mut items = format!("(UID FLAGS INTERNALDATE RFC822.SIZE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS ({HEADER_FIELDS})]");
        if self.gmail {
            items += " X-GM-THRID";
        }
        items += ")";
        let mut parts: indexmap::IndexMap<String, Vec<(i64, Value)>> = indexmap::IndexMap::new();
        let mut rows_all: Vec<Value> = vec![];
        let mut sorted = uids.to_vec();
        sorted.sort_by(|a, b| b.cmp(a));
        for part in chunks(&sorted, BATCH) {
            let mut rows = vec![];
            for r in conn.fetch(&uidset(&part), &items)? {
                let uid = ip::num_of(r.get(&b"UID".to_vec()));
                if uid == 0 {
                    continue;
                }
                let mut hdr = vec![];
                for (k, v) in &r {
                    if k.starts_with(b"BODY[HEADER") {
                        hdr = v.bytes();
                    }
                }
                let (pnum, pinfo, att) = match r.get(&b"BODYSTRUCTURE".to_vec()) {
                    Some(S::List(bs)) => ip::summarize_structure(bs),
                    _ => (None, None, false),
                };
                let idate = r.get(&b"INTERNALDATE".to_vec()).filter(|v| v.is_truthy()).map(|v| internaldate(&v.text())).unwrap_or(0.0);
                let flags: Vec<String> = r.get(&b"FLAGS".to_vec()).and_then(S::list).map(|l| l.iter().map(S::text).collect()).unwrap_or_default();
                let row = mime::header_row(
                    &hdr,
                    uid,
                    &flags,
                    idate,
                    ip::num_of(r.get(&b"RFC822.SIZE".to_vec())),
                    pnum.as_deref().unwrap_or(""),
                    att,
                    &ip::text_of(r.get(&b"X-GM-THRID".to_vec())),
                );
                rows.push(row);
                if let (Some(n), Some(info)) = (pnum, pinfo) {
                    parts.entry(n).or_default().push((uid, info));
                }
            }
            store.put_messages(&self.id, path, &rows);
            rows_all.extend(rows);
            if uids.len() > BATCH {
                self.emit("changed", json!({"folder": path}));
            }
        }
        let f = store.folder(&self.id, path);
        let pair = |x: &Value| (x[0].as_str().unwrap_or("").to_string(), x[1].as_str().unwrap_or("").to_string());
        if f.is_some_and(|f| s(&f, "role") == "sent") {
            let people: Vec<(String, String)> = rows_all
                .iter()
                .flat_map(|r| r["rcpt"].as_array().cloned().unwrap_or_default().into_iter().chain(r["cc"].as_array().cloned().unwrap_or_default()))
                .map(|x| pair(&x))
                .collect();
            store.add_contacts(&people, true, None);
        } else {
            let people: Vec<(String, String)> =
                rows_all.iter().map(|r| (r["from_name"].as_str().unwrap_or("").to_string(), r["from_addr"].as_str().unwrap_or("").to_string())).collect();
            store.add_contacts(&people, false, None);
        }
        if snippets && !parts.is_empty() {
            self.fetch_snippets(conn, store, path, &parts)?;
        }
        Ok(())
    }

    /// Previews from the first 3 KB of each text part — and login codes found there.
    fn fetch_snippets(&self, conn: &mut Conn, store: &Store, path: &str, parts: &indexmap::IndexMap<String, Vec<(i64, Value)>>) -> OResult<()> {
        for (pnum, items) in parts {
            let infos: HashMap<i64, Value> = items.iter().cloned().collect();
            let mut keys: Vec<i64> = infos.keys().copied().collect();
            keys.sort_by(|a, b| b.cmp(a));
            for part in chunks(&keys, BATCH) {
                let q = format!("SELECT uid, subject FROM messages WHERE acc=? AND folder=? AND uid IN ({})", vec!["?"; part.len()].join(","));
                let mut args: Vec<rusqlite::types::Value> = vec![self.id.clone().into(), path.to_string().into()];
                args.extend(part.iter().map(|u| rusqlite::types::Value::Integer(*u)));
                let subjects: HashMap<i64, String> = store
                    .db
                    .prepare(&q)
                    .and_then(|mut st| {
                        st.query_map(rusqlite::params_from_iter(args), |r| Ok((r.get::<_, i64>(0)?, r.get::<_, Option<String>>(1)?.unwrap_or_default())))
                            .map(|it| it.flatten().collect())
                    })
                    .unwrap_or_default();
                let rows = conn.fetch(&uidset(&part), &format!("(UID BODY.PEEK[{pnum}]<0.3072>)"))?;
                let (mut out, mut found) = (vec![], vec![]);
                for r in rows {
                    let uid = ip::num_of(r.get(&b"UID".to_vec()));
                    let mut data = vec![];
                    for (k, v) in &r {
                        if k.starts_with(b"BODY[") {
                            data = v.bytes();
                        }
                    }
                    if let Some(info) = infos.get(&uid) {
                        let txt = mime::part_text(&data, info);
                        let sn = mime::snippet_of_text(&txt);
                        out.push((uid, if sn.is_empty() { " ".to_string() } else { sn }));
                        if let Some((code, _)) = codes::find(subjects.get(&uid).map(String::as_str).unwrap_or(""), &txt) {
                            found.push((uid, code));
                        }
                    }
                }
                store.set_snippets(&self.id, path, &out);
                if !found.is_empty() {
                    store.set_codes(&self.id, path, &found);
                }
            }
        }
        Ok(())
    }

    /// Snippets missing after a restart (e.g. a sync cut short).
    fn all_snippets(&self, conn: &mut Conn, store: &Store) -> OResult<()> {
        for f in store.folders(&self.id) {
            let path = s(&f, "path");
            let missing = store.missing_snippets(&self.id, &path, 200);
            if missing.is_empty() {
                continue;
            }
            conn.select(&path, false)?;
            let uids: Vec<i64> = missing.iter().map(|m| m.0).collect();
            let mut parts: indexmap::IndexMap<String, Vec<(i64, Value)>> = indexmap::IndexMap::new();
            for part in chunks(&uids, BATCH) {
                for r in conn.fetch(&uidset(&part), "(UID BODYSTRUCTURE)")? {
                    if let Some(S::List(bs)) = r.get(&b"BODYSTRUCTURE".to_vec()) {
                        if let (Some(n), Some(info), _) = ip::summarize_structure(bs) {
                            parts.entry(n).or_default().push((ip::num_of(r.get(&b"UID".to_vec())), info));
                        }
                    }
                }
            }
            self.fetch_snippets(conn, store, &path, &parts)?;
            self.emit("changed", json!({"folder": path}));
        }
        Ok(())
    }

    /// Keep the newest inbox messages' bodies on disk so they open instantly.
    fn prefetch(&self, conn: &mut Conn, store: &Store, path: &str) -> OResult<()> {
        let rows = store.list(&self.id, path, PREFETCH);
        let todo: Vec<i64> = rows.iter().map(|r| r["uid"].as_i64().unwrap_or(0)).filter(|u| !body_path(&self.id, path, *u).exists()).collect();
        if todo.is_empty() {
            return Ok(());
        }
        conn.select(path, false)?;
        for part in chunks(&todo, 10) {
            let rows = conn.fetch(&uidset(&part), "(UID RFC822.SIZE)")?;
            let small: Vec<i64> = rows.iter().filter(|r| ip::num_of(r.get(&b"RFC822.SIZE".to_vec())) < 2_000_000).map(|r| ip::num_of(r.get(&b"UID".to_vec()))).collect();
            if !small.is_empty() {
                self.fetch_bodies(conn, path, &small)?;
            }
        }
        Ok(())
    }

    fn fetch_bodies(&self, conn: &mut Conn, path: &str, uids: &[i64]) -> OResult<HashSet<i64>> {
        let mut got = HashSet::new();
        for r in conn.fetch(&uidset(uids), "(UID BODY.PEEK[])")? {
            let uid = ip::num_of(r.get(&b"UID".to_vec()));
            if let (true, Some(raw)) = (uid != 0, r.get(&b"BODY[]".to_vec()).filter(|v| !matches!(v, S::Nil))) {
                let p = body_path(&self.id, path, uid);
                if let Some(d) = p.parent() {
                    let _ = std::fs::create_dir_all(d);
                }
                let tmp = p.with_extension("eml.tmp");
                std::fs::write(&tmp, raw.bytes())?;
                std::fs::rename(&tmp, &p)?;
                got.insert(uid);
            }
        }
        Ok(got)
    }

    fn do_older(&self, conn: &mut Conn, store: &Store, path: &str) -> OResult<()> {
        conn.run(|c| {
            c.select(path, false)?;
            let lo = store.min_uid(&self.id, path);
            if lo == 0 {
                return self.sync_folder(c, store, path, INITIAL).map(|_| ());
            }
            let uids: Vec<i64> = if lo > 1 { c.search(&format!("UID 1:{}", lo - 1))?.into_iter().filter(|u| *u < lo).collect() } else { vec![] };
            let want = uids[uids.len().saturating_sub(PAGE)..].to_vec();
            if !want.is_empty() {
                self.fetch_headers(c, store, path, &want, true)?;
            }
            if uids.len() <= PAGE {
                store.update_folder(&self.id, path, &[("complete", json!(1))]);
            }
            self.emit("changed", json!({"folder": path, "older": true, "complete": uids.len() <= PAGE}));
            Ok(())
        })
    }

    // ---------------------------------------------------------------- new mail
    pub fn notify_new(&self, store: &Store, path: &str, first: bool) -> Vec<i64> {
        let Some(f) = store.folder(&self.id, path) else { return vec![] };
        let top = store.max_uid(&self.id, path);
        let notified = i(&f, "notified");
        if first || notified == 0 {
            store.update_folder(&self.id, path, &[("notified", json!(top))]);
            return vec![];
        }
        if top <= notified {
            return vec![];
        }
        // claim the range atomically, so the app and the watcher never both notify
        let n = store.db.execute("UPDATE folders SET notified=? WHERE acc=? AND path=? AND notified=?", rusqlite::params![top, self.id, path, notified]).unwrap_or(0);
        if n != 1 {
            return vec![];
        }
        let rows: Vec<Map<String, Value>> = store
            .db
            .prepare("SELECT * FROM messages WHERE acc=? AND folder=? AND uid>? AND seen=0 ORDER BY uid")
            .and_then(|mut st| {
                st.query_map(rusqlite::params![self.id, path, notified], |r| {
                    let mut m = Map::new();
                    for name in r.as_ref().column_names() {
                        let v = match r.get_ref(name) {
                            Ok(rusqlite::types::ValueRef::Integer(x)) => json!(x),
                            Ok(rusqlite::types::ValueRef::Real(x)) => json!(x),
                            Ok(rusqlite::types::ValueRef::Text(t)) => json!(String::from_utf8_lossy(t)),
                            _ => Value::Null,
                        };
                        m.insert(name.to_string(), v);
                    }
                    Ok(m)
                })
                .map(|it| it.flatten().collect())
            })
            .unwrap_or_default();
        if rows.is_empty() {
            return vec![];
        }
        self.hub.notify(&self.conf(), path, &rows)
    }

    fn idle_loop(self: Arc<Self>) {
        let mut backoff = 15;
        while !self.stopped.load(Ordering::SeqCst) {
            if self.auth_failed.load(Ordering::SeqCst) {
                self.wait(30, false);
                continue;
            }
            let res: OResult<()> = (|| {
                let mut c = imap_connect(&self.conf(), 60)?;
                *self.idle_sock.lock().unwrap() = c.shutdown_handle().ok();
                if self.stopped.load(Ordering::SeqCst) {
                    c.logout();
                    return Ok(());
                }
                if !c.has("IDLE") {
                    c.logout();
                    *self.idle_sock.lock().unwrap() = None;
                    self.wait(self.hub.poll_seconds(), true);
                    if !self.stopped.load(Ordering::SeqCst) {
                        self.bg(Op::Refresh { full: false });
                    }
                    return Ok(());
                }
                c.select("INBOX", true)?;
                backoff = 15;
                while !self.stopped.load(Ordering::SeqCst) {
                    let hit = c.idle(Duration::from_secs(9 * 60))?;
                    if self.stopped.load(Ordering::SeqCst) {
                        break;
                    }
                    if hit {
                        self.bg(Op::Sync { path: "INBOX".into() });
                    } else {
                        self.bg(Op::Refresh { full: false });
                    }
                    c.simple("NOOP")?;
                }
                c.logout();
                Ok(())
            })();
            *self.idle_sock.lock().unwrap() = None;
            match res {
                Ok(()) => {}
                Err(OpErr::Auth(_)) => self.wait(60, false),
                Err(e) => {
                    if self.stopped.load(Ordering::SeqCst) {
                        break;
                    }
                    self.hub.log(&format!("{} idle: {e}", self.id));
                    self.wait(backoff, false);
                    backoff = (backoff * 2).min(300);
                }
            }
        }
    }

    // ---------------------------------------------------------------- opening a message
    fn do_open(&self, conn: &mut Conn, store: &Store, path: &str, uid: i64, rid: Value, mark: bool) -> OResult<()> {
        let p = body_path(&self.id, path, uid);
        if !p.exists() {
            let got = conn.run(|c| {
                c.select(path, false)?;
                self.fetch_bodies(c, path, &[uid])
            })?;
            if !got.contains(&uid) {
                self.emit("msg", json!({"rid": rid, "folder": path, "uid": uid, "error": "This message is no longer on the server."}));
                return Ok(());
            }
        }
        let raw = std::fs::read(&p)?;
        let colors = self.hub.colors.lock().unwrap().clone();
        let mut v = mime::view(&raw, &colors);
        self.hub.prepare_images(&self.id, &raw, &mut v);
        let row = store.message(&self.id, path, uid);
        v["thread"] = json!([]);
        if let Some(r) = &row {
            let msgid = r["msgid"].as_str().unwrap_or("");
            let others: Vec<Value> = store
                .thread(&self.id, r["thrid"].as_str().unwrap_or(""), msgid, v["refs"].as_str().unwrap_or(""))
                .into_iter()
                .filter(|m| m["msgid"].as_str().unwrap_or("") != msgid)
                .collect();
            let start = others.len().saturating_sub(20);
            v["thread"] = Value::Array(others[start..].to_vec());
        }
        let from_addr = v["from"].get(0).and_then(|x| x.get(1)).and_then(Value::as_str).unwrap_or("").to_string();
        v["showImages"] = json!(self.hub.images_allowed(&from_addr));
        let code = codes::find(v["subject"].as_str().unwrap_or(""), &mime::text_of(&raw)).map(|c| c.0).unwrap_or_default();
        v["code"] = json!(code);
        let seen = row.as_ref().map(|r| r["seen"] == true);
        self.emit("msg", json!({"rid": rid, "folder": path, "uid": uid, "view": v, "row": row}));
        if mark && seen == Some(false) {
            self.do_flag(conn, store, &[uid], path, "seen", true, false)?;
        }
        Ok(())
    }

    pub fn body(&self, path: &str, uid: i64) -> Option<Vec<u8>> {
        std::fs::read(body_path(&self.id, path, uid)).ok()
    }

    fn do_fetchraw(&self, conn: &mut Conn, _store: &Store, path: &str, uid: i64, then: Box<dyn FnOnce(Option<Vec<u8>>) + Send>) -> OResult<()> {
        let mut raw = self.body(path, uid);
        if raw.is_none() {
            let r = conn.run(|c| {
                c.select(path, false)?;
                self.fetch_bodies(c, path, &[uid])
            });
            if let Err(e) = r {
                then(None);
                return Err(e);
            }
            raw = self.body(path, uid);
        }
        then(raw);
        Ok(())
    }

    // ---------------------------------------------------------------- actions
    #[allow(clippy::too_many_arguments)]
    pub fn do_flag(&self, conn: &mut Conn, store: &Store, uids: &[i64], path: &str, what: &str, on: bool, quiet: bool) -> OResult<()> {
        let flag = match what {
            "seen" => "\\Seen",
            "flagged" => "\\Flagged",
            _ => "\\Answered",
        };
        conn.run(|c| {
            c.select(path, false)?;
            c.uid(&format!("STORE {} {} ({flag})", uidset(uids), if on { "+FLAGS.SILENT" } else { "-FLAGS.SILENT" }))?;
            Ok(())
        })?;
        store.set_flag(&self.id, path, uids, what, on);
        if what == "seen" {
            if let Some(f) = store.folder(&self.id, path) {
                let d = if on { -(uids.len() as i64) } else { uids.len() as i64 };
                store.update_folder(&self.id, path, &[("unread", json!((i(&f, "unread") + d).max(0)))]);
            }
            self.emit_folders(store);
            self.hub.write_unread(store);
        }
        if !quiet {
            self.emit("changed", json!({"folder": path}));
        }
        Ok(())
    }

    fn target(&self, conn: &mut Conn, store: &Store, role: &str) -> OResult<Option<String>> {
        if let Some(f) = store.folder_by_role(&self.id, role) {
            return Ok(Some(s(&f, "path")));
        }
        if role == "archive" && self.gmail {
            if let Some(f) = store.folder_by_role(&self.id, "all") {
                return Ok(Some(s(&f, "path")));
            }
        }
        let name = match role {
            "archive" => "Archive",
            "trash" => "Trash",
            "junk" => "Spam",
            _ => return Ok(None),
        };
        let r = conn.run(|c| {
            let q = ip::quote(name);
            c.im()?.simple(&format!("CREATE {q}"))?;
            let _ = c.im()?.simple(&format!("SUBSCRIBE {q}"));
            Ok(())
        });
        match r {
            Ok(()) | Err(OpErr::Other(_)) => {}
            Err(e) => return Err(e),
        }
        conn.run(|c| self.sync_folder_list(c, store))?;
        if let Some(f) = store.folder(&self.id, name) {
            if s(&f, "role").is_empty() {
                store.update_folder(&self.id, name, &[("role", json!(role))]);
            }
        }
        self.emit_folders(store);
        Ok(Some(name.to_string()))
    }

    pub fn move_(&self, conn: &mut Conn, path: &str, uids: &[i64], dest: &str) -> OResult<()> {
        conn.run(|c| {
            c.select(path, false)?;
            let set = uidset(uids);
            if c.has("MOVE") {
                c.uid(&format!("MOVE {set} {}", ip::quote(dest)))?;
            } else {
                c.uid(&format!("COPY {set} {}", ip::quote(dest)))?;
                c.uid(&format!("STORE {set} +FLAGS.SILENT (\\Deleted)"))?;
                if c.has("UIDPLUS") {
                    c.uid(&format!("EXPUNGE {set}"))?;
                } else {
                    c.im()?.simple("EXPUNGE")?;
                }
            }
            Ok(())
        })
    }

    /// archive / trash / spam / notspam / move / delete (forever) / seen / unseen / flag / unflag
    #[allow(clippy::too_many_arguments)]
    fn do_act(&self, conn: &mut Conn, store: &Store, op: &str, path: &str, uids: &[i64], rid: Value, dest: Option<String>, msgids: Vec<String>) -> OResult<()> {
        if ["seen", "unseen", "flag", "unflag"].contains(&op) {
            let what = if op == "seen" || op == "unseen" { "seen" } else { "flagged" };
            self.do_flag(conn, store, uids, path, what, op == "seen" || op == "flag", false)?;
            self.emit("acted", json!({"rid": rid, "op": op, "folder": path, "uids": uids}));
            return Ok(());
        }
        let role = store.folder(&self.id, path).map(|f| s(&f, "role")).unwrap_or_default();
        let mut dest = dest;
        if op == "delete" || (op == "trash" && role == "trash") {
            conn.run(|c| {
                c.select(path, false)?;
                let set = uidset(uids);
                c.uid(&format!("STORE {set} +FLAGS.SILENT (\\Deleted)"))?;
                if c.has("UIDPLUS") {
                    c.uid(&format!("EXPUNGE {set}"))?;
                } else {
                    c.im()?.simple("EXPUNGE")?;
                }
                Ok(())
            })?;
            store.delete(&self.id, path, uids);
            dest = None;
        } else {
            if op == "notspam" {
                dest = Some(store.folder_by_role(&self.id, "inbox").map(|f| s(&f, "path")).unwrap_or_else(|| "INBOX".into()));
            } else if op != "move" {
                let role = match op {
                    "archive" => "archive",
                    "trash" => "trash",
                    "spam" => "junk",
                    _ => return Err(OpErr::Other(format!("'{op}'"))),
                };
                dest = self.target(conn, store, role)?;
            }
            match &dest {
                Some(d) if d != path && !d.is_empty() => {
                    self.move_(conn, path, uids, d)?;
                    store.delete(&self.id, path, uids);
                }
                _ => {
                    self.emit("acted", json!({"rid": rid, "op": op, "folder": path, "uids": [], "text": "Nothing to do here"}));
                    return Ok(());
                }
            }
        }
        self.emit("acted", json!({"rid": rid, "op": op, "folder": path, "uids": uids, "dest": dest.clone().unwrap_or_default(), "msgids": msgids}));
        self.emit("changed", json!({"folder": path}));
        match dest {
            Some(d) => {
                if self.watch.lock().unwrap().contains(&d) {
                    self.bg(Op::Sync { path: d });
                } else {
                    self.bg(Op::Counts);
                }
            }
            None => self.bg(Op::Counts),
        }
        Ok(())
    }

    fn do_counts(&self, conn: &mut Conn, store: &Store) -> OResult<()> {
        conn.run(|c| self.sync_folder_list(c, store))?;
        self.emit_folders(store);
        self.hub.write_unread(store);
        Ok(())
    }

    /// Move messages back from dest to src, found by Message-ID.
    fn do_undo(&self, conn: &mut Conn, store: &Store, src: &str, dest: &str, msgids: &[String], rid: Value) -> OResult<()> {
        let uids = conn.run(|c| {
            c.select(dest, true)?;
            let mut uids = vec![];
            for mid in msgids.iter().filter(|m| !m.is_empty()) {
                uids.extend(c.search(&format!("HEADER Message-ID {}", ip::quote(mid)))?);
            }
            Ok(uids)
        })?;
        if !uids.is_empty() {
            self.move_(conn, dest, &uids, src)?;
            store.delete(&self.id, dest, &uids);
            conn.run(|c| self.sync_folder(c, store, src, INITIAL).map(|_| ()))?;
            self.emit("changed", json!({"folder": dest}));
        }
        self.emit("undone", json!({"rid": rid, "n": uids.len(), "folder": src}));
        self.bg(Op::Counts);
        Ok(())
    }

    // ---------------------------------------------------------------- search
    fn do_search(&self, conn: &mut Conn, store: &Store, q: &str, rid: Value, path: Option<String>) -> OResult<()> {
        let folders: Vec<String> = if self.gmail {
            vec![store.folder_by_role(&self.id, "all").map(|f| s(&f, "path")).unwrap_or_else(|| "INBOX".into())]
        } else if let Some(p) = path {
            vec![p]
        } else {
            ["inbox", "sent", "archive"].iter().filter_map(|r| store.folder_by_role(&self.id, r).map(|f| s(&f, "path"))).collect()
        };
        let mut results = conn.run(|c| {
            let mut out = vec![];
            for p in &folders {
                c.select(p, false)?;
                let mut uids = if self.gmail {
                    c.search_lit("CHARSET UTF-8 X-GM-RAW", q.as_bytes())?
                } else {
                    match c.search_lit("CHARSET UTF-8 TEXT", q.as_bytes()) {
                        Ok(u) => u,
                        Err(OpErr::Other(_)) => {
                            let ascii: String = q.chars().filter(char::is_ascii).collect();
                            c.search(&format!("TEXT {}", ip::quote(&ascii)))?
                        }
                        Err(e) => return Err(e),
                    }
                };
                uids.sort();
                let uids = uids[uids.len().saturating_sub(60)..].to_vec();
                if uids.is_empty() {
                    continue;
                }
                let items = format!(
                    "(UID FLAGS INTERNALDATE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS ({HEADER_FIELDS})]{}",
                    if self.gmail { " X-GM-THRID)" } else { ")" }
                );
                for r in c.fetch(&uidset(&uids), &items)? {
                    let uid = ip::num_of(r.get(&b"UID".to_vec()));
                    let hdr = r.iter().find(|(k, _)| k.starts_with(b"BODY[HEADER")).map(|(_, v)| v.bytes()).unwrap_or_default();
                    let (pnum, _, att) = match r.get(&b"BODYSTRUCTURE".to_vec()) {
                        Some(S::List(bs)) => ip::summarize_structure(bs),
                        _ => (None, None, false),
                    };
                    let flags: Vec<String> = r.get(&b"FLAGS".to_vec()).and_then(S::list).map(|l| l.iter().map(S::text).collect()).unwrap_or_default();
                    let mut row = mime::header_row(&hdr, uid, &flags, 0.0, 0, pnum.as_deref().unwrap_or(""), att, &ip::text_of(r.get(&b"X-GM-THRID".to_vec())));
                    let cached = store.message(&self.id, p, uid);
                    row["snippet"] = cached.map(|m| m["snippet"].clone()).unwrap_or(json!(""));
                    row["acc"] = json!(self.id);
                    row["folder"] = json!(p);
                    out.push(row);
                }
            }
            Ok(out)
        })?;
        results.sort_by(|a, b| b["date"].as_f64().unwrap_or(0.0).total_cmp(&a["date"].as_f64().unwrap_or(0.0)));
        for r in results.iter_mut() {
            if let Some(o) = r.as_object_mut() {
                for k in ["cc", "refs", "part", "size", "draft"] {
                    o.shift_remove(k);
                }
            }
        }
        results.truncate(100);
        self.emit("search", json!({"rid": rid, "items": results}));
        Ok(())
    }

    // ---------------------------------------------------------------- sending
    fn do_send(&self, conn: &mut Conn, store: &Store, draft: &Value, attachments: &[String], rid: Value, forward: Option<Value>) -> OResult<()> {
        let mut fwd: Vec<(String, String, Vec<u8>)> = vec![];
        if let Some(fw) = &forward {
            let folder = fw["folder"].as_str().unwrap_or("").to_string();
            let uid = fw["uid"].as_i64().or_else(|| fw["uid"].as_str().and_then(|s| s.parse().ok())).unwrap_or(0);
            let mut raw = self.body(&folder, uid);
            if raw.is_none() {
                conn.run(|c| {
                    c.select(&folder, false)?;
                    self.fetch_bodies(c, &folder, &[uid])
                })?;
                raw = self.body(&folder, uid);
            }
            if let Some(raw) = raw {
                if let Some(m) = mime::parse(&raw) {
                    for k in fw["keep"].as_array().cloned().unwrap_or_default() {
                        if let Some((name, ctype, data)) = mime::attachment_bytes(&m, k.as_u64().unwrap_or(u64::MAX) as usize) {
                            fwd.push((name, ctype, data));
                        }
                    }
                }
            }
        }
        let conf = self.conf();
        let (msg, rcpts) = mime::build(&conf, draft, attachments, &fwd)?;
        if rcpts.is_empty() {
            self.emit("sent", json!({"rid": rid, "ok": false, "text": "Add at least one recipient."}));
            return Ok(());
        }
        let mut sm = smtp_connect(&conf)?;
        let r = sm.send(conf["email"].as_str().unwrap_or(""), &rcpts, &msg);
        sm.quit();
        r.map_err(|e| OpErr::Other(e.to_string()))?;
        let ds = |k: &str| draft[k].as_str().unwrap_or("").to_string();
        store.add_contacts(&mime::parse_rcpt(&format!("{},{},{}", ds("to"), ds("cc"), ds("bcc"))), true, None);
        self.emit("sent", json!({"rid": rid, "ok": true}));
        // a copy in Sent (Gmail files it by itself), and \Answered on the original
        let after: OResult<()> = (|| {
            if !self.gmail {
                if let Some(sent) = store.folder_by_role(&self.id, "sent") {
                    let p = s(&sent, "path");
                    conn.run(|c| {
                        c.im()?.append(&ip::quote(&p), "(\\Seen)", &time2internaldate(mime::now()), &msg)?;
                        Ok(())
                    })?;
                }
            }
            if let Some(rt) = draft.get("replyTo").filter(|v| v.is_object()) {
                let uid = rt["uid"].as_i64().unwrap_or(0);
                self.do_flag(conn, store, &[uid], rt["folder"].as_str().unwrap_or(""), "answered", true, true)?;
            }
            Ok(())
        })();
        if let Err(e) = after {
            self.hub.log(&format!("{} after-send: {e}", self.id));
        }
        self.bg(Op::Counts);
        if let Some(sent) = store.folder_by_role(&self.id, "sent") {
            let p = s(&sent, "path");
            if self.watch.lock().unwrap().contains(&p) {
                self.bg(Op::Sync { path: p });
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn uidset() {
        assert_eq!(super::uidset(&[5, 1, 2, 3, 9, 10]), "1:3,5,9:10");
    }
    #[test]
    fn internaldate() {
        assert_eq!(super::internaldate("12-Oct-2026 10:00:00 +0300"), 1791788400.0);
    }
}
