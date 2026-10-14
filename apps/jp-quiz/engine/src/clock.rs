//! Local-time helpers matching Python's datetime.fromtimestamp(...) (microsecond rounding included).

fn split(ts: f64) -> i64 {
    // datetime.fromtimestamp: round to microseconds (half even); a carry moves to the next second
    let t = ts.trunc();
    let us = ((ts - t) * 1e6).round_ties_even();
    (if us >= 1e6 { t + 1.0 } else if us < 0.0 { t - 1.0 } else { t }) as i64
}

fn tm(ts: f64) -> libc::tm {
    let t = split(ts) as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&t, &mut tm) };
    tm
}

/// strftime("%Y-%m-%d") of the local date.
pub fn date_str(ts: f64) -> String {
    let t = tm(ts);
    format!("{:04}-{:02}-{:02}", t.tm_year + 1900, t.tm_mon + 1, t.tm_mday)
}

pub fn hour(ts: f64) -> i32 {
    tm(ts).tm_hour
}

/// Timestamp of the local midnight that starts ts's day.
pub fn local_midnight(ts: f64) -> f64 {
    let mut t = tm(ts);
    t.tm_hour = 0;
    t.tm_min = 0;
    t.tm_sec = 0;
    t.tm_isdst = -1;
    unsafe { libc::mktime(&mut t) as f64 }
}

/// A calendar date (days since 1970-01-01).
#[derive(Clone, Copy)]
pub struct Date(i64);

impl Date {
    pub fn of(ts: f64) -> Date {
        let t = tm(ts);
        Date::from_ymd((t.tm_year + 1900) as i64, (t.tm_mon + 1) as u32, t.tm_mday as u32)
    }
    pub fn from_ymd(y: i64, m: u32, d: u32) -> Date {
        let y = if m <= 2 { y - 1 } else { y };
        let era = y.div_euclid(400);
        let yoe = y - era * 400;
        let mp = (m as i64 + 9) % 12;
        let doy = (153 * mp + 2) / 5 + d as i64 - 1;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        Date(era * 146097 + doe - 719468)
    }
    pub fn iso(self) -> String {
        let z = self.0 + 719468;
        let era = z.div_euclid(146097);
        let doe = z - era * 146097;
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let d = doy - (153 * mp + 2) / 5 + 1;
        let m = if mp < 10 { mp + 3 } else { mp - 9 };
        let y = if m <= 2 { yoe + era * 400 + 1 } else { yoe + era * 400 };
        format!("{y:04}-{m:02}-{d:02}")
    }
    pub fn add(self, days: i64) -> Date {
        Date(self.0 + days)
    }
}
