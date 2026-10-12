//! serp-sysdata — CPU / RAM / temperature / network / disk for Serpantinum's SysData
//! (port of quickshell/watchers/sys_fetcher.sh, same output line).
//!
//!   serp-sysdata --once            one line after a 0.5 s CPU/network sample (like the script)
//!   serp-sysdata --interval MS     a line every MS milliseconds while running (first one after 0.5 s)
//!
//! Line: CPU%|RAM%|RAM_GB|TEMP_C|RX_B/s|TX_B/s|DISK%|DISK_USED_GB|DISK_TOTAL_GB
//! The script forked about ten processes (bash, grep, awk, sleep, df, cat…) every 2–5 s; the stream
//! mode is one process that reads /proc and /sys directly. Temperature is re-read every 6 s and disk
//! usage every 60 s, as the script's caches did.
use glass::util;
use std::ffi::CString;
use std::fs;
use std::time::{Duration, Instant};

fn cpu() -> Option<(u64, u64)> {
    let s = fs::read_to_string("/proc/stat").ok()?;
    let line = s.lines().find(|l| l.starts_with("cpu "))?;
    let v: Vec<u64> = line.split_whitespace().skip(1).take(8).filter_map(|x| x.parse().ok()).collect();
    if v.len() < 8 {
        return None;
    }
    Some((v[3], v.iter().sum())) // idle, user+nice+system+idle+iowait+irq+softirq+steal
}

/// Bytes received / sent on interfaces whose name starts with e or w (wired, wireless).
fn net() -> (u64, u64) {
    let s = fs::read_to_string("/proc/net/dev").unwrap_or_default();
    let (mut rx, mut tx) = (0, 0);
    for line in s.lines() {
        let t = line.trim_start();
        if !t.starts_with(['e', 'w', 'E', 'W']) {
            continue;
        }
        if let Some((_, rest)) = t.split_once(':') {
            let f: Vec<u64> = rest.split_whitespace().filter_map(|x| x.parse().ok()).collect();
            if f.len() >= 9 {
                rx += f[0];
                tx += f[8];
            }
        }
    }
    (rx, tx)
}

fn mem() -> (u64, u64) {
    let s = fs::read_to_string("/proc/meminfo").unwrap_or_default();
    let get = |k: &str| {
        s.lines().find(|l| l.starts_with(k)).and_then(|l| l.split_whitespace().nth(1)).and_then(|x| x.parse().ok()).unwrap_or(0)
    };
    (get("MemTotal:"), get("MemAvailable:"))
}

fn read_num(p: &std::path::Path) -> Option<i64> {
    fs::read_to_string(p).ok()?.trim().parse().ok()
}

/// Entries of a sysfs class dir in numeric order (hwmon0, hwmon1, … like the shell glob, which sorts
/// lexically; the numeric order only differs from 10 entries on).
fn numbered(dir: &str, prefix: &str) -> Vec<std::path::PathBuf> {
    let mut v: Vec<(String, std::path::PathBuf)> = fs::read_dir(dir)
        .map(|d| {
            d.flatten()
                .filter_map(|e| {
                    let n = e.file_name().to_string_lossy().into_owned();
                    n.starts_with(prefix).then(|| (n, e.path()))
                })
                .collect()
        })
        .unwrap_or_default();
    v.sort(); // bash globs sort lexically
    v.into_iter().map(|(_, p)| p).collect()
}

fn temp() -> i64 {
    let mut raw = None;
    for h in numbered("/sys/class/hwmon", "hwmon") {
        let name = fs::read_to_string(h.join("name")).unwrap_or_default();
        if ["coretemp", "k10temp", "zenpower", "cpu_thermal", "bcm2835_thermal"].contains(&name.trim()) && h.join("temp1_input").exists() {
            raw = read_num(&h.join("temp1_input"));
            break;
        }
    }
    if raw.is_none() {
        for z in numbered("/sys/class/thermal", "thermal_zone") {
            let ty = fs::read_to_string(z.join("type")).unwrap_or_default();
            if ["x86_pkg_temp", "cpu_thermal", "cpu-thermal"].contains(&ty.trim()) {
                raw = read_num(&z.join("temp"));
                break;
            }
        }
    }
    let raw = raw
        .or_else(|| read_num("/sys/class/hwmon/hwmon0/temp1_input".as_ref()))
        .or_else(|| read_num("/sys/class/thermal/thermal_zone0/temp".as_ref()))
        .unwrap_or(0);
    if raw > 1000 {
        raw / 1000
    } else {
        raw
    }
}

/// `df -Plk -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs -x iso9660`, each device counted once.
fn disk() -> (i64, f64, f64) {
    const SKIP_FS: [&str; 6] = ["tmpfs", "devtmpfs", "squashfs", "overlay", "efivarfs", "iso9660"];
    const REMOTE: [&str; 9] = ["nfs", "nfs4", "cifs", "smb3", "smbfs", "sshfs", "fuse.sshfs", "9p", "afs"];
    let mounts = fs::read_to_string("/proc/self/mounts").unwrap_or_default();
    let mut seen = std::collections::HashSet::new();
    let (mut total, mut used) = (0u128, 0u128);
    for line in mounts.lines() {
        let f: Vec<&str> = line.split(' ').collect();
        if f.len() < 3 {
            continue;
        }
        let (src, mnt, fstype) = (f[0], f[1].replace("\\040", " "), f[2]);
        if SKIP_FS.contains(&fstype) || REMOTE.contains(&fstype) || src.starts_with("/dev/loop") || src == "udev" || src == "none" {
            continue;
        }
        let c = match CString::new(mnt) {
            Ok(c) => c,
            Err(_) => continue,
        };
        let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
        if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 || st.f_blocks == 0 {
            continue; // df hides "dummy" filesystems (proc, sysfs, cgroup…: no blocks)
        }
        if !seen.insert(src.to_string()) {
            continue;
        }
        let fr = st.f_frsize as u128;
        // df -k: sizes in 1 KiB blocks, rounded up
        total += (st.f_blocks as u128 * fr).div_ceil(1024);
        used += ((st.f_blocks - st.f_bfree) as u128 * fr).div_ceil(1024);
    }
    if total == 0 {
        return (0, 0.0, 0.0);
    }
    let pct = ((used as f64 / total as f64) * 100.0 + 0.5) as i64;
    (pct, used as f64 / 1048576.0, total as f64 / 1048576.0)
}

type Cached<T> = (T, Option<Instant>);

struct Sampler {
    cpu: (u64, u64),
    net: (u64, u64),
    at: Instant,
    temp: Cached<i64>,
    disk: Cached<(i64, f64, f64)>,
}

impl Sampler {
    fn new() -> Sampler {
        Sampler { cpu: cpu().unwrap_or((0, 0)), net: net(), at: Instant::now(), temp: (0, None), disk: ((0, 0.0, 0.0), None) }
    }

    /// One line, with CPU and network measured since the previous sample.
    fn line(&mut self, once: bool) -> String {
        let (c2, n2, now) = (cpu().unwrap_or(self.cpu), net(), Instant::now());
        let (di, dt) = (c2.0.saturating_sub(self.cpu.0) as i64, c2.1.saturating_sub(self.cpu.1) as i64);
        let cpu_pct = if dt == 0 { 0 } else { 100 * (dt - di) / dt };
        let (drx, dtx) = (n2.0.wrapping_sub(self.net.0) as i64, n2.1.wrapping_sub(self.net.1) as i64);
        let (rx, tx) = if once {
            (drx * 2, dtx * 2) // the script's fixed 0.5 s window
        } else {
            let ms = now.duration_since(self.at).as_millis().max(1) as i64;
            (drx * 1000 / ms, dtx * 1000 / ms)
        };
        (self.cpu, self.net, self.at) = (c2, n2, now);

        let (mt, ma) = mem();
        let used = mt.saturating_sub(ma);
        let ram_pct = if mt > 0 { 100 * used / mt } else { 0 };
        let ram_gb = used as f64 / 1024.0 / 1024.0;
        if self.temp.1.is_none_or(|t| now.duration_since(t) >= Duration::from_secs(6)) {
            self.temp = (temp(), Some(now));
        }
        if self.disk.1.is_none_or(|t| now.duration_since(t) >= Duration::from_secs(60)) {
            self.disk = (disk(), Some(now));
        }
        let (dp, du, dtot) = self.disk.0;
        format!("{cpu_pct}|{ram_pct}|{ram_gb:.1}|{}|{rx}|{tx}|{dp}|{du:.1}|{dtot:.1}", self.temp.0)
    }
}

fn main() {
    util::ignore_sigpipe();
    let args: Vec<String> = std::env::args().collect();
    let mut s = Sampler::new();
    std::thread::sleep(Duration::from_millis(500));
    match args.get(1).map(String::as_str) {
        Some("--interval") => {
            let ms: u64 = args.get(2).and_then(|x| x.parse().ok()).unwrap_or(2000).max(200);
            loop {
                util::emit(&s.line(false));
                std::thread::sleep(Duration::from_millis(ms));
            }
        }
        _ => util::emit(&s.line(true)),
    }
}
