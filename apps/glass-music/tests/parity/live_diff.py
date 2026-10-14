"""Differential test: the Python and the Rust backend run the same scripted session against a private
MPD (own socket, database, state, null audio output) whose music folder is a symlink mirror of the
real library plus a few generated test songs, with fakes for the Yandex worker, LRCLIB, music-smart
and the desktop Trash. Everything they emit and leave behind is normalized and compared.
Nothing outside the output folder is written: the mirror holds symlinks, new files land in it.

    python -m tests.parity.live_diff [--only python|rust] [--music DIR]
"""
import calendar
import hashlib
import http.server
import json
import os
import queue
import re
import shutil
import socket
import socketserver
import subprocess
import sys
import threading
import time
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUST = os.path.join(ROOT, "backend/target/release/glass-music-backend")
OUT = os.environ.get("GLASS_MUSIC_DIFF_OUT", os.path.join(ROOT, "tests/parity/out"))
HOME = os.path.expanduser("~")
LRCLIB_PORT = 31927
M = os.path.join(OUT, "music")
MPD_DIR = os.path.join(OUT, "mpd")
SOCK = os.path.join(MPD_DIR, "socket")
CACHE = os.path.join(OUT, "cache")


# ---------------------------------------------------------------- fake LRCLIB
LRC_REQS = []
LRC_DB = {
    "Lost Song": [{"id": 1, "trackName": "Lost Song", "artistName": "Zz Tester", "duration": 120,
                   "syncedLyrics": "[00:01.00]found it\n[00:03.00]on lrclib", "plainLyrics": "found it\non lrclib"},
                  {"id": 2, "trackName": "Lost Song (Live)", "artistName": "Zz Tester", "duration": 121,
                   "syncedLyrics": "[00:01.00]the live one", "plainLyrics": "the live one"}],
    "Plain Song": [{"id": 3, "trackName": "Plain Song", "artistName": "Zz Tester", "duration": 120, "plainLyrics": "lrclib plain"}],
    "Instrumental Song": [{"id": 4, "trackName": "Instrumental Song", "artistName": "Zz Tester", "duration": 120, "instrumental": True}],
}


class LrcHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        LRC_REQS.append(u.path + "?" + u.query)
        hits = LRC_DB.get(q.get("track_name", ""), [])
        if u.path.endswith("/get"):
            exact = [h for h in hits if h["trackName"] == q.get("track_name") and q.get("album_name") == "Zz Album"]
            code, body = (200, exact[0]) if exact and q["track_name"] == "Plain Song" else (404, {"code": 404})
        else:
            code, body = 200, hits
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class LrcServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


# ---------------------------------------------------------------- the world
def sh(*a, **kw):
    return subprocess.run(a, check=True, capture_output=True, **kw)


def make_fixtures(music_src):
    """The pristine test world in OUT/pristine (built once): mirror, test songs, MPD database."""
    P = os.path.join(OUT, "pristine")
    stamp = os.path.join(P, ".done")
    if os.path.exists(stamp):
        return P
    shutil.rmtree(P, ignore_errors=True)
    os.makedirs(P)
    fx = os.path.join(OUT, "fixtures")
    os.makedirs(fx, exist_ok=True)
    music = os.path.join(P, "music")
    # symlink mirror of the real library
    for base, dirs, files in os.walk(music_src):
        rel = os.path.relpath(base, music_src)
        d = os.path.join(music, rel) if rel != "." else music
        os.makedirs(d, exist_ok=True)
        for f in files:
            os.symlink(os.path.join(base, f), os.path.join(d, f))
    # generated songs (real files: these get removed / get lyrics written next to them)
    alb = os.path.join(music, "Zz Tester", "Zz Album")
    os.makedirs(alb)

    def tone(path, title, extra=()):
        sh("ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "anullsrc=r=8000:cl=mono", "-t", "120",
           "-metadata", f"title={title}", "-metadata", "artist=Zz Tester", "-metadata", "album=Zz Album",
           "-metadata", "genre=Shoegaze", *extra, path)

    for n, t in enumerate(["Lost Song", "Plain Song", "Instrumental Song", "Ym Song", "Broken Song"], 1):
        tone(os.path.join(alb, f"{n:02d} - {t}.flac"), t, ("-metadata", f"track={n}"))
    with open(os.path.join(alb, "04 - Ym Song.txt"), "w") as f:
        f.write("old plain words\n")
    tone(os.path.join(music, "Zz Tester", "Zz Album", "06 - Tagged.mp3"), "Tagged",
         ("-metadata", "lyrics=[00:01.00]id3 synced\n[00:02.00]line two", "-id3v2_version", "3", "-metadata", "track=6"))
    tone(os.path.join(music, "Zz Tester", "Zz Album", "07 - Mp4.m4a"), "Mp4", ("-metadata", "lyrics=mp4 plain lyrics", "-metadata", "track=7"))
    # an album to remove: two songs, a cover and a stray .lrc
    rm = os.path.join(music, "Zz Gone", "Gone Album")
    os.makedirs(rm)
    for n in (1, 2):
        tone(os.path.join(rm, f"0{n} - Gone {n}.flac"), f"Gone {n}")
    with open(os.path.join(rm, "01 - Gone 1.lrc"), "w") as f:
        f.write("[00:01.00]bye\n")
    covers = [os.path.join(b, "cover.jpg") for b, _, fs in os.walk(music_src) if "cover.jpg" in fs]
    if covers:
        shutil.copy(sorted(covers)[0], os.path.join(rm, "cover.jpg"))
        shutil.copy(sorted(covers)[-1], os.path.join(alb, "cover.jpg"))
    tone(os.path.join(fx, "dl.flac"), "Downloaded")
    # MPD database
    os.makedirs(os.path.join(P, "mpd", "playlists"))
    open(stamp + ".tmp", "w").close()
    start_mpd(P)
    for _ in range(600):
        st = mpd_cmd("status")
        if "updating_db" not in st:
            break
        time.sleep(0.5)
    stop_mpd()
    os.rename(stamp + ".tmp", stamp)
    return P


MPD_PROC = None


def start_mpd(base):
    global MPD_PROC
    conf = os.path.join(base, "mpd", "mpd.conf")
    os.makedirs(os.path.join(base, "mpd", "playlists"), exist_ok=True)
    first = not os.path.exists(os.path.join(base, "mpd", "db"))
    with open(conf, "w") as f:
        f.write(f'''music_directory "{base}/music"
db_file "{base}/mpd/db"
state_file "{base}/mpd/state"
sticker_file "{base}/mpd/sticker.sql"
playlist_directory "{base}/mpd/playlists"
bind_to_address "{SOCK}"
log_file "{base}/mpd/log"
auto_update "no"
restore_paused "yes"
audio_output {{
    type "null"
    name "null"
    mixer_type "software"
}}
''')
    if os.path.exists(SOCK):
        os.remove(SOCK)
    os.makedirs(os.path.dirname(SOCK), exist_ok=True)
    MPD_PROC = subprocess.Popen(["mpd", "--no-daemon", conf], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(200):
        if os.path.exists(SOCK):
            try:
                mpd_cmd("ping")
                break
            except OSError:
                pass
        time.sleep(0.05)
    if first:
        mpd_cmd("update")


def stop_mpd():
    global MPD_PROC
    if MPD_PROC:
        MPD_PROC.terminate()
        MPD_PROC.wait(10)
        MPD_PROC = None


def mpd_cmd(*args, pairs=False):
    s = socket.socket(socket.AF_UNIX)
    s.connect(SOCK)
    f = s.makefile("rwb")
    f.readline()
    f.write((" ".join([args[0]] + ['"%s"' % a.replace("\\", "\\\\").replace('"', '\\"') for a in args[1:]]) + "\n").encode())
    f.flush()
    out = []
    while True:
        ln = f.readline().decode().rstrip("\n")
        if ln == "OK" or ln.startswith("ACK") or not ln:
            break
        k, _, v = ln.partition(": ")
        out.append((k, v))
    s.close()
    return out if pairs else dict(out)


def smart_fake():
    """music-smart stand-in: the real genre rules (the Python backend loads them from this file),
    and run as a program it only logs its arguments."""
    src = open(os.path.expanduser("~/.local/bin/music-smart"), encoding="utf-8").read()
    rules = re.search(r"^GENRE_RULES = \[.*?^\]\n", src, re.S | re.M).group(0)
    funcs = re.search(r"^def norm_genre\(g\):.*?\n\n\ndef mood_of\(genres\):.*?\n\n\n", src, re.S | re.M).group(0)
    return (f"#!{sys.executable}\nimport re\nimport sys\n\n{rules}\n\n{funcs}"
            f"if __name__ == '__main__':\n    with open({os.path.join(OUT, 'smart.log')!r}, 'a') as f:\n"
            f"        f.write(' '.join(sys.argv[1:]) + '\\n')\n")


def bin_fakes():
    b = os.path.join(OUT, "bin")
    os.makedirs(b, exist_ok=True)
    py = sys.executable
    files = {
        "gio": f'#!/bin/sh\n# fake desktop Trash: log, then delete\n[ "$1" = trash ] && shift\n[ "$1" = -- ] && shift\nprintf "%s\\n" "$@" >> "{OUT}/gio.log"\nrm -rf -- "$@"\n',
        "music-smart": smart_fake(),
        "ym-python": f'#!/bin/sh\n# the app runs: <python> -m glassmusic.yandex serve\nexec "{py}" "{ROOT}/tests/parity/fake_ym.py"\n',
    }
    for n, t in files.items():
        p = os.path.join(b, n)
        with open(p, "w") as f:
            f.write(t)
        os.chmod(p, 0o755)
    return b


# ---------------------------------------------------------------- normalization
PRISTINE_T = 0.0      # when the pristine MPD database was built
VOLATILE = {"ms", "elapsed", "trace", "stamp"}   # stamp: MPD db_update, the database changes during a run


def norm(o, key=None):
    if isinstance(o, dict):
        return {k: norm(v, k) for k, v in o.items()}
    if isinstance(o, list):
        return [norm(v) for v in o]
    if key in VOLATILE:
        return "*"
    if isinstance(o, str):
        # MPD's "Added" time of files created during a run (the two runs are minutes apart)
        if key == "ad" and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", o):
            t = calendar.timegm(time.strptime(o, "%Y-%m-%dT%H:%M:%SZ"))
            if t > PRISTINE_T + 5:
                return "ADDED-IN-RUN"
        return o.replace(OUT, "$OUT")
    if isinstance(o, (int, float)) and not isinstance(o, bool) and abs(o - time.time()) < 86400:
        return "NOW"
    return o


# ---------------------------------------------------------------- one run
class Run:
    def __init__(self, name, cmd):
        self.name, self.cmd = name, cmd
        self.steps, self.err = [], []

    def start(self, P):
        stop_mpd()
        for d in ("music", "mpd", "cache", "home", "config", "state"):
            shutil.rmtree(os.path.join(OUT, d), ignore_errors=True)
        sh("cp", "-a", os.path.join(P, "music"), M)
        sh("cp", "-a", os.path.join(P, "mpd"), MPD_DIR)
        for f in ("gio.log", "smart.log", "ym.log"):
            open(os.path.join(OUT, f), "w").close()
        os.makedirs(os.path.join(OUT, "config", "glass-music"))
        with open(os.path.join(OUT, "config", "glass-music", "yandex.json"), "w") as f:
            json.dump({"token": "fake"}, f)
        os.makedirs(os.path.join(OUT, "home"))
        os.makedirs(os.path.join(OUT, "state", "music-smart"))
        start_mpd(OUT)
        LRC_REQS.clear()
        b = bin_fakes()
        hist = os.path.join(HOME, ".local/share/music-smart/history.sqlite")
        hcopy = os.path.join(OUT, "history.sqlite")
        if os.path.exists(hist) and not os.path.exists(hcopy):
            shutil.copy(hist, hcopy)
        env = dict(os.environ, HOME=os.path.join(OUT, "home"), PATH=b + ":" + os.environ["PATH"], PYTHONPATH=ROOT,
                   PYTHONUNBUFFERED="1", GLASS_MUSIC_MPD=SOCK, GLASS_MUSIC_CACHE=CACHE, GLASS_MUSIC_HISTORY=hcopy,
                   GLASS_MUSIC_SMART_STATE=os.path.join(OUT, "state", "music-smart", "state.json"),
                   GLASS_MUSIC_SMART_BIN=os.path.join(b, "music-smart"), GLASS_MUSIC_YM_PYTHON=os.path.join(b, "ym-python"),
                   GLASS_MUSIC_LRCLIB=f"http://127.0.0.1:{LRCLIB_PORT}/api", XDG_CONFIG_HOME=os.path.join(OUT, "config"),
                   GM_TEST_OUT=OUT, GLASS_MUSIC_SMART_ENV=json.dumps({"MS_TEST": "1"}), LC_ALL="C.UTF-8")
        env.pop("GLASS_MUSIC_DIR", None)
        self.t0 = time.time()
        self.p = subprocess.Popen(self.cmd, cwd=ROOT, env=env, text=True, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.q = queue.Queue()
        threading.Thread(target=lambda: [self.q.put(json.loads(ln)) for ln in self.p.stdout], daemon=True).start()
        threading.Thread(target=lambda: [self.err.append(ln) for ln in self.p.stderr], daemon=True).start()
        self.seen = {"lrc": 0, "gio": 0, "smart": 0, "ym": 0}

    def send(self, o):
        self.p.stdin.write((json.dumps(o, ensure_ascii=False) if not isinstance(o, str) else o) + "\n")
        self.p.stdin.flush()

    def tail(self, name):
        with open(os.path.join(OUT, f"{name}.log")) as f:
            lines = f.readlines()
        new = lines[self.seen[name]:]
        self.seen[name] = len(lines)
        return [ln.rstrip("\n") for ln in new]

    def collect(self, label, until=None, quiet=1.0, t=40):
        out, done, last, end = [], until is None, time.time(), time.time() + t
        while time.time() < end:
            try:
                m = self.q.get(timeout=0.05)
                out.append(m)
                last = time.time()
                if not done and until(m):
                    done = True
            except queue.Empty:
                if done and time.time() - last >= quiet:
                    break
        else:
            out.append({"type": "_TIMEOUT"})
        for r in LRC_REQS[self.seen["lrc"]:]:
            out.append({"type": "_lrclib", "q": r})
        self.seen["lrc"] = len(LRC_REQS)
        for n in ("gio", "smart"):
            for ln in self.tail(n):
                out.append({"type": f"_{n}", "line": ln})
        for ln in self.tail("ym"):
            out.append({"type": "_ym", "cmd": json.loads(ln)})
        self.steps.append((label, [norm(m) for m in out]))
        return out

    def step(self, label, cmd, until=None, **kw):
        self.send(cmd)
        return self.collect(label, until, **kw)

    # ---------------------------------------------------------------- the session
    def script(self):
        S = self.step
        got = S("hello", {"cmd": "hello"}, lambda m: m["type"] == "home", quiet=2.5, t=90)
        lib = next(m for m in got if m["type"] == "library")["lib"]
        tracks = lib["tracks"]
        f_of = {t["t"]: t["f"] for t in tracks}
        for i, q in enumerate(["zz", "lost", "ЗЗ", "pfp", "ys", "nothing at all", "", "Gone"]):
            S(f"search {q!r}", {"cmd": "search", "q": q, "rid": i}, lambda m: m["type"] == "search", quiet=0.2)
        keys = [a["k"] for a in lib["albums"]][:40] + ["Zz Tester/Zz Album", "nope/nope"]
        S("thumbs", {"cmd": "thumbs", "keys": keys}, lambda m: m["type"] == "thumbs", quiet=3.0, t=120)
        S("thumbs again", {"cmd": "thumbs", "keys": keys[:5]}, lambda m: m["type"] == "thumbs", quiet=1.0)
        with_lrc = [t["f"] for t in tracks if t["l"]][:2]
        for f in with_lrc + [f_of["Tagged"], f_of["Mp4"], "file:///nonexistent.flac", "http://stream", ""]:
            S(f"lyrics {f}", {"cmd": "lyrics", "file": f}, lambda m: m["type"] == "lyrics", quiet=1.5)
        for t in ("Lost Song", "Plain Song", "Instrumental Song", "Ym Song"):
            S(f"lyrics {t}", {"cmd": "lyrics", "file": f_of[t]}, lambda m: m["type"] == "lyrics", quiet=2.0)
        S("lyrics Broken Song", {"cmd": "lyrics", "file": f_of["Broken Song"]}, lambda m: m["type"] == "lyrics", quiet=2.0)
        S("lyricsfind plain", {"cmd": "lyricsfind", "file": f_of["Plain Song"]}, lambda m: m["type"] == "lyrics", quiet=2.0)
        S("lyricswrong lost", {"cmd": "lyricswrong", "file": f_of["Lost Song"]}, lambda m: m["type"] == "lyrics", quiet=2.5)
        S("lyricswrong lost again", {"cmd": "lyricswrong", "file": f_of["Lost Song"]}, lambda m: m["type"] == "lyrics", quiet=2.5)
        S("lyricswrong own file", {"cmd": "lyricswrong", "file": with_lrc[0]}, lambda m: m["type"] == "lyrics", quiet=2.0)
        album = [f_of[t] for t in ("Lost Song", "Plain Song", "Instrumental Song", "Ym Song", "Broken Song")]
        S("play", {"cmd": "play", "files": album, "index": 1}, lambda m: m["type"] == "status", quiet=2.5)
        S("pause", {"cmd": "toggle"}, lambda m: m["type"] == "status", quiet=1.0)
        S("seek", {"cmd": "seek", "pos": 12.345}, lambda m: m["type"] == "status", quiet=1.0)
        S("volume", {"cmd": "volume", "value": 130}, lambda m: m["type"] == "status", quiet=1.0)
        S("random on", {"cmd": "random", "on": True}, lambda m: m["type"] == "status", quiet=1.0)
        S("random off", {"cmd": "random", "on": False}, lambda m: m["type"] == "status", quiet=1.0)
        for mode in ("all", "one", "off"):
            S(f"repeat {mode}", {"cmd": "repeat", "mode": mode}, lambda m: m["type"] == "status", quiet=1.0)
        S("add next", {"cmd": "add", "files": [f_of["Tagged"], f_of["Mp4"]], "next": True}, lambda m: m["type"] == "queue", quiet=1.5)
        S("add", {"cmd": "add", "files": [with_lrc[0]]}, lambda m: m["type"] == "queue", quiet=1.5)
        S("same play = jump", {"cmd": "play", "files": album, "index": 3}, lambda m: m["type"] == "status", quiet=2.0)
        S("pause again", {"cmd": "toggle"}, lambda m: m["type"] == "status", quiet=1.0)
        ids = [int(v) for k, v in mpd_cmd("playlistinfo", pairs=True) if k == "Id"]
        S("playid", {"cmd": "playid", "id": ids[0]}, lambda m: m["type"] == "status", quiet=1.5)
        S("toggle 3", {"cmd": "toggle"}, lambda m: m["type"] == "status", quiet=1.0)
        S("moveid", {"cmd": "moveid", "id": ids[1], "to": 4}, lambda m: m["type"] == "queue", quiet=1.5)
        S("deleteid", {"cmd": "deleteid", "id": ids[2]}, lambda m: m["type"] == "queue", quiet=1.5)
        S("next", {"cmd": "next"}, lambda m: m["type"] == "status", quiet=1.5)
        S("previous", {"cmd": "previous"}, lambda m: m["type"] == "status", quiet=1.5)
        S("pause 4", {"cmd": "toggle"}, lambda m: m["type"] == "status", quiet=1.0)
        S("clearqueue (keeps current)", {"cmd": "clearqueue"}, lambda m: m["type"] == "queue", quiet=1.5)
        S("stop", {"cmd": "stop"}, lambda m: m["type"] == "status", quiet=1.0)
        S("clearqueue (stopped)", {"cmd": "clearqueue"}, lambda m: m["type"] == "queue", quiet=1.5)
        S("toggle from stop", {"cmd": "toggle"}, quiet=1.5)
        for c, label in (({"cmd": "fav", "file": album[0]}, "fav on"), ({"cmd": "love", "file": album[1]}, "love on"),
                         ({"cmd": "fav", "file": album[0], "on": False}, "fav off"), ({"cmd": "ban", "file": album[2]}, "ban on"),
                         ({"cmd": "ban", "file": album[2], "on": False}, "ban off"), ({"cmd": "ban", "file": album[3]}, "ban on 2"),
                         ({"cmd": "fav", "file": ""}, "fav nothing")):
            S(label, c, quiet=1.2)
        for c in ({"cmd": "smart", "action": "start", "style": "rock"}, {"cmd": "smart", "style": "Bad Style!"},
                  {"cmd": "mix", "mood": "chill"}, {"cmd": "smart", "action": "stop"}):
            S(f"smart {c}", c, quiet=0.8)
        S("playlistadd", {"cmd": "playlistadd", "name": " Test PL ", "files": album[:2]}, quiet=1.2)
        S("savequeue", {"cmd": "savequeue", "name": "Saved Q"}, quiet=1.2)
        S("savequeue exists", {"cmd": "savequeue", "name": "Saved Q"}, quiet=1.0)
        S("playlistdelete", {"cmd": "playlistdelete", "name": "Test PL"}, quiet=1.2)
        S("playlistdelete missing", {"cmd": "playlistdelete", "name": "nope"}, quiet=0.8)
        S("rescan", {"cmd": "rescan"}, quiet=2.5)
        S("home", {"cmd": "home"}, lambda m: m["type"] == "home", quiet=0.5)
        # Yandex worker: play / next / add jobs, sync, cancel
        S("ym status", {"cmd": "ym", "ym": {"cmd": "status"}}, lambda m: m["type"] == "ym-status", quiet=1.0)
        S("ym play", {"cmd": "ym", "ym": {"cmd": "fetch", "mode": "play", "job": "j1", "ids": ["a1", "a2", "a3"], "at": 1}},
          lambda m: m["type"] == "ym-done", quiet=2.5)
        S("pause ym", {"cmd": "toggle"}, lambda m: m["type"] == "status", quiet=1.0)
        S("ym next", {"cmd": "ym", "ym": {"cmd": "fetch", "mode": "next", "job": 7, "ids": ["n1", "n2"]}},
          lambda m: m["type"] == "ym-done", quiet=2.5)
        S("ym add (library)", {"cmd": "ym", "ym": {"cmd": "fetch", "mode": "add", "job": "j3", "ids": ["lib1"]}},
          lambda m: m["type"] == "ym-done", quiet=4.0)
        S("ym play superseded", {"cmd": "ym", "ym": {"cmd": "fetch", "mode": "play", "job": "j4", "ids": ["s1", "s2"], "at": 0}},
          lambda m: m["type"] == "ym-ready", quiet=0.1)
        S("play local (cancels ym)", {"cmd": "play", "files": album[:2], "index": 0}, lambda m: m["type"] == "ym-done", quiet=2.5)
        S("pause 5", {"cmd": "toggle"}, lambda m: m["type"] == "status", quiet=1.0)
        S("ym sync", {"cmd": "ym", "ym": {"cmd": "sync", "job": "s"}}, lambda m: m["type"] == "ym-done", quiet=4.0)
        # removal: library songs to the (fake) Trash, temp ones through the worker with unlike
        gone = [t["f"] for t in tracks if t["f"].startswith("Zz Gone/")]
        S("remove library", {"cmd": "remove", "files": gone + ["../../etc/passwd", 5]}, lambda m: m["type"] == "removed", quiet=4.0)
        temp = os.path.join(CACHE, "yandex-temp", "a1.flac")
        S("remove unlike", {"cmd": "remove", "files": ["file://" + temp], "unlike": True, "ids": {"file://" + temp: 12345}},
          lambda m: m["type"] == "removed", quiet=3.0)
        S("remove nothing", {"cmd": "remove", "files": ["/etc/passwd"]}, quiet=0.8)
        # errors and odd input
        S("playid without id", {"cmd": "playid"}, quiet=0.8)
        S("spawn terminal", {"cmd": "spawn", "what": "terminal"}, quiet=0.8)
        S("unknown", {"cmd": "nope"}, quiet=0.5)
        self.send("not json")
        self.send("")
        self.collect("garbage", quiet=0.5)
        # CPU time and peak memory of the backend over the whole session
        with open(f"/proc/{self.p.pid}/stat") as f:
            st = f.read().rsplit(")", 1)[1].split()
        tck = os.sysconf("SC_CLK_TCK")
        self.cpu = (int(st[11]) + int(st[12])) / tck
        with open(f"/proc/{self.p.pid}/status") as f:
            self.rss = next(int(ln.split()[1]) for ln in f if ln.startswith("VmHWM")) // 1024
        self.send({"cmd": "quit"})
        try:
            self.p.wait(10)
            self.exit = self.p.returncode
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.exit = "hung"
        self.elapsed = time.time() - self.t0

    # ---------------------------------------------------------------- what is left behind
    def leftovers(self):
        out = {"exit": self.exit}
        st = mpd_cmd("status")
        out["mpd status"] = {k: v for k, v in st.items() if k not in ("elapsed", "time", "bitrate", "audio", "mixrampdb")}
        out["mpd queue"] = [v for k, v in mpd_cmd("playlistinfo", pairs=True) if k == "file"]
        for name in ("favourite", "love", "ban"):
            out[f"sticker {name}"] = mpd_cmd("sticker", "find", "song", "", name, pairs=True)
        out["playlists"] = {v: [x for k2, x in mpd_cmd("listplaylist", v, pairs=True)]
                            for k, v in mpd_cmd("listplaylists", pairs=True) if k == "playlist"}
        files = {}
        for top in (M, CACHE):
            for base, _, names in os.walk(top):
                for n in names:
                    p = os.path.join(base, n)
                    rel = os.path.relpath(p, OUT)
                    if os.path.islink(p):
                        continue
                    with open(p, "rb") as f:
                        data = f.read()
                    if n.endswith(".json"):
                        try:
                            data = json.dumps(norm(json.loads(data)), ensure_ascii=False, sort_keys=True).encode()
                        except ValueError:
                            pass
                    files[rel] = data.decode("utf-8", "replace") if len(data) < 3000 and not n.endswith((".flac", ".jpg")) \
                        else hashlib.sha1(data).hexdigest()
        out["files"] = files
        links = set()
        for base, _, names in os.walk(M):
            links |= {os.path.relpath(os.path.join(base, n), M) for n in names if os.path.islink(os.path.join(base, n))}
        out["symlinks"] = len(links)
        return out

    def run(self, P):
        self.start(P)
        try:
            self.script()
            self.left = self.leftovers()
        finally:
            if self.p.poll() is None:
                self.p.kill()
            stop_mpd()


def transient(m):
    """A status sent while MPD's database update is still running. How many of these a step sees depends
    on how long MPD takes to rescan, not on the backend (the Python reference varies run to run too)."""
    return isinstance(m, dict) and m.get("type") == "status" and m.get("updating") is True


def canon(msgs):
    return [json.dumps(m, ensure_ascii=False, sort_keys=True) for m in msgs if not transient(m)]


def main():
    only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None
    music = sys.argv[sys.argv.index("--music") + 1] if "--music" in sys.argv else HOME + "/Music"
    os.makedirs(OUT, exist_ok=True)
    P = make_fixtures(music)
    global PRISTINE_T
    PRISTINE_T = os.path.getmtime(os.path.join(P, ".done"))
    srv = LrcServer(("127.0.0.1", LRCLIB_PORT), LrcHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    runs = {}
    for name, cmd in (("python", [sys.executable, "-m", "glassmusic.server"]), ("rust", [RUST])):
        if only and name != only:
            continue
        r = Run(name, cmd)
        print(f"--- {name}", flush=True)
        r.run(P)
        runs[name] = r
        with open(os.path.join(OUT, f"{name}.json"), "w") as f:
            json.dump({"steps": r.steps, "left": r.left, "stderr": r.err}, f, ensure_ascii=False, indent=1)
        print(f"{name}: {len(r.steps)} steps, {sum(len(m) for _, m in r.steps)} messages, {r.elapsed:.1f}s, exit {r.exit}, "
              f"stderr {len(r.err)} lines, cpu {r.cpu:.2f}s, peak rss {r.rss} MB", flush=True)
    if len(runs) < 2:
        return 0
    a, b = runs["python"], runs["rust"]
    bad = 0
    for (la, ma), (lb, mb) in zip(a.steps, b.steps):
        ca, cb = canon(ma), canon(mb)
        if sorted(ca) == sorted(cb):
            if ca != cb:
                print(f"  (order differs in step {la!r})")
            continue
        if set(ca) == set(cb):
            print(f"  (same messages, different repeat counts in step {la!r}: py {len(ca)} rs {len(cb)})")
            continue
        bad += 1
        print(f"\n=== step {la!r}")
        for x in sorted(set(ca) - set(cb)):
            print("  py  ", x[:1200])
        for x in sorted(set(cb) - set(ca)):
            print("  rs  ", x[:1200])
    for k in sorted(set(a.left) | set(b.left)):
        va, vb = a.left.get(k), b.left.get(k)
        if va == vb:
            continue
        bad += 1
        print(f"\n=== left {k}")
        if isinstance(va, dict) and isinstance(vb, dict):
            for f in sorted(set(va) | set(vb)):
                if va.get(f) != vb.get(f):
                    print(f"  {f}:\n    py {str(va.get(f))[:500]!r}\n    rs {str(vb.get(f))[:500]!r}")
        else:
            print(f"  py {str(va)[:800]}\n  rs {str(vb)[:800]}")
    print(f"\n{len(a.steps)} steps; {bad} differing; python {a.elapsed:.1f}s, rust {b.elapsed:.1f}s")
    print("python stderr:", "".join(a.err[-10:]))
    print("rust stderr:", "".join(b.err[-10:]))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
