mod http;
mod library;
mod lyrics;
mod lyricsfetch;
mod mpd;
mod pyjson;
mod pymath;
mod pystr;
mod pytables;
mod removal;
mod search;
mod server;
mod thumbs;

use serde_json::{json, Value};
use std::io::{BufRead, Write};

/// Test hook: the pure functions over JSON lines, for the parity test.
fn pure() {
    let stdin = std::io::stdin();
    let mut out = std::io::stdout().lock();
    let mut index: Option<search::Index> = None;
    for line in stdin.lock().lines().map_while(Result::ok) {
        let r: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
        let s = |k: &str| r[k].as_str().unwrap_or("").to_string();
        let res = match r["fn"].as_str().unwrap_or("") {
            "norm" => json!(search::norm(&s("s"))),
            "variants" => json!(search::variants(&s("s"))),
            "index" => {
                index = Some(search::Index::new(&r["lib"]));
                Value::Null
            }
            "search" => index.as_ref().map(|i| i.search(&s("q"))).unwrap_or(Value::Null),
            "load_path" => lyrics::load_path(&s("path"), &Default::default()),
            "parse_any" => {
                let (l, sy) = lyrics::parse_any(&s("text"));
                json!([l, sy])
            }
            "embedded" => json!(lyrics::embedded(&s("path"))),
            "lfnorm" => json!(lyricsfetch::norm(&s("s"))),
            "matches" => json!(lyricsfetch::matches(&r["meta"], &r["title"], &r["artist"], &r["duration"])),
            "dominant" => match std::fs::read(s("path")).ok().and_then(|d| thumbs::decode_jpeg(&d)) {
                Some(im) => {
                    let t = thumbs::thumbnail(&im);
                    let h = sha1_smol::Sha1::from(&t.px).digest().to_string();
                    json!({"c": thumbs::dominant(&im), "w": t.w, "h": t.h, "px": h})
                }
                None => Value::Null,
            },
            "hash_colour" => json!(thumbs::hash_colour(&s("s"))),
            "casefold" => json!(pystr::casefold(&s("s"))),
            "lower" => json!(pystr::lower(&s("s"))),
            _ => Value::Null,
        };
        let _ = writeln!(out, "{}", pyjson::dumps(&res, false));
    }
}

fn main() {
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) };
    match std::env::args().nth(1).as_deref() {
        Some("--pure") => pure(),
        _ => server::Server::new().run(),
    }
}
