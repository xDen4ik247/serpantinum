//! Background new-mail check (port of check.py, glass-mail-check.timer): syncs each inbox into the
//! cache and notifies about new unread mail. Does nothing while the app is open (it has IMAP IDLE).
use crate::accounts;
use crate::engine::{Account, Conn, INITIAL};
use crate::hub::Hub;
use crate::paths;
use crate::store::Store;

/// The app writes its pid; it's "running" if that process is a Glass Mail server (Python or Rust).
pub fn app_running() -> bool {
    let Ok(pid) = std::fs::read_to_string(paths::state().join("app.pid")) else { return false };
    let Ok(pid) = pid.trim().parse::<u32>() else { return false };
    let Ok(cmd) = std::fs::read(format!("/proc/{pid}/cmdline")) else { return false };
    let has = |n: &[u8]| cmd.windows(n.len()).any(|w| w == n);
    has(b"glassmail.server") || (has(b"glass-mail-backend") && !has(b"\0watch") && !has(b"\0check"))
}

pub fn main() {
    paths::ensure();
    if app_running() {
        return;
    }
    let hub = Hub::new(true);
    let store = Store::open();
    for conf in accounts::load() {
        let a = Account::new(&conf, hub.clone());
        let mut conn = Conn::new(&conf);
        let r = conn.run(|c| a.sync_folder_list(c, &store)).and_then(|_| match store.folder_by_role(&a.id, "inbox") {
            Some(inbox) => {
                let p = inbox.get("path").and_then(|v| v.as_str()).unwrap_or("").to_string();
                conn.run(|c| a.sync_folder(c, &store, &p, INITIAL)).map(|_| ())
            }
            None => Ok(()),
        });
        if let Err(e) = r {
            hub.log(&format!("{}: {e}", conf["email"].as_str().unwrap_or("")));
        }
        conn.close();
    }
    hub.write_unread(&store);
}
