//! Login / verification codes in mail ("Your code is 482913"), found without AI (port of codes.py).
//!
//! Every number-like token (4–8 digits, "123 456", "123-456", G-123456, 6–8 letter+digit codes,
//! 5-character Steam Guard style codes right after "Login Code") gets a score: near a code word it rises; things that look like money, dates, years, phone
//! numbers, order / tracking numbers fall. The best candidate above the threshold wins. Only mail
//! that talks about codes at all is considered. Slicing is by characters, like Python's.
use fancy_regex::Regex as FRegex;
use regex::Regex;
use std::sync::OnceLock;

struct Res {
    topic: FRegex,
    near: Regex,
    strong: Regex,
    bad_before: Regex,
    bad_after: Regex,
    promo: Regex,
    months: Regex,
    token: FRegex,
    code_is: Regex,
    is_your: Regex,
    phone_before: Regex,
    phone_after: Regex,
    dash6: Regex,
    letters_dash: Regex,
    clause: Regex,
}

/// Python's \w is str.isalnum() or '_' (no marks, no joiners): [\p{L}\p{N}_]. Rewrite \w and \b with it.
fn py_word(pat: &str) -> String {
    const W: &str = r"\p{L}\p{N}_";
    pat.replace(r"\b", &format!(r"(?:(?<=[{W}])(?![{W}])|(?<![{W}])(?=[{W}]))")).replace(r"\w", W)
}

fn res() -> &'static Res {
    static R: OnceLock<Res> = OnceLock::new();
    R.get_or_init(|| Res {
        topic: FRegex::new(&py_word(concat!(
            r"(?i)(verif|one[- ]?time|otp|passcode|pass code|security code|login code|sign[- ]?in|log[- ]?in|2fa|two[- ]factor|",
            r"authenticat|confirm|access code|\bcode\b|\bpin\b|token|",
            r"код|подтвержд|вход|одноразов|пароль|авториз|верификац|",
            r"código|codice|bestätigung|bestaetigung|anmelde|\bcodice\b|コード|認証|確認)"
        )))
        .unwrap(),
        near: Regex::new(concat!(
            r"(?i)(code|kod|pin|otp|passcode|password|verification|verify|confirm|one[- ]time|security|login|sign[- ]in|",
            r"код|пароль|подтвержд|вход|введите|enter|use|is|:)"
        ))
        .unwrap(),
        strong: Regex::new(r"(?i)(code|kod|otp|passcode|pin|код|c[óo]digo|codice|コード)").unwrap(),
        bad_before: Regex::new(concat!(
            r"(?i)(order|заказ|invoice|счёт|счет|tracking|трек|ticket|билет|booking|бронир|account|аккаунт|номер|№|#|id|ref|",
            r"phone|тел|call|\+|\$|€|£|₽|руб|usd|eur|rub|price|total|amount|сумм|итого|balance|баланс)[^\p{L}\p{N}_]{0,3}$"
        ))
        .unwrap(),
        bad_after: Regex::new(r"(?i)^[^\p{L}\p{N}_]{0,2}(₽|руб|rub|usd|eur|\$|€|%|px|mb|gb|kb|km|кг|kg|мин|min|sec|сек|г\.|year|год)").unwrap(),
        promo: Regex::new(r"(?i)(promo|coupon|discount|voucher|gift|скидк|промокод|купон|подар)").unwrap(),
        months: Regex::new(r"(?i)(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|янв|фев|мар|апр|мая|июн|июл|авг|сен|окт|ноя|дек)").unwrap(),
        token: FRegex::new(&py_word(concat!(
            r"(?<![\w/.:#@-])(",
            r"[A-Z]{1,3}-\d{4,8}",
            r"|\d{3}[ -]\d{3}",
            r"|\d{4,8}",
            r"|(?=[A-Z0-9]{6,8}\b)(?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])[A-Z0-9]{6,8}",
            r"|(?=[A-Z0-9]{5}\b)[A-Z0-9]{5}", // JH4CQ, FGHKT (Steam Guard): only right after "code"
            r")(?![\w/@]|\.\d|,\d|:\d)"
        )))
        .unwrap(),
        code_is: Regex::new(r"(?i)(code|код|пароль|pin|otp|c[óo]digo|codice)[\s\x1c-\x1f]*(is|es|ist|è|:|—|-|–)?[\s\x1c-\x1f]*:?[\s\x1c-\x1f]*$").unwrap(),
        is_your: Regex::new(r"(?i)^[\s\x1c-\x1f]*(is your|это ваш|— ваш|is the|ist dein|es tu)").unwrap(),
        phone_before: Regex::new(r"\+\d[\d ()-]{6,}$").unwrap(),
        phone_after: Regex::new(r"^[\d ()-]{4,}").unwrap(),
        dash6: Regex::new(r"^\d{3}[ -]\d{3}$").unwrap(),
        letters_dash: Regex::new(r"^[A-Z]{1,3}-\d{4,8}$").unwrap(),
        clause: Regex::new(r"[.!?\n]").unwrap(),
    })
}

/// Character-indexed view of a string (Python slicing).
struct Chars<'a> {
    s: &'a str,
    idx: Vec<usize>, // byte offset of each char, plus len
}

impl<'a> Chars<'a> {
    fn new(s: &'a str) -> Chars<'a> {
        let mut idx: Vec<usize> = s.char_indices().map(|(i, _)| i).collect();
        idx.push(s.len());
        Chars { s, idx }
    }
    fn len(&self) -> usize {
        self.idx.len() - 1
    }
    /// s[a:b] with Python's clamping
    fn slice(&self, a: isize, b: isize) -> &'a str {
        let n = self.len() as isize;
        let fix = |x: isize| if x < 0 { (n + x).max(0) } else { x.min(n) } as usize;
        let (a, b) = (fix(a), fix(b));
        if a >= b {
            return "";
        }
        &self.s[self.idx[a]..self.idx[b]]
    }
    fn char_at_byte(&self, byte: usize) -> usize {
        self.idx.partition_point(|&x| x < byte)
    }
}

fn tail(s: &str, n: usize) -> &str {
    let c = Chars::new(s);
    c.slice(-(n as isize), c.len() as isize)
}

pub fn score(src: &str, a: usize, b: usize, tok: &str) -> i64 {
    let r = res();
    let c = Chars::new(src);
    let (ai, bi) = (a as isize, b as isize);
    let before = c.slice((ai - 60).max(0), ai);
    let after = c.slice(bi, bi + 30);
    let near_before = c.slice((ai - 25).max(0), ai);
    let mut s = 0i64;
    // tokens only hold \d digits, A-Z, '-' and ' ': re.sub(r'\D', '', tok) and tok.isdigit()
    let is_sep = |ch: char| ch.is_ascii_alphabetic() || ch == '-' || ch == ' ';
    let digits: String = tok.chars().filter(|&ch| !is_sep(ch)).collect();
    let all_digits = !tok.is_empty() && !tok.chars().any(is_sep);
    if all_digits {
        let n = tok.chars().count();
        s += match n {
            4 => 1,
            5 => 2,
            6 => 3,
            7 => 2,
            8 => 2,
            _ => 0,
        };
        if n == 4 {
            if let Ok(y) = tok.parse::<i64>() {
                if (1900..=2100).contains(&y) {
                    s -= 4; // a year
                }
            }
        }
    } else if r.dash6.is_match(tok) {
        s += 3;
    } else if r.letters_dash.is_match(tok) {
        s += 4;
    } else if tok.chars().count() == 5 {
        s += 1; // 5 letters/digits: only as "Login Code JH4CQ" / "code: FGHKT"
        if !r.code_is.is_match(before) {
            s -= 6;
        }
    } else {
        s += 1; // letter+digit codes need strong context
        if !r.strong.is_match(tail(before, 40)) {
            s -= 4;
        }
    }
    if r.strong.is_match(before) {
        s += 4;
    } else if r.near.is_match(near_before) {
        s += 1;
    }
    if r.code_is.is_match(before) {
        s += 3;
    }
    if r.is_your.is_match(after) {
        s += 4;
    }
    if r.bad_before.is_match(tail(before, 25)) {
        let clause = r.clause.split(before).last().unwrap_or("");
        s -= if r.strong.is_match(clause) { 2 } else { 6 };
    }
    if r.promo.is_match(before) {
        s -= 8;
    }
    if r.bad_after.is_match(after) {
        s -= 6;
    }
    if r.months.is_match(c.slice((ai - 12).max(0), bi + 12)) {
        s -= 3;
    }
    if r.phone_before.is_match(tail(before, 20)) || r.phone_after.is_match(after) {
        s -= 6;
    }
    let mut uniq: Vec<char> = digits.chars().collect();
    uniq.sort();
    uniq.dedup();
    if uniq.len() == 1 && digits.chars().count() >= 4 {
        s -= 2;
    }
    s
}

/// -> (code, score) or None
pub fn find(subject: &str, text: &str) -> Option<(String, i64)> {
    let r = res();
    let tc = Chars::new(text);
    let text = tc.slice(0, 6000);
    let head3000 = Chars::new(text).slice(0, 3000);
    if !r.topic.is_match(subject).unwrap_or(false) && !r.topic.is_match(head3000).unwrap_or(false) {
        return None;
    }
    let mut best: Option<(i64, String)> = None;
    for (src, base) in [(subject, 2i64), (text, 0)] {
        let c = Chars::new(src);
        for m in r.token.captures_iter(src).flatten() {
            let g = m.get(1).unwrap();
            let (a, b) = (c.char_at_byte(g.start()), c.char_at_byte(g.end()));
            let tok = g.as_str();
            let s = score(src, a, b, tok) + base;
            if best.as_ref().is_none_or(|(bs, _)| s > *bs) {
                best = Some((s, tok.to_string()));
            }
        }
    }
    let (s, code) = best?;
    if s < 5 {
        return None;
    }
    let code = if r.dash6.is_match(&code) {
        let ch: Vec<char> = code.chars().collect();
        ch[..3].iter().chain(ch[4..].iter()).collect()
    } else {
        code
    };
    Some((code, s))
}

#[cfg(test)]
mod tests {
    use super::find;

    #[test]
    fn codes() {
        assert_eq!(find("Sign in to Telegram", "Your login code: 62519. Do not give this code to anyone.").map(|c| c.0), Some("62519".into()));
        assert_eq!(find("G-482913 is your Google verification code", "").map(|c| c.0), Some("G-482913".into()));
        assert_eq!(find("Ваш заказ 123456", "Спасибо за заказ").map(|c| c.0), None);
        assert_eq!(find("Код подтверждения", "Код для входа в аккаунт: 384 920").map(|c| c.0), Some("384920".into()));
        let steam = "Here is the Steam\r\nGuard code you need to access your account:\n\nRequest made from\r\nGermany\r\n\r\nLogin Code\r\nJH4CQ\r\n";
        assert_eq!(find("Your Steam account: Access from new computer", steam).map(|c| c.0), Some("JH4CQ".into()));
        assert_eq!(find("Steam Guard code", "Login Code\r\nFGHKT\r\n").map(|c| c.0), Some("FGHKT".into()));
        assert_eq!(find("Your verification code", "Your code is below. GUARD it well. EARLY access starts today.").map(|c| c.0), None);
    }
}
