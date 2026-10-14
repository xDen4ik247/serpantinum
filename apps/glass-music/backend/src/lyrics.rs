//! Lyrics for a track (port of lyrics.py): a synced .lrc next to it, else lyrics embedded in the
//! file's tags (MP4 ©lyr, ID3 USLT, FLAC Vorbis LYRICS), else a plain .txt next to it.
use crate::pyjson;
use crate::pystr;
use regex::Regex;
use serde_json::{json, Value};
use std::io::{Read, Seek, SeekFrom};
use std::sync::OnceLock;

const MAX_TAG_BYTES: u64 = 64 << 20;
pub const MARK: &str = "Glass Music";

struct Res {
    tag: Regex,
    word: Regex,
    meta: Regex,
    origin: Regex,
    offset: Regex,
}

/// Python's \s for str patterns
const S: &str = r"[\s\x1c-\x1f]";

fn res() -> &'static Res {
    static R: OnceLock<Res> = OnceLock::new();
    R.get_or_init(|| Res {
        tag: Regex::new(r"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]").unwrap(),
        word: Regex::new(r"<(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)>").unwrap(),
        meta: Regex::new(&format!(r"^{S}*\[[a-zA-Z#]+:[^\]]*\]{S}*$")).unwrap(),
        origin: Regex::new(&format!(r"(?m)^{S}*\[re:{S}*{MARK}{S}*·{S}*([^\]]+)\]")).unwrap(),
        offset: Regex::new(&format!(r"(?i)\[offset:{S}*([+-]?\d+)\]")).unwrap(),
    })
}

/// int() of a run of (any script's) decimal digits
fn py_int(s: &str) -> i64 {
    let mut n: i64 = 0;
    for c in s.chars() {
        n = n * 10 + digit(c) as i64;
    }
    n
}

fn digit(c: char) -> u32 {
    if let Some(d) = c.to_digit(10) {
        return d;
    }
    // every Unicode decimal digit block runs 0..9 from a code point ending in a multiple of 10 offset
    let u = c as u32;
    let start = crate::pytables::DECIMAL.iter().find(|(a, b)| *a <= u && u <= *b).map(|r| r.0).unwrap_or(u);
    (u - start) % 10
}

fn secs(m: &str, s: &str) -> f64 {
    let s: String = s.chars().map(|c| if c == ':' { '.' } else if c == '.' { '.' } else { char::from_digit(digit(c), 10).unwrap() }).collect();
    py_int(m) as f64 * 60.0 + s.parse::<f64>().unwrap_or(0.0)
}

/// Identity of a lyrics text, independent of timing and of .lrc vs tag copies.
pub fn text_hash(lines: &[Value]) -> String {
    let words: Vec<String> = lines
        .iter()
        .filter_map(|r| r["x"].as_str().filter(|x| !x.is_empty()))
        .map(|x| pystr::split(&pystr::lower(x)).join(" "))
        .collect();
    sha1_smol::Sha1::from(words.join("\n").as_bytes()).digest().to_string()[..16].to_string()
}

pub fn origin_of(text: &str) -> String {
    res().origin.captures(text).map(|c| pystr::strip(&c[1]).to_string()).unwrap_or_default()
}

/// str.splitlines()
pub fn splitlines(s: &str) -> Vec<&str> {
    let mut out = vec![];
    let mut start = 0;
    let mut it = s.char_indices().peekable();
    while let Some((i, c)) = it.next() {
        if matches!(c, '\n' | '\r' | '\x0b' | '\x0c' | '\x1c' | '\x1d' | '\x1e' | '\u{85}' | '\u{2028}' | '\u{2029}') {
            out.push(&s[start..i]);
            let mut end = i + c.len_utf8();
            if c == '\r' && it.peek().is_some_and(|(_, n)| *n == '\n') {
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

/// Synced lines, sorted; repeated empty lines collapsed; a leading blank at 0 s dropped.
pub fn parse_lrc(text: &str) -> Vec<Value> {
    let r = res();
    let offset = r.offset.captures(text).map(|c| {
        let s = &c[1];
        let (neg, d) = match s.strip_prefix('-') {
            Some(d) => (true, d),
            None => (false, s.strip_prefix('+').unwrap_or(s)),
        };
        let v = py_int(d) as f64 / 1000.0;
        if neg { -v } else { v }
    });
    let offset = offset.unwrap_or(0.0);
    let mut out: Vec<(f64, Value)> = vec![];
    for line in splitlines(text) {
        let times: Vec<f64> = r.tag.captures_iter(line).map(|c| secs(&c[1], &c[2])).collect();
        if times.is_empty() {
            continue;
        }
        let body = r.tag.replace_all(line, "");
        let mut words: Vec<(f64, usize)> = vec![];
        let mut x = String::new();
        let mut pos = 0;
        for wm in r.word.captures_iter(&body) {
            let m0 = wm.get(0).unwrap();
            x.push_str(&body[pos..m0.start()]);
            words.push((pyjson::round_n((secs(&wm[1], &wm[2]) - offset).max(0.0), 3), pystr::clen(&x)));
            pos = m0.end();
        }
        x.push_str(&body[pos..]);
        let lead = pystr::clen(&x) - pystr::clen(pystr::lstrip(&x));
        let x = pystr::strip(&x).to_string();
        let xl = pystr::clen(&x) as i64;
        let words: Vec<Value> = words.iter().map(|(t, c)| json!([pyjson::f(*t), (*c as i64 - lead as i64).clamp(0, xl.max(0)).min(xl)])).collect();
        for t in &times {
            let tv = pyjson::round_n((t - offset).max(0.0), 3);
            let mut o = serde_json::Map::new();
            o.insert("t".into(), pyjson::f(tv));
            o.insert("x".into(), json!(x));
            if !words.is_empty() && times.len() == 1 {
                o.insert("w".into(), Value::Array(words.clone()));
            }
            out.push((tv, Value::Object(o)));
        }
    }
    out.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    let mut tidy: Vec<Value> = vec![];
    for (t, r) in out {
        if r["x"] == "" {
            if tidy.is_empty() && t < 0.5 {
                continue;
            }
            if tidy.last().is_some_and(|l| l["x"] == "") {
                continue;
            }
        }
        tidy.push(r);
    }
    tidy
}

/// Unsynced lyrics: one entry per line, t = -1, single empty entries between stanzas.
pub fn parse_plain(text: &str) -> Vec<Value> {
    let text = text.replace("\r\n", "\n").replace('\r', "\n");
    let mut out: Vec<Value> = vec![];
    for line in text.split('\n') {
        if res().meta.is_match(line) {
            continue;
        }
        let x = pystr::strip(line);
        if x.is_empty() && out.last().is_none_or(|l| l["x"] == "") {
            continue;
        }
        out.push(json!({"t": -1, "x": x}));
    }
    while out.last().is_some_and(|l| l["x"] == "") {
        out.pop();
    }
    out
}

/// (lines, synced) for text that may or may not carry LRC time stamps.
pub fn parse_any(text: &str) -> (Vec<Value>, bool) {
    if res().tag.is_match(text) {
        let lines = parse_lrc(text);
        if lines.iter().any(|r| r["x"] != "") {
            return (lines, true);
        }
    }
    (parse_plain(&res().tag.replace_all(text, "")), false)
}

// ---------------------------------------------------------------- embedded tags
fn be32(d: &[u8], p: usize) -> Option<u64> {
    d.get(p..p + 4).map(|b| u32::from_be_bytes(b.try_into().unwrap()) as u64)
}

fn be64(d: &[u8], p: usize) -> Option<u64> {
    d.get(p..p + 8).map(|b| u64::from_be_bytes(b.try_into().unwrap()))
}

fn le32(d: &[u8], p: usize) -> Option<u64> {
    d.get(p..p + 4).map(|b| u32::from_le_bytes(b.try_into().unwrap()) as u64)
}

fn slice(d: &[u8], a: usize, b: usize) -> &[u8] {
    let b = b.min(d.len());
    if a >= b { &[] } else { &d[a..b] }
}

/// The ©lyr path walk: boxes are read one at a time like the Python generator, so a malformed box
/// only matters once the walk reaches it. None = malformed (struct.error).
fn find_box(data: &[u8], start: usize, end: usize, path: &[&[u8; 4]]) -> Option<Option<(usize, usize)>> {
    let mut p = start;
    while p + 8 <= end {
        let mut size = be32(data, p)? as usize;
        let kind: [u8; 4] = data.get(p + 4..p + 8)?.try_into().ok()?;
        let mut hdr = 8;
        if size == 1 {
            size = be64(data, p + 8)? as usize;
            hdr = 16;
        } else if size == 0 {
            size = end - p;
        }
        if size < hdr {
            break;
        }
        let (mut a, b) = (p + hdr, end.min(p.saturating_add(size)));
        p = p.saturating_add(size);
        if &kind == path[0] {
            if path.len() == 1 {
                return Some(Some((a, b)));
            }
            if &kind == b"meta" && slice(data, a + 4, a + 8) != b"hdlr" {
                a += 4; // full box (iTunes): version + flags
            }
            if let Some(r) = find_box(data, a, b, &path[1..])? {
                return Some(Some(r));
            }
        }
    }
    Some(None)
}

fn mp4_lyrics(fh: &mut std::fs::File) -> Option<String> {
    let flen = fh.seek(SeekFrom::End(0)).ok()?;
    let mut p: u64 = 0;
    let mut moov: Vec<u8> = vec![];
    while p + 8 <= flen {
        fh.seek(SeekFrom::Start(p)).ok()?;
        let mut h = vec![];
        fh.by_ref().take(16).read_to_end(&mut h).ok()?;
        if h.len() < 8 {
            break;
        }
        let mut size = be32(&h, 0)?;
        if size == 1 && h.len() >= 16 {
            size = be64(&h, 8)?;
        } else if size == 0 {
            size = flen - p;
        }
        if size < 8 {
            break;
        }
        if &h[4..8] == b"moov" {
            if size > MAX_TAG_BYTES {
                return Some(String::new());
            }
            fh.seek(SeekFrom::Start(p)).ok()?;
            fh.by_ref().take(size).read_to_end(&mut moov).ok()?;
            break;
        }
        p += size;
    }
    if moov.is_empty() {
        return Some(String::new());
    }
    let start = if be32(&moov, 0)? == 1 { 16 } else { 8 };
    match find_box(&moov, start, moov.len(), &[b"udta", b"meta", b"ilst", b"\xa9lyr", b"data"])? {
        None => Some(String::new()),
        Some((a, b)) => Some(String::from_utf8_lossy(slice(&moov, a + 8, b)).into_owned()),
    }
}

fn syncsafe(b: &[u8]) -> Option<u64> {
    let b = b.get(..4)?;
    Some(((b[0] as u64) << 21) | ((b[1] as u64) << 14) | ((b[2] as u64) << 7) | b[3] as u64)
}

/// bytes.decode("utf-16" / "utf-16-be", "replace")
fn utf16(b: &[u8], be: bool) -> String {
    let (mut b, mut be) = (b, be);
    if !be || b.len() >= 2 {
        if b.starts_with(&[0xff, 0xfe]) && !be {
            b = &b[2..];
        } else if b.starts_with(&[0xfe, 0xff]) && !be {
            b = &b[2..];
            be = true;
        }
    }
    let units: Vec<u16> = b.chunks_exact(2).map(|c| if be { u16::from_be_bytes([c[0], c[1]]) } else { u16::from_le_bytes([c[0], c[1]]) }).collect();
    let mut s: String = char::decode_utf16(units).map(|r| r.unwrap_or('\u{fffd}')).collect();
    if b.len() % 2 == 1 {
        s.push('\u{fffd}');
    }
    s
}

fn id3_lyrics(fh: &mut std::fs::File) -> Option<String> {
    fh.seek(SeekFrom::Start(0)).ok()?;
    let mut h = vec![];
    fh.by_ref().take(10).read_to_end(&mut h).ok()?;
    if h.len() < 10 || &h[..3] != b"ID3" || !(h[3] == 3 || h[3] == 4) {
        return Some(String::new());
    }
    let (ver, flags, size) = (h[3], h[5], syncsafe(&h[6..10])?);
    let mut data = vec![];
    fh.by_ref().take(size.min(MAX_TAG_BYTES)).read_to_end(&mut data).ok()?;
    if flags & 0x80 != 0 {
        // whole-tag unsynchronisation
        let mut o = Vec::with_capacity(data.len());
        let mut i = 0;
        while i < data.len() {
            o.push(data[i]);
            if data[i] == 0xff && data.get(i + 1) == Some(&0) {
                i += 1;
            }
            i += 1;
        }
        data = o;
    }
    let mut p: usize = 0;
    if flags & 0x40 != 0 {
        p = if ver == 4 { syncsafe(&data)? as usize } else { be32(&data, 0)? as usize + 4 };
    }
    while p + 10 <= data.len() {
        let fid = &data[p..p + 4];
        if fid.iter().all(|&b| b == 0) {
            break;
        }
        let fsize = if ver == 4 { syncsafe(&data[p + 4..p + 8])? } else { be32(&data, p + 4)? } as usize;
        let body = slice(&data, p + 10, p + 10 + fsize);
        p += 10 + fsize;
        if fid != b"USLT" || body.len() < 5 {
            continue;
        }
        let (enc, rest) = (body[0], &body[4..]);
        let text = if enc == 1 || enc == 2 {
            let mut i = 0;
            while i + 1 < rest.len() && &rest[i..i + 2] != b"\x00\x00" {
                i += 2;
            }
            utf16(slice(rest, i + 2, rest.len()), enc == 2)
        } else {
            let t = match rest.iter().position(|&b| b == 0) {
                Some(i) => &rest[i + 1..],
                None => &[][..],
            };
            if enc == 0 { t.iter().map(|&b| b as char).collect() } else { String::from_utf8_lossy(t).into_owned() }
        };
        return Some(text.trim_end_matches('\0').to_string());
    }
    Some(String::new())
}

fn flac_lyrics(fh: &mut std::fs::File) -> Option<String> {
    fh.seek(SeekFrom::Start(0)).ok()?;
    let mut magic = vec![];
    fh.by_ref().take(4).read_to_end(&mut magic).ok()?;
    if magic != b"fLaC" {
        return Some(String::new());
    }
    loop {
        let mut h = vec![];
        fh.by_ref().take(4).read_to_end(&mut h).ok()?;
        if h.len() < 4 {
            return Some(String::new());
        }
        let (last, kind, size) = (h[0] & 0x80, h[0] & 0x7f, u32::from_be_bytes([0, h[1], h[2], h[3]]) as u64);
        if kind != 4 {
            fh.seek(SeekFrom::Current(size as i64)).ok()?;
            if last != 0 {
                return Some(String::new());
            }
            continue;
        }
        let mut d = vec![];
        fh.by_ref().take(size).read_to_end(&mut d).ok()?;
        let vlen = le32(&d, 0)? as usize;
        let mut p = 4 + vlen;
        let n = le32(&d, p)?;
        p += 4;
        let mut found: std::collections::HashMap<String, String> = std::collections::HashMap::new();
        for _ in 0..n {
            let ln = le32(&d, p)? as usize;
            let kv = String::from_utf8_lossy(slice(&d, p + 4, p + 4 + ln)).into_owned();
            p += 4 + ln;
            let (k, v) = kv.split_once('=').unwrap_or((&kv, ""));
            let ku = k.to_uppercase();
            if ku == "LYRICS" || ku == "UNSYNCEDLYRICS" || ku == "SYNCEDLYRICS" {
                found.insert(ku, v.to_string());
            }
        }
        for k in ["SYNCEDLYRICS", "LYRICS", "UNSYNCEDLYRICS"] {
            if let Some(v) = found.get(k).filter(|v| !v.is_empty()) {
                return Some(v.clone());
            }
        }
        return Some(String::new());
    }
}

pub fn embedded(path: &str) -> String {
    let Ok(mut fh) = std::fs::File::open(path) else { return String::new() };
    let mut head = vec![];
    if fh.by_ref().take(12).read_to_end(&mut head).is_err() {
        return String::new();
    }
    let r = if head.starts_with(b"ID3") {
        id3_lyrics(&mut fh)
    } else if head.starts_with(b"fLaC") {
        flac_lyrics(&mut fh)
    } else if head.get(4..8) == Some(b"ftyp") {
        mp4_lyrics(&mut fh)
    } else {
        Some(String::new())
    };
    r.unwrap_or_default()
}

// ---------------------------------------------------------------- entry point
/// open(path, encoding="utf-8", errors="replace").read(): universal newlines
pub fn read(path: &str) -> Option<String> {
    let b = std::fs::read(path).ok()?;
    Some(String::from_utf8_lossy(&b).replace("\r\n", "\n").replace('\r', "\n"))
}

/// Absolute path of a library-relative song (or a file:// one); "" for streams.
pub fn song_path(music_dir: &str, rel: &str) -> String {
    if let Some(p) = rel.strip_prefix("file://").filter(|_| rel.starts_with("file:///")) {
        return p.to_string();
    }
    if rel.is_empty() || rel.contains("://") {
        return String::new();
    }
    pystr::join(music_dir, rel)
}

fn pack(text: &str, lines: Vec<Value>, synced: bool, source: &str) -> Value {
    let h = text_hash(&lines);
    json!({"lines": lines, "synced": synced, "source": source, "origin": origin_of(text), "hash": h})
}

pub fn empty() -> Value {
    json!({"lines": [], "synced": false, "source": "", "origin": "", "hash": ""})
}

/// Best lyrics for a song file: synced .lrc, synced tag, then plain ones.
pub fn load_path(path: &str, skip: &std::collections::HashSet<String>) -> Value {
    if path.is_empty() {
        return empty();
    }
    let stem = pystr::splitext(path).0;
    let mut fallback: Option<Value> = None;
    for source in ["lrc", "embedded", "txt"] {
        let text = match source {
            "lrc" => read(&format!("{stem}.lrc")),
            "embedded" => Some(embedded(path)),
            _ => read(&format!("{stem}.txt")),
        };
        let Some(text) = text else { continue };
        if pystr::strip(&text).is_empty() {
            continue;
        }
        let (lines, synced) = parse_any(&text);
        if lines.is_empty() || skip.contains(&text_hash(&lines)) {
            continue;
        }
        if synced {
            return pack(&text, lines, true, source);
        }
        if fallback.is_none() {
            fallback = Some(pack(&text, lines, false, source));
        }
    }
    fallback.unwrap_or_else(empty)
}
