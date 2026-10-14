//! Mail AI on the local model (port of ai.py; npu-llm: llama.cpp, OpenAI-compatible API on
//! 127.0.0.1:8765). Nothing leaves the laptop. One request at a time: what you clicked goes first,
//! background work (summaries of new mail) waits.
//! Tasks: analyze, reply, write, rewrite, translate, ask (with sources), brief (catch me up).
use crate::http::{self, HttpError};
use crate::pyjson::dumps;
use regex::Regex;
use serde_json::{json, Value};
use std::collections::{BinaryHeap, HashSet};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

pub const MAX_CHARS: usize = 6000;

fn url() -> String {
    std::env::var("GLASS_MAIL_AI_URL").unwrap_or_else(|_| "http://127.0.0.1:8765/v1".into()).trim_end_matches('/').to_string()
}

fn lang_name(code: &str) -> Option<&'static str> {
    Some(match code {
        "ru" => "Russian",
        "en" => "English",
        "ja" => "Japanese",
        "de" => "German",
        "es" => "Spanish",
        "fr" => "French",
        _ => return None,
    })
}

fn re(cell: &'static OnceLock<Regex>, p: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(p).unwrap())
}

/// Very small language guess for prompts: ru / ja / en.
pub fn lang_of(text: &str) -> &'static str {
    let t: String = text.chars().take(3000).collect();
    static CYR: OnceLock<Regex> = OnceLock::new();
    static KANA: OnceLock<Regex> = OnceLock::new();
    static LAT: OnceLock<Regex> = OnceLock::new();
    let cyr = re(&CYR, "[а-яёА-ЯЁ]").find_iter(&t).count();
    let kana = re(&KANA, "[぀-ヿ一-鿿]").find_iter(&t).count();
    let lat = re(&LAT, "[a-zA-Z]").find_iter(&t).count();
    if kana > 20usize.max(lat / 3) {
        "ja"
    } else if cyr as f64 > lat as f64 * 0.6 {
        "ru"
    } else {
        "en"
    }
}

pub fn clip(text: &str, n: usize) -> String {
    static NL: OnceLock<Regex> = OnceLock::new();
    let t = re(&NL, r"\n{3,}").replace_all(crate::htmlparser::py_strip(text), "\n\n").into_owned();
    if t.chars().count() <= n {
        t
    } else {
        t.chars().take(n).collect::<String>() + "\n[…]"
    }
}

/// Drop quoted history so the model reads only the new part.
pub fn strip_quotes(text: &str) -> String {
    static HIST: OnceLock<Regex> = OnceLock::new();
    let hist = re(&HIST, r"^[\s\x1c-\x1f]*(On .{5,80} wrote:|.{5,80} написал\(а\):|-----Original Message-----|---------- Forwarded)");
    let mut out = vec![];
    for ln in text.split('\n') {
        if hist.is_match(ln) {
            break;
        }
        if ln.trim_start_matches(crate::htmlparser::py_space).starts_with('>') {
            continue;
        }
        out.push(ln);
    }
    crate::htmlparser::py_strip(&out.join("\n")).to_string()
}

fn strftime(fmt: &str, t: f64) -> String {
    let tt = t as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&tt, &mut tm) };
    let c = std::ffi::CString::new(fmt).unwrap();
    let mut buf = vec![0u8; 128];
    let n = unsafe { libc::strftime(buf.as_mut_ptr() as *mut libc::c_char, buf.len(), c.as_ptr(), &tm) };
    buf.truncate(n);
    String::from_utf8_lossy(&buf).into_owned()
}

fn today() -> String {
    strftime("%A, %d %B %Y", crate::mime::now())
}

pub enum Fail {
    Cancelled,
    Http(HttpError),
    Other(String),
}

impl From<HttpError> for Fail {
    fn from(e: HttpError) -> Self {
        Fail::Http(e)
    }
}

pub type Task = Box<dyn FnOnce(&Ai, &Value) -> Result<(), Fail> + Send>;

struct Job {
    prio: u8,
    seq: u64,
    rid: Value,
    task: Task,
}

impl PartialEq for Job {
    fn eq(&self, o: &Self) -> bool {
        self.prio == o.prio && self.seq == o.seq
    }
}
impl Eq for Job {}
impl PartialOrd for Job {
    fn partial_cmp(&self, o: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(o))
    }
}
impl Ord for Job {
    fn cmp(&self, o: &Self) -> std::cmp::Ordering {
        // BinaryHeap is a max-heap: lower priority number and older seq first
        o.prio.cmp(&self.prio).then(o.seq.cmp(&self.seq))
    }
}

pub struct Ai {
    emit: Box<dyn Fn(Value) + Send + Sync>,
    log: Box<dyn Fn(&str) + Send + Sync>,
    q: Mutex<(BinaryHeap<Job>, u64)>,
    cv: Condvar,
    model: Mutex<Option<String>>,
    state: Mutex<String>,
    cancelled: Mutex<HashSet<String>>,
}

fn key(rid: &Value) -> String {
    rid.to_string()
}

impl Ai {
    pub fn new(emit: Box<dyn Fn(Value) + Send + Sync>, log: Box<dyn Fn(&str) + Send + Sync>) -> Arc<Ai> {
        let ai = Arc::new(Ai {
            emit,
            log,
            q: Mutex::new((BinaryHeap::new(), 0)),
            cv: Condvar::new(),
            model: Mutex::new(None),
            state: Mutex::new("idle".into()),
            cancelled: Mutex::new(HashSet::new()),
        });
        let me = ai.clone();
        std::thread::Builder::new().name("ai".into()).spawn(move || me.run()).ok();
        ai
    }

    /// rid identifies the request for the UI; background work runs last.
    pub fn submit(&self, rid: Value, background: bool, task: Task) {
        let mut q = self.q.lock().unwrap();
        q.1 += 1;
        let seq = q.1;
        q.0.push(Job { prio: u8::from(background), seq, rid, task });
        self.cv.notify_one();
    }

    pub fn cancel(&self, rid: &Value) {
        self.cancelled.lock().unwrap().insert(key(rid));
    }

    fn is_cancelled(&self, rid: &Value) -> bool {
        self.cancelled.lock().unwrap().contains(&key(rid))
    }

    fn run(self: Arc<Self>) {
        loop {
            let job = {
                let mut q = self.q.lock().unwrap();
                while q.0.is_empty() {
                    q = self.cv.wait(q).unwrap();
                }
                q.0.pop().unwrap()
            };
            if self.is_cancelled(&job.rid) {
                self.cancelled.lock().unwrap().remove(&key(&job.rid));
                continue;
            }
            match (job.task)(&self, &job.rid) {
                Ok(()) => {}
                Err(Fail::Cancelled) => (self.emit)(json!({"type": "ai-done", "rid": job.rid, "cancelled": true})),
                Err(e) => {
                    let text = match &e {
                        Fail::Http(HttpError::Conn(_)) => "The local AI isn’t answering (npu-llm). Try again in a minute, or check `ai status`.".to_string(),
                        Fail::Http(HttpError::Timeout) => "The local AI took too long.".to_string(),
                        Fail::Http(other) => format!("AI error: {other}"),
                        Fail::Other(s) => format!("AI error: {s}"),
                        Fail::Cancelled => unreachable!(),
                    };
                    let msg = match &e {
                        Fail::Http(h) => h.to_string(),
                        Fail::Other(s) => s.clone(),
                        Fail::Cancelled => String::new(),
                    };
                    (self.log)(&format!("ai {}: {msg}", job.rid));
                    (self.emit)(json!({"type": "ai-error", "rid": job.rid, "text": text}));
                }
            }
            self.cancelled.lock().unwrap().remove(&key(&job.rid));
        }
    }

    // ---------------------------------------------------------------- the model
    fn set_state(&self, s: &str) {
        let mut st = self.state.lock().unwrap();
        if *st != s {
            *st = s.to_string();
            (self.emit)(json!({"type": "ai-state", "state": s}));
        }
    }

    /// Wake the on-demand model early (socket-activated, ~45 s cold start).
    pub fn warm(self: &Arc<Self>) {
        let me = self.clone();
        std::thread::spawn(move || {
            if let Err(e) = me.ensure_model() {
                (me.log)(&format!("ai warm: {}", match e {
                    Fail::Http(h) => h.to_string(),
                    Fail::Other(s) => s,
                    Fail::Cancelled => String::new(),
                }));
                me.set_state("off");
            }
        });
    }

    fn ensure_model(&self) -> Result<String, Fail> {
        if let Some(m) = self.model.lock().unwrap().clone() {
            return Ok(m);
        }
        self.set_state("waking");
        let mut r = http::request("GET", &format!("{}/models", url()), None, Duration::from_secs(150))?;
        let data: Value = serde_json::from_slice(&r.read_all()?).map_err(|e| Fail::Other(e.to_string()))?;
        let items = data.get("data").or(data.get("models")).and_then(Value::as_array).cloned().unwrap_or_default();
        let m = items.first().and_then(|i| i.get("id").or(i.get("name"))).and_then(Value::as_str).unwrap_or("local").to_string();
        *self.model.lock().unwrap() = Some(m.clone());
        self.set_state("ready");
        Ok(m)
    }

    #[allow(clippy::too_many_arguments)]
    fn chat(&self, rid: &Value, system: &str, user: &str, schema: Option<Value>, max_tokens: u32, temperature: f64, stream: bool) -> Result<String, Fail> {
        let model = self.ensure_model()?;
        let mut body = json!({"model": model, "max_tokens": max_tokens, "temperature": temperature,
                              "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                              "chat_template_kwargs": {"enable_thinking": false}});
        if let Some(s) = schema {
            body["response_format"] = json!({"type": "json_schema", "json_schema": {"name": "out", "schema": s}});
        }
        if stream {
            body["stream"] = json!(true);
        }
        let t0 = Instant::now();
        let mut r = http::request("POST", &format!("{}/chat/completions", url()), Some(dumps(&body, true).as_bytes()), Duration::from_secs(240))?;
        let out = if !stream {
            let v: Value = serde_json::from_slice(&r.read_all()?).map_err(|e| Fail::Other(e.to_string()))?;
            v["choices"][0]["message"]["content"].as_str().unwrap_or("").to_string()
        } else {
            let mut parts = String::new();
            let mut cancelled = false;
            r.lines(|raw| {
                if self.is_cancelled(rid) {
                    cancelled = true;
                    return Ok(false);
                }
                let line = String::from_utf8_lossy(raw).trim().to_string();
                let Some(data) = line.strip_prefix("data:") else { return Ok(true) };
                let data = data.trim();
                if data == "[DONE]" {
                    return Ok(false);
                }
                if let Ok(v) = serde_json::from_str::<Value>(data) {
                    if let Some(delta) = v["choices"][0]["delta"]["content"].as_str().filter(|d| !d.is_empty()) {
                        parts.push_str(delta);
                        (self.emit)(json!({"type": "ai-chunk", "rid": rid, "text": delta}));
                    }
                }
                Ok(true)
            })?;
            if cancelled {
                return Err(Fail::Cancelled);
            }
            parts
        };
        self.set_state("ready");
        (self.log)(&format!("ai {rid}: {:.1}s", t0.elapsed().as_secs_f64()));
        static THINK: OnceLock<Regex> = OnceLock::new();
        Ok(crate::htmlparser::py_strip(&re(&THINK, r"(?s)^\s*<think>.*?</think>\s*").replace(&out, "")).to_string())
    }

    // ---------------------------------------------------------------- tasks
    /// mail: {subject, from, date, text, thread: [text], me}; done(result) caches it.
    pub fn analyze(&self, rid: &Value, mail: &Value, done: impl FnOnce(&Value)) -> Result<(), Fail> {
        let ms = |k: &str| mail[k].as_str().unwrap_or("").to_string();
        let lang = lang_name(lang_of(&format!("{} {}", ms("subject"), ms("text")))).unwrap_or("English");
        let date = mail["date"].as_f64().unwrap_or(0.0);
        let sent = if date != 0.0 { strftime("%A, %d %B %Y %H:%M", date) } else { "unknown".into() };
        let schema = json!({"type": "object", "properties": {
            "summary": {"type": "string"},
            "actions": {"type": "array", "items": {"type": "string"}, "maxItems": 4},
            "events": {"type": "array", "maxItems": 3, "items": {"type": "object", "properties": {
                "title": {"type": "string"}, "when": {"type": "string"}}, "required": ["title", "when"]}},
            "replies": {"type": "array", "items": {"type": "string"}, "maxItems": 3},
            "needsReply": {"type": "boolean"}
        }, "required": ["summary", "actions", "events", "replies", "needsReply"]});
        let me = mail["me"].as_str().filter(|s| !s.is_empty()).unwrap_or("the user");
        let system = format!(
            "You help {me} read email. Today is {}. Answer in {lang}.\n\
- summary: what the email is about and what is asked, 1-2 short sentences.\n\
- actions: concrete to-dos for the reader (empty for newsletters and notifications).\n\
- events: meetings, deadlines, flights with their date/time, written so a calendar parser understands them (e.g. \"Tuesday 15:00\", \"before Friday\", \"13 October 18:30\"); empty if none.\n\
- replies: 3 short, different replies the reader might send (a few words each, first person); empty for notifications, newsletters and automated mail.\n\
- needsReply: true only if a person expects an answer.",
            today()
        );
        let mut ctx = String::new();
        if let Some(th) = mail["thread"].as_array().filter(|t| !t.is_empty()) {
            let start = th.len().saturating_sub(3);
            let parts: Vec<String> = th[start..].iter().map(|t| clip(t.as_str().unwrap_or(""), 900)).collect();
            ctx = format!("Earlier in this conversation:\n{}\n\n", parts.join("\n---\n"));
        }
        let text = ms("text");
        let sq = strip_quotes(&text);
        let user = format!("{ctx}Email sent {sent}\nFrom: {}\nSubject: {}\n\n{}", ms("from"), ms("subject"), clip(if sq.is_empty() { &text } else { &sq }, MAX_CHARS));
        let raw = self.chat(rid, &system, &user, Some(schema), 600, 0.3, false)?;
        let mut out: Value = serde_json::from_str(&raw).map_err(|e| Fail::Other(e.to_string()))?;
        out["lang"] = json!(lang);
        done(&out);
        (self.emit)(json!({"type": "ai-analysis", "rid": rid, "result": out}));
        Ok(())
    }

    pub fn reply(&self, rid: &Value, mail: &Value, intent: &str, me: &str) -> Result<(), Fail> {
        let text = mail["text"].as_str().unwrap_or("");
        let lang = lang_name(lang_of(&format!("{text} {intent}"))).unwrap_or("English");
        let system = format!(
            "Write the body of an email reply as {}. Language: {lang}. Match the tone of the original (casual stays casual). No subject line, no quoted text, no placeholders like [Name]. Don't end with a sign-off name or signature — the user's signature is added separately. Output only the reply text.",
            if me.is_empty() { "the user" } else { me }
        );
        let user = format!(
            "Original email from {}:\nSubject: {}\n\n{}\n\nWhat my reply should say: {intent}",
            mail["from"].as_str().unwrap_or(""),
            mail["subject"].as_str().unwrap_or(""),
            clip(&strip_quotes(text), 3500)
        );
        let out = self.chat(rid, &system, &user, None, 500, 0.6, true)?;
        (self.emit)(json!({"type": "ai-done", "rid": rid, "text": out}));
        Ok(())
    }

    pub fn write(&self, rid: &Value, prompt: &str, ctx: &Value, me: &str) -> Result<(), Fail> {
        let lang = lang_name(lang_of(&format!("{prompt} {}", ctx["body"].as_str().unwrap_or("")))).unwrap_or("English");
        let system = format!(
            "Write an email as {} from their instructions. Language: {lang} unless the instructions ask for another. First line: \"Subject: …\", then a blank line, then the body. Natural, concise, no placeholders like [Name]. Don't end with a sign-off name or signature — the user's signature is added separately. Output only the email.",
            if me.is_empty() { "the user" } else { me }
        );
        let mut user = format!("Instructions: {prompt}");
        if let Some(to) = ctx["to"].as_str().filter(|s| !s.is_empty()) {
            user += &format!("\nTo: {to}");
        }
        if let Some(s) = ctx["subject"].as_str().filter(|s| !s.is_empty()) {
            user += &format!("\nSubject so far: {s}");
        }
        if let Some(q) = ctx["quote"].as_str().filter(|s| !s.is_empty()) {
            user += &format!("\n\nThis replies to:\n{}", clip(&strip_quotes(q), 3000));
        }
        let text = self.chat(rid, &system, &user, None, 700, 0.6, true)?;
        static SUBJ: OnceLock<Regex> = OnceLock::new();
        let (mut subject, mut body) = (String::new(), text.clone());
        if let Some(m) = re(&SUBJ, r"(?i)^\s*(subject|тема)\s*:\s*(.+?)\s*\n+").captures(&text) {
            subject = m[2].to_string();
            body = text[m.get(0).unwrap().end()..].to_string();
        }
        (self.emit)(json!({"type": "ai-done", "rid": rid, "text": crate::htmlparser::py_strip(&body), "subject": subject}));
        Ok(())
    }

    pub fn rewrite(&self, rid: &Value, text: &str, mode: &str) -> Result<(), Fail> {
        let base = match mode {
            "improve" => "Improve this email: clearer, better flow, correct grammar. Keep the language, meaning and length roughly the same.".to_string(),
            "shorten" => "Make this email much shorter while keeping every request, date and fact. Keep the language.".to_string(),
            "formal" => "Rewrite this email in a polite, professional tone. Keep the language and every fact.".to_string(),
            "friendly" => "Rewrite this email in a warm, friendly, casual tone. Keep the language and every fact.".to_string(),
            "fix" => "Fix spelling, grammar and punctuation only. Change nothing else. Keep the language.".to_string(),
            "en" => "Translate this email into natural English.".to_string(),
            "ru" => "Translate this email into natural Russian.".to_string(),
            "ja" => "Translate this email into natural Japanese (polite です/ます style).".to_string(),
            other => format!("Rewrite this email following this instruction: {other}. Keep every fact unless told otherwise."),
        };
        let mut task = base;
        if !["en", "ru", "ja"].contains(&mode) {
            task += &format!(" Write it in {}, the language it is in now (unless the instruction says otherwise).", lang_name(lang_of(text)).unwrap_or("English"));
        }
        let system = format!("{task} Never add placeholders like [Name] or [Your name]; use only names that appear in the text. Don't add a sign-off name or signature the text doesn't have (the user's signature is added separately). Output only the rewritten email text, without a subject line or comments.");
        let out = self.chat(rid, &system, &clip(text, 5000), None, 900, 0.4, true)?;
        (self.emit)(json!({"type": "ai-done", "rid": rid, "text": out}));
        Ok(())
    }

    pub fn translate(&self, rid: &Value, text: &str, target: &str) -> Result<(), Fail> {
        let system = format!("Translate the email into {}. Keep paragraphs, lists and links. Output only the translation.", lang_name(target).unwrap_or(target));
        let out = self.chat(rid, &system, &clip(text, 5000), None, 1400, 0.2, true)?;
        (self.emit)(json!({"type": "ai-done", "rid": rid, "text": out}));
        Ok(())
    }

    /// docs: [{n, from, date, subject, text}] — answer citing [n].
    pub fn ask(&self, rid: &Value, question: &str, docs: &[Value]) -> Result<(), Fail> {
        let lang = lang_name(lang_of(question)).unwrap_or("English");
        let system = format!("Answer the question using only the emails below. Today is {}. Answer in {lang}, briefly (a few sentences or bullets). Cite emails as [1], [2]. If the emails don't contain the answer, say so in one sentence.", today());
        let mut parts = vec![];
        let mut budget = MAX_CHARS as i64;
        for d in docs {
            let body = clip(&strip_quotes(d["text"].as_str().unwrap_or("")), 700);
            let chunk = format!("[{}] {} · from {} · \"{}\"\n{body}", d["n"], d["date"].as_str().unwrap_or(""), d["from"].as_str().unwrap_or(""), d["subject"].as_str().unwrap_or(""));
            let n = chunk.chars().count() as i64;
            if n > budget {
                break;
            }
            parts.push(chunk);
            budget -= n;
        }
        let out = self.chat(rid, &system, &format!("Emails:\n\n{}\n\nQuestion: {question}", parts.join("\n\n")), None, 450, 0.2, true)?;
        (self.emit)(json!({"type": "ai-done", "rid": rid, "text": out}));
        Ok(())
    }

    pub fn brief(&self, rid: &Value, docs: &[Value], lang: &str) -> Result<(), Fail> {
        let system = format!(
            "You brief the user on their unread email. Today is {}. Answer in {}. Start with one line on the overall picture, then group: what needs a reply or action (most urgent first), then FYI, then a single line for newsletters/promotions. One short bullet per email, citing it as [n]. No preamble.",
            today(),
            lang_name(lang).unwrap_or("English")
        );
        let parts: Vec<String> = docs
            .iter()
            .map(|d| {
                let t: String = d["text"].as_str().unwrap_or("").chars().take(260).collect();
                format!("[{}] {} · {} · \"{}\" — {t}", d["n"], d["date"].as_str().unwrap_or(""), d["from"].as_str().unwrap_or(""), d["subject"].as_str().unwrap_or(""))
            })
            .collect();
        let out = self.chat(rid, &system, &parts.join("\n"), None, 650, 0.3, true)?;
        (self.emit)(json!({"type": "ai-done", "rid": rid, "text": out}));
        Ok(())
    }
}
