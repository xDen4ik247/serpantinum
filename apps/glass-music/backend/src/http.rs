//! A small blocking HTTP(S) GET (what urllib.request.urlopen does for the lyrics resolver):
//! TLS through the system OpenSSL, redirects followed, chunked bodies, per-operation timeout.
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

pub enum Error {
    /// HTTP status >= 400 (urllib's HTTPError)
    Status(u16),
    /// network trouble (URLError / timeout / connection reset)
    Net(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            Error::Status(c) => write!(f, "HTTP Error {c}"),
            Error::Net(e) => write!(f, "{e}"),
        }
    }
}

trait Rw: Read + Write {}
impl<T: Read + Write> Rw for T {}

fn net<E: std::fmt::Display>(e: E) -> Error {
    Error::Net(e.to_string())
}

pub fn get(url: &str, ua: &str, timeout: Duration) -> Result<Vec<u8>, Error> {
    let mut url = url.to_string();
    for _ in 0..10 {
        let (tls, rest) = if let Some(r) = url.strip_prefix("https://") {
            (true, r)
        } else if let Some(r) = url.strip_prefix("http://") {
            (false, r)
        } else {
            return Err(Error::Net(format!("unknown url type: {url}")));
        };
        let (hostport, path) = match rest.find('/') {
            Some(i) => (&rest[..i], &rest[i..]),
            None => (rest, "/"),
        };
        let (host, port) = match hostport.rsplit_once(':') {
            Some((h, p)) if p.chars().all(|c| c.is_ascii_digit()) => (h, p.parse().unwrap_or(if tls { 443 } else { 80 })),
            _ => (hostport, if tls { 443 } else { 80 }),
        };
        let addr = (host, port).to_socket_addrs().map_err(net)?.next().ok_or_else(|| Error::Net("no address".into()))?;
        let tcp = TcpStream::connect_timeout(&addr, timeout).map_err(net)?;
        tcp.set_read_timeout(Some(timeout)).ok();
        tcp.set_write_timeout(Some(timeout)).ok();
        let mut s: Box<dyn Rw> = if tls {
            let c = native_tls::TlsConnector::new().map_err(net)?;
            Box::new(c.connect(host, tcp).map_err(net)?)
        } else {
            Box::new(tcp)
        };
        let host_hdr = if (tls && port == 443) || (!tls && port == 80) { host.to_string() } else { hostport.to_string() };
        write!(s, "GET {path} HTTP/1.1\r\nAccept-Encoding: identity\r\nHost: {host_hdr}\r\nUser-Agent: {ua}\r\nConnection: close\r\n\r\n").map_err(net)?;
        let mut r = BufReader::new(s);
        let mut line = String::new();
        r.read_line(&mut line).map_err(net)?;
        let code: u16 = line.split_whitespace().nth(1).and_then(|c| c.parse().ok()).ok_or_else(|| Error::Net("bad status line".into()))?;
        let (mut len, mut chunked, mut location) = (None, false, None);
        loop {
            let mut h = String::new();
            if r.read_line(&mut h).map_err(net)? == 0 {
                break;
            }
            let h = h.trim_end();
            if h.is_empty() {
                break;
            }
            if let Some((k, v)) = h.split_once(':') {
                let (k, v) = (k.trim().to_ascii_lowercase(), v.trim());
                match k.as_str() {
                    "content-length" => len = v.parse::<usize>().ok(),
                    "transfer-encoding" => chunked = v.eq_ignore_ascii_case("chunked"),
                    "location" => location = Some(v.to_string()),
                    _ => {}
                }
            }
        }
        if matches!(code, 301 | 302 | 303 | 307 | 308) {
            if let Some(loc) = location {
                url = if loc.starts_with("http://") || loc.starts_with("https://") {
                    loc
                } else {
                    format!("{}://{}{}", if tls { "https" } else { "http" }, hostport, loc)
                };
                continue;
            }
        }
        if code >= 400 {
            return Err(Error::Status(code));
        }
        let mut body = vec![];
        if chunked {
            loop {
                let mut l = String::new();
                r.read_line(&mut l).map_err(net)?;
                let n = usize::from_str_radix(l.trim().split(';').next().unwrap_or("0"), 16).map_err(net)?;
                if n == 0 {
                    break;
                }
                let mut c = vec![0u8; n + 2];
                r.read_exact(&mut c).map_err(net)?;
                body.extend_from_slice(&c[..n]);
            }
        } else if let Some(n) = len {
            body.resize(n, 0);
            r.read_exact(&mut body).map_err(net)?;
        } else {
            r.read_to_end(&mut body).map_err(net)?;
        }
        return Ok(body);
    }
    Err(Error::Net("too many redirects".into()))
}

/// urllib.parse.urlencode (quote_plus) for str values
pub fn urlencode(pairs: &[(&str, String)]) -> String {
    let q = |s: &str| {
        let mut o = String::new();
        for b in s.bytes() {
            match b {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'_' | b'.' | b'-' | b'~' => o.push(b as char),
                b' ' => o.push('+'),
                _ => o.push_str(&format!("%{b:02X}")),
            }
        }
        o
    };
    pairs.iter().map(|(k, v)| format!("{}={}", q(k), q(v))).collect::<Vec<_>>().join("&")
}
