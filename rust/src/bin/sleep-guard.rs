//! sleep-guard — reliable suspend/resume with the Serpantinum lock screen on niri
//! (Rust port of the Python sleep-guard; same behaviour, same log lines).
//!
//! Fixes three ways the laptop "didn't wake up":
//!   1. The idle "suspend" action asks for the lock only 200 ms before `systemctl suspend`, and the
//!      lock screen takes longer than that. We hold a logind *delay* inhibitor: on PrepareForSleep we
//!      turn the monitors on, lock, wait until the lock screen is up, then let sleep proceed.
//!   2. niri handles the power key itself. The press that wakes the laptop reached niri after resume
//!      and sent it straight back to sleep. After every resume we hold a *block* inhibitor for a few
//!      seconds, so that request is refused.
//!   3. Opening the lid is not "input" for niri, so screens powered off by the idle timer stayed
//!      black. We power the monitors on after every resume.
//! Plus a lock guardian: while the session is locked, if the shell that draws the lock screen dies or
//! hangs, its log is saved and it is restarted and locked again.
//!
//! Idle cost: blocks on D-Bus/inotify; checks the shell every 3 s only while the session is locked.
use dbus::blocking::Connection;
use dbus::channel::Channel;
use glass::niri;
use glass::util;
use serde_json::json;
use std::fs;
use std::os::fd::OwnedFd;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const RESUME_BLOCK: Duration = Duration::from_secs(4); // refuse suspend requests this long after resume
const LOCK_WAIT_S: f64 = 3.5; // max wait for the lock screen before sleep (logind allows 5 s)
const PROBE_EVERY: Duration = Duration::from_secs(3);
const HANG_PROBES: u32 = 4; // consecutive failed IPC probes (~12 s) = hung lock screen
const MAX_RESTARTS: usize = 3; // per 10 minutes

fn log(msg: &str) {
    println!("{msg}");
}

fn py_bool(b: bool) -> &'static str {
    if b {
        "True"
    } else {
        "False"
    }
}

struct Paths {
    run: PathBuf,
    main_qml: String,
    lock_marker: PathBuf,
    state: PathBuf,
}

fn paths() -> Paths {
    let home = util::home();
    let run = util::runtime_dir();
    let main_qml = home.join(".local/share/serpantinum/src/quickshell/Shell.qml").to_string_lossy().into_owned();
    Paths { lock_marker: run.join("serpantinum/lock/locked"), run, main_qml, state: home.join(".local/state/sleep-guard") }
}

/// Point NIRI_SOCKET at the newest live niri (a service's environment can outlive a niri restart).
fn niri_env() {
    if let Some(s) = niri::discover() {
        std::env::set_var("NIRI_SOCKET", s);
    }
}

fn monitors_off() -> bool {
    let Ok(rd) = fs::read_dir("/sys/class/drm") else { return false };
    for e in rd.flatten() {
        let n = e.file_name().to_string_lossy().into_owned();
        if !(n.starts_with("card") && n.contains('-')) {
            continue;
        }
        let d = e.path();
        if util::read_trim(d.join("status")).as_deref() == Some("connected") && util::read_trim(d.join("dpms")).as_deref() == Some("Off") {
            return true;
        }
    }
    false
}

fn monitors_on() {
    niri_env();
    let _ = niri::action("PowerOnMonitors", json!({}));
}

fn cmdline(pid: &str) -> Option<Vec<u8>> {
    fs::read(format!("/proc/{pid}/cmdline")).ok()
}

/// PID of the main shell. While locked, quickshell forks a PAM helper with the same command line:
/// the main process is the one whose parent is not itself a copy of the shell.
fn shell_pid(p: &Paths) -> Option<i32> {
    let want = format!("quickshell\0-p\0{}\0", p.main_qml).into_bytes();
    let pids: Vec<i32> = fs::read_dir("/proc")
        .ok()?
        .flatten()
        .filter_map(|e| {
            let n = e.file_name().to_string_lossy().into_owned();
            let pid: i32 = n.parse().ok()?;
            (cmdline(&n)? == want).then_some(pid)
        })
        .collect();
    pids.iter().copied().find(|pid| {
        let ppid = fs::read_to_string(format!("/proc/{pid}/stat"))
            .ok()
            .and_then(|s| s.rsplit_once(')').and_then(|(_, r)| r.split_whitespace().nth(1).and_then(|x| x.parse::<i32>().ok())));
        ppid.is_some_and(|pp| !pids.contains(&pp))
    })
}

fn shell_ipc(p: &Paths, args: &[&str], timeout: Duration) -> i32 {
    niri_env();
    let mut cmd = vec!["quickshell", "-p", p.main_qml.as_str(), "ipc"];
    cmd.extend_from_slice(args);
    util::run_quiet(&cmd, timeout)
}

fn pgrep(pattern: &str) -> Vec<i32> {
    util::run_output(&["pgrep", "-f", pattern], Duration::from_secs(5))
        .map(|s| s.split_whitespace().filter_map(|x| x.parse().ok()).collect())
        .unwrap_or_default()
}

fn sleep_s(s: f64) {
    std::thread::sleep(Duration::from_secs_f64(s.max(0.0)));
}

struct Guard {
    conn: Connection,
    p: Paths,
    delay: Option<OwnedFd>,
    blocks: Vec<(Instant, OwnedFd)>,
    restarts: Vec<Instant>,
    bad_probes: u32,
    next_probe: Option<Instant>,
}

impl Guard {
    fn locked(&self) -> bool {
        self.p.lock_marker.exists()
    }

    fn inhibit(&self, mode: &str, why: &str) -> Result<OwnedFd, dbus::Error> {
        let proxy = self.conn.with_proxy("org.freedesktop.login1", "/org/freedesktop/login1", Duration::from_secs(25));
        let (fd,): (OwnedFd,) = proxy.method_call("org.freedesktop.login1.Manager", "Inhibit", ("sleep", "sleep-guard", why, mode))?;
        Ok(fd)
    }

    fn take_delay(&mut self) {
        if self.delay.is_none() {
            match self.inhibit("delay", "Lock the screen before sleeping") {
                Ok(fd) => self.delay = Some(fd),
                Err(e) => log(&format!("delay inhibitor failed: {}", e.message().unwrap_or(""))),
            }
        }
    }

    fn before_sleep(&mut self) {
        let t0 = Instant::now();
        let el = || t0.elapsed().as_secs_f64();
        if !self.locked() {
            if monitors_off() {
                monitors_on();
                sleep_s(0.3);
            }
            shell_ipc(&self.p, &["call", "lock", "activate"], Duration::from_secs(2));
            while !self.locked() && el() < LOCK_WAIT_S {
                sleep_s(0.1);
            }
            // let the lock surface paint its first frames before the GPU powers down
            sleep_s((LOCK_WAIT_S - el()).min(0.8));
        }
        log(&format!("before sleep: locked={} after {:.1}s", py_bool(self.locked()), el()));
        self.delay = None; // release: sleep may proceed
    }

    fn after_resume(&mut self) {
        match self.inhibit("block", "Just woke up: ignore the power-button press that woke the laptop") {
            Ok(fd) => self.blocks.push((Instant::now() + RESUME_BLOCK, fd)),
            Err(e) => log(&format!("block inhibitor failed: {}", e.message().unwrap_or(""))),
        }
        monitors_on();
        let _ = fs::write(self.p.run.join("sleep-guard-resumed"), format!("{:.0}\n", util::now_unix()));
        self.take_delay();
        log(&format!("resumed: locked={}", py_bool(self.locked())));
        self.bad_probes = 0;
        self.update_probe();
    }

    fn update_probe(&mut self) {
        if self.locked() && self.next_probe.is_none() {
            self.next_probe = Some(Instant::now() + PROBE_EVERY);
        } else if !self.locked() && self.next_probe.is_some() {
            self.next_probe = None;
            self.bad_probes = 0;
        }
    }

    fn probe(&mut self) {
        if !self.locked() {
            self.next_probe = None;
            return;
        }
        self.next_probe = Some(Instant::now() + PROBE_EVERY);
        match shell_pid(&self.p) {
            None => self.recover(None, "the shell is gone while the session is locked"),
            Some(pid) => {
                if shell_ipc(&self.p, &["show"], Duration::from_secs(2)) != 0 {
                    self.bad_probes += 1;
                    if self.bad_probes >= HANG_PROBES {
                        let why = format!("the shell did not answer for {}s while locked", self.bad_probes * PROBE_EVERY.as_secs() as u32);
                        self.recover(Some(pid), &why);
                    }
                } else {
                    self.bad_probes = 0;
                }
            }
        }
        if self.next_probe.is_some() {
            self.next_probe = Some(Instant::now() + PROBE_EVERY);
        }
    }

    fn save_log(&self, pid: Option<i32>) {
        let out = self.p.state.join(format!("shell-{}.log", util::strftime("%Y%m%d-%H%M%S", util::now_unix() as i64)));
        let qs = self.p.run.join("quickshell");
        let mut files: Vec<PathBuf> = pid.map(|pid| qs.join(format!("by-pid/{pid}/log.qslog"))).filter(|f| f.exists()).into_iter().collect();
        if files.is_empty() {
            // dead instance: the newest Shell.qml log
            let mut logs: Vec<(std::time::SystemTime, PathBuf)> = fs::read_dir(qs.join("by-id"))
                .map(|d| {
                    d.flatten()
                        .map(|e| e.path().join("log.qslog"))
                        .filter_map(|f| Some((fs::metadata(&f).ok()?.modified().ok()?, f)))
                        .collect()
                })
                .unwrap_or_default();
            logs.sort();
            files.extend(logs.pop().map(|(_, f)| f));
        }
        for f in files {
            if let Some(txt) = util::run_output(&["quickshell", "log", "-t", "300", &f.to_string_lossy()], Duration::from_secs(10)) {
                let _ = fs::write(&out, txt);
            }
        }
        let mut old: Vec<PathBuf> = fs::read_dir(&self.p.state)
            .map(|d| {
                d.flatten()
                    .map(|e| e.path())
                    .filter(|p| p.file_name().is_some_and(|n| {
                        let n = n.to_string_lossy();
                        n.starts_with("shell-") && n.ends_with(".log") // (shell-stderr.log sorts last and is kept)
                    }))
                    .collect()
            })
            .unwrap_or_default();
        old.sort();
        let keep = old.len().saturating_sub(5);
        for f in &old[..keep] {
            let _ = fs::remove_file(f);
        }
    }

    fn recover(&mut self, pid: Option<i32>, why: &str) {
        let now = Instant::now();
        self.restarts.retain(|t| now.duration_since(*t) < Duration::from_secs(600));
        if self.restarts.len() >= MAX_RESTARTS {
            log(&format!("NOT restarting ({why}): too many restarts"));
            return;
        }
        self.restarts.push(now);
        log(&format!("restarting the shell: {why}"));
        self.save_log(pid);
        for p in pgrep(r"^bash .*/serpantinumd start$") {
            unsafe { libc::kill(p, libc::SIGTERM) };
        }
        sleep_s(1.5);
        // the main shell and its PAM helper (same command line)
        for p in pgrep(&format!("^quickshell -p {}$", self.p.main_qml)) {
            unsafe { libc::kill(p, libc::SIGKILL) };
        }
        sleep_s(0.3);
        for f in [Path::new("/tmp/serpantinumd.lock"), Path::new("/tmp/serpantinumd.pid"), self.p.lock_marker.as_path()] {
            let _ = fs::remove_file(f);
        }
        let errlog = self.p.state.join("shell-stderr.log");
        if fs::metadata(&errlog).is_ok_and(|m| m.len() > 2_000_000) {
            let _ = fs::OpenOptions::new().write(true).truncate(true).open(&errlog);
        }
        let start = format!("exec serpantinumd start >>'{}' 2>&1", errlog.display());
        // 1st try: spawned by niri (like at login), so it doesn't live in this service's cgroup;
        // 2nd try: a transient scope of the user manager (also outside this service)
        for attempt in ["niri", "systemd-run"] {
            niri_env();
            if attempt == "niri" {
                if niri::action("Spawn", json!({"command": ["bash", "-c", &start]})).is_err() {
                    log("niri spawn failed (rc 1)");
                }
            } else {
                use std::os::unix::process::CommandExt;
                let _ = Command::new("systemd-run")
                    .args(["--user", "--scope", "--quiet", "--collect", "bash", "-c", &start])
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .process_group(0)
                    .spawn()
                    .map(|mut c| std::thread::spawn(move || c.wait()));
            }
            for _ in 0..30 {
                sleep_s(0.5);
                if shell_pid(&self.p).is_some() && shell_ipc(&self.p, &["show"], Duration::from_secs(2)) == 0 {
                    break;
                }
            }
            if shell_pid(&self.p).is_some() {
                break;
            }
            log(&format!("no shell after {attempt}, trying the next way"));
        }
        monitors_on();
        shell_ipc(&self.p, &["call", "lock", "activate"], Duration::from_secs(2)); // niri lets a new client replace a dead lock
        self.bad_probes = 0;
        log(&format!("shell restarted (pid {}) and locked again", shell_pid(&self.p).map_or("None".into(), |p| p.to_string())));
    }

    /// Handle queued D-Bus messages (PrepareForSleep).
    fn dispatch(&mut self) {
        let ch: &Channel = self.conn.channel();
        let _ = ch.read_write(Some(Duration::ZERO));
        while let Some(msg) = self.conn.channel().pop_message() {
            if msg.interface().as_deref() == Some("org.freedesktop.login1.Manager") && msg.member().as_deref() == Some("PrepareForSleep") {
                if let Some(going) = msg.get1::<bool>() {
                    if going {
                        self.before_sleep();
                    } else {
                        self.after_resume();
                    }
                }
            }
        }
    }
}

fn inotify_dir(dir: &Path) -> Option<i32> {
    let fd = unsafe { libc::inotify_init1(libc::IN_NONBLOCK | libc::IN_CLOEXEC) };
    if fd < 0 {
        return None;
    }
    let c = std::ffi::CString::new(dir.as_os_str().as_encoded_bytes()).ok()?;
    let mask = libc::IN_CREATE | libc::IN_DELETE | libc::IN_MOVED_FROM | libc::IN_MOVED_TO | libc::IN_MODIFY | libc::IN_ATTRIB;
    unsafe { libc::inotify_add_watch(fd, c.as_ptr(), mask) };
    Some(fd)
}

fn main() {
    util::ignore_sigpipe();
    let p = paths();
    let _ = fs::create_dir_all(&p.state);
    // a private channel with its fd watch enabled, so the main loop can poll the bus fd
    let conn = match Channel::get_private(dbus::channel::BusType::System).map(|mut ch| {
        ch.set_watch_enabled(true);
        Connection::from(ch)
    }) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("sleep-guard: system bus: {e}");
            std::process::exit(1);
        }
    };
    conn.add_match_no_cb("type='signal',sender='org.freedesktop.login1',interface='org.freedesktop.login1.Manager',member='PrepareForSleep',path='/org/freedesktop/login1'")
        .expect("subscribe PrepareForSleep");
    let mut g = Guard { conn, p, delay: None, blocks: vec![], restarts: vec![], bad_probes: 0, next_probe: None };
    g.take_delay();
    if g.delay.is_none() {
        std::process::exit(1); // like the Python: no delay lock, no point (systemd restarts us)
    }
    let lock_dir = g.p.lock_marker.parent().unwrap().to_path_buf();
    let _ = fs::create_dir_all(&lock_dir);
    let ino = inotify_dir(&lock_dir).expect("inotify");
    g.update_probe();
    let sig = util::signal_pipe(&[libc::SIGTERM, libc::SIGINT]).expect("signal pipe");
    let bus_fd = g.conn.channel().watch().fd;
    loop {
        g.dispatch();
        let now = Instant::now();
        let mut next = g.next_probe;
        for (t, _) in &g.blocks {
            next = Some(next.map_or(*t, |n| n.min(*t)));
        }
        let timeout = next.map(|t| t.saturating_duration_since(now));
        let ready = util::poll_read(&[bus_fd, ino, sig], timeout).unwrap_or(vec![false; 3]);
        if ready[2] {
            util::drain_signals(sig);
            if util::terminated() {
                break;
            }
        }
        if ready[1] {
            let mut b = [0u8; 4096];
            while unsafe { libc::read(ino, b.as_mut_ptr() as *mut libc::c_void, b.len()) } > 0 {}
            g.update_probe();
        }
        let now = Instant::now();
        g.blocks.retain(|(t, _)| *t > now); // dropping the fd releases the block inhibitor
        if g.next_probe.is_some_and(|t| t <= now) {
            g.probe();
        }
    }
}
