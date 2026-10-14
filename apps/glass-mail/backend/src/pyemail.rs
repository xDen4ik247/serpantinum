//! Ports of CPython 3.14's email._parseaddr / email.utils pieces the backend relies on:
//! parsedate_to_datetime(...).timestamp(), getaddresses(strict=True) (AddrlistClass) and formataddr.
//! Working on chars, like Python's str indexing.

const MONTHS: [&str; 24] = [
    "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec", "january", "february", "march", "april", "may", "june",
    "july", "august", "september", "october", "november", "december",
];
const DAYS: [&str; 7] = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];

fn tz_named(t: &str) -> Option<i64> {
    Some(match t {
        "UT" | "UTC" | "GMT" | "Z" => 0,
        "AST" => -400,
        "ADT" => -300,
        "EST" => -500,
        "EDT" => -400,
        "CST" => -600,
        "CDT" => -500,
        "MST" => -700,
        "MDT" => -600,
        "PST" => -800,
        "PDT" => -700,
        _ => return None,
    })
}

/// int(s) for the strings _parsedate_tz feeds it (surrounding whitespace, a sign, '_' between digits)
fn py_int(s: &str) -> Option<i64> {
    let t = s.trim_matches(crate::htmlparser::py_space);
    let (neg, body) = match t.strip_prefix('-') {
        Some(b) => (true, b),
        None => (false, t.strip_prefix('+').unwrap_or(t)),
    };
    if body.is_empty() || body.starts_with('_') || body.ends_with('_') || body.contains("__") {
        return None;
    }
    let mut v: i64 = 0;
    for c in body.chars() {
        if c == '_' {
            continue;
        }
        let d = c.to_digit(10)? as i64;
        v = v.checked_mul(10)?.checked_add(d)?;
    }
    Some(if neg { -v } else { v })
}

fn first_char_digit(s: &str) -> bool {
    s.chars().next().is_some_and(|c| c.is_ascii_digit() || (c.is_numeric() && c.to_digit(10).is_some()))
}

/// _parsedate_tz -> (y, m, d, hh, mm, ss, tz offset seconds or None)
pub fn parsedate_tz(data: &str) -> Option<(i64, i64, i64, i64, i64, i64, Option<i64>)> {
    let mut d: Vec<String> = data.split_whitespace().map(String::from).collect();
    // Python's str.split() also splits on \x1c-\x1f
    d = d.iter().flat_map(|w| w.split(|c: char| ('\x1c'..='\x1f').contains(&c)).filter(|x| !x.is_empty()).map(String::from).collect::<Vec<_>>()).collect();
    if d.is_empty() {
        return None;
    }
    if d[0].ends_with(',') || DAYS.contains(&d[0].to_lowercase().as_str()) {
        d.remove(0);
    } else if let Some(i) = d[0].rfind(',') {
        d[0] = d[0][i + 1..].to_string();
    }
    if d.len() == 3 {
        let stuff: Vec<String> = d[0].split('-').map(String::from).collect();
        if stuff.len() == 3 {
            let rest = d[1..].to_vec();
            d = stuff;
            d.extend(rest);
        }
    }
    if d.len() == 4 {
        let s = d[3].clone();
        let i = s.find('+').or_else(|| s.find('-'));
        match i {
            Some(i) if i > 0 => {
                d.truncate(3);
                d.push(s[..i].to_string());
                d.push(s[i..].to_string());
            }
            _ => d.push(String::new()),
        }
    }
    if d.len() < 5 {
        return None;
    }
    d.truncate(5);
    let (mut dd, mut mm, mut yy, mut tm, mut tz) = (d[0].clone(), d[1].clone(), d[2].clone(), d[3].clone(), d[4].clone());
    if dd.is_empty() || mm.is_empty() || yy.is_empty() {
        return None;
    }
    mm = mm.to_lowercase();
    if !MONTHS.contains(&mm.as_str()) {
        let t = dd.to_lowercase();
        dd = mm;
        mm = t;
        if !MONTHS.contains(&mm.as_str()) {
            return None;
        }
    }
    let mut month = MONTHS.iter().position(|x| *x == mm).unwrap() as i64 + 1;
    if month > 12 {
        month -= 12;
    }
    if dd.ends_with(',') {
        dd.pop();
    }
    if let Some(i) = yy.find(':') {
        if i > 0 {
            std::mem::swap(&mut yy, &mut tm);
        }
    }
    if yy.ends_with(',') {
        yy.pop();
        if yy.is_empty() {
            return None;
        }
    }
    if !first_char_digit(&yy) {
        std::mem::swap(&mut yy, &mut tz);
    }
    if tm.ends_with(',') {
        tm.pop();
    }
    let parts: Vec<String> = tm.split(':').map(String::from).collect();
    let (thh, tmm, tss) = match parts.len() {
        2 => (parts[0].clone(), parts[1].clone(), "0".to_string()),
        3 => (parts[0].clone(), parts[1].clone(), parts[2].clone()),
        1 if parts[0].contains('.') => {
            let p: Vec<String> = parts[0].split('.').map(String::from).collect();
            match p.len() {
                2 => (p[0].clone(), p[1].clone(), "0".to_string()),
                3 => (p[0].clone(), p[1].clone(), p[2].clone()),
                _ => return None,
            }
        }
        _ => return None,
    };
    let mut y = py_int(&yy)?;
    let day = py_int(&dd)?;
    let (h, mi, s) = (py_int(&thh)?, py_int(&tmm)?, py_int(&tss)?);
    if y < 100 {
        y += if y > 68 { 1900 } else { 2000 };
    }
    let tzu = tz.to_uppercase();
    let mut off: Option<i64> = tz_named(&tzu);
    if off.is_none() {
        off = py_int(&tzu);
        if off == Some(0) && tzu.starts_with('-') {
            off = None;
        }
    }
    if let Some(o) = off.filter(|o| *o != 0) {
        let (sign, a) = if o < 0 { (-1, -o) } else { (1, o) };
        off = Some(sign * ((a / 100) * 3600 + (a % 100) * 60));
    }
    Some((y, month, day, h, mi, s, off))
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

fn days_in_month(y: i64, m: i64) -> i64 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        _ => {
            if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 {
                29
            } else {
                28
            }
        }
    }
}

/// parsedate_to_datetime(v).timestamp(), 0 when it can't be read (like mime.parse_date)
pub fn date_timestamp(v: &str) -> f64 {
    let Some((y, m, d, h, mi, s, off)) = parsedate_tz(v) else { return 0.0 };
    if !(1..=9999).contains(&y) || !(1..=12).contains(&m) || d < 1 || d > days_in_month(y, m) || !(0..24).contains(&h) || !(0..60).contains(&mi) || !(0..60).contains(&s) {
        return 0.0;
    }
    match off {
        Some(o) => {
            if o.abs() >= 86400 {
                return 0.0; // datetime.timezone rejects offsets of a day or more
            }
            (days_from_civil(y, m, d) * 86400 + h * 3600 + mi * 60 + s - o) as f64
        }
        None => {
            let mut tm: libc::tm = unsafe { std::mem::zeroed() };
            tm.tm_year = (y - 1900) as i32;
            tm.tm_mon = (m - 1) as i32;
            tm.tm_mday = d as i32;
            tm.tm_hour = h as i32;
            tm.tm_min = mi as i32;
            tm.tm_sec = s as i32;
            tm.tm_isdst = -1;
            unsafe { libc::mktime(&mut tm) as f64 }
        }
    }
}

// ---------------------------------------------------------------- addresses

struct Addrlist {
    f: Vec<char>,
    pos: usize,
    commentlist: Vec<String>,
}

const SPECIALS: &str = "()<>@,:;.\"[]";
const LWS: &str = " \t";

fn atomend(c: char) -> bool {
    SPECIALS.contains(c) || LWS.contains(c) || c == '\r' || c == '\n'
}

fn phraseend(c: char) -> bool {
    c != '.' && atomend(c)
}

fn qquote(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

impl Addrlist {
    fn at(&self) -> char {
        self.f[self.pos]
    }
    fn more(&self) -> bool {
        self.pos < self.f.len()
    }

    fn gotonext(&mut self) -> String {
        let mut ws = String::new();
        while self.more() {
            let c = self.at();
            if LWS.contains(c) || c == '\n' || c == '\r' {
                if c != '\n' && c != '\r' {
                    ws.push(c);
                }
                self.pos += 1;
            } else if c == '(' {
                let cm = self.getcomment();
                self.commentlist.push(cm);
            } else {
                break;
            }
        }
        ws
    }

    fn getaddrlist(&mut self) -> Vec<(String, String)> {
        let mut result = vec![];
        while self.more() {
            let ad = self.getaddress();
            if ad.is_empty() {
                result.push((String::new(), String::new()));
            } else {
                result.extend(ad);
            }
        }
        result
    }

    fn getaddress(&mut self) -> Vec<(String, String)> {
        self.commentlist.clear();
        self.gotonext();
        let oldpos = self.pos;
        let oldcl = self.commentlist.clone();
        let plist = self.getphraselist();
        self.gotonext();
        let mut ret = vec![];
        if !self.more() {
            if let Some(p) = plist.first() {
                ret = vec![(self.commentlist.join(" "), p.clone())];
            }
        } else if self.at() == '.' || self.at() == '@' {
            self.pos = oldpos;
            self.commentlist = oldcl;
            let spec = self.getaddrspec();
            ret = vec![(self.commentlist.join(" "), spec)];
        } else if self.at() == ':' {
            let n = self.f.len();
            self.pos += 1;
            while self.more() {
                self.gotonext();
                if self.pos < n && self.at() == ';' {
                    self.pos += 1;
                    break;
                }
                let more = self.getaddress();
                ret.extend(more);
            }
        } else if self.at() == '<' {
            let route = self.getrouteaddr();
            if !self.commentlist.is_empty() {
                ret = vec![(format!("{} ({})", plist.join(" "), self.commentlist.join(" ")), route)];
            } else {
                ret = vec![(plist.join(" "), route)];
            }
        } else if let Some(p) = plist.first() {
            ret = vec![(self.commentlist.join(" "), p.clone())];
        } else if SPECIALS.contains(self.at()) {
            self.pos += 1;
        }
        self.gotonext();
        if self.more() && self.at() == ',' {
            self.pos += 1;
        }
        ret
    }

    fn getrouteaddr(&mut self) -> String {
        if self.at() != '<' {
            return String::new();
        }
        let mut expectroute = false;
        self.pos += 1;
        self.gotonext();
        let mut adlist = String::new();
        while self.more() {
            if expectroute {
                self.getdomain();
                expectroute = false;
            } else if self.at() == '>' {
                self.pos += 1;
                break;
            } else if self.at() == '@' {
                self.pos += 1;
                expectroute = true;
            } else if self.at() == ':' {
                self.pos += 1;
            } else {
                adlist = self.getaddrspec();
                self.pos += 1;
                break;
            }
            self.gotonext();
        }
        adlist
    }

    fn getaddrspec(&mut self) -> String {
        let mut aslist: Vec<String> = vec![];
        self.gotonext();
        while self.more() {
            let mut preserve_ws = true;
            let c = self.at();
            if c == '.' {
                if aslist.last().is_some_and(|l| l.trim().is_empty()) {
                    aslist.pop();
                }
                aslist.push(".".into());
                self.pos += 1;
                preserve_ws = false;
            } else if c == '"' {
                let q = self.getquote();
                aslist.push(format!("\"{}\"", qquote(&q)));
            } else if atomend(c) {
                if aslist.last().is_some_and(|l| l.trim().is_empty()) {
                    aslist.pop();
                }
                break;
            } else {
                let a = self.getatom(atomend);
                aslist.push(a);
            }
            let ws = self.gotonext();
            if preserve_ws && !ws.is_empty() {
                aslist.push(ws);
            }
        }
        if !self.more() || self.at() != '@' {
            return aslist.concat();
        }
        aslist.push("@".into());
        self.pos += 1;
        self.gotonext();
        let domain = self.getdomain();
        if domain.is_empty() {
            return String::new();
        }
        aslist.concat() + &domain
    }

    fn getdomain(&mut self) -> String {
        let mut sd: Vec<String> = vec![];
        while self.more() {
            let c = self.at();
            if LWS.contains(c) {
                self.pos += 1;
            } else if c == '(' {
                let cm = self.getcomment();
                self.commentlist.push(cm);
            } else if c == '[' {
                let d = self.getdelimited('[', "]\r", false);
                sd.push(format!("[{d}]"));
            } else if c == '.' {
                self.pos += 1;
                sd.push(".".into());
            } else if c == '@' {
                return String::new();
            } else if atomend(c) {
                break;
            } else {
                let a = self.getatom(atomend);
                sd.push(a);
            }
        }
        sd.concat()
    }

    fn getdelimited(&mut self, begin: char, ends: &str, allow_comments: bool) -> String {
        if self.at() != begin {
            return String::new();
        }
        let mut s = String::new();
        let mut quote = false;
        self.pos += 1;
        while self.more() {
            let c = self.at();
            if quote {
                s.push(c);
                quote = false;
            } else if ends.contains(c) {
                self.pos += 1;
                break;
            } else if allow_comments && c == '(' {
                let cm = self.getcomment();
                s.push_str(&cm);
                continue;
            } else if c == '\\' {
                quote = true;
            } else {
                s.push(c);
            }
            self.pos += 1;
        }
        s
    }

    fn getquote(&mut self) -> String {
        self.getdelimited('"', "\"\r", false)
    }

    fn getcomment(&mut self) -> String {
        self.getdelimited('(', ")\r", true)
    }

    fn getatom(&mut self, end: fn(char) -> bool) -> String {
        let mut s = String::new();
        while self.more() {
            let c = self.at();
            if end(c) {
                break;
            }
            s.push(c);
            self.pos += 1;
        }
        s
    }

    fn getphraselist(&mut self) -> Vec<String> {
        let mut plist = vec![];
        while self.more() {
            let c = self.at();
            if LWS.contains(c) || c == '\r' || c == '\n' {
                self.pos += 1;
            } else if c == '"' {
                let q = self.getquote();
                plist.push(q);
            } else if c == '(' {
                let cm = self.getcomment();
                self.commentlist.push(cm);
            } else if phraseend(c) {
                break;
            } else {
                let a = self.getatom(phraseend);
                plist.push(a);
            }
        }
        plist
    }
}

/// (pos, char-or-escaped) pairs like email.utils._iter_escaped_chars
fn iter_escaped(addr: &[char]) -> Vec<(usize, String)> {
    let mut out = vec![];
    let mut escape = false;
    let mut last = 0;
    for (pos, &ch) in addr.iter().enumerate() {
        last = pos;
        if escape {
            out.push((pos, format!("\\{ch}")));
            escape = false;
        } else if ch == '\\' {
            escape = true;
        } else {
            out.push((pos, ch.to_string()));
        }
    }
    if escape {
        out.push((last, "\\".into()));
    }
    out
}

fn strip_quoted_realnames(addr: &str) -> String {
    if !addr.contains('"') {
        return addr.to_string();
    }
    let chars: Vec<char> = addr.chars().collect();
    let mut start = 0;
    let mut open: Option<usize> = None;
    let mut result = String::new();
    for (pos, ch) in iter_escaped(&chars) {
        if ch == "\"" {
            match open {
                None => open = Some(pos),
                Some(o) => {
                    if start != o {
                        result.extend(&chars[start..o]);
                    }
                    start = pos + 1;
                    open = None;
                }
            }
        }
    }
    if start < chars.len() {
        result.extend(&chars[start..]);
    }
    result
}

fn check_parenthesis(addr: &str) -> bool {
    let a: Vec<char> = strip_quoted_realnames(addr).chars().collect();
    let mut opens = 0i64;
    for (_, ch) in iter_escaped(&a) {
        if ch == "(" {
            opens += 1;
        } else if ch == ")" {
            opens -= 1;
            if opens < 0 {
                return false;
            }
        }
    }
    opens == 0
}

/// email.utils.getaddresses(fieldvalues) (strict)
pub fn getaddresses(values: &[&str]) -> Vec<(String, String)> {
    let vals: Vec<String> = values.iter().map(|v| if check_parenthesis(v) { v.to_string() } else { "('', '')".to_string() }).collect();
    let joined = vals.join(", ");
    let mut p = Addrlist { f: joined.chars().collect(), pos: 0, commentlist: vec![] };
    let list = if joined.is_empty() { vec![] } else { p.getaddrlist() };
    let result: Vec<(String, String)> = list.into_iter().map(|(n, a)| if a.contains('[') { (String::new(), String::new()) } else { (n, a) }).collect();
    let n: usize = vals.iter().map(|v| 1 + strip_quoted_realnames(v).matches(',').count()).sum();
    if result.len() != n {
        return vec![(String::new(), String::new())];
    }
    result
}

/// email.utils.formataddr((name, addr)) (non-ASCII names as one RFC 2047 b-word)
pub fn formataddr(name: &str, addr: &str) -> String {
    if name.is_empty() {
        return addr.to_string();
    }
    if !name.is_ascii() {
        use base64::Engine as _;
        return format!("=?utf-8?b?{}?= <{addr}>", base64::engine::general_purpose::STANDARD.encode(name));
    }
    let quotes = if name.chars().any(|c| "][\\()<>@,:;\".".contains(c)) { "\"" } else { "" };
    let esc = name.replace('\\', "\\\\").replace('"', "\\\"");
    format!("{quotes}{esc}{quotes} <{addr}>")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn addresses() {
        assert_eq!(getaddresses(&["u"]), vec![("".into(), "u".into())]);
        assert_eq!(getaddresses(&["A <a@x.org>, b@y.org"]), vec![("A".into(), "a@x.org".into()), ("".into(), "b@y.org".into())]);
        assert_eq!(getaddresses(&["Smith, John <j@x>"]), vec![("".into(), "Smith".into()), ("John".into(), "j@x".into())]);
        assert_eq!(getaddresses(&["\"Smith, J\" <j@s.example>"]), vec![("Smith, J".into(), "j@s.example".into())]);
    }
    #[test]
    fn dates() {
        assert_eq!(date_timestamp("Mon, 12 Oct 2026 10:00:00 +0300"), 1791788400.0);
        assert_eq!(date_timestamp("Mon, 12 Oct 2026 07:00:00 GMT"), 1791788400.0);
        assert_eq!(date_timestamp("garbage"), 0.0);
    }
}
