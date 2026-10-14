//! What the accounts share (the Hub of server.py): output to the window, settings, theme colours,
//! the unread file, notifications, the clipboard, images for the reader. In the watcher and the
//! one-shot check the hub is quiet (no window to talk to).
use crate::accounts;
use crate::engine::Account;
use crate::mime;
use crate::paths;
use crate::pyjson;
use crate::store::Store;
use base64::Engine as _;
use serde_json::{json, Map, Value};
use std::io::Write;
use std::sync::{Arc, Mutex, OnceLock};

pub struct Hub {
    pub quiet: bool,
    out: Mutex<()>,
    pub settings: Mutex<Map<String, Value>>,
    pub colors: Mutex<Value>,
    pub accounts: Mutex<indexmap::IndexMap<String, Arc<Account>>>,
    pub ai: OnceLock<Arc<crate::ai::Ai>>,
}

pub fn default_settings() -> Map<String, Value> {
    json!({"markRead": true, "notify": true, "imagesFrom": [], "imagesAlways": false, "pollMinutes": 3,
           "autoCopyCodes": true, "codesTrash": "now", "aiOn": true, "aiAuto": true, "translateTo": "ru"})
    .as_object()
    .unwrap()
    .clone()
}

fn sh_quote(s: &str) -> String {
    if !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || "@%+=:,./-_".contains(c)) {
        return s.to_string();
    }
    format!("'{}'", s.replace('\'', "'\"'\"'"))
}

fn spawn_detached(args: &[&str]) {
    use std::os::unix::process::CommandExt;
    let _ = std::process::Command::new(args[0])
        .args(&args[1..])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .process_group(0)
        .spawn()
        .map(|mut c| std::thread::spawn(move || c.wait()));
}

fn notify_log() -> Option<String> {
    std::env::var("GLASS_MAIL_NOTIFY_LOG").ok().filter(|s| !s.is_empty())
}

fn log_line(v: &Value) {
    if let Some(p) = notify_log() {
        if let Ok(mut f) = std::fs::OpenOptions::new().append(true).create(true).open(p) {
            let _ = writeln!(f, "{}", pyjson::dumps(v, false));
        }
    }
}

/// A desktop notification with an Open action (glass-mail --open …), detached.
pub fn notify_one(title: &str, body: &str, open_cmd: &[String], icon: &str) {
    if notify_log().is_some() {
        log_line(&json!({"title": title, "body": body, "open": open_cmd, "icon": icon}));
        return;
    }
    let script = format!(
        "a=$(notify-send -a \"Glass Mail\" -i {} -c email.arrived -A default=Open -A open=Open {} {} 2>/dev/null); case \"$a\" in default|open) exec {};; esac",
        sh_quote(icon),
        sh_quote(title),
        sh_quote(body),
        open_cmd.iter().map(|x| sh_quote(x)).collect::<Vec<_>>().join(" ")
    );
    spawn_detached(&["sh", "-c", &script]);
}

/// Wayland clipboard (wl-copy); optionally cleared later if it still holds this text.
pub fn copy(text: &str, clear_after: u64) {
    if notify_log().is_some() {
        log_line(&json!({"copied": text}));
        return;
    }
    let ok = std::process::Command::new("wl-copy")
        .args(["--", text])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok();
    if ok && clear_after != 0 {
        let q = sh_quote(text);
        spawn_detached(&["sh", "-c", &format!("sleep {clear_after}; [ \"$(wl-paste -n 2>/dev/null)\" = {q} ] && wl-copy --clear")]);
    }
}

fn exe() -> String {
    paths::home().join(".local/bin/glass-mail").to_string_lossy().into_owned()
}

impl Hub {
    pub fn new(quiet: bool) -> Arc<Hub> {
        paths::ensure();
        let mut settings = default_settings();
        for (k, v) in accounts::load_settings() {
            settings.insert(k, v);
        }
        Arc::new(Hub {
            quiet,
            out: Mutex::new(()),
            settings: Mutex::new(settings),
            colors: Mutex::new(json!({})),
            accounts: Mutex::new(indexmap::IndexMap::new()),
            ai: OnceLock::new(),
        })
    }

    pub fn emit(&self, obj: Value) {
        if self.quiet {
            return;
        }
        let line = pyjson::dumps(&obj, false);
        let _g = self.out.lock().unwrap();
        let mut o = std::io::stdout().lock();
        let _ = o.write_all(line.as_bytes());
        let _ = o.write_all(b"\n");
        let _ = o.flush();
    }

    pub fn log(&self, msg: &str) {
        let _g = self.out.lock().unwrap();
        eprintln!("{}", msg.trim_end());
    }

    pub fn toast(&self, icon: &str, text: &str) {
        self.emit(json!({"type": "toast", "icon": icon, "text": text}));
    }

    pub fn setting(&self, k: &str) -> Value {
        self.settings.lock().unwrap().get(k).cloned().unwrap_or(Value::Null)
    }

    pub fn poll_seconds(&self) -> u64 {
        let m = self.setting("pollMinutes");
        let m = m.as_i64().or_else(|| m.as_f64().map(|x| x as i64)).filter(|x| *x != 0).unwrap_or(3);
        (m.max(1) * 60) as u64
    }

    pub fn save_settings(&self) {
        let s = self.settings.lock().unwrap().clone();
        accounts::save_settings(&s);
        self.emit(json!({"type": "settings", "settings": s}));
    }

    pub fn acc_ids(&self) -> Vec<String> {
        accounts::load().iter().filter_map(|c| c["id"].as_str().map(String::from)).collect()
    }

    pub fn write_unread(&self, store: &Store) {
        let counts = store.unread_counts();
        let ids = self.acc_ids();
        let total: i64 = ids.iter().map(|i| counts.get(i).copied().unwrap_or(0)).sum();
        let mut per = Map::new();
        for i in &ids {
            per.insert(i.clone(), json!(counts.get(i).copied().unwrap_or(0)));
        }
        let data = json!({"unread": total, "accounts": per, "at": mime::now()});
        let tmp = paths::unread().with_extension("json.tmp");
        if std::fs::write(&tmp, pyjson::dumps(&data, true)).is_ok() {
            let _ = std::fs::rename(&tmp, paths::unread());
        }
        let mut m = Map::new();
        m.insert("type".into(), json!("unread"));
        for (k, v) in data.as_object().unwrap() {
            m.insert(k.clone(), v.clone());
        }
        self.emit(Value::Object(m));
    }

    /// What happens to a login-code mail: 'now' (Trash once copied), 'day', 'keep'.
    pub fn code_trash_mode(&self) -> String {
        match self.setting("codesTrash").as_str() {
            Some(m @ ("now" | "day" | "keep")) => m.to_string(),
            _ => {
                if crate::engine_truthy(&self.setting("codesCleanup")) {
                    "day".into()
                } else {
                    "now".into()
                }
            }
        }
    }

    /// -> UIDs whose login code went to the clipboard
    pub fn notify(&self, conf: &Value, path: &str, rows: &[Map<String, Value>]) -> Vec<i64> {
        let now = mime::now();
        let date = |r: &Map<String, Value>| r.get("date").and_then(Value::as_f64).unwrap_or(0.0);
        let code = |r: &Map<String, Value>| r.get("code").and_then(Value::as_str).unwrap_or("").to_string();
        let uid = |r: &Map<String, Value>| r.get("uid").and_then(Value::as_i64).unwrap_or(0);
        let auto = !matches!(self.setting("autoCopyCodes"), Value::Bool(false));
        if matches!(self.setting("notify"), Value::Bool(false)) {
            let fresh: Vec<&Map<String, Value>> = rows.iter().filter(|r| !code(r).is_empty() && date(r) > now - 15.0 * 60.0).collect();
            if auto {
                for r in &fresh {
                    copy(&code(r), 180);
                }
                return fresh.iter().map(|r| uid(r)).collect();
            }
            return vec![];
        }
        let rows: Vec<&Map<String, Value>> = rows.iter().filter(|r| date(r) > now - 2.0 * 86400.0).collect();
        let fresh: Vec<&Map<String, Value>> = rows.iter().copied().filter(|r| !code(r).is_empty() && date(r) > now - 15.0 * 60.0).collect();
        let copied: Vec<i64> = fresh.iter().filter(|r| self.code_arrived(conf, path, r)).map(|r| uid(r)).collect();
        let rest: Vec<&Map<String, Value>> = rows.into_iter().filter(|r| !fresh.iter().any(|f| std::ptr::eq(*f, *r))).collect();
        if !rest.is_empty() {
            notify_rows(conf, path, &rest);
        }
        copied
    }

    /// A fresh login code: straight to the clipboard (cleared after 3 min).
    fn code_arrived(&self, conf: &Value, path: &str, r: &Map<String, Value>) -> bool {
        let g = |k: &str| r.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        let who = [g("from_name"), g("from_addr")].into_iter().find(|x| !x.is_empty()).unwrap_or_else(|| "Login code".into());
        let code = g("code");
        let uid = r.get("uid").and_then(Value::as_i64).unwrap_or(0).to_string();
        let acc = conf["id"].as_str().unwrap_or("").to_string();
        if !matches!(self.setting("autoCopyCodes"), Value::Bool(false)) {
            copy(&code, 180);
            let now = self.code_trash_mode() == "now";
            let open: Vec<String> = if now { vec![exe()] } else { vec![exe(), "--open".into(), acc.clone(), path.into(), uid.clone()] };
            notify_one(
                &format!("{code} copied"),
                &format!("{who}{}\nPaste it — the clipboard clears in 3 min.", if now { " · mail moved to Trash" } else { "" }),
                &open,
                "dialog-password",
            );
            self.emit(json!({"type": "code", "code": code, "from": who, "acc": acc, "folder": path, "uid": r.get("uid").cloned().unwrap_or(Value::Null)}));
            true
        } else {
            notify_one(&format!("Code {code} · {who}"), &g("subject"), &[exe(), "--open".into(), acc, path.into(), uid], "dialog-password");
            false
        }
    }

    pub fn images_allowed(&self, addr: &str) -> bool {
        if crate::engine_truthy(&self.setting("imagesAlways")) {
            return true;
        }
        let addr = addr.to_lowercase();
        let dom = addr.rsplit('@').next().unwrap_or("").to_string();
        let allow: Vec<String> = self.setting("imagesFrom").as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_lowercase)).collect()).unwrap_or_default();
        allow.contains(&addr) || allow.contains(&format!("@{dom}"))
    }

    /// cid: and data: images -> files QML can show; remote ones keep their URL in 'url'.
    pub fn prepare_images(&self, acc: &str, raw: &[u8], v: &mut Value) {
        let d = paths::images().join(acc);
        let parsed = mime::parse(raw);
        let walk = parsed.as_ref().map(mime::walk_parts);
        let Some(blocks) = v["blocks"].as_array_mut() else { return };
        for b in blocks.iter_mut() {
            if b["t"] != "img" {
                continue;
            }
            if let Some(cid) = b.get("cid").and_then(Value::as_str).filter(|c| !c.is_empty()).map(String::from) {
                let part = walk.as_ref().and_then(|w| w.cids.iter().find(|(c, _)| *c == cid).map(|(_, p)| (p.ctype.clone(), p.payload())));
                match part {
                    None => b["t"] = json!("skip"),
                    Some((ctype, data)) => {
                        let ext = mime::guess_extension(&ctype).unwrap_or(".img");
                        b["src"] = json!(write_image(&d, &data, ext));
                    }
                }
            } else if let Some(data) = b.get("data").and_then(Value::as_str).map(String::from) {
                static RE: OnceLock<regex::Regex> = OnceLock::new();
                let re = RE.get_or_init(|| regex::Regex::new(r"(?s)^data:(image/[\w.+-]+)?(;base64)?,(.*)$").unwrap());
                let Some(m) = re.captures(&data) else {
                    b["t"] = json!("skip");
                    continue;
                };
                if m.get(2).is_none() {
                    b["t"] = json!("skip");
                    continue;
                }
                let payload: String = m[3].chars().filter(|c| !c.is_whitespace()).collect();
                let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(payload.as_bytes()) else {
                    b["t"] = json!("skip");
                    continue;
                };
                let ext = m.get(1).and_then(|t| mime::guess_extension(t.as_str())).unwrap_or(".img");
                b["src"] = json!(write_image(&d, &bytes, ext));
                if let Some(o) = b.as_object_mut() {
                    o.shift_remove("data");
                }
            } else {
                b["url"] = b["src"].clone();
                b["src"] = json!("");
            }
        }
        blocks.retain(|b| b["t"] != "skip");
    }
}

fn write_image(d: &std::path::Path, data: &[u8], ext: &str) -> String {
    let _ = std::fs::create_dir_all(d);
    let p = d.join(format!("{}{ext}", &sha1_smol::Sha1::from(data).digest().to_string()[..20]));
    if !p.exists() {
        let _ = std::fs::write(&p, data);
    }
    format!("file://{}", p.display())
}

/// The notification for new mail (one per message, or a summary for more than three).
pub fn notify_rows(conf: &Value, path: &str, rows: &[&Map<String, Value>]) {
    let g = |r: &Map<String, Value>, k: &str| r.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    if rows.len() <= 3 {
        for r in rows {
            let who = [g(r, "from_name"), g(r, "from_addr")].into_iter().find(|x| !x.is_empty()).unwrap_or_else(|| "New mail".into());
            let subj = g(r, "subject");
            let snip = g(r, "snippet");
            let mut body = if subj.is_empty() { "(no subject)".to_string() } else { subj };
            if !crate::htmlparser::py_strip(&snip).is_empty() {
                body.push('\n');
                body.extend(snip.chars().take(140));
            }
            let uid = r.get("uid").and_then(Value::as_i64).unwrap_or(0).to_string();
            notify_one(&who, &body, &[exe(), "--open".into(), conf["id"].as_str().unwrap_or("").into(), path.into(), uid], "glass-mail");
        }
    } else {
        let mut names: Vec<String> = vec![];
        for r in &rows[rows.len().saturating_sub(4)..] {
            let n = [g(r, "from_name"), g(r, "from_addr")].into_iter().find(|x| !x.is_empty()).unwrap_or_else(|| "?".into());
            if !names.contains(&n) {
                names.push(n);
            }
        }
        notify_one(&format!("{} new messages · {}", rows.len(), conf["email"].as_str().unwrap_or("")), &names.join(", "), &[exe()], "glass-mail");
    }
}
