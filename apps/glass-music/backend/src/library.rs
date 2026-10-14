//! Library index (port of library.py): one MPD `listallinfo` turned into compact tracks / albums /
//! artists, cached as JSON and reused while MPD's database timestamp (`db_update`) is unchanged.
use crate::mpd::{self, Mpd};
use crate::pyjson;
use crate::pystr::{self, casefold};
use serde_json::{json, Map, Value};

pub const VERSION: i64 = 4;
const MOOD_LABEL: [(&str, &str); 7] =
    [("heavy", "Heavy"), ("rock", "Rock"), ("alt", "Alt & indie"), ("rap", "Rap"), ("electronic", "Electronic"), ("pop", "Pop"), ("chill", "Chill")];

/// music-smart's genre rules (GENRE_RULES / norm_genre / mood_of), in its order
const GENRE_RULES: &[(&str, &str)] = &[
    ("metal", "heavy"), ("core", "heavy"), ("thrash", "heavy"), ("doom", "heavy"),
    ("hardrock", "heavy"), ("stoner", "heavy"), ("grunge", "heavy"),
    ("triphop", "chill"), ("jazz", "chill"), ("bebop", "chill"), ("bigband", "chill"),
    ("lounge", "chill"), ("relax", "chill"), ("newage", "chill"), ("ambient", "chill"),
    ("classical", "chill"), ("soundtrack", "chill"), ("films", "chill"), ("videogame", "chill"),
    ("bard", "chill"), ("folk", "chill"), ("country", "chill"), ("reggaeton", "pop"), ("reggae", "chill"),
    ("soul", "chill"), ("blues", "chill"), ("jewish", "chill"), ("chill", "chill"),
    ("hyperpop", "rap"), ("phonk", "rap"), ("rap", "rap"), ("hiphop", "rap"), ("trap", "rap"),
    ("edm", "electronic"), ("house", "electronic"), ("electron", "electronic"), ("idm", "electronic"),
    ("breakbeat", "electronic"), ("techno", "electronic"), ("trance", "electronic"),
    ("dnb", "electronic"), ("dubstep", "electronic"), ("synth", "electronic"),
    ("postpunk", "alt"), ("alternative", "alt"), ("indie", "alt"), ("experimental", "alt"),
    ("modern", "alt"), ("shoegaze", "alt"),
    ("punk", "rock"), ("rock", "rock"), ("rnr", "rock"), ("prog", "rock"), ("ska", "rock"),
    ("rnb", "pop"), ("funk", "pop"), ("disco", "pop"), ("dance", "pop"), ("estrada", "pop"),
    ("latin", "pop"), ("pop", "pop"), ("sport", "pop"),
];

pub fn music_smart_bin() -> String {
    std::env::var("GLASS_MUSIC_SMART_BIN").unwrap_or_else(|_| format!("{}/.local/bin/music-smart", pystr::home()))
}

fn norm_genre(g: &str) -> String {
    pystr::lower(g).chars().filter(|c| !(pystr::is_space(*c) || *c == '-' || *c == '_')).collect()
}

pub fn mood_of(genres: &[&str]) -> &'static str {
    for g in genres {
        let g = norm_genre(g);
        for (key, mood) in GENRE_RULES {
            if g.contains(key) {
                return mood;
            }
        }
    }
    "alt"
}

/// int(str(v).split("/")[0]) with a default
fn int_of(v: Option<&str>, default: i64) -> i64 {
    let Some(v) = v else { return default };
    let s = pystr::strip(v.split('/').next().unwrap_or(""));
    let s = s.replace('_', "");
    s.parse::<i64>().unwrap_or(default)
}

/// re.sub(r"^\d+\s*-\s*", "", base)
fn strip_number(base: &str) -> &str {
    let d: usize = base.chars().take_while(|c| pystr::is_decimal(*c)).map(char::len_utf8).sum();
    if d == 0 {
        return base;
    }
    let rest = base[d..].trim_start_matches(pystr::is_space);
    match rest.strip_prefix('-') {
        Some(r) => r.trim_start_matches(pystr::is_space),
        None => base,
    }
}

/// float(x) for an MPD number string
fn py_float(s: &str) -> Option<f64> {
    let t = pystr::strip(s);
    if t.is_empty() {
        return None;
    }
    t.replace('_', "").parse::<f64>().ok()
}

/// Counter(xs).most_common(1)[0][0]: the most frequent, the first seen among ties
fn most_common<'a>(xs: impl IntoIterator<Item = &'a str>) -> String {
    let mut c: indexmap::IndexMap<&str, usize> = indexmap::IndexMap::new();
    for x in xs {
        *c.entry(x).or_insert(0) += 1;
    }
    let mut best: Option<(&str, usize)> = None;
    for (k, n) in c {
        if best.is_none_or(|b| n > b.1) {
            best = Some((k, n));
        }
    }
    best.map(|b| b.0.to_string()).unwrap_or_default()
}

struct T {
    f: String,
    t: String,
    a: String,
    as_: Vec<String>,
    p: String,
    al: String,
    k: String,
    n: i64,
    dn: i64,
    d: f64,
    y: String,
    g: String,
    m: &'static str,
    ad: String,
    l: bool,
}

pub fn build(m: &mut Mpd, music_dir: &str) -> mpd::Result<Value> {
    let songs = Mpd::songs(&m.cmd("listallinfo", &[])?);
    let mut tracks: Vec<T> = vec![];
    for s in songs {
        let f = s.file.clone();
        if f.starts_with('.') || f.contains("/.") {
            continue;
        }
        let parts: Vec<&str> = f.split('/').collect();
        let artists: Vec<String> =
            s.list("Artist").iter().flat_map(|v| v.split(';')).map(|a| pystr::strip(a).to_string()).filter(|a| !a.is_empty()).collect();
        let primary = if parts.len() > 1 {
            parts[0].to_string()
        } else {
            artists.first().cloned().unwrap_or_else(|| "Unknown artist".into())
        };
        let base = pystr::splitext(parts[parts.len() - 1]).0;
        let title = match s.get("Title") {
            Some(t) if !t.is_empty() => t.to_string(),
            _ => strip_number(base).to_string(),
        };
        let dsrc = s.get("duration").filter(|x| !x.is_empty()).or(s.get("Time").filter(|x| !x.is_empty()));
        let dur = match dsrc {
            None => 0.0,
            Some(x) => py_float(x).map(|v| pyjson::round_n(v, 2)).unwrap_or(0.0),
        };
        let genres = s.list("Genre");
        let al = match s.get("Album") {
            Some(a) if !a.is_empty() => a.to_string(),
            _ => if parts.len() > 2 { parts[parts.len() - 2].to_string() } else { String::new() },
        };
        let ad = s.get("Added").filter(|x| !x.is_empty()).or(s.get("Last-Modified").filter(|x| !x.is_empty())).unwrap_or("");
        tracks.push(T {
            t: title,
            a: if artists.is_empty() { primary.clone() } else { artists.join(", ") },
            as_: if artists.is_empty() { vec![primary.clone()] } else { artists.clone() },
            p: primary,
            al,
            k: pystr::dirname(&f).to_string(),
            n: int_of(s.get("Track"), 0),
            dn: int_of(s.get("Disc"), 1),
            d: dur,
            y: s.get("Date").unwrap_or("").chars().take(4).collect(),
            g: genres.first().map(|g| g.to_string()).unwrap_or_default(),
            m: mood_of(&genres),
            ad: ad.to_string(),
            l: pystr::exists(&pystr::join(music_dir, &format!("{}.lrc", pystr::splitext(&f).0))),
            f,
        });
    }
    tracks.sort_by_cached_key(|t| (casefold(&t.p), casefold(&t.k), t.dn, t.n, casefold(&t.t)));

    let mut by_album: indexmap::IndexMap<&str, Vec<usize>> = indexmap::IndexMap::new();
    for (i, t) in tracks.iter().enumerate() {
        by_album.entry(t.k.as_str()).or_default().push(i);
    }
    struct A {
        k: String,
        n: String,
        p: String,
        ar: String,
        y: String,
        c: String,
        tr: Vec<usize>,
        d: i64,
        m: String,
        ad: String,
        single: bool,
    }
    let mut albums: Vec<A> = vec![];
    for (k, idx) in &by_album {
        let ts: Vec<&T> = idx.iter().map(|&i| &tracks[i]).collect();
        let joined: Vec<String> = ts.iter().map(|t| t.as_.join(", ")).collect();
        let cover = pystr::join(&pystr::join(music_dir, k), "cover.jpg");
        albums.push(A {
            k: k.to_string(),
            n: if ts[0].al.is_empty() { pystr::basename(k).to_string() } else { ts[0].al.clone() },
            p: ts[0].p.clone(),
            ar: most_common(joined.iter().map(String::as_str)),
            y: ts.iter().map(|t| t.y.clone()).max().unwrap_or_default(),
            c: if pystr::exists(&cover) { cover } else { String::new() },
            tr: idx.clone(),
            d: pyjson::round_i(crate::pymath::sum(ts.iter().map(|t| t.d))),
            m: most_common(ts.iter().map(|t| t.m)),
            ad: ts.iter().map(|t| t.ad.clone()).max().unwrap_or_default(),
            single: ts.len() <= 3,
        });
    }
    albums.sort_by_cached_key(|a| (casefold(&a.p), a.y.clone(), casefold(&a.n)));

    let mut by_artist: indexmap::IndexMap<&str, Vec<usize>> = indexmap::IndexMap::new();
    for (i, a) in albums.iter().enumerate() {
        by_artist.entry(a.p.as_str()).or_default().push(i);
    }
    let mut feat: std::collections::HashMap<String, Vec<usize>> = std::collections::HashMap::new();
    for (i, t) in tracks.iter().enumerate() {
        let pf = casefold(&t.p);
        for name in &t.as_ {
            let nf = casefold(name);
            if nf != pf {
                feat.entry(nf).or_default().push(i);
            }
        }
    }
    let mut artists: Vec<(String, Value)> = vec![];
    for (name, als) in &by_artist {
        let mut sorted: Vec<&A> = als.iter().map(|&i| &albums[i]).collect();
        sorted.sort_by(|x, y| (&y.y, &y.ad).cmp(&(&x.y, &x.ad)));
        let cover = sorted.iter().find(|a| !a.c.is_empty()).map(|a| a.k.clone()).unwrap_or_default();
        let ap: Vec<usize> = feat.get(&casefold(name)).map(|v| v.iter().take(60).copied().collect()).unwrap_or_default();
        artists.push((
            casefold(name),
            json!({"n": name, "al": sorted.iter().map(|a| a.k.clone()).collect::<Vec<_>>(),
                   "nt": als.iter().map(|&i| albums[i].tr.len()).sum::<usize>(), "c": cover, "ap": ap,
                   "m": most_common(als.iter().map(|&i| albums[i].m.as_str()))}),
        ));
    }
    artists.sort_by(|a, b| a.0.cmp(&b.0));

    let mut moods: indexmap::IndexMap<&str, i64> = indexmap::IndexMap::new();
    for t in &tracks {
        *moods.entry(t.m).or_insert(0) += 1;
    }
    let tracks_v: Vec<Value> = tracks
        .iter()
        .map(|t| {
            let mut o = Map::new();
            o.insert("f".into(), json!(t.f));
            o.insert("t".into(), json!(t.t));
            o.insert("a".into(), json!(t.a));
            if t.as_.len() >= 2 {
                o.insert("as".into(), json!(t.as_));
            }
            o.insert("p".into(), json!(t.p));
            o.insert("al".into(), json!(t.al));
            o.insert("k".into(), json!(t.k));
            o.insert("n".into(), json!(t.n));
            o.insert("dn".into(), json!(t.dn));
            o.insert("d".into(), pyjson::f(t.d));
            o.insert("y".into(), json!(t.y));
            o.insert("g".into(), json!(t.g));
            o.insert("m".into(), json!(t.m));
            o.insert("l".into(), json!(t.l));
            Value::Object(o)
        })
        .collect();
    let albums_v: Vec<Value> = albums
        .iter()
        .map(|a| {
            json!({"k": a.k, "n": a.n, "p": a.p, "ar": a.ar, "y": a.y, "c": a.c, "tr": a.tr, "d": a.d, "m": a.m, "ad": a.ad, "single": a.single})
        })
        .collect();
    Ok(json!({"v": VERSION, "tracks": tracks_v, "albums": albums_v, "artists": artists.into_iter().map(|a| a.1).collect::<Vec<_>>(),
              "moods": MOOD_LABEL.iter().filter(|(m, _)| moods.get(m).copied().unwrap_or(0) > 0)
                  .map(|(m, l)| json!({"id": m, "label": l, "n": moods[m]})).collect::<Vec<_>>()}))
}

/// (library, from_cache)
pub fn load(m: &mut Mpd, music_dir: &str, cache_dir: &str, force: bool) -> mpd::Result<(Value, bool)> {
    let stamp = m.dict("stats", &[])?.get("db_update").cloned().unwrap_or_default();
    let path = format!("{cache_dir}/library.json");
    if !force {
        if let Ok(t) = std::fs::read_to_string(&path) {
            if let Ok(Value::Object(mut c)) = serde_json::from_str::<Value>(&t) {
                if c.get("v") == Some(&json!(VERSION)) && c.get("stamp") == Some(&json!(stamp)) && c.get("dir") == Some(&json!(music_dir)) {
                    if let Some(lib) = c.remove("lib") {
                        return Ok((lib, true));
                    }
                }
            }
        }
    }
    let lib = build(m, music_dir)?;
    let _ = std::fs::create_dir_all(cache_dir);
    let tmp = format!("{path}.tmp");
    let doc = json!({"v": VERSION, "stamp": stamp, "dir": music_dir, "lib": lib});
    std::fs::write(&tmp, pyjson::dumps_compact(&doc, false)).map_err(mpd::Error::Io)?;
    std::fs::rename(&tmp, &path).map_err(mpd::Error::Io)?;
    Ok((doc["lib"].clone(), false))
}
