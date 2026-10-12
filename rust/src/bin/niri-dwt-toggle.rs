//! niri-dwt-toggle — turn the touchpad's disable-while-typing (libinput dwt) OFF while a game is
//! focused (Rust port of the Python script of the same name).
//!
//! niri has no per-window dwt, so this daemon flips the `dwt` line of the touchpad section in
//! ~/.config/niri/user/input.kdl (niri hot-reloads its config).
//!
//! A focused window counts as a game when (generic, no app names built in):
//!   * it covers its whole output (fullscreen, or borderless window sized to the output), or
//!   * it matches a pattern in the optional override file (see below).
//!
//! Event-driven only: it follows niri's event stream, never polls, and only writes the config when
//! the wanted state actually changes. On exit (niri quits, SIGTERM, error) it restores `dwt`.
//!
//! Override file: ~/.config/niri-dwt-toggle/overrides.conf (re-read when it changes)
//!     # one regex per line, matched (case-insensitive) against the app_id;
//!     # prefix with "title:" to match the window title instead
//!     ^steam_app_          -> always a game, even windowed (dwt off)
//!     !^mpv$               -> never a game, even fullscreen (dwt stays on)
//! First matching line wins.
use glass::niri::{self, EventStream};
use glass::util;
use regex::{Regex, RegexBuilder};
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime};

const TOLERANCE: f64 = 2.0; // logical px of slack when comparing a window to its output
const DEBOUNCE: Duration = Duration::from_millis(250); // collapses resize/focus bursts into one config write

fn log(msg: &str) {
    eprintln!("niri-dwt-toggle: {msg}");
}

fn cfg_path() -> PathBuf {
    util::home().join(".config/niri/user/input.kdl")
}

fn overrides_path() -> PathBuf {
    util::env_or("XDG_CONFIG_HOME", util::home().join(".config")).join("niri-dwt-toggle/overrides.conf")
}

fn dwt_re() -> Regex {
    Regex::new(r"(?m)^([ \t]*)(?://[ \t]*)?dwt[ \t]*$").unwrap()
}

/// Some(true/false) = current dwt line state, None = no dwt line.
fn file_dwt_state() -> Option<bool> {
    let text = std::fs::read_to_string(cfg_path()).ok()?;
    let m = dwt_re().find(&text)?;
    Some(!m.as_str().trim_start().starts_with("//"))
}

fn set_dwt(on: bool) {
    // re-read right before writing; touch nothing but the dwt line
    let text = match std::fs::read_to_string(cfg_path()) {
        Ok(t) => t,
        Err(e) => return log(&format!("cannot read {} {e}", cfg_path().display())),
    };
    let new = dwt_re().replacen(&text, 1, |c: &regex::Captures| format!("{}{}", &c[1], if on { "dwt" } else { "// dwt" })).into_owned();
    if new != text {
        if let Err(e) = std::fs::write(cfg_path(), new) {
            return log(&format!("cannot write {}: {e}", cfg_path().display()));
        }
        log(if on { "dwt ON" } else { "dwt OFF (game focused)" });
    }
}

struct Rule {
    negate: bool,
    title: bool,
    rx: Regex,
}

#[derive(Default)]
struct Overrides {
    mtime: Option<SystemTime>,
    loaded: bool,
    rules: Vec<Rule>,
}

impl Overrides {
    fn get(&mut self) -> &[Rule] {
        let p = overrides_path();
        let mt = std::fs::metadata(&p).and_then(|m| m.modified()).ok();
        if self.loaded && mt == self.mtime {
            return &self.rules;
        }
        (self.mtime, self.loaded, self.rules) = (mt, true, vec![]);
        if mt.is_some() {
            for ln in std::fs::read_to_string(&p).unwrap_or_default().lines() {
                let ln = ln.trim();
                if ln.is_empty() || ln.starts_with('#') {
                    continue;
                }
                let negate = ln.starts_with('!');
                let mut ln = if negate { ln[1..].trim() } else { ln };
                let title = ln.starts_with("title:");
                if title {
                    ln = ln[6..].trim();
                }
                match RegexBuilder::new(ln).case_insensitive(true).build() {
                    Ok(rx) => self.rules.push(Rule { negate, title, rx }),
                    Err(e) => log(&format!("bad pattern in {} {ln:?} {e}", p.display())),
                }
            }
        }
        &self.rules
    }
}

#[derive(Default)]
struct Dwt {
    windows: HashMap<u64, Value>,
    workspaces: HashMap<u64, Value>,
    outputs: HashMap<String, (f64, f64)>,
    focused: Option<u64>,
    overrides: Overrides,
}

impl Dwt {
    fn load_outputs(&mut self) {
        match niri::query("Outputs") {
            Ok(Value::Object(o)) => {
                self.outputs = o
                    .iter()
                    .filter_map(|(name, v)| {
                        let l = v.get("logical")?;
                        Some((name.clone(), (l["width"].as_f64()?, l["height"].as_f64()?)))
                    })
                    .collect();
            }
            Ok(_) => self.outputs.clear(),
            Err(e) => log(&format!("cannot read outputs: {e}")),
        }
    }

    fn covers_output(&self, w: &Value) -> bool {
        let Some(ws) = w["workspace_id"].as_u64().and_then(|i| self.workspaces.get(&i)) else { return false };
        let Some(size) = ws["output"].as_str().and_then(|o| self.outputs.get(o)) else { return false };
        ["window_size", "tile_size"].iter().any(|k| {
            let s = &w["layout"][k];
            match (s[0].as_f64(), s[1].as_f64()) {
                (Some(a), Some(b)) => a >= size.0 - TOLERANCE && b >= size.1 - TOLERANCE,
                _ => false,
            }
        })
    }

    fn is_game(&mut self, w: &Value) -> bool {
        for r in self.overrides.get() {
            let field = if r.title { &w["title"] } else { &w["app_id"] };
            if r.rx.is_match(field.as_str().unwrap_or("")) {
                return !r.negate;
            }
        }
        self.covers_output(w)
    }

    fn wanted_dwt(&mut self) -> bool {
        match self.focused.and_then(|id| self.windows.get(&id)).cloned() {
            Some(w) => !self.is_game(&w),
            None => true,
        }
    }
}

fn run() {
    let lock_path = util::runtime_dir().join("niri-dwt-toggle.lock");
    let _lock = match util::try_lock(&lock_path) {
        Ok(Some(f)) => f,
        _ => return log("already running"),
    };
    let verbose = std::env::args().any(|a| a == "-v");
    let sig = util::signal_pipe(&[libc::SIGTERM, libc::SIGHUP, libc::SIGINT]).expect("signal pipe");
    let mut d = Dwt::default();
    d.load_outputs();
    let mut applied = file_dwt_state();
    let mut pending: Option<bool> = None;
    let mut due = Instant::now();
    let mut es = match EventStream::connect() {
        Ok(e) => e,
        Err(e) => {
            log(&format!("cannot open the event stream: {e}"));
            set_dwt(true);
            return;
        }
    };
    loop {
        let timeout = pending.map(|_| due.saturating_duration_since(Instant::now()));
        let ready = util::poll_read(&[es.fd(), sig], timeout).unwrap_or(vec![false, false]);
        if ready[1] {
            util::drain_signals(sig);
            if util::terminated() {
                break;
            }
        }
        if !ready[0] {
            if ready[1] {
                continue;
            }
            // debounce elapsed
            if let Some(p) = pending.take() {
                if Some(p) != applied {
                    set_dwt(p);
                    applied = Some(p);
                }
            }
            continue;
        }
        let evs = match es.read() {
            Ok(Some(evs)) => evs,
            _ => {
                log("event stream closed");
                break;
            }
        };
        for ev in evs {
            let Some((name, e)) = ev.as_object().and_then(|o| o.iter().next()) else { continue };
            match name.as_str() {
                "WindowsChanged" => {
                    d.windows = e["windows"].as_array().into_iter().flatten().filter_map(|w| Some((w["id"].as_u64()?, w.clone()))).collect();
                    d.focused = d.windows.values().find(|w| w["is_focused"] == true).and_then(|w| w["id"].as_u64());
                }
                "WindowOpenedOrChanged" => {
                    let w = &e["window"];
                    if let Some(id) = w["id"].as_u64() {
                        d.windows.insert(id, w.clone());
                        if w["is_focused"] == true {
                            d.focused = Some(id);
                        } else if d.focused == Some(id) {
                            d.focused = None;
                        }
                    }
                }
                "WindowClosed" => {
                    if let Some(id) = e["id"].as_u64() {
                        d.windows.remove(&id);
                    }
                }
                "WindowFocusChanged" => d.focused = e["id"].as_u64(),
                "WindowLayoutsChanged" => {
                    for c in e["changes"].as_array().into_iter().flatten() {
                        if let Some(w) = c[0].as_u64().and_then(|id| d.windows.get_mut(&id)) {
                            w["layout"] = c[1].clone();
                        }
                    }
                }
                "WorkspacesChanged" => {
                    d.workspaces = e["workspaces"].as_array().into_iter().flatten().filter_map(|w| Some((w["id"].as_u64()?, w.clone()))).collect();
                    if d.workspaces.values().any(|w| w["output"].as_str().is_some_and(|o| !d.outputs.contains_key(o))) {
                        d.load_outputs();
                    }
                }
                "ConfigLoaded" => {
                    d.load_outputs(); // scale/mode may have changed
                    applied = file_dwt_state(); // the file may have been edited by hand
                }
                _ => continue,
            }
            let want = d.wanted_dwt();
            if verbose {
                log(&format!("event {name} focused {:?} want dwt {want}", d.focused));
            }
            if Some(want) != applied {
                if pending != Some(want) {
                    pending = Some(want);
                    due = Instant::now() + DEBOUNCE;
                }
            } else {
                pending = None;
            }
        }
    }
    set_dwt(true);
}

fn main() {
    run();
}
