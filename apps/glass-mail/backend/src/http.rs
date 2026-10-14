//! A tiny HTTP/1.1 client for the local model (plain http on 127.0.0.1): JSON requests and a
//! line-by-line reader for streamed (chunked / SSE) answers.
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

pub struct Response {
    pub status: u16,
    reader: BufReader<TcpStream>,
    chunked: bool,
    left: Option<usize>, // content-length left, or bytes left in the current chunk
    done: bool,
}

#[derive(Debug)]
pub enum HttpError {
    /// could not connect / connection broke (urllib.error.URLError, ConnectionError)
    Conn(String),
    Timeout,
    Status(u16, String),
}

impl std::fmt::Display for HttpError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            HttpError::Conn(s) => write!(f, "{s}"),
            HttpError::Timeout => write!(f, "timed out"),
            HttpError::Status(c, s) => write!(f, "HTTP Error {c}: {s}"),
        }
    }
}

fn io_err(e: io::Error) -> HttpError {
    if matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) {
        HttpError::Timeout
    } else {
        HttpError::Conn(e.to_string())
    }
}

pub fn request(method: &str, url: &str, body: Option<&[u8]>, timeout: Duration) -> Result<Response, HttpError> {
    let rest = url.strip_prefix("http://").ok_or_else(|| HttpError::Conn("only http:// URLs".into()))?;
    let (hostport, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    let addr = if hostport.contains(':') { hostport.to_string() } else { format!("{hostport}:80") };
    let sa = addr.to_socket_addrs().map_err(|e| HttpError::Conn(e.to_string()))?.next().ok_or_else(|| HttpError::Conn("no address".into()))?;
    let mut s = TcpStream::connect_timeout(&sa, timeout).map_err(|e| HttpError::Conn(format!("<urlopen error {e}>")))?;
    s.set_read_timeout(Some(timeout)).ok();
    s.set_write_timeout(Some(timeout)).ok();
    let mut req = format!("{method} {path} HTTP/1.1\r\nHost: {hostport}\r\nConnection: close\r\nAccept-Encoding: identity\r\n");
    if let Some(b) = body {
        req += &format!("Content-Type: application/json\r\nContent-Length: {}\r\n", b.len());
    }
    req += "\r\n";
    s.write_all(req.as_bytes()).map_err(io_err)?;
    if let Some(b) = body {
        s.write_all(b).map_err(io_err)?;
    }
    let mut reader = BufReader::new(s);
    let mut line = String::new();
    reader.read_line(&mut line).map_err(io_err)?;
    let status: u16 = line.split_whitespace().nth(1).and_then(|x| x.parse().ok()).ok_or_else(|| HttpError::Conn("bad response".into()))?;
    let (mut chunked, mut length) = (false, None);
    loop {
        let mut h = String::new();
        if reader.read_line(&mut h).map_err(io_err)? == 0 {
            break;
        }
        let h = h.trim_end();
        if h.is_empty() {
            break;
        }
        let low = h.to_ascii_lowercase();
        if low.starts_with("transfer-encoding:") && low.contains("chunked") {
            chunked = true;
        }
        if let Some(v) = low.strip_prefix("content-length:") {
            length = v.trim().parse().ok();
        }
    }
    let mut r = Response { status, reader, chunked, left: if chunked { Some(0) } else { length }, done: false };
    if !(200..300).contains(&status) {
        let b = r.read_all().unwrap_or_default();
        return Err(HttpError::Status(status, String::from_utf8_lossy(&b).chars().take(200).collect()));
    }
    Ok(r)
}

impl Response {
    /// Next piece of the body, None at the end.
    fn piece(&mut self) -> Result<Option<Vec<u8>>, HttpError> {
        if self.done {
            return Ok(None);
        }
        if self.chunked {
            if self.left == Some(0) {
                let mut l = String::new();
                if self.reader.read_line(&mut l).map_err(io_err)? == 0 {
                    self.done = true;
                    return Ok(None);
                }
                let l = l.trim();
                if l.is_empty() {
                    return self.piece();
                }
                let n = usize::from_str_radix(l.split(';').next().unwrap_or("0"), 16).unwrap_or(0);
                if n == 0 {
                    self.done = true;
                    return Ok(None);
                }
                self.left = Some(n);
            }
            let n = self.left.unwrap_or(0);
            let mut buf = vec![0u8; n.min(65536)];
            let k = self.reader.read(&mut buf).map_err(io_err)?;
            if k == 0 {
                self.done = true;
                return Ok(None);
            }
            buf.truncate(k);
            self.left = Some(n - k);
            if self.left == Some(0) {
                let mut crlf = String::new();
                let _ = self.reader.read_line(&mut crlf);
            }
            return Ok(Some(buf));
        }
        let want = match self.left {
            Some(0) => {
                self.done = true;
                return Ok(None);
            }
            Some(n) => n.min(65536),
            None => 65536,
        };
        let mut buf = vec![0u8; want];
        let k = self.reader.read(&mut buf).map_err(io_err)?;
        if k == 0 {
            self.done = true;
            return Ok(None);
        }
        buf.truncate(k);
        if let Some(n) = self.left.as_mut() {
            *n -= k;
        }
        Ok(Some(buf))
    }

    pub fn read_all(&mut self) -> Result<Vec<u8>, HttpError> {
        let mut out = vec![];
        while let Some(p) = self.piece()? {
            out.extend(p);
        }
        Ok(out)
    }

    /// Calls f for every body line (without the newline) as it arrives; f returns false to stop.
    pub fn lines(&mut self, mut f: impl FnMut(&[u8]) -> Result<bool, HttpError>) -> Result<(), HttpError> {
        let mut buf: Vec<u8> = vec![];
        while let Some(p) = self.piece()? {
            buf.extend(p);
            while let Some(i) = buf.iter().position(|&b| b == b'\n') {
                let line: Vec<u8> = buf.drain(..=i).collect();
                if !f(&line[..line.len() - 1])? {
                    return Ok(());
                }
            }
        }
        if !buf.is_empty() {
            f(&buf)?;
        }
        Ok(())
    }
}
