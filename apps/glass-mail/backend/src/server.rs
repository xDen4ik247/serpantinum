//! The window's backend (port of server.py): JSON lines on stdin/stdout between the quickshell
//! window and the mail accounts.
use crate::accounts;
use crate::ai::{self, Ai};
use crate::engine::{self, Account, Op, OpErr};
use crate::hub::{self, Hub};
use crate::mime;
use crate::paths;
use crate::pyjson;
use crate::store::Store;
use regex::Regex;
use serde_json::{json, Map, Value};
use std::collections::HashSet;
use std::io::BufRead;
use std::sync::{Arc, OnceLock};

thread_local! {
    static STORE: std::cell::RefCell<Option<Store>> = const { std::cell::RefCell::new(None) };
}

/// This thread's cache connection.
pub fn with_store<T>(f: impl FnOnce(&Store) -> T) -> T {
    STORE.with(|s| {
        let mut s = s.borrow_mut();
        if s.is_none() {
            *s = Some(Store::open());
        }
        f(s.as_ref().unwrap())
    })
}

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

fn bulk() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"(?i)(no-?reply|do-?not-?reply|notifications?|mailer|news(letter)?|info|support|hello|team|updates?|alerts?|billing|marketing|digest|bounce)@").unwrap())
}

/// people / updates / news — instant, from the headers (no AI)
pub fn category(r: &Value, mine: &HashSet<String>) -> &'static str {
    let addr = r["from_addr"].as_str().unwrap_or("").to_lowercase();
    if truthy(&r["code"]) {
        "updates"
    } else if mine.contains(&addr) {
        "people"
    } else if truthy(&r["unsub"]) {
        "news"
    } else if bulk().is_match(&addr) {
        "updates"
    } else {
        "people"
    }
}

fn unique_path(d: &std::path::Path, name: &str) -> std::path::PathBuf {
    let clean = crate::htmlparser::py_strip(&name.replace(['/', '\0'], "_")).to_string();
    let name = if clean.is_empty() { "attachment".to_string() } else { clean };
    let (base, ext) = match name.rfind('.') {
        Some(i) if i > 0 => (name[..i].to_string(), name[i..].to_string()),
        _ => (name.clone(), String::new()),
    };
    let mut p = d.join(&name);
    let mut i = 2;
    while p.exists() {
        p = d.join(format!("{base} ({i}){ext}"));
        i += 1;
    }
    p
}

fn xdg_open(p: &str) {
    use std::os::unix::process::CommandExt;
    let _ = std::process::Command::new("xdg-open")
        .arg(p)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .process_group(0)
        .spawn()
        .map(|mut c| std::thread::spawn(move || c.wait()));
}

// ---------------------------------------------------------------- local drafts (the open compose, autosaved)
fn draft_id_ok(d: &str) -> bool {
    !d.is_empty() && d.chars().all(|c| c.is_alphanumeric() || c == '_' || c == '-')
}

fn load_drafts() -> Vec<Value> {
    let mut names: Vec<String> = std::fs::read_dir(paths::drafts())
        .map(|d| d.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).filter(|n| n.ends_with(".json")).collect())
        .unwrap_or_default();
    names.sort();
    let mut out = vec![];
    for n in names {
        let Ok(t) = std::fs::read_to_string(paths::drafts().join(&n)) else { return out };
        let Ok(mut d) = serde_json::from_str::<Value>(&t) else { return out };
        d["id"] = json!(n[..n.len() - 5]);
        out.push(d);
    }
    out
}

fn save_draft(did: &Value, data: &Value) {
    let did = match did {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    };
    if !draft_id_ok(&did) {
        return;
    }
    let p = paths::drafts().join(format!("{did}.json"));
    let tmp = p.with_extension("json.tmp");
    if std::fs::write(&tmp, pyjson::dumps(data, false)).is_ok() {
        let _ = std::fs::rename(&tmp, &p);
    }
}

fn drop_draft(did: Option<&Value>) {
    let Some(did) = did.filter(|d| truthy(d)) else { return };
    let did = match did {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    };
    if draft_id_ok(&did) {
        let _ = std::fs::remove_file(paths::drafts().join(format!("{did}.json")));
    }
}

const STOP: &str = "the and for that with from what when where which who how did does was were are is about this have has \
mail email emails письмо письма почта что где когда кто как это был была были про мне меня мой моя есть или для from was any all last";

pub struct Server {
    pub hub: Arc<Hub>,
}

fn num(v: &Value) -> i64 {
    v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)).or_else(|| v.as_str().and_then(|s| s.trim().parse().ok())).unwrap_or(0)
}

fn st(v: &Value, k: &str) -> String {
    v[k].as_str().unwrap_or("").to_string()
}

impl Server {
    pub fn new() -> Server {
        Server { hub: Hub::new(false) }
    }

    fn acc(&self, aid: &str) -> Result<Arc<Account>, String> {
        self.hub.accounts.lock().unwrap().get(aid).cloned().ok_or_else(|| format!("'no account {aid}'"))
    }

    fn ai(&self) -> Arc<Ai> {
        let h = self.hub.clone();
        let h2 = self.hub.clone();
        self.hub.ai.get_or_init(|| Ai::new(Box::new(move |v| h.emit(v)), Box::new(move |m| h2.log(m)))).clone()
    }

    // ---------------------------------------------------------------- accounts
    fn start_accounts(&self) {
        for conf in accounts::load() {
            self.start_account(&conf);
        }
    }

    fn start_account(&self, conf: &Value) -> Arc<Account> {
        let id = st(conf, "id");
        if let Some(old) = self.hub.accounts.lock().unwrap().shift_remove(&id) {
            old.stop();
        }
        let a = Account::new(conf, self.hub.clone());
        self.hub.accounts.lock().unwrap().insert(id, a.clone());
        a.start();
        a
    }

    fn send_accounts(&self) {
        let confs = accounts::load();
        let accs = self.hub.accounts.lock().unwrap().clone();
        let items: Vec<Value> = confs
            .iter()
            .map(|c| {
                let mut p = accounts::public(c);
                p["status"] = accs.get(&st(c, "id")).map(|a| a.status_json()).unwrap_or(json!({}));
                p
            })
            .collect();
        self.hub.emit(json!({"type": "accounts", "items": items}));
        with_store(|s| {
            for c in &confs {
                if let Some(a) = accs.get(&st(c, "id")) {
                    a.emit_folders(s);
                }
            }
        });
    }

    /// Add or edit an account: check the login first, then save and start it.
    fn account_save(self: &Arc<Self>, d: Value, rid: Value) {
        let me = self.clone();
        std::thread::spawn(move || {
            let confs = accounts::load();
            let email = crate::htmlparser::py_strip(&st(&d, "email")).to_string();
            let aid = d["id"].as_str().filter(|s| !s.is_empty()).map(String::from).unwrap_or_else(|| accounts::account_id(&email));
            let old = confs.iter().find(|c| c["id"] == aid.as_str()).cloned().unwrap_or(json!({}));
            let g = accounts::guess(&email);
            let user = crate::htmlparser::py_strip(d["user"].as_str().unwrap_or("")).to_string();
            let pick = |a: &Value, b: &Value| if truthy(a) { a.clone() } else { b.clone() };
            let conf = json!({
                "id": aid, "email": email, "name": crate::htmlparser::py_strip(&st(&d, "name")),
                "user": if user.is_empty() { email.clone() } else { user },
                "password": pick(&d["password"], &json!(old["password"].as_str().unwrap_or(""))),
                "provider": g["provider"],
                "imap": {"host": pick(&d["imapHost"], &g["imap"]["host"]), "port": num(&pick(&d["imapPort"], &g["imap"]["port"]))},
                "smtp": {"host": pick(&d["smtpHost"], &g["smtp"]["host"]), "port": num(&pick(&d["smtpPort"], &g["smtp"]["port"])),
                         "security": pick(&d["smtpSecurity"], &g["smtp"]["security"])},
                "signature": d.get("signature").cloned().unwrap_or_else(|| old.get("signature").cloned().unwrap_or(json!(""))),
                "color": pick(&old["color"], &json!(accounts::COLORS[confs.len() % accounts::COLORS.len()])),
            });
            let n = match engine::test_account(&conf) {
                Ok(n) => n,
                Err(OpErr::Auth(e)) | Err(OpErr::Conn(e)) => {
                    me.hub.emit(json!({"type": "account-saved", "rid": rid, "ok": false, "text": e}));
                    return;
                }
                Err(OpErr::Other(e)) => {
                    me.hub.emit(json!({"type": "account-saved", "rid": rid, "ok": false, "text": format!("Sign-in failed: {e}")}));
                    return;
                }
            };
            let mut confs = accounts::load();
            match confs.iter().position(|c| c["id"] == aid.as_str()) {
                None => confs.push(conf.clone()),
                Some(i) => confs[i] = conf.clone(),
            }
            if let Err(e) = accounts::save(&confs) {
                me.hub.emit(json!({"type": "account-saved", "rid": rid, "ok": false, "text": format!("Sign-in failed: {e}")}));
                return;
            }
            me.start_account(&conf);
            me.hub.emit(json!({"type": "account-saved", "rid": rid, "ok": true, "id": aid, "folders": n}));
            me.send_accounts();
        });
    }

    /// Name / signature edits that don't need a new sign-in.
    fn account_update(&self, aid: &str, fields: &Value) {
        let mut confs = accounts::load();
        let mut changed = false;
        for c in confs.iter_mut() {
            if c["id"] == aid {
                for k in ["name", "signature", "color"] {
                    if let Some(v) = fields.get(k) {
                        c[k] = v.clone();
                    }
                }
                changed = true;
                if let Some(a) = self.hub.accounts.lock().unwrap().get(aid) {
                    let mut conf = a.conf.lock().unwrap();
                    for k in ["name", "signature", "color"] {
                        if let Some(v) = c.get(k) {
                            conf[k] = v.clone();
                        }
                    }
                }
            }
        }
        if changed {
            let _ = accounts::save(&confs);
        }
        self.send_accounts();
    }

    fn account_remove(&self, aid: &str) {
        if let Some(a) = self.hub.accounts.lock().unwrap().shift_remove(aid) {
            a.stop();
        }
        let confs: Vec<Value> = accounts::load().into_iter().filter(|c| c["id"] != aid).collect();
        let _ = accounts::save(&confs);
        with_store(|s| s.drop_account(aid));
        self.send_accounts();
        with_store(|s| self.hub.write_unread(s));
        self.hub.toast("logout", "Account removed from Glass Mail");
    }

    // ---------------------------------------------------------------- lists
    fn send_list(&self, v: &Value, limit: i64, rid: Value) {
        let ids = self.hub.acc_ids();
        let (mut items, complete) = with_store(|s| {
            if v["kind"] == "starred" {
                (s.flagged(&ids, limit), true)
            } else if v["acc"] == "*" {
                let role = v["role"].as_str().unwrap_or("inbox");
                let items = s.list_role(&ids, role, limit);
                let c = (items.len() as i64) < limit;
                (items, c)
            } else {
                let items = s.list(&st(v, "acc"), &st(v, "folder"), limit);
                let f = s.folder(&st(v, "acc"), &st(v, "folder"));
                let c = f.is_some_and(|f| {
                    let g = |k: &str| f.get(k).and_then(Value::as_i64).unwrap_or(0);
                    g("complete") != 0 || (g("total") != 0 && items.len() as i64 >= g("total"))
                });
                (items, c)
            }
        });
        let mine = with_store(|s| s.sent_contacts());
        for r in items.iter_mut() {
            let c = category(r, &mine);
            r["cat"] = json!(c);
        }
        self.hub.emit(json!({"type": "list", "rid": rid, "view": v, "items": items, "complete": complete}));
    }

    /// Keep the folders on screen fresh: sync now if stale, and on every refresh.
    fn watch(&self, v: &Value) {
        let accs = self.hub.accounts.lock().unwrap().clone();
        for a in accs.values() {
            a.watch.lock().unwrap().clear();
        }
        let mut targets: Vec<(Arc<Account>, String)> = vec![];
        with_store(|s| {
            if v["kind"] == "starred" {
                for (aid, a) in &accs {
                    if let Some(f) = s.folder_by_role(aid, "flagged") {
                        targets.push((a.clone(), f["path"].as_str().unwrap_or("").to_string()));
                    }
                }
            } else if v["acc"] == "*" {
                for (aid, a) in &accs {
                    if let Some(f) = s.folder_by_role(aid, v["role"].as_str().unwrap_or("inbox")) {
                        targets.push((a.clone(), f["path"].as_str().unwrap_or("").to_string()));
                    }
                }
            } else if let Some(a) = accs.get(&st(v, "acc")) {
                targets.push((a.clone(), st(v, "folder")));
            }
            for (a, p) in &targets {
                a.watch.lock().unwrap().insert(p.clone());
                let f = s.folder(&a.id, p);
                let synced = f.as_ref().and_then(|f| f.get("synced")).and_then(Value::as_f64).unwrap_or(0.0);
                if f.is_none() || mime::now() - synced > 45.0 {
                    a.bg(Op::Sync { path: p.clone() });
                }
            }
        });
    }

    // ---------------------------------------------------------------- the protocol
    pub fn run(self: Arc<Self>) {
        let pidfile = paths::state().join("app.pid");
        let _ = std::fs::write(&pidfile, std::process::id().to_string());
        let stdin = std::io::stdin();
        for line in stdin.lock().lines() {
            let Ok(line) = line else { break };
            let line = crate::htmlparser::py_strip(&line).to_string();
            if line.is_empty() {
                continue;
            }
            let Ok(c) = serde_json::from_str::<Value>(&line) else { continue };
            if c["cmd"] == "quit" {
                break;
            }
            if let Err(e) = self.handle(&c) {
                self.hub.emit(json!({"type": "error", "error": e, "trace": ""}));
            }
        }
        for a in self.hub.accounts.lock().unwrap().values() {
            a.stop();
        }
        let _ = std::fs::remove_file(pidfile);
    }

    fn handle(self: &Arc<Self>, c: &Value) -> Result<(), String> {
        let h = &self.hub;
        let cmd = c["cmd"].as_str().ok_or("'cmd'")?;
        let rid = c.get("rid").cloned().unwrap_or(json!(0));
        match cmd {
            "hello" => {
                *h.colors.lock().unwrap() = c.get("colors").filter(|x| truthy(x)).cloned().unwrap_or(json!({}));
                let settings = h.settings.lock().unwrap().clone();
                h.emit(json!({"type": "hello", "settings": settings, "downloads": paths::downloads().to_string_lossy(), "drafts": load_drafts()}));
                self.start_accounts();
                self.send_accounts();
                with_store(|s| h.write_unread(s));
            }
            "theme" => *h.colors.lock().unwrap() = c.get("colors").filter(|x| truthy(x)).cloned().unwrap_or(json!({})),
            "list" => {
                let v = c.get("view").ok_or("'view'")?;
                self.send_list(v, c.get("limit").map(num).unwrap_or(300), rid);
                if c.get("watch").is_none_or(truthy) {
                    self.watch(v);
                }
            }
            "older" => {
                let v = &c["view"];
                if truthy(&v["acc"]) && v["acc"] != "*" {
                    self.acc(&st(v, "acc"))?.fg(Op::Older { path: st(v, "folder") });
                }
            }
            "refresh" => {
                for a in h.accounts.lock().unwrap().values() {
                    if truthy(&c["retry"]) {
                        a.auth_failed.store(false, std::sync::atomic::Ordering::SeqCst);
                    }
                    a.bg(Op::Refresh { full: false });
                }
            }
            "open" => {
                let mark = truthy(&h.settings.lock().unwrap().get("markRead").cloned().unwrap_or(json!(true)));
                self.acc(&st(c, "acc"))?.fg(Op::Open { path: st(c, "folder"), uid: num(&c["uid"]), rid, mark });
            }
            "act" => {
                let mut groups: indexmap::IndexMap<(String, String), Vec<Value>> = indexmap::IndexMap::new();
                for it in c["items"].as_array().ok_or("'items'")? {
                    groups.entry((st(it, "acc"), st(it, "folder"))).or_default().push(it.clone());
                }
                for ((aid, folder), its) in groups {
                    self.acc(&aid)?.fg(Op::Act {
                        op: st(c, "op"),
                        path: folder,
                        uids: its.iter().map(|i| num(&i["uid"])).collect(),
                        rid: rid.clone(),
                        dest: c["dest"].as_str().map(String::from),
                        msgids: its.iter().map(|i| st(i, "msgid")).collect(),
                    });
                }
            }
            "undo" => {
                let msgids: Vec<String> = c["msgids"].as_array().map(|a| a.iter().map(|x| x.as_str().unwrap_or("").to_string()).collect()).unwrap_or_default();
                self.acc(&st(c, "acc"))?.fg(Op::Undo { src: st(c, "src"), dest: st(c, "dest"), msgids, rid });
            }
            "search" => {
                let q = crate::htmlparser::py_strip(c["q"].as_str().ok_or("'q'")?).to_string();
                let local = with_store(|s| s.search_local(&h.acc_ids(), &q, 100));
                h.emit(json!({"type": "search", "rid": c["rid"], "local": true, "items": local}));
                if !q.is_empty() && c.get("server").is_none_or(truthy) {
                    for a in h.accounts.lock().unwrap().values() {
                        a.fg(Op::Search { q: q.clone(), rid: c["rid"].clone(), path: None });
                    }
                }
            }
            "contacts" => {
                let items = with_store(|s| s.contacts(c["q"].as_str().unwrap_or(""), 8));
                h.emit(json!({"type": "contacts", "rid": rid, "items": items}));
            }
            "send" => {
                let atts: Vec<String> = c["attachments"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
                let fwd = c.get("forward").filter(|f| truthy(f)).cloned();
                self.acc(&st(c, "acc"))?.fg(Op::Send { draft: c["draft"].clone(), attachments: atts, rid, forward: fwd });
                drop_draft(c.get("draftId"));
            }
            "draft-save" => save_draft(&c["id"], &c["data"]),
            "draft-drop" => drop_draft(c.get("id")),
            "pick" => {
                let hub = h.clone();
                std::thread::spawn(move || pick(&hub, rid));
            }
            "att-open" | "att-save" | "browser" | "source" => {
                let a = self.acc(&st(c, "acc"))?;
                let hub = h.clone();
                let c2 = c.clone();
                let cmd = cmd.to_string();
                a.fg(Op::FetchRaw {
                    path: st(c, "folder"),
                    uid: num(&c["uid"]),
                    then: Box::new(move |raw| match cmd.as_str() {
                        "browser" => browser(&hub, raw, &c2),
                        "source" => source(raw),
                        _ => attachment(&hub, raw, &c2),
                    }),
                });
            }
            "images" => {
                let addr = c["addr"].as_str().unwrap_or("").to_lowercase();
                if truthy(&c["always"]) && !addr.is_empty() {
                    {
                        let mut s = h.settings.lock().unwrap();
                        let lst = s.entry("imagesFrom").or_insert(json!([]));
                        if let Some(a) = lst.as_array_mut() {
                            if !a.iter().any(|x| x == &json!(addr)) {
                                a.push(json!(addr));
                            }
                        }
                    }
                    h.save_settings();
                }
            }
            "settings" => {
                if let Some(Value::Object(m)) = c.get("set") {
                    let mut s = h.settings.lock().unwrap();
                    for (k, v) in m {
                        s.insert(k.clone(), v.clone());
                    }
                }
                h.save_settings();
            }
            "account-guess" => {
                let mut m = Map::new();
                m.insert("type".into(), json!("account-guess"));
                m.insert("rid".into(), rid);
                for (k, v) in accounts::guess(c["email"].as_str().unwrap_or("")).as_object().unwrap() {
                    m.insert(k.clone(), v.clone());
                }
                h.emit(Value::Object(m));
            }
            "account-save" => self.account_save(c.get("account").cloned().ok_or("'account'")?, rid),
            "account-update" => self.account_update(&st(c, "id"), c.get("fields").unwrap_or(&json!({}))),
            "account-remove" => self.account_remove(&st(c, "id")),
            "url" => {
                let u = c["url"].as_str().unwrap_or("");
                if u.starts_with("http://") || u.starts_with("https://") {
                    xdg_open(u);
                }
            }
            "spawn" if c["what"] == "mail-dir" => xdg_open(&paths::downloads().to_string_lossy()),
            _ if cmd.starts_with("ai-") || cmd == "copy" || cmd == "calendar" => self.handle_ai(c)?,
            _ => {}
        }
        Ok(())
    }

    // ---------------------------------------------------------------- AI, codes, calendar
    fn mail_payload(&self, a: &Account, folder: &str, uid: i64, raw: &[u8]) -> Value {
        let m = mime::parse(raw);
        let get = |n: &str| m.as_ref().and_then(|m| m.header_raw(n)).map(String::from).unwrap_or_default();
        let frm = mime::addresses(&get("From"));
        let text = mime::text_of(raw);
        let row = with_store(|s| s.message(&a.id, folder, uid));
        let mut thread = vec![];
        if let Some(r) = &row {
            let others = with_store(|s| s.thread(&a.id, r["thrid"].as_str().unwrap_or(""), r["msgid"].as_str().unwrap_or(""), ""));
            for t in others {
                if t["msgid"] == r["msgid"] {
                    continue;
                }
                let who = if truthy(&t["from_name"]) { st(&t, "from_name") } else { st(&t, "from_addr") };
                let body = a.body(&st(&t, "folder"), t["uid"].as_i64().unwrap_or(0)).map(|b| mime::text_of(&b)).unwrap_or_else(|| st(&t, "snippet"));
                thread.push(format!("{who}: {body}"));
            }
        }
        let start = thread.len().saturating_sub(3);
        let conf = a.conf();
        json!({"subject": mime::dec(&get("Subject")), "from": frm.first().map(|(n, x)| mime::fmt_addr(n, x)).unwrap_or_default(),
               "date": mime::parse_date(Some(&get("Date"))), "text": text, "thread": thread[start..].to_vec(),
               "me": if truthy(&conf["name"]) { conf["name"].clone() } else { conf["email"].clone() }})
    }

    /// fn(account, raw) once the body is cached (on the account's fg thread)
    fn with_raw(self: &Arc<Self>, c: &Value, f: impl FnOnce(&Arc<Server>, &Arc<Account>, Vec<u8>) + Send + 'static) -> Result<(), String> {
        let a = self.acc(&st(c, "acc"))?;
        let me = self.clone();
        let a2 = a.clone();
        let rid = c.get("rid").cloned().unwrap_or(Value::Null);
        a.fg(Op::FetchRaw {
            path: st(c, "folder"),
            uid: num(&c["uid"]),
            then: Box::new(move |raw| match raw {
                None => me.hub.emit(json!({"type": "ai-error", "rid": rid, "text": "Couldn’t get that message from the server."})),
                Some(raw) => f(&me, &a2, raw),
            }),
        });
        Ok(())
    }

    fn handle_ai(self: &Arc<Self>, c: &Value) -> Result<(), String> {
        let h = self.hub.clone();
        let cmd = st(c, "cmd");
        let rid = c.get("rid").cloned().unwrap_or(json!(0));
        if cmd == "copy" {
            hub::copy(c["text"].as_str().unwrap_or(""), num(&c["clear"]).max(0) as u64);
            return Ok(());
        }
        if cmd == "calendar" {
            let (title, when) = (st(c, "title"), st(c, "when"));
            std::thread::spawn(move || calendar_add(&h, &title, &when));
            return Ok(());
        }
        if cmd == "ai-cancel" {
            self.ai().cancel(&rid);
            return Ok(());
        }
        let ai_on = h.settings.lock().unwrap().get("aiOn").cloned().unwrap_or(json!(true));
        if !truthy(&ai_on) {
            h.emit(json!({"type": "ai-error", "rid": rid, "text": "AI is off (Settings → AI)."}));
            return Ok(());
        }
        let ai = self.ai();
        match cmd.as_str() {
            "ai-warm" => ai.warm(),
            "ai-analyze" => {
                let key = format!("an:{}:{}:{}", st(c, "acc"), st(c, "folder"), c["uid"]);
                let key = key.replace('"', "");
                if let Some(got) = with_store(|s| s.ai_get(&key)) {
                    if !truthy(&c["force"]) {
                        h.emit(json!({"type": "ai-analysis", "rid": rid, "result": got, "cached": true}));
                        return Ok(());
                    }
                }
                let (folder, uid, auto) = (st(c, "folder"), num(&c["uid"]), truthy(&c["auto"]));
                self.with_raw(c, move |me, a, raw| {
                    let mail = me.mail_payload(a, &folder, uid, &raw);
                    me.ai().submit(rid, auto, Box::new(move |ai, rid| ai.analyze(rid, &mail, |res| with_store(|s| s.ai_put(&key, res)))));
                })?;
            }
            "ai-reply" => {
                let (folder, uid, intent) = (st(c, "folder"), num(&c["uid"]), st(c, "intent"));
                self.with_raw(c, move |me, a, raw| {
                    let mail = me.mail_payload(a, &folder, uid, &raw);
                    let name = a.conf()["name"].as_str().unwrap_or("").to_string();
                    me.ai().submit(rid, false, Box::new(move |ai, rid| ai.reply(rid, &mail, &intent, &name)));
                })?;
            }
            "ai-translate" => {
                let target = c["target"].as_str().filter(|t| !t.is_empty()).map(String::from).unwrap_or_else(|| {
                    h.settings.lock().unwrap().get("translateTo").and_then(Value::as_str).unwrap_or("ru").to_string()
                });
                self.with_raw(c, move |me, _a, raw| {
                    let text = mime::text_of(&raw);
                    me.ai().submit(rid, false, Box::new(move |ai, rid| ai.translate(rid, &text, &target)));
                })?;
            }
            "ai-write" => {
                let name = h.accounts.lock().unwrap().get(&st(c, "acc")).map(|a| a.conf()["name"].as_str().unwrap_or("").to_string()).unwrap_or_default();
                let (prompt, ctx) = (st(c, "prompt"), c.get("ctx").filter(|x| truthy(x)).cloned().unwrap_or(json!({})));
                ai.submit(rid, false, Box::new(move |ai, rid| ai.write(rid, &prompt, &ctx, &name)));
            }
            "ai-rewrite" => {
                let (text, mode) = (st(c, "text"), c["mode"].as_str().unwrap_or("improve").to_string());
                ai.submit(rid, false, Box::new(move |ai, rid| ai.rewrite(rid, &text, &mode)));
            }
            "ai-ask" => {
                let q = st(c, "q");
                let rows = self.ask_sources(&q);
                h.emit(json!({"type": "ai-sources", "rid": rid, "items": rows}));
                let docs = self.docs(&rows, true);
                ai.submit(rid, false, Box::new(move |ai, rid| ai.ask(rid, &q, &docs)));
            }
            "ai-brief" => {
                let rows = with_store(|s| s.unread_inbox(&h.acc_ids(), 20));
                h.emit(json!({"type": "ai-sources", "rid": rid, "items": rows}));
                if rows.is_empty() {
                    h.emit(json!({"type": "ai-done", "rid": rid, "text": "No unread mail in your inboxes. Nice."}));
                    return Ok(());
                }
                let lang = ai::lang_of(&rows.iter().map(|r| format!("{} {}", st(r, "subject"), st(r, "snippet"))).collect::<Vec<_>>().join(" ")).to_string();
                let docs = self.docs(&rows, false);
                ai.submit(rid, false, Box::new(move |ai, rid| ai.brief(rid, &docs, &lang)));
            }
            _ => {}
        }
        Ok(())
    }

    fn ask_sources(&self, q: &str) -> Vec<Value> {
        static W: OnceLock<Regex> = OnceLock::new();
        static NS: OnceLock<Regex> = OnceLock::new();
        let wre = W.get_or_init(|| Regex::new(r"[\p{L}\p{N}_@.-]{3,}").unwrap());
        let nostem = NS.get_or_init(|| Regex::new(r"[@.\d]").unwrap());
        let stop: HashSet<&str> = STOP.split_whitespace().collect();
        let ql = q.to_lowercase();
        let words: Vec<String> = wre.find_iter(&ql).map(|m| m.as_str().to_string()).filter(|w| !stop.contains(w.as_str())).collect();
        let mut stems: Vec<String> = vec![];
        for w in words {
            let s = if w.chars().count() > 5 && !nostem.is_match(&w) { w.chars().take(w.chars().count() - 2).collect() } else { w };
            if !stems.contains(&s) {
                stems.push(s);
            }
        }
        let ids = self.hub.acc_ids();
        let mut hits: indexmap::IndexMap<String, (i64, Value)> = indexmap::IndexMap::new();
        for stem in &stems {
            for r in with_store(|s| s.search_local(&ids, stem, 40)) {
                let k = format!("{}\0{}\0{}", r["acc"], r["folder"], r["uid"]);
                hits.entry(k).or_insert((0, r)).0 += 1;
            }
        }
        let mut ranked: Vec<(i64, Value)> = hits.into_values().collect();
        ranked.sort_by(|a, b| b.0.cmp(&a.0).then(b.1["date"].as_f64().unwrap_or(0.0).total_cmp(&a.1["date"].as_f64().unwrap_or(0.0))));
        let rows: Vec<Value> = ranked.into_iter().take(10).map(|e| e.1).collect();
        if rows.is_empty() {
            return with_store(|s| s.list_role(&ids, "inbox", 10));
        }
        rows
    }

    fn docs(&self, rows: &[Value], full: bool) -> Vec<Value> {
        let accs = self.hub.accounts.lock().unwrap().clone();
        rows.iter()
            .enumerate()
            .map(|(i, r)| {
                let mut text = st(r, "snippet");
                if full {
                    if let Some(a) = accs.get(&st(r, "acc")) {
                        if let Some(raw) = a.body(&st(r, "folder"), r["uid"].as_i64().unwrap_or(0)) {
                            text = mime::text_of(&raw);
                        }
                    }
                }
                let date = r["date"].as_f64().unwrap_or(0.0);
                json!({"n": i + 1, "from": if truthy(&r["from_name"]) { st(r, "from_name") } else { st(r, "from_addr") },
                       "subject": r["subject"], "text": text, "date": strftime("%d %b %Y %H:%M", date)})
            })
            .collect()
    }
}

fn strftime(fmt: &str, t: f64) -> String {
    let tt = t as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&tt, &mut tm) };
    let c = std::ffi::CString::new(fmt).unwrap();
    let mut buf = vec![0u8; 128];
    let n = unsafe { libc::strftime(buf.as_mut_ptr() as *mut libc::c_char, buf.len(), c.as_ptr(), &tm) };
    buf.truncate(n);
    String::from_utf8_lossy(&buf).into_owned()
}

fn calendar_add(h: &Hub, title: &str, when: &str) {
    let exe = std::env::var_os("PATH")
        .and_then(|p| std::env::split_paths(&p).map(|d| d.join("gcal-sync")).find(|x| x.is_file()))
        .unwrap_or_else(|| paths::home().join(".local/bin/gcal-sync"));
    if !exe.exists() {
        h.toast("warn", "gcal-sync isn’t installed");
        return;
    }
    let run = |args: &[&str]| std::process::Command::new(&exe).args(args).output();
    let res: Result<Value, String> = (|| {
        let p = run(&["parse", "--engine", "rules", &format!("{title} {when}")]).map_err(|e| e.to_string())?;
        let mut ev: Value = serde_json::from_slice(&p.stdout).map_err(|e| e.to_string())?;
        if !truthy(&ev["date"]) {
            return Err(format!("\u{0}Couldn’t read a date from “{when}”"));
        }
        ev["title"] = json!(title);
        let p = run(&["add", "--json", &pyjson::dumps(&ev, false)]).map_err(|e| e.to_string())?;
        if !p.status.success() {
            let t = String::from_utf8_lossy(if p.stderr.is_empty() { &p.stdout } else { &p.stderr }).trim().to_string();
            let t: String = t.chars().rev().take(200).collect::<Vec<_>>().into_iter().rev().collect();
            return Err(t);
        }
        Ok(ev)
    })();
    match res {
        Ok(ev) => {
            let time = ev["time"].as_str().filter(|t| !t.is_empty()).map(|t| format!(" {t}")).unwrap_or_default();
            h.toast("calendar", &format!("Added “{title}” · {}{time}", ev["date"].as_str().unwrap_or("")));
        }
        Err(e) if e.starts_with('\u{0}') => h.toast("warn", &e[1..]),
        Err(e) => h.toast("warn", &format!("Calendar: {e}")),
    }
}

fn attachment(h: &Hub, raw: Option<Vec<u8>>, c: &Value) {
    let Some(raw) = raw else {
        h.toast("warn", "Couldn’t get that message from the server");
        return;
    };
    let found = mime::parse(&raw).and_then(|m| mime::attachment_bytes(&m, num(&c["i"]).max(0) as usize).map(|(n, _, d)| (n, d)));
    let Some((name, data)) = found else {
        h.toast("warn", "Attachment not found");
        return;
    };
    if c["cmd"] == "att-save" {
        let _ = std::fs::create_dir_all(paths::downloads());
        let p = unique_path(&paths::downloads(), &name);
        if std::fs::write(&p, &data).is_ok() {
            h.emit(json!({"type": "saved", "path": p.to_string_lossy(), "name": p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()}));
            let home = paths::home();
            let shown = match p.strip_prefix(&home) {
                Ok(rel) if p.starts_with(&home) => format!("Saved to ~/{}", rel.display()),
                _ => p.to_string_lossy().into_owned(),
            };
            h.toast("download", &shown);
        }
    } else {
        let key = format!("{}{}{}", st(c, "acc"), st(c, "folder"), c["uid"].to_string().trim_matches('"'));
        let d = paths::opened().join(&sha1_smol::Sha1::from(key.as_bytes()).digest().to_string()[..12]);
        let _ = std::fs::create_dir_all(&d);
        let p = d.join(name.replace(['/', '\0'], "_"));
        if std::fs::write(&p, &data).is_ok() {
            xdg_open(&p.to_string_lossy());
        }
    }
}

fn browser(h: &Hub, raw: Option<Vec<u8>>, c: &Value) {
    let Some(raw) = raw else {
        h.toast("warn", "Couldn’t get that message from the server");
        return;
    };
    let page = mime::original_html(&raw, truthy(&c["images"]));
    let p = paths::opened().join(format!("msg-{}.html", &sha1_smol::Sha1::from(&raw).digest().to_string()[..12]));
    if std::fs::write(&p, page).is_ok() {
        xdg_open(&p.to_string_lossy());
    }
}

fn source(raw: Option<Vec<u8>>) {
    let Some(raw) = raw else { return };
    let p = paths::opened().join(format!("source-{}.txt", &sha1_smol::Sha1::from(&raw).digest().to_string()[..12]));
    if std::fs::write(&p, &raw).is_ok() {
        xdg_open(&p.to_string_lossy());
    }
}

fn pick(h: &Hub, rid: Value) {
    let out = std::process::Command::new("zenity").args(["--file-selection", "--multiple", "--separator=\n", "--title=Attach files"]).output();
    let files: Vec<Value> = match out {
        Ok(o) => String::from_utf8_lossy(&o.stdout)
            .split('\n')
            .filter(|f| !crate::htmlparser::py_strip(f).is_empty() && std::path::Path::new(f).is_file())
            .map(|f| {
                let p = std::path::Path::new(f);
                json!({"path": f, "name": p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
                       "size": std::fs::metadata(p).map(|m| m.len()).unwrap_or(0)})
            })
            .collect(),
        Err(_) => vec![],
    };
    h.emit(json!({"type": "picked", "rid": rid, "files": files}));
}
