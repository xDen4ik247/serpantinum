//! IMAP and SMTP clients (what imaplib / smtplib did for the Python backend).
//! One blocking connection each, TLS through the system OpenSSL (native-tls). GLASS_MAIL_INSECURE=1
//! accepts a self-signed server (tests only).
use native_tls::{TlsConnector, TlsStream};
use std::collections::HashSet;
use std::io::{self, Read, Write};
use std::net::{Shutdown, TcpStream, ToSocketAddrs};
use std::time::{Duration, Instant};

pub enum Stream {
    Plain(TcpStream),
    Tls(Box<TlsStream<TcpStream>>),
}

impl Read for Stream {
    fn read(&mut self, b: &mut [u8]) -> io::Result<usize> {
        match self {
            Stream::Plain(s) => s.read(b),
            Stream::Tls(s) => s.read(b),
        }
    }
}

impl Write for Stream {
    fn write(&mut self, b: &[u8]) -> io::Result<usize> {
        match self {
            Stream::Plain(s) => s.write(b),
            Stream::Tls(s) => s.write(b),
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        match self {
            Stream::Plain(s) => s.flush(),
            Stream::Tls(s) => s.flush(),
        }
    }
}

fn connector() -> io::Result<TlsConnector> {
    let insecure = std::env::var("GLASS_MAIL_INSECURE").as_deref() == Ok("1");
    TlsConnector::builder()
        .danger_accept_invalid_certs(insecure)
        .danger_accept_invalid_hostnames(insecure)
        .build()
        .map_err(io::Error::other)
}

fn tcp(host: &str, port: u16, timeout: Duration) -> io::Result<TcpStream> {
    let mut last = io::Error::new(io::ErrorKind::NotFound, "no address");
    for a in (host, port).to_socket_addrs()? {
        match TcpStream::connect_timeout(&a, timeout) {
            Ok(s) => {
                s.set_read_timeout(Some(timeout))?;
                s.set_write_timeout(Some(timeout))?;
                return Ok(s);
            }
            Err(e) => last = e,
        }
    }
    Err(last)
}

fn upgrade(host: &str, s: TcpStream) -> io::Result<Stream> {
    let c = connector()?;
    c.connect(host, s).map(|t| Stream::Tls(Box::new(t))).map_err(|e| io::Error::other(e.to_string()))
}

/// A stream with its own line buffer (a read timeout never loses buffered bytes).
pub struct Conn {
    pub s: Stream,
    pub sock: TcpStream, // a clone, for timeouts and shutdown from another thread
    buf: Vec<u8>,
}

impl Conn {
    fn fill(&mut self) -> io::Result<()> {
        let mut chunk = [0u8; 65536];
        let n = self.s.read(&mut chunk)?;
        if n == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "connection closed"));
        }
        self.buf.extend_from_slice(&chunk[..n]);
        Ok(())
    }

    /// One line including CRLF.
    pub fn line(&mut self) -> io::Result<Vec<u8>> {
        loop {
            if let Some(i) = self.buf.windows(2).position(|w| w == b"\r\n") {
                return Ok(self.buf.drain(..i + 2).collect());
            }
            if let Some(i) = self.buf.iter().position(|&b| b == b'\n') {
                return Ok(self.buf.drain(..=i).collect());
            }
            self.fill()?;
        }
    }

    pub fn exact(&mut self, n: usize) -> io::Result<Vec<u8>> {
        while self.buf.len() < n {
            self.fill()?;
        }
        Ok(self.buf.drain(..n).collect())
    }

    pub fn send(&mut self, b: &[u8]) -> io::Result<()> {
        self.s.write_all(b)?;
        self.s.flush()
    }

    pub fn set_timeout(&self, t: Option<Duration>) {
        let _ = self.sock.set_read_timeout(t);
    }
}

// ---------------------------------------------------------------- IMAP

#[derive(Debug, Clone)]
pub struct Untagged {
    pub kind: String,
    pub num: Option<u64>,
    /// the rest of the response with literals replaced by \x00<i>\x00
    pub data: Vec<u8>,
    pub lits: Vec<Vec<u8>>,
}

#[derive(Debug)]
pub struct Done {
    pub status: String,
    pub text: String,
    pub untagged: Vec<Untagged>,
}

#[derive(Debug)]
pub enum ImapError {
    Io(io::Error),
    /// NO / BAD from the server (imaplib.IMAP4.error)
    No(String),
}

/// An OS error the way Python prints it: "[Errno 111] Connection refused", "timed out", ...
pub fn py_io(e: &io::Error) -> String {
    if let Some(n) = e.raw_os_error() {
        let t = e.to_string();
        let t = t.strip_suffix(&format!(" (os error {n})")).unwrap_or(&t).to_string();
        return format!("[Errno {n}] {t}");
    }
    if matches!(e.kind(), io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock) {
        return "timed out".into();
    }
    let t = e.to_string();
    if let Some(r) = t.strip_prefix("failed to lookup address information: ") {
        let code = match r {
            "Name or service not known" => -2,
            "Temporary failure in name resolution" => -3,
            "No address associated with hostname" => -5,
            _ => 0,
        };
        if code != 0 {
            return format!("[Errno {code}] {r}");
        }
    }
    t
}

impl std::fmt::Display for ImapError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            ImapError::Io(e) => write!(f, "{}", py_io(e)),
            ImapError::No(s) => write!(f, "{s}"),
        }
    }
}

impl From<io::Error> for ImapError {
    fn from(e: io::Error) -> Self {
        ImapError::Io(e)
    }
}

pub type IResult<T> = Result<T, ImapError>;

pub enum Arg<'a> {
    Text(&'a str),
    Lit(&'a [u8]),
}

pub struct Imap {
    pub c: Conn,
    tag: u32,
    pub caps: HashSet<String>,
}

fn parse_untagged(raw: &[u8], lits: Vec<Vec<u8>>) -> Untagged {
    // "* 12 FETCH (...)" / "* OK [UIDVALIDITY 3] ..." / "* SEARCH 1 2"
    let body = &raw[2.min(raw.len())..];
    let mut it = body.splitn(2, |&b| b == b' ');
    let first = it.next().unwrap_or(b"");
    let rest = it.next().unwrap_or(b"");
    if !first.is_empty() && first.iter().all(|b| b.is_ascii_digit()) {
        let mut it2 = rest.splitn(2, |&b| b == b' ');
        let kind = String::from_utf8_lossy(it2.next().unwrap_or(b"")).to_uppercase();
        let data = it2.next().unwrap_or(b"").to_vec();
        return Untagged { kind, num: std::str::from_utf8(first).ok().and_then(|s| s.parse().ok()), data, lits };
    }
    Untagged { kind: String::from_utf8_lossy(first).to_uppercase(), num: None, data: rest.to_vec(), lits }
}

/// [CODE value] at the start of a status text
fn response_code(text: &[u8]) -> Option<(String, String)> {
    let t = text.strip_prefix(b"[")?;
    let end = t.iter().position(|&b| b == b']')?;
    let inner = String::from_utf8_lossy(&t[..end]).into_owned();
    let mut it = inner.splitn(2, ' ');
    Some((it.next()?.to_uppercase(), it.next().unwrap_or("").to_string()))
}

impl Imap {
    pub fn connect(host: &str, port: u16, starttls: bool, timeout: Duration) -> IResult<Imap> {
        let sock = tcp(host, port, timeout)?;
        let clone = sock.try_clone()?;
        let s = if starttls { Stream::Plain(sock) } else { upgrade(host, sock)? };
        let mut im = Imap { c: Conn { s, sock: clone, buf: vec![] }, tag: 0, caps: HashSet::new() };
        let greet = im.c.line()?;
        if !greet.starts_with(b"* OK") && !greet.starts_with(b"* PREAUTH") {
            return Err(ImapError::No(String::from_utf8_lossy(&greet).trim().to_string()));
        }
        if starttls {
            im.command(&[Arg::Text("STARTTLS")])?;
            let plain = std::mem::replace(&mut im.c.s, Stream::Plain(im.c.sock.try_clone()?));
            let Stream::Plain(tcp_s) = plain else { unreachable!() };
            im.c.s = upgrade(host, tcp_s)?;
        }
        im.capability()?;
        Ok(im)
    }

    pub fn capability(&mut self) -> IResult<()> {
        let d = self.command(&[Arg::Text("CAPABILITY")])?;
        self.caps = d
            .untagged
            .iter()
            .filter(|u| u.kind == "CAPABILITY")
            .flat_map(|u| String::from_utf8_lossy(&u.data).split_whitespace().map(|s| s.to_uppercase()).collect::<Vec<_>>())
            .collect();
        Ok(())
    }

    pub fn has(&self, cap: &str) -> bool {
        self.caps.contains(cap)
    }

    /// Read one response (a line plus its literals) -> (raw with placeholders, literals)
    fn response(&mut self) -> IResult<(Vec<u8>, Vec<Vec<u8>>)> {
        let mut out = vec![];
        let mut lits = vec![];
        loop {
            let line = self.c.line()?;
            let body = line.strip_suffix(b"\r\n").or_else(|| line.strip_suffix(b"\n")).unwrap_or(&line);
            // a literal: the line ends with {n} or {n+}
            if body.ends_with(b"}") {
                if let Some(open) = body.iter().rposition(|&b| b == b'{') {
                    let num = std::str::from_utf8(&body[open + 1..body.len() - 1]).unwrap_or("").trim_end_matches('+');
                    if let Ok(n) = num.parse::<usize>() {
                        out.extend_from_slice(&body[..open]);
                        out.extend_from_slice(format!("\x00{}\x00", lits.len()).as_bytes());
                        lits.push(self.c.exact(n)?);
                        continue;
                    }
                }
            }
            out.extend_from_slice(body);
            return Ok((out, lits));
        }
    }

    fn quote_arg(s: &str) -> String {
        format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
    }

    /// Send a command; literals wait for the server's "+" continuation. Returns the completion.
    pub fn command(&mut self, args: &[Arg]) -> IResult<Done> {
        self.tag += 1;
        let tag = format!("G{:04}", self.tag);
        let mut pending: Vec<u8> = format!("{tag} ").into_bytes();
        let mut first = true;
        for a in args {
            if !first {
                pending.push(b' ');
            }
            first = false;
            match a {
                Arg::Text(t) => pending.extend_from_slice(t.as_bytes()),
                Arg::Lit(b) => {
                    pending.extend_from_slice(format!("{{{}}}\r\n", b.len()).as_bytes());
                    self.c.send(&pending)?;
                    pending.clear();
                    // wait for "+ ..." (untagged data may come first)
                    loop {
                        let (raw, _) = self.response()?;
                        if raw.starts_with(b"+") {
                            break;
                        }
                        if raw.starts_with(tag.as_bytes()) {
                            return Err(ImapError::No(String::from_utf8_lossy(&raw[tag.len()..]).trim().to_string()));
                        }
                    }
                    self.c.send(b)?;
                }
            }
        }
        pending.extend_from_slice(b"\r\n");
        self.c.send(&pending)?;
        self.finish(&tag)
    }

    fn finish(&mut self, tag: &str) -> IResult<Done> {
        let mut untagged = vec![];
        loop {
            let (raw, lits) = self.response()?;
            if raw.starts_with(b"* ") {
                let u = parse_untagged(&raw, lits);
                if u.kind == "BYE" {
                    return Err(ImapError::Io(io::Error::new(io::ErrorKind::ConnectionAborted, String::from_utf8_lossy(&u.data).into_owned())));
                }
                untagged.push(u);
                continue;
            }
            if raw.starts_with(b"+") {
                continue;
            }
            if raw.starts_with(tag.as_bytes()) {
                let rest = String::from_utf8_lossy(&raw[tag.len()..]).trim().to_string();
                let mut it = rest.splitn(2, ' ');
                let status = it.next().unwrap_or("").to_uppercase();
                let text = it.next().unwrap_or("").to_string();
                if status != "OK" {
                    return Err(ImapError::No(format!("{status} {text}").trim().to_string()));
                }
                return Ok(Done { status, text, untagged });
            }
        }
    }

    pub fn login(&mut self, user: &str, pass: &str) -> IResult<()> {
        let needs_lit = |s: &str| !s.is_ascii() || s.contains(['\r', '\n']);
        let (u, p) = (Self::quote_arg(user), Self::quote_arg(pass));
        let mut args = vec![Arg::Text("LOGIN")];
        if needs_lit(user) {
            args.push(Arg::Lit(user.as_bytes()));
        } else {
            args.push(Arg::Text(&u));
        }
        if needs_lit(pass) {
            args.push(Arg::Lit(pass.as_bytes()));
        } else {
            args.push(Arg::Text(&p));
        }
        self.command(&args)?;
        // capabilities often change after login
        let _ = self.capability();
        Ok(())
    }

    pub fn simple(&mut self, line: &str) -> IResult<Done> {
        self.command(&[Arg::Text(line)])
    }

    /// SELECT / EXAMINE -> {exists, uidvalidity, uidnext, highestmodseq}
    pub fn select(&mut self, quoted: &str, readonly: bool) -> IResult<(i64, i64, i64, i64)> {
        let d = self.simple(&format!("{} {quoted}", if readonly { "EXAMINE" } else { "SELECT" }))?;
        let mut exists = 0;
        let (mut uv, mut un, mut hm) = (0, 0, 0);
        for u in &d.untagged {
            if u.kind == "EXISTS" {
                exists = u.num.unwrap_or(0) as i64;
            }
            if u.kind == "OK" {
                if let Some((code, v)) = response_code(&u.data) {
                    let n = v.trim().parse().unwrap_or(0);
                    match code.as_str() {
                        "UIDVALIDITY" => uv = n,
                        "UIDNEXT" => un = n,
                        "HIGHESTMODSEQ" => hm = n,
                        _ => {}
                    }
                }
            }
        }
        if let Some((code, v)) = response_code(d.text.as_bytes()) {
            if code == "HIGHESTMODSEQ" {
                hm = v.trim().parse().unwrap_or(hm);
            }
        }
        Ok((exists, uv, un, hm))
    }

    /// The FETCH responses of a completion, as the buffer parse_fetch expects.
    pub fn fetch_buf(d: &Done) -> (Vec<u8>, Vec<Vec<u8>>) {
        let mut buf = vec![];
        let mut lits = vec![];
        for u in d.untagged.iter().filter(|u| u.kind == "FETCH") {
            buf.extend_from_slice(format!("{} ", u.num.unwrap_or(0)).as_bytes());
            // re-number the placeholders into one list
            let base = lits.len();
            let mut i = 0;
            while i < u.data.len() {
                if u.data[i] == 0 {
                    let end = u.data[i + 1..].iter().position(|&b| b == 0).map(|e| i + 1 + e).unwrap_or(u.data.len());
                    let idx: usize = std::str::from_utf8(&u.data[i + 1..end]).ok().and_then(|s| s.parse().ok()).unwrap_or(0);
                    buf.extend_from_slice(format!("\x00{}\x00", base + idx).as_bytes());
                    i = end + 1;
                } else {
                    buf.push(u.data[i]);
                    i += 1;
                }
            }
            lits.extend(u.lits.iter().cloned());
        }
        (buf, lits)
    }

    pub fn search_nums(d: &Done) -> Vec<i64> {
        d.untagged
            .iter()
            .filter(|u| u.kind == "SEARCH")
            .flat_map(|u| String::from_utf8_lossy(&u.data).split_whitespace().filter_map(|x| x.parse().ok()).collect::<Vec<i64>>())
            .collect()
    }

    pub fn list_lines(d: &Done) -> Vec<crate::imapparse::ListLine> {
        d.untagged
            .iter()
            .filter(|u| u.kind == "LIST" || u.kind == "XLIST")
            .map(|u| {
                if let Some(p) = u.data.iter().position(|&b| b == 0) {
                    (u.data[..p].to_vec(), u.lits.first().cloned())
                } else {
                    (u.data.clone(), None)
                }
            })
            .collect()
    }

    pub fn append(&mut self, quoted: &str, flags: &str, date: &str, msg: &[u8]) -> IResult<Done> {
        let head = format!("APPEND {quoted} {flags} \"{date}\"");
        self.command(&[Arg::Text(&head), Arg::Lit(msg)])
    }

    /// IDLE until something arrives (true) or `duration` passes (false). shutdown() from another
    /// thread ends it with an error.
    pub fn idle(&mut self, duration: Duration) -> IResult<bool> {
        self.tag += 1;
        let tag = format!("G{:04}", self.tag);
        self.c.send(format!("{tag} IDLE\r\n").as_bytes())?;
        loop {
            let (raw, _) = self.response()?;
            if raw.starts_with(b"+") {
                break;
            }
            if raw.starts_with(tag.as_bytes()) {
                return Err(ImapError::No(String::from_utf8_lossy(&raw).into_owned()));
            }
        }
        let deadline = Instant::now() + duration;
        let mut hit = false;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            self.c.set_timeout(Some(left));
            match self.response() {
                Ok((raw, lits)) => {
                    if raw.starts_with(b"* ") {
                        let u = parse_untagged(&raw, lits);
                        if u.kind == "BYE" {
                            return Err(ImapError::Io(io::Error::new(io::ErrorKind::ConnectionAborted, "BYE")));
                        }
                        if ["EXISTS", "EXPUNGE", "FETCH", "RECENT"].contains(&u.kind.as_str()) {
                            hit = true;
                            break;
                        }
                    }
                }
                Err(ImapError::Io(e)) if matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) => break,
                Err(e) => {
                    self.c.set_timeout(Some(Duration::from_secs(60)));
                    return Err(e);
                }
            }
        }
        self.c.set_timeout(Some(Duration::from_secs(60)));
        self.c.send(b"DONE\r\n")?;
        self.finish(&tag)?;
        Ok(hit)
    }

    pub fn shutdown_handle(&self) -> io::Result<TcpStream> {
        self.c.sock.try_clone()
    }

    pub fn logout(&mut self) {
        let _ = self.simple("LOGOUT");
        let _ = self.c.sock.shutdown(Shutdown::Both);
    }
}

// ---------------------------------------------------------------- SMTP

pub struct Smtp {
    c: Conn,
    pub ext: HashSet<String>,
    auth: Vec<String>,
}

#[derive(Debug)]
pub enum SmtpError {
    Io(io::Error),
    Auth(String),
    Reply(u16, String),
}

impl std::fmt::Display for SmtpError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            SmtpError::Io(e) => write!(f, "{}", py_io(e)),
            SmtpError::Auth(s) => write!(f, "{s}"),
            SmtpError::Reply(c, s) => write!(f, "({c}, '{s}')"),
        }
    }
}

impl From<io::Error> for SmtpError {
    fn from(e: io::Error) -> Self {
        SmtpError::Io(e)
    }
}

impl Smtp {
    fn reply(&mut self) -> Result<(u16, String), SmtpError> {
        let mut text = vec![];
        loop {
            let l = self.c.line()?;
            let s = String::from_utf8_lossy(&l).trim_end().to_string();
            let code: u16 = s.get(..3).and_then(|c| c.parse().ok()).unwrap_or(0);
            text.push(s.get(4..).unwrap_or("").to_string());
            if s.as_bytes().get(3) != Some(&b'-') {
                return Ok((code, text.join("\n")));
            }
        }
    }

    fn cmd(&mut self, line: &str) -> Result<(u16, String), SmtpError> {
        self.c.send(format!("{line}\r\n").as_bytes())?;
        self.reply()
    }

    fn ehlo(&mut self) -> Result<(), SmtpError> {
        let (code, text) = self.cmd("EHLO glass-mail")?;
        if code != 250 {
            let (c2, t2) = self.cmd("HELO glass-mail")?;
            if c2 != 250 {
                return Err(SmtpError::Reply(c2, t2));
            }
            self.ext.clear();
            return Ok(());
        }
        self.ext.clear();
        self.auth.clear();
        for l in text.lines().skip(1) {
            let up = l.to_uppercase();
            let mut it = up.split_whitespace();
            if let Some(k) = it.next() {
                if k == "AUTH" || k.starts_with("AUTH=") {
                    self.auth.extend(it.map(String::from));
                    if let Some(rest) = k.strip_prefix("AUTH=") {
                        self.auth.push(rest.to_string());
                    }
                    self.ext.insert("AUTH".into());
                } else {
                    self.ext.insert(k.to_string());
                }
            }
        }
        Ok(())
    }

    /// security: "ssl" | "starttls" | anything else (plain)
    pub fn connect(host: &str, port: u16, security: &str, timeout: Duration) -> Result<Smtp, SmtpError> {
        let sock = tcp(host, port, timeout)?;
        let clone = sock.try_clone()?;
        let s = if security == "ssl" { upgrade(host, sock)? } else { Stream::Plain(sock) };
        let mut m = Smtp { c: Conn { s, sock: clone, buf: vec![] }, ext: HashSet::new(), auth: vec![] };
        let (code, text) = m.reply()?;
        if code != 220 {
            return Err(SmtpError::Reply(code, text));
        }
        m.ehlo()?;
        if security == "starttls" {
            let (code, text) = m.cmd("STARTTLS")?;
            if code != 220 {
                return Err(SmtpError::Reply(code, text));
            }
            let plain = std::mem::replace(&mut m.c.s, Stream::Plain(m.c.sock.try_clone()?));
            let Stream::Plain(t) = plain else { unreachable!() };
            m.c.s = upgrade(host, t)?;
            m.ehlo()?;
        }
        Ok(m)
    }

    pub fn has_auth(&self) -> bool {
        self.ext.contains("AUTH")
    }

    pub fn login(&mut self, user: &str, pass: &str) -> Result<(), SmtpError> {
        use base64::Engine as _;
        let b64 = |s: &[u8]| base64::engine::general_purpose::STANDARD.encode(s);
        let (code, text) = if self.auth.iter().any(|a| a == "PLAIN") || !self.auth.iter().any(|a| a == "LOGIN") {
            let token = b64(format!("\0{user}\0{pass}").as_bytes());
            self.cmd(&format!("AUTH PLAIN {token}"))?
        } else {
            let (c, t) = self.cmd("AUTH LOGIN")?;
            if c != 334 {
                (c, t)
            } else {
                let (c, t) = self.cmd(&b64(user.as_bytes()))?;
                if c != 334 {
                    (c, t)
                } else {
                    self.cmd(&b64(pass.as_bytes()))?
                }
            }
        };
        if code != 235 && code != 503 {
            return Err(SmtpError::Auth(text));
        }
        Ok(())
    }

    pub fn send(&mut self, from: &str, rcpts: &[String], data: &[u8]) -> Result<(), SmtpError> {
        let intl = !from.is_ascii() || rcpts.iter().any(|r| !r.is_ascii());
        let mut opts = String::new();
        if self.ext.contains("SIZE") {
            opts += &format!(" SIZE={}", data.len());
        }
        if intl && self.ext.contains("SMTPUTF8") {
            opts += " SMTPUTF8 BODY=8BITMIME";
        }
        let (c, t) = self.cmd(&format!("MAIL FROM:<{from}>{opts}"))?;
        if c != 250 {
            return Err(SmtpError::Reply(c, t));
        }
        let mut ok = 0;
        let mut last_err = (0, String::new());
        for r in rcpts {
            let (c, t) = self.cmd(&format!("RCPT TO:<{r}>"))?;
            if c == 250 || c == 251 {
                ok += 1;
            } else {
                last_err = (c, t);
            }
        }
        if ok == 0 {
            let _ = self.cmd("RSET");
            return Err(SmtpError::Reply(last_err.0, format!("all recipients were refused: {}", last_err.1)));
        }
        let (c, t) = self.cmd("DATA")?;
        if c != 354 {
            return Err(SmtpError::Reply(c, t));
        }
        let mut body = Vec::with_capacity(data.len() + 64);
        for line in data.split_inclusive(|&b| b == b'\n') {
            let l = line.strip_suffix(b"\n").unwrap_or(line);
            let l = l.strip_suffix(b"\r").unwrap_or(l);
            if l.starts_with(b".") {
                body.push(b'.');
            }
            body.extend_from_slice(l);
            body.extend_from_slice(b"\r\n");
        }
        body.extend_from_slice(b".\r\n");
        self.c.send(&body)?;
        let (c, t) = self.reply()?;
        if c != 250 {
            return Err(SmtpError::Reply(c, t));
        }
        Ok(())
    }

    pub fn quit(&mut self) {
        let _ = self.cmd("QUIT");
        let _ = self.c.sock.shutdown(Shutdown::Both);
    }
}
