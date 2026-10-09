"""glass-music backend: JSON lines on stdin (commands) / stdout (events) for the QML window.

Threads: stdin reader and MPD idle watcher feed one queue; the main loop handles everything
serially on a command connection (reconnected on demand: MPD drops idle command clients).
Nothing polls: playback state arrives through MPD's `idle`, smart-shuffle state through the
UI's inotify watch on music-smart's state.json. The process exits with the window.
"""

import json
import os
import queue
import random
import re
import sqlite3
import subprocess
import sys
import threading
import time
import traceback

from . import library, search
from .mpdclient import MPD, MPDError, default_address
from .thumbs import Thumbs

HOME = os.path.expanduser("~")
CACHE_DIR = os.environ.get("GLASS_MUSIC_CACHE",
                           os.path.join(os.environ.get("XDG_CACHE_HOME", HOME + "/.cache"), "glass-music"))
HISTORY = os.environ.get("GLASS_MUSIC_HISTORY", HOME + "/.local/share/music-smart/history.sqlite")
SMART_STATE = os.environ.get("GLASS_MUSIC_SMART_STATE", HOME + "/.local/state/music-smart/state.json")

_out_lock = threading.Lock()


def emit(obj):
    data = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    with _out_lock:
        sys.stdout.write(data + "\n")
        sys.stdout.flush()


def parse_lrc(text):
    tag = re.compile(r"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]")
    offset = 0.0
    m = re.search(r"\[offset:\s*([+-]?\d+)\]", text, re.I)
    if m:
        offset = int(m.group(1)) / 1000.0
    out = []
    for line in text.splitlines():
        times = [int(a) * 60 + float(b.replace(":", ".")) for a, b in tag.findall(line)]
        if not times:
            continue
        words = re.sub(r"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>", "", tag.sub("", line)).strip()
        for t in times:
            out.append({"t": round(max(0.0, t - offset), 3), "x": words})
    out.sort(key=lambda r: r["t"])
    tidy = []
    for r in out:
        if not r["x"]:
            if not tidy and r["t"] < 0.5:
                continue
            if tidy and not tidy[-1]["x"]:
                continue
        tidy.append(r)
    return tidy


class Server:
    def __init__(self):
        self.q = queue.Queue()
        self.address = default_address()
        self.mpd = None
        self.lib = None
        self.index = None
        self.files = {}
        self.music_dir = os.environ.get("GLASS_MUSIC_DIR", "")
        self.last_songid = None
        self.thumbs = Thumbs(CACHE_DIR, emit)
        self.queue_files = []
        self.backlog = []

    # ── MPD plumbing ─────────────────────────────────────────────────────────
    def conn(self):
        if self.mpd is None:
            self.mpd = MPD(self.address)
        return self.mpd

    def call(self, fn):
        """Run fn(mpd); reconnect once if MPD dropped the idle command connection."""
        for attempt in (0, 1):
            try:
                return fn(self.conn())
            except (ConnectionError, OSError, BrokenPipeError):
                try:
                    if self.mpd:
                        self.mpd.sock.close()
                except Exception:
                    pass
                self.mpd = None
                if attempt:
                    raise

    def idle_thread(self):
        backoff = 1
        while True:
            try:
                m = MPD(self.address)
                self.q.put(("event", ["reconnect"]))
                backoff = 1
                while True:
                    changed = m.idle("player", "playlist", "mixer", "options", "database",
                                     "stored_playlist", "sticker", "update")
                    self.q.put(("event", changed))
            except Exception as ex:
                emit({"type": "mpd", "ok": False, "error": str(ex)})
                time.sleep(backoff)
                backoff = min(30, backoff * 2)

    def stdin_thread(self):
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                self.q.put(("cmd", json.loads(line)))
            except ValueError:
                pass
        self.q.put(("quit", None))

    # ── data senders ─────────────────────────────────────────────────────────
    def send_library(self, force=False):
        t0 = time.time()
        if not self.music_dir:
            try:
                self.music_dir = self.call(lambda m: m.dict("config")).get("music_directory", "")
            except MPDError:
                pass
            if not self.music_dir:
                self.music_dir = HOME + "/Music"
        lib, cached = self.call(lambda m: library.load(m, self.music_dir, CACHE_DIR, force=force))
        self.lib = lib
        self.files = {t["f"]: i for i, t in enumerate(lib["tracks"])}
        self.album_of = {a["k"]: a for a in lib["albums"]}
        self.index = search.Index(lib)
        emit({"type": "library", "lib": lib, "thumbs": self.thumbs.known(lib["albums"]),
              "cached": cached, "ms": round((time.time() - t0) * 1000)})

    def send_status(self):
        def get(m):
            r = m.batch([("status",), ("currentsong",)])
            st = dict(r[0]) if r else {}
            cur = MPD.songs(r[1]) if len(r) > 1 else []
            return st, (cur[0] if cur else {})
        st, cur = self.call(get)
        f = cur.get("file", "")
        out = {"type": "status", "state": st.get("state", "stop"),
               "elapsed": float(st.get("elapsed", 0) or 0),
               "duration": float(st.get("duration", 0) or cur.get("duration", 0) or 0),
               "volume": int(st.get("volume", -1) or -1),
               "random": st.get("random") == "1", "repeat": st.get("repeat") == "1",
               "single": st.get("single", "0") != "0", "consume": st.get("consume") == "1",
               "pos": int(st.get("song", -1)), "id": int(st.get("songid", -1)),
               "len": int(st.get("playlistlength", 0)), "file": f,
               "title": cur.get("Title", ""), "artist": "; ".join(cur.get("Artist", [])),
               "album": cur.get("Album", ""), "updating": "updating_db" in st,
               "error": st.get("error", "")}
        emit(out)
        if out["id"] != self.last_songid:
            if self.last_songid is not None:
                # music-smart logs the finished play on this same event; read history a bit later
                threading.Timer(2.0, lambda: self.q.put(("home", None))).start()
            self.last_songid = out["id"]

    def send_queue(self):
        items = MPD.songs(self.call(lambda m: m.cmd("playlistinfo")))
        out = []
        for s in items:
            i = self.files.get(s["file"], -1)
            e = {"id": int(s.get("Id", -1)), "i": i}
            if i < 0:
                e.update({"f": s["file"], "t": s.get("Title", os.path.basename(s["file"])),
                          "a": "; ".join(s.get("Artist", [])), "d": float(s.get("duration", 0) or 0)})
            out.append(e)
        self.queue_files = [s["file"] for s in items]
        emit({"type": "queue", "items": out})

    def stickers(self, name):
        files = []
        try:
            pairs = self.call(lambda m: m.cmd("sticker", "find", "song", "", name))
            cur = None
            for k, v in pairs:
                if k == "file":
                    cur = v
                elif k == "sticker" and cur:
                    key, _, val = v.partition("=")
                    if key == name and val not in ("", "0"):
                        files.append(cur)
        except MPDError:
            pass
        return files

    def send_likes(self):
        # the same stickers music-smart reads: love = favourite (x2.5), ban = never in smart queues
        emit({"type": "likes", "files": self.stickers("love"), "bans": self.stickers("ban")})

    def send_playlists(self):
        names = []
        try:
            for k, v in self.call(lambda m: m.cmd("listplaylists")):
                if k == "playlist":
                    names.append(v)
        except MPDError:
            pass
        pls = []
        for n in sorted(names, key=str.casefold):
            try:
                files = [v for k, v in self.call(lambda m: m.cmd("listplaylist", n)) if k == "file"]
            except MPDError:
                files = []
            pls.append({"n": n, "files": files})
        emit({"type": "playlists", "items": pls})

    def history_db(self):
        if not os.path.exists(HISTORY):
            return None
        db = sqlite3.connect(HISTORY, timeout=2)
        db.execute("PRAGMA query_only=1")
        return db

    def send_home(self):
        recent, most, counts = [], [], {}
        try:
            db = self.history_db()
            if db:
                for f, last in db.execute(
                        "SELECT file, MAX(started) s FROM plays WHERE outcome != 'replaced' "
                        "GROUP BY file ORDER BY s DESC LIMIT 60"):
                    if f in self.files:
                        recent.append(f)
                for f, n in db.execute(
                        "SELECT file, COUNT(*) n FROM plays WHERE outcome IN ('full','partial','seed') "
                        "GROUP BY file ORDER BY n DESC, MAX(started) DESC"):
                    if f in self.files:
                        counts[f] = n
                        if len(most) < 40:
                            most.append(f)
                db.close()
        except sqlite3.Error as ex:
            emit({"type": "log", "msg": f"history: {ex}"})
        emit({"type": "home", "recent": recent, "most": most, "counts": counts})

    # ── playback helpers ─────────────────────────────────────────────────────
    def play_files(self, files, index=0, shuffle=False):
        files = [f for f in files if f]
        if not files:
            return
        # Like Spotify: the shuffle toggle (MPD random) is global; the Shuffle button turns it
        # on and starts anywhere. If the queue already is this context, just jump.
        index = random.randrange(len(files)) if shuffle else max(0, min(index, len(files) - 1))
        cmds = []
        if files != self.queue_files:
            cmds += [("clear",)] + [("add", f) for f in files]
            self.queue_files = list(files)
        if shuffle:
            cmds.append(("random", "1"))
        cmds.append(("play", str(index)))
        self.call(lambda m: m.batch(cmds))

    def add_files(self, files, next_=False):
        if next_:
            st = self.call(lambda m: m.dict("status"))
            if "song" in st:
                cmds = [("addid", f, "+0") for f in reversed(files)]
            else:
                cmds = [("addid", f) for f in files]
        else:
            cmds = [("addid", f) for f in files]
        self.call(lambda m: m.batch(cmds))

    def mood_mix(self, mood, count=50):
        tracks = self.lib["tracks"]
        ms = library.music_smart()
        files = []
        if ms:
            try:
                lib = [{"file": t["f"], "title": t["t"], "artist": t["a"], "primary": t["p"],
                        "keys": {t["p"].lower()} | set(ms.split_artists(t.get("as") or [t["a"]])), "album": t["al"],
                        "genres": [t["g"]], "mood": t["m"], "duration": t["d"]} for t in tracks]
                stick = {"love": set(), "ban": set(), "rating": {}}
                for name in ("love", "ban"):
                    try:
                        pairs = self.call(lambda m: m.cmd("sticker", "find", "song", "", name))
                    except MPDError:
                        continue
                    cur = None
                    for k, v in pairs:
                        if k == "file":
                            cur = v
                        elif k == "sticker" and cur and v.partition("=")[0] == name:
                            stick[name].add(cur)
                db = self.history_db() or sqlite3.connect(":memory:")
                if not db.execute("SELECT name FROM sqlite_master WHERE name='plays'").fetchone():
                    db = sqlite3.connect(":memory:")
                    db.execute("CREATE TABLE plays(file, artist, mood, started, outcome)")
                model = ms.Model(db, lib, stick)
                picks = model.pick(count, mood, set(), [])
                files = [s["file"] for s, _, _ in picks]
                db.close()
            except Exception:
                emit({"type": "log", "msg": "mix: " + traceback.format_exc(limit=2)})
                files = []
        if not files:
            pool = [t["f"] for t in tracks if t["m"] == mood]
            random.shuffle(pool)
            files = pool[:count]
        self.play_files(files, 0)
        emit({"type": "toast", "icon": "mix", "text": f"{library.MOOD_LABEL.get(mood, mood)} mix · {len(files)} tracks"})

    def smart(self, action):
        env = dict(os.environ)
        extra = os.environ.get("GLASS_MUSIC_SMART_ENV")
        if extra:
            env.update(json.loads(extra))
        try:
            subprocess.Popen([library.MUSIC_SMART, action], env=env, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError as ex:
            emit({"type": "toast", "icon": "warn", "text": f"music-smart: {ex}"})

    # ── commands ─────────────────────────────────────────────────────────────
    def handle(self, c):
        cmd = c.get("cmd")
        if cmd == "hello":
            emit({"type": "hello", "smartState": SMART_STATE, "mpd": self.address})
            self.send_library()
            self.send_status()
            self.send_queue()
            self.send_likes()
            self.send_playlists()
            self.send_home()
        elif cmd == "search":
            r = self.index.search(c.get("q", "")) if self.index else {}
            emit(dict(r, type="search", q=c.get("q", ""), rid=c.get("rid", 0)))
        elif cmd == "thumbs":
            self.thumbs.request([(k, self.album_of[k]["c"]) for k in c.get("keys", [])
                                 if k in self.album_of and self.album_of[k]["c"]])
        elif cmd == "lyrics":
            f = c.get("file", "")
            lines = []
            try:
                with open(os.path.join(self.music_dir, os.path.splitext(f)[0] + ".lrc"),
                          encoding="utf-8", errors="replace") as fh:
                    lines = parse_lrc(fh.read())
            except OSError:
                pass
            emit({"type": "lyrics", "file": f, "lines": lines})
        elif cmd == "play":
            self.play_files(c.get("files", []), int(c.get("index", 0)), bool(c.get("shuffle")))
        elif cmd == "add":
            self.add_files(c.get("files", []), bool(c.get("next")))
            n = len(c.get("files", []))
            emit({"type": "toast", "icon": "queue",
                  "text": ("Playing next" if c.get("next") else "Added to queue") + (f" · {n} tracks" if n > 1 else "")})
        elif cmd == "toggle":
            st = self.call(lambda m: m.dict("status")).get("state")
            self.call(lambda m: m.cmd("play") if st == "stop" else m.cmd("pause", "1" if st == "play" else "0"))
        elif cmd in ("next", "previous", "stop"):
            self.call(lambda m: m.cmd(cmd))
        elif cmd == "seek":
            self.call(lambda m: m.cmd("seekcur", "%.2f" % max(0.0, float(c.get("pos", 0)))))
        elif cmd == "volume":
            self.call(lambda m: m.cmd("setvol", str(max(0, min(100, int(c.get("value", 50)))))))
        elif cmd == "random":
            self.call(lambda m: m.cmd("random", "1" if c.get("on") else "0"))
        elif cmd == "repeat":
            mode = c.get("mode", "off")   # off | all | one
            self.call(lambda m: m.batch([("repeat", "0" if mode == "off" else "1"),
                                         ("single", "1" if mode == "one" else "0")]))
        elif cmd == "playid":
            self.call(lambda m: m.cmd("playid", str(c["id"])))
        elif cmd == "deleteid":
            self.call(lambda m: m.cmd("deleteid", str(c["id"])))
        elif cmd == "moveid":
            self.call(lambda m: m.cmd("moveid", str(c["id"]), str(c["to"])))
        elif cmd == "clearqueue":
            st = self.call(lambda m: m.dict("status"))
            if "song" in st:   # keep the current track, drop the rest
                pos = int(st["song"])
                n = int(st.get("playlistlength", 0))
                cmds = []
                if pos + 1 < n:
                    cmds.append(("delete", f"{pos + 1}:{n}"))
                if pos > 0:
                    cmds.append(("delete", f"0:{pos}"))
                self.call(lambda m: m.batch(cmds))
            else:
                self.call(lambda m: m.cmd("clear"))
        elif cmd == "love":
            f = c.get("file")
            if f:
                if c.get("on", True):
                    self.call(lambda m: m.cmd("sticker", "set", "song", f, "love", "1"))
                else:
                    try:
                        self.call(lambda m: m.cmd("sticker", "delete", "song", f, "love"))
                    except MPDError:
                        pass
                emit({"type": "toast", "icon": "heart" if c.get("on", True) else "heart-off",
                      "text": "Added to Liked Songs" if c.get("on", True) else "Removed from Liked Songs"})
        elif cmd == "ban":
            f = c.get("file")
            if f:
                if c.get("on", True):
                    self.call(lambda m: m.cmd("sticker", "set", "song", f, "ban", "1"))
                else:
                    try:
                        self.call(lambda m: m.cmd("sticker", "delete", "song", f, "ban"))
                    except MPDError:
                        pass
                emit({"type": "toast", "icon": "cancel" if c.get("on", True) else "smart",
                      "text": "Smart shuffle will skip this song" if c.get("on", True) else "Back in smart shuffle"})
        elif cmd == "mix":
            self.mood_mix(c.get("mood", "alt"))
        elif cmd == "smart":
            self.smart(c.get("action", "start"))
        elif cmd == "playlistadd":
            name, files = c.get("name", "").strip(), c.get("files", [])
            if name and files:
                self.call(lambda m: m.batch([("playlistadd", name, f) for f in files]))
                emit({"type": "toast", "icon": "playlist", "text": f"Added to {name}"})
        elif cmd == "savequeue":
            name = c.get("name", "").strip()
            if name:
                try:
                    self.call(lambda m: m.cmd("save", name))
                    emit({"type": "toast", "icon": "playlist", "text": f"Saved queue as {name}"})
                except MPDError as ex:
                    emit({"type": "toast", "icon": "warn", "text": str(ex).split("} ")[-1]})
        elif cmd == "playlistdelete":
            try:
                self.call(lambda m: m.cmd("rm", c.get("name", "")))
            except MPDError:
                pass
        elif cmd == "rescan":
            self.call(lambda m: m.cmd("update"))
        elif cmd == "home":
            self.send_home()
        elif cmd == "spawn":
            what = c.get("what")
            if what == "terminal":
                subprocess.Popen([os.path.expanduser("~/.local/bin/music-player")], start_new_session=True,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def on_event(self, changed):
        ch = set(changed)
        if "reconnect" in ch:
            if self.lib is not None:
                self.send_status()
                self.send_queue()
            return
        if "database" in ch:
            self.send_library()
            self.send_queue()
            self.send_home()
        if "playlist" in ch and "database" not in ch:
            self.send_queue()
        if ch & {"player", "mixer", "options", "playlist", "update"}:
            self.send_status()
        if "sticker" in ch:
            self.send_likes()
        if "stored_playlist" in ch:
            self.send_playlists()

    def run(self):
        threading.Thread(target=self.stdin_thread, daemon=True).start()
        started_idle = False
        while True:
            kind, data = self.backlog.pop(0) if self.backlog else self.q.get()
            if kind == "quit" or (kind == "cmd" and data.get("cmd") == "quit"):
                break
            try:
                if kind == "cmd":
                    self.handle(data)
                    if data.get("cmd") == "hello" and not started_idle:
                        started_idle = True
                        threading.Thread(target=self.idle_thread, daemon=True).start()
                elif kind == "event" and self.lib is not None:
                    # coalesce bursts (a context play fires playlist+player+options at once)
                    changed = set(data)
                    time.sleep(0.03)
                    while True:
                        try:
                            k2, d2 = self.q.get_nowait()
                        except queue.Empty:
                            break
                        if k2 == "event":
                            changed |= set(d2)
                        else:
                            self.backlog.append((k2, d2))
                            break
                    self.on_event(list(changed))
                elif kind == "home" and self.lib is not None:
                    self.send_home()
            except (MPDError, ConnectionError, OSError) as ex:
                emit({"type": "error", "error": str(ex)})
            except Exception as ex:
                emit({"type": "error", "error": str(ex), "trace": traceback.format_exc(limit=4)})


def main():
    try:
        Server().run()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
