//! niri IPC over its Unix socket (no `niri msg` processes): one JSON request per line,
//! and the event stream mirrored into a local state the same way niri-ipc's EventStreamState does.
use crate::util::{self, LineBuf};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::io::{self, Write};
use std::os::unix::io::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

/// The newest niri socket in the runtime dir whose compositor is still alive.
pub fn discover() -> Option<PathBuf> {
    let dir = util::runtime_dir();
    let mut socks: Vec<(std::time::SystemTime, PathBuf)> = std::fs::read_dir(&dir)
        .ok()?
        .filter_map(|e| e.ok())
        .filter_map(|e| {
            let name = e.file_name().into_string().ok()?;
            if !(name.starts_with("niri.") && name.ends_with(".sock")) {
                return None;
            }
            let pid: i32 = name.trim_end_matches(".sock").rsplit('.').next()?.parse().ok()?;
            if !std::path::Path::new(&format!("/proc/{pid}")).exists() {
                return None;
            }
            Some((e.metadata().ok()?.modified().ok()?, e.path()))
        })
        .collect();
    socks.sort();
    socks.pop().map(|(_, p)| p)
}

/// $NIRI_SOCKET when it exists, else [`discover`].
pub fn socket_path() -> Option<PathBuf> {
    match std::env::var_os("NIRI_SOCKET") {
        Some(p) if !p.is_empty() && std::path::Path::new(&p).exists() => Some(PathBuf::from(p)),
        _ => discover(),
    }
}

fn connect() -> io::Result<UnixStream> {
    let p = socket_path().ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no niri socket"))?;
    let s = UnixStream::connect(p)?;
    s.set_write_timeout(Some(Duration::from_secs(5)))?;
    Ok(s)
}

fn reply(line: &[u8]) -> io::Result<Value> {
    let v: Value = serde_json::from_slice(line).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    match v {
        Value::Object(mut m) => {
            if let Some(ok) = m.remove("Ok") {
                Ok(ok)
            } else {
                Err(io::Error::other(m.remove("Err").map(|e| e.to_string()).unwrap_or_default()))
            }
        }
        _ => Err(io::Error::new(io::ErrorKind::InvalidData, "unexpected reply")),
    }
}

/// Send one request, return the `Ok` payload.
pub fn request(req: &Value) -> io::Result<Value> {
    let mut s = connect()?;
    s.set_read_timeout(Some(Duration::from_secs(5)))?;
    s.write_all(format!("{req}\n").as_bytes())?;
    let mut lb = LineBuf::new(s);
    match lb.next_line()? {
        Some(l) => reply(&l),
        None => Err(io::Error::new(io::ErrorKind::UnexpectedEof, "niri closed the socket")),
    }
}

/// `{"Action": {name: fields}}`; errors are returned, most callers ignore them like `niri msg` did.
pub fn action(name: &str, fields: Value) -> io::Result<Value> {
    request(&json!({ "Action": { name: fields } }))
}

/// Workspaces / Windows / FocusedWindow / Outputs: the payload under its own name.
pub fn query(name: &str) -> io::Result<Value> {
    let mut v = request(&Value::String(name.into()))?;
    Ok(v.get_mut(name).map(Value::take).unwrap_or(Value::Null))
}

pub struct EventStream {
    pub lines: LineBuf<UnixStream>,
}

impl EventStream {
    pub fn connect() -> io::Result<Self> {
        let mut s = connect()?;
        s.write_all(b"\"EventStream\"\n")?;
        let mut lines = LineBuf::new(s);
        match lines.next_line()? {
            Some(l) => {
                reply(&l)?;
            }
            None => return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "niri closed the event stream")),
        }
        Ok(Self { lines })
    }
    pub fn fd(&self) -> RawFd {
        self.lines.inner.as_raw_fd()
    }
    /// Read once (blocking) and parse the complete events; `None` when niri closed the stream.
    pub fn read(&mut self) -> io::Result<Option<Vec<Value>>> {
        if !self.lines.fill()? {
            return Ok(None);
        }
        Ok(Some(self.lines.lines().iter().filter_map(|l| serde_json::from_slice(l).ok()).collect()))
    }
}

pub fn id_of(v: &Value) -> Option<u64> {
    v.get("id").and_then(Value::as_u64)
}

/// The compositor state as the event stream describes it.
#[derive(Default, Debug)]
pub struct State {
    pub workspaces: BTreeMap<u64, Value>,
    pub windows: BTreeMap<u64, Value>,
    pub have_workspaces: bool,
    pub have_windows: bool,
}

impl State {
    /// Apply one event; returns its name (the single key of the event object).
    pub fn apply<'a>(&mut self, ev: &'a Value) -> Option<&'a str> {
        let (name, e) = ev.as_object()?.iter().next()?;
        match name.as_str() {
            "WorkspacesChanged" => {
                self.workspaces = e["workspaces"]
                    .as_array()
                    .map(|a| a.iter().filter_map(|w| Some((id_of(w)?, w.clone()))).collect())
                    .unwrap_or_default();
                self.have_workspaces = true;
            }
            "WorkspaceActivated" => {
                let id = e["id"].as_u64();
                let focused = e["focused"].as_bool().unwrap_or(false);
                let output = id.and_then(|i| self.workspaces.get(&i)).map(|w| w["output"].clone());
                if let Some(output) = output {
                    for w in self.workspaces.values_mut() {
                        let hit = id_of(w) == id;
                        if w["output"] == output {
                            w["is_active"] = Value::Bool(hit);
                        }
                        if focused {
                            w["is_focused"] = Value::Bool(hit);
                        }
                    }
                }
            }
            "WorkspaceActiveWindowChanged" => {
                if let Some(w) = e["workspace_id"].as_u64().and_then(|i| self.workspaces.get_mut(&i)) {
                    w["active_window_id"] = e["active_window_id"].clone();
                }
            }
            "WorkspaceUrgencyChanged" => {
                if let Some(w) = e["id"].as_u64().and_then(|i| self.workspaces.get_mut(&i)) {
                    w["is_urgent"] = e["urgent"].clone();
                }
            }
            "WindowsChanged" => {
                self.windows = e["windows"]
                    .as_array()
                    .map(|a| a.iter().filter_map(|w| Some((id_of(w)?, w.clone()))).collect())
                    .unwrap_or_default();
                self.have_windows = true;
            }
            "WindowOpenedOrChanged" => {
                let w = &e["window"];
                if let Some(id) = id_of(w) {
                    if w["is_focused"].as_bool() == Some(true) {
                        for o in self.windows.values_mut() {
                            o["is_focused"] = Value::Bool(false);
                        }
                    }
                    self.windows.insert(id, w.clone());
                }
            }
            "WindowClosed" => {
                if let Some(id) = e["id"].as_u64() {
                    self.windows.remove(&id);
                }
            }
            "WindowFocusChanged" => {
                let id = e["id"].as_u64();
                for (wid, o) in self.windows.iter_mut() {
                    o["is_focused"] = Value::Bool(Some(*wid) == id);
                }
            }
            "WindowFocusTimestampChanged" => {
                if let Some(w) = e["id"].as_u64().and_then(|i| self.windows.get_mut(&i)) {
                    w["focus_timestamp"] = e["focus_timestamp"].clone();
                }
            }
            "WindowUrgencyChanged" => {
                if let Some(w) = e["id"].as_u64().and_then(|i| self.windows.get_mut(&i)) {
                    w["is_urgent"] = e["urgent"].clone();
                }
            }
            "WindowLayoutsChanged" => {
                if let Some(changes) = e["changes"].as_array() {
                    for c in changes {
                        if let (Some(id), Some(layout)) = (c[0].as_u64(), c.get(1)) {
                            if let Some(w) = self.windows.get_mut(&id) {
                                w["layout"] = layout.clone();
                            }
                        }
                    }
                }
            }
            _ => {}
        }
        Some(name.as_str())
    }

    pub fn focused_window(&self) -> Option<&Value> {
        self.windows.values().find(|w| w["is_focused"].as_bool() == Some(true))
    }

    pub fn focused_workspace(&self) -> Option<&Value> {
        self.workspaces.values().find(|w| w["is_focused"].as_bool() == Some(true))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(s: &str) -> Value {
        serde_json::from_str(s).unwrap()
    }

    #[test]
    fn workspace_activation_is_per_output() {
        let mut st = State::default();
        st.apply(&ev(r#"{"WorkspacesChanged":{"workspaces":[
            {"id":1,"idx":1,"output":"A","is_active":true,"is_focused":true,"active_window_id":null},
            {"id":2,"idx":2,"output":"A","is_active":false,"is_focused":false,"active_window_id":null},
            {"id":3,"idx":1,"output":"B","is_active":true,"is_focused":false,"active_window_id":null}]}}"#));
        st.apply(&ev(r#"{"WorkspaceActivated":{"id":2,"focused":true}}"#));
        assert_eq!(st.workspaces[&1]["is_active"], false);
        assert_eq!(st.workspaces[&2]["is_active"], true);
        assert_eq!(st.workspaces[&3]["is_active"], true, "other output keeps its active workspace");
        assert_eq!(st.focused_workspace().unwrap()["id"], 2);
        st.apply(&ev(r#"{"WorkspaceActivated":{"id":3,"focused":false}}"#));
        assert_eq!(st.focused_workspace().unwrap()["id"], 2, "unfocused activation keeps focus");
    }

    #[test]
    fn window_focus_and_layout() {
        let mut st = State::default();
        st.apply(&ev(r#"{"WindowsChanged":{"windows":[
            {"id":5,"app_id":"a","is_focused":true,"layout":{"pos_in_scrolling_layout":[1,1]}},
            {"id":6,"app_id":"b","is_focused":false,"layout":{"pos_in_scrolling_layout":[2,1]}}]}}"#));
        assert_eq!(st.focused_window().unwrap()["id"], 5);
        st.apply(&ev(r#"{"WindowOpenedOrChanged":{"window":{"id":7,"app_id":"c","is_focused":true}}}"#));
        assert_eq!(st.focused_window().unwrap()["id"], 7);
        assert_eq!(st.windows[&5]["is_focused"], false);
        st.apply(&ev(r#"{"WindowFocusChanged":{"id":6}}"#));
        assert_eq!(st.focused_window().unwrap()["id"], 6);
        st.apply(&ev(r#"{"WindowFocusChanged":{"id":null}}"#));
        assert!(st.focused_window().is_none());
        st.apply(&ev(r#"{"WindowLayoutsChanged":{"changes":[[6,{"pos_in_scrolling_layout":[1,1]}]]}}"#));
        assert_eq!(st.windows[&6]["layout"]["pos_in_scrolling_layout"][0], 1);
        st.apply(&ev(r#"{"WindowClosed":{"id":6}}"#));
        assert!(!st.windows.contains_key(&6));
    }
}
