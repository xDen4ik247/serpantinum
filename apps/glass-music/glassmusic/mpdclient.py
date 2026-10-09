"""A tiny dependency-free MPD client (same wire handling as music-smart)."""

import os
import socket


class MPDError(Exception):
    pass


def quote(a):
    a = str(a)
    return '"' + a.replace("\\", "\\\\").replace('"', '\\"') + '"'


def default_address():
    env = os.environ.get("GLASS_MUSIC_MPD")
    if env:
        return env
    rt = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    path = os.path.join(rt, "mpd", "socket")
    if os.path.exists(path):
        return path
    return "127.0.0.1:6600"


class MPD:
    def __init__(self, address=None, timeout=10):
        self.address = address or default_address()
        self.timeout = timeout
        self.sock = None
        self.f = None
        self.connect()

    def connect(self):
        a = self.address
        if a.startswith("/"):
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(self.timeout)
            s.connect(a)
        else:
            host, _, port = a.rpartition(":")
            s = socket.create_connection((host or "127.0.0.1", int(port or 6600)), timeout=self.timeout)
        self.sock = s
        self.f = s.makefile("rwb")
        hello = self.f.readline()
        if not hello.startswith(b"OK MPD"):
            raise MPDError("not an MPD server")

    def close(self):
        try:
            self.f.write(b"close\n")
            self.f.flush()
        except Exception:
            pass
        try:
            self.sock.close()
        except Exception:
            pass

    def _send(self, line):
        self.f.write(line.encode() + b"\n")
        self.f.flush()

    def _read(self, list_ok=False):
        pairs = []
        while True:
            raw = self.f.readline()
            if not raw:
                raise ConnectionError("MPD closed the connection")
            line = raw.decode("utf-8", "replace").rstrip("\n")
            if line == "OK" or (list_ok and line == "list_OK"):
                return pairs
            if line.startswith("ACK"):
                raise MPDError(line)
            k, _, v = line.partition(": ")
            pairs.append((k, v))

    def cmd(self, name, *args):
        self._send(" ".join([name] + [quote(a) for a in args]))
        return self._read()

    def batch(self, cmds):
        """Run a command list; returns one pair list per command."""
        if not cmds:
            return []
        lines = ["command_list_ok_begin"]
        for c in cmds:
            lines.append(" ".join([c[0]] + [quote(a) for a in c[1:]]))
        lines.append("command_list_end")
        self.f.write(("\n".join(lines) + "\n").encode())
        self.f.flush()
        out = []
        try:
            for _ in cmds:
                out.append(self._read(list_ok=True))
            self._read()
        except MPDError:
            # an ACK aborts the rest of the list
            pass
        return out

    def dict(self, name, *args):
        d = {}
        for k, v in self.cmd(name, *args):
            d.setdefault(k, v)
        return d

    def idle(self, *subsystems):
        self._send(" ".join(["idle"] + list(subsystems)))
        self.sock.settimeout(None)
        try:
            return [v for k, v in self._read() if k == "changed"]
        finally:
            self.sock.settimeout(self.timeout)

    @staticmethod
    def songs(pairs):
        out, cur = [], None
        for k, v in pairs:
            if k in ("file", "directory", "playlist"):
                cur = {"_kind": k, "file": v} if k == "file" else {"_kind": k}
                out.append(cur)
                continue
            if cur is None:
                continue
            if k in ("Artist", "Genre", "AlbumArtist"):
                cur.setdefault(k, []).append(v)
            else:
                cur.setdefault(k, v)
        return [s for s in out if s.get("_kind") == "file"]
