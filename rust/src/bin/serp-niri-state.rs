//! serp-niri-state — workspaces + windows of niri as a stream of JSON lines.
//!
//!   serp-niri-state          one line `{"workspaces":[…],"windows":[…]}` now and whenever it changes
//!   serp-niri-state --once   one line, then exit
//!
//! Replaces the bar/dock pollers that ran `bash -c 'niri msg -j workspaces; niri msg -j windows'`
//! after (almost) every niri event. This keeps the state from the event stream itself, and prints a
//! line only when something the workspace indicators use changes: window titles (terminal spinners
//! retitle a window every second) and layouts never cause output.
use glass::niri::{self, EventStream, State};
use glass::util;
use serde_json::{json, Map, Value};
use std::time::Duration;

const WINDOW_KEYS: [&str; 5] = ["id", "workspace_id", "app_id", "is_focused", "is_floating"];

fn snapshot(st: &State) -> String {
    let windows: Vec<Value> = st
        .windows
        .values()
        .map(|w| {
            let mut m = Map::new();
            for k in WINDOW_KEYS {
                m.insert(k.into(), w.get(k).cloned().unwrap_or(Value::Null));
            }
            Value::Object(m)
        })
        .collect();
    let workspaces: Vec<&Value> = st.workspaces.values().collect();
    json!({ "workspaces": workspaces, "windows": windows }).to_string()
}

fn once() -> i32 {
    let mut st = State::default();
    let ws = niri::query("Workspaces").unwrap_or(Value::Array(vec![]));
    let win = niri::query("Windows").unwrap_or(Value::Array(vec![]));
    st.apply(&json!({ "WorkspacesChanged": { "workspaces": ws } }));
    st.apply(&json!({ "WindowsChanged": { "windows": win } }));
    util::emit(&snapshot(&st));
    0
}

fn main() {
    util::ignore_sigpipe();
    if std::env::args().nth(1).as_deref() == Some("--once") {
        std::process::exit(once());
    }
    let mut es = match EventStream::connect() {
        Ok(e) => e,
        Err(e) => {
            eprintln!("serp-niri-state: {e}");
            std::process::exit(1);
        }
    };
    let mut st = State::default();
    let mut last = String::new();
    loop {
        // read one burst: keep reading while more arrives within 15 ms (niri sends
        // WorkspacesChanged + WindowsChanged + … back to back), then publish once
        let mut first = true;
        loop {
            if !first {
                match util::poll_read(&[es.fd()], Some(Duration::from_millis(15))) {
                    Ok(r) if r[0] => {}
                    _ => break,
                }
            }
            first = false;
            match es.read() {
                Ok(Some(evs)) => {
                    for ev in &evs {
                        st.apply(ev);
                    }
                }
                Ok(None) => std::process::exit(2), // niri went away; the shell restarts us
                Err(e) => {
                    eprintln!("serp-niri-state: {e}");
                    std::process::exit(2);
                }
            }
        }
        if st.have_workspaces && st.have_windows {
            let s = snapshot(&st);
            if s != last {
                util::emit(&s);
                last = s;
            }
        }
    }
}
