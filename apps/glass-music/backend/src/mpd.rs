//! A tiny MPD client (port of mpdclient.py, same wire handling as music-smart).
use std::io::{self, BufRead, BufReader, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::net::TcpStream;
use std::time::Duration;

#[derive(Debug)]
pub enum Error {
    Io(io::Error),
    /// MPD answered ACK (or isn't MPD)
    Ack(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            Error::Io(e) => write!(f, "{e}"),
            Error::Ack(s) => write!(f, "{s}"),
        }
    }
}

impl From<io::Error> for Error {
    fn from(e: io::Error) -> Self {
        Error::Io(e)
    }
}

pub type Result<T> = std::result::Result<T, Error>;
pub type Pairs = Vec<(String, String)>;

pub fn quote(a: &str) -> String {
    format!("\"{}\"", a.replace('\\', "\\\\").replace('"', "\\\""))
}

pub fn default_address() -> String {
    if let Ok(e) = std::env::var("GLASS_MUSIC_MPD") {
        if !e.is_empty() {
            return e;
        }
    }
    let rt = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| format!("/run/user/{}", unsafe { libc::getuid() }));
    let p = format!("{rt}/mpd/socket");
    if std::path::Path::new(&p).exists() {
        return p;
    }
    "127.0.0.1:6600".into()
}

enum Sock {
    Unix(UnixStream),
    Tcp(TcpStream),
}

impl Sock {
    fn try_clone(&self) -> io::Result<Sock> {
        Ok(match self {
            Sock::Unix(s) => Sock::Unix(s.try_clone()?),
            Sock::Tcp(s) => Sock::Tcp(s.try_clone()?),
        })
    }
    fn set_read_timeout(&self, t: Option<Duration>) {
        let _ = match self {
            Sock::Unix(s) => s.set_read_timeout(t),
            Sock::Tcp(s) => s.set_read_timeout(t),
        };
    }
    fn fd(&self) -> i32 {
        match self {
            Sock::Unix(s) => s.as_raw_fd(),
            Sock::Tcp(s) => s.as_raw_fd(),
        }
    }
    pub fn shutdown(&self) {
        let _ = match self {
            Sock::Unix(s) => s.shutdown(std::net::Shutdown::Both),
            Sock::Tcp(s) => s.shutdown(std::net::Shutdown::Both),
        };
    }
}

impl io::Read for Sock {
    fn read(&mut self, b: &mut [u8]) -> io::Result<usize> {
        match self {
            Sock::Unix(s) => s.read(b),
            Sock::Tcp(s) => s.read(b),
        }
    }
}

impl io::Write for Sock {
    fn write(&mut self, b: &[u8]) -> io::Result<usize> {
        match self {
            Sock::Unix(s) => s.write(b),
            Sock::Tcp(s) => s.write(b),
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

pub struct Mpd {
    r: BufReader<Sock>,
    w: Sock,
    timeout: Duration,
    /// writes that reached the socket; Server::call retries only while unchanged
    pub sent: u64,
}

/// A song from a pair list: file plus tags; Artist / Genre / AlbumArtist are lists.
#[derive(Debug, Default, Clone)]
pub struct Song {
    pub file: String,
    pub tags: Vec<(String, String)>,
}

impl Song {
    /// first value of a tag (cur.setdefault semantics)
    pub fn get(&self, k: &str) -> Option<&str> {
        self.tags.iter().find(|(a, _)| a == k).map(|(_, v)| v.as_str())
    }
    pub fn list(&self, k: &str) -> Vec<&str> {
        self.tags.iter().filter(|(a, _)| a == k).map(|(_, v)| v.as_str()).collect()
    }
}

impl Mpd {
    pub fn connect(address: &str) -> Result<Mpd> {
        let timeout = Duration::from_secs(10);
        let s = if address.starts_with('/') {
            let s = UnixStream::connect(address)?;
            Sock::Unix(s)
        } else {
            let (host, port) = match address.rfind(':') {
                Some(i) => (&address[..i], &address[i + 1..]),
                None => ("", address),
            };
            let host = if host.is_empty() { "127.0.0.1" } else { host };
            let port: u16 = port.parse().unwrap_or(6600);
            use std::net::ToSocketAddrs;
            let addr = (host, port).to_socket_addrs()?.next().ok_or_else(|| io::Error::other("no address"))?;
            Sock::Tcp(TcpStream::connect_timeout(&addr, timeout)?)
        };
        s.set_read_timeout(Some(timeout));
        let w = s.try_clone()?;
        let mut m = Mpd { r: BufReader::new(s), w, timeout, sent: 0 };
        let mut hello = vec![];
        m.r.read_until(b'\n', &mut hello)?;
        if !hello.starts_with(b"OK MPD") {
            return Err(Error::Ack("not an MPD server".into()));
        }
        Ok(m)
    }

    /// True if the peer already closed this idle connection (EOF or junk waiting to be read).
    pub fn stale(&self) -> bool {
        if !self.r.buffer().is_empty() {
            return true;
        }
        let mut p = libc::pollfd { fd: self.w.fd(), events: libc::POLLIN, revents: 0 };
        let n = unsafe { libc::poll(&mut p, 1, 0) };
        n != 0
    }

    pub fn shutdown(&self) {
        self.w.shutdown();
    }

    fn send(&mut self, line: &str) -> Result<()> {
        self.w.write_all(format!("{line}\n").as_bytes())?;
        self.sent += 1;
        Ok(())
    }

    fn read(&mut self, list_ok: bool) -> Result<Pairs> {
        let mut pairs = vec![];
        loop {
            let mut raw = vec![];
            let n = self.r.read_until(b'\n', &mut raw)?;
            if n == 0 {
                return Err(Error::Io(io::Error::new(io::ErrorKind::ConnectionAborted, "MPD closed the connection")));
            }
            let line = String::from_utf8_lossy(&raw);
            let line = line.trim_end_matches('\n');
            if line == "OK" || (list_ok && line == "list_OK") {
                return Ok(pairs);
            }
            if line.starts_with("ACK") {
                return Err(Error::Ack(line.to_string()));
            }
            match line.split_once(": ") {
                Some((k, v)) => pairs.push((k.to_string(), v.to_string())),
                None => pairs.push((line.to_string(), String::new())),
            }
        }
    }

    fn line(name: &str, args: &[&str]) -> String {
        let mut s = name.to_string();
        for a in args {
            s.push(' ');
            s.push_str(&quote(a));
        }
        s
    }

    pub fn cmd(&mut self, name: &str, args: &[&str]) -> Result<Pairs> {
        self.send(&Self::line(name, args))?;
        self.read(false)
    }

    /// Run a command list; one pair list per command (an ACK cuts the list short).
    pub fn batch(&mut self, cmds: &[Vec<String>]) -> Result<Vec<Pairs>> {
        if cmds.is_empty() {
            return Ok(vec![]);
        }
        let mut lines = vec!["command_list_ok_begin".to_string()];
        for c in cmds {
            let args: Vec<&str> = c[1..].iter().map(String::as_str).collect();
            lines.push(Self::line(&c[0], &args));
        }
        lines.push("command_list_end".into());
        self.w.write_all((lines.join("\n") + "\n").as_bytes())?;
        self.sent += 1;
        let mut out = vec![];
        let r: Result<()> = (|| {
            for _ in cmds {
                out.push(self.read(true)?);
            }
            self.read(false)?;
            Ok(())
        })();
        match r {
            Ok(()) | Err(Error::Ack(_)) => Ok(out),
            Err(e) => Err(e),
        }
    }

    pub fn dict(&mut self, name: &str, args: &[&str]) -> Result<indexmap::IndexMap<String, String>> {
        let mut d = indexmap::IndexMap::new();
        for (k, v) in self.cmd(name, args)? {
            d.entry(k).or_insert(v);
        }
        Ok(d)
    }

    pub fn idle(&mut self, subsystems: &[&str]) -> Result<Vec<String>> {
        let mut l = "idle".to_string();
        for s in subsystems {
            l.push(' ');
            l.push_str(s);
        }
        self.send(&l)?;
        self.w.set_read_timeout(None);
        let r = self.read(false);
        self.w.set_read_timeout(Some(self.timeout));
        Ok(r?.into_iter().filter(|(k, _)| k == "changed").map(|(_, v)| v).collect())
    }

    pub fn songs(pairs: &Pairs) -> Vec<Song> {
        let mut out: Vec<Option<Song>> = vec![];
        let mut have = false;
        for (k, v) in pairs {
            if k == "file" || k == "directory" || k == "playlist" {
                out.push(if k == "file" { Some(Song { file: v.clone(), tags: vec![] }) } else { None });
                have = true;
                continue;
            }
            if !have {
                continue;
            }
            if let Some(Some(s)) = out.last_mut() {
                s.tags.push((k.clone(), v.clone()));
            }
        }
        out.into_iter().flatten().collect()
    }
}
