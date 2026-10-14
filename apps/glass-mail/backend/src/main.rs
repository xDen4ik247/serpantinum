mod accounts;
mod ai;
mod check;
mod codes;
mod engine;
mod entities;
mod htmlparser;
mod http;
mod hub;
mod imapparse;
mod mime;
mod mimetab;
mod net;
mod paths;
mod pyemail;
mod pyfold;
mod pyjson;
mod reader;
mod server;
mod store;
mod watch;

pub use server::truthy as engine_truthy;

use base64::Engine as _;
use serde_json::{json, Value};
use std::io::{BufRead, Write};

fn b64(v: &Value) -> Vec<u8> {
    base64::engine::general_purpose::STANDARD.decode(v.as_str().unwrap_or("")).unwrap_or_default()
}

/// Test hook: the pure functions (reader view, login codes, MIME) over JSON lines, for the parity test.
fn pure() {
    let stdin = std::io::stdin();
    let mut out = std::io::stdout().lock();
    for line in stdin.lock().lines().map_while(Result::ok) {
        let r: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
        let s = |k: &str| r[k].as_str().unwrap_or("").to_string();
        let res = match r["fn"].as_str().unwrap_or("") {
            "html_blocks" => Value::Array(reader::html_blocks_default(&s("src"))),
            "text_blocks" => Value::Array(reader::text_blocks_default(&s("src"))),
            "html_to_text" => json!(reader::html_to_text(&s("src"))),
            "codes" => codes::find(&s("subject"), &s("text")).map_or(Value::Null, |(c, sc)| json!([c, sc])),
            "view" => mime::view(&b64(&r["raw"]), &json!({})),
            "text_of" => json!(mime::text_of(&b64(&r["raw"]))),
            "header_row" => {
                let flags: Vec<String> = r["flags"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
                mime::header_row(&b64(&r["hdr"]), 7, &flags, r["idate"].as_f64().unwrap_or(0.0), 1234, "1", true, "")
            }
            "part_text" => json!(mime::part_text(&b64(&r["data"]), &r["info"])),
            "snippet" => json!(mime::snippet_from_part(&b64(&r["data"]), &r["info"])),
            "parse_rcpt" => json!(mime::parse_rcpt(&s("text"))),
            "reply_subject" => json!(mime::reply_subject(&s("s"), &s("prefix"))),
            "text_to_html" => json!(mime::text_to_html(&s("body"))),
            "build" => {
                let fwd: Vec<(String, String, Vec<u8>)> = r["forwarded"]
                    .as_array()
                    .map(|a| a.iter().map(|x| (x[0].as_str().unwrap_or("").to_string(), x[1].as_str().unwrap_or("").to_string(), b64(&x[2]))).collect())
                    .unwrap_or_default();
                let atts: Vec<String> = r["attachments"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
                match mime::build(&r["acc"], &r["draft"], &atts, &fwd) {
                    Ok((m, rcpts)) => json!([base64::engine::general_purpose::STANDARD.encode(m), rcpts]),
                    Err(e) => json!(["error", e.to_string()]),
                }
            }
            _ => Value::Null,
        };
        let _ = writeln!(out, "{res}");
    }
}

fn main() {
    // a closed window must not kill us mid-write with SIGPIPE; writes just fail
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) };
    match std::env::args().nth(1).as_deref() {
        Some("--pure") => pure(),
        Some("watch") => watch::main(),
        Some("check") => check::main(),
        _ => std::sync::Arc::new(server::Server::new()).run(),
    }
}
