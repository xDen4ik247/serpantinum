//! CPython 3.14's html.parser.HTMLParser (convert_charrefs=True, scripting=False) and html.unescape,
//! ported so the reader view sees exactly the same tag / data events as the Python backend did.
//! The tokenizer regexes (tagfind_tolerant, attrfind_tolerant, locatetagend…) are greedy and need no
//! backtracking beyond "an optional value that doesn't match is skipped", so they are hand-written
//! scanners here; positions are byte offsets (every delimiter is ASCII).
use crate::entities::{HTML5, INVALID_CHARREFS, INVALID_CODEPOINTS};
use regex::Regex;
use std::borrow::Cow;
use std::sync::OnceLock;

pub trait Handler {
    fn start(&mut self, tag: &str, attrs: &[(String, Option<String>)]);
    fn end(&mut self, tag: &str);
    fn data(&mut self, data: &str);
    fn startend(&mut self, tag: &str, attrs: &[(String, Option<String>)]) {
        self.start(tag, attrs);
        self.end(tag);
    }
}

// ---------------------------------------------------------------- Python string helpers

/// str.isspace() for one char (Unicode White_Space plus the ASCII separators \x1c-\x1f).
pub fn py_space(c: char) -> bool {
    c.is_whitespace() || ('\x1c'..='\x1f').contains(&c)
}

pub fn py_strip(s: &str) -> &str {
    s.trim_matches(py_space)
}

/// html.escape(s, quote)
pub fn escape(s: &str, quote: bool) -> String {
    let mut o = String::with_capacity(s.len() + 8);
    for c in s.chars() {
        match c {
            '&' => o.push_str("&amp;"),
            '<' => o.push_str("&lt;"),
            '>' => o.push_str("&gt;"),
            '"' if quote => o.push_str("&quot;"),
            '\'' if quote => o.push_str("&#x27;"),
            c => o.push(c),
        }
    }
    o
}

fn html5(name: &str) -> Option<&'static str> {
    HTML5.binary_search_by(|(k, _)| (*k).cmp(name)).ok().map(|i| HTML5[i].1)
}

fn replace_charref(s: &str) -> String {
    if let Some(num) = s.strip_prefix('#') {
        let num = num.trim_end_matches(';');
        let n: Option<u64> = if let Some(h) = num.strip_prefix(['x', 'X']) { u64::from_str_radix(h, 16).ok() } else { num.parse().ok() };
        let n = n.unwrap_or(u64::MAX); // overflow: far beyond 0x10FFFF
        if n <= u32::MAX as u64 {
            if let Ok(i) = INVALID_CHARREFS.binary_search_by(|(k, _)| k.cmp(&(n as u32))) {
                return INVALID_CHARREFS[i].1.to_string();
            }
        }
        if (0xD800..=0xDFFF).contains(&n) || n > 0x10FFFF {
            return "\u{FFFD}".into();
        }
        if INVALID_CODEPOINTS.binary_search(&(n as u32)).is_ok() {
            return String::new();
        }
        return char::from_u32(n as u32).map(String::from).unwrap_or_else(|| "\u{FFFD}".into());
    }
    if let Some(v) = html5(s) {
        return v.to_string();
    }
    // the longest prefix that is a name (as the standard defines it)
    let idx: Vec<usize> = s.char_indices().map(|(i, _)| i).collect();
    for x in (2..idx.len()).rev() {
        if let Some(v) = html5(&s[..idx[x]]) {
            return format!("{v}{}", &s[idx[x]..]);
        }
    }
    format!("&{s}")
}

/// html.unescape
pub fn unescape(s: &str) -> Cow<'_, str> {
    if !s.contains('&') {
        return Cow::Borrowed(s);
    }
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r"&(#[0-9]+;?|#[xX][0-9a-fA-F]+;?|[^\t\n\x0c <&#;]{1,32};?)").unwrap());
    Cow::Owned(re.replace_all(s, |c: &regex::Captures| replace_charref(&c[1])).into_owned())
}

/// html.parser._unescape_attrvalue
fn unescape_attr(s: &str) -> String {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*)[;=]?").unwrap());
    re.replace_all(s, |c: &regex::Captures| {
        let r = &c[0];
        if r.starts_with("&#") || (!r.ends_with('=') && html5(&r[1..]).is_some()) {
            unescape(r).into_owned()
        } else {
            r.to_string()
        }
    })
    .into_owned()
}

// ---------------------------------------------------------------- scanners

fn ws(b: u8) -> bool {
    matches!(b, b'\t' | b'\n' | b'\r' | 0x0c | b' ')
}

/// [^\t\n\r\f />]
fn name_char(b: u8) -> bool {
    !ws(b) && b != b'/' && b != b'>'
}

/// tagfind_tolerant at p: ([a-zA-Z][^\t\n\r\f />]*)(?:[\t\n\r\f ]|/(?!>))* -> (name end, match end)
fn tagfind(s: &[u8], p: usize) -> Option<(usize, usize)> {
    if p >= s.len() || !s[p].is_ascii_alphabetic() {
        return None;
    }
    let mut k = p + 1;
    while k < s.len() && name_char(s[k]) {
        k += 1;
    }
    let name_end = k;
    loop {
        if k < s.len() && ws(s[k]) {
            k += 1;
        } else if k < s.len() && s[k] == b'/' && s.get(k + 1) != Some(&b'>') {
            k += 1;
        } else {
            break;
        }
    }
    Some((name_end, k))
}

/// The optional `\s*=\s*(value)` after an attribute name; returns (value start, value end, end) when it matches.
fn attr_value(s: &[u8], p: usize) -> Option<(usize, usize, usize)> {
    let mut k = p;
    while k < s.len() && ws(s[k]) {
        k += 1;
    }
    if s.get(k) != Some(&b'=') {
        return None;
    }
    k += 1;
    while k < s.len() && ws(s[k]) {
        k += 1;
    }
    match s.get(k) {
        Some(&q @ (b'\'' | b'"')) => {
            let close = s[k + 1..].iter().position(|&b| b == q)?;
            let end = k + 1 + close + 1;
            Some((k, end, end))
        }
        _ => {
            let mut e = k;
            while e < s.len() && s[e] != b'>' && !ws(s[e]) {
                e += 1;
            }
            Some((k, e, e))
        }
    }
}

/// lookbehind ['"\t\n\r\f /] then [^\t\n\r\f />][^\t\n\r\f /=>]* -> name end
fn attr_name(s: &[u8], p: usize) -> Option<usize> {
    if p == 0 || p >= s.len() {
        return None;
    }
    let prev = s[p - 1];
    if !(prev == b'\'' || prev == b'"' || ws(prev) || prev == b'/') {
        return None;
    }
    if !name_char(s[p]) {
        return None;
    }
    let mut k = p + 1;
    while k < s.len() && name_char(s[k]) && s[k] != b'=' {
        k += 1;
    }
    Some(k)
}

/// locatetagend at p -> match end
fn locatetagend(s: &[u8], p: usize) -> usize {
    let mut k = p;
    // tag name (always present: callers checked [a-zA-Z])
    if k < s.len() && s[k].is_ascii_alphabetic() {
        k += 1;
        while k < s.len() && name_char(s[k]) {
            k += 1;
        }
    }
    while k < s.len() && (ws(s[k]) || s[k] == b'/') {
        k += 1;
    }
    while let Some(ne) = attr_name(s, k) {
        k = ne;
        if let Some((_, _, e)) = attr_value(s, k) {
            k = e;
        }
        while k < s.len() && (ws(s[k]) || s[k] == b'/') {
            k += 1;
        }
    }
    if s.get(k) == Some(&b'>') {
        k += 1;
    }
    k
}

/// attrfind_tolerant at p -> (name, value-or-None, end)
fn attrfind(src: &str, p: usize) -> Option<(String, Option<String>, usize)> {
    let s = src.as_bytes();
    let ne = attr_name(s, p)?;
    let name = &src[p..ne];
    let mut k = ne;
    let mut value = None;
    if let Some((vs, ve, e)) = attr_value(s, k) {
        value = Some(&src[vs..ve]);
        k = e;
    }
    loop {
        if k < s.len() && ws(s[k]) {
            k += 1;
        } else if k < s.len() && s[k] == b'/' && s.get(k + 1) != Some(&b'>') {
            k += 1;
        } else {
            break;
        }
    }
    let value = value.map(|v| {
        let v = if v.len() >= 2 && ((v.starts_with('\'') && v.ends_with('\'')) || (v.starts_with('"') && v.ends_with('"'))) {
            &v[1..v.len() - 1]
        } else {
            v
        };
        if v.is_empty() { String::new() } else { unescape_attr(v) }
    });
    Some((name.to_lowercase(), value, k))
}

const CDATA_CONTENT: [&str; 6] = ["script", "style", "xmp", "iframe", "noembed", "noframes"];
const RCDATA_CONTENT: [&str; 2] = ["textarea", "title"];

struct Parser<'h, H: Handler> {
    raw: String,
    cdata_elem: Option<String>,
    escapable: bool,
    h: &'h mut H,
}

impl<'h, H: Handler> Parser<'h, H> {
    fn data(&mut self, d: &str) {
        if self.escapable {
            let u = unescape(d).into_owned();
            self.h.data(&u);
        } else {
            self.h.data(d);
        }
    }

    /// the cdata "interesting" regex: </elem followed by [\t\n\r\f />] (ASCII case-insensitive)
    fn find_cdata_end(&self, raw: &str, from: usize) -> Option<usize> {
        let elem = self.cdata_elem.as_deref()?;
        if elem == "plaintext" {
            return Some(raw.len());
        }
        let s = raw.as_bytes();
        let pat = elem.as_bytes();
        let mut i = from;
        while i + 2 + pat.len() < s.len() {
            if s[i] == b'<' && s[i + 1] == b'/' && s[i + 2..i + 2 + pat.len()].eq_ignore_ascii_case(pat) {
                let c = s[i + 2 + pat.len()];
                if ws(c) || c == b'/' || c == b'>' {
                    return Some(i);
                }
            }
            i += 1;
        }
        None
    }

    fn parse_starttag(&mut self, raw: &str, i: usize) -> isize {
        let s = raw.as_bytes();
        let endpos = locatetagend(s, i + 1);
        if endpos == 0 || s[endpos - 1] != b'>' {
            return -1;
        }
        let (name_end, mut k) = tagfind(s, i + 1).expect("starttag");
        let tag = raw[i + 1..name_end].to_lowercase();
        let mut attrs = vec![];
        while k < endpos {
            match attrfind(raw, k) {
                Some((n, v, e)) => {
                    attrs.push((n, v));
                    k = e;
                }
                None => break,
            }
        }
        let end = py_strip(&raw[k..endpos]);
        if end != ">" && end != "/>" {
            let d = raw[i..endpos].to_string();
            self.h.data(&d);
            return endpos as isize;
        }
        if end.ends_with("/>") {
            self.h.startend(&tag, &attrs);
        } else {
            self.h.start(&tag, &attrs);
            if CDATA_CONTENT.contains(&tag.as_str()) || tag == "plaintext" {
                self.cdata_elem = Some(tag);
                self.escapable = false;
            } else if RCDATA_CONTENT.contains(&tag.as_str()) {
                self.cdata_elem = Some(tag);
                self.escapable = true;
            }
        }
        endpos as isize
    }

    fn parse_bogus_comment(&mut self, raw: &str, i: usize) -> isize {
        match raw[i + 2..].find('>') {
            Some(p) => (i + 2 + p + 1) as isize,
            None => -1,
        }
    }

    fn parse_endtag(&mut self, raw: &str, i: usize) -> isize {
        let s = raw.as_bytes();
        if !raw[i + 2..].contains('>') {
            return -1;
        }
        if !(i + 2 < s.len() && s[i + 2].is_ascii_alphabetic()) {
            if s.get(i + 2) == Some(&b'>') {
                return (i + 3) as isize;
            }
            return self.parse_bogus_comment(raw, i);
        }
        let j = locatetagend(s, i + 2);
        if s[j - 1] != b'>' {
            return -1;
        }
        let (name_end, _) = tagfind(s, i + 2).expect("endtag");
        let tag = raw[i + 2..name_end].to_lowercase();
        self.h.end(&tag);
        self.cdata_elem = None;
        self.escapable = true;
        j as isize
    }

    fn parse_comment(&self, raw: &str, i: usize) -> isize {
        let rest = &raw[i + 4..];
        if rest.starts_with('>') {
            return (i + 5) as isize;
        }
        if rest.starts_with("->") {
            return (i + 6) as isize;
        }
        let b = rest.as_bytes();
        for p in 0..b.len() {
            if b[p..].starts_with(b"-->") {
                return (i + 4 + p + 3) as isize;
            }
            if b[p..].starts_with(b"--!>") {
                return (i + 4 + p + 4) as isize;
            }
        }
        -1
    }

    fn parse_html_declaration(&mut self, raw: &str, i: usize) -> isize {
        let rest = &raw[i..];
        if rest.starts_with("<!--") {
            self.parse_comment(raw, i)
        } else if rest.starts_with("<![CDATA[") {
            match raw[i + 9..].find("]]>") {
                Some(p) => (i + 9 + p + 3) as isize,
                None => -1,
            }
        } else if rest.len() >= 9 && rest.as_bytes()[..9].eq_ignore_ascii_case(b"<!doctype") {
            match raw[i + 9..].find('>') {
                Some(p) => (i + 9 + p + 1) as isize,
                None => -1,
            }
        } else {
            self.parse_bogus_comment(raw, i)
        }
    }

    fn goahead(&mut self, end: bool) {
        let raw = std::mem::take(&mut self.raw);
        let s = raw.as_bytes();
        let n = raw.len();
        let mut i = 0usize;
        while i < n {
            let j;
            if self.cdata_elem.is_none() {
                match raw[i..].find('<') {
                    Some(p) => j = i + p,
                    None => {
                        // a charref may be cut in half at the end of the buffer
                        let start = {
                            let tail: Vec<usize> = raw.char_indices().map(|(x, _)| x).collect();
                            let nc = tail.len();
                            let from_char = nc.saturating_sub(34);
                            i.max(tail.get(from_char).copied().unwrap_or(n))
                        };
                        if let Some(a) = raw[start..].rfind('&') {
                            let amppos = start + a;
                            if !raw[amppos..].bytes().any(|b| matches!(b, b'\t' | b'\n' | b'\r' | 0x0c | b' ' | b';')) {
                                break;
                            }
                        }
                        j = n;
                    }
                }
            } else {
                match self.find_cdata_end(&raw, i) {
                    Some(p) => j = p,
                    None => break,
                }
            }
            if i < j {
                self.data(&raw[i..j]);
            }
            i = j;
            if i == n {
                break;
            }
            // raw[i] == '<'
            let rest = &raw[i..];
            let k: isize = if i + 1 < n && s[i + 1].is_ascii_alphabetic() {
                self.parse_starttag(&raw, i)
            } else if rest.starts_with("</") {
                self.parse_endtag(&raw, i)
            } else if rest.starts_with("<!--") {
                self.parse_comment(&raw, i)
            } else if rest.starts_with("<?") {
                match raw[i + 2..].find('>') {
                    Some(p) => (i + 2 + p + 1) as isize,
                    None => -1,
                }
            } else if rest.starts_with("<!") {
                self.parse_html_declaration(&raw, i)
            } else if i + 1 < n || end {
                self.h.data("<");
                (i + 1) as isize
            } else {
                break;
            };
            let k = if k < 0 {
                if !end {
                    break;
                }
                if rest.starts_with("</") && i + 2 == n {
                    self.h.data("</");
                }
                // other unterminated constructs at EOF: comments / declarations / pi / a cut tag
                n
            } else {
                k as usize
            };
            i = k;
        }
        if end && i < n {
            let rest = raw[i..].to_string();
            self.data(&rest);
            i = n;
        }
        self.raw = raw[i..].to_string();
    }
}

/// p.feed(src); p.close()
pub fn parse<H: Handler>(src: &str, h: &mut H) {
    let mut p = Parser { raw: String::new(), cdata_elem: None, escapable: true, h };
    if !src.is_empty() {
        p.raw = src.to_string();
        p.goahead(false);
    }
    p.goahead(true);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Rec(Vec<String>);
    impl Handler for Rec {
        fn start(&mut self, t: &str, a: &[(String, Option<String>)]) {
            self.0.push(format!("S {t} {a:?}"));
        }
        fn end(&mut self, t: &str) {
            self.0.push(format!("E {t}"));
        }
        fn data(&mut self, d: &str) {
            self.0.push(format!("D {d}"));
        }
    }

    #[test]
    fn basics() {
        let mut r = Rec::default();
        parse("<p class=x id='y' hidden>a &amp; b&nbsp;c</p><br/><script>if (a<b) x()</script>t", &mut r);
        assert_eq!(
            r.0,
            vec![
                "S p [(\"class\", Some(\"x\")), (\"id\", Some(\"y\")), (\"hidden\", None)]",
                "D a & b\u{a0}c",
                "E p",
                "S br []",
                "E br",
                "S script []",
                "D if (a<b) x()",
                "E script",
                "D t"
            ]
        );
        assert_eq!(unescape("&lt;&#65;&#x42;&notit;&amp"), "<AB¬it;&");
    }
}
