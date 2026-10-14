//! What Python's email package does when it writes a message out with policy SMTP (CPython 3.14
//! email._header_value_parser._refold_parse_tree, _encoded_words.encode, quoprimime.body_encode,
//! contentmanager._encode_text), so a sent mail is byte-for-byte what the Python backend sent.
//! Header values become a small token tree shaped like Python's parse tree; folding walks it the
//! same way.

const MAXLEN: usize = 78;

#[derive(Clone, Debug)]
pub enum Tok {
    /// a terminal: text, token type, as_ew_allowed, syntactic_break, whitespace, rendered empty
    T { s: String, kind: &'static str, ew: bool, sb: bool, ws: bool, hidden: bool },
    L { kind: &'static str, kids: Vec<Tok>, ew: bool, sb: bool, params: Vec<(String, String)> },
    /// the end_ew_not_allowed marker
    End,
}

fn clen(s: &str) -> usize {
    s.chars().count()
}

fn cslice(s: &str, a: usize, b: usize) -> String {
    s.chars().skip(a).take(b.saturating_sub(a)).collect()
}

fn is_wsp(c: char) -> bool {
    c == ' ' || c == '\t'
}

pub fn vt(s: &str, kind: &'static str) -> Tok {
    Tok::T { s: s.into(), kind, ew: true, sb: true, ws: false, hidden: false }
}

pub fn ws(s: &str) -> Tok {
    Tok::T { s: s.into(), kind: "fws", ew: true, sb: true, ws: true, hidden: false }
}

pub fn list(kind: &'static str, ew: bool, kids: Vec<Tok>) -> Tok {
    Tok::L { kind, kids, ew, sb: true, params: vec![] }
}

fn quote_string(v: &str) -> String {
    format!("\"{}\"", v.replace('\\', "\\\\").replace('"', "\\\""))
}

impl Tok {
    pub fn text(&self) -> String {
        match self {
            Tok::T { s, hidden, .. } => if *hidden { String::new() } else { s.clone() },
            Tok::L { kind: "bare-quoted-string", kids, .. } => quote_string(&kids.iter().map(Tok::text).collect::<String>()),
            Tok::L { kids, .. } => kids.iter().map(Tok::text).collect(),
            Tok::End => String::new(),
        }
    }
    fn kind(&self) -> &'static str {
        match self {
            Tok::T { kind, .. } | Tok::L { kind, .. } => kind,
            Tok::End => "",
        }
    }
    fn ew_allowed(&self) -> bool {
        match self {
            Tok::T { ew, .. } | Tok::L { ew, .. } => *ew,
            Tok::End => false,
        }
    }
    fn syntactic_break(&self) -> bool {
        match self {
            Tok::T { sb, .. } | Tok::L { sb, .. } => *sb,
            Tok::End => false,
        }
    }
    fn startswith_fws(&self) -> bool {
        match self {
            Tok::T { ws, .. } => *ws,
            Tok::L { kids, .. } => kids.first().is_some_and(Tok::startswith_fws),
            Tok::End => false,
        }
    }
}

// ---------------------------------------------------------------- encoded words
fn q_len(b: &[u8]) -> usize {
    b.iter().map(|&c| if c.is_ascii_alphanumeric() || b"-!*+/ ".contains(&c) { 1 } else { 3 }).sum()
}

fn q_enc(b: &[u8]) -> String {
    b.iter()
        .map(|&c| match c {
            b' ' => "_".to_string(),
            c if c.is_ascii_alphanumeric() || b"-!*+/".contains(&c) => (c as char).to_string(),
            c => format!("={c:02X}"),
        })
        .collect()
}

/// email._encoded_words.encode(s, 'utf-8'): q unless b is 5+ shorter
pub fn ew_encode(s: &str) -> String {
    use base64::Engine as _;
    let b = s.as_bytes();
    let (ql, bl) = (q_len(b), b.len().div_ceil(3) * 4);
    if ql as i64 - (bl as i64) < 5 {
        format!("=?utf-8?q?{}?=", q_enc(b))
    } else {
        format!("=?utf-8?b?{}?=", base64::engine::general_purpose::STANDARD.encode(b))
    }
}

/// _ew.decode for get_unstructured: None when the word isn't a well-formed encoded word
fn ew_decode(tok: &str) -> Option<String> {
    use base64::Engine as _;
    let parts: Vec<&str> = tok.split('?').collect();
    if parts.len() != 5 {
        return None;
    }
    let charset = parts[1].split('*').next().unwrap_or("");
    let data = match parts[2].to_ascii_lowercase().as_str() {
        "q" => {
            let raw = parts[3].as_bytes();
            let mut out = vec![];
            let mut i = 0;
            while i < raw.len() {
                let hex = |j: usize| raw.get(j).filter(|c| c.is_ascii_hexdigit()).map(|c| (*c as char).to_digit(16).unwrap() as u8);
                if raw[i] == b'_' {
                    out.push(b' ');
                } else if let (b'=', Some(h), Some(l)) = (raw[i], hex(i + 1), hex(i + 2)) {
                    out.push(h * 16 + l);
                    i += 2;
                } else {
                    out.push(raw[i]);
                }
                i += 1;
            }
            out
        }
        "b" => {
            let mut s = parts[3].to_string();
            while s.len() % 4 != 0 {
                s.push('=');
            }
            base64::engine::general_purpose::STANDARD.decode(s.as_bytes()).ok()?
        }
        _ => return None,
    };
    let enc = encoding_rs::Encoding::for_label(charset.as_bytes()).unwrap_or(encoding_rs::UTF_8);
    Some(enc.decode_without_bom_handling(&data).0.into_owned())
}

/// rfc2047_matcher.search
fn has_ew(s: &str) -> bool {
    static R: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    R.get_or_init(|| regex::Regex::new(r"(?s)=\?[^?]*\?[qQbB]\?.*?\?=").unwrap()).is_match(s)
}

/// get_encoded_word's split of the decoded text into vtext / fws
fn ew_words(text: &str, kind: &'static str) -> Vec<Tok> {
    let mut out = vec![];
    let mut rest = text;
    while !rest.is_empty() {
        if rest.starts_with(is_wsp) {
            let n = rest.len() - rest.trim_start().len();
            out.push(ws(&rest[..n]));
            rest = &rest[n..];
            continue;
        }
        let n = rest.find(is_wsp).unwrap_or(rest.len());
        out.push(vt(&rest[..n], kind));
        rest = &rest[n..];
    }
    out
}

/// get_unstructured
pub fn unstructured(value: &str) -> Vec<Tok> {
    let mut toks: Vec<Tok> = vec![];
    let mut v = value.to_string();
    while !v.is_empty() {
        if v.starts_with(is_wsp) {
            let n = v.len() - v.trim_start().len(); // str.lstrip(): any whitespace
            toks.push(ws(&v[..n]));
            v = v[n..].to_string();
            continue;
        }
        let mut valid_ew = true;
        if v.starts_with("=?") {
            if let Some((tok, rem)) = v[2..].split_once("?=") {
                let (mut tok, mut rem) = (tok.to_string(), rem.to_string());
                let rb = rem.as_bytes();
                if rb.len() > 1 && rb[0].is_ascii_hexdigit() && rb[1].is_ascii_hexdigit() && tok.matches('?').count() < 2 {
                    let (r, rr) = rem.split_once("?=").map(|(a, b)| (a.to_string(), b.to_string())).unwrap_or((rem.clone(), String::new()));
                    tok = format!("{tok}?={r}");
                    rem = rr;
                }
                match ew_decode(&format!("=?{tok}?=")) {
                    Some(text) => {
                        let mut have_ws = true;
                        if let Some(last) = toks.last() {
                            if last.kind() != "fws" {
                                have_ws = false;
                            }
                        }
                        if have_ws && toks.len() > 1 && toks[toks.len() - 2].kind() == "encoded-word" {
                            if let Some(Tok::T { hidden, .. }) = toks.last_mut() {
                                *hidden = true;
                            }
                        }
                        toks.push(list("encoded-word", true, ew_words(&text, "vtext")));
                        v = rem;
                        continue;
                    }
                    None => valid_ew = false,
                }
            }
        }
        let n = v.find(is_wsp).unwrap_or(v.len());
        let (mut tok, mut rest) = (v[..n].to_string(), v[n..].to_string());
        if valid_ew && has_ew(&tok) {
            let i = v.find("=?").unwrap();
            tok = v[..i].to_string();
            rest = v[i..].to_string();
            if tok.is_empty() {
                // value.partition('=?') at 0: an empty utext, then the same text again (Python loops the same way)
                tok = "=?".into();
                rest = v[2..].to_string();
            }
        }
        toks.push(vt(&tok, "utext"));
        v = rest;
    }
    toks
}

fn unstructured_str(value: &str) -> String {
    unstructured(value).iter().map(Tok::text).collect()
}

// ---------------------------------------------------------------- folding
fn steal_trailing_wsp(lines: &mut Vec<String>) -> String {
    let mut w = String::new();
    if let Some(last) = lines.last_mut() {
        if let Some(c) = last.chars().last().filter(|c| is_wsp(*c)) {
            w.push(c);
            last.pop();
            if last.is_empty() {
                lines.pop();
            }
        }
    }
    w
}

fn fold_as_ew(to_encode: &str, lines: &mut Vec<String>, last_ew: Option<usize>, combine: bool, last_word_is_ew: bool) -> Option<usize> {
    let mut to_encode = to_encode.to_string();
    if let (Some(le), true) = (last_ew, combine) {
        let last = lines.last().unwrap().clone();
        to_encode = unstructured_str(&(cslice(&last, le, clen(&last)) + &to_encode));
        *lines.last_mut().unwrap() = cslice(&last, 0, le);
    } else if last_word_is_ew {
        let last = lines.last().unwrap().clone();
        let without = last.trim_end_matches(is_wsp).to_string();
        let lead = last[without.len()..].to_string();
        *lines.last_mut().unwrap() = without + if lead.is_empty() { "" } else { " " };
        to_encode = lead + &to_encode;
    } else if to_encode.starts_with(is_wsp) {
        let lead = to_encode.chars().next().unwrap();
        to_encode = to_encode[lead.len_utf8()..].to_string();
        if clen(lines.last().unwrap()) == MAXLEN {
            let nl = steal_trailing_wsp(lines);
            lines.push(nl);
        }
        lines.last_mut().unwrap().push(lead);
    }
    let mut trailing = String::new();
    if to_encode.ends_with(is_wsp) {
        trailing = to_encode.pop().unwrap().to_string();
    }
    let mut new_last_ew = last_ew.unwrap_or_else(|| clen(lines.last().unwrap()));
    let chrome = "utf-8".len() + 7;
    while !to_encode.is_empty() {
        let remaining = MAXLEN as i64 - clen(lines.last().unwrap()) as i64;
        let text_space = remaining - chrome as i64;
        if text_space <= 0 {
            let nl = steal_trailing_wsp(lines);
            lines.push(if nl.is_empty() { " ".into() } else { nl });
            new_last_ew = clen(lines.last().unwrap());
            continue;
        }
        let mut n = (text_space as usize).min(clen(&to_encode));
        let mut word = ew_encode(&cslice(&to_encode, 0, n));
        while clen(&word) as i64 > remaining {
            n -= 1;
            word = ew_encode(&cslice(&to_encode, 0, n));
        }
        lines.last_mut().unwrap().push_str(&word);
        to_encode = cslice(&to_encode, n, clen(&to_encode));
        if !to_encode.is_empty() {
            lines.push(" ".into());
            new_last_ew = clen(lines.last().unwrap());
        }
    }
    lines.last_mut().unwrap().push_str(&trailing);
    if combine { Some(new_last_ew) } else { None }
}

fn url_quote(v: &str) -> String {
    v.bytes().map(|b| if b.is_ascii_alphanumeric() || b"_.-~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect()
}

fn fold_mime_parameters(params: &[(String, String)], lines: &mut Vec<String>) {
    let mut maxlen = MAXLEN;
    for (name, value) in params {
        if !lines.last().unwrap().trim_end().ends_with(';') {
            lines.last_mut().unwrap().push(';');
        }
        let ascii = value.is_ascii();
        let charset = if ascii { "us-ascii" } else { "utf-8" };
        let tstr = if ascii { format!("{name}={}", quote_string(value)) } else { format!("{name}*={charset}''{}", url_quote(value)) };
        if clen(lines.last().unwrap()) + clen(&tstr) + 1 < maxlen {
            let l = lines.last_mut().unwrap();
            l.push(' ');
            l.push_str(&tstr);
            continue;
        } else if clen(&tstr) + 2 <= maxlen {
            lines.push(format!(" {tstr}"));
            continue;
        }
        let mut section = 0;
        let mut extra = format!("{charset}''");
        let mut value = value.clone();
        while !value.is_empty() {
            let chrome = name.len() + section.to_string().len() + 3 + extra.len();
            if maxlen <= chrome + 3 {
                maxlen = 78;
            }
            let maxchars = maxlen - chrome - 2;
            let mut split = maxchars;
            let mut enc;
            loop {
                enc = url_quote(&cslice(&value, 0, split));
                if enc.len() <= maxchars {
                    break;
                }
                split -= 1;
            }
            lines.push(format!(" {name}*{section}*={extra}{enc}"));
            extra.clear();
            section += 1;
            value = cslice(&value, split, clen(&value));
            if !value.is_empty() {
                lines.last_mut().unwrap().push(';');
            }
        }
    }
}

const SPECIALSNL: &str = "()<>@,:;.\\\"[]\n\r";

fn refold(tree: Vec<Tok>) -> Vec<String> {
    let mut lines = vec![String::new()];
    let mut last_word_is_ew = false;
    let mut last_ew: Option<usize> = None;
    let mut last_charset: Option<&str> = None;
    let mut blocked = 0i32;
    let mut want_encoding = false;
    let mut parts: std::collections::VecDeque<Tok> = tree.into();
    while let Some(part) = parts.pop_front() {
        if matches!(part, Tok::End) {
            blocked -= 1;
            continue;
        }
        let tstr = part.text();
        if !want_encoding {
            want_encoding = if matches!(part.kind(), "ptext" | "vtext") {
                tstr.chars().any(|c| SPECIALSNL.contains(c))
            } else {
                tstr.contains(['\n', '\r'])
            };
        }
        let charset = if tstr.is_ascii() { "us-ascii" } else { "utf-8" };
        if charset != "us-ascii" {
            want_encoding = true;
        }
        if let Tok::L { kind: "mime-parameters", params, .. } = &part {
            fold_mime_parameters(params, &mut lines);
            last_word_is_ew = false;
            continue;
        }
        if want_encoding && blocked == 0 {
            if !part.ew_allowed() {
                want_encoding = false;
                last_ew = None;
                if part.syntactic_break() {
                    if let Tok::L { kids, .. } = &part {
                        let enc = refold(kids.clone()).join("\r\n");
                        if !enc.contains("\r\n") {
                            if clen(&enc) > MAXLEN.saturating_sub(clen(lines.last().unwrap())) {
                                let nl = steal_trailing_wsp(&mut lines);
                                lines.push(nl);
                            }
                            lines.last_mut().unwrap().push_str(&enc);
                            last_word_is_ew = false;
                            continue;
                        }
                    }
                }
            }
            if let Tok::L { kids, .. } = &part {
                for k in kids.iter().rev() {
                    parts.push_front(k.clone());
                }
                want_encoding = false;
                continue;
            } else if part.ew_allowed() {
                if last_ew.is_some() && Some(charset) != last_charset && (last_charset == Some("unknown-8bit") || (last_charset == Some("utf-8") && charset != "us-ascii")) {
                    last_ew = None;
                }
                last_ew = fold_as_ew(&tstr, &mut lines, last_ew, true, last_word_is_ew);
                last_word_is_ew = true;
                last_charset = Some(charset);
                want_encoding = false;
                continue;
            } else {
                last_ew = None;
                want_encoding = false;
            }
        }
        let room = MAXLEN as i64 - clen(lines.last().unwrap()) as i64;
        if clen(&tstr) as i64 <= room {
            lines.last_mut().unwrap().push_str(&tstr);
            last_word_is_ew = last_word_is_ew && tstr.trim_matches(is_wsp).is_empty();
            continue;
        }
        if part.syntactic_break() && clen(&tstr) < MAXLEN {
            let nl = steal_trailing_wsp(&mut lines);
            if !nl.is_empty() || part.startswith_fws() {
                lines.push(nl + &tstr);
                last_word_is_ew = last_word_is_ew && lines.last().unwrap().trim_matches(is_wsp).is_empty();
                last_ew = None;
                continue;
            }
        }
        if let Tok::L { kind, kids, ew, .. } = &part {
            let mut newparts: Vec<Tok> = kids.clone();
            if *kind == "bare-quoted-string" {
                newparts = std::iter::once(vt("\"", "ptext"))
                    .chain(kids.iter().map(|p| vt(&p.text().replace('\\', "\\\\").replace('"', "\\\""), "ptext")))
                    .chain(std::iter::once(vt("\"", "ptext")))
                    .collect();
            }
            if !ew {
                blocked += 1;
                newparts.push(Tok::End);
            }
            for k in newparts.into_iter().rev() {
                parts.push_front(k);
            }
            continue;
        }
        if part.ew_allowed() && blocked == 0 {
            parts.push_front(part);
            want_encoding = true;
            continue;
        }
        let nl = steal_trailing_wsp(&mut lines);
        if !nl.is_empty() || part.startswith_fws() {
            lines.push(nl + &tstr);
        } else {
            lines.last_mut().unwrap().push_str(&tstr);
        }
        last_word_is_ew = last_word_is_ew && tstr.trim_matches(is_wsp).is_empty();
    }
    lines
}

/// "Name: value\r\n", folded like BaseHeader.fold
pub fn header(name: &str, value: Vec<Tok>) -> String {
    let mut tree = vec![list("header-label", false, vec![vt(name, "header-name"), vt(":", "header-sep")])];
    // BaseHeader.fold: no blank after the colon when the parse tree is empty
    if value.iter().any(|t| !matches!(t, Tok::L { kids, .. } if kids.is_empty())) {
        tree.push(list("cfws", true, vec![ws(" ")]));
        tree.extend(value);
    }
    refold(tree).join("\r\n") + "\r\n"
}

pub fn unstructured_header(name: &str, value: &str) -> String {
    header(name, vec![list("unstructured", true, unstructured(value))])
}

// ---------------------------------------------------------------- message ids (In-Reply-To, References)
const ATOM_ENDS: &str = "()<>@,:;.\\\"[] \t";

fn dot_atom_text(v: &str) -> Option<(Tok, &str)> {
    let mut kids = vec![];
    let mut v = v;
    if v.is_empty() || v.starts_with(|c| ATOM_ENDS.contains(c)) {
        return None;
    }
    while !v.is_empty() && !v.starts_with(|c| ATOM_ENDS.contains(c)) {
        let n = v.find(|c| ATOM_ENDS.contains(c)).unwrap_or(v.len());
        kids.push(vt(&v[..n], "atext"));
        v = &v[n..];
        if let Some(r) = v.strip_prefix('.') {
            kids.push(vt(".", "dot"));
            v = r;
        }
    }
    if kids.last().is_some_and(|k| k.kind() == "dot") {
        return None;
    }
    Some((list("dot-atom-text", true, kids), v))
}

fn lead_ws(v: &str) -> Option<(Tok, &str)> {
    if v.starts_with(is_wsp) {
        let n = v.len() - v.trim_start().len();
        Some((list("cfws", true, vec![ws(&v[..n])]), &v[n..]))
    } else {
        None
    }
}

fn msg_id(v: &str) -> Option<(Tok, &str)> {
    let mut kids = vec![];
    let mut v = v;
    if let Some((t, r)) = lead_ws(v) {
        kids.push(t);
        v = r;
    }
    v = v.strip_prefix('<')?;
    kids.push(vt("<", "msg-id-start"));
    let (t, r) = dot_atom_text(v)?;
    kids.push(t);
    v = r;
    let Some(r) = v.strip_prefix('@') else {
        if let Some(r) = v.strip_prefix('>') {
            kids.push(vt(">", "msg-id-end"));
            v = r;
        }
        return Some((list("msg-id", false, kids), v));
    };
    kids.push(vt("@", "address-at-symbol"));
    v = r;
    if let Some((t, r)) = dot_atom_text(v) {
        kids.push(t);
        v = r;
    } else if let Some(r) = v.strip_prefix('[') {
        let n = r.find([']', '[', '\\']).filter(|&i| r[i..].starts_with(']'))?;
        kids.push(list("no-fold-literal", false, vec![vt("[", "no-fold-literal-start"), vt(&r[..n], "ptext"), vt("]", "no-fold-literal-end")]));
        v = &r[n + 1..];
    } else {
        return None;
    }
    if let Some(r) = v.strip_prefix('>') {
        v = r;
    }
    kids.push(vt(">", "msg-id-end"));
    if let Some((t, r)) = lead_ws(v) {
        kids.push(t);
        v = r;
    }
    Some((list("msg-id", false, kids), v))
}

/// parse_message_ids
pub fn message_ids(value: &str) -> Tok {
    let mut kids = vec![];
    let mut v = value;
    while !v.is_empty() {
        if let Some(r) = v.strip_prefix(',') {
            kids.push(Tok::T { s: " ".into(), kind: "invalid-comma-replacement", ew: true, sb: true, ws: true, hidden: false });
            v = r;
            continue;
        }
        match msg_id(v) {
            Some((t, r)) => {
                kids.push(t);
                v = r;
            }
            None => {
                kids.push(list("invalid-message-id", false, unstructured(v)));
                break;
            }
        }
    }
    list("message-id-list", false, kids)
}

// ---------------------------------------------------------------- addresses (what formataddr gave)
fn addr_spec(addr: &str, lead: bool) -> Tok {
    let (local, dom) = addr.rsplit_once('@').unwrap_or((addr, ""));
    let mut lp = vec![];
    if lead {
        lp.push(list("cfws", true, vec![ws(" ")]));
    }
    lp.push(list("dot-atom-text", true, vec![vt(local, "atext")]));
    let mut kids = vec![list("local-part", false, vec![list("dot-atom", true, lp)])];
    if !dom.is_empty() || addr.contains('@') {
        kids.push(vt("@", "address-at-symbol"));
        kids.push(list("domain", false, vec![list("dot-atom", true, vec![list("dot-atom-text", true, vec![vt(dom, "atext")])])]));
    }
    list("addr-spec", false, kids)
}

const ADDR_SPECIALS: &str = "][\\()<>@,:;\".";

/// email.utils.formataddr((name, addr)) for each pair, joined with ", ", as Python parses it back
pub fn address_list(pairs: &[(String, String)]) -> Tok {
    let mut kids = vec![];
    for (i, (name, addr)) in pairs.iter().enumerate() {
        if i > 0 {
            kids.push(Tok::T { s: ",".into(), kind: "list-separator", ew: false, sb: false, ws: false, hidden: false });
        }
        let lead = i > 0;
        let lead_cfws = || list("cfws", true, vec![ws(" ")]);
        let mailbox = if name.is_empty() {
            addr_spec(addr, lead)
        } else {
            let dn = if !name.is_ascii() {
                let mut a = vec![];
                if lead {
                    a.push(lead_cfws());
                }
                a.push(list("encoded-word", true, ew_words(name, "vtext")));
                a.push(lead_cfws());
                vec![list("atom", true, a)]
            } else if name.contains(|c| ADDR_SPECIALS.contains(c)) {
                let mut q = vec![];
                if lead {
                    q.push(lead_cfws());
                }
                q.push(list("bare-quoted-string", true, ew_words(name, "ptext")));
                q.push(lead_cfws());
                vec![list("quoted-string", true, q)]
            } else {
                let mut atoms = vec![];
                let words: Vec<Tok> = ew_words(name, "atext");
                let mut cur = vec![];
                if lead {
                    cur.push(lead_cfws());
                }
                for w in words {
                    if w.startswith_fws() {
                        cur.push(list("cfws", true, vec![w]));
                        atoms.push(list("atom", true, std::mem::take(&mut cur)));
                    } else {
                        cur.push(w);
                    }
                }
                cur.push(lead_cfws());
                atoms.push(list("atom", true, cur));
                atoms
            };
            let angle = list("angle-addr", false, vec![vt("<", "angle-addr-start"), addr_spec(addr, false), vt(">", "angle-addr-end")]);
            list("name-addr", false, vec![list("display-name", true, dn), angle])
        };
        kids.push(list("address", false, vec![list("mailbox", false, vec![mailbox])]));
    }
    list("address-list", false, kids)
}

// ---------------------------------------------------------------- MIME headers
/// "maintype/subtype; k=v" with the parameters folded the RFC 2231 way
pub fn content_header(name: &str, value: &str, params: &[(&str, &str)]) -> String {
    let mut kids = vec![];
    let ctype = name.eq_ignore_ascii_case("Content-Type");
    if ctype {
        let (m, s) = value.split_once('/').unwrap_or((value, ""));
        kids.push(list("token", true, vec![vt(m, "ttext")]));
        kids.push(vt("/", "content-type-separator"));
        kids.push(list("token", true, vec![vt(s, "ttext")]));
    } else {
        kids.push(list("token", true, vec![vt(value, "ttext")]));
    }
    if !params.is_empty() {
        kids.push(vt(";", "parameter-separator"));
        // str() of the parsed parameters: what Message.set_param wrote
        let text: String = params
            .iter()
            .map(|(k, v)| if v.is_ascii() { format!(" {k}={}", quote_string(v)) } else { format!(" {k}*=utf-8''{}", url_quote(v)) })
            .collect::<Vec<_>>()
            .join(";");
        kids.push(Tok::L {
            kind: "mime-parameters",
            kids: vec![vt(&text, "mime-text")],
            ew: true,
            sb: false,
            params: params.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
        });
    }
    let tree = Tok::L { kind: if ctype { "content-type" } else { "content-disposition" }, kids, ew: false, sb: false, params: vec![] };
    header(name, vec![tree])
}

// ---------------------------------------------------------------- bodies
/// quoprimime.body_encode(body, 78) with eol "\n"
pub fn qp_body(body: &[u8]) -> String {
    if body.is_empty() {
        return String::new();
    }
    let enc: String = body
        .iter()
        .map(|&c| if (c.is_ascii_graphic() && c != b'=') || c == b' ' || c == b'\t' || c == b'\r' || c == b'\n' { (c as char).to_string() } else { format!("={c:02X}") })
        .collect();
    let maxlen = MAXLEN;
    let mut out: Vec<String> = vec![];
    // str.splitlines on \r, \n, \r\n (the only line breaks left after quoting)
    let mut lines = vec![];
    let mut cur = String::new();
    let b = enc.as_bytes();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'\r' => {
                lines.push(std::mem::take(&mut cur));
                if b.get(i + 1) == Some(&b'\n') {
                    i += 1;
                }
            }
            b'\n' => lines.push(std::mem::take(&mut cur)),
            c => cur.push(c as char),
        }
        i += 1;
    }
    if !cur.is_empty() {
        lines.push(cur);
    }
    for line in lines {
        let lb = line.as_bytes();
        let mut start = 0usize;
        let last = lb.len() as i64 - 1 - maxlen as i64;
        while start as i64 <= last {
            let stop = start + maxlen - 1;
            if lb[stop - 2] == b'=' {
                out.push(line[start..stop - 1].to_string());
                start = stop - 2;
            } else if lb[stop - 1] == b'=' {
                out.push(line[start..stop].to_string());
                start = stop - 1;
            } else {
                out.push(format!("{}=", &line[start..stop]));
                start = stop;
            }
        }
        if let Some(&c) = lb.last().filter(|c| **c == b' ' || **c == b'\t') {
            let room = start as i64 - last;
            let q = if room >= 3 {
                format!("={c:02X}")
            } else if room == 2 {
                format!("{}=\n", c as char)
            } else {
                format!("=\n={c:02X}")
            };
            out.push(format!("{}{q}", &line[start..lb.len() - 1]));
        } else {
            out.push(line[start..].to_string());
        }
    }
    if matches!(body.last(), Some(b'\r' | b'\n')) {
        out.push(String::new());
    }
    out.join("\n")
}

/// bytes.splitlines()
fn split_lines(b: &[u8]) -> Vec<&[u8]> {
    let mut out = vec![];
    let mut s = 0;
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'\n' || b[i] == b'\r' {
            out.push(&b[s..i]);
            if b[i] == b'\r' && b.get(i + 1) == Some(&b'\n') {
                i += 1;
            }
            s = i + 1;
        }
        i += 1;
    }
    if s < b.len() {
        out.push(&b[s..]);
    }
    out
}

/// _encode_base64(data, 78): 57-byte chunks, "\n" after each line
pub fn b64_body(data: &[u8]) -> String {
    use base64::Engine as _;
    data.chunks(57).map(|c| base64::engine::general_purpose::STANDARD.encode(c) + "\n").collect()
}

/// contentmanager._encode_text(string, 'utf-8', None, SMTP) -> (cte, payload with "\n" line ends)
pub fn encode_text(s: &str) -> (&'static str, Vec<u8>) {
    let lines = split_lines(s.as_bytes());
    let normal = |ls: &[&[u8]]| -> Vec<u8> {
        let mut v = ls.join(&b"\n"[..]);
        v.push(b'\n');
        v
    };
    let embedded = |ls: &[&[u8]]| -> Vec<u8> {
        let mut v = ls.join(&b"\r\n"[..]);
        v.extend_from_slice(b"\r\n");
        v
    };
    if lines.iter().map(|l| l.len()).max().unwrap_or(0) <= MAXLEN {
        let n = normal(&lines);
        return if n.is_ascii() { ("7bit", n) } else { ("8bit", n) };
    }
    let sniff = embedded(&lines[..lines.len().min(10)]);
    let sniff_qp = qp_body(&sniff);
    let sniff_b64 = sniff.len().div_ceil(3) * 4 + 1;
    if sniff_qp.len() > sniff_b64 {
        ("base64", b64_body(&embedded(&lines)).into_bytes())
    } else if lines.len() <= 10 {
        ("quoted-printable", sniff_qp.into_bytes())
    } else {
        ("quoted-printable", qp_body(&normal(&lines)).into_bytes())
    }
}

/// Generator._write_lines: every line break becomes CRLF
pub fn crlf(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(payload.len() + payload.len() / 40);
    let mut i = 0;
    while i < payload.len() {
        match payload[i] {
            b'\r' => {
                out.extend_from_slice(b"\r\n");
                if payload.get(i + 1) == Some(&b'\n') {
                    i += 1;
                }
            }
            b'\n' => out.extend_from_slice(b"\r\n"),
            c => out.push(c),
        }
        i += 1;
    }
    out
}

/// Generator._make_boundary: '=' * 15 + 19 random digits + '=='
pub fn boundary() -> String {
    let mut r = [0u8; 8];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        use std::io::Read;
        let _ = f.read_exact(&mut r);
    }
    format!("==============={:019}==", u64::from_le_bytes(r) % (i64::MAX as u64))
}
