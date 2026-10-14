//! Instant search over artists, albums and tracks (port of search.py; Latin, Cyrillic, Japanese).
//! Every key is normalised the same way (NFKC, casefold, ё→е, katakana→hiragana, punctuation
//! dropped). A query is tried as typed, with the keyboard layout swapped and transliterated.
use crate::pystr::{self, casefold, clen, is_space, is_word};
use serde_json::{json, Value};
use unicode_normalization::UnicodeNormalization;

const US: &str = "`qwertyuiop[]asdfghjkl;'zxcvbnm,./";
const RU: &str = "ёйцукенгшщзхъфывапролджэячсмитьбю.";

const RU2LAT: &[(char, &str)] = &[
    ('а', "a"), ('б', "b"), ('в', "v"), ('г', "g"), ('д', "d"), ('е', "e"), ('ё', "e"), ('ж', "zh"), ('з', "z"),
    ('и', "i"), ('й', "i"), ('к', "k"), ('л', "l"), ('м', "m"), ('н', "n"), ('о', "o"), ('п', "p"), ('р', "r"),
    ('с', "s"), ('т', "t"), ('у', "u"), ('ф', "f"), ('х', "h"), ('ц', "ts"), ('ч', "ch"), ('ш', "sh"), ('щ', "sch"),
    ('ъ', ""), ('ы', "y"), ('ь', ""), ('э', "e"), ('ю', "yu"), ('я', "ya"),
];
const LAT2RU: &[(&str, &str)] = &[
    ("shch", "щ"), ("sch", "щ"), ("zh", "ж"), ("kh", "х"), ("ts", "ц"), ("ch", "ч"), ("sh", "ш"),
    ("yu", "ю"), ("ya", "я"), ("yo", "ё"), ("ye", "е"), ("ju", "ю"), ("ja", "я"),
    ("a", "а"), ("b", "б"), ("v", "в"), ("w", "в"), ("g", "г"), ("d", "д"), ("e", "е"), ("z", "з"),
    ("i", "и"), ("j", "й"), ("y", "ы"), ("k", "к"), ("c", "к"), ("q", "к"), ("l", "л"), ("m", "м"),
    ("n", "н"), ("o", "о"), ("p", "п"), ("r", "р"), ("s", "с"), ("t", "т"), ("u", "у"), ("f", "ф"),
    ("h", "х"), ("x", "кс"),
];

pub fn norm(s: &str) -> String {
    if s.is_empty() {
        return String::new();
    }
    let s: String = s.nfkc().collect();
    let s = casefold(&s).replace('ё', "е");
    // katakana → hiragana so either script finds the other
    let s: String = s.chars().map(|c| if ('ァ'..='ヶ').contains(&c) { char::from_u32(c as u32 - 0x60).unwrap() } else { c }).collect();
    // [^\w\s]+ → " ", then [\s_]+ → " ", strip
    let mut o = String::with_capacity(s.len());
    let mut gap = false;
    for c in s.chars() {
        if (!is_word(c) && !is_space(c)) || is_space(c) || c == '_' {
            gap = true;
        } else {
            if gap {
                o.push(' ');
                gap = false;
            }
            o.push(c);
        }
    }
    pystr::strip(&o).to_string()
}

fn swap_layout(q: &str) -> String {
    let us: Vec<char> = US.chars().collect();
    let ru: Vec<char> = RU.chars().collect();
    let ru2us = |c: char| ru.iter().position(|&r| r == c).map(|i| us[i]);
    let us2ru = |c: char| us.iter().position(|&u| u == c).map(|i| ru[i]);
    if q.chars().any(|c| ru2us(c).is_some()) {
        q.chars().map(|c| ru2us(c).unwrap_or(c)).collect()
    } else {
        q.chars().map(|c| us2ru(c).unwrap_or(c)).collect()
    }
}

fn translit(q: &str) -> String {
    if q.chars().any(|c| ('Ѐ'..='ӿ').contains(&c)) {
        return q.chars().map(|c| RU2LAT.iter().find(|(r, _)| *r == c).map(|(_, l)| l.to_string()).unwrap_or_else(|| c.to_string())).collect();
    }
    let mut out = String::new();
    let mut rest = q;
    'outer: while let Some(c) = rest.chars().next() {
        for (lat, cyr) in LAT2RU {
            if let Some(r) = rest.strip_prefix(lat) {
                out.push_str(cyr);
                rest = r;
                continue 'outer;
            }
        }
        out.push(c);
        rest = &rest[c.len_utf8()..];
    }
    out
}

pub fn variants(query: &str) -> Vec<(String, f64)> {
    let q = norm(query);
    if q.is_empty() {
        return vec![];
    }
    let raw = casefold(query);
    let sw = norm(&swap_layout(&raw));
    let tr = norm(&translit(&q));
    let mut out = vec![(q.clone(), 1.0)];
    if !sw.is_empty() && sw != q {
        out.push((sw.clone(), 0.8));
    }
    if !tr.is_empty() && tr != q && tr != sw {
        out.push((tr, 0.7));
    }
    out
}

/// 0 = no match; higher is better.
pub fn score_key(key: &str, q: &str) -> f64 {
    if key.is_empty() {
        return 0.0;
    }
    if key == q {
        return 100.0;
    }
    if key.starts_with(q) {
        return 80.0 + (10 * clen(q)) as f64 / clen(key).max(1) as f64;
    }
    if let Some(i) = pystr::find(key, &format!(" {q}")) {
        return 60.0 - 10f64.min(i as f64 / 4.0);
    }
    if let Some(i) = pystr::find(key, q) {
        return 40.0 - 10f64.min(i as f64 / 4.0);
    }
    // every word of the query is somewhere in the key
    let words = pystr::split(q);
    if words.len() > 1 && words.iter().all(|w| key.contains(w)) {
        return 30.0;
    }
    0.0
}

pub struct Index {
    tracks: Vec<(usize, String, String)>,
    albums: Vec<(String, String, String)>,
    artists: Vec<(String, String)>,
}

fn s<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str().unwrap_or("")
}

impl Index {
    pub fn new(lib: &Value) -> Index {
        let arr = |k: &str| lib[k].as_array().cloned().unwrap_or_default();
        Index {
            tracks: arr("tracks").iter().enumerate().map(|(i, t)| (i, norm(s(t, "t")), norm(&format!("{} {}", s(t, "a"), s(t, "al"))))).collect(),
            albums: arr("albums").iter().map(|a| (s(a, "k").to_string(), norm(s(a, "n")), norm(s(a, "ar")))).collect(),
            artists: arr("artists").iter().map(|a| (s(a, "n").to_string(), norm(s(a, "n")))).collect(),
        }
    }

    pub fn search(&self, query: &str) -> Value {
        let (limit_tracks, limit_albums, limit_artists) = (60, 24, 18);
        let vs = variants(query);
        if vs.is_empty() {
            return json!({"artists": [], "albums": [], "tracks": [], "top": null});
        }
        let best = |keys: &[&str]| {
            let mut b = 0.0;
            for (q, w) in &vs {
                for (j, k) in keys.iter().enumerate() {
                    let s = score_key(k, q) * w * if j == 0 { 1.0 } else { 0.55 };
                    if s > b {
                        b = s;
                    }
                }
            }
            b
        };
        fn top<T: Clone>(mut v: Vec<(f64, T)>, n: usize) -> Vec<(f64, T)> {
            v.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
            v.into_iter().filter(|x| x.0 > 0.0).take(n).collect()
        }
        let ar = top(self.artists.iter().map(|(n, k)| (best(&[k]), n.clone())).collect(), limit_artists);
        let al = top(self.albums.iter().map(|(key, k, a)| (best(&[k, a]), key.clone())).collect(), limit_albums);
        let tr = top(self.tracks.iter().map(|(i, k, a)| (best(&[k, a]), *i)).collect(), limit_tracks);
        let mut cands: Vec<(f64, &str, Value)> = vec![];
        if let Some(x) = ar.first() {
            cands.push((x.0 + 6.0, "artist", json!(x.1)));
        }
        if let Some(x) = al.first() {
            cands.push((x.0 + 2.0, "album", json!(x.1)));
        }
        if let Some(x) = tr.first() {
            cands.push((x.0, "track", json!(x.1)));
        }
        let mut topv = Value::Null;
        let mut bestc: Option<&(f64, &str, Value)> = None;
        for c in &cands {
            if bestc.is_none_or(|b| c.0 > b.0) {
                bestc = Some(c);
            }
        }
        if let Some((_, kind, r)) = bestc {
            topv = json!({"kind": kind, "ref": r});
        }
        json!({"artists": ar.iter().map(|x| x.1.clone()).collect::<Vec<_>>(), "albums": al.iter().map(|x| x.1.clone()).collect::<Vec<_>>(),
               "tracks": tr.iter().map(|x| x.1).collect::<Vec<_>>(), "top": topv})
    }
}
