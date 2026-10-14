//! Mail accounts (port of accounts.py): ~/.config/glass-mail/accounts.json (mode 600, holds the app
//! passwords) and server presets for the common providers.
use crate::paths;
use crate::pyjson;
use serde_json::{json, Map, Value};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;

/// (imap host, imap port, smtp host, smtp port, smtp security, app-password page, label)
fn preset(key: &str) -> Option<(&'static str, u16, &'static str, u16, &'static str, &'static str, &'static str)> {
    Some(match key {
        "gmail" => ("imap.gmail.com", 993, "smtp.gmail.com", 465, "ssl", "https://myaccount.google.com/apppasswords", "Gmail"),
        "yandex" => ("imap.yandex.ru", 993, "smtp.yandex.ru", 465, "ssl", "https://id.yandex.ru/security/app-passwords", "Yandex Mail"),
        "mailru" => ("imap.mail.ru", 993, "smtp.mail.ru", 465, "ssl", "https://account.mail.ru/user/2-step-auth/passwords", "Mail.ru"),
        "outlook" => ("outlook.office365.com", 993, "smtp-mail.outlook.com", 587, "starttls", "https://account.live.com/proofs/AppPassword", "Outlook"),
        "icloud" => ("imap.mail.me.com", 993, "smtp.mail.me.com", 587, "starttls", "https://account.apple.com/account/manage", "iCloud Mail"),
        _ => return None,
    })
}

fn domain_key(dom: &str) -> Option<&'static str> {
    Some(match dom {
        "gmail.com" | "googlemail.com" => "gmail",
        "yandex.ru" | "ya.ru" | "yandex.com" | "yandex.by" | "yandex.kz" | "yandex.ua" | "narod.ru" => "yandex",
        "mail.ru" | "inbox.ru" | "list.ru" | "bk.ru" | "internet.ru" => "mailru",
        "outlook.com" | "hotmail.com" | "live.com" | "msn.com" => "outlook",
        "icloud.com" | "me.com" | "mac.com" => "icloud",
        _ => return None,
    })
}

pub const COLORS: [&str; 7] = ["#80d4db", "#f2b880", "#b7c7ea", "#e8a0bf", "#a6d189", "#c6a0f6", "#f5c2a0"];

/// Server settings for an address: a known provider, else imap./smtp.<domain>.
pub fn guess(email: &str) -> Value {
    let dom = crate::htmlparser::py_strip(email.rsplit('@').next().unwrap_or("")).to_lowercase();
    if let Some(key) = domain_key(&dom) {
        let (ih, ip, sh, sp, sec, help, label) = preset(key).unwrap();
        return json!({"provider": key, "label": label, "help": help, "imap": {"host": ih, "port": ip},
                      "smtp": {"host": sh, "port": sp, "security": sec}});
    }
    json!({"provider": "", "label": dom, "help": "", "imap": {"host": format!("imap.{dom}"), "port": 993},
           "smtp": {"host": format!("smtp.{dom}"), "port": 465, "security": "ssl"}})
}

pub fn account_id(email: &str) -> String {
    sha1_smol::Sha1::from(crate::htmlparser::py_strip(email).to_lowercase().as_bytes()).digest().to_string()[..10].to_string()
}

pub fn load() -> Vec<Value> {
    std::fs::read_to_string(paths::accounts())
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .and_then(|v| v.get("accounts").and_then(Value::as_array).cloned())
        .unwrap_or_default()
}

/// json.dump(indent=2, ensure_ascii=False) like the Python wrote it
pub fn dumps_indent(v: &Value, indent: usize, level: usize) -> String {
    let pad = " ".repeat(indent * (level + 1));
    let end = " ".repeat(indent * level);
    match v {
        Value::Array(a) if !a.is_empty() => {
            let items: Vec<String> = a.iter().map(|x| format!("{pad}{}", dumps_indent(x, indent, level + 1))).collect();
            format!("[\n{}\n{end}]", items.join(",\n"))
        }
        Value::Object(o) if !o.is_empty() => {
            let items: Vec<String> =
                o.iter().map(|(k, x)| format!("{pad}{}: {}", pyjson::dumps(&Value::String(k.clone()), false), dumps_indent(x, indent, level + 1))).collect();
            format!("{{\n{}\n{end}}}", items.join(",\n"))
        }
        other => pyjson::dumps(other, false),
    }
}

pub fn save(accounts: &[Value]) -> std::io::Result<()> {
    paths::ensure();
    let tmp = paths::config().join(format!(".accounts.{}", std::process::id()));
    let mut f = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&tmp)?;
    f.write_all(dumps_indent(&json!({"accounts": accounts}), 2, 0).as_bytes())?;
    drop(f);
    std::fs::rename(&tmp, paths::accounts())
}

/// What the UI may see (no password).
pub fn public(a: &Value) -> Value {
    let mut m: Map<String, Value> = a.as_object().cloned().unwrap_or_default();
    let has = m.get("password").and_then(Value::as_str).is_some_and(|p| !p.is_empty());
    m.shift_remove("password");
    m.insert("hasPassword".into(), json!(has));
    Value::Object(m)
}

pub fn is_gmail(a: &Value) -> bool {
    a["provider"] == "gmail" || a["imap"]["host"].as_str().is_some_and(|h| h.ends_with("gmail.com"))
}

pub fn load_settings() -> Map<String, Value> {
    std::fs::read_to_string(paths::settings()).ok().and_then(|s| serde_json::from_str::<Value>(&s).ok()).and_then(|v| v.as_object().cloned()).unwrap_or_default()
}

pub fn save_settings(s: &Map<String, Value>) {
    paths::ensure();
    let tmp = paths::settings().with_extension("json.tmp");
    if std::fs::write(&tmp, dumps_indent(&Value::Object(s.clone()), 2, 0)).is_ok() {
        let _ = std::fs::rename(&tmp, paths::settings());
    }
}
