//! Small Unix helpers shared by the binaries (no async runtime, no threads).
use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::io::{AsRawFd, RawFd};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::time::Duration;

pub fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}

pub fn uid() -> u32 {
    unsafe { libc::getuid() }
}

/// $XDG_RUNTIME_DIR, or /run/user/UID.
pub fn runtime_dir() -> PathBuf {
    match std::env::var_os("XDG_RUNTIME_DIR") {
        Some(v) if !v.is_empty() => PathBuf::from(v),
        _ => PathBuf::from(format!("/run/user/{}", uid())),
    }
}

/// `$name` when set and non-empty, else `default`.
pub fn env_or(name: &str, default: impl Into<PathBuf>) -> PathBuf {
    match std::env::var_os(name) {
        Some(v) if !v.is_empty() => PathBuf::from(v),
        _ => default.into(),
    }
}

pub fn read_trim(path: impl AsRef<Path>) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().to_string())
}

/// Rewrite a file in place (truncate + write, same inode) so inotify watches on it survive.
pub fn write_in_place(path: impl AsRef<Path>, data: &[u8]) -> io::Result<()> {
    let mut f = OpenOptions::new().write(true).create(true).truncate(true).open(path)?;
    f.write_all(data)
}

/// Write to `path.tmp`, then rename over `path`.
pub fn write_atomic(path: impl AsRef<Path>, data: &[u8]) -> io::Result<()> {
    let path = path.as_ref();
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    fs::write(&tmp, data)?;
    fs::rename(&tmp, path)
}

/// Non-blocking exclusive flock; `None` when another process holds it.
pub fn try_lock(path: impl AsRef<Path>) -> io::Result<Option<File>> {
    let f = OpenOptions::new().write(true).create(true).truncate(false).open(path)?;
    if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
        Ok(Some(f))
    } else {
        Ok(None)
    }
}

pub fn pid_alive(pid: i32) -> bool {
    pid > 0 && unsafe { libc::kill(pid, 0) } == 0
}

/// Wait until one of `fds` is readable. Returns the readiness flags (all false on timeout).
pub fn poll_read(fds: &[RawFd], timeout: Option<Duration>) -> io::Result<Vec<bool>> {
    let mut p: Vec<libc::pollfd> =
        fds.iter().map(|&fd| libc::pollfd { fd, events: libc::POLLIN, revents: 0 }).collect();
    let ms = timeout.map(|d| d.as_millis().min(i32::MAX as u128) as i32).unwrap_or(-1);
    loop {
        let r = unsafe { libc::poll(p.as_mut_ptr(), p.len() as libc::nfds_t, ms) };
        if r >= 0 {
            return Ok(p.iter().map(|x| x.revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0).collect());
        }
        let e = io::Error::last_os_error();
        if e.kind() != io::ErrorKind::Interrupted {
            return Err(e);
        }
    }
}

/// Splits a byte stream into lines without losing partial data across reads.
pub struct LineBuf<R> {
    pub inner: R,
    buf: Vec<u8>,
}

impl<R: Read> LineBuf<R> {
    pub fn new(inner: R) -> Self {
        Self { inner, buf: Vec::with_capacity(1 << 16) }
    }
    /// One read; Ok(false) on EOF.
    pub fn fill(&mut self) -> io::Result<bool> {
        let mut chunk = [0u8; 65536];
        loop {
            match self.inner.read(&mut chunk) {
                Ok(0) => return Ok(false),
                Ok(n) => {
                    self.buf.extend_from_slice(&chunk[..n]);
                    return Ok(true);
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            }
        }
    }
    /// Complete lines read so far (without the newline).
    pub fn lines(&mut self) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        let mut start = 0;
        for i in 0..self.buf.len() {
            if self.buf[i] == b'\n' {
                out.push(self.buf[start..i].to_vec());
                start = i + 1;
            }
        }
        self.buf.drain(..start);
        out
    }
    /// Blocking: the next complete line, `None` on EOF.
    pub fn next_line(&mut self) -> io::Result<Option<Vec<u8>>> {
        loop {
            if let Some(i) = self.buf.iter().position(|&b| b == b'\n') {
                let line = self.buf[..i].to_vec();
                self.buf.drain(..=i);
                return Ok(Some(line));
            }
            if !self.fill()? {
                return Ok(None);
            }
        }
    }
}

// ---------- signals ----------
static TERM: AtomicBool = AtomicBool::new(false);
static WAKE_FD: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_signal(sig: libc::c_int) {
    if sig == libc::SIGTERM || sig == libc::SIGINT || sig == libc::SIGHUP {
        TERM.store(true, Ordering::SeqCst);
    }
    let fd = WAKE_FD.load(Ordering::SeqCst);
    if fd >= 0 {
        let b = sig as u8;
        unsafe { libc::write(fd, &b as *const u8 as *const libc::c_void, 1) };
    }
}

/// Route `signals` to a self-pipe; returns its read end (one byte = the signal number).
/// Handlers are installed without SA_RESTART so blocking reads return EINTR.
pub fn signal_pipe(signals: &[libc::c_int]) -> io::Result<RawFd> {
    let mut fds = [0; 2];
    if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC | libc::O_NONBLOCK) } != 0 {
        return Err(io::Error::last_os_error());
    }
    WAKE_FD.store(fds[1], Ordering::SeqCst);
    for &s in signals {
        unsafe {
            let mut sa: libc::sigaction = std::mem::zeroed();
            sa.sa_sigaction = on_signal as *const () as usize;
            libc::sigemptyset(&mut sa.sa_mask);
            libc::sigaction(s, &sa, std::ptr::null_mut());
        }
    }
    Ok(fds[0])
}

pub fn terminated() -> bool {
    TERM.load(Ordering::SeqCst)
}

/// Drain the self-pipe; returns the signal numbers received.
pub fn drain_signals(fd: RawFd) -> Vec<i32> {
    let mut out = Vec::new();
    let mut b = [0u8; 64];
    loop {
        let n = unsafe { libc::read(fd, b.as_mut_ptr() as *mut libc::c_void, b.len()) };
        if n <= 0 {
            break;
        }
        out.extend(b[..n as usize].iter().map(|&x| x as i32));
    }
    out
}

pub fn ignore_sigpipe() {
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) };
}

/// Print a line to stdout and flush; exit quietly when the reader went away.
pub fn emit(line: &str) {
    let mut out = io::stdout().lock();
    if out.write_all(line.as_bytes()).and_then(|_| out.write_all(b"\n")).and_then(|_| out.flush()).is_err() {
        std::process::exit(0);
    }
}

pub fn now_unix() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// Local time broken down (libc localtime_r): (year, month 1-12, day, hour, minute, second, weekday Mon=0).
pub fn local_tm(t: i64) -> (i32, u32, u32, u32, u32, u32, u32) {
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let tt = t as libc::time_t;
    unsafe { libc::localtime_r(&tt, &mut tm) };
    (
        tm.tm_year + 1900,
        (tm.tm_mon + 1) as u32,
        tm.tm_mday as u32,
        tm.tm_hour as u32,
        tm.tm_min as u32,
        tm.tm_sec as u32,
        ((tm.tm_wday + 6) % 7) as u32,
    )
}

/// strftime with the local time zone.
pub fn strftime(fmt: &str, t: i64) -> String {
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let tt = t as libc::time_t;
    unsafe { libc::localtime_r(&tt, &mut tm) };
    let cfmt = CString::new(fmt).unwrap();
    let mut buf = vec![0u8; 256];
    let n = unsafe { libc::strftime(buf.as_mut_ptr() as *mut libc::c_char, buf.len(), cfmt.as_ptr(), &tm) };
    buf.truncate(n);
    String::from_utf8_lossy(&buf).into_owned()
}

/// Run a command with stdio discarded; returns the exit code (-1 if it could not run or timed out).
pub fn run_quiet(cmd: &[&str], timeout: Duration) -> i32 {
    use std::process::{Command, Stdio};
    let child = Command::new(cmd[0]).args(&cmd[1..]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn();
    let mut child = match child {
        Ok(c) => c,
        Err(_) => return -1,
    };
    let t0 = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(st)) => return st.code().unwrap_or(-1),
            Ok(None) if t0.elapsed() < timeout => std::thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return -1;
            }
        }
    }
}

/// Run a command and capture stdout (None on failure / timeout).
pub fn run_output(cmd: &[&str], timeout: Duration) -> Option<String> {
    use std::process::{Command, Stdio};
    let mut child = Command::new(cmd[0]).args(&cmd[1..]).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().ok()?;
    let mut out = child.stdout.take()?;
    let t0 = std::time::Instant::now();
    let reader = std::thread::spawn(move || {
        let mut s = Vec::new();
        let _ = out.read_to_end(&mut s);
        s
    });
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if t0.elapsed() < timeout => std::thread::sleep(Duration::from_millis(5)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    reader.join().ok().map(|b| String::from_utf8_lossy(&b).into_owned())
}
