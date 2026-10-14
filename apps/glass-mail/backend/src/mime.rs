//! Reading and writing messages (port of glassmail/mime.py): header rows for the list, the reader
//! pane's view of a full message, snippets, and new mail / replies / forwards ready for SMTP.
//! Parsing uses mail-parser; the part walk follows Python's email.Message.walk() (it also steps
//! into attached messages), so the same parts end up as text, inline images and attachments.
use crate::htmlparser::{escape, py_strip};
use crate::mimetab::{EXT_OF, TYPE_OF};
use crate::pyfold;
use crate::reader;
use base64::Engine as _;
use mail_parser::{Message, MessageParser, MessagePart, MimeHeaders, PartType};
use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

fn re(cell: &'static OnceLock<Regex>, pat: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pat).unwrap())
}

pub fn parse(raw: &[u8]) -> Option<Message<'_>> {
    MessageParser::default().parse(raw)
}

/// Unfold a raw header value (CRLF + WSP -> WSP).
pub fn unfold(s: &str) -> String {
    let s = s.replace("\r\n", "\n");
    let mut out = String::with_capacity(s.len());
    let mut it = s.chars().peekable();
    while let Some(c) = it.next() {
        if c == '\n' && it.peek().is_some_and(|n| *n == ' ' || *n == '\t') {
            continue;
        }
        if c == '\n' && it.peek().is_none() {
            continue;
        }
        out.push(c);
    }
    out
}

/// The raw (undecoded, unfolded) text of a header.
pub fn raw_header(m: &Message, name: &str) -> Option<String> {
    m.header_raw(name).map(unfold)
}

/// Decode RFC 2047 words in a header value (dec() in Python).
pub fn dec(v: &str) -> String {
    // decode_header: without a real encoded word the value comes back untouched (folds included)
    static ECRE: OnceLock<Regex> = OnceLock::new();
    if !re(&ECRE, r"=\?[^?]*?\?[qQbB]\?.*?\?=").is_match(v) {
        return py_strip(v).to_string();
    }
    let fake = format!("Subject: {}\r\n\r\n", v.replace("\r\n", "\r\n").trim_end());
    match MessageParser::default().parse(fake.as_bytes()).and_then(|m| m.subject().map(String::from)) {
        Some(s) => py_strip(&s).to_string(),
        None => py_strip(v).to_string(),
    }
}

/// addresses() of the Python: getaddresses([dec(v) if '=?' in v else v]) -> [(dec(name), addr)]
pub fn addresses(v: &str) -> Vec<(String, String)> {
    if v.is_empty() {
        return vec![];
    }
    let text = if v.contains("=?") { dec(v) } else { v.to_string() };
    crate::pyemail::getaddresses(&[&text]).into_iter().map(|(n, a)| (dec(&n), a)).filter(|(n, a)| !a.is_empty() || !n.is_empty()).collect()
}

/// The reader view's addresses (email.policy.default parses before decoding): names decoded one by one.
fn view_addresses(v: &str) -> Vec<(String, String)> {
    if v.is_empty() {
        return vec![];
    }
    crate::pyemail::getaddresses(&[&unfold(v)]).into_iter().map(|(n, a)| (dec(&n), a)).filter(|(n, a)| !a.is_empty() || !n.is_empty()).collect()
}

fn header_addresses(m: &Message, name: &str) -> Vec<(String, String)> {
    m.header_raw(name).map(view_addresses).unwrap_or_default()
}

fn pairs(v: &[(String, String)]) -> Value {
    Value::Array(v.iter().map(|(n, a)| json!([n, a])).collect())
}

/// parsedate_to_datetime(v).timestamp(); 0 when unreadable
pub fn parse_date(v: Option<&str>) -> f64 {
    match v {
        Some(v) if !v.trim().is_empty() => crate::pyemail::date_timestamp(v),
        _ => 0.0,
    }
}

/// header_row(): BODY[HEADER.FIELDS (...)] bytes -> a messages row
#[allow(clippy::too_many_arguments)]
pub fn header_row(raw_headers: &[u8], uid: i64, flags: &[String], internaldate: f64, size: i64, part: &str, att: bool, thrid: &str) -> Value {
    let mut hb = raw_headers.to_vec();
    if !hb.ends_with(b"\r\n\r\n") && !hb.ends_with(b"\n\n") {
        hb.extend_from_slice(b"\r\n");
    }
    let parsed = parse(&hb);
    // compat32: the raw header text, folding included
    let get = |name: &str| parsed.as_ref().and_then(|m| m.header_raw(name)).map(|v| v.trim_end_matches(['\r', '\n']).to_string());
    let frm = get("From").map(|v| addresses(&v)).unwrap_or_default();
    let rcpt = get("To").map(|v| addresses(&v)).unwrap_or_default();
    let cc = get("Cc").map(|v| addresses(&v)).unwrap_or_default();
    static ANGLE: OnceLock<Regex> = OnceLock::new();
    let refs_src = format!("{} {}", get("References").unwrap_or_default(), get("In-Reply-To").unwrap_or_default());
    let refs: Vec<&str> = re(&ANGLE, r"<[^>]+>").find_iter(&refs_src).map(|m| m.as_str()).collect();
    let fl: Vec<String> = flags.iter().map(|f| f.to_lowercase()).collect();
    let has = |f: &str| fl.iter().any(|x| x == f);
    let mut date = parse_date(get("Date").as_deref());
    if date == 0.0 {
        date = if internaldate != 0.0 { internaldate } else { now() };
    }
    if internaldate != 0.0 && date > internaldate + 86400.0 {
        date = internaldate;
    }
    let subject = parsed.as_ref().and_then(|m| m.header_raw("Subject")).map(dec).unwrap_or_default();
    json!({
        "uid": uid,
        "msgid": py_strip(&get("Message-ID").unwrap_or_default()),
        "thrid": thrid,
        "date": date,
        "from_name": frm.first().map(|x| x.0.clone()).unwrap_or_default(),
        "from_addr": frm.first().map(|x| x.1.clone()).unwrap_or_default(),
        "rcpt": pairs(&rcpt),
        "cc": pairs(&cc),
        "subject": subject,
        "snippet": "",
        "seen": has("\\seen"),
        "flagged": has("\\flagged"),
        "answered": has("\\answered"),
        "draft": has("\\draft"),
        "att": att,
        "size": size,
        "refs": refs.join(" "),
        "unsub": py_strip(&get("List-Unsubscribe").unwrap_or_default()),
        "part": part,
    })
}

pub fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

// ---------------------------------------------------------------- partial text parts (snippets)

/// binascii.a2b_qp
pub fn qp_decode(raw: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(raw.len());
    let mut i = 0;
    while i < raw.len() {
        if raw[i] == b'=' {
            if raw.get(i + 1) == Some(&b'\n') {
                i += 2;
                continue;
            }
            if raw.get(i + 1) == Some(&b'\r') && raw.get(i + 2) == Some(&b'\n') {
                i += 3;
                continue;
            }
            if let (Some(a), Some(b)) = (raw.get(i + 1), raw.get(i + 2)) {
                if a.is_ascii_hexdigit() && b.is_ascii_hexdigit() {
                    let h = |c: u8| (c as char).to_digit(16).unwrap() as u8;
                    out.push(h(*a) * 16 + h(*b));
                    i += 3;
                    continue;
                }
            }
            if i + 1 == raw.len() {
                // a trailing '=' is a soft break
                break;
            }
        }
        out.push(raw[i]);
        i += 1;
    }
    out
}

/// base64 that forgives junk and a cut in the middle (binascii.a2b_base64, non-strict)
pub fn b64_lenient(raw: &[u8]) -> Vec<u8> {
    let clean: Vec<u8> = raw.iter().copied().filter(|c| c.is_ascii_alphanumeric() || *c == b'+' || *c == b'/' || *c == b'=').collect();
    let cut = &clean[..clean.len() / 4 * 4];
    let mut out = vec![];
    for q in cut.chunks(4) {
        let pad = q.iter().filter(|&&c| c == b'=').count();
        let mut quad = [b'A'; 4];
        for (i, &c) in q.iter().enumerate() {
            quad[i] = if c == b'=' { b'A' } else { c };
        }
        if let Ok(d) = base64::engine::general_purpose::STANDARD.decode(quad) {
            out.extend_from_slice(&d[..3usize.saturating_sub(pad.min(2))]);
        }
    }
    out
}

/// bytes.decode(charset, 'replace') with Python's codecs for the common mail charsets
pub fn decode_charset(raw: &[u8], charset: &str) -> String {
    let cs = charset.trim().trim_matches('"').to_ascii_lowercase();
    match cs.as_str() {
        "us-ascii" | "ascii" | "ansi_x3.4-1968" => raw.iter().map(|&b| if b < 0x80 { b as char } else { '\u{fffd}' }).collect(),
        "iso-8859-1" | "latin1" | "latin-1" | "iso8859-1" | "l1" => raw.iter().map(|&b| b as char).collect(),
        "utf-8" | "utf8" | "" => String::from_utf8_lossy(raw).into_owned(),
        _ => match encoding_rs::Encoding::for_label(cs.as_bytes()) {
            Some(enc) => enc.decode_without_bom_handling(raw).0.into_owned(),
            None => String::from_utf8_lossy(raw).into_owned(),
        },
    }
}

/// part_text(): decoded text of a (partial) body part; HTML becomes plain text
pub fn part_text(data: &[u8], info: &Value) -> String {
    let enc = info["encoding"].as_str().unwrap_or("7bit");
    let charset = info["params"]["charset"].as_str().filter(|c| !c.is_empty()).unwrap_or("utf-8");
    let raw = match enc {
        "base64" => b64_lenient(data),
        "quoted-printable" => qp_decode(data),
        _ => data.to_vec(),
    };
    let txt = decode_charset(&raw, charset);
    if info["subtype"] == "html" {
        reader::html_to_text(&txt)
    } else {
        txt
    }
}

pub fn snippet_of_text(txt: &str) -> String {
    let mut lines = vec![];
    for ln in txt.lines() {
        let s = py_strip(ln);
        if s.starts_with('>') {
            continue;
        }
        if s == "--" || s == "-- " {
            break;
        }
        lines.push(s.to_string());
    }
    reader::snippet_of(&lines.join(" "), 180)
}

pub fn snippet_from_part(data: &[u8], info: &Value) -> String {
    snippet_of_text(&part_text(data, info))
}

// ---------------------------------------------------------------- the part walk

pub struct Part<'a> {
    pub p: &'a MessagePart<'a>,
    pub ctype: String,
}

impl<'a> Part<'a> {
    pub fn filename(&self) -> Option<String> {
        self.p.attachment_name().map(|s| dec(s)).filter(|s| !s.is_empty())
    }
    pub fn payload(&self) -> Vec<u8> {
        match &self.p.body {
            PartType::Message(m) => m.raw_message().to_vec(),
            _ => self.p.contents().to_vec(),
        }
    }
    fn text(&self) -> String {
        if let Some(t) = self.p.text_contents() {
            return t.to_string();
        }
        let cs = self.p.content_type().and_then(|c| c.attribute("charset")).unwrap_or("utf-8");
        decode_charset(self.p.contents(), cs)
    }
}

fn ctype_of(p: &MessagePart) -> String {
    match p.content_type() {
        Some(ct) => format!("{}/{}", ct.ctype(), ct.subtype().unwrap_or("plain")).to_lowercase(),
        None => match &p.body {
            PartType::Message(_) => "message/rfc822".into(),
            _ => "text/plain".into(),
        },
    }
}

/// Every leaf of msg.walk() in order (multiparts and attached-message containers are walked into).
fn leaves<'a>(m: &'a Message<'a>, idx: usize, out: &mut Vec<Part<'a>>) {
    let Some(p) = m.parts.get(idx) else { return };
    match &p.body {
        PartType::Multipart(kids) => {
            for &k in kids {
                leaves(m, k as usize, out);
            }
        }
        PartType::Message(inner) => {
            if !inner.parts.is_empty() {
                leaves(inner, 0, out);
            }
        }
        _ => out.push(Part { p, ctype: ctype_of(p) }),
    }
}

pub struct Walk<'a> {
    pub plain: Option<String>,
    pub html: Option<String>,
    pub cids: Vec<(String, Part<'a>)>,
    pub atts: Vec<Part<'a>>,
}

pub fn walk_parts<'a>(m: &'a Message<'a>) -> Walk<'a> {
    let mut all = vec![];
    leaves(m, 0, &mut all);
    let mut w = Walk { plain: None, html: None, cids: vec![], atts: vec![] };
    for part in all {
        let ctype = part.ctype.clone();
        let disp = part.p.content_disposition().map(|d| d.ctype().to_lowercase()).unwrap_or_default();
        let fname = part.filename();
        let cid = part.p.content_id().map(|c| py_strip(c).trim_matches(['<', '>']).to_string()).unwrap_or_default();
        if ctype == "message/rfc822"
            || disp == "attachment"
            || (fname.is_some() && !ctype.starts_with("text/") && !(!cid.is_empty() && ctype.starts_with("image/")))
        {
            w.atts.push(part);
            continue;
        }
        if ctype.starts_with("image/") && !cid.is_empty() {
            if disp == "attachment" {
                // (unreachable: attachments were taken above) kept for symmetry with the Python
            }
            match w.cids.iter().position(|(c, _)| *c == cid) {
                Some(i) => w.cids[i].1 = part,
                None => w.cids.push((cid, part)),
            }
            continue;
        }
        if ctype == "text/plain" && w.plain.is_none() {
            w.plain = Some(part.text());
        } else if ctype == "text/html" && w.html.is_none() {
            w.html = Some(part.text());
        } else if ctype == "text/calendar" || (fname.is_some() && ctype.starts_with("text/")) || !ctype.starts_with("text/") {
            w.atts.push(part);
        }
    }
    w
}

pub fn guess_extension(ctype: &str) -> Option<&'static str> {
    EXT_OF.iter().find(|(t, _)| *t == ctype).map(|(_, e)| *e)
}

/// os.path.splitext
fn py_splitext(p: &str) -> (&str, &str) {
    let sep = p.rfind('/').map_or(0, |i| i + 1);
    match p.rfind('.') {
        Some(dot) if dot > sep && p[sep..dot].chars().any(|c| c != '.') => (&p[..dot], &p[dot..]),
        _ => (p, ""),
    }
}

/// mimetypes.guess_type(path)[0]
pub fn guess_type(path: &str) -> Option<&'static str> {
    const SUFFIX: [(&str, &str); 6] = [(".svgz", ".svg.gz"), (".tgz", ".tar.gz"), (".taz", ".tar.gz"), (".tz", ".tar.gz"), (".tbz2", ".tar.bz2"), (".txz", ".tar.xz")];
    const ENCODINGS: [&str; 5] = [".gz", ".Z", ".bz2", ".xz", ".br"];
    let (mut base, mut ext) = {
        let (b, e) = py_splitext(path);
        (b.to_string(), e.to_string())
    };
    while let Some((_, to)) = SUFFIX.iter().find(|(k, _)| *k == ext.to_lowercase()) {
        let joined = base + to;
        let (b, e) = py_splitext(&joined);
        (base, ext) = (b.to_string(), e.to_string());
    }
    if ENCODINGS.contains(&ext.as_str()) {
        ext = py_splitext(&base).1.to_string();
    }
    let ext = ext.to_lowercase();
    TYPE_OF.binary_search_by(|(k, _)| (*k).cmp(ext.as_str())).ok().map(|i| TYPE_OF[i].1)
}

pub fn kind_of(ctype: &str, name: &str) -> &'static str {
    let lname = name.to_lowercase();
    let ext = match lname.rfind('.') {
        Some(i) if i > 0 && !lname[..i].ends_with('/') => &lname[i..],
        _ => "",
    };
    if ctype.starts_with("image/") {
        "image"
    } else if ctype == "application/pdf" || ext == ".pdf" {
        "pdf"
    } else if [".zip", ".rar", ".7z", ".tar", ".gz", ".xz", ".zst", ".bz2"].contains(&ext) {
        "archive"
    } else if [".doc", ".docx", ".odt", ".rtf", ".pages"].contains(&ext) {
        "doc"
    } else if [".xls", ".xlsx", ".ods", ".csv", ".numbers"].contains(&ext) {
        "sheet"
    } else if [".ppt", ".pptx", ".odp", ".key"].contains(&ext) {
        "slides"
    } else if ctype.starts_with("audio/") {
        "audio"
    } else if ctype.starts_with("video/") {
        "video"
    } else if ctype == "text/calendar" || ext == ".ics" {
        "calendar"
    } else if ctype == "message/rfc822" {
        "mail"
    } else {
        "file"
    }
}

pub fn attachment_info(part: &Part, i: usize) -> Value {
    let mut fname = part.filename().unwrap_or_default();
    let ctype = part.ctype.as_str();
    if ctype == "message/rfc822" && fname.is_empty() {
        let inner = match &part.p.body {
            PartType::Message(m) => m.subject().map(dec).unwrap_or_default(),
            _ => String::new(),
        };
        fname = if inner.is_empty() { "message".into() } else { inner };
        fname.push_str(".eml");
    }
    if fname.is_empty() {
        fname = format!("attachment-{}{}", i + 1, guess_extension(ctype).unwrap_or(""));
    }
    let size = part.payload().len();
    json!({"i": i, "name": fname, "type": ctype, "size": size, "kind": kind_of(ctype, &fname)})
}

/// (name, bytes) of attachment i
pub fn attachment_bytes(m: &Message, i: usize) -> Option<(String, String, Vec<u8>)> {
    let w = walk_parts(m);
    let part = w.atts.get(i)?;
    let info = attachment_info(part, i);
    Some((info["name"].as_str().unwrap_or("").to_string(), part.ctype.clone(), part.payload()))
}

pub fn text_of(raw: &[u8]) -> String {
    let Some(m) = parse(raw) else { return String::new() };
    let w = walk_parts(&m);
    if let Some(h) = &w.html {
        if w.plain.as_ref().is_none_or(|p| py_strip(p).chars().count() < 200) {
            return reader::html_to_text(h);
        }
    }
    w.plain.unwrap_or_default()
}

/// view(): full message bytes -> the reader pane's data
pub fn view(raw: &[u8], colors: &Value) -> Value {
    let lc = colors["link"].as_str().unwrap_or("#80d4db");
    let qc = colors["quote"].as_str().unwrap_or("#899393");
    let cb = colors["code"].as_str().unwrap_or("#252b2c");
    let Some(m) = parse(raw) else {
        return json!({"subject": "", "from": [], "to": [], "cc": [], "replyTo": [], "date": 0.0, "msgid": "", "refs": "", "unsub": "",
                      "unsubPost": "", "blocks": reader::text_blocks(&String::from_utf8_lossy(raw), lc, qc), "kind": "text", "remote": 0,
                      "attachments": [], "plain": String::from_utf8_lossy(raw), "html": ""});
    };
    let w = walk_parts(&m);
    let (mut blocks, kind) = match &w.html {
        Some(h) if !py_strip(h).is_empty() => {
            let mut b = reader::html_blocks(h, lc, qc, cb);
            if b.is_empty() {
                if let Some(p) = &w.plain {
                    b = reader::text_blocks(p, lc, qc);
                }
            }
            (b, "html")
        }
        _ => (reader::text_blocks(w.plain.as_deref().unwrap_or(""), lc, qc), "text"),
    };
    let mut remote = 0;
    for b in blocks.iter_mut() {
        if b["t"] == "img" {
            let src = b["src"].as_str().unwrap_or("").to_string();
            let l = src.to_lowercase();
            if l.starts_with("cid:") {
                b["cid"] = json!(src[4..].trim_matches(['<', '>']));
                b["src"] = json!("");
            } else if l.starts_with("data:") {
                b["data"] = json!(src);
                b["src"] = json!("");
            } else {
                remote += 1;
            }
        }
    }
    let used: Vec<String> = blocks.iter().filter_map(|b| b.get("cid").and_then(Value::as_str).map(String::from)).collect();
    if w.html.is_none() {
        for (cid, part) in &w.cids {
            if !used.contains(cid) {
                blocks.push(json!({"t": "img", "src": "", "cid": cid, "alt": part.filename().unwrap_or_default(), "href": "", "w": 0, "h": 0}));
            }
        }
    }
    let plain = match (&w.plain, &w.html) {
        (Some(p), _) => p.clone(),
        (None, Some(h)) => reader::html_to_text(h),
        _ => String::new(),
    };
    json!({
        "subject": m.header_raw("Subject").map(dec).unwrap_or_default(),
        "from": pairs(&header_addresses(&m, "From")),
        "to": pairs(&header_addresses(&m, "To")),
        "cc": pairs(&header_addresses(&m, "Cc")),
        "replyTo": pairs(&header_addresses(&m, "Reply-To")),
        "date": parse_date(raw_header(&m, "Date").as_deref()),
        "msgid": dec(&raw_header(&m, "Message-ID").unwrap_or_default()),
        "refs": dec(&raw_header(&m, "References").unwrap_or_default()),
        "unsub": dec(&raw_header(&m, "List-Unsubscribe").unwrap_or_default()),
        "unsubPost": dec(&raw_header(&m, "List-Unsubscribe-Post").unwrap_or_default()),
        "blocks": blocks,
        "kind": kind,
        "remote": remote,
        "attachments": w.atts.iter().enumerate().map(|(i, p)| attachment_info(p, i)).collect::<Vec<_>>(),
        "plain": plain,
        "html": w.html.clone().unwrap_or_default(),
    })
}

/// (content type, bytes) of an inline image
pub fn cid_bytes(raw: &[u8], cid: &str) -> Option<(String, Vec<u8>)> {
    let m = parse(raw)?;
    let w = walk_parts(&m);
    w.cids.iter().find(|(c, _)| c == cid).map(|(_, p)| (p.ctype.clone(), p.payload()))
}

/// The message as a standalone, script-free HTML page (Open in browser).
pub fn original_html(raw: &[u8], allow_remote: bool) -> String {
    let img = if allow_remote { "img-src data: https: http:;" } else { "img-src data:;" };
    let csp = format!("default-src 'none'; {img} style-src 'unsafe-inline' https:; font-src https: data:;");
    page_html(raw, &csp, "")
}

/// The message for the reader's web view (glass-mail-web): like original_html, but without
/// remote styles or fonts unless images are allowed (they can track too), and with the
/// reader's stylesheet first in <head> so the mail's own styles win where it has them.
pub fn web_html(raw: &[u8], allow_remote: bool, css: &str) -> String {
    let csp = if allow_remote {
        "default-src 'none'; img-src data: https: http:; style-src 'unsafe-inline' https:; font-src https: data:;"
    } else {
        "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:;"
    };
    page_html(raw, csp, &format!("<style>{}</style>", css.replace("</", "<\\/")))
}

fn page_html(raw: &[u8], csp: &str, extra_head: &str) -> String {
    let Some(m) = parse(raw) else { return String::new() };
    let w = walk_parts(&m);
    let mut htm = w
        .html
        .clone()
        .unwrap_or_else(|| format!("<pre style=\"white-space:pre-wrap;font-family:sans-serif\">{}</pre>", escape(w.plain.as_deref().unwrap_or(""), true)));
    static CID: OnceLock<fancy_regex::Regex> = OnceLock::new();
    let cid_re = CID.get_or_init(|| fancy_regex::Regex::new(r#"(?i)(src\s*=\s*["']?)cid:<?([^"'\s>]+?)>?(?=["'\s>])"#).unwrap());
    htm = cid_re
        .replace_all(&htm, |c: &fancy_regex::Captures| match w.cids.iter().find(|(id, _)| id == &c[2]) {
            Some((_, p)) => format!("{}data:{};base64,{}", &c[1], p.ctype, base64::engine::general_purpose::STANDARD.encode(p.payload())),
            None => c[0].to_string(),
        })
        .into_owned();
    let subject = m.header_raw("Subject").map(dec).unwrap_or_default();
    let head = format!("<meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"{csp}\"><title>{}</title>{extra_head}", escape(&subject, true));
    static SCRIPT: OnceLock<Regex> = OnceLock::new();
    htm = re(&SCRIPT, r"(?is)<script\b.*?</script>").replace_all(&htm, "").into_owned();
    static HEAD: OnceLock<Regex> = OnceLock::new();
    let hr = re(&HEAD, r"(?i)<head[^>]*>");
    if let Some(mm) = hr.find(&htm) {
        return format!("{}{}{}", &htm[..mm.end()], head, &htm[mm.end()..]);
    }
    format!("<!doctype html><html><head>{head}</head><body>{htm}</body></html>")
}

// ---------------------------------------------------------------- writing

/// str.splitlines()
pub fn py_splitlines(s: &str) -> Vec<&str> {
    let mut out = vec![];
    let mut start = 0;
    let mut it = s.char_indices().peekable();
    while let Some((i, c)) = it.next() {
        if matches!(c, '\n' | '\r' | '\x0b' | '\x0c' | '\x1c' | '\x1d' | '\x1e' | '\u{85}' | '\u{2028}' | '\u{2029}') {
            out.push(&s[start..i]);
            let mut end = i + c.len_utf8();
            if c == '\r' && it.peek().map(|x| x.1) == Some('\n') {
                it.next();
                end += 1;
            }
            start = end;
        }
    }
    if start < s.len() {
        out.push(&s[start..]);
    }
    out
}

/// email.utils.formataddr((name, addr)) if name else addr
pub fn fmt_addr(name: &str, addr: &str) -> String {
    if name.is_empty() { addr.to_string() } else { crate::pyemail::formataddr(name, addr) }
}

/// 'Ann <a@x>, b@y; c@z' -> [(name, addr)] (only things that look like addresses)
pub fn parse_rcpt(text: &str) -> Vec<(String, String)> {
    static OK: OnceLock<Regex> = OnceLock::new();
    let ok = re(&OK, r"^[^@\s]+@[^@\s]+\.[^@\s]+$");
    crate::pyemail::getaddresses(&[&text.replace(';', ",")])
        .into_iter()
        .map(|(n, a)| (py_strip(&n).to_string(), py_strip(&a).to_string()))
        .filter(|(_, a)| ok.is_match(a))
        .collect()
}

pub fn reply_subject(s: &str, prefix: &str) -> String {
    static RE_: OnceLock<Regex> = OnceLock::new();
    static FWD: OnceLock<Regex> = OnceLock::new();
    if prefix == "Re" && re(&RE_, r"(?i)^\s*(re|aw|sv|ответ)\s*:").is_match(s) {
        return s.to_string();
    }
    if prefix == "Fwd" && re(&FWD, r"(?i)^\s*(fwd?|wg|пересл)\s*:").is_match(s) {
        return s.to_string();
    }
    format!("{prefix}: {s}")
}

/// Plain text compose body -> a simple HTML alternative (links, quotes).
pub fn text_to_html(body: &str) -> String {
    let mut out = vec![];
    let mut quote = 0usize;
    for ln in body.split('\n') {
        let b = ln.as_bytes();
        let (mut i, mut depth) = (0, 0);
        while i < b.len() && b[i] == b'>' {
            depth += 1;
            i += 1;
            if let Some(c) = ln[i..].chars().next() {
                if crate::htmlparser::py_space(c) {
                    i += c.len_utf8();
                }
            }
        }
        let txt = if depth != 0 { &ln[i..] } else { ln };
        while quote < depth {
            out.push("<blockquote style=\"margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex\">".to_string());
            quote += 1;
        }
        while quote > depth {
            out.push("</blockquote>".into());
            quote -= 1;
        }
        let e = escape(txt, true);
        let e = reader::url_re().replace_all(&e, |c: &regex::Captures| format!("<a href=\"{0}\">{0}</a>", &c[1])).into_owned();
        out.push(format!("{e}<br>"));
    }
    out.extend(std::iter::repeat_n("</blockquote>".to_string(), quote));
    format!("<div dir=\"auto\">{}</div>", out.join("\n"))
}

fn text_part(ctype: &str, body: &str, mime_version: bool) -> Vec<u8> {
    let (cte, payload) = pyfold::encode_text(body);
    let mut h = pyfold::content_header("Content-Type", ctype, &[("charset", "utf-8")]);
    h += &format!("Content-Transfer-Encoding: {cte}\r\n");
    if mime_version {
        h += "MIME-Version: 1.0\r\n";
    }
    let mut out = h.into_bytes();
    out.extend_from_slice(b"\r\n");
    out.extend(pyfold::crlf(&payload));
    out
}

fn attachment_part(data: &[u8], ctype: &str, name: &str) -> Vec<u8> {
    let mut h = pyfold::content_header("Content-Type", ctype, &[]);
    h += "Content-Transfer-Encoding: base64\r\n";
    h += &pyfold::content_header("Content-Disposition", "attachment", &[("filename", name)]);
    h += "MIME-Version: 1.0\r\n\r\n";
    let mut out = h.into_bytes();
    out.extend(pyfold::crlf(pyfold::b64_body(data).as_bytes()));
    out
}

/// Generator._handle_multipart: the Content-Type header, a blank line and the parts
fn multipart(subtype: &str, parts: &[Vec<u8>]) -> Vec<u8> {
    let b = pyfold::boundary();
    let mut out = pyfold::content_header("Content-Type", &format!("multipart/{subtype}"), &[("boundary", &b)]).into_bytes();
    out.extend_from_slice(format!("\r\n--{b}\r\n").as_bytes());
    for (i, p) in parts.iter().enumerate() {
        if i > 0 {
            out.extend_from_slice(format!("\r\n--{b}\r\n").as_bytes());
        }
        out.extend_from_slice(p);
    }
    out.extend_from_slice(format!("\r\n--{b}--\r\n").as_bytes());
    out
}

pub fn formatdate_local(t: f64) -> String {
    let tt = t as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&tt, &mut tm) };
    const D: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    const M: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    let off = tm.tm_gmtoff / 60;
    format!(
        "{}, {:02} {} {} {:02}:{:02}:{:02} {}{:02}{:02}",
        D[tm.tm_wday as usize],
        tm.tm_mday,
        M[tm.tm_mon as usize],
        tm.tm_year + 1900,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec,
        if off < 0 { '-' } else { '+' },
        off.abs() / 60,
        off.abs() % 60
    )
}

/// email.utils.make_msgid(domain=...)
pub fn make_msgid(domain: &str) -> String {
    let mut r = [0u8; 8];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        use std::io::Read;
        let _ = f.read_exact(&mut r);
    }
    format!("<{}.{}.{}@{domain}>", (now() * 100.0) as u64, std::process::id(), u64::from_le_bytes(r))
}

/// build(): -> (message bytes, recipient addresses)
pub fn build(acc: &Value, d: &Value, attachments: &[String], forwarded: &[(String, String, Vec<u8>)]) -> std::io::Result<(Vec<u8>, Vec<String>)> {
    let s = |k: &str| d[k].as_str().unwrap_or("").to_string();
    let email = acc["email"].as_str().unwrap_or("");
    let to = parse_rcpt(&s("to"));
    let cc = parse_rcpt(&s("cc"));
    let bcc = parse_rcpt(&s("bcc"));
    for k in ["subject", "inReplyTo"] {
        // EmailPolicy.header_store_parse
        if py_splitlines(&s(k)).len() > 1 {
            return Err(std::io::Error::other("Header values may not contain linefeed or carriage return characters"));
        }
    }
    let name = acc["name"].as_str().unwrap_or("");
    let mut h = pyfold::header("From", vec![pyfold::address_list(&[(name.to_string(), email.to_string())])]);
    if !to.is_empty() {
        h += &pyfold::header("To", vec![pyfold::address_list(&to)]);
    }
    if !cc.is_empty() {
        h += &pyfold::header("Cc", vec![pyfold::address_list(&cc)]);
    }
    h += &pyfold::unstructured_header("Subject", &s("subject"));
    h += &pyfold::unstructured_header("Date", &formatdate_local(now()));
    let dom = email.rsplit('@').next().unwrap_or("localhost");
    h += &pyfold::header("Message-ID", vec![pyfold::message_ids(&make_msgid(dom))]);
    let irt = s("inReplyTo");
    if !irt.is_empty() {
        h += &pyfold::header("In-Reply-To", vec![pyfold::message_ids(&irt)]);
        let mut refs: Vec<String> = s("refs").split_whitespace().map(String::from).collect();
        if !refs.contains(&irt) {
            refs.push(irt.clone());
        }
        let start = refs.len().saturating_sub(20);
        h += &pyfold::header("References", vec![pyfold::message_ids(&refs[start..].join(" "))]);
    }
    h += "User-Agent: Glass Mail\r\nMIME-Version: 1.0\r\n";
    let body = s("body");
    let alt = multipart("alternative", &[text_part("text/plain", &body, false), text_part("text/html", &text_to_html(&body), true)]);
    let mut parts = vec![alt];
    for p in attachments {
        let data = std::fs::read(p)?;
        let name = std::path::Path::new(p).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "attachment".into());
        let ctype = guess_type(p).unwrap_or("application/octet-stream");
        parts.push(attachment_part(&data, ctype, &name));
    }
    for (name, ctype, data) in forwarded {
        let ct = if ctype.starts_with("message/") || ctype.is_empty() { "application/octet-stream" } else { ctype.as_str() };
        parts.push(attachment_part(data, ct, name));
    }
    let mut out = h.into_bytes();
    if parts.len() == 1 {
        out.extend(parts.pop().unwrap());
    } else {
        out.extend(multipart("mixed", &parts));
    }
    let rcpts = to.iter().chain(cc.iter()).chain(bcc.iter()).map(|(_, a)| a.clone()).collect();
    Ok((out, rcpts))
}

/// strftime('%a, %d %b %Y at %H:%M', localtime(t))
fn when(t: f64) -> String {
    let tt = t as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&tt, &mut tm) };
    const D: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    const M: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    format!("{}, {:02} {} {} at {:02}:{:02}", D[tm.tm_wday as usize], tm.tm_mday, M[tm.tm_mon as usize], tm.tm_year + 1900, tm.tm_hour, tm.tm_min)
}

#[allow(dead_code)]
pub fn quote_text(v: &Value) -> String {
    let date = v["date"].as_f64().unwrap_or(0.0);
    let w = if date != 0.0 { when(date) } else { String::new() };
    let who = v["from"].get(0).map(|f| fmt_addr(f[0].as_str().unwrap_or(""), f[1].as_str().unwrap_or(""))).unwrap_or_else(|| "someone".into());
    let body = v["plain"].as_str().unwrap_or("").trim_end();
    let quoted: Vec<String> = body.split('\n').map(|ln| if ln.is_empty() { ">".into() } else { format!("> {ln}") }).collect();
    format!("\n\nOn {w}, {who} wrote:\n{}\n", quoted.join("\n"))
}

