//! niri-autofit — Sway-like auto-fit for niri (Rust port of the Python script of the same name).
//!
//! When the number of tiled columns on a workspace changes, a lone column fills the screen and every
//! other count splits into halves (3+ columns scroll two at a time). Manual resizes are left alone
//! until a window opens, closes or gets stacked into another column.
//!
//!   niri-autofit          run the daemon (started from niri's autostart)
//!   niri-autofit toggle   switch the focused workspace between auto-fit and scrolling
//!
//! Talks to niri's socket directly: no `niri msg` process per resize.
use glass::niri::{self, EventStream};
use glass::util;
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::path::PathBuf;
use std::time::Duration;

const DEBOUNCE: Duration = Duration::from_millis(12); // long enough to skip half-updated layouts

fn run_dir() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| "/tmp".into()).join("niri-autofit")
}

fn read_scroll_ids() -> BTreeSet<u64> {
    std::fs::read_to_string(run_dir().join("scroll-ids"))
        .map(|s| s.split_whitespace().filter_map(|x| x.parse().ok()).collect())
        .unwrap_or_default()
}

fn log(msg: &str) {
    if std::env::var_os("NIRI_AUTOFIT_DEBUG").is_some_and(|v| !v.is_empty()) {
        eprintln!("{msg}");
    }
}

fn act(name: &str, fields: Value) {
    let _ = niri::action(name, fields);
}

fn toggle() {
    let ws = niri::query("Workspaces").unwrap_or(Value::Null);
    let Some(ws) = ws.as_array().and_then(|a| a.iter().find(|w| w["is_focused"] == true)).cloned() else { return };
    let id = ws["id"].as_u64().unwrap_or(0);
    let mut ids = read_scroll_ids();
    if !ids.remove(&id) {
        ids.insert(id);
    }
    let _ = std::fs::create_dir_all(run_dir());
    let _ = std::fs::write(run_dir().join("scroll-ids"), ids.iter().map(u64::to_string).collect::<Vec<_>>().join(" "));
    if let Some(pid) = util::read_trim(run_dir().join("pid")).and_then(|s| s.parse::<i32>().ok()) {
        unsafe { libc::kill(pid, libc::SIGUSR1) };
    }
    let mode = if ids.contains(&id) { "scrolling" } else { "auto-fit" };
    let _ = std::process::Command::new("notify-send")
        .args(["-a", "niri", "-u", "low", "-t", "1500", "-h", "string:x-canonical-private-synchronous:niri-autofit"])
        .arg(format!("Workspace {}: {mode}", ws["idx"]))
        .stderr(std::process::Stdio::null())
        .status();
}

/// Windows in the order the Python dict kept them (insertion order; replacing keeps the position).
#[derive(Default)]
struct Windows(Vec<(u64, Value)>);

impl Windows {
    fn get(&self, id: u64) -> Option<&Value> {
        self.0.iter().find(|(i, _)| *i == id).map(|(_, w)| w)
    }
    fn set(&mut self, id: u64, w: Value) {
        match self.0.iter_mut().find(|(i, _)| *i == id) {
            Some(slot) => slot.1 = w,
            None => self.0.push((id, w)),
        }
    }
    fn remove(&mut self, id: u64) {
        self.0.retain(|(i, _)| *i != id);
    }
}

fn col_of(w: &Value) -> Option<i64> {
    w["layout"]["pos_in_scrolling_layout"].get(0).and_then(Value::as_i64)
}

struct Autofit {
    windows: Windows,
    counts: std::collections::HashMap<u64, usize>,
    focused_ws: Option<u64>,
    focused_win: Option<u64>,
    scroll_ids: BTreeSet<u64>,
}

impl Autofit {
    /// column index -> the first window id seen in it (stacked/tabbed columns count once), in order
    fn columns(&self, ws: u64) -> Vec<(i64, u64)> {
        let mut cols: Vec<(i64, u64)> = vec![];
        for (id, w) in &self.windows.0 {
            if w["workspace_id"].as_u64() != Some(ws) || w["is_floating"] == true {
                continue;
            }
            let pos = &w["layout"]["pos_in_scrolling_layout"];
            if pos.as_array().is_some_and(|a| !a.is_empty()) {
                if let Some(c) = pos[0].as_i64() {
                    if !cols.iter().any(|(k, _)| *k == c) {
                        cols.push((c, *id));
                    }
                }
            }
        }
        cols
    }

    fn fit(&self, ws: u64) {
        let cols = self.columns(ws);
        let shown: Vec<String> = cols.iter().map(|(c, id)| format!("{c}: {id}")).collect();
        log(&format!("fit ws={ws} cols={{{}}}", shown.join(", ")));
        if cols.is_empty() {
            return;
        }
        let width = if cols.len() == 1 { 100.0 } else { 50.0 };
        for (_, wid) in &cols {
            act("SetWindowWidth", json!({"id": wid, "change": {"SetProportion": width}}));
        }
        if Some(ws) == self.focused_ws && cols.len() >= 2 {
            self.fill_screen(ws, cols.iter().map(|(c, _)| *c).max().unwrap());
        }
    }

    /// After a close, niri keeps the old scroll position, which can leave an empty half next to an edge
    /// column. Stepping focus away and back makes niri scroll the minimum needed, so two whole columns
    /// fill the screen again.
    fn fill_screen(&self, ws: u64, last_col: i64) {
        let Some(w) = self.focused_win.and_then(|id| self.windows.get(id)) else { return };
        if w["workspace_id"].as_u64() != Some(ws) || w["is_floating"] == true {
            return;
        }
        let col = col_of(w).unwrap_or(0);
        if col == last_col {
            act("FocusColumnLeft", json!({}));
            act("FocusColumnRight", json!({}));
        } else if col == 1 {
            act("FocusColumnRight", json!({}));
            act("FocusColumnLeft", json!({}));
        }
    }

    fn refresh(&mut self, initial: bool) {
        let mut ws_ids: BTreeSet<u64> = self.windows.0.iter().filter_map(|(_, w)| w["workspace_id"].as_u64()).collect();
        ws_ids.extend(self.counts.keys().copied());
        for ws in ws_ids {
            let n = self.columns(ws).len();
            if n == 0 {
                self.counts.remove(&ws);
                continue;
            }
            if self.counts.get(&ws) == Some(&n) {
                continue;
            }
            let old = self.counts.get(&ws).map_or("None".to_string(), |c| c.to_string());
            log(&format!("ws={ws} columns {old} -> {n}"));
            self.counts.insert(ws, n);
            if !initial && !self.scroll_ids.contains(&ws) {
                self.fit(ws);
            }
        }
    }

    fn handle(&mut self, ev: &Value) {
        let Some((name, e)) = ev.as_object().and_then(|o| o.iter().next()) else { return };
        match name.as_str() {
            "WindowsChanged" => {
                self.windows = Windows::default();
                for w in e["windows"].as_array().into_iter().flatten() {
                    if let Some(id) = w["id"].as_u64() {
                        self.windows.set(id, w.clone());
                    }
                }
                self.focused_win = self.windows.0.iter().find(|(_, w)| w["is_focused"] == true).map(|(i, _)| *i);
            }
            "WindowOpenedOrChanged" => {
                let w = &e["window"];
                if let Some(id) = w["id"].as_u64() {
                    self.windows.set(id, w.clone());
                    if w["is_focused"] == true {
                        self.focused_win = Some(id);
                    }
                }
            }
            "WindowFocusChanged" => self.focused_win = e["id"].as_u64(),
            "WindowClosed" => {
                if let Some(id) = e["id"].as_u64() {
                    self.windows.remove(id);
                }
            }
            "WindowLayoutsChanged" => {
                for c in e["changes"].as_array().into_iter().flatten() {
                    if let Some(id) = c[0].as_u64() {
                        if let Some(slot) = self.windows.0.iter_mut().find(|(i, _)| *i == id) {
                            slot.1["layout"] = c[1].clone();
                        }
                    }
                }
            }
            "WorkspacesChanged" => {
                if let Some(id) = e["workspaces"].as_array().and_then(|a| a.iter().find(|w| w["is_focused"] == true)).and_then(|w| w["id"].as_u64()) {
                    self.focused_ws = Some(id);
                }
            }
            "WorkspaceActivated" => {
                if e["focused"] == true {
                    self.focused_ws = e["id"].as_u64();
                }
            }
            _ => {}
        }
    }
}

fn single_instance() {
    let dir = run_dir();
    let _ = std::fs::create_dir_all(&dir);
    let me = std::process::id() as i32;
    if let Some(old) = util::read_trim(dir.join("pid")).and_then(|s| s.parse::<i32>().ok()) {
        if let Ok(cmd) = std::fs::read(format!("/proc/{old}/cmdline")) {
            if old != me && cmd.windows(12).any(|w| w == b"niri-autofit") {
                unsafe { libc::kill(old, libc::SIGTERM) };
            }
        }
    }
    let _ = std::fs::write(dir.join("pid"), me.to_string());
}

fn daemon() {
    single_instance();
    let sig = util::signal_pipe(&[libc::SIGUSR1]).expect("signal pipe");
    let mut es = match EventStream::connect() {
        Ok(e) => e,
        Err(e) => {
            eprintln!("niri-autofit: {e}");
            std::process::exit(1);
        }
    };
    let mut a = Autofit {
        windows: Windows::default(),
        counts: Default::default(),
        focused_ws: None,
        focused_win: None,
        scroll_ids: read_scroll_ids(),
    };
    let (mut initial, mut dirty) = (true, false);
    loop {
        let ready = match util::poll_read(&[es.fd(), sig], if dirty { Some(DEBOUNCE) } else { None }) {
            Ok(r) => r,
            Err(_) => continue,
        };
        if ready[1] {
            util::drain_signals(sig);
            let old = std::mem::replace(&mut a.scroll_ids, read_scroll_ids());
            for ws in old.difference(&a.scroll_ids) {
                a.fit(*ws); // switched back to auto-fit: even out now
            }
        }
        if ready[0] {
            match es.read() {
                Ok(Some(evs)) => evs.iter().for_each(|e| a.handle(e)),
                _ => break, // niri exited
            }
            dirty = true;
        } else if !ready[1] && dirty {
            a.refresh(initial);
            initial = false;
            dirty = false;
        }
    }
}

fn main() {
    if std::env::args().skip(1).collect::<Vec<_>>() == ["toggle"] {
        toggle();
    } else {
        daemon();
    }
}
