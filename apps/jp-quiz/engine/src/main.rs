//! jp-quiz-engine — the JSON-lines bridge between the QML window and the engine (stdin -> stdout),
//! a Rust port of jpquiz/server.py with the same requests and replies:
//!   {"cmd": "hello"} | {"cmd": "next"} | {"cmd": "answer", "qid": 3, "choice": 1, "ms": 2300}
//!   {"cmd": "answer", "qid": 3, "order": ["本を", "読んで", "いる"]} | {"cmd": "skip", "qid": 3}
//!   {"cmd": "stats"} | {"cmd": "settings", "set": {"target": 0.8}} | {"cmd": "anki_add", "key": "vc:1:2"}
//!   {"cmd": "grammar"} | {"cmd": "grammar_example", "id": "tai"} | {"cmd": "anki_sync"} | {"cmd": "peek"} | {"cmd": "quit"}
//!   {"cmd": "rank"} (the Rank tab: tiers, what is left, study plan)
//!   {"cmd": "calib_start"} | {"cmd": "calib_answer", "choice": 2 or null} | {"cmd": "calib_cancel"} (placement test)
//! Every reply is one JSON object per line, echoing the request's "rid".
//! Test hooks: JPQUIZ_SEED=<int> seeds the random choices like random.Random(seed);
//! JPQUIZ_TEST_CLOCK=1 lets a request carry "_now" (unix seconds) to set the engine's clock
//! (JPQUIZ_TEST_NOW = its value before the first request).
mod anki;
mod clock;
mod engine;
mod memory;
mod model;
mod pyjson;
mod pymath;
mod pyrand;
mod review;

use serde_json::{json, Value};
use std::cell::Cell;
use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::rc::Rc;

fn data_dir() -> PathBuf {
    let d = match std::env::var_os("JPQUIZ_DATA") {
        Some(p) => PathBuf::from(p),
        None => PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".local/share/jp-quiz"),
    };
    let _ = std::fs::create_dir_all(&d);
    d
}

fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

fn main() {
    let d = data_dir();
    let content = std::env::var("JPQUIZ_CONTENT").unwrap_or_else(|_| d.join("content.db").to_string_lossy().into_owned());
    let progress = std::env::var("JPQUIZ_PROGRESS").unwrap_or_else(|_| d.join("progress.db").to_string_lossy().into_owned());
    let seed: Option<u128> = std::env::var("JPQUIZ_SEED").ok().and_then(|s| s.parse().ok());
    let test_clock = std::env::var("JPQUIZ_TEST_CLOCK").is_ok_and(|v| v == "1");
    let start = std::env::var("JPQUIZ_TEST_NOW").ok().and_then(|v| v.parse::<f64>().ok()).filter(|_| test_clock);
    let clock = Rc::new(Cell::new(start.unwrap_or(f64::NAN)));
    let c2 = clock.clone();
    let now_fn: Box<dyn Fn() -> f64> = if test_clock { Box::new(move || if c2.get().is_nan() { now() } else { c2.get() }) } else { Box::new(now) };
    let mut eng = match engine::Engine::new(&content, &progress, now_fn, seed) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("jp-quiz-engine: {e}");
            std::process::exit(1);
        }
    };
    let stdin = std::io::stdin();
    let mut out = std::io::stdout().lock();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let req: Option<Value> = serde_json::from_str(line).ok();
        let res: Result<Value, String> = match &req {
            None => Err("JSONDecodeError".into()),
            Some(Value::Object(r)) => {
                if test_clock {
                    if let Some(t) = r.get("_now").and_then(Value::as_f64) {
                        clock.set(t);
                    }
                }
                let ms = || r.get("ms").map_or(Ok(0), engine::py_int);
                let qid = || r.get("qid").ok_or_else(|| "KeyError: 'qid'".to_string()).and_then(engine::py_int);
                match r.get("cmd").and_then(Value::as_str).unwrap_or("") {
                    "hello" => Ok(eng.hello()),
                    "next" => eng.next(),
                    "answer" => qid().and_then(|q| ms().and_then(|m| eng.answer(q, r.get("choice"), r.get("order"), false, m))),
                    "skip" => qid().and_then(|q| ms().and_then(|m| eng.answer(q, None, None, true, m))),
                    "stats" => Ok(eng.stats()),
                    "settings" => eng.set_settings(r.get("set").unwrap_or(&json!({}))),
                    "anki_add" => eng.anki_add(r.get("key")),
                    "grammar" => Ok(eng.grammar_list()),
                    "grammar_example" => eng.grammar_example(&r.get("id").map(|v| match v {
                        Value::String(s) => s.clone(),
                        other => other.to_string(),
                    }).unwrap_or_default()),
                    "anki_sync" => eng.anki_sync(),
                    "rank" => eng.rank(),
                    "calib_start" => eng.calib_start(),
                    "calib_answer" => eng.calib_answer(r.get("choice").and_then(Value::as_i64)),
                    "calib_cancel" => Ok(eng.calib_cancel()),
                    "peek" => Ok(eng.peek()),
                    "quit" => break,
                    other => {
                        let c = r.get("cmd").map_or("None".to_string(), |v| if let Value::String(s) = v { s.clone() } else { v.to_string() });
                        let _ = other;
                        Ok(json!({"type": "error", "error": format!("unknown cmd {c}")}))
                    }
                }
            }
            Some(_) => Err("AttributeError: object has no attribute 'get'".into()),
        };
        let mut res = res.unwrap_or_else(|e| json!({"type": "error", "error": e, "trace": ""}));
        let rid = match &req {
            Some(Value::Object(r)) => r.get("rid").cloned().unwrap_or(Value::Null),
            _ => Value::Null,
        };
        res["rid"] = rid;
        if writeln!(out, "{}", pyjson::dumps(&res, false)).and_then(|_| out.flush()).is_err() {
            break;
        }
    }
}
