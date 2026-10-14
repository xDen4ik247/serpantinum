//! Python's str semantics where the backend's output depends on them: casefold(), lower(),
//! isspace() / strip() / split(), the re module's \w, and os.path.
use crate::pytables::{CASEFOLD, DECIMAL, LOWER, SPACE, WORD};

fn in_ranges(t: &[(u32, u32)], c: char) -> bool {
    let c = c as u32;
    t.binary_search_by(|&(a, b)| if b < c { std::cmp::Ordering::Less } else if a > c { std::cmp::Ordering::Greater } else { std::cmp::Ordering::Equal })
        .is_ok()
}

fn mapped(t: &'static [(u32, &'static str)], c: char) -> Option<&'static str> {
    t.binary_search_by_key(&(c as u32), |e| e.0).ok().map(|i| t[i].1)
}

/// re's \w for str patterns (str.isalnum() or "_")
pub fn is_word(c: char) -> bool {
    in_ranges(WORD, c)
}

/// str.isdecimal() (re's \\d)
pub fn is_decimal(c: char) -> bool {
    in_ranges(DECIMAL, c)
}

/// str.isspace()
pub fn is_space(c: char) -> bool {
    in_ranges(SPACE, c)
}

pub fn strip(s: &str) -> &str {
    s.trim_matches(is_space)
}

pub fn lstrip(s: &str) -> &str {
    s.trim_start_matches(is_space)
}

/// str.split() with no arguments
pub fn split(s: &str) -> Vec<&str> {
    s.split(is_space).filter(|w| !w.is_empty()).collect()
}

pub fn casefold(s: &str) -> String {
    let mut o = String::with_capacity(s.len());
    for c in s.chars() {
        match mapped(CASEFOLD, c) {
            Some(m) => o.push_str(m),
            None => o.push(c),
        }
    }
    o
}

/// str.lower(), including the final-sigma rule
pub fn lower(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut o = String::with_capacity(s.len());
    for (i, &c) in chars.iter().enumerate() {
        if c == 'Σ' {
            o.push(if final_sigma(&chars, i) { 'ς' } else { 'σ' });
            continue;
        }
        match mapped(LOWER, c) {
            Some(m) => o.push_str(m),
            None => o.push(c),
        }
    }
    o
}

fn cased(c: char) -> bool {
    c.is_lowercase() || c.is_uppercase() || mapped(LOWER, c).is_some()
}

fn case_ignorable(c: char) -> bool {
    matches!(c, '\'' | '.' | ':' | '^' | '`' | '\u{ad}' | '\u{b7}' | '\u{2019}') || {
        // combining marks and modifier letters / symbols, roughly Unicode's Case_Ignorable
        let u = c as u32;
        (0x300..=0x36f).contains(&u) || (0x2b0..=0x2ff).contains(&u) || (0x1ab0..=0x1aff).contains(&u) || (0x20d0..=0x20ff).contains(&u)
    }
}

fn final_sigma(cs: &[char], i: usize) -> bool {
    let mut j = i;
    let mut before = false;
    while j > 0 {
        j -= 1;
        if case_ignorable(cs[j]) {
            continue;
        }
        before = cased(cs[j]);
        break;
    }
    if !before {
        return false;
    }
    for &c in &cs[i + 1..] {
        if case_ignorable(c) {
            continue;
        }
        return !cased(c);
    }
    true
}

/// str.find in code points
pub fn find(hay: &str, needle: &str) -> Option<usize> {
    hay.find(needle).map(|b| hay[..b].chars().count())
}

pub fn clen(s: &str) -> usize {
    s.chars().count()
}

// ---------------------------------------------------------------- os.path
pub fn basename(p: &str) -> &str {
    p.rsplit('/').next().unwrap_or(p)
}

pub fn dirname(p: &str) -> &str {
    match p.rfind('/') {
        None => "",
        Some(i) => {
            let head = &p[..i + 1];
            let t = head.trim_end_matches('/');
            if t.is_empty() { head } else { t }
        }
    }
}

/// os.path.splitext -> (root, ext)
pub fn splitext(p: &str) -> (&str, &str) {
    let sep = p.rfind('/').map(|i| i + 1).unwrap_or(0);
    if let Some(dot) = p.rfind('.') {
        if dot > sep && p[sep..dot].chars().any(|c| c != '.') {
            return (&p[..dot], &p[dot..]);
        }
    }
    (p, "")
}

pub fn join(a: &str, b: &str) -> String {
    if b.starts_with('/') || a.is_empty() {
        b.to_string()
    } else if a.ends_with('/') {
        format!("{a}{b}")
    } else {
        format!("{a}/{b}")
    }
}

/// os.path.normpath for absolute or relative POSIX paths
pub fn normpath(p: &str) -> String {
    if p.is_empty() {
        return ".".into();
    }
    let initial = if p.starts_with("//") && !p.starts_with("///") { 2 } else if p.starts_with('/') { 1 } else { 0 };
    let mut out: Vec<&str> = vec![];
    for c in p.split('/') {
        if c.is_empty() || c == "." {
            continue;
        }
        if c != ".." || (initial == 0 && out.is_empty()) || out.last() == Some(&"..") {
            out.push(c);
        } else if !out.is_empty() {
            out.pop();
        }
    }
    let s = format!("{}{}", "/".repeat(initial), out.join("/"));
    if s.is_empty() { ".".into() } else { s }
}

pub fn abspath(p: &str) -> String {
    if p.starts_with('/') {
        normpath(p)
    } else {
        let cwd = std::env::current_dir().map(|d| d.to_string_lossy().into_owned()).unwrap_or_default();
        normpath(&join(&cwd, p))
    }
}

/// os.path.relpath(path, start)
pub fn relpath(p: &str, start: &str) -> String {
    let a = abspath(start);
    let b = abspath(p);
    let sa: Vec<&str> = a.split('/').filter(|x| !x.is_empty()).collect();
    let sb: Vec<&str> = b.split('/').filter(|x| !x.is_empty()).collect();
    let n = sa.iter().zip(&sb).take_while(|(x, y)| x == y).count();
    let mut parts: Vec<&str> = vec![".."; sa.len() - n];
    parts.extend(&sb[n..]);
    if parts.is_empty() { ".".into() } else { parts.join("/") }
}

/// os.path.realpath (non-strict: resolves what exists, keeps the rest)
pub fn realpath(p: &str) -> String {
    let a = abspath(p);
    if let Ok(r) = std::fs::canonicalize(&a) {
        return r.to_string_lossy().into_owned();
    }
    // resolve the longest existing prefix
    let mut head = a.as_str();
    let mut tail = vec![];
    while let Some(i) = head.rfind('/') {
        tail.push(&head[i + 1..]);
        head = &head[..i];
        if let Ok(r) = std::fs::canonicalize(if head.is_empty() { "/" } else { head }) {
            let mut s = r.to_string_lossy().into_owned();
            for t in tail.iter().rev() {
                s = join(&s, t);
            }
            return normpath(&s);
        }
    }
    a
}

pub fn exists(p: &str) -> bool {
    !p.is_empty() && std::fs::metadata(p).is_ok()
}

pub fn lexists(p: &str) -> bool {
    std::fs::symlink_metadata(p).is_ok()
}

pub fn isfile(p: &str) -> bool {
    std::fs::metadata(p).is_ok_and(|m| m.is_file())
}

pub fn isdir(p: &str) -> bool {
    std::fs::metadata(p).is_ok_and(|m| m.is_dir())
}

pub fn islink(p: &str) -> bool {
    std::fs::symlink_metadata(p).is_ok_and(|m| m.file_type().is_symlink())
}

pub fn mtime(p: &str) -> Option<f64> {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(p).ok().map(|m| m.mtime() as f64 + m.mtime_nsec() as f64 * 1e-9)
}

pub fn home() -> String {
    std::env::var("HOME").unwrap_or_else(|_| "/".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn paths() {
        assert_eq!(splitext("a/b.c/d"), ("a/b.c/d", ""));
        assert_eq!(splitext("a/.hidden"), ("a/.hidden", ""));
        assert_eq!(splitext("a/x.tar.gz"), ("a/x.tar", ".gz"));
        assert_eq!(splitext("..x"), ("..x", ""));
        assert_eq!(dirname("a/b/c"), "a/b");
        assert_eq!(dirname("/a"), "/");
        assert_eq!(dirname("x"), "");
        assert_eq!(relpath("/m/a/b.flac", "/m"), "a/b.flac");
        assert_eq!(relpath("/m", "/m/"), ".");
        assert_eq!(normpath("/a/./b/../c//"), "/a/c");
        assert_eq!(casefold("Straße ẞ"), "strasse ss");
        assert_eq!(lower("ΟΔΟΣ ΣΑ"), "οδος σα");
        assert_eq!(split(" a\u{1f}b  c "), vec!["a", "b", "c"]);
        assert_eq!(find("абв где", "где"), Some(4));
    }
}
