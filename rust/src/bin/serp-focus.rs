//! serp-focus — the focused app for Serpantinum's CurrentFocus (niri port of scripts/current_focus.sh).
//!
//! Prints `{"timestamp":…,"app_class":"…","app_title":"…"}` whenever the focused window's class or title
//! changes, and mirrors it into $RUN_DIR/focus_state.json (rewritten in place) and focus_events.jsonl
//! (kept to the last 200 lines), RUN_DIR = $QS_RUN_FOCUSTIME or $XDG_RUNTIME_DIR/serpantinum/focustime.
//! The script asked `niri msg -j focused-window | jq` after every focus-ish event; this reads it
//! straight from the event stream.
use glass::niri::{EventStream, State};
use glass::util;
use serde_json::Value;
use std::ffi::CString;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

static PID_FILE: OnceLock<CString> = OnceLock::new();

/// (class, title) exactly as current_focus.sh derives them from `niri msg -j focused-window`.
pub fn resolve(w: Option<&Value>) -> (String, String) {
    let w = match w {
        Some(w) if w.is_object() => w,
        _ => return ("Desktop".into(), "Desktop".into()),
    };
    // jq: (.app_id // "Unknown") as $c | "\(.id)|\($c)|\(.title // $c)"; `//` skips null and false
    let alt = |v: &Value| -> Option<String> {
        match v {
            Value::Null | Value::Bool(false) => None,
            Value::String(s) => Some(s.clone()),
            other => Some(other.to_string()),
        }
    };
    let c = alt(&w["app_id"]).unwrap_or_else(|| "Unknown".into());
    let t = alt(&w["title"]).unwrap_or_else(|| c.clone());
    // `IFS='|' read -r id cls title`: one line only; the class ends at the first '|'
    let line = format!("{c}|{t}");
    let line = line.split('\n').next().unwrap_or("");
    let (mut cls, mut title) = match line.split_once('|') {
        Some((a, b)) => (a.to_string(), b.to_string()),
        None => (line.to_string(), String::new()),
    };
    if cls.is_empty() {
        cls = "Desktop".into();
    }
    if title.is_empty() {
        title = "Desktop".into();
    }
    let (cl, tl) = (cls.to_lowercase(), title.to_lowercase());
    if cl.contains("quickshell") || tl.contains("qs-master") || cl.contains("qs-master") {
        return ("Quickshell".into(), "Quickshell".into());
    }
    (cls, title)
}

/// The script's escaping: \ " \n \r \t only.
pub fn esc(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n").replace('\r', "\\r").replace('\t', "\\t")
}

fn trim_log(log: &Path) {
    if let Ok(text) = fs::read_to_string(log) {
        let lines: Vec<&str> = text.lines().collect();
        let keep = &lines[lines.len().saturating_sub(200)..];
        let mut out = keep.join("\n");
        if !keep.is_empty() {
            out.push('\n');
        }
        let _ = util::write_atomic(log, out.as_bytes());
    }
}

struct Out {
    state: PathBuf,
    log: PathBuf,
    appended: u32,
    last: Option<(String, String)>,
}

impl Out {
    fn emit(&mut self, cls: String, title: String) {
        if self.last.as_ref() == Some(&(cls.clone(), title.clone())) {
            return;
        }
        let ts = util::now_unix() as i64;
        let line = format!("{{\"timestamp\":{ts},\"app_class\":\"{}\",\"app_title\":\"{}\"}}", esc(&cls), esc(&title));
        self.last = Some((cls, title));
        util::emit(&line);
        let _ = util::write_in_place(&self.state, format!("{line}\n").as_bytes());
        if let Ok(mut f) = OpenOptions::new().append(true).create(true).open(&self.log) {
            let _ = writeln!(f, "{line}");
        }
        self.appended += 1;
        if self.appended >= 100 {
            self.appended = 0;
            trim_log(&self.log);
        }
    }
}

extern "C" fn bye(_: libc::c_int) {
    if let Some(p) = PID_FILE.get() {
        unsafe { libc::unlink(p.as_ptr()) };
    }
    unsafe { libc::_exit(0) };
}

fn replace_old_instance(pid_file: &Path) {
    if let Some(old) = util::read_trim(pid_file).and_then(|s| s.parse::<i32>().ok()) {
        let me = std::process::id() as i32;
        if old != me && util::pid_alive(old) {
            unsafe { libc::kill(old, libc::SIGTERM) };
            for _ in 0..5 {
                if !util::pid_alive(old) {
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            unsafe { libc::kill(old, libc::SIGKILL) };
        }
    }
    let _ = fs::write(pid_file, format!("{}\n", std::process::id()));
}

fn main() {
    util::ignore_sigpipe();
    let run_dir = util::env_or("QS_RUN_FOCUSTIME", util::runtime_dir().join("serpantinum/focustime"));
    let _ = fs::create_dir_all(&run_dir);
    let pid_file = run_dir.join("current_focus.pid");
    let mut out = Out { state: run_dir.join("focus_state.json"), log: run_dir.join("focus_events.jsonl"), appended: 0, last: None };
    for p in [&out.log, &out.state] {
        let _ = OpenOptions::new().append(true).create(true).open(p);
    }
    trim_log(&out.log);
    replace_old_instance(&pid_file);
    let _ = PID_FILE.set(CString::new(pid_file.as_os_str().as_encoded_bytes()).unwrap());
    unsafe {
        libc::signal(libc::SIGTERM, bye as *const () as usize);
        libc::signal(libc::SIGINT, bye as *const () as usize);
    }

    let mut first_connect = true;
    loop {
        let mut es = match EventStream::connect() {
            Ok(e) => e,
            Err(_) => {
                if first_connect {
                    out.emit("Desktop".into(), "Desktop".into());
                }
                first_connect = false;
                std::thread::sleep(Duration::from_secs(1));
                continue;
            }
        };
        first_connect = false;
        let mut st = State::default();
        'stream: loop {
            let mut first = true;
            loop {
                if !first && !matches!(util::poll_read(&[es.fd()], Some(Duration::from_millis(20))), Ok(r) if r[0]) {
                    break;
                }
                first = false;
                match es.read() {
                    Ok(Some(evs)) => evs.iter().for_each(|e| {
                        st.apply(e);
                    }),
                    _ => break 'stream,
                }
            }
            if st.have_windows {
                let (c, t) = resolve(st.focused_window());
                out.emit(c, t);
            }
        }
        std::thread::sleep(Duration::from_secs(1));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn resolves_like_the_script() {
        assert_eq!(resolve(None), ("Desktop".into(), "Desktop".into()));
        assert_eq!(resolve(Some(&json!({"app_id": "kitty", "title": "zsh"}))), ("kitty".into(), "zsh".into()));
        assert_eq!(resolve(Some(&json!({"app_id": null, "title": null}))), ("Unknown".into(), "Unknown".into()));
        assert_eq!(resolve(Some(&json!({"app_id": "", "title": ""}))), ("Desktop".into(), "Desktop".into()));
        assert_eq!(resolve(Some(&json!({"app_id": "foo", "title": "a\nb"}))), ("foo".into(), "a".into()));
        assert_eq!(resolve(Some(&json!({"app_id": "foo", "title": "a | b"}))), ("foo".into(), "a | b".into()));
        assert_eq!(resolve(Some(&json!({"app_id": "org.quickshell", "title": "x"}))), ("Quickshell".into(), "Quickshell".into()));
        assert_eq!(resolve(Some(&json!({"app_id": "x", "title": "QS-Master bar"}))), ("Quickshell".into(), "Quickshell".into()));
    }

    #[test]
    fn escapes_like_the_script() {
        assert_eq!(esc("a\"b\\c\td"), "a\\\"b\\\\c\\td");
    }
}
