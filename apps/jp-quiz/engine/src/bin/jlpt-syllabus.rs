//! jlpt-syllabus — writes the word and kanji lists the Rank tab measures against:
//!   assets/jlpt/vocab.tsv  (level, jmdict_seq, kanji, kana)   one row per word, the easiest level wins
//!   assets/jlpt/kanji.tsv  (level, joyo, kanji)               level 0 = 常用漢字 that is on no JLPT list
//! from the raw data build/fetch.sh downloads: the JLPT lists (J. Waller / tanos.co.uk, CC BY; JMdict ids
//! by stephenmk/yomitan-jlpt-vocab, CC BY-SA 4.0; kanji levels via davidluzgouveia/kanji-data, `jlpt_new`)
//! and KANJIDIC2 (EDRDG, CC BY-SA 4.0) for the 常用漢字: school grades 1–6 + 8 = the 2136 jōyō kanji of 2010.
//! The grammar list (assets/jlpt/grammar.tsv) is written by hand.
//!
//!   cargo run --release --bin jlpt-syllabus -- <data/raw> <assets/jlpt>
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

/// One CSV record per line (the lists have no embedded newlines); handles "quoted, fields" and "".
fn csv_fields(line: &str) -> Vec<String> {
    let mut out = vec![];
    let mut cur = String::new();
    let mut quoted = false;
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' if quoted && chars.peek() == Some(&'"') => {
                cur.push('"');
                chars.next();
            }
            '"' => quoted = !quoted,
            ',' if !quoted => out.push(std::mem::take(&mut cur)),
            _ => cur.push(c),
        }
    }
    out.push(cur);
    out
}

fn read(path: &Path) -> String {
    std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

/// KANJIDIC2 (gzipped XML): literal -> (school grade, frequency rank).
fn kanjidic(path: &Path) -> HashMap<String, (u8, u32)> {
    let out = std::process::Command::new("gzip").arg("-dc").arg(path).output().unwrap_or_else(|e| panic!("gzip -dc {}: {e}", path.display()));
    assert!(out.status.success(), "gzip -dc {} failed", path.display());
    let xml = String::from_utf8_lossy(&out.stdout);
    let tag = |block: &str, name: &str| -> Option<String> {
        let open = format!("<{name}>");
        let i = block.find(&open)? + open.len();
        let j = block[i..].find("</")? + i;
        Some(block[i..j].to_string())
    };
    xml.split("<character>")
        .skip(1)
        .filter_map(|b| {
            let lit = tag(b, "literal")?;
            let grade = tag(b, "grade").and_then(|g| g.parse().ok()).unwrap_or(0);
            let freq = tag(b, "freq").and_then(|g| g.parse().ok()).unwrap_or(9999);
            Some((lit, (grade, freq)))
        })
        .collect()
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() != 2 {
        eprintln!("usage: jlpt-syllabus <data/raw> <assets/jlpt>");
        std::process::exit(2);
    }
    let (raw, out) = (PathBuf::from(&args[0]), PathBuf::from(&args[1]));
    std::fs::create_dir_all(&out).expect("create output dir");

    // seq -> (level, kanji, kana); N1 first so that an easier list overwrites it
    let mut words: BTreeMap<u64, (u8, String, String, String)> = BTreeMap::new();
    for level in 1..=5u8 {
        for line in read(&raw.join(format!("jlpt/vocab_n{level}.csv"))).lines().skip(1) {
            let f = csv_fields(line);
            let Some(seq) = f.first().and_then(|s| s.trim().parse::<u64>().ok()) else { continue };
            let (kana, kanji) = (f.get(1).cloned().unwrap_or_default(), f.get(2).cloned().unwrap_or_default());
            if kana.is_empty() && kanji.is_empty() {
                continue;
            }
            let def = cut(f.get(3).map_or("", |s| s.trim()), 48).replace(['\t', '\n'], " ");
            words.insert(seq, (level, kanji.trim().to_string(), kana.trim().to_string(), def));
        }
    }
    let mut rows: Vec<_> = words.into_iter().collect();
    rows.sort_by(|a, b| b.1 .0.cmp(&a.1 .0).then(a.0.cmp(&b.0)));
    let mut tsv = String::from("# level\tjmdict_seq\tkanji\tkana\ten — JLPT vocabulary lists by Jonathan Waller (tanos.co.uk, CC BY), JMdict ids by stephenmk/yomitan-jlpt-vocab (CC BY-SA 4.0)\n");
    for (seq, (level, kanji, kana, def)) in &rows {
        let _ = writeln!(tsv, "{level}\t{seq}\t{kanji}\t{kana}\t{def}");
    }
    std::fs::write(out.join("vocab.tsv"), tsv).expect("write vocab.tsv");

    let kd: Value = serde_json::from_str(&read(&raw.join("jlpt/kanji-data.json"))).expect("kanji-data.json");
    let dic = kanjidic(&raw.join("kanjidic2.xml.gz"));
    let joyo = |k: &str| dic.get(k).is_some_and(|&(g, _)| (1..=6).contains(&g) || g == 8);
    let freq = |k: &str| dic.get(k).map_or(9999, |&(_, f)| f);
    // (level, joyo, freq, kanji)
    let mut kanji: Vec<(u8, bool, u32, String)> = kd
        .as_object()
        .expect("kanji-data.json is an object")
        .iter()
        .filter_map(|(k, v)| Some((v.get("jlpt_new").and_then(Value::as_u64)? as u8, joyo(k), freq(k), k.clone())))
        .collect();
    let on_lists: HashSet<String> = kanji.iter().map(|k| k.3.clone()).collect();
    for k in dic.keys().filter(|k| joyo(k) && !on_lists.contains(*k)) {
        kanji.push((0, true, freq(k), k.clone()));
    }
    kanji.sort_by(|a, b| b.0.cmp(&a.0).then(a.2.cmp(&b.2)).then(a.3.cmp(&b.3)));
    let mut tsv = String::from(
        "# level\tjoyo\tkanji — JLPT kanji levels by Jonathan Waller (tanos.co.uk, CC BY) via davidluzgouveia/kanji-data; \
         常用漢字 (joyo=1) from KANJIDIC2 (EDRDG, CC BY-SA 4.0); level 0 = jōyō, on no JLPT list; ordered by frequency\n",
    );
    for (lv, j, _, k) in &kanji {
        let _ = writeln!(tsv, "{lv}\t{}\t{k}", u8::from(*j));
    }
    std::fs::write(out.join("kanji.tsv"), tsv).expect("write kanji.tsv");
    for lv in (1..=5).rev() {
        let w = rows.iter().filter(|r| r.1 .0 == lv).count();
        let k = kanji.iter().filter(|k| k.0 == lv).count();
        let kj = kanji.iter().filter(|k| k.0 == lv && k.1).count();
        println!("N{lv}: {w} words, {k} kanji ({kj} of them jōyō)");
    }
    let total_joyo = kanji.iter().filter(|k| k.1).count();
    let extra = kanji.iter().filter(|k| k.0 == 0).count();
    println!("常用漢字: {total_joyo} ({extra} on no JLPT list)");

    let jlpt_seqs: HashSet<u64> = rows.iter().map(|r| r.0).collect();
    let joyo_set: HashSet<char> = dic.keys().filter(|k| joyo(k)).filter_map(|k| k.chars().next()).collect();
    everyday(&raw, &out, &jlpt_seqs, &joyo_set);
}

// ===========================================================================================
// Everyday vocabulary: what people actually read and say (web, subtitles, social media), beyond the
// JLPT lists. Ranked by wordfreq (R. Speer et al., CC BY-SA 4.0: Wikipedia, OpenSubtitles, Twitter,
// Reddit, web text), checked against JMdict for a reading and a gloss, plus a hand-picked list of
// brands, cars, tech/net slang and food (assets/jlpt/everyday-extra.tsv).
// Mix: 90 % words written with 常用 kanji · 7.5 % kana-only · 2.5 % with kanji outside the 常用 list.
// ===========================================================================================

const EVERYDAY_TOTAL: usize = 10_000;
const SHARE_KANA: f64 = 0.075;
const SHARE_OTHER: f64 = 0.025;
/// Words per tier, most frequent first: N5 tier, N4, N3, N2, N1, then the 常用 tier (level 0) takes the rest.
const TIER_SIZES: [(u8, usize); 5] = [(5, 400), (4, 600), (3, 1400), (2, 1800), (1, 2800)];
/// Parts of speech that are grammar, not vocabulary.
/// Frequent on the web, but not what a vocabulary tier should hand out.
const BLOCK: [&str; 4] = ["強姦", "おっぱい", "ソープ", "エロ"];
const FUNCTION_POS: [&str; 12] =["prt", "aux", "aux-v", "aux-adj", "conj", "cop", "suf", "pref", "ctr", "num", "unc", "pn"];

/// Minimal MessagePack reader for wordfreq's cBpack: [header, bucket0, bucket1, …], buckets = arrays of str.
struct Mp<'a> {
    b: &'a [u8],
    i: usize,
}

enum MpVal {
    Arr(usize),
    Map(usize),
    Str(String),
    Other,
}

impl Mp<'_> {
    fn u(&mut self, n: usize) -> usize {
        let v = self.b[self.i..self.i + n].iter().fold(0usize, |a, &x| (a << 8) | x as usize);
        self.i += n;
        v
    }
    fn str(&mut self, n: usize) -> MpVal {
        let s = String::from_utf8_lossy(&self.b[self.i..self.i + n]).into_owned();
        self.i += n;
        MpVal::Str(s)
    }
    fn next(&mut self) -> MpVal {
        let t = self.b[self.i];
        self.i += 1;
        match t {
            0x00..=0x7f | 0xe0..=0xff | 0xc0 | 0xc2 | 0xc3 => MpVal::Other,
            0x80..=0x8f => MpVal::Map((t & 0x0f) as usize),
            0x90..=0x9f => MpVal::Arr((t & 0x0f) as usize),
            0xa0..=0xbf => self.str((t & 0x1f) as usize),
            0xd9 => { let n = self.u(1); self.str(n) }
            0xda => { let n = self.u(2); self.str(n) }
            0xdb => { let n = self.u(4); self.str(n) }
            0xdc => MpVal::Arr(self.u(2)),
            0xdd => MpVal::Arr(self.u(4)),
            0xde => MpVal::Map(self.u(2)),
            0xdf => MpVal::Map(self.u(4)),
            0xcc | 0xd0 => { self.i += 1; MpVal::Other }
            0xcd | 0xd1 => { self.i += 2; MpVal::Other }
            0xce | 0xd2 | 0xca => { self.i += 4; MpVal::Other }
            0xcf | 0xd3 | 0xcb => { self.i += 8; MpVal::Other }
            _ => panic!("msgpack type {t:#x} not supported"),
        }
    }
    fn skip(&mut self) {
        match self.next() {
            MpVal::Arr(n) => (0..n).for_each(|_| self.skip()),
            MpVal::Map(n) => (0..2 * n).for_each(|_| self.skip()),
            _ => {}
        }
    }
}

/// wordfreq words, most frequent first.
fn wordfreq(path: &Path) -> Vec<String> {
    let bytes = gunzip(path);
    let mut mp = Mp { b: &bytes, i: 0 };
    let MpVal::Arr(n) = mp.next() else { panic!("wordfreq: not an array") };
    mp.skip(); // header {"format": "cB", "version": 1}
    let mut out = vec![];
    for _ in 1..n {
        let MpVal::Arr(m) = mp.next() else { panic!("wordfreq: bucket is not an array") };
        for _ in 0..m {
            if let MpVal::Str(s) = mp.next() {
                out.push(s);
            }
        }
    }
    out
}

fn gunzip(path: &Path) -> Vec<u8> {
    let out = std::process::Command::new("gzip").arg("-dc").arg(path).output().unwrap_or_else(|e| panic!("gzip -dc {}: {e}", path.display()));
    assert!(out.status.success(), "gzip -dc {} failed", path.display());
    out.stdout
}

struct JReb {
    text: String,
    nokanji: bool,
    restr: Vec<String>,
}

struct JEntry {
    seq: u64,
    kebs: Vec<String>,
    rebs: Vec<JReb>,
    common: bool,
    /// priority from everyday sources (ichi/spec/gai), not only newspaper counts (which also rank surnames)
    everyday: bool,
    pos: Vec<String>,  // first sense
    misc: Vec<String>, // all senses
    en: String,
    ru: String,
}

fn all_tags<'a>(block: &'a str, name: &str) -> Vec<&'a str> {
    let (open, close) = (format!("<{name}>"), format!("</{name}>"));
    let mut out = vec![];
    let mut rest = block;
    while let Some(i) = rest.find(&open) {
        let after = &rest[i + open.len()..];
        let Some(j) = after.find(&close) else { break };
        out.push(&after[..j]);
        rest = &after[j + close.len()..];
    }
    out
}

fn entity(s: &str) -> String {
    s.trim_start_matches('&').trim_end_matches(';').to_string()
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'")
}

fn jmdict(path: &Path) -> Vec<JEntry> {
    let xml = String::from_utf8(gunzip(path)).expect("JMdict is UTF-8");
    let mut out = vec![];
    for block in xml.split("<entry>").skip(1) {
        let block = block.split("</entry>").next().unwrap_or("");
        let seq = all_tags(block, "ent_seq").first().and_then(|s| s.parse().ok()).unwrap_or(0);
        let mut common = false;
        let mut everyday = false;
        let mut pri = |tags: Vec<&str>| {
            common |= !tags.is_empty();
            everyday |= tags.iter().any(|t| t.starts_with("ichi") || t.starts_with("spec") || t.starts_with("gai"));
        };
        let kebs = all_tags(block, "k_ele")
            .iter()
            .filter_map(|k| {
                pri(all_tags(k, "ke_pri"));
                all_tags(k, "keb").first().map(|s| s.to_string())
            })
            .collect();
        let rebs = all_tags(block, "r_ele")
            .iter()
            .filter_map(|r| {
                pri(all_tags(r, "re_pri"));
                Some(JReb {
                    text: all_tags(r, "reb").first()?.to_string(),
                    nokanji: r.contains("<re_nokanji"),
                    restr: all_tags(r, "re_restr").iter().map(|s| s.to_string()).collect(),
                })
            })
            .collect();
        let senses = all_tags(block, "sense");
        let pos = senses.first().map(|s| all_tags(s, "pos").iter().map(|p| entity(p)).collect()).unwrap_or_default();
        let misc = senses.iter().flat_map(|s| all_tags(s, "misc")).map(entity).collect();
        // glosses: <gloss> is English, <gloss xml:lang="rus"> Russian
        let mut en = String::new();
        let mut ru = String::new();
        for s in &senses {
            if en.is_empty() {
                let g: Vec<String> = all_tags(s, "gloss").iter().take(3).map(|x| unescape(x)).collect();
                en = g.join(", ");
            }
            if ru.is_empty() {
                let g: Vec<String> = s
                    .split("<gloss xml:lang=\"rus\">")
                    .skip(1)
                    .filter_map(|x| x.split("</gloss>").next())
                    .take(2)
                    .map(unescape)
                    .collect();
                ru = g.join(", ");
            }
        }
        out.push(JEntry { seq, kebs, rebs, common, everyday, pos, misc, en, ru });
    }
    out
}

fn is_kanji(c: char) -> bool {
    ('\u{4e00}'..='\u{9fff}').contains(&c) || ('\u{3400}'..='\u{4dbf}').contains(&c) || ('\u{20000}'..='\u{2ffff}').contains(&c) || c == '々'
}

fn is_kana(c: char) -> bool {
    ('\u{3041}'..='\u{30ff}').contains(&c) || c == 'ー'
}

fn is_katakana(s: &str) -> bool {
    s.chars().all(|c| ('\u{30a0}'..='\u{30ff}').contains(&c))
}

fn cut(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        return s.to_string();
    }
    let t: String = s.chars().take(n).collect();
    match t.rfind(", ") {
        Some(i) => t[..i].to_string(),
        None => t,
    }
}

#[derive(Clone)]
struct Daily {
    rank: usize,
    seq: u64,
    written: String,
    reading: String,
    class: u8, // 0 常用 kanji, 1 kana only, 2 non-常用 kanji
    tag: String,
    pos: String,
    en: String,
    ru: String,
}

fn everyday(raw: &Path, out: &Path, jlpt_seqs: &HashSet<u64>, joyo: &HashSet<char>) {
    let freq = wordfreq(&raw.join("wordfreq/large_ja.msgpack.gz"));
    let rank_of: HashMap<&str, usize> = freq.iter().enumerate().rev().map(|(i, w)| (w.as_str(), i)).collect();
    let entries = jmdict(&raw.join("JMdict.gz"));
    let mut by_form: HashMap<&str, Vec<usize>> = HashMap::new();
    for (i, e) in entries.iter().enumerate() {
        for k in &e.kebs {
            by_form.entry(k.as_str()).or_default().push(i);
        }
        for r in &e.rebs {
            by_form.entry(r.text.as_str()).or_default().push(i);
        }
    }
    let class_of = |w: &str| -> u8 {
        if !w.chars().any(is_kanji) {
            1
        } else if w.chars().filter(|&c| is_kanji(c) && c != '々').all(|c| joyo.contains(&c)) {
            0
        } else {
            2
        }
    };
    let tag_of = |e: &JEntry| -> &str {
        if e.misc.iter().any(|m| m == "net-sl" || m == "sl") {
            "slang"
        } else if e.misc.iter().any(|m| m == "col") {
            "col"
        } else {
            ""
        }
    };
    // the JMdict entry a written form stands for (None: not a dictionary word, or too ambiguous)
    let lookup = |w: &str| -> Option<&JEntry> {
        let cands = by_form.get(w)?;
        let kanji_form = w.chars().any(is_kanji);
        let ok = |e: &&JEntry| {
            if kanji_form {
                return e.kebs.iter().any(|k| k == w);
            }
            // kana: a word normally written in kana, or a loanword; not the kana spelling of a kanji word
            e.rebs.iter().any(|r| r.text == w)
                && (e.kebs.is_empty() || e.misc.iter().any(|m| m == "uk") || is_katakana(w))
        };
        let mut good: Vec<&JEntry> = cands.iter().map(|&i| &entries[i]).filter(ok).collect();
        good.sort_by_key(|e| !e.common);
        good.first().copied()
    };
    let reading_of = |e: &JEntry, w: &str| -> String {
        if !w.chars().any(is_kanji) {
            return w.to_string();
        }
        e.rebs
            .iter()
            .find(|r| !r.nokanji && (r.restr.is_empty() || r.restr.iter().any(|x| x == w)))
            .map(|r| r.text.clone())
            .unwrap_or_default()
    };

    let is_stem = |w: &str| -> bool {
        let Some(last) = w.chars().last() else { return false };
        let head: String = w.chars().take(w.chars().count() - 1).collect();
        let u = match last {
            'い' => "う", 'き' => "く", 'ぎ' => "ぐ", 'し' => "す", 'ち' => "つ", 'に' => "ぬ", 'び' => "ぶ", 'み' => "む", 'り' => "る",
            _ => "",
        };
        let mut forms = vec![format!("{w}る")];
        if !u.is_empty() {
            forms.push(format!("{head}{u}"));
        }
        forms.iter().any(|f| by_form.get(f.as_str()).is_some_and(|v| v.iter().any(|&i| entries[i].pos.iter().any(|p| p.starts_with('v')))))
    };
    // every spelling of a grammar-list pattern: "〜上で(は)" -> 上で, 上では
    let grammar_text = read(&out.join("grammar.tsv"));
    let mut grammar: HashSet<String> = HashSet::new();
    for line in grammar_text.lines().filter(|l| !l.starts_with('#')) {
        let pat = line.split('\t').nth(1).unwrap_or("");
        for alt in pat.split(" / ") {
            let alt = alt.split(" (").next().unwrap_or("").replace(['〜', ' '], "");
            let short = alt.split('(').next().unwrap_or("").to_string() + alt.split(')').nth(1).unwrap_or("");
            let long = alt.replace(['(', ')'], "");
            let mut forms = vec![short, long];
            for f in forms.clone() {
                if let Some(h) = f.strip_suffix("だ") {
                    forms.push(h.to_string()); // みたいだ -> みたい
                }
                if let Some(h) = f.strip_suffix("して") {
                    forms.push(format!("{h}する")); // に対して -> に対する
                }
            }
            grammar.extend(forms.into_iter().filter(|s| s.chars().count() >= 2));
        }
    }
    let mut seen_seq: HashSet<u64> = HashSet::new();
    let mut seen_w: HashSet<String> = HashSet::new();
    let mut picked: Vec<Daily> = vec![];
    // hand-picked words first: they are in whatever the frequency says
    let unranked = freq.len();
    let extra_path = out.join("everyday-extra.tsv");
    let mut n_extra = 0;
    for line in read(&extra_path).lines().filter(|l| !l.starts_with('#') && !l.trim().is_empty()) {
        let f: Vec<&str> = line.split('\t').collect();
        let w = f[0].trim();
        let e = lookup(w);
        let reading = f.get(1).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).or_else(|| e.map(|e| reading_of(e, w))).unwrap_or_default();
        let en = f.get(3).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).or_else(|| e.map(|e| cut(&e.en, 48))).unwrap_or_default();
        let ru = f.get(4).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).or_else(|| e.map(|e| cut(&e.ru, 48))).unwrap_or_default();
        if reading.is_empty() || en.is_empty() {
            eprintln!("everyday-extra: no dictionary entry for {w}, skipped");
            continue;
        }
        let seq = e.map_or(0, |e| e.seq);
        if (seq != 0 && jlpt_seqs.contains(&seq)) || !seen_w.insert(w.to_string()) {
            continue; // on a JLPT list already: counted there
        }
        if seq != 0 {
            seen_seq.insert(seq);
        }
        n_extra += 1;
        picked.push(Daily {
            rank: rank_of.get(w).copied().unwrap_or(unranked),
            seq,
            written: w.to_string(),
            reading,
            class: class_of(w),
            tag: f.get(2).map(|s| s.trim().to_string()).unwrap_or_default(),
            pos: e.map(|e| e.pos.join(",")).unwrap_or_else(|| "n".into()),
            en,
            ru,
        });
    }
    // then the frequency list, until each share is full
    let want = [
        ((1.0 - SHARE_KANA - SHARE_OTHER) * EVERYDAY_TOTAL as f64).round() as usize,
        (SHARE_KANA * EVERYDAY_TOTAL as f64).round() as usize,
        (SHARE_OTHER * EVERYDAY_TOTAL as f64).round() as usize,
    ];
    let mut have = [0usize; 3];
    for d in &picked {
        have[d.class as usize] += 1;
    }
    for (rank, w) in freq.iter().enumerate() {
        if have.iter().zip(want).all(|(h, x)| *h >= x) {
            break;
        }
        let n = w.chars().count();
        if !w.chars().all(|c| is_kanji(c) || is_kana(c)) || (n == 1 && !w.chars().any(is_kanji)) || seen_w.contains(w) {
            continue;
        }
        let Some(e) = lookup(w) else { continue };
        if jlpt_seqs.contains(&e.seq) || seen_seq.contains(&e.seq) || !e.common {
            continue;
        }
        if e.pos.iter().all(|p| FUNCTION_POS.contains(&p.as_str())) || e.misc.iter().any(|m| m == "arch" || m == "obs" || m == "vulg") {
            continue;
        }
        // grammar, not vocabulary: patterns of the grammar list (について, という…) and hiragana expressions
        let hira = w.chars().all(|c| ('\u{3041}'..='\u{309f}').contains(&c));
        if grammar.contains(w.as_str()) || (hira && e.pos.iter().any(|p| p == "exp" || p.starts_with("aux"))) || BLOCK.contains(&w.as_str()) {
            continue;
        }
        // a verb stem the tokenizer split off (思い ← 思う, 出来 ← 出来る): the verb is the word
        if !e.pos.iter().any(|p| p == "int") && is_stem(w) {
            continue;
        }
        // two-kana fragments (マン, イン) only when everyday sources rank them
        if n <= 2 && !w.chars().any(is_kanji) && !e.everyday {
            continue;
        }
        // a lone kanji whose only claim to fame is newspaper counts is usually a surname (辻, 桂)
        if n == 1 && (!e.everyday || e.pos.iter().any(|p| p.contains("suf") || p.contains("pref"))) {
            continue;
        }
        let class = class_of(w);
        if have[class as usize] >= want[class as usize] {
            continue;
        }
        let reading = reading_of(e, w);
        if reading.is_empty() || e.en.is_empty() {
            continue;
        }
        have[class as usize] += 1;
        seen_seq.insert(e.seq);
        seen_w.insert(w.clone());
        picked.push(Daily {
            rank,
            seq: e.seq,
            written: w.clone(),
            reading,
            class,
            tag: tag_of(e).to_string(),
            pos: e.pos.join(","),
            en: cut(&e.en, 48),
            ru: cut(&e.ru, 48),
        });
    }
    picked.sort_by_key(|d| d.rank);
    let mut tsv = String::from(
        "# tier\trank\tjmdict_seq\twritten\treading\tclass\ttag\tpos\ten\tru — everyday words beyond the JLPT lists, most frequent first. \
         rank: wordfreq (CC BY-SA 4.0); readings/glosses: JMdict (EDRDG, CC BY-SA 4.0); class 0 常用 kanji, 1 kana only, 2 other kanji; tier 0 = 常用 tier\n",
    );
    let mut bounds = vec![];
    let mut acc = 0;
    for (lv, n) in TIER_SIZES {
        acc += n;
        bounds.push((lv, acc));
    }
    let mut per_tier: BTreeMap<u8, [usize; 3]> = BTreeMap::new();
    for (i, d) in picked.iter().enumerate() {
        let tier = bounds.iter().find(|(_, b)| i < *b).map_or(0, |(lv, _)| *lv);
        per_tier.entry(tier).or_default()[d.class as usize] += 1;
        let clean = |s: &str| s.replace(['\t', '\n'], " ");
        let _ = writeln!(
            tsv,
            "{tier}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
            if d.rank == unranked { 0 } else { d.rank + 1 },
            d.seq,
            d.written,
            d.reading,
            d.class,
            d.tag,
            d.pos,
            clean(&d.en),
            clean(&d.ru)
        );
    }
    std::fs::write(out.join("everyday.tsv"), tsv).expect("write everyday.tsv");
    println!("everyday: {} words ({n_extra} hand-picked) · 常用 kanji {} · kana {} · other kanji {}", picked.len(), have[0], have[1], have[2]);
    for (tier, c) in per_tier.iter().rev() {
        let name = if *tier == 0 { "常用 tier".to_string() } else { format!("N{tier} tier") };
        println!("  {name}: {} words (常用 {} · kana {} · other {})", c.iter().sum::<usize>(), c[0], c[1], c[2]);
    }
}
