//! HTML mail -> a calm "reader view" for the glass window (port of glassmail/reader.py).
//!
//! QML can't host a browser engine inside quickshell, so HTML is rewritten into a small, safe
//! rich-text subset that Qt's Text renders: paragraphs, headings, bold/italic, links, lists, quotes,
//! code, rules and simple tables flattened into lines. Images become their own blocks. Scripts,
//! styles, forms, iframes and tracking pixels are dropped.
//! Output: [{"t": "text", "html", "q"} | {"t": "img", "src", "alt", "href", "w", "h"} | {"t": "hr"}]
use crate::htmlparser::{self, escape, py_strip, Handler};
use regex::Regex;
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::sync::OnceLock;

const DROP: [&str; 21] = [
    "script", "style", "head", "title", "noscript", "iframe", "object", "embed", "form", "select", "option", "textarea", "button", "svg",
    "canvas", "template", "video", "audio", "map", "meta", "link",
];
const BLOCK: [&str; 25] = [
    "p", "div", "section", "article", "header", "footer", "main", "aside", "nav", "center", "table", "tbody", "thead", "tfoot", "tr", "dl",
    "dd", "dt", "figure", "figcaption", "address", "fieldset", "body", "html", "",
];
const VOID: [&str; 10] = ["br", "img", "hr", "input", "col", "wbr", "meta", "link", "area", "source"];

fn inline_keep(tag: &str) -> Option<&'static str> {
    Some(match tag {
        "b" | "strong" => "b",
        "i" | "em" => "i",
        "u" | "ins" => "u",
        "s" | "strike" | "del" => "s",
        "code" | "tt" | "kbd" => "code",
        "sub" => "sub",
        "sup" => "sup",
        "small" => "small",
        "big" => "big",
        _ => return None,
    })
}

fn head_level(tag: &str) -> Option<u8> {
    Some(match tag {
        "h1" => 1,
        "h2" => 2,
        "h3" => 3,
        "h4" | "h5" | "h6" => 4,
        _ => return None,
    })
}

fn is_block(tag: &str) -> bool {
    !tag.is_empty() && BLOCK.contains(&tag)
}

fn re(cell: &'static OnceLock<Regex>, pat: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pat).unwrap())
}

/// URL_RE (Python's \s also covers \x1c-\x1f)
pub fn url_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    re(&R, r#"(https?://[^\s\x1c-\x1f<>"']+[^\s\x1c-\x1f<>"'.,;:!?)\]])"#)
}

pub fn linkify(escaped: &str, color: &str) -> String {
    url_re()
        .replace_all(escaped, |c: &regex::Captures| format!("<a href=\"{0}\" style=\"color:{color}; text-decoration:none\">{0}</a>", &c[1]))
        .into_owned()
}

fn safe_link(href: &str) -> bool {
    let l = href.to_ascii_lowercase();
    l.starts_with("http:") || l.starts_with("https:") || l.starts_with("mailto:") || l.starts_with("tel:")
}

/// _px: leading integer of an HTML size ("600", " 1px", "100%")
fn px(v: Option<&str>) -> i64 {
    static R: OnceLock<Regex> = OnceLock::new();
    let r = re(&R, r"^[\s\x1c-\x1f]*(\d+)");
    v.and_then(|v| r.captures(v)).and_then(|c| c[1].chars().map(|d| d.to_digit(10)).collect::<Option<Vec<u32>>>())
        .map(|ds| ds.iter().fold(0i64, |a, d| a.saturating_mul(10).saturating_add(*d as i64)))
        .unwrap_or(0)
}

/// _style: one property of an inline style
fn style_prop(style: Option<&str>, prop: &str) -> Option<String> {
    let style = style?;
    if style.is_empty() {
        return None;
    }
    let r = Regex::new(&format!(r"(?i)(?:^|;)[\s\x1c-\x1f]*{prop}[\s\x1c-\x1f]*:[\s\x1c-\x1f]*([^;]+)")).ok()?;
    r.captures(style).map(|c| c[1].to_string())
}

struct ReaderState {
    blocks: Vec<Value>,
    cur: Vec<String>,
    drop: i64,
    stack: Vec<&'static str>,
    links: Vec<Option<String>>,
    lists: Vec<(String, i64)>,
    pre: i64,
    quote: i64,
    cell: bool,
    link_color: String,
    quote_color: String,
    code_bg: String,
    hide: Vec<(String, i64)>,
}

impl ReaderState {
    fn has_text(&self) -> bool {
        self.cur.iter().any(|p| !py_strip(p).is_empty() && p != "<br>")
    }

    fn br(&mut self) {
        if self.cur.last().is_some_and(|l| l != "<br>") {
            self.cur.push("<br>".into());
        }
    }

    fn para(&mut self) {
        while self.cur.last().is_some_and(|l| l == "<br>") {
            self.cur.pop();
        }
        if self.has_text() {
            self.cur.push("<br>".into());
            self.cur.push("<br>".into());
        }
    }

    fn flush(&mut self) {
        while self.cur.last().is_some_and(|l| l == "<br>") {
            self.cur.pop();
        }
        if self.has_text() {
            let mut body: String = self.cur.concat();
            for t in self.stack.iter().rev() {
                body.push_str(&format!("</{t}>"));
            }
            if self.links.last().is_some_and(|l| l.is_some()) {
                body.push_str("</a>");
            }
            if self.quote != 0 {
                body = format!("<span style=\"color:{}\">{body}</span>", self.quote_color);
            }
            self.blocks.push(json!({"t": "text", "html": body, "q": self.quote}));
        }
        self.cur = self.stack.iter().map(|t| format!("<{t}>")).collect();
    }

    fn image(&mut self, a: &HashMap<&str, Option<&str>>) {
        let get = |k: &str| a.get(k).copied().flatten();
        let src = py_strip(get("src").unwrap_or("")).to_string();
        let w = match px(get("width")) {
            0 => px(style_prop(get("style"), "width").as_deref()),
            v => v,
        };
        let h = match px(get("height")) {
            0 => px(style_prop(get("style"), "height").as_deref()),
            v => v,
        };
        if src.is_empty() || (w != 0 && w <= 3) || (h != 0 && h <= 3) {
            return;
        }
        let l = src.to_lowercase();
        if !(l.starts_with("http://") || l.starts_with("https://") || l.starts_with("cid:") || l.starts_with("data:image/")) {
            return;
        }
        let alt = py_strip(get("alt").unwrap_or("")).to_string();
        let href = self.links.last().cloned().flatten().unwrap_or_default();
        self.flush();
        self.blocks.push(json!({"t": "img", "src": src, "alt": alt, "href": href, "w": w, "h": h}));
    }
}

impl Handler for ReaderState {
    fn start(&mut self, tag: &str, attrs: &[(String, Option<String>)]) {
        // dict(attrs): the last value of a repeated attribute wins
        let mut a: HashMap<&str, Option<&str>> = HashMap::new();
        for (k, v) in attrs {
            a.insert(k.as_str(), v.as_deref());
        }
        if DROP.contains(&tag) {
            self.drop += 1;
            return;
        }
        if let Some(last) = self.hide.last_mut() {
            if last.0 == tag {
                last.1 += 1;
            }
        }
        if self.drop != 0 || !self.hide.is_empty() {
            return;
        }
        let style: String = a.get("style").copied().flatten().unwrap_or("").replace(' ', "").to_lowercase();
        if style.contains("display:none") || style.contains("visibility:hidden") || (style.contains("max-height:0") && style.contains("overflow:hidden")) {
            if !VOID.contains(&tag) {
                self.hide.push((tag.to_string(), 1));
            }
            return;
        }
        if tag == "br" {
            self.cur.push("<br>".into());
        } else if let Some(lv) = head_level(tag) {
            self.para();
            self.flush();
            let size = match lv {
                1 => "x-large",
                2 => "large",
                _ => "medium",
            };
            self.cur.push(format!("<span style=\"font-size:{size}\"><b>"));
        } else if ["p", "blockquote", "pre", "ul", "ol", "table", "dl", "figure", "address", "center"].contains(&tag) {
            self.para();
            if tag == "blockquote" {
                self.flush();
                self.quote += 1;
            } else if tag == "pre" {
                self.pre += 1;
                self.cur.push(format!("<span style=\"font-family:monospace; background-color:{}\">", self.code_bg));
            } else if tag == "ul" || tag == "ol" {
                self.lists.push((tag.to_string(), 0));
            }
        } else if tag == "li" {
            self.br();
            let depth = (self.lists.len() as i64 - 1).max(0);
            let mark = match self.lists.last_mut() {
                Some(l) if l.0 == "ol" => {
                    l.1 += 1;
                    format!("{}.", l.1)
                }
                _ => "•".to_string(),
            };
            self.cur.push(format!("{}{mark}&nbsp;&nbsp;", "&nbsp;".repeat((3 + depth * 4) as usize)));
        } else if ["tr", "dt", "dd"].contains(&tag) {
            self.br();
            self.cell = false;
        } else if tag == "td" || tag == "th" {
            if self.cell && self.cur.last().is_some_and(|l| l != "<br>") && self.has_text() {
                self.cur.push("&nbsp;&nbsp; ".into());
            }
            self.cell = true;
            if tag == "th" {
                self.stack.push("b");
                self.cur.push("<b>".into());
            }
        } else if is_block(tag) {
            self.br();
        } else if tag == "hr" {
            self.flush();
            self.blocks.push(json!({"t": "hr"}));
        } else if tag == "a" {
            let href = py_strip(a.get("href").copied().flatten().unwrap_or("")).to_string();
            if safe_link(&href) {
                self.cur.push(format!("<a href=\"{}\" style=\"color:{}; text-decoration:none\">", escape(&href, true), self.link_color));
                self.links.push(Some(href));
            } else {
                self.links.push(None);
            }
        } else if let Some(t) = inline_keep(tag) {
            self.stack.push(t);
            match t {
                "code" => self.cur.push(format!("<code style=\"background-color:{}\">", self.code_bg)),
                "small" => self.cur.push("<span style=\"font-size:small\">".into()),
                "big" => self.cur.push("<span style=\"font-size:large\">".into()),
                _ => self.cur.push(format!("<{t}>")),
            }
        } else if tag == "img" {
            self.image(&a);
        }
    }

    fn end(&mut self, tag: &str) {
        if DROP.contains(&tag) {
            self.drop = (self.drop - 1).max(0);
            return;
        }
        if let Some(last) = self.hide.last_mut() {
            if last.0 == tag {
                last.1 -= 1;
                if last.1 == 0 {
                    self.hide.pop();
                }
            }
            return;
        }
        if self.drop != 0 {
            return;
        }
        if head_level(tag).is_some() {
            self.cur.push("</b></span>".into());
            self.para();
        } else if tag == "blockquote" {
            self.flush();
            self.quote = (self.quote - 1).max(0);
        } else if tag == "pre" {
            if self.pre != 0 {
                self.pre -= 1;
                self.cur.push("</span>".into());
            }
            self.para();
        } else if tag == "ul" || tag == "ol" {
            self.lists.pop();
            self.para();
        } else if ["p", "table", "dl", "figure", "address", "center"].contains(&tag) {
            self.para();
        } else if tag == "th" {
            if self.stack.last() == Some(&"b") {
                self.stack.pop();
                self.cur.push("</b>".into());
            }
        } else if is_block(tag) || tag == "li" {
            self.br();
        } else if tag == "a" {
            if let Some(l) = self.links.pop() {
                if l.is_some() {
                    self.cur.push("</a>".into());
                }
            }
        } else if let Some(t) = inline_keep(tag) {
            if self.stack.contains(&t) {
                // close up to and including t (tolerates sloppy nesting)
                while let Some(x) = self.stack.pop() {
                    self.cur.push(if x == "small" || x == "big" { "</span>".into() } else { format!("</{x}>") });
                    if x == t {
                        break;
                    }
                }
            }
        }
    }

    fn data(&mut self, data: &str) {
        if self.drop != 0 || !self.hide.is_empty() {
            return;
        }
        if self.pre != 0 {
            self.cur.push(escape(data, true).replace('\n', "<br>").replace("  ", "&nbsp; "));
            return;
        }
        static WS: OnceLock<Regex> = OnceLock::new();
        let ws = re(&WS, "[\\s\\x1c-\\x1f\u{200c}\u{200b}\u{34f}\u{ad}\u{2007}\u{feff}]+");
        let mut data = ws.replace_all(data, " ").into_owned();
        if py_strip(&data).is_empty() {
            if self.cur.last().is_some_and(|l| !(l.ends_with(' ') || l.ends_with('>'))) {
                self.cur.push(" ".into());
            }
            return;
        }
        if self.cur.last().is_some_and(|l| l == "<br>") {
            data = data.trim_start_matches(htmlparser::py_space).to_string();
        }
        let in_link = self.links.last().is_some_and(|l| l.is_some());
        let e = escape(&data, false);
        self.cur.push(if in_link { e } else { linkify(&e, &self.link_color) });
    }
}

/// Glue neighbouring text blocks with the same quote level; drop trailing rules.
fn merge(blocks: Vec<Value>) -> Vec<Value> {
    let mut out: Vec<Value> = vec![];
    for b in blocks {
        if let Some(last) = out.last_mut() {
            if b["t"] == "text" && last["t"] == "text" && last.get("q") == b.get("q") {
                let html = format!("{}<br><br>{}", last["html"].as_str().unwrap_or(""), b["html"].as_str().unwrap_or(""));
                last["html"] = Value::String(html);
                continue;
            }
        }
        out.push(b);
    }
    while out.last().is_some_and(|b| b["t"] == "hr") {
        out.pop();
    }
    out
}

pub fn html_blocks(src: &str, link_color: &str, quote_color: &str, code_bg: &str) -> Vec<Value> {
    let mut p = ReaderState {
        blocks: vec![],
        cur: vec![],
        drop: 0,
        stack: vec![],
        links: vec![],
        lists: vec![],
        pre: 0,
        quote: 0,
        cell: false,
        link_color: link_color.into(),
        quote_color: quote_color.into(),
        code_bg: code_bg.into(),
        hide: vec![],
    };
    htmlparser::parse(src, &mut p);
    p.flush();
    merge(p.blocks)
}

pub fn html_blocks_default(src: &str) -> Vec<Value> {
    html_blocks(src, "#80d4db", "#899393", "#252b2c")
}

fn quote_depth(line: &str) -> (usize, &str) {
    // re.match(r'^(>\s?)*') : '>' optionally followed by one whitespace, repeated
    let b = line.as_bytes();
    let mut i = 0;
    let mut depth = 0;
    while i < b.len() && b[i] == b'>' {
        depth += 1;
        i += 1;
        if let Some(c) = line[i..].chars().next() {
            if htmlparser::py_space(c) {
                i += c.len_utf8();
            }
        }
    }
    (depth, &line[i..])
}

fn text_block(lines: &[&str], q: usize, link_color: &str, quote_color: &str) -> Value {
    let mut lines = lines;
    while lines.first().is_some_and(|l| py_strip(l).is_empty()) {
        lines = &lines[1..];
    }
    while lines.last().is_some_and(|l| py_strip(l).is_empty()) {
        lines = &lines[..lines.len() - 1];
    }
    let out: Vec<String> = lines
        .iter()
        .map(|ln| {
            let e = escape(ln, false);
            let n = e.len() - e.trim_start_matches(' ').len();
            let e = format!("{}{}", "&nbsp;".repeat(n), &e[n..]);
            linkify(&e, link_color)
        })
        .collect();
    let mut body = out.join("<br>");
    if q != 0 {
        body = format!("<span style=\"color:{quote_color}\">{body}</span>");
    }
    json!({"t": "text", "html": body, "q": q})
}

/// Plain-text mail -> blocks; '>' quoted runs become dimmed quote blocks, the rest is linkified.
pub fn text_blocks(body: &str, link_color: &str, quote_color: &str) -> Vec<Value> {
    let body = body.replace("\r\n", "\n").replace('\r', "\n");
    let mut blocks = vec![];
    let mut cur: Vec<&str> = vec![];
    let mut q = 0usize;
    for line in body.split('\n') {
        let (depth, stripped) = quote_depth(line);
        let level = usize::from(depth != 0);
        if level != q && !cur.is_empty() {
            blocks.push(text_block(&cur, q, link_color, quote_color));
            cur.clear();
        }
        q = level;
        cur.push(if depth != 0 { stripped } else { line });
    }
    if !cur.is_empty() {
        blocks.push(text_block(&cur, q, link_color, quote_color));
    }
    blocks.into_iter().filter(|b| !py_strip(&b["html"].as_str().unwrap_or("").replace("<br>", "")).is_empty()).collect()
}

pub fn text_blocks_default(body: &str) -> Vec<Value> {
    text_blocks(body, "#80d4db", "#899393")
}

/// For snippets, quoting in replies and the plain-text fallback.
pub fn html_to_text(src: &str) -> String {
    static BR: OnceLock<Regex> = OnceLock::new();
    static TAG: OnceLock<Regex> = OnceLock::new();
    static NL3: OnceLock<Regex> = OnceLock::new();
    let mut parts = vec![];
    for b in html_blocks_default(src) {
        match b["t"].as_str() {
            Some("text") => {
                let t = re(&BR, r"<br[\s\x1c-\x1f]*/?>").replace_all(b["html"].as_str().unwrap_or(""), "\n").into_owned();
                let t = re(&TAG, r"<[^>]+>").replace_all(&t, "").into_owned();
                let mut t = htmlparser::unescape(&t).replace('\u{a0}', " ");
                if b.get("q").and_then(Value::as_i64).unwrap_or(0) != 0 {
                    t = t.split('\n').map(|ln| format!("> {ln}")).collect::<Vec<_>>().join("\n");
                }
                parts.push(t);
            }
            Some("img") => {
                if let Some(alt) = b["alt"].as_str().filter(|a| !a.is_empty()) {
                    parts.push(format!("[{alt}]"));
                }
            }
            Some("hr") => parts.push("———".into()),
            _ => {}
        }
    }
    let text = parts.join("\n\n");
    py_strip(&re(&NL3, r"\n{3,}").replace_all(&text, "\n\n")).to_string()
}

pub fn snippet_of(text: &str, n: usize) -> String {
    static WS: OnceLock<Regex> = OnceLock::new();
    let t = re(&WS, r"[\s\x1c-\x1f]+").replace_all(text, " ");
    py_strip(&t).chars().take(n).collect()
}

/// A block as a JSON object (for the protocol).
pub fn obj(v: &Value) -> Map<String, Value> {
    v.as_object().cloned().unwrap_or_default()
}
