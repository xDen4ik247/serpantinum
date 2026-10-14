//! The local cache (port of glassmail/store.py): folders and message headers in SQLite
//! (~/.cache/glass-mail/mail.db), full messages as .eml files under bodies/. One Store per thread;
//! WAL lets the app and the watcher use it at the same time. Same schema as the Python.
use crate::paths;
use rusqlite::functions::FunctionFlags;
use rusqlite::{params, params_from_iter, Connection, OptionalExtension, Row, ToSql};
use serde_json::{json, Map, Value};
use std::collections::HashSet;
use std::path::PathBuf;
use std::time::Duration;

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS folders (
    acc TEXT, path TEXT, name TEXT, role TEXT, delim TEXT, flags TEXT,
    uidvalidity INTEGER DEFAULT 0, uidnext INTEGER DEFAULT 0, highestmodseq INTEGER DEFAULT 0,
    total INTEGER DEFAULT 0, unread INTEGER DEFAULT 0, oldest INTEGER DEFAULT 0,
    complete INTEGER DEFAULT 0, synced REAL DEFAULT 0, notified INTEGER DEFAULT 0,
    PRIMARY KEY (acc, path)
);
CREATE TABLE IF NOT EXISTS messages (
    acc TEXT, folder TEXT, uid INTEGER,
    msgid TEXT, thrid TEXT, date REAL, from_name TEXT, from_addr TEXT,
    rcpt TEXT, cc TEXT, subject TEXT, snippet TEXT,
    seen INTEGER, flagged INTEGER, answered INTEGER, draft INTEGER,
    att INTEGER, size INTEGER, refs TEXT, unsub TEXT, part TEXT,
    PRIMARY KEY (acc, folder, uid)
);
CREATE INDEX IF NOT EXISTS messages_date ON messages (acc, folder, date DESC);
CREATE INDEX IF NOT EXISTS messages_msgid ON messages (msgid);
CREATE TABLE IF NOT EXISTS ai (k TEXT PRIMARY KEY, data TEXT, at REAL);
CREATE TABLE IF NOT EXISTS contacts (
    addr TEXT PRIMARY KEY, name TEXT, n INTEGER DEFAULT 0, sent INTEGER DEFAULT 0, last REAL DEFAULT 0
);
";

const ROLE_ORDER: [&str; 8] = ["inbox", "flagged", "sent", "drafts", "archive", "all", "junk", "trash"];
const LIST_COLS: [&str; 17] =
    ["uid", "msgid", "thrid", "date", "from_name", "from_addr", "rcpt", "subject", "snippet", "seen", "flagged", "answered", "att", "unsub", "acc", "folder", "code"];

pub struct Store {
    pub db: Connection,
}

fn val(r: &Row, name: &str) -> Value {
    use rusqlite::types::ValueRef;
    match r.get_ref(name) {
        Ok(ValueRef::Null) | Err(_) => Value::Null,
        Ok(ValueRef::Integer(i)) => json!(i),
        Ok(ValueRef::Real(f)) => json!(f),
        Ok(ValueRef::Text(t)) => json!(String::from_utf8_lossy(t)),
        Ok(ValueRef::Blob(b)) => json!(String::from_utf8_lossy(b)),
    }
}

/// a row as a dict (all columns)
fn row_dict(r: &Row) -> Map<String, Value> {
    let mut m = Map::new();
    let names: Vec<String> = r.as_ref().column_names().iter().map(|s| s.to_string()).collect();
    for n in names {
        let v = val(r, &n);
        m.insert(n, v);
    }
    m
}

/// row_out(): the list columns, booleans as booleans, rcpt parsed
pub fn row_out(r: &Row) -> Value {
    let mut d = Map::new();
    for k in LIST_COLS {
        d.insert(k.into(), val(r, k));
    }
    let rcpt = d.get("rcpt").and_then(Value::as_str).filter(|s| !s.is_empty()).unwrap_or("[]").to_string();
    d.insert("rcpt".into(), serde_json::from_str(&rcpt).unwrap_or(json!([])));
    for k in ["seen", "flagged", "answered", "att"] {
        let b = d.get(k).and_then(Value::as_i64).unwrap_or(0) != 0;
        d.insert(k.into(), json!(b));
    }
    let code = d.get("code").and_then(Value::as_str).unwrap_or("").to_string();
    d.insert("code".into(), json!(code));
    Value::Object(d)
}

pub fn body_dir(acc: &str, folder: &str) -> PathBuf {
    let h = sha1_smol::Sha1::from(folder.as_bytes()).digest().to_string();
    paths::bodies().join(acc).join(&h[..16])
}

pub fn body_path(acc: &str, folder: &str, uid: i64) -> PathBuf {
    body_dir(acc, folder).join(format!("{uid}.eml"))
}

fn ph(n: usize) -> String {
    vec!["?"; n].join(",")
}

type R<T> = rusqlite::Result<T>;

impl Store {
    pub fn open() -> Store {
        paths::ensure();
        let db = Connection::open(paths::db()).expect("open the mail cache");
        let _ = db.busy_timeout(Duration::from_secs(15));
        let _ = db.create_scalar_function("ulower", 1, FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_DETERMINISTIC, |ctx| {
            use rusqlite::types::ValueRef;
            Ok(match ctx.get_raw(0) {
                ValueRef::Text(t) => rusqlite::types::Value::Text(String::from_utf8_lossy(t).to_lowercase()),
                ValueRef::Null => rusqlite::types::Value::Null,
                ValueRef::Integer(i) => rusqlite::types::Value::Integer(i),
                ValueRef::Real(f) => rusqlite::types::Value::Real(f),
                ValueRef::Blob(b) => rusqlite::types::Value::Blob(b.to_vec()),
            })
        });
        // several threads open a brand-new cache at once: journal_mode needs the lock briefly
        for attempt in 0..50 {
            let r = (|| -> R<()> {
                db.query_row("PRAGMA journal_mode=WAL", [], |_| Ok(()))?;
                db.execute_batch("PRAGMA synchronous=NORMAL;")?;
                db.execute_batch(SCHEMA)?;
                let cols: HashSet<String> = db.prepare("PRAGMA table_info(messages)")?.query_map([], |r| r.get::<_, String>(1))?.flatten().collect();
                if !cols.contains("code") {
                    db.execute("ALTER TABLE messages ADD COLUMN code TEXT DEFAULT ''", [])?;
                }
                Ok(())
            })();
            match r {
                Ok(()) => break,
                Err(e) if e.to_string().contains("locked") && attempt < 49 => std::thread::sleep(Duration::from_millis(100)),
                Err(e) => panic!("mail cache: {e}"),
            }
        }
        Store { db }
    }

    fn rows<P: rusqlite::Params>(&self, sql: &str, p: P, f: fn(&Row) -> Value) -> Vec<Value> {
        match self.db.prepare(sql) {
            Ok(mut st) => st.query_map(p, |r| Ok(f(r))).map(|it| it.flatten().collect()).unwrap_or_default(),
            Err(_) => vec![],
        }
    }

    // ---------------------------------------------------------------- folders
    pub fn folders(&self, acc: &str) -> Vec<Map<String, Value>> {
        let mut rows: Vec<Map<String, Value>> =
            self.rows("SELECT * FROM folders WHERE acc=?", [acc], |r| Value::Object(row_dict(r))).into_iter().filter_map(|v| v.as_object().cloned()).collect();
        rows.sort_by_key(|r| {
            let role = r.get("role").and_then(Value::as_str).unwrap_or("");
            let i = ROLE_ORDER.iter().position(|x| *x == role).unwrap_or(ROLE_ORDER.len());
            (i, r.get("path").and_then(Value::as_str).unwrap_or("").to_lowercase())
        });
        rows
    }

    pub fn folder(&self, acc: &str, path: &str) -> Option<Map<String, Value>> {
        self.db.query_row("SELECT * FROM folders WHERE acc=? AND path=?", [acc, path], |r| Ok(row_dict(r))).optional().ok().flatten()
    }

    pub fn folder_by_role(&self, acc: &str, role: &str) -> Option<Map<String, Value>> {
        self.db.query_row("SELECT * FROM folders WHERE acc=? AND role=? ORDER BY path LIMIT 1", [acc, role], |r| Ok(row_dict(r))).optional().ok().flatten()
    }

    /// items: [{path, name, role, delim, flags}] from LIST; drops folders that are gone
    pub fn set_folders(&self, acc: &str, items: &[Value]) {
        let have: HashSet<String> = self.db.prepare("SELECT path FROM folders WHERE acc=?").and_then(|mut s| s.query_map([acc], |r| r.get(0)).map(|it| it.flatten().collect())).unwrap_or_default();
        let mut new = HashSet::new();
        let tx = self.db.unchecked_transaction().ok();
        for f in items {
            let s = |k: &str| f[k].as_str().unwrap_or("").to_string();
            new.insert(s("path"));
            if have.contains(&s("path")) {
                let _ = self.db.execute(
                    "UPDATE folders SET name=?, role=?, delim=?, flags=? WHERE acc=? AND path=?",
                    params![s("name"), s("role"), s("delim"), s("flags"), acc, s("path")],
                );
            } else {
                let _ = self.db.execute(
                    "INSERT INTO folders (acc, path, name, role, delim, flags) VALUES (?,?,?,?,?,?)",
                    params![acc, s("path"), s("name"), s("role"), s("delim"), s("flags")],
                );
            }
        }
        if let Some(tx) = tx {
            let _ = tx.commit();
        }
        for gone in have.difference(&new) {
            self.drop_folder(acc, gone);
        }
    }

    pub fn update_folder(&self, acc: &str, path: &str, kw: &[(&str, Value)]) {
        if kw.is_empty() {
            return;
        }
        let cols: Vec<String> = kw.iter().map(|(k, _)| format!("{k}=?")).collect();
        let sql = format!("UPDATE folders SET {} WHERE acc=? AND path=?", cols.join(", "));
        let mut vals: Vec<rusqlite::types::Value> = kw
            .iter()
            .map(|(_, v)| match v {
                Value::Number(n) if n.is_i64() => rusqlite::types::Value::Integer(n.as_i64().unwrap()),
                Value::Number(n) => rusqlite::types::Value::Real(n.as_f64().unwrap_or(0.0)),
                Value::String(s) => rusqlite::types::Value::Text(s.clone()),
                Value::Bool(b) => rusqlite::types::Value::Integer(*b as i64),
                _ => rusqlite::types::Value::Null,
            })
            .collect();
        vals.push(rusqlite::types::Value::Text(acc.into()));
        vals.push(rusqlite::types::Value::Text(path.into()));
        let _ = self.db.execute(&sql, params_from_iter(vals));
    }

    pub fn drop_folder(&self, acc: &str, path: &str) {
        let _ = self.db.execute("DELETE FROM messages WHERE acc=? AND folder=?", [acc, path]);
        let _ = self.db.execute("DELETE FROM folders WHERE acc=? AND path=?", [acc, path]);
        let _ = std::fs::remove_dir_all(body_dir(acc, path));
    }

    pub fn reset_folder(&self, acc: &str, path: &str) {
        let _ = self.db.execute("DELETE FROM messages WHERE acc=? AND folder=?", [acc, path]);
        let _ = self.db.execute("UPDATE folders SET oldest=0, complete=0, notified=0, highestmodseq=0 WHERE acc=? AND path=?", [acc, path]);
        let _ = std::fs::remove_dir_all(body_dir(acc, path));
    }

    pub fn drop_account(&self, acc: &str) {
        let _ = self.db.execute("DELETE FROM messages WHERE acc=?", [acc]);
        let _ = self.db.execute("DELETE FROM folders WHERE acc=?", [acc]);
        let _ = std::fs::remove_dir_all(paths::bodies().join(acc));
    }

    pub fn recount(&self, acc: &str, path: &str) -> (i64, i64) {
        self.db
            .query_row("SELECT COUNT(*), SUM(seen=0) FROM messages WHERE acc=? AND folder=?", [acc, path], |r| {
                Ok((r.get::<_, Option<i64>>(0)?.unwrap_or(0), r.get::<_, Option<i64>>(1)?.unwrap_or(0)))
            })
            .unwrap_or((0, 0))
    }

    // ---------------------------------------------------------------- messages
    pub fn uids(&self, acc: &str, folder: &str) -> HashSet<i64> {
        self.db.prepare("SELECT uid FROM messages WHERE acc=? AND folder=?").and_then(|mut s| s.query_map([acc, folder], |r| r.get(0)).map(|it| it.flatten().collect())).unwrap_or_default()
    }

    pub fn max_uid(&self, acc: &str, folder: &str) -> i64 {
        self.db.query_row("SELECT MAX(uid) FROM messages WHERE acc=? AND folder=?", [acc, folder], |r| r.get::<_, Option<i64>>(0)).ok().flatten().unwrap_or(0)
    }

    pub fn min_uid(&self, acc: &str, folder: &str) -> i64 {
        self.db.query_row("SELECT MIN(uid) FROM messages WHERE acc=? AND folder=?", [acc, folder], |r| r.get::<_, Option<i64>>(0)).ok().flatten().unwrap_or(0)
    }

    pub fn put_messages(&self, acc: &str, folder: &str, msgs: &[Value]) {
        let tx = self.db.unchecked_transaction().ok();
        for m in msgs {
            let s = |k: &str| m[k].as_str().unwrap_or("").to_string();
            let i = |k: &str| match &m[k] {
                Value::Bool(b) => *b as i64,
                v => v.as_i64().unwrap_or(0),
            };
            let _ = self.db.execute(
                "INSERT OR REPLACE INTO messages (acc, folder, uid, msgid, thrid, date, from_name, from_addr, rcpt, cc,
                 subject, snippet, seen, flagged, answered, draft, att, size, refs, unsub, part, code)
                 VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                params![
                    acc,
                    folder,
                    m["uid"].as_i64().unwrap_or(0),
                    s("msgid"),
                    s("thrid"),
                    m["date"].as_f64().unwrap_or(0.0),
                    s("from_name"),
                    s("from_addr"),
                    crate::pyjson::dumps(m.get("rcpt").unwrap_or(&json!([])), true),
                    crate::pyjson::dumps(m.get("cc").unwrap_or(&json!([])), true),
                    s("subject"),
                    s("snippet"),
                    i("seen"),
                    i("flagged"),
                    i("answered"),
                    i("draft"),
                    i("att"),
                    m["size"].as_i64().unwrap_or(0),
                    s("refs"),
                    s("unsub"),
                    s("part"),
                    s("code")
                ],
            );
        }
        if let Some(tx) = tx {
            let _ = tx.commit();
        }
    }

    pub fn set_snippets(&self, acc: &str, folder: &str, snippets: &[(i64, String)]) {
        let tx = self.db.unchecked_transaction().ok();
        for (uid, s) in snippets {
            let _ = self.db.execute("UPDATE messages SET snippet=? WHERE acc=? AND folder=? AND uid=?", params![s, acc, folder, uid]);
        }
        if let Some(tx) = tx {
            let _ = tx.commit();
        }
    }

    pub fn set_codes(&self, acc: &str, folder: &str, codes: &[(i64, String)]) {
        for (uid, c) in codes {
            let _ = self.db.execute("UPDATE messages SET code=? WHERE acc=? AND folder=? AND uid=?", params![c, acc, folder, uid]);
        }
    }

    pub fn ai_get(&self, k: &str) -> Option<Value> {
        let s: Option<String> = self.db.query_row("SELECT data FROM ai WHERE k=?", [k], |r| r.get(0)).optional().ok().flatten();
        s.and_then(|s| serde_json::from_str(&s).ok())
    }

    pub fn ai_put(&self, k: &str, data: &Value) {
        let _ = self.db.execute("INSERT OR REPLACE INTO ai (k, data, at) VALUES (?,?,?)", params![k, crate::pyjson::dumps(data, false), crate::mime::now()]);
    }

    pub fn sent_contacts(&self) -> HashSet<String> {
        self.db.prepare("SELECT addr FROM contacts WHERE sent>0").and_then(|mut s| s.query_map([], |r| r.get(0)).map(|it| it.flatten().collect())).unwrap_or_default()
    }

    pub fn unread_inbox(&self, accs: &[String], limit: i64) -> Vec<Value> {
        if accs.is_empty() {
            return vec![];
        }
        let q = format!(
            "SELECT m.* FROM messages m JOIN folders f ON f.acc=m.acc AND f.path=m.folder WHERE f.role='inbox' AND m.seen=0 AND m.acc IN ({}) ORDER BY m.date DESC LIMIT ?",
            ph(accs.len())
        );
        let mut args: Vec<&dyn ToSql> = accs.iter().map(|a| a as &dyn ToSql).collect();
        args.push(&limit);
        self.rows(&q, params_from_iter(args), row_out)
    }

    pub fn missing_snippets(&self, acc: &str, folder: &str, limit: i64) -> Vec<(i64, String)> {
        self.db
            .prepare("SELECT uid, part FROM messages WHERE acc=? AND folder=? AND snippet='' AND part!='' ORDER BY uid DESC LIMIT ?")
            .and_then(|mut s| s.query_map(params![acc, folder, limit], |r| Ok((r.get(0)?, r.get(1)?))).map(|it| it.flatten().collect()))
            .unwrap_or_default()
    }

    pub fn set_flags(&self, acc: &str, folder: &str, upd: &[(i64, [bool; 4])]) {
        let tx = self.db.unchecked_transaction().ok();
        for (uid, f) in upd {
            let _ = self.db.execute(
                "UPDATE messages SET seen=?, flagged=?, answered=?, draft=? WHERE acc=? AND folder=? AND uid=?",
                params![f[0] as i64, f[1] as i64, f[2] as i64, f[3] as i64, acc, folder, uid],
            );
        }
        if let Some(tx) = tx {
            let _ = tx.commit();
        }
    }

    pub fn set_flag(&self, acc: &str, folder: &str, uids: &[i64], col: &str, val: bool) {
        assert!(["seen", "flagged", "answered"].contains(&col));
        let sql = format!("UPDATE messages SET {col}=? WHERE acc=? AND folder=? AND uid=?");
        let tx = self.db.unchecked_transaction().ok();
        for u in uids {
            let _ = self.db.execute(&sql, params![val as i64, acc, folder, u]);
        }
        if let Some(tx) = tx {
            let _ = tx.commit();
        }
    }

    pub fn delete(&self, acc: &str, folder: &str, uids: &[i64]) {
        if uids.is_empty() {
            return;
        }
        let tx = self.db.unchecked_transaction().ok();
        for u in uids {
            let _ = self.db.execute("DELETE FROM messages WHERE acc=? AND folder=? AND uid=?", params![acc, folder, u]);
        }
        if let Some(tx) = tx {
            let _ = tx.commit();
        }
        let d = body_dir(acc, folder);
        for u in uids {
            let _ = std::fs::remove_file(d.join(format!("{u}.eml")));
        }
    }

    pub fn message(&self, acc: &str, folder: &str, uid: i64) -> Option<Value> {
        self.db.query_row("SELECT * FROM messages WHERE acc=? AND folder=? AND uid=?", params![acc, folder, uid], |r| Ok(row_out(r))).optional().ok().flatten()
    }

    pub fn message_row(&self, acc: &str, folder: &str, uid: i64) -> Option<Map<String, Value>> {
        self.db.query_row("SELECT * FROM messages WHERE acc=? AND folder=? AND uid=?", params![acc, folder, uid], |r| Ok(row_dict(r))).optional().ok().flatten()
    }

    pub fn list(&self, acc: &str, folder: &str, limit: i64) -> Vec<Value> {
        self.rows("SELECT * FROM messages WHERE acc=? AND folder=? ORDER BY date DESC, uid DESC LIMIT ?", params![acc, folder, limit], row_out)
    }

    pub fn list_role(&self, accs: &[String], role: &str, limit: i64) -> Vec<Value> {
        if accs.is_empty() {
            return vec![];
        }
        let q = format!(
            "SELECT m.* FROM messages m JOIN folders f ON f.acc=m.acc AND f.path=m.folder WHERE f.role=? AND m.acc IN ({}) ORDER BY m.date DESC LIMIT ?",
            ph(accs.len())
        );
        let mut args: Vec<&dyn ToSql> = vec![&role];
        args.extend(accs.iter().map(|a| a as &dyn ToSql));
        args.push(&limit);
        self.rows(&q, params_from_iter(args), row_out)
    }

    pub fn flagged(&self, accs: &[String], limit: i64) -> Vec<Value> {
        if accs.is_empty() {
            return vec![];
        }
        let q = format!(
            "SELECT m.* FROM messages m JOIN folders f ON f.acc=m.acc AND f.path=m.folder WHERE m.flagged=1 AND m.acc IN ({}) AND COALESCE(f.role,'') NOT IN ('all','trash','junk') ORDER BY m.date DESC LIMIT ?",
            ph(accs.len())
        );
        let mut args: Vec<&dyn ToSql> = accs.iter().map(|a| a as &dyn ToSql).collect();
        args.push(&limit);
        self.rows(&q, params_from_iter(args), row_out)
    }

    pub fn search_local(&self, accs: &[String], q: &str, limit: usize) -> Vec<Value> {
        let q = crate::htmlparser::py_strip(q);
        if accs.is_empty() || q.is_empty() {
            return vec![];
        }
        let like = format!("%{}%", q.to_lowercase().replace(['%', '_'], ""));
        let sql = format!(
            "SELECT m.* FROM messages m JOIN folders f ON f.acc=m.acc AND f.path=m.folder WHERE m.acc IN ({}) AND COALESCE(f.role,'') NOT IN ('trash','junk')
             AND (ulower(m.subject) LIKE ? OR ulower(m.from_name) LIKE ? OR ulower(m.from_addr) LIKE ? OR ulower(m.snippet) LIKE ? OR ulower(m.rcpt) LIKE ?)
             ORDER BY m.date DESC LIMIT ?",
            ph(accs.len())
        );
        let lim = (limit * 3) as i64;
        let mut args: Vec<&dyn ToSql> = accs.iter().map(|a| a as &dyn ToSql).collect();
        for _ in 0..5 {
            args.push(&like);
        }
        args.push(&lim);
        let rows = self.rows(&sql, params_from_iter(args), row_out);
        let mut out = vec![];
        let mut seen = HashSet::new();
        for r in rows {
            let msgid = r["msgid"].as_str().unwrap_or("");
            let k = if msgid.is_empty() { format!("{}\0{}\0{}", r["acc"], r["folder"], r["uid"]) } else { msgid.to_string() };
            if !seen.insert(k) {
                continue;
            }
            out.push(r);
            if out.len() >= limit {
                break;
            }
        }
        out
    }

    pub fn thread(&self, acc: &str, thrid: &str, msgid: &str, refs: &str) -> Vec<Value> {
        let rows = if !thrid.is_empty() {
            self.rows("SELECT * FROM messages WHERE acc=? AND thrid=? ORDER BY date", [acc, thrid], row_out)
        } else {
            let mut ids: Vec<String> = refs.split_whitespace().map(String::from).collect();
            if !msgid.is_empty() {
                ids.push(msgid.to_string());
            }
            if ids.is_empty() {
                return vec![];
            }
            let sql = format!("SELECT * FROM messages WHERE acc=? AND (msgid IN ({}) OR refs LIKE ?) ORDER BY date", ph(ids.len()));
            let like = format!("%{}%", if msgid.is_empty() { "\0" } else { msgid });
            let mut args: Vec<&dyn ToSql> = vec![&acc];
            args.extend(ids.iter().map(|i| i as &dyn ToSql));
            args.push(&like);
            self.rows(&sql, params_from_iter(args), row_out)
        };
        let mut out = vec![];
        let mut seen = HashSet::new();
        for r in rows {
            let msgid = r["msgid"].as_str().unwrap_or("");
            let k = if msgid.is_empty() { r["uid"].to_string() } else { msgid.to_string() };
            if seen.insert(k) {
                out.push(r);
            }
        }
        out
    }

    // ---------------------------------------------------------------- contacts
    pub fn add_contacts(&self, people: &[(String, String)], sent: bool, when: Option<f64>) {
        let when = when.unwrap_or_else(crate::mime::now);
        let tx = self.db.unchecked_transaction().ok();
        for (name, addr) in people {
            let addr = crate::htmlparser::py_strip(addr).to_lowercase();
            if addr.is_empty() || !addr.contains('@') || addr.contains("noreply") || addr.contains("no-reply") {
                continue;
            }
            let _ = self.db.execute(
                "INSERT INTO contacts (addr, name, n, sent, last) VALUES (?,?,1,?,?)
                 ON CONFLICT(addr) DO UPDATE SET n=n+1, sent=sent+excluded.sent,
                 name=CASE WHEN excluded.name!='' THEN excluded.name ELSE name END, last=MAX(last, excluded.last)",
                params![addr, name, sent as i64, when],
            );
        }
        if let Some(tx) = tx {
            let _ = tx.commit();
        }
    }

    pub fn contacts(&self, q: &str, limit: i64) -> Vec<Value> {
        let like = format!("%{}%", crate::htmlparser::py_strip(q).to_lowercase().replace('%', ""));
        self.rows(
            "SELECT * FROM contacts WHERE addr LIKE ? OR ulower(name) LIKE ? ORDER BY sent*5 + n DESC, last DESC LIMIT ?",
            params![like, like, limit],
            |r| json!({"name": val(r, "name"), "addr": val(r, "addr")}),
        )
    }

    pub fn unread_counts(&self) -> std::collections::HashMap<String, i64> {
        self.db
            .prepare("SELECT acc, unread FROM folders WHERE role='inbox'")
            .and_then(|mut s| s.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<i64>>(1)?.unwrap_or(0)))).map(|it| it.flatten().collect()))
            .unwrap_or_default()
    }
}
