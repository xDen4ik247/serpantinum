//! glass-mail-watch (port of watch.py): the always-on new-mail watcher (user service). One IMAP
//! IDLE connection per account on the inbox; the server pushes new mail, so login codes reach the
//! clipboard within seconds even when the app is closed. Idle cost: a sleeping socket per account.
//!
//! - IDLE is re-issued every few minutes (servers drop idle connections at ~30 min), with a cheap
//!   inbox sync each time to catch anything a dropped connection missed.
//! - Suspend / resume: a light clock check notices the jump and reconnects at once (sockets from
//!   before sleep are usually dead). TCP keepalive notices dead networks (Wi-Fi switches).
//! - The app and this watcher both sync, but each new message is claimed once in the cache
//!   (folders.notified), so there is only ever one notification / one copy.
use crate::accounts;
use crate::engine::{Account, Conn, OpErr, INITIAL};
use crate::hub::Hub;
use crate::paths;
use crate::store::Store;
use serde_json::Value;
use std::net::{Shutdown, TcpStream};
use std::os::fd::AsRawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

const IDLE_SECONDS: u64 = 270; // re-issue IDLE (and resync) this often

fn keepalive(sock: &TcpStream) {
    let fd = sock.as_raw_fd();
    let set = |level, opt, v: libc::c_int| unsafe {
        libc::setsockopt(fd, level, opt, &v as *const _ as *const libc::c_void, std::mem::size_of::<libc::c_int>() as libc::socklen_t)
    };
    set(libc::SOL_SOCKET, libc::SO_KEEPALIVE, 1);
    set(libc::IPPROTO_TCP, libc::TCP_KEEPIDLE, 60);
    set(libc::IPPROTO_TCP, libc::TCP_KEEPINTVL, 10);
    set(libc::IPPROTO_TCP, libc::TCP_KEEPCNT, 3);
}

struct Watcher {
    hub: Arc<Hub>,
    conf: Value,
    acc: Arc<Account>, // used for its sync / notify logic, threads not started
    stop: AtomicBool,
    kick: (Mutex<bool>, Condvar), // "reconnect now" (resume from suspend)
    sock: Mutex<Option<TcpStream>>,
}

impl Watcher {
    fn new(hub: Arc<Hub>, conf: Value) -> Arc<Watcher> {
        let acc = Account::new(&conf, hub.clone());
        Arc::new(Watcher { hub, conf, acc, stop: AtomicBool::new(false), kick: (Mutex::new(false), Condvar::new()), sock: Mutex::new(None) })
    }

    fn start(self: &Arc<Self>) {
        let me = self.clone();
        let name = self.acc.id.clone();
        std::thread::Builder::new().name(name).spawn(move || me.run()).ok();
    }

    fn close(&self) {
        self.stop.store(true, Ordering::SeqCst);
        self.kick_now();
    }

    /// breaks a blocking IDLE read, and any wait
    fn kick_now(&self) {
        let (m, cv) = &self.kick;
        *m.lock().unwrap() = true;
        cv.notify_all();
        if let Some(s) = self.sock.lock().unwrap().as_ref() {
            let _ = s.shutdown(Shutdown::Both);
        }
    }

    /// kick.wait(t); true when kicked. Clears the kick.
    fn wait(&self, secs: u64) -> bool {
        let (m, cv) = &self.kick;
        let g = m.lock().unwrap();
        let (mut g, _) = cv.wait_timeout_while(g, Duration::from_secs(secs), |k| !*k && !self.stop.load(Ordering::SeqCst)).unwrap();
        let k = *g;
        *g = false;
        k
    }

    fn stopped(&self) -> bool {
        self.stop.load(Ordering::SeqCst)
    }

    fn session(&self, conn: &mut Conn, store: &Store) -> Result<(), OpErr> {
        conn.open()?;
        if let Some(c) = conn.c.as_ref() {
            if let Ok(s) = c.shutdown_handle() {
                keepalive(&s);
                *self.sock.lock().unwrap() = Some(s);
            }
        }
        if self.stopped() {
            return Ok(());
        }
        if store.folder_by_role(&self.acc.id, "inbox").is_none() {
            self.acc.sync_folder_list(conn, store)?;
        }
        let inbox = store
            .folder_by_role(&self.acc.id, "inbox")
            .and_then(|f| f.get("path").and_then(Value::as_str).map(String::from))
            .unwrap_or_else(|| "INBOX".into());
        self.acc.sync_folder(conn, store, &inbox, INITIAL)?;
        if !conn.has("IDLE") {
            // no push on this server: poll quietly
            while !self.stopped() && !self.wait(20) {
                self.acc.sync_folder(conn, store, &inbox, INITIAL)?;
            }
            return Ok(());
        }
        while !self.stopped() {
            let hit = conn.im()?.idle(Duration::from_secs(IDLE_SECONDS))?;
            if self.stopped() {
                break;
            }
            self.acc.sync_folder(conn, store, &inbox, INITIAL)?;
            if hit {
                self.hub.write_unread(store);
            }
        }
        Ok(())
    }

    fn run(self: Arc<Self>) {
        let store = Store::open();
        let mut backoff = 5;
        let email = self.conf["email"].as_str().unwrap_or("").to_string();
        while !self.stopped() {
            let mut conn = Conn::new(&self.conf);
            let r = self.session(&mut conn, &store);
            *self.sock.lock().unwrap() = None;
            conn.close();
            match r {
                Ok(()) => backoff = 5,
                Err(OpErr::Auth(e)) => {
                    self.hub.log(&format!("{email}: {e}"));
                    // wrong password: don't hammer the server
                    let _ = self.wait(600);
                }
                Err(e) => {
                    if !self.stopped() {
                        self.hub.log(&format!("{email}: {e} (retry in {backoff}s)"));
                        let _ = self.wait(backoff);
                        backoff = (backoff * 2).min(300);
                    }
                }
            }
        }
    }
}

fn clock(id: libc::clockid_t) -> f64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(id, &mut ts) };
    ts.tv_sec as f64 + ts.tv_nsec as f64 / 1e9
}

fn mtime(p: &std::path::Path) -> Option<std::time::SystemTime> {
    std::fs::metadata(p).and_then(|m| m.modified()).ok()
}

pub fn main() {
    paths::ensure();
    let hub = Hub::new(true);
    let mut watchers: indexmap::IndexMap<String, Arc<Watcher>> = indexmap::IndexMap::new();
    let mut seen: Option<Option<std::time::SystemTime>> = None;
    // suspend shows up as BOOTTIME (counts sleep) running ahead of MONOTONIC (doesn't)
    let drift_now = || clock(libc::CLOCK_BOOTTIME) - clock(libc::CLOCK_MONOTONIC);
    let mut drift = drift_now();
    let mut settings_m = mtime(&paths::settings());
    loop {
        let m = mtime(&paths::accounts());
        if seen != Some(m) {
            // accounts added / removed / edited
            seen = Some(m);
            let confs: indexmap::IndexMap<String, Value> =
                accounts::load().into_iter().map(|c| (c["id"].as_str().unwrap_or("").to_string(), c)).collect();
            let gone: Vec<String> = watchers.iter().filter(|(aid, w)| confs.get(*aid) != Some(&w.conf)).map(|(a, _)| a.clone()).collect();
            for aid in gone {
                if let Some(w) = watchers.shift_remove(&aid) {
                    w.close();
                }
            }
            for (aid, conf) in confs {
                if !watchers.contains_key(&aid) {
                    let w = Watcher::new(hub.clone(), conf);
                    w.start();
                    watchers.insert(aid, w);
                }
            }
        }
        let sm = mtime(&paths::settings());
        if sm != settings_m {
            settings_m = sm;
            let mut s = hub.settings.lock().unwrap();
            for (k, v) in accounts::load_settings() {
                s.insert(k, v);
            }
        }
        let now = drift_now();
        if now - drift > 5.0 {
            // we were asleep
            hub.log(&format!("resumed after {:.0}s asleep: reconnecting", now - drift));
            for w in watchers.values() {
                w.kick_now();
            }
        }
        drift = now;
        std::thread::sleep(Duration::from_secs(3));
    }
}
