//! The reader's web view: HTML mails drawn by glass-mail-web (WebKitGTK offscreen) as a picture
//! plus link boxes, because quickshell can't host a web engine itself.
//!
//! One renderer runs at a time, started on first use and stopped after a few idle minutes (it
//! holds a WebKit web process, ~100 MB). Pictures are cached under the cache dir by the hash of
//! everything that shapes them, so reopening a mail or going back is instant.
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

use crate::paths;

const IDLE: Duration = Duration::from_secs(180);
const TIMEOUT: Duration = Duration::from_secs(40);

struct Proc {
    child: Child,
    stdin: ChildStdin,
    waiting: Arc<Mutex<HashMap<u64, Sender<Value>>>>,
    last: Instant,
}

static PROC: OnceLock<Mutex<Option<Proc>>> = OnceLock::new();
static NEXT: Mutex<u64> = Mutex::new(1);

/// glass-mail-web next to this binary, or GLASS_MAIL_WEB (tests / development)
pub fn renderer() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("GLASS_MAIL_WEB").filter(|p| !p.is_empty()) {
        return Some(PathBuf::from(p)).filter(|p| p.is_file());
    }
    let me = std::env::current_exe().ok()?;
    Some(me.parent()?.join("glass-mail-web")).filter(|p| p.is_file())
}

pub fn dir() -> PathBuf {
    paths::cache().join("web")
}

fn spawn() -> Result<Proc, String> {
    let bin = renderer().ok_or("the web view isn't installed")?;
    let mut child = Command::new(bin)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("couldn't start the web view: {e}"))?;
    let stdin = child.stdin.take().ok_or("no stdin")?;
    let stdout = child.stdout.take().ok_or("no stdout")?;
    let waiting: Arc<Mutex<HashMap<u64, Sender<Value>>>> = Arc::default();
    let w2 = waiting.clone();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else { break };
            let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
            if let Some(id) = v["id"].as_u64() {
                if let Some(tx) = w2.lock().unwrap().remove(&id) {
                    let _ = tx.send(v);
                }
            }
        }
        // the renderer died: wake everyone still waiting
        for (_, tx) in w2.lock().unwrap().drain() {
            let _ = tx.send(json!({"ok": false, "error": "the web view stopped"}));
        }
    });
    // stop it when idle
    std::thread::spawn(|| loop {
        std::thread::sleep(Duration::from_secs(30));
        let mut g = PROC.get().unwrap().lock().unwrap();
        let idle = g.as_ref().is_some_and(|p| p.last.elapsed() > IDLE && p.waiting.lock().unwrap().is_empty());
        if idle {
            if let Some(mut p) = g.take() {
                let _ = p.child.kill();
                let _ = p.child.wait();
            }
            return;
        }
        if g.is_none() {
            return;
        }
    });
    Ok(Proc { child, stdin, waiting, last: Instant::now() })
}

/// Old pictures out (two weeks), once per run.
fn sweep() {
    static DONE: OnceLock<()> = OnceLock::new();
    DONE.get_or_init(|| {
        let Ok(rd) = std::fs::read_dir(dir()) else { return };
        let old = SystemTime::now() - Duration::from_secs(14 * 86400);
        for e in rd.flatten() {
            if e.metadata().and_then(|m| m.modified()).is_ok_and(|t| t < old) {
                let _ = std::fs::remove_file(e.path());
            }
        }
    });
}

/// Draws `page` at `width` CSS px. -> {ok, png, w, h, paper, cut, links} or {ok: false, error}
pub fn render(page: &str, width: f64, zoom: f64) -> Value {
    sweep();
    let _ = std::fs::create_dir_all(dir());
    let key = sha1_smol::Sha1::from(format!("{width:.0}|{zoom:.2}|{page}")).digest().to_string();
    let png = dir().join(format!("{}.png", &key[..20]));
    let meta = dir().join(format!("{}.json", &key[..20]));
    if png.is_file() {
        if let Some(v) = std::fs::read_to_string(&meta).ok().and_then(|s| serde_json::from_str::<Value>(&s).ok()) {
            return v;
        }
    }
    let id = {
        let mut n = NEXT.lock().unwrap();
        *n += 1;
        *n
    };
    let (tx, rx) = channel();
    {
        let mut g = PROC.get_or_init(Mutex::default).lock().unwrap();
        let alive = g.as_mut().is_some_and(|p| p.child.try_wait().ok().flatten().is_none());
        if !alive {
            *g = match spawn() {
                Ok(p) => Some(p),
                Err(e) => return json!({"ok": false, "error": e}),
            };
        }
        let p = g.as_mut().unwrap();
        p.last = Instant::now();
        p.waiting.lock().unwrap().insert(id, tx);
        let req = json!({"id": id, "html": page, "width": width, "zoom": zoom, "out": png.to_string_lossy()});
        if writeln!(p.stdin, "{req}").and_then(|_| p.stdin.flush()).is_err() {
            p.waiting.lock().unwrap().remove(&id);
            let _ = p.child.kill();
            *g = None;
            return json!({"ok": false, "error": "the web view stopped"});
        }
    }
    let mut v = rx.recv_timeout(TIMEOUT).unwrap_or_else(|_| json!({"ok": false, "error": "the web view took too long"}));
    if let Some(p) = PROC.get().unwrap().lock().unwrap().as_mut() {
        p.last = Instant::now();
    }
    if let Some(o) = v.as_object_mut() {
        o.remove("id");
        o.remove("scale");
    }
    if v["ok"] == true {
        let _ = std::fs::write(&meta, v.to_string());
    }
    v
}

/// Remote things the page would load once images are allowed (img src, background=, url(…)).
pub fn remote_refs(page: &str) -> usize {
    static RE: OnceLock<regex::Regex> = OnceLock::new();
    RE.get_or_init(|| regex::Regex::new(r#"(?i)(?:\b(?:src|background|srcset)\s*=\s*["']?\s*https?://|url\(\s*["']?\s*https?://)"#).unwrap())
        .find_iter(page)
        .count()
}

/// Only plain colours reach the stylesheet.
fn color(c: &Value, k: &str, default: &str) -> String {
    let s = c[k].as_str().unwrap_or("");
    let ok = s.len() == 7 && s.starts_with('#') && s[1..].chars().all(|ch| ch.is_ascii_hexdigit());
    if ok { s.to_string() } else { default.to_string() }
}

/// The reader's stylesheet: prose mails blend into the glass in the theme's colours; designed
/// mails (own backgrounds, detected by the renderer -> html.gm-paper) sit on white paper.
pub fn css(colors: &Value) -> String {
    let text = color(colors, "text", "#dde4e4");
    let link = color(colors, "link", "#80d4db");
    let quote = color(colors, "quote", "#899393");
    let font = colors["font"].as_str().unwrap_or("").chars().filter(|c| c.is_alphanumeric() || *c == ' ' || *c == '-').collect::<String>();
    format!(
        "html{{background:transparent}}\
body{{margin:0;padding:4px 2px 12px;font:15px/1.6 \"{font}\",system-ui,sans-serif;color:{text};overflow-wrap:anywhere;-webkit-font-smoothing:antialiased}}\
a{{color:{link}}}img{{max-width:100%;height:auto}}\
blockquote{{margin:8px 0;padding:2px 0 2px 14px;border-left:3px solid {quote}55;color:{quote}}}\
pre,code{{font-family:\"JetBrains Mono\",monospace;font-size:13px;white-space:pre-wrap}}\
hr{{border:0;border-top:1px solid {text}22}}\
table{{border-collapse:collapse}}\
iframe,frame,object,embed,video,audio{{display:none!important}}\
html.gm-paper{{background:#ffffff}}\
html.gm-paper body{{color:#1d1d1f;padding:16px}}\
html.gm-paper a{{color:#0a66d8}}\
html.gm-paper blockquote{{color:#555;border-left-color:#ccc}}"
    )
}
