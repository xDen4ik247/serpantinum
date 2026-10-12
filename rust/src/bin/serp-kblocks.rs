//! serp-kblocks — Caps Lock / Num Lock watcher for Serpantinum's OSD (port of the Python inside
//! quickshell/watchers/kb_locks.sh).
//!
//!   serp-kblocks watch   print "capslock 0|1" / "numlock 0|1" whenever a lock LED changes
//!   serp-kblocks get     print "CAPS NUM" (0/1) once
//!
//! The Python read every input event of every keyboard, so it woke up on each key press and
//! release. Here the kernel filters per client (EVIOCSMASK): key, scancode and repeat events are
//! masked out, and only LED changes wake the process. New keyboards are picked up through inotify.
//! Without read access to /dev/input (user not in the `input` group) it polls the LED files like the
//! Python fallback did.
use glass::util;
use std::ffi::CString;
use std::fs;
use std::os::unix::io::RawFd;
use std::time::Duration;

const EV_SYN: u16 = 0;
const EV_LED: u16 = 0x11;
const LED_NUML: u16 = 0;
const LED_CAPSL: u16 = 1;
// _IOW('E', 0x93, struct input_mask { u32 type; u32 codes_size; u64 codes_ptr; })
const EVIOCSMASK: libc::c_ulong = 0x4010_4593;

#[repr(C)]
struct InputMask {
    kind: u32,
    codes_size: u32,
    codes_ptr: u64,
}

/// /sys/class/leds (SERP_KBLOCKS_LEDS overrides it for tests).
fn leds_dir() -> std::path::PathBuf {
    util::env_or("SERP_KBLOCKS_LEDS", "/sys/class/leds")
}

/// The brightness files of every LED whose name contains `name_part` (e.g. input2::capslock).
fn led_files(name_part: &str) -> Vec<fs::File> {
    let mut v: Vec<_> = fs::read_dir(leds_dir()).map(|d| d.flatten().map(|e| e.path()).collect()).unwrap_or_default();
    v.sort();
    v.into_iter()
        .filter(|p| p.file_name().is_some_and(|n| n.to_string_lossy().contains(name_part)))
        .filter_map(|p| fs::File::open(p.join("brightness")).ok())
        .collect()
}

fn any_on(files: &[fs::File]) -> u8 {
    use std::os::unix::fs::FileExt;
    for f in files {
        let mut b = [0u8; 16];
        if let Ok(n) = f.read_at(&mut b, 0) {
            if std::str::from_utf8(&b[..n]).ok().and_then(|s| s.trim().parse::<i64>().ok()).is_some_and(|x| x > 0) {
                return 1;
            }
        }
    }
    0
}

fn leds_on(name_part: &str) -> u8 {
    any_on(&led_files(name_part))
}

fn keyboards() -> Vec<String> {
    let list = |dir: &str, pred: &dyn Fn(&str) -> bool| -> Vec<String> {
        let mut v: Vec<String> = fs::read_dir(dir)
            .map(|d| d.flatten().map(|e| e.path().to_string_lossy().into_owned()).filter(|p| pred(p)).collect())
            .unwrap_or_default();
        v.sort();
        v
    };
    let mut v = list("/dev/input/by-id", &|p| p.ends_with("-event-kbd"));
    if v.is_empty() {
        v = list("/dev/input/by-path", &|p| p.ends_with("-event-kbd"));
    }
    if v.is_empty() {
        v = list("/dev/input", &|p| p.rsplit('/').next().is_some_and(|n| n.starts_with("event")));
    }
    v
}

/// Open a device and mask everything but LED (and the SYN that frames it).
fn open_masked(path: &str) -> Option<RawFd> {
    let c = CString::new(path).ok()?;
    let fd = unsafe { libc::open(c.as_ptr(), libc::O_RDONLY | libc::O_NONBLOCK | libc::O_CLOEXEC) };
    if fd < 0 {
        return None;
    }
    let zeros = [0u8; 128]; // ≥ KEY_CNT bits
    for kind in [0x01u32, 0x02, 0x03, 0x04, 0x05, 0x12, 0x14, 0x15, 0x16] {
        // EV_KEY EV_REL EV_ABS EV_MSC EV_SW EV_SND EV_REP EV_FF EV_PWR
        let m = InputMask { kind, codes_size: zeros.len() as u32, codes_ptr: zeros.as_ptr() as u64 };
        unsafe { libc::ioctl(fd, EVIOCSMASK as _, &m) };
    }
    Some(fd)
}

struct Watch {
    fds: Vec<RawFd>,
    caps: u8,
    num: u8,
}

impl Watch {
    fn rescan(&mut self) {
        for fd in self.fds.drain(..) {
            unsafe { libc::close(fd) };
        }
        self.fds = keyboards().iter().filter_map(|p| open_masked(p)).collect();
    }

    fn report(&mut self, code: u16, value: i32) {
        let v = u8::from(value > 0);
        let (name, last) = match code {
            LED_CAPSL => ("capslock", &mut self.caps),
            LED_NUML => ("numlock", &mut self.num),
            _ => return,
        };
        if v != *last {
            *last = v;
            util::emit(&format!("{name} {v}"));
        }
    }

    /// Drain one device; false when it is gone.
    fn drain(&mut self, fd: RawFd) -> bool {
        const SZ: usize = std::mem::size_of::<libc::input_event>();
        let mut buf = [0u8; SZ * 64];
        loop {
            let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
            if n < 0 {
                let e = std::io::Error::last_os_error();
                return matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted);
            }
            if n == 0 || (n as usize) < SZ {
                return false;
            }
            for chunk in buf[..n as usize].chunks_exact(SZ) {
                let ev: libc::input_event = unsafe { std::ptr::read_unaligned(chunk.as_ptr() as *const libc::input_event) };
                if ev.type_ == EV_LED {
                    self.report(ev.code, ev.value);
                } else if ev.type_ == EV_SYN && ev.code == 3 {
                    // SYN_DROPPED: resync from sysfs
                    let (c, n) = (leds_on("capslock") as i32, leds_on("numlock") as i32);
                    self.report(LED_CAPSL, c);
                    self.report(LED_NUML, n);
                }
            }
        }
    }
}

fn inotify_dev_input() -> Option<RawFd> {
    let fd = unsafe { libc::inotify_init1(libc::IN_NONBLOCK | libc::IN_CLOEXEC) };
    if fd < 0 {
        return None;
    }
    let p = CString::new("/dev/input").unwrap();
    unsafe { libc::inotify_add_watch(fd, p.as_ptr(), libc::IN_CREATE | libc::IN_ATTRIB) };
    Some(fd)
}

/// stdout when it is a pipe: the write end of a pipe reports POLLERR once the reader is gone, so the
/// watcher (which can stay silent for hours) exits with the shell instead of lingering as an orphan.
/// A terminal or file would always poll ready, so those are not watched.
fn stdout_pipe() -> Option<RawFd> {
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    (unsafe { libc::fstat(1, &mut st) } == 0 && st.st_mode & libc::S_IFMT == libc::S_IFIFO).then_some(1)
}

fn watch() {
    let out = stdout_pipe();
    let reader_gone = || out.is_some_and(|fd| util::poll_read(&[fd], Some(Duration::ZERO)).is_ok_and(|r| r[0]));
    let mut w = Watch { fds: vec![], caps: leds_on("capslock"), num: leds_on("numlock") };
    w.rescan();
    if w.fds.is_empty() {
        // No readable keyboard device (the user is not in the `input` group): sysfs LED files can't
        // be watched, so poll them every 80 ms like the Python did, with the files kept open
        // (one pread each) and re-opened every ~5 s in case a keyboard comes or goes.
        let (mut caps, mut num) = (led_files("capslock"), led_files("numlock"));
        let mut count = 0;
        loop {
            std::thread::sleep(Duration::from_millis(80));
            if reader_gone() {
                return;
            }
            count += 1;
            if count >= 60 {
                count = 0;
                (caps, num) = (led_files("capslock"), led_files("numlock"));
            }
            let (c, n) = (any_on(&caps) as i32, any_on(&num) as i32);
            w.report(LED_CAPSL, c);
            w.report(LED_NUML, n);
        }
    }
    let ino = inotify_dev_input();
    loop {
        let mut fds = w.fds.clone();
        if let Some(i) = ino {
            fds.push(i);
        }
        if let Some(o) = out {
            fds.push(o);
        }
        let ready = match util::poll_read(&fds, if w.fds.is_empty() { Some(Duration::from_secs(1)) } else { None }) {
            Ok(r) => r,
            Err(_) => {
                std::thread::sleep(Duration::from_secs(1));
                continue;
            }
        };
        let mut lost = false;
        for (i, fd) in w.fds.clone().into_iter().enumerate() {
            if ready[i] && !w.drain(fd) {
                lost = true;
            }
        }
        if out.is_some() && *ready.last().unwrap_or(&false) {
            return; // the reader closed the pipe
        }
        let new_dev = ino.is_some() && ready.get(w.fds.len()).copied().unwrap_or(false);
        if new_dev {
            let mut b = [0u8; 4096];
            while unsafe { libc::read(ino.unwrap(), b.as_mut_ptr() as *mut libc::c_void, b.len()) } > 0 {}
            std::thread::sleep(Duration::from_millis(200)); // let udev set permissions / symlinks
        }
        if lost || new_dev || w.fds.is_empty() {
            w.rescan();
        }
    }
}

fn main() {
    util::ignore_sigpipe();
    match std::env::args().nth(1).as_deref() {
        Some("get") => println!("{} {}", leds_on("capslock"), leds_on("numlock")),
        _ => watch(),
    }
}
