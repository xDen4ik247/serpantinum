//! IMAP response helpers (port of glassmail/imapparse.py): s-expressions with literals, FETCH and
//! LIST responses, BODYSTRUCTURE walking, modified UTF-7 folder names (RFC 3501 §5.1.3).
//! A response arrives as a buffer where every {n} literal is replaced by \x00<index>\x00, plus the
//! list of literals, exactly the shape the Python built from imaplib's output.
use base64::Engine as _;
use indexmap::IndexMap;
use serde_json::{json, Value};

#[derive(Clone, Debug, PartialEq)]
pub enum S {
    Nil,
    Atom(Vec<u8>),
    /// a quoted string or a {n} literal: raw bytes, never an atom
    Lit(Vec<u8>),
    List(Vec<S>),
}

impl S {
    /// ip.text(): None -> '', bytes -> str
    pub fn text(&self) -> String {
        match self {
            S::Nil => String::new(),
            S::Atom(b) | S::Lit(b) => String::from_utf8_lossy(b).into_owned(),
            S::List(_) => String::new(),
        }
    }
    /// ip.num(): int() or the default
    pub fn num(&self) -> i64 {
        match self {
            S::Atom(b) | S::Lit(b) => std::str::from_utf8(b).ok().and_then(|s| s.trim().parse().ok()).unwrap_or(0),
            _ => 0,
        }
    }
    pub fn bytes(&self) -> Vec<u8> {
        match self {
            S::Atom(b) | S::Lit(b) => b.clone(),
            _ => vec![],
        }
    }
    pub fn is_truthy(&self) -> bool {
        match self {
            S::Nil => false,
            S::Atom(b) | S::Lit(b) => !b.is_empty(),
            S::List(l) => !l.is_empty(),
        }
    }
    pub fn list(&self) -> Option<&Vec<S>> {
        match self {
            S::List(l) => Some(l),
            _ => None,
        }
    }
}

pub fn num_of(v: Option<&S>) -> i64 {
    v.map_or(0, S::num)
}

pub fn text_of(v: Option<&S>) -> String {
    v.map_or(String::new(), S::text)
}

fn atom_end(c: u8) -> bool {
    matches!(c, b' ' | b'(' | b')' | b'{' | b'"' | b'\r' | b'\n')
}

/// Parse one value list from buf starting at pos; returns (list, pos).
pub fn parse_sexp(buf: &[u8], lits: &[Vec<u8>], mut pos: usize) -> (Vec<S>, usize) {
    let mut out = vec![];
    let n = buf.len();
    while pos < n {
        let c = buf[pos];
        match c {
            b' ' | b'\r' | b'\n' => pos += 1,
            b'(' => {
                let (sub, p) = parse_sexp(buf, lits, pos + 1);
                out.push(S::List(sub));
                pos = p;
            }
            b')' => return (out, pos + 1),
            b'"' => {
                pos += 1;
                let mut s = vec![];
                while pos < n && buf[pos] != b'"' {
                    if buf[pos] == b'\\' && pos + 1 < n {
                        pos += 1;
                    }
                    s.push(buf[pos]);
                    pos += 1;
                }
                out.push(S::Lit(s));
                pos += 1;
            }
            0 => {
                let end = buf[pos + 1..].iter().position(|&b| b == 0).map(|e| pos + 1 + e).unwrap_or(n);
                let idx: usize = std::str::from_utf8(&buf[pos + 1..end]).ok().and_then(|s| s.parse().ok()).unwrap_or(usize::MAX);
                out.push(S::Lit(lits.get(idx).cloned().unwrap_or_default()));
                pos = end + 1;
            }
            b'{' => {
                // an inline {n} literal (the reader normally replaces them)
                let Some(e) = buf[pos..].iter().position(|&b| b == b'}') else { break };
                let end = pos + e;
                let k: usize = std::str::from_utf8(&buf[pos + 1..end]).ok().and_then(|s| s.parse().ok()).unwrap_or(0);
                let Some(nl) = buf[end..].iter().position(|&b| b == b'\n') else { break };
                let start = end + nl + 1;
                out.push(S::Lit(buf[start..(start + k).min(n)].to_vec()));
                pos = start + k;
            }
            _ => {
                let start = pos;
                let mut depth = 0i32;
                while pos < n {
                    let ch = buf[pos];
                    if ch == b'[' {
                        depth += 1;
                    } else if ch == b']' {
                        depth -= 1;
                    } else if depth == 0 && atom_end(ch) {
                        break;
                    } else if depth > 0 && ch == 0 {
                        break;
                    }
                    pos += 1;
                }
                if pos == start {
                    pos += 1;
                    continue;
                }
                let atom = &buf[start..pos];
                out.push(if atom.eq_ignore_ascii_case(b"NIL") { S::Nil } else { S::Atom(atom.to_vec()) });
            }
        }
    }
    (out, pos)
}

pub type Fetch = IndexMap<Vec<u8>, S>;

/// FETCH response -> [{b"UID": .., b"FLAGS": .., b"BODY[...]": .., b"SEQ": ..}]
pub fn parse_fetch(buf: &[u8], lits: &[Vec<u8>]) -> Vec<Fetch> {
    let mut out = vec![];
    let mut pos = 0;
    loop {
        // _FETCH_RE: (\d+) \(
        let mut found = None;
        let mut i = pos;
        while i < buf.len() {
            if buf[i].is_ascii_digit() {
                let s = i;
                while i < buf.len() && buf[i].is_ascii_digit() {
                    i += 1;
                }
                if buf.get(i) == Some(&b' ') && buf.get(i + 1) == Some(&b'(') {
                    found = Some((s, i, i + 2));
                    break;
                }
            } else {
                i += 1;
            }
        }
        let Some((s, e, after)) = found else { break };
        let (items, p) = parse_sexp(buf, lits, after);
        pos = p;
        let mut d: Fetch = IndexMap::new();
        let mut k = 0;
        while k + 1 < items.len() {
            if let S::Atom(key) = &items[k] {
                let up: Vec<u8> = key.to_ascii_uppercase();
                let up = String::from_utf8_lossy(&up).replace("BODY.PEEK", "BODY").into_bytes();
                d.insert(up, items[k + 1].clone());
            }
            k += 2;
        }
        d.insert(b"SEQ".to_vec(), S::Atom(buf[s..e].to_vec()));
        out.push(d);
    }
    out
}

/// A LIST response line (after "* LIST ") and its literal name, if the name came as a literal.
pub type ListLine = (Vec<u8>, Option<Vec<u8>>);

/// LIST lines -> [(flags (lower case), delimiter, decoded name, raw name)]
pub fn parse_list(data: &[ListLine]) -> Vec<(Vec<String>, Option<String>, String, String)> {
    let mut out = vec![];
    for (line, lit) in data {
        if line.is_empty() {
            continue;
        }
        let mut l = line.clone();
        while l.last().is_some_and(|c| c.is_ascii_whitespace()) {
            l.pop();
        }
        if lit.is_some() {
            l.extend_from_slice(b" \"x\"");
        }
        // \((flags)\) (NIL|"delim") (name)
        if l.first() != Some(&b'(') {
            continue;
        }
        let Some(close) = l.iter().position(|&c| c == b')') else { continue };
        let flags_s = String::from_utf8_lossy(&l[1..close]).into_owned();
        let rest = &l[close + 1..];
        if rest.first() != Some(&b' ') {
            continue;
        }
        let rest = &rest[1..];
        let (delim, after) = if rest.starts_with(b"NIL") {
            (None, &rest[3..])
        } else if rest.first() == Some(&b'"') {
            let mut j = 1;
            let mut ok = false;
            while j < rest.len() {
                if rest[j] == b'\\' && j + 1 < rest.len() {
                    j += 2;
                    continue;
                }
                if rest[j] == b'"' {
                    ok = true;
                    break;
                }
                j += 1;
            }
            if !ok {
                continue;
            }
            let d = String::from_utf8_lossy(&rest[1..j]).replace("\\\\", "\\");
            (Some(d), &rest[j + 1..])
        } else {
            continue;
        };
        if after.first() != Some(&b' ') || after.len() < 2 {
            continue;
        }
        let name_part = &after[1..];
        let raw: Vec<u8> = match lit {
            Some(n) => n.clone(),
            None => {
                let t = name_part.trim_ascii();
                if t.first() == Some(&b'"') && t.len() >= 2 {
                    String::from_utf8_lossy(&t[1..t.len() - 1]).replace("\\\"", "\"").replace("\\\\", "\\").into_bytes()
                } else {
                    t.to_vec()
                }
            }
        };
        let raw = String::from_utf8_lossy(&raw).into_owned();
        let flags: Vec<String> = flags_s.split_whitespace().map(|f| f.to_lowercase()).collect();
        out.push((flags, delim, decode_utf7(&raw), raw));
    }
    out
}

/// Quote a mailbox name for a command.
pub fn quote(name: &str) -> String {
    format!("\"{}\"", name.replace('\\', "\\\\").replace('"', "\\\""))
}

pub fn decode_utf7(s: &str) -> String {
    let mut out = String::new();
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        let tail = &rest[i..];
        match tail[1..].find('-') {
            None => {
                out.push_str(tail);
                return out;
            }
            Some(0) => {
                out.push('&');
                rest = &tail[2..];
            }
            Some(j) => {
                let mut b = tail[1..1 + j].replace(',', "/");
                while b.len() % 4 != 0 {
                    b.push('=');
                }
                let decoded = base64::engine::general_purpose::STANDARD.decode(&b).ok().and_then(|bytes| {
                    if bytes.len() % 2 != 0 {
                        return None;
                    }
                    let u: Vec<u16> = bytes.chunks(2).map(|c| u16::from_be_bytes([c[0], c[1]])).collect();
                    String::from_utf16(&u).ok()
                });
                match decoded {
                    Some(d) => out.push_str(&d),
                    None => out.push_str(&tail[..j + 2]),
                }
                rest = &tail[j + 2..];
            }
        }
    }
    out.push_str(rest);
    out
}

pub fn encode_utf7(s: &str) -> String {
    let mut out = String::new();
    let mut buf: Vec<char> = vec![];
    let flush = |buf: &mut Vec<char>, out: &mut String| {
        if !buf.is_empty() {
            let mut u16s = vec![];
            for c in buf.iter() {
                let mut tmp = [0u16; 2];
                u16s.extend_from_slice(c.encode_utf16(&mut tmp));
            }
            let bytes: Vec<u8> = u16s.iter().flat_map(|u| u.to_be_bytes()).collect();
            let b = base64::engine::general_purpose::STANDARD.encode(bytes);
            out.push('&');
            out.push_str(&b.trim_end_matches('=').replace('/', ","));
            out.push('-');
            buf.clear();
        }
    };
    for c in s.chars() {
        if (0x20..=0x7e).contains(&(c as u32)) {
            flush(&mut buf, &mut out);
            if c == '&' {
                out.push_str("&-");
            } else {
                out.push(c);
            }
        } else {
            buf.push(c);
        }
    }
    flush(&mut buf, &mut out);
    out
}

fn pairs(v: Option<&S>) -> IndexMap<String, String> {
    let mut out = IndexMap::new();
    if let Some(S::List(l)) = v {
        let mut i = 0;
        while i + 1 < l.len() {
            out.insert(l[i].text().to_lowercase(), l[i + 1].text());
            i += 2;
        }
    }
    out
}

/// Every leaf part of a BODYSTRUCTURE: (part number, info {type, subtype, params, id, encoding, size, disposition, filename})
pub fn walk_structure(bs: &[S], prefix: &str, out: &mut Vec<(String, Value)>) {
    if bs.is_empty() {
        return;
    }
    if let S::List(_) = bs[0] {
        let mut n = 1;
        for part in bs {
            let S::List(p) = part else { break };
            let pre = if prefix.is_empty() { n.to_string() } else { format!("{prefix}.{n}") };
            walk_structure(p, &pre, out);
            n += 1;
        }
        return;
    }
    let t = bs[0].text().to_lowercase();
    let st = bs.get(1).map(|x| x.text().to_lowercase()).unwrap_or_default();
    let params = pairs(bs.get(2));
    let id = match bs.get(3) {
        Some(x) if x.is_truthy() => x.text().trim_matches(['<', '>']).to_string(),
        _ => String::new(),
    };
    let encoding = bs.get(5).map(|x| x.text().to_lowercase()).unwrap_or_else(|| "7bit".into());
    let size = bs.get(6).map(S::num).unwrap_or(0);
    let mut filename = params.get("name").cloned().unwrap_or_default();
    let mut disposition = String::new();
    let ext = if t == "text" {
        8
    } else if t == "message" && st == "rfc822" {
        10
    } else {
        7
    };
    if let Some(S::List(d)) = bs.get(ext + 1) {
        if !d.is_empty() {
            disposition = d[0].text().to_lowercase();
            let dp = pairs(d.get(1));
            if let Some(f) = dp.get("filename").filter(|f| !f.is_empty()) {
                filename = f.clone();
            }
        }
    }
    if !filename.is_empty() {
        filename = crate::mime::dec(&filename);
    }
    let params_v: serde_json::Map<String, Value> = params.into_iter().map(|(k, v)| (k, Value::String(v))).collect();
    let info = json!({"type": t, "subtype": st, "params": params_v, "id": id, "encoding": encoding, "size": size,
                      "disposition": disposition, "filename": filename});
    out.push((if prefix.is_empty() { "1".into() } else { prefix.to_string() }, info));
}

/// -> (text part number, its info, has attachments)
pub fn summarize_structure(bs: &[S]) -> (Option<String>, Option<Value>, bool) {
    let mut all = vec![];
    walk_structure(bs, "", &mut all);
    let (mut plain, mut html) = (None, None);
    let mut att = false;
    for (n, info) in all {
        let t = info["type"].as_str().unwrap_or("");
        let disp = info["disposition"].as_str().unwrap_or("");
        let fname = info["filename"].as_str().unwrap_or("");
        let is_att = disp == "attachment" || (!fname.is_empty() && t != "text" && disp != "inline");
        if is_att || (t != "text" && t != "multipart" && disp != "inline" && !fname.is_empty()) {
            att = true;
            continue;
        }
        let sub = info["subtype"].as_str().unwrap_or("");
        if t == "text" && sub == "plain" && plain.is_none() {
            plain = Some((n, info));
        } else if t == "text" && sub == "html" && html.is_none() {
            html = Some((n, info));
        }
    }
    match plain.or(html) {
        Some((n, i)) => (Some(n), Some(i), att),
        None => (None, None, att),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fetch_with_literals_and_flags() {
        // b'1 (UID 7 FLAGS (\\Seen $Label) BODY[HEADER.FIELDS (SUBJECT)] {13}' + literal + b' X-GM-THRID 99)' + b'2 (UID 8 FLAGS () BODY[1]<0> NIL)'
        let buf = b"1 (UID 7 FLAGS (\\Seen $Label) BODY[HEADER.FIELDS (SUBJECT)] \x000\x00 X-GM-THRID 99)2 (UID 8 FLAGS () BODY[1]<0> NIL)";
        let lits = vec![b"Subject: hi\r\n".to_vec()];
        let r = parse_fetch(buf, &lits);
        assert_eq!(r[0][&b"UID".to_vec()], S::Atom(b"7".to_vec()));
        assert_eq!(r[0][&b"FLAGS".to_vec()], S::List(vec![S::Atom(b"\\Seen".to_vec()), S::Atom(b"$Label".to_vec())]));
        assert_eq!(r[0][&b"BODY[HEADER.FIELDS (SUBJECT)]".to_vec()], S::Lit(b"Subject: hi\r\n".to_vec()));
        assert_eq!(r[0][&b"X-GM-THRID".to_vec()], S::Atom(b"99".to_vec()));
        assert_eq!(r[1][&b"BODY[1]<0>".to_vec()], S::Nil);
    }

    #[test]
    fn list_and_utf7() {
        let data: Vec<ListLine> = vec![
            (b"(\\HasNoChildren \\Sent) \"/\" \"&BB4EQgQ,BEAEMAQyBDsENQQ9BD0ESwQ1-\"".to_vec(), None),
            (b"(\\Noselect) \"/\" \"[Gmail]\"".to_vec(), None),
            (b"(\\HasNoChildren) \".\" INBOX".to_vec(), None),
        ];
        let out = parse_list(&data);
        assert_eq!(out[0].2, "Отправленные");
        assert!(out[0].0.contains(&"\\sent".to_string()));
        assert_eq!(out[2].2, "INBOX");
        assert_eq!(encode_utf7("Отправленные"), "&BB4EQgQ,BEAEMAQyBDsENQQ9BD0ESwQ1-");
        assert_eq!(decode_utf7(&encode_utf7("A & B")), "A & B");
    }

    #[test]
    fn bodystructure() {
        let a = |s: &str| S::Atom(s.as_bytes().to_vec());
        let l = |s: &str| S::Lit(s.as_bytes().to_vec());
        let bs = vec![
            S::List(vec![
                S::List(vec![l("text"), l("plain"), S::List(vec![l("charset"), l("utf-8")]), S::Nil, S::Nil, l("quoted-printable"), a("100"), a("3"), S::Nil, S::Nil, S::Nil, S::Nil]),
                S::List(vec![l("text"), l("html"), S::List(vec![l("charset"), l("utf-8")]), S::Nil, S::Nil, l("base64"), a("900"), a("12"), S::Nil, S::Nil, S::Nil, S::Nil]),
                l("alternative"),
            ]),
            S::List(vec![
                l("application"), l("pdf"), S::List(vec![l("name"), l("a.pdf")]), S::Nil, S::Nil, l("base64"), a("5000"), S::Nil,
                S::List(vec![l("attachment"), S::List(vec![l("filename"), l("a.pdf")])]), S::Nil, S::Nil,
            ]),
            l("mixed"),
        ];
        let (part, info, att) = summarize_structure(&bs);
        assert_eq!(part.as_deref(), Some("1.1"));
        assert_eq!(info.unwrap()["encoding"], "quoted-printable");
        assert!(att);
    }
}
