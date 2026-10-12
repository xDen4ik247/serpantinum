//! serp-wellbeing — Serpantinum's Digital Wellbeing tracker (port of guide/wellbeing/focus_daemon.py).
//!
//! Counts the seconds spent in the focused app into the same SQLite database
//! (~/.local/state/quickshell/focustime/focustime.db, tables focus_log/_hourly/_intervals/_minutes) and
//! writes the same $QS_RUN_FOCUSTIME/focustime_state.json for the Wellbeing tab, with the same daily
//! limit notifications. The Python daemon spawned `niri msg -j focused-window` after every niri event
//! (a terminal spinner alone is one per second); this follows niri's event stream in-process.
//!
//!   serp-wellbeing                       run the daemon (niri only; launch_daemon.sh falls back to Python)
//!   serp-wellbeing --dump-sync DATE      print the state JSON for DATE (YYYY-MM-DD) and exit (tests)
//!   serp-wellbeing --replay FILE         feed ticks "UNIX_TIME<TAB>CLASS<TAB>TITLE<TAB>SECS<TAB>WRITE" (tests)
//!   serp-wellbeing --resolve             one niri window JSON per stdin line -> ["class","name"] (tests)
use glass::niri::{EventStream, State};
use glass::util;
use regex::Regex;
use rusqlite::{params, Connection};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

const SYSTEM_STATES: [&str; 4] = ["Desktop", "Locked", "Quickshell", "Unknown"];
const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const DAYS: [&str; 7] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

fn is_system(c: &str) -> bool {
    SYSTEM_STATES.contains(&c)
}

// ---------- dates (proleptic Gregorian, days since 1970-01-01) ----------
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
struct Date(i64);

impl Date {
    fn from_ymd(y: i64, m: u32, d: u32) -> Date {
        let y = if m <= 2 { y - 1 } else { y };
        let era = y.div_euclid(400);
        let yoe = y - era * 400;
        let mp = (m as i64 + 9) % 12;
        let doy = (153 * mp + 2) / 5 + d as i64 - 1;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        Date(era * 146097 + doe - 719468)
    }
    fn ymd(self) -> (i64, u32, u32) {
        let z = self.0 + 719468;
        let era = z.div_euclid(146097);
        let doe = z - era * 146097;
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
        let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
        (if m <= 2 { yoe + era * 400 + 1 } else { yoe + era * 400 }, m, d)
    }
    fn parse(s: &str) -> Option<Date> {
        let mut it = s.split('-');
        let y = it.next()?.parse().ok()?;
        let m = it.next()?.parse().ok()?;
        let d = it.next()?.parse().ok()?;
        Some(Date::from_ymd(y, m, d))
    }
    fn iso(self) -> String {
        let (y, m, d) = self.ymd();
        format!("{y:04}-{m:02}-{d:02}")
    }
    fn weekday(self) -> i64 {
        (self.0 + 3).rem_euclid(7) // Monday = 0
    }
    fn add(self, days: i64) -> Date {
        Date(self.0 + days)
    }
    fn days_in_month(self) -> u32 {
        let (y, m, _) = self.ymd();
        let next = if m == 12 { Date::from_ymd(y + 1, 1, 1) } else { Date::from_ymd(y, m + 1, 1) };
        (next.0 - Date::from_ymd(y, m, 1).0) as u32
    }
}

/// "Now" broken down in local time; injectable for --replay.
#[derive(Clone, Copy)]
struct Now {
    unix: f64,
    date: Date,
    hour: u32,
    minute: u32,
}

impl Now {
    fn at(unix: f64) -> Now {
        let (y, m, d, hh, mm, _, _) = util::local_tm(unix.floor() as i64);
        Now { unix, date: Date::from_ymd(y as i64, m, d), hour: hh, minute: mm }
    }
    fn real() -> Now {
        Now::at(util::now_unix())
    }
}

/// Python's round(x, 1): correctly rounded from the exact binary value (ties to even).
fn round1(x: f64) -> f64 {
    format!("{x:.1}").parse().unwrap_or(x)
}

fn pct(part: i64, total: i64) -> Value {
    if total > 0 {
        json!(round1(part as f64 / total as f64 * 100.0))
    } else {
        json!(0)
    }
}

// ---------- the focused app, as focus_daemon.py names it ----------
fn py_capitalize(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + &c.as_str().to_lowercase(),
        None => String::new(),
    }
}

fn py_strip(s: &str) -> &str {
    // str.strip(): Unicode whitespace plus the ASCII separators \x1c-\x1f
    s.trim_matches(|c: char| c.is_whitespace() || ('\x1c'..='\x1f').contains(&c))
}

fn resolve_app_name(app_class: &str, raw_title: &str) -> String {
    static RES: OnceLock<(Regex, Regex, Regex)> = OnceLock::new();
    let (lead, trail, split) = RES.get_or_init(|| {
        (
            Regex::new(r"^\(\d+\)\s*|^\[\d+\]\s*").unwrap(),
            Regex::new(r"\s*\(\d+\)$").unwrap(),
            Regex::new(r"\s+[-—|]\s+").unwrap(),
        )
    });
    if app_class.is_empty() || is_system(app_class) {
        return if app_class.is_empty() { "Unknown".into() } else { app_class.into() };
    }
    let t = lead.replace(raw_title, "");
    let t = trail.replace(&t, "");
    let parts: Vec<&str> = split.split(&t).collect();
    let name = if parts.len() > 1 { py_strip(parts[parts.len() - 1]) } else { py_strip(&t) };
    if name.chars().count() > 25 {
        py_capitalize(app_class)
    } else {
        name.to_string()
    }
}

/// get_active_window_niri(): (class, display name) of the focused window.
fn active_window(w: Option<&Value>) -> (String, String) {
    let w = match w {
        Some(w) if w.is_object() => w,
        _ => return ("Desktop".into(), "Desktop".into()),
    };
    let s = |k: &str| py_strip(w[k].as_str().unwrap_or("")).to_string();
    let (cls, title) = (s("app_id"), s("title"));
    let (cl, tl) = (cls.to_lowercase(), title.to_lowercase());
    if cl.contains("quickshell") || tl.contains("qs-master") || cl.contains("qs-master") {
        return ("Quickshell".into(), "Quickshell".into());
    }
    let cls = if cls.is_empty() { "Unknown".to_string() } else { cls };
    let title = if title.is_empty() { cls.clone() } else { title };
    let name = resolve_app_name(&cls, &title);
    (cls, name)
}

// ---------- database ----------
fn init_db(path: &Path) -> rusqlite::Result<Connection> {
    let c = Connection::open(path)?;
    c.execute_batch(
        "CREATE TABLE IF NOT EXISTS focus_log (log_date TEXT, app_class TEXT, seconds INTEGER, app_title TEXT, PRIMARY KEY (log_date, app_class));
         CREATE INDEX IF NOT EXISTS idx_log_date ON focus_log(log_date);
         CREATE TABLE IF NOT EXISTS focus_hourly (log_date TEXT, hour INTEGER, app_class TEXT, seconds INTEGER, PRIMARY KEY (log_date, hour, app_class));
         CREATE TABLE IF NOT EXISTS focus_intervals (log_date TEXT, interval_idx INTEGER, app_class TEXT, seconds INTEGER, PRIMARY KEY (log_date, interval_idx, app_class));
         CREATE TABLE IF NOT EXISTS focus_minutes (log_date TEXT, minute_idx INTEGER, app_class TEXT, seconds INTEGER, PRIMARY KEY (log_date, minute_idx, app_class));",
    )?;
    let has_title = {
        let mut st = c.prepare("PRAGMA table_info(focus_log)")?;
        let cols: Vec<String> = st.query_map([], |r| r.get::<_, String>(1))?.filter_map(Result::ok).collect();
        cols.iter().any(|n| n == "app_title")
    };
    if !has_title {
        c.execute("ALTER TABLE focus_log ADD COLUMN app_title TEXT", [])?;
    }
    Ok(c)
}

struct Entry {
    date: String,
    class: String,
    title: String,
    hour: u32,
    minute: u32,
    secs: i64,
}

struct Tracker {
    conn: Connection,
    buffer: Vec<Entry>,
    cached: Option<Map<String, Value>>,
    last_sync: f64,
    last_date: Date,
    state_file: PathBuf,
}

fn sum_i64(conn: &Connection, sql: &str, p: &[&dyn rusqlite::ToSql]) -> i64 {
    conn.query_row(sql, p, |r| r.get::<_, Option<i64>>(0)).ok().flatten().unwrap_or(0)
}

type Row3 = (String, String, i64);

fn rows3(c: &Connection, sql: &str, p: &[&dyn rusqlite::ToSql]) -> rusqlite::Result<Vec<Row3>> {
    let mut st = c.prepare(sql)?;
    let v = st
        .query_map(p, |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?.unwrap_or_default(), r.get::<_, Option<i64>>(2)?.unwrap_or(0))))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(v)
}

fn pairs(c: &Connection, sql: &str, p: &[&dyn rusqlite::ToSql]) -> Vec<(i64, i64)> {
    c.prepare(sql)
        .and_then(|mut st| {
            st.query_map(p, |r| Ok((r.get::<_, Option<i64>>(0)?.unwrap_or(-1), r.get::<_, Option<i64>>(1)?.unwrap_or(0))))
                .and_then(|it| it.collect::<rusqlite::Result<Vec<_>>>())
        })
        .unwrap_or_default()
}

fn by_date(c: &Connection, a: &str, b: &str) -> rusqlite::Result<HashMap<String, i64>> {
    let mut st = c.prepare("SELECT log_date, SUM(seconds) FROM focus_log WHERE log_date >= ? AND log_date <= ? GROUP BY log_date")?;
    let m = st
        .query_map(params![a, b], |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<i64>>(1)?.unwrap_or(0))))?
        .collect::<rusqlite::Result<HashMap<_, _>>>()?;
    Ok(m)
}

impl Tracker {
    fn full_sync(&mut self, target: Date, current: &str, now_unix: f64) -> rusqlite::Result<()> {
        let c = &self.conn;
        let t_iso = target.iso();
        let yesterday = sum_i64(c, "SELECT SUM(seconds) FROM focus_log WHERE log_date = ?", &[&target.add(-1).iso()]);
        let monday = target.add(-target.weekday());
        let sunday = monday.add(6);
        let (mi, si) = (monday.iso(), sunday.iso());
        let fmt_md = |d: Date| {
            let (_, m, dd) = d.ymd();
            format!("{} {}", MONTHS[m as usize - 1], dd)
        };
        let week_range = format!("{} - {}", fmt_md(monday), fmt_md(sunday));
        let (days_count, total_week): (i64, i64) = c.query_row(
            "SELECT COUNT(DISTINCT log_date), SUM(seconds) FROM focus_log
                     WHERE log_date >= ? AND log_date <= ? AND seconds > 0",
            params![mi, si],
            |r| Ok((r.get::<_, Option<i64>>(0)?.unwrap_or(0), r.get::<_, Option<i64>>(1)?.unwrap_or(0))),
        )?;
        let average = if days_count > 0 { total_week.div_euclid(days_count) } else { 0 };
        let total = sum_i64(c, "SELECT SUM(seconds) FROM focus_log WHERE log_date = ?", &[&t_iso]);

        let apps: Vec<Value> = rows3(
            c,
            "SELECT app_class, COALESCE(app_title, app_class), SUM(seconds) as secs
                     FROM focus_log WHERE log_date = ? GROUP BY app_class ORDER BY secs DESC",
            &[&t_iso],
        )?
        .into_iter()
        .map(|(cls, name, secs)| json!({"class": cls, "name": name, "seconds": secs, "percent": pct(secs, total)}))
        .collect();
        let wk = rows3(
            c,
            "SELECT app_class, COALESCE(app_title, app_class), SUM(seconds) as secs FROM focus_log
                     WHERE log_date >= ? AND log_date <= ? GROUP BY app_class ORDER BY secs DESC LIMIT 50",
            &[&mi, &si],
        )?;
        let wk_total: i64 = wk.iter().map(|r| r.2).sum();
        let week_apps: Vec<Value> =
            wk.into_iter().map(|(cls, name, secs)| json!({"class": cls, "name": name, "seconds": secs, "percent": pct(secs, wk_total)})).collect();

        let week_map = by_date(c, &mi, &si)?;
        let week: Vec<Value> = (0..7)
            .map(|i| {
                let d = monday.add(i).iso();
                json!({"date": d, "day": DAYS[i as usize], "total": week_map.get(&d).copied().unwrap_or(0), "is_target": d == t_iso})
            })
            .collect();

        let (y, m, _) = target.ymd();
        let first = Date::from_ymd(y, m, 1);
        let n_days = target.days_in_month();
        let month_map = by_date(c, &first.iso(), &Date::from_ymd(y, m, n_days).iso())?;
        let mut month: Vec<Value> = (0..first.weekday()).map(|_| json!({"date": "", "total": -1, "is_target": false})).collect();
        for i in 1..=n_days {
            let d = Date::from_ymd(y, m, i).iso();
            month.push(json!({"date": d, "total": month_map.get(&d).copied().unwrap_or(0), "is_target": d == t_iso}));
        }

        let mut hourly = vec![0i64; 48];
        for (hr, secs) in pairs(c, "SELECT hour, SUM(seconds) FROM focus_hourly WHERE log_date = ? GROUP BY hour", &[&t_iso]) {
            if (0..=23).contains(&hr) {
                hourly[(hr * 2) as usize] += secs;
            }
        }
        for (idx, secs) in pairs(c, "SELECT interval_idx, SUM(seconds) FROM focus_intervals WHERE log_date = ? GROUP BY interval_idx", &[&t_iso]) {
            if (0..96).contains(&idx) {
                hourly[(idx / 2) as usize] += secs;
            }
        }

        let mut heat = vec![vec![0i64; 24]; 7];
        if let Ok(mut st) = c.prepare("SELECT log_date, hour, SUM(seconds) FROM focus_hourly WHERE log_date >= ? AND log_date <= ? GROUP BY log_date, hour") {
            if let Ok(rows) = st.query_map(params![mi, si], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, Option<i64>>(1)?.unwrap_or(-1), r.get::<_, Option<i64>>(2)?.unwrap_or(0)))
            }) {
                for (ld, hr, secs) in rows.flatten() {
                    if let Some(d) = Date::parse(&ld) {
                        if (0..=23).contains(&hr) {
                            heat[d.weekday() as usize][hr as usize] += secs;
                        }
                    }
                }
            }
        }

        let mut minute = vec![0i64; 1440];
        for (idx, secs) in pairs(
            c,
            "SELECT minute_idx, SUM(seconds) FROM focus_minutes WHERE log_date >= ? AND log_date <= ? GROUP BY minute_idx",
            &[&mi, &si],
        ) {
            if (0..1440).contains(&idx) {
                minute[idx as usize] += secs;
            }
        }
        // busiest hour of the week: the first 60-minute window with the largest sum (start < 1380, like the Python)
        let mut peak = "N/A".to_string();
        let mut win: i64 = minute[..60].iter().sum();
        let (mut max_sum, mut best) = (0i64, None);
        for i in 0..(1440 - 60) {
            if i > 0 {
                win += minute[i + 59] - minute[i - 1];
            }
            if win > max_sum && win > 0 {
                max_sum = win;
                best = Some((i, i + 60));
            }
        }
        if let Some((mut s, e)) = best {
            while s < e && minute[s] == 0 {
                s += 1;
            }
            let mut end = e - 1;
            while end > s && minute[end] == 0 {
                end -= 1;
            }
            peak = format!("{:02}:{:02} - {:02}:{:02}", s / 60, s % 60, end / 60, end % 60);
        }

        let known: Vec<Value> = rows3(
            c,
            "SELECT app_class, MAX(COALESCE(app_title, app_class)), SUM(seconds) FROM focus_log GROUP BY app_class ORDER BY SUM(seconds) DESC",
            &[],
        )
        .unwrap_or_default()
        .into_iter()
        .map(|(cls, name, _)| json!({"class": cls, "name": name}))
        .collect();

        let v = json!({
            "selected_date": t_iso, "total": total, "average": average,
            "week_range": week_range, "yesterday": yesterday, "current": current,
            "apps": apps, "week_apps": week_apps, "week": week, "month": month,
            "hourly": hourly, "week_heatmap": heat, "peak_usage_str": peak, "all_known_apps": known
        });
        self.cached = v.as_object().cloned();
        self.last_sync = now_unix;
        self.last_date = target;
        Ok(())
    }

    fn write_state(&self) {
        if let Some(c) = &self.cached {
            let _ = util::write_atomic(&self.state_file, Value::Object(c.clone()).to_string().as_bytes());
        }
    }

    fn fast_tick(&mut self, now: Now, class: &str, title: &str, secs: i64, write: bool) {
        if class.is_empty() || is_system(class) {
            if let Some(c) = self.cached.as_mut() {
                c.insert("current".into(), json!(title));
                if write {
                    self.write_state();
                }
            }
            return;
        }
        self.buffer.push(Entry { date: now.date.iso(), class: class.into(), title: title.into(), hour: now.hour, minute: now.minute, secs });
        if self.cached.is_none() || now.date != self.last_date || now.unix - self.last_sync > 60.0 {
            self.flush();
            if let Err(e) = self.full_sync(now.date, title, now.unix) {
                eprintln!("serp-wellbeing: {e}");
            }
        } else if let Some(d) = self.cached.as_mut() {
            let total = d["total"].as_i64().unwrap_or(0) + secs;
            d.insert("total".into(), json!(total));
            d.insert("current".into(), json!(title));
            if let Some(apps) = d.get_mut("apps").and_then(Value::as_array_mut) {
                match apps.iter_mut().find(|a| a["class"] == class) {
                    Some(a) => {
                        a["seconds"] = json!(a["seconds"].as_i64().unwrap_or(0) + secs);
                        a["name"] = json!(title);
                    }
                    None => apps.push(json!({"class": class, "name": title, "seconds": secs, "percent": 0})),
                }
                for a in apps.iter_mut() {
                    a["percent"] = pct(a["seconds"].as_i64().unwrap_or(0), total);
                }
                apps.sort_by(|a, b| b["seconds"].as_i64().cmp(&a["seconds"].as_i64()));
            }
            for key in ["week", "month"] {
                if let Some(arr) = d.get_mut(key).and_then(Value::as_array_mut) {
                    for w in arr.iter_mut().filter(|w| w["is_target"] == true) {
                        w["total"] = json!(w["total"].as_i64().unwrap_or(0) + secs);
                    }
                }
            }
            let idx = (now.hour * 2 + u32::from(now.minute >= 30)) as usize;
            if let Some(h) = d.get_mut("hourly").and_then(|h| h.get_mut(idx)) {
                *h = json!(h.as_i64().unwrap_or(0) + secs);
            }
            if let Some(h) = d.get_mut("week_heatmap").and_then(|h| h.get_mut(now.date.weekday() as usize)).and_then(|r| r.get_mut(now.hour as usize)) {
                *h = json!(h.as_i64().unwrap_or(0) + secs);
            }
        }
        if write {
            self.write_state();
        }
        if self.buffer.len() >= 15 {
            self.flush();
        }
    }

    fn flush(&mut self) {
        if self.buffer.is_empty() {
            return;
        }
        let mut logs: BTreeMap<(String, String), i64> = BTreeMap::new();
        let mut titles: HashMap<String, String> = HashMap::new();
        let mut hours: BTreeMap<(String, u32, String), i64> = BTreeMap::new();
        let mut intervals: BTreeMap<(String, u32, String), i64> = BTreeMap::new();
        let mut minutes: BTreeMap<(String, u32, String), i64> = BTreeMap::new();
        for e in &self.buffer {
            *logs.entry((e.date.clone(), e.class.clone())).or_default() += e.secs;
            titles.insert(e.class.clone(), e.title.clone());
            *hours.entry((e.date.clone(), e.hour, e.class.clone())).or_default() += e.secs;
            let m = e.hour * 60 + e.minute;
            *intervals.entry((e.date.clone(), m / 15, e.class.clone())).or_default() += e.secs;
            *minutes.entry((e.date.clone(), m, e.class.clone())).or_default() += e.secs;
        }
        let res = (|| -> rusqlite::Result<()> {
            let tx = self.conn.transaction()?;
            for ((d, cls), secs) in &logs {
                let t = &titles[cls];
                tx.execute(
                    "INSERT INTO focus_log (log_date, app_class, seconds, app_title) VALUES (?, ?, ?, ?)
                     ON CONFLICT(log_date, app_class) DO UPDATE SET seconds = seconds + ?, app_title = ?",
                    params![d, cls, secs, t, secs, t],
                )?;
            }
            for (table, col, map) in [("focus_hourly", "hour", &hours), ("focus_intervals", "interval_idx", &intervals), ("focus_minutes", "minute_idx", &minutes)] {
                let sql = format!(
                    "INSERT INTO {table} (log_date, {col}, app_class, seconds) VALUES (?, ?, ?, ?)
                     ON CONFLICT(log_date, {col}, app_class) DO UPDATE SET seconds = seconds + ?"
                );
                for ((d, k, cls), secs) in map.iter() {
                    tx.execute(&sql, params![d, k, cls, secs, secs])?;
                }
            }
            tx.commit()
        })();
        match res {
            Ok(()) => self.buffer.clear(),
            Err(e) => eprintln!("serp-wellbeing: flush failed: {e}"),
        }
    }
}

// ---------- paths ----------
struct Paths {
    run_dir: PathBuf,
    db: PathBuf,
    config: PathBuf,
    lock_marker: PathBuf,
}

fn paths() -> Paths {
    let run_dir = util::env_or("QS_RUN_FOCUSTIME", "/tmp/quickshell/focustime");
    let db_dir = util::env_or("QS_STATE_FOCUSTIME", util::home().join(".local/state/quickshell/focustime"));
    let _ = std::fs::create_dir_all(&run_dir);
    let _ = std::fs::create_dir_all(&db_dir);
    let db = db_dir.join("focustime.db");
    // one-time move from the old location (like the Python)
    let old_dir = util::home().join(".local/share/focustime");
    if !db.exists() && old_dir.join("focustime.db").exists() {
        if let Ok(rd) = std::fs::read_dir(&old_dir) {
            for e in rd.flatten() {
                let n = e.file_name().to_string_lossy().into_owned();
                if n.starts_with("focustime.db") {
                    let _ = std::fs::rename(e.path(), db_dir.join(&n));
                }
            }
        }
    }
    let qs_run = util::env_or("QS_RUN_DIR", util::runtime_dir().join("serpantinum"));
    let lock_dir = util::env_or("QS_RUN_LOCK", qs_run.join("lock"));
    Paths {
        run_dir,
        db,
        config: util::env_or("QS_SETTINGS", util::home().join(".config/serpantinum/settings.json")),
        lock_marker: lock_dir.join("locked"),
    }
}

fn tracker(p: &Paths) -> Tracker {
    let conn = match init_db(&p.db) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("serp-wellbeing: cannot open {}: {e}", p.db.display());
            std::process::exit(1);
        }
    };
    Tracker { conn, buffer: vec![], cached: None, last_sync: 0.0, last_date: Now::real().date, state_file: p.run_dir.join("focustime_state.json") }
}

fn notify(body: &str) {
    if let Ok(mut c) = std::process::Command::new("notify-send")
        .args(["-u", "critical", "Digital Wellbeing", body])
        .stdin(std::process::Stdio::null())
        .spawn()
    {
        std::thread::spawn(move || c.wait());
    }
}

/// The settings that matter here, re-read when settings.json changes.
#[derive(Default)]
struct Wellbeing {
    excluded: HashSet<String>,
    overall_limit: i64,
    app_limits: HashMap<String, i64>,
}

fn load_settings(path: &Path) -> Option<Wellbeing> {
    let v: Value = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    let w = &v["wellbeing"];
    let num = |x: &Value| x.as_i64().or_else(|| x.as_f64().map(|f| f as i64)).unwrap_or(0);
    Some(Wellbeing {
        excluded: w["excludedApps"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default(),
        overall_limit: num(&w["overallDailyLimit"]),
        app_limits: w["appLimits"].as_object().map(|m| m.iter().map(|(k, x)| (k.clone(), num(x))).collect()).unwrap_or_default(),
    })
}

fn daemon() {
    let p = paths();
    let _lock = match util::try_lock(p.run_dir.join("focus_daemon.lock")) {
        Ok(Some(f)) => f,
        _ => return, // another tracker (Rust or Python) is running
    };
    let mut tr = tracker(&p);
    let sig = util::signal_pipe(&[libc::SIGTERM, libc::SIGINT]).expect("signal pipe");

    let mut st = State::default();
    let mut es: Option<EventStream> = None;
    let mut retry_at = Instant::now();
    let (mut cur_class, mut cur_title) = ("Desktop".to_string(), "Desktop".to_string());

    let mut settings = Wellbeing::default();
    let mut settings_mtime = None;
    let (mut notified_overall, mut notified_apps) = (false, HashSet::<String>::new());
    let mut notif_date = Now::real().date;

    let mut last_mono = Instant::now();
    let mut next_tick = last_mono + Duration::from_secs(1);
    let mut acc = 0.0f64;
    let mut tick: u64 = 0;

    loop {
        if es.is_none() && Instant::now() >= retry_at {
            match EventStream::connect() {
                Ok(e) => {
                    es = Some(e);
                    st = State::default();
                }
                Err(_) => retry_at = Instant::now() + Duration::from_secs(2),
            }
        }
        let wait = next_tick.saturating_duration_since(Instant::now());
        let mut fds = vec![sig];
        if let Some(e) = &es {
            fds.push(e.fd());
        }
        let ready = util::poll_read(&fds, Some(wait)).unwrap_or_default();
        if ready.first() == Some(&true) {
            util::drain_signals(sig);
            if util::terminated() {
                tr.flush();
                return;
            }
        }
        if ready.get(1) == Some(&true) {
            let e = es.as_mut().unwrap();
            match e.read() {
                Ok(Some(evs)) => {
                    for ev in &evs {
                        st.apply(ev);
                    }
                    if st.have_windows {
                        (cur_class, cur_title) = active_window(st.focused_window());
                    }
                    if p.lock_marker.exists() {
                        (cur_class, cur_title) = ("Locked".into(), "Locked".into());
                    }
                }
                _ => {
                    es = None;
                    retry_at = Instant::now() + Duration::from_secs(2);
                }
            }
        }
        if Instant::now() < next_tick {
            continue;
        }
        // ---- one tick (≈ 1 s) ----
        let mono = Instant::now();
        let mut delta = mono.duration_since(last_mono).as_secs_f64();
        last_mono = mono;
        next_tick = mono + Duration::from_secs(1);
        if !(0.0..=3.0).contains(&delta) {
            delta = 1.0; // after a suspend: count one second, not the whole sleep
        }
        acc += delta;
        let secs = acc.floor() as i64;
        if secs < 1 {
            continue;
        }
        acc -= secs as f64;
        tick += 1;
        let now = Now::real();
        if now.date != notif_date {
            notified_overall = false;
            notified_apps.clear();
            notif_date = now.date;
        }
        if tick % 5 == 1 {
            let mt = std::fs::metadata(&p.config).and_then(|m| m.modified()).ok();
            if mt.is_some() && mt != settings_mtime {
                settings_mtime = mt;
                if let Some(s) = load_settings(&p.config) {
                    settings = s;
                }
            }
        }
        if p.lock_marker.exists() {
            (cur_class, cur_title) = ("Locked".into(), "Locked".into());
        } else if cur_class == "Locked" && st.have_windows {
            // unlocked: back to the focused window (the Python waited for the next niri event)
            (cur_class, cur_title) = active_window(st.focused_window());
        }
        let write = tick % 5 == 0;
        if !cur_class.is_empty() && !is_system(&cur_class) && !settings.excluded.contains(&cur_class) {
            tr.fast_tick(now, &cur_class, &cur_title, secs, write);
            if let Some(c) = &tr.cached {
                let total = c["total"].as_i64().unwrap_or(0);
                if settings.overall_limit > 0 && total >= settings.overall_limit && !notified_overall {
                    notify("Overall daily limit reached!");
                    notified_overall = true;
                }
                let app_secs = c["apps"]
                    .as_array()
                    .and_then(|a| a.iter().find(|a| a["class"] == cur_class.as_str()))
                    .and_then(|a| a["seconds"].as_i64())
                    .unwrap_or(0);
                let limit = settings.app_limits.get(&cur_class).copied().unwrap_or(0);
                if limit > 0 && app_secs >= limit && !notified_apps.contains(&cur_class) {
                    notify(&format!("{cur_title} daily limit reached!"));
                    notified_apps.insert(cur_class.clone());
                }
            }
        } else {
            tr.fast_tick(now, &cur_class, &cur_title, 0, write);
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("--dump-sync") => {
            let p = paths();
            let mut tr = tracker(&p);
            let d = args.get(2).and_then(|s| Date::parse(s)).unwrap_or_else(|| Now::real().date);
            tr.full_sync(d, args.get(3).map(String::as_str).unwrap_or("Desktop"), util::now_unix()).expect("full_sync");
            println!("{}", Value::Object(tr.cached.unwrap()));
        }
        Some("--replay") => {
            let p = paths();
            let mut tr = tracker(&p);
            let text = std::fs::read_to_string(args.get(2).expect("--replay FILE")).expect("read replay file");
            for line in text.lines().filter(|l| !l.is_empty()) {
                let f: Vec<&str> = line.split('\t').collect();
                tr.fast_tick(Now::at(f[0].parse().unwrap()), f[1], f[2], f[3].parse().unwrap(), f[4] == "1");
            }
            tr.flush();
            println!("{}", tr.cached.map(Value::Object).unwrap_or(Value::Null));
        }
        Some("--resolve") => {
            for line in std::io::stdin().lines().map_while(Result::ok) {
                let w: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
                let (c, n) = active_window(if w.is_null() { None } else { Some(&w) });
                println!("{}", json!([c, n]));
            }
        }
        _ => daemon(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates() {
        let d = Date::parse("2026-10-12").unwrap();
        assert_eq!(d.iso(), "2026-10-12");
        assert_eq!(d.weekday(), 0, "2026-10-12 is a Monday");
        assert_eq!(Date::parse("2024-02-10").unwrap().days_in_month(), 29);
        assert_eq!(Date::parse("2026-03-01").unwrap().add(-1).iso(), "2026-02-28");
        assert_eq!(Date::from_ymd(1970, 1, 1).0, 0);
    }

    #[test]
    fn python_rounding() {
        assert_eq!(round1(0.25), 0.2);
        assert_eq!(round1(0.35), 0.3);
        assert_eq!(round1(2.0 / 3.0 * 100.0), 66.7);
        assert_eq!(round1(12.45), 12.4); // 12.45 is 12.4499999… in binary
    }

    #[test]
    fn names() {
        assert_eq!(resolve_app_name("firefox", "(3) Inbox — Mozilla Firefox"), "Mozilla Firefox");
        assert_eq!(resolve_app_name("kitty", "zsh"), "zsh");
        assert_eq!(resolve_app_name("kitty", "a very long terminal title that keeps going"), "Kitty");
        assert_eq!(resolve_app_name("code", "file.rs - project - Visual Studio Code"), "Visual Studio Code");
        assert_eq!(resolve_app_name("", "x"), "Unknown");
    }
}
