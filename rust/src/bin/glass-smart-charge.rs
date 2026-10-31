//! glass-smart-charge — optimized battery charging, like iPhone's "Optimized Charging" (Rust port of the
//! Python glass-smart-charge, which is kept in rust/reference/).
//!
//! While on AC it holds the battery at 80 % and only charges to 100 % when you are likely to need it:
//!   * learning      - the first days (not enough history yet): charge fully, like before
//!   * new place     - plugged in somewhere you rarely charge (Wi-Fi/wired network as the location): charge fully
//!   * calendar      - an in-person event (one with a location) is coming up: be full ~45 min before it starts
//!   * routine       - you usually unplug around this time on this kind of day here, and the battery use after that
//!                     unplug is usually more than 80 % can cover: finish charging just before that time
//!   * otherwise     - hold at 80 % (less time at 100 % = slower battery wear)
//!
//! Drain to 80 %: the ASUS firmware only stops charging at the limit, it cannot run the laptop from the battery
//! while the charger is in (tested: limit 80 at 97 % -> "Not charging", 0 W, stays at 97 %). A lithium battery
//! wears faster sitting near full than at 80 %, so when it is held above 85 % on AC with no full charge needed
//! for the next 6 h, the panel says so, and after 30 min one notification suggests unplugging; a second one says
//! when it is down to 80 % and can go back on the charger (where it then stays at 80 %). At most once per 12 h.
//! `glass-smart-charge drain off` turns the notifications off.
//!
//! Changes from the Python version:
//!   * the limit is written on battery too, so plugging in already charges to the right level (the old daemon
//!     left the last limit, often 100, until its next tick: a missed plug event meant a charge to 100 %)
//!   * "on AC" is any online mains or USB-C power-in supply (UPower's view; ACPI AC0 can lag the USB-C one by
//!     seconds), and after every plug/unplug signal it re-checks at 2 s, 15 s and 60 s
//!   * a fixed tick schedule: unrelated D-Bus traffic no longer pushes the next tick back
//!
//!   glass-smart-charge                show the status
//!   glass-smart-charge mode smart|80|100
//!   glass-smart-charge drain on|off   the "unplug to drain to 80 %" notifications (default on)
//!   glass-smart-charge daemon         run (glass-smart-charge.service)
//!
//! Files (~/.local/state/glass-smart-charge/):
//!   mode           smart | 80 | 100 (missing = smart)
//!   drain          on | off (missing = on)
//!   status.json    what the panel shows (code + args, translated in the panel)
//!   history.jsonl  plug/unplug events: time, battery %, hashed network id
//!   learned.json   learned charge speed above 80 %
//! The battery limit is BAT0/charge_control_end_threshold (asus-wmi); it is made writable for the wheel group
//! by /etc/udev/rules.d/61-glass-smart-charge.rules. GLASS_SMART_CHARGE_SYS overrides /sys/class/power_supply
//! (tests).
use dbus::blocking::Connection;
use dbus::channel::Channel;
use glass::util;
use serde_json::{json, Map, Value};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{exit, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const LIMIT: i64 = 80; // hold level
const RESERVE: i64 = 20; // % that should be left at the end of a typical battery session
const LEARN_DAYS: usize = 5; // distinct days of history before "smart" starts holding
const LEARN_UNPLUGS: usize = 4; // ... and this many real unplugs (>= MIN_SESSION)
const PLACE_DAYS: usize = 3; // days with a charge at a network before it counts as a usual place
const MIN_SESSION: i64 = 20 * 60; // unplugs shorter than this are cable jiggles, not "leaving"
const HALF_LIFE: f64 = 14.0; // days; older habits weigh less
const P_UNPLUG: f64 = 0.5; // probability that counts as "you usually unplug around now"
const LOOKAHEAD: f64 = 16.0 * 3600.0; // how far ahead the routine is checked
const MARGIN: f64 = 20.0 * 60.0; // be full this long before the predicted unplug
const CAL_LEAD: f64 = 45.0 * 60.0; // ... and this long before a calendar event
const RATE_HIGH: f64 = 0.6; // default %/min above 80 % (learned)
const RATE_LOW: f64 = 1.0; // %/min below 80 %
const TICK_AC: u64 = 300;
const TICK_BAT: u64 = 3600;
const TICK_NOBUS: u64 = 60; // no system bus: no plug signals, so look more often
const RECHECK: [u64; 3] = [2, 15, 60]; // seconds after a plug/unplug signal
const DRAIN_FROM: i64 = LIMIT + 5; // held at or above this on AC: worth draining
const DRAIN_AFTER: f64 = 30.0 * 60.0; // ... for this long before the notification
const DRAIN_FREE: f64 = 6.0 * 3600.0; // ... and no full charge planned within this
const DRAIN_EVERY: f64 = 12.0 * 3600.0; // at most one drain suggestion per this

struct Paths {
    sys: PathBuf,
    state: PathBuf,
    cal: PathBuf,
}

impl Paths {
    fn new() -> Paths {
        let home = util::home();
        Paths {
            sys: util::env_or("GLASS_SMART_CHARGE_SYS", "/sys/class/power_supply"),
            state: util::env_or("XDG_STATE_HOME", home.join(".local/state")).join("glass-smart-charge"),
            cal: home.join(".cache/gcal-sync/events.json"),
        }
    }
    fn bat(&self, f: &str) -> PathBuf {
        self.sys.join("BAT0").join(f)
    }
    fn thresh(&self) -> PathBuf {
        self.bat("charge_control_end_threshold")
    }
    fn st(&self, f: &str) -> PathBuf {
        self.state.join(f)
    }
}

fn rd(path: impl AsRef<Path>) -> String {
    util::read_trim(path).unwrap_or_default()
}

fn now_f() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// Plugged in: an online mains or USB power-in supply (what UPower counts; not "Device" scoped ones).
fn on_ac(p: &Paths) -> bool {
    let Ok(dir) = fs::read_dir(&p.sys) else { return false };
    dir.flatten().any(|e| {
        let d = e.path();
        matches!(rd(d.join("type")).as_str(), "Mains" | "USB") && rd(d.join("scope")) != "Device" && rd(d.join("online")) == "1"
    })
}

fn capacity(p: &Paths) -> i64 {
    rd(p.bat("capacity")).parse().unwrap_or(0)
}

fn mode(p: &Paths) -> String {
    let m = rd(p.st("mode"));
    if matches!(m.as_str(), "smart" | "80" | "100") { m } else { "smart".into() }
}

fn drain_on(p: &Paths) -> bool {
    rd(p.st("drain")) != "off"
}

// ---------- local time (what Python's datetime.fromtimestamp does) ----------
extern "C" {
    fn tzset();
}

struct Lt {
    day: i64, // yyyymmdd
    tod: i64, // minutes since midnight
    weekend: bool,
    hhmm: String,
}

fn local(ts: f64) -> Lt {
    let t = ts.floor() as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&t, &mut tm) };
    Lt {
        day: (tm.tm_year as i64 + 1900) * 10000 + (tm.tm_mon as i64 + 1) * 100 + tm.tm_mday as i64,
        tod: tm.tm_hour as i64 * 60 + tm.tm_min as i64,
        weekend: tm.tm_wday == 0 || tm.tm_wday == 6,
        hhmm: format!("{:02}:{:02}", tm.tm_hour, tm.tm_min),
    }
}

/// "YYYY-MM-DD..." at 08:00 local time, as a timestamp.
fn date_at_8(s: &str) -> Option<f64> {
    let mut it = s.get(..10)?.split('-').map(|x| x.parse::<i32>().ok());
    let (y, m, d) = (it.next()??, it.next()??, it.next()??);
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    tm.tm_year = y - 1900;
    tm.tm_mon = m - 1;
    tm.tm_mday = d;
    tm.tm_hour = 8;
    tm.tm_isdst = -1;
    let t = unsafe { libc::mktime(&mut tm) };
    (t != -1).then_some(t as f64)
}

fn tod_dist(a: i64, b: i64) -> i64 {
    let d = (a - b).abs() % 1440;
    d.min(1440 - d)
}

fn weight(ts: f64, now: f64) -> f64 {
    0.5f64.powf((now - ts) / 86400.0 / HALF_LIFE)
}

// ---------- history ----------
#[derive(Clone)]
struct Ev {
    plug: bool,
    ts: i64,
    cap: i64,
    loc: String,
}

struct Session {
    ts: i64,
    loc: String,
    drain: i64,
}

fn load_history(p: &Paths) -> Vec<Ev> {
    let Ok(text) = fs::read_to_string(p.st("history.jsonl")) else { return vec![] };
    text.lines()
        .filter_map(|l| {
            let v: Value = serde_json::from_str(l).ok()?;
            let plug = match v["ev"].as_str()? {
                "plug" => true,
                "unplug" => false,
                _ => return None,
            };
            Some(Ev { plug, ts: v["ts"].as_i64()?, cap: v["cap"].as_i64()?, loc: v["loc"].as_str()?.to_string() })
        })
        .collect()
}

fn log_event(p: &Paths, plug: bool, cap: i64, loc: &str) {
    let _ = fs::create_dir_all(&p.state);
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(p.st("history.jsonl")) {
        let ev = if plug { "plug" } else { "unplug" };
        let ts = now_f() as i64;
        let _ = writeln!(f, "{{\"ev\": \"{ev}\", \"ts\": {ts}, \"cap\": {cap}, \"loc\": {}}}", Value::from(loc));
    }
}

/// Battery sessions: unplug -> next plug, at least MIN_SESSION long.
fn sessions(ev: &[Ev]) -> Vec<Session> {
    let mut out = vec![];
    let mut open: Option<&Ev> = None;
    for e in ev {
        if !e.plug {
            open = Some(e);
        } else if let Some(u) = open.take() {
            let dur = e.ts - u.ts;
            if dur >= MIN_SESSION {
                out.push(Session { ts: u.ts, loc: u.loc.clone(), drain: (u.cap - e.cap).max(0) });
            }
        }
    }
    out
}

fn n_days(ev: &[Ev]) -> usize {
    let mut d: Vec<i64> = ev.iter().map(|e| local(e.ts as f64).day).collect();
    d.sort_unstable();
    d.dedup();
    d.len()
}

/// First time in the next LOOKAHEAD when you usually unplug here (P >= P_UNPLUG), or None.
fn predict_unplug(ev: &[Ev], sess: &[Session], loc: &str, now: f64) -> Option<f64> {
    let today = local(now).day;
    // day -> (ts of the last event there, weekend), in first-seen order like the Python dict
    let mut days: Vec<(i64, f64, bool)> = vec![];
    for e in ev.iter().filter(|e| e.loc == loc) {
        let lt = local(e.ts as f64);
        if lt.day == today {
            continue;
        }
        match days.iter_mut().find(|d| d.0 == lt.day) {
            Some(d) => d.1 = e.ts as f64,
            None => days.push((lt.day, e.ts as f64, lt.weekend)),
        }
    }
    if days.len() < 2 {
        return None;
    }
    let mut hits: Vec<(i64, Vec<i64>)> = vec![];
    for s in sess.iter().filter(|s| s.loc == loc) {
        let lt = local(s.ts as f64);
        match hits.iter_mut().find(|h| h.0 == lt.day) {
            Some(h) => h.1.push(lt.tod),
            None => hits.push((lt.day, vec![lt.tod])),
        }
    }
    let mut t = now;
    while t <= now + LOOKAHEAD {
        let lt = local(t);
        let mut pool: Vec<&(i64, f64, bool)> = days.iter().filter(|d| d.2 == lt.weekend).collect();
        if pool.len() < 3 {
            pool = days.iter().collect();
        }
        let tot: f64 = pool.iter().map(|d| weight(d.1, now)).sum();
        let hit: f64 = pool
            .iter()
            .filter(|d| hits.iter().find(|h| h.0 == d.0).is_some_and(|h| h.1.iter().any(|&u| tod_dist(u, lt.tod) <= 30)))
            .map(|d| weight(d.1, now))
            .sum();
        if tot != 0.0 && hit / tot >= P_UNPLUG {
            return Some(t);
        }
        t += 900.0;
    }
    None
}

/// Weighted ~80th percentile of battery used after unplugs around this time of day, or None.
fn usual_drain(sess: &[Session], loc: &str, at: f64, now: f64) -> Option<i64> {
    let x = local(at).tod;
    let mut pts: Vec<(i64, f64)> = sess
        .iter()
        .filter(|s| s.loc == loc && tod_dist(local(s.ts as f64).tod, x) <= 90)
        .map(|s| (s.drain, weight(s.ts as f64, now)))
        .collect();
    if pts.len() < 2 {
        return None;
    }
    pts.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.total_cmp(&b.1)));
    let total: f64 = pts.iter().map(|p| p.1).sum();
    let mut acc = 0.0;
    for &(d, w) in &pts {
        acc += w;
        if acc >= 0.8 * total {
            return Some(d);
        }
    }
    pts.last().map(|p| p.0)
}

/// Next in-person calendar event (has a location) within LOOKAHEAD: (start ts, title) or None.
fn next_event(p: &Paths, now: f64) -> Option<(f64, String)> {
    let v: Value = serde_json::from_slice(&fs::read(&p.cal).ok()?).ok()?;
    let evs = v.as_object()?.get("events")?.as_array()?;
    let num = |x: &Value| x.as_f64().filter(|f| *f != 0.0).unwrap_or(0.0);
    let mut best: Option<(f64, String)> = None;
    for e in evs {
        if e["location"].as_str().unwrap_or("").trim().is_empty() {
            continue;
        }
        let mut start = num(&e["startMs"]) / 1000.0;
        if e["allDay"].as_bool().unwrap_or(false) {
            let Some(s) = e["startDate"].as_str().and_then(date_at_8) else { continue };
            start = s;
            let end = num(&e["endMs"]) / 1000.0;
            if start <= now && now < end {
                start = now;
            }
        }
        if now - 60.0 <= start && start <= now + LOOKAHEAD && best.as_ref().map_or(true, |b| start < b.0) {
            best = Some((start, e["title"].as_str().unwrap_or("").to_string()));
        }
    }
    best
}

fn minutes_to_full(cap: i64, rate_high: f64) -> f64 {
    let mut m = 0.0;
    if cap < LIMIT {
        m += (LIMIT - cap) as f64 / RATE_LOW;
    }
    m + (100 - cap.max(LIMIT)) as f64 / rate_high
}

fn load_json(path: &Path) -> Map<String, Value> {
    fs::read(path).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()).and_then(|v| v.as_object().cloned()).unwrap_or_default()
}

fn rate_high(p: &Paths) -> f64 {
    load_json(&p.st("learned.json")).get("rate_high").and_then(Value::as_f64).unwrap_or(RATE_HIGH)
}

struct Decision {
    limit: i64,
    code: &'static str,
    args: Value,
    /// when holding at 80 %: the time the planned charge to 100 % starts, if any
    charge_at: Option<f64>,
}

fn decide(p: &Paths, now: f64, cap: i64, loc: &str) -> Decision {
    let d = |limit, code, args| Decision { limit, code, args, charge_at: None };
    match mode(p).as_str() {
        "80" => return d(80, "manual80", json!({})),
        "100" => return d(100, "manual100", json!({})),
        _ => {}
    }
    let ev = load_history(p);
    let sess = sessions(&ev);
    let ndays = n_days(&ev);
    if ndays < LEARN_DAYS || sess.len() < LEARN_UNPLUGS {
        return d(100, "learning", json!({"days": ndays.min(LEARN_DAYS), "need": LEARN_DAYS}));
    }
    let place_days = n_days(&ev.iter().filter(|e| e.plug && e.loc == loc).cloned().collect::<Vec<_>>());
    if place_days < PLACE_DAYS {
        return d(100, "newplace", json!({}));
    }
    let lead = minutes_to_full(cap, rate_high(p)) * 60.0;
    let cal = next_event(p, now);
    if let Some((start, title)) = &cal {
        if now >= start - CAL_LEAD - lead - MARGIN {
            let title: String = title.chars().take(40).collect();
            return d(100, "calendar", json!({"time": local(*start).hhmm, "title": title}));
        }
    }
    if let Some(t) = predict_unplug(&ev, &sess, loc, now) {
        let need = usual_drain(&sess, loc, t, now);
        if need.map_or(true, |n| n > LIMIT - RESERVE) {
            if now >= t - lead - MARGIN {
                return d(100, "topup", json!({"time": local(t).hhmm}));
            }
            let args = json!({"full": local(t - MARGIN).hhmm, "time": local(t).hhmm});
            return Decision { limit: LIMIT, code: "holduntil", args, charge_at: Some(t - lead - MARGIN) };
        }
        return d(LIMIT, "enough", json!({"time": local(t).hhmm, "use": need}));
    }
    if let Some((start, _)) = cal {
        let args = json!({"full": local(start - CAL_LEAD).hhmm, "time": local(start).hhmm});
        return Decision { limit: LIMIT, code: "holduntil", args, charge_at: Some(start - CAL_LEAD - lead - MARGIN) };
    }
    d(LIMIT, "hold", json!({}))
}

fn set_limit(p: &Paths, limit: i64) -> bool {
    let path = p.thresh();
    if rd(&path) == limit.to_string() {
        return true;
    }
    match fs::write(&path, limit.to_string()) {
        Ok(()) => true,
        Err(e) => {
            eprintln!("cannot set {}: {e}", path.display());
            false
        }
    }
}

// ---------- location: the active network, hashed ----------
fn sha1_hex(data: &[u8]) -> String {
    let mut h: [u32; 5] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&((data.len() as u64) * 8).to_be_bytes());
    for chunk in msg.chunks(64) {
        let mut w = [0u32; 80];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([chunk[4 * i], chunk[4 * i + 1], chunk[4 * i + 2], chunk[4 * i + 3]]);
        }
        for i in 16..80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1);
        }
        let [mut a, mut b, mut c, mut d, mut e] = h;
        for (i, &wi) in w.iter().enumerate() {
            let (f, k) = match i {
                0..=19 => ((b & c) | (!b & d), 0x5A827999),
                20..=39 => (b ^ c ^ d, 0x6ED9EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1BBCDC),
                _ => (b ^ c ^ d, 0xCA62C1D6),
            };
            let t = a.rotate_left(5).wrapping_add(f).wrapping_add(e).wrapping_add(k).wrapping_add(wi);
            (e, d, c, b, a) = (d, c, b.rotate_left(30), a, t);
        }
        for (x, y) in h.iter_mut().zip([a, b, c, d, e]) {
            *x = x.wrapping_add(y);
        }
    }
    h.iter().map(|x| format!("{x:08x}")).collect()
}

/// (id, name) of the first active Wi-Fi/wired connection in `nmcli -t -f NAME,TYPE` output.
fn parse_location(out: &str) -> (String, String) {
    for line in out.lines() {
        let Some((name, typ)) = line.rsplit_once(':') else { continue };
        if typ.ends_with("wireless") || typ.ends_with("ethernet") {
            let name = name.replace("\\:", ":");
            return (sha1_hex(format!("{typ}:{name}").as_bytes())[..12].to_string(), name);
        }
    }
    ("offline".into(), String::new())
}

fn location() -> (String, String) {
    let out = Command::new("nmcli")
        .args(["-t", "-f", "NAME,TYPE", "connection", "show", "--active"])
        .stderr(Stdio::null())
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    parse_location(&out)
}

/// Written in place (not tmp + rename): the panel's FileView watches this path with inotify.
fn save_json(p: &Paths, path: &Path, v: &Value) {
    let _ = fs::create_dir_all(&p.state);
    let data = v.to_string();
    if rd(path) != data {
        let _ = util::write_in_place(path, data.as_bytes());
    }
}

// ---------- notifications, in the shell's language ----------
fn tr(key: &str, args: &[(&str, String)], fallback: &str) -> String {
    let home = util::home();
    let settings = load_json(&home.join(".config/serpantinum/settings.json"));
    let lang = settings.get("general").and_then(|g| g["language"].as_str()).unwrap_or("en").to_string();
    let dir = util::env_or("SERPANTINUM_DIR", home.join(".local/share/serpantinum/src")).join("assets/languages");
    let lookup = |l: &str| {
        let v: Value = serde_json::from_slice(&fs::read(dir.join(format!("{l}.json"))).ok()?).ok()?;
        key.split('.').try_fold(&v, |v, k| v.get(k)).and_then(Value::as_str).map(String::from)
    };
    let mut s = lookup(&lang).or_else(|| lookup("en")).unwrap_or_else(|| fallback.to_string());
    for (k, v) in args {
        s = s.replace(&format!("{{{k}}}"), v);
    }
    s
}

fn notify(body: &str) {
    let title = tr("syspanel.charge.title", &[], "Smart charging");
    let _ = Command::new("notify-send")
        .args(["-a", "glass-smart-charge", "-i", "battery-good", "-h", "string:x-canonical-private-synchronous:glass-smart-charge"])
        .args([title.as_str(), body])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

// ---------- daemon ----------
struct Daemon {
    p: Paths,
    ac: Option<bool>,
    last: Option<(f64, i64)>, // (ts, cap) while charging above LIMIT, to learn the charge speed
    above_since: Option<f64>, // held at >= DRAIN_FROM on AC since
    draining: bool,           // asked to unplug; waiting for 80 %
    last_ask: f64,
    notify: fn(&str),
}

impl Daemon {
    fn new(p: Paths, notify: fn(&str)) -> Daemon {
        let ev = load_history(&p); // a plug/unplug while the daemon was not running is logged on the first tick
        let ac = ev.last().map(|e| e.plug);
        Daemon { p, ac, last: None, above_since: None, draining: false, last_ask: f64::NEG_INFINITY, notify }
    }

    fn learn_rate(&mut self, now: f64, cap: i64) {
        if !(self.ac == Some(true) && rd(self.p.bat("status")) == "Charging" && (LIMIT..100).contains(&cap)) {
            self.last = None;
            return;
        }
        if let Some((t0, c0)) = self.last {
            if cap > c0 && now - t0 < 2.0 * TICK_AC as f64 {
                let r = (cap - c0) as f64 / ((now - t0) / 60.0);
                if 0.05 < r && r < 5.0 {
                    let path = self.p.st("learned.json");
                    let mut lr = load_json(&path);
                    let old = lr.get("rate_high").and_then(Value::as_f64).unwrap_or(RATE_HIGH);
                    lr.insert("rate_high".into(), json!(((0.7 * old + 0.3 * r) * 1000.0).round() / 1000.0));
                    save_json(&self.p, &path, &Value::Object(lr));
                }
            }
        }
        if self.last.map_or(true, |l| l.1 != cap) {
            self.last = Some((now, cap));
        }
    }

    /// The drain-to-80 % suggestion: status code override, and the two notifications.
    fn drain(&mut self, now: f64, cap: i64, ac: bool, d: &mut Decision) {
        if !ac {
            self.above_since = None;
            if self.draining && cap <= LIMIT {
                self.draining = false;
                (self.notify)(&tr("syspanel.charge.notify.plugin", &[("cap", cap.to_string())], "Battery at {cap}%: plug the charger back in, it will stay at 80%"));
            } else if self.draining {
                (d.code, d.args) = ("draining", json!({"cap": cap}));
            }
            return;
        }
        self.draining = false;
        let wanted = d.limit == LIMIT && cap >= DRAIN_FROM && d.charge_at.map_or(true, |t| t - now > DRAIN_FREE);
        if !wanted {
            self.above_since = None;
            return;
        }
        (d.code, d.args) = ("drain", json!({"cap": cap}));
        let since = *self.above_since.get_or_insert(now);
        if drain_on(&self.p) && now - since >= DRAIN_AFTER && now - self.last_ask >= DRAIN_EVERY {
            self.last_ask = now;
            self.draining = true;
            (self.notify)(&tr("syspanel.charge.notify.drain", &[("cap", cap.to_string())], "Battery held at {cap}%: unplug for a while to let it drain to 80%, it wears less there"));
        }
    }

    fn tick(&mut self) {
        let (now, cap, ac) = (now_f(), capacity(&self.p), on_ac(&self.p));
        let (loc, name) = location();
        if self.ac != Some(ac) {
            if self.ac.is_some() {
                log_event(&self.p, ac, cap, &loc);
            }
            self.ac = Some(ac);
        }
        self.learn_rate(now, cap);
        let status = self.p.st("status.json");
        if !self.p.thresh().exists() {
            save_json(&self.p, &status, &json!({"supported": false}));
            return;
        }
        let mut d = decide(&self.p, now, cap, &loc);
        // also on battery: the limit is then already right the moment the charger goes in
        let ok = set_limit(&self.p, d.limit);
        self.drain(now, cap, ac, &mut d);
        save_json(
            &self.p,
            &status,
            &json!({"supported": true, "writable": ok, "mode": mode(&self.p), "ac": ac, "limit": d.limit,
                    "applied": rd(self.p.thresh()), "code": d.code, "args": d.args, "place": name,
                    "updated": now as i64}),
        );
    }

    fn run(&mut self) -> i32 {
        let sig = util::signal_pipe(&[libc::SIGTERM, libc::SIGINT, libc::SIGUSR1]).expect("signal pipe");
        let mut bus: Option<Connection> = None;
        let mut rechecks: Vec<Instant> = vec![];
        let mut next = Instant::now();
        loop {
            if bus.is_none() {
                bus = system_bus();
            }
            let now = Instant::now();
            if now >= next || rechecks.iter().any(|&r| now >= r) {
                rechecks.retain(|&r| r > now);
                self.tick();
                let every = if bus.is_none() { TICK_NOBUS } else if self.ac == Some(true) { TICK_AC } else { TICK_BAT };
                next = Instant::now() + Duration::from_secs(every);
            }
            let wake = rechecks.iter().copied().fold(next, Instant::min);
            let timeout = wake.saturating_duration_since(Instant::now());
            let fds: Vec<i32> = [Some(sig), bus.as_ref().map(|c| c.channel().watch().fd)].into_iter().flatten().collect();
            let ready = util::poll_read(&fds, Some(timeout)).unwrap_or_default();
            if ready.first() == Some(&true) {
                let sigs = util::drain_signals(sig);
                if util::terminated() {
                    return 0;
                }
                if sigs.contains(&libc::SIGUSR1) {
                    next = Instant::now(); // "mode changed": the panel pokes us
                }
            }
            if ready.get(1) == Some(&true) {
                let Some(c) = bus.as_ref() else { continue };
                if c.channel().read_write(Some(Duration::ZERO)).is_err() {
                    eprintln!("glass-smart-charge: lost the system bus");
                    bus = None;
                    continue;
                }
                if plug_signal(c) {
                    let t = Instant::now();
                    rechecks = RECHECK.iter().map(|&s| t + Duration::from_secs(s)).collect();
                }
            }
        }
    }
}

fn system_bus() -> Option<Connection> {
    let conn = Channel::get_private(dbus::channel::BusType::System).ok().map(|mut ch| {
        ch.set_watch_enabled(true);
        Connection::from(ch)
    })?;
    conn.add_match_no_cb(
        "type='signal',sender='org.freedesktop.UPower',path='/org/freedesktop/UPower',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'",
    )
    .ok()?;
    Some(conn)
}

/// Drains the queued messages; true when UPower's OnBattery changed among them.
fn plug_signal(c: &Connection) -> bool {
    let mut flipped = false;
    while let Some(msg) = c.channel().pop_message() {
        if msg.member().as_deref() != Some("PropertiesChanged") {
            continue;
        }
        let (iface, changed, invalidated): (Option<String>, Option<dbus::arg::PropMap>, Option<Vec<String>>) = msg.get3();
        if iface.as_deref() == Some("org.freedesktop.UPower")
            && (changed.is_some_and(|c| c.contains_key("OnBattery")) || invalidated.is_some_and(|i| i.iter().any(|x| x == "OnBattery")))
        {
            flipped = true;
        }
    }
    flipped
}

fn show(p: &Paths) {
    let s = load_json(&p.st("status.json"));
    let ev = load_history(p);
    let ac = if on_ac(p) { "AC" } else { "battery" };
    println!("mode       {}  (glass-smart-charge mode smart|80|100)", mode(p));
    println!("limit      {} %   battery {} %  {ac}", util::read_trim(p.thresh()).unwrap_or_else(|| "?".into()), capacity(p));
    let code = s.get("code").and_then(Value::as_str).unwrap_or("?");
    println!("decision   {code} {}", s.get("args").map(Value::to_string).unwrap_or_default());
    let place = s.get("place").and_then(Value::as_str).filter(|x| !x.is_empty()).unwrap_or("(no network)");
    println!("place      {place}");
    println!("drain      {}  (glass-smart-charge drain on|off: suggest unplugging when held above {DRAIN_FROM} %)", if drain_on(p) { "on" } else { "off" });
    println!(
        "history    {} events, {} days, {} real unplugs; charge speed >80 %: {} %/min",
        ev.len(),
        n_days(&ev),
        sessions(&ev).len(),
        rate_high(p)
    );
}

fn write_setting(p: &Paths, name: &str, value: &str) {
    let _ = fs::create_dir_all(&p.state);
    if let Err(e) = fs::write(p.st(name), format!("{value}\n")) {
        eprintln!("glass-smart-charge: {e}");
        exit(1);
    }
    let _ = Command::new("systemctl")
        .args(["--user", "kill", "-s", "USR1", "glass-smart-charge.service"])
        .stderr(Stdio::null())
        .status();
}

fn main() {
    util::ignore_sigpipe();
    unsafe { tzset() };
    let p = Paths::new();
    let a: Vec<String> = std::env::args().skip(1).collect();
    let a: Vec<&str> = a.iter().map(String::as_str).collect();
    match a.as_slice() {
        [] => show(&p),
        ["daemon"] => exit(Daemon::new(p, notify).run()),
        ["mode", m @ ("smart" | "80" | "100")] => write_setting(&p, "mode", m),
        ["drain", v @ ("on" | "off")] => write_setting(&p, "drain", v),
        // tests: the decision at a given time, battery level and place, as JSON [limit, code, args]
        ["decide", ts, cap, loc] => {
            let d = decide(&p, ts.parse().unwrap_or(0.0), cap.parse().unwrap_or(0), loc);
            println!("{}", json!([d.limit, d.code, d.args]));
        }
        _ => {
            eprintln!("usage: glass-smart-charge [daemon | mode smart|80|100 | drain on|off]");
            exit(2);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha1() {
        assert_eq!(sha1_hex(b""), "da39a3ee5e6b4b0d3255bfef95601890afd80709");
        assert_eq!(sha1_hex(b"abc"), "a9993e364706816aba3e25717850c26c9cd0d89d");
        assert_eq!(sha1_hex(&[b'a'; 1000]), "291e9a6c66994949b57ba5e650361e98fc36b1ba");
    }

    #[test]
    fn nmcli_location() {
        let (id, name) = parse_location("lo:loopback\nMy\\:Net:802-11-wireless\nWired:802-3-ethernet\n");
        assert_eq!(name, "My:Net");
        assert_eq!(id, sha1_hex(b"802-11-wireless:My:Net")[..12]);
        assert_eq!(parse_location("lo:loopback\n"), ("offline".into(), String::new()));
    }

    #[test]
    fn sessions_and_drain() {
        let e = |plug, ts, cap| Ev { plug, ts, cap, loc: "x".into() };
        let ev = [e(false, 0, 90), e(true, 600, 88), e(false, 1000, 80), e(true, 1000 + 3600, 50), e(true, 9000, 40)];
        let s = sessions(&ev);
        assert_eq!(s.len(), 1); // the 10 min unplug is a jiggle
        assert_eq!((s[0].ts, s[0].drain), (1000, 30));
        assert_eq!(tod_dist(10, 1430), 20);
        assert_eq!(minutes_to_full(70, 0.5), 10.0 + 40.0);
        assert_eq!(minutes_to_full(90, 0.5), 20.0);
    }

    static SENT: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());
    fn record(s: &str) {
        SENT.lock().unwrap().push(s.to_string());
    }

    #[test]
    fn drain_suggestion() {
        let p = Paths { sys: "/nonexistent".into(), state: "/nonexistent".into(), cal: "/nonexistent".into() };
        let mut dm = Daemon { p, ac: Some(true), last: None, above_since: None, draining: false, last_ask: f64::NEG_INFINITY, notify: record };
        let hold = || Decision { limit: LIMIT, code: "hold", args: json!({}), charge_at: None };
        let sent = || SENT.lock().unwrap().len();
        let t0 = 1_000_000.0;
        // 84 % is close enough to 80: nothing
        let mut d = hold();
        dm.drain(t0, 84, true, &mut d);
        assert_eq!((d.code, sent()), ("hold", 0));
        // 97 % held: the panel says so at once, the notification comes after 30 min, once
        for (dt, want) in [(0.0, 0), (29.0 * 60.0, 0), (31.0 * 60.0, 1), (60.0 * 60.0, 1)] {
            let mut d = hold();
            dm.drain(t0 + dt, 97, true, &mut d);
            assert_eq!((d.code, sent()), ("drain", want));
        }
        // a full charge planned in 2 h: draining now would be undone, so no suggestion
        let mut d = Decision { charge_at: Some(t0 + 7200.0), ..hold() };
        dm.drain(t0, 97, true, &mut d);
        assert_eq!(d.code, "hold");
        // unplugged: "draining" until 80 %, then one "plug back in"
        dm.draining = true;
        let mut d = hold();
        dm.drain(t0 + 4000.0, 90, false, &mut d);
        assert_eq!((d.code, sent()), ("draining", 1));
        let mut d = hold();
        dm.drain(t0 + 8000.0, 80, false, &mut d);
        assert_eq!((d.code, sent()), ("hold", 2));
        assert!(SENT.lock().unwrap()[1].contains("80%"));
        // back on AC above 85 % within 12 h: the panel says so, but no second notification
        for dt in [9000.0, 9000.0 + 3600.0] {
            let mut d = hold();
            dm.drain(t0 + dt, 90, true, &mut d);
            assert_eq!((d.code, sent()), ("drain", 2));
        }
    }
}
