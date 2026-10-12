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

from . import library, lyrics, lyricsfetch, removal, search
from .lyrics import parse_lrc  # noqa: F401  (re-exported for tests)
from .mpdclient import MPD, MPDError, default_address
from .thumbs import Thumbs

HOME = os.path.expanduser("~")
CACHE_DIR = os.environ.get("GLASS_MUSIC_CACHE",
                           os.path.join(os.environ.get("XDG_CACHE_HOME", HOME + "/.cache"), "glass-music"))
HISTORY = os.environ.get("GLASS_MUSIC_HISTORY", HOME + "/.local/share/music-smart/history.sqlite")
SMART_STATE = os.environ.get("GLASS_MUSIC_SMART_STATE", HOME + "/.local/state/music-smart/state.json")
# Yandex Music worker (glassmusic.yandex) runs in its own venv with yandex-music-downloader
YM_TEMP = os.environ.get("GLASS_MUSIC_YM_TEMP", os.path.join(CACHE_DIR, "yandex-temp"))
YM_PYTHON = os.environ.get("GLASS_MUSIC_YM_PYTHON", HOME + "/.local/share/glass-music/yandex-venv/bin/python")
FAV = "favourite"     # MPD sticker shared with music-smart

_out_lock = threading.Lock()


def emit(obj):
    data = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    with _out_lock:
        sys.stdout.write(data + "\n")
        sys.stdout.flush()


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
        self.ym = None             # Yandex worker process (started on first use)
        self.ym_play = None        # {"job", "before"} of the Yandex play job that owns the queue
        self.ym_next = {}          # job -> tracks already inserted after the current one
        self.ym_index_q = queue.Queue()
        self.lyr = None            # lyrics resolver (glassmusic.lyricsfetch), made on first use
        self.lyr_view = ""         # the song whose lyrics the window shows
        self.lyr_meta = {}         # file -> tags of songs outside the library (from MPD)

    # ── MPD plumbing ─────────────────────────────────────────────────────────
    def conn(self):
        if self.mpd is not None and self.mpd.stale():
            self.drop()   # MPD timed the idle command connection out: reconnect before sending
        if self.mpd is None:
            self.mpd = MPD(self.address)
        return self.mpd

    def drop(self):
        try:
            if self.mpd:
                self.mpd.sock.close()
        except Exception:
            pass
        self.mpd = None

    def call(self, fn, idempotent=False):
        """Run fn(mpd) on the command connection, reconnecting once on a connection error.

        The retry re-runs fn only if it is safe: fn is a pure read (idempotent=True), or nothing
        reached the socket before the failure. A command list like clear+add that was already
        sent may have been executed, so it is never sent twice; the error goes to the caller."""
        for attempt in (0, 1):
            m = None
            try:
                m = self.conn()
                before = m.sent
                return fn(m)
            except (ConnectionError, OSError):
                sent = m is not None and m.sent != before
                self.drop()
                if attempt or (sent and not idempotent):
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
                self.music_dir = self.call(lambda m: m.dict("config"), idempotent=True).get("music_directory", "")
            except MPDError:
                pass
            if not self.music_dir:
                self.music_dir = HOME + "/Music"
        lib, cached = self.call(lambda m: library.load(m, self.music_dir, CACHE_DIR, force=force), idempotent=True)
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
        st, cur = self.call(get, idempotent=True)
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
            try:
                self.lyr_prefetch(out)
            except (MPDError, ConnectionError, OSError):
                pass

    # ── lyrics: own files first, the resolver looks further in the background ────
    def lyr_init(self):
        if self.lyr is None:
            self.lyr = lyricsfetch.Resolver(
                self.music_dir or HOME + "/Music", CACHE_DIR, on_found=self.lyr_found,
                ym_send=lambda c: self.q.put(("cmd", {"cmd": "ym", "ym": c})),   # via the main loop
                log=lambda msg: emit({"type": "log", "msg": msg}))
            self.lyr.ym_ok = lambda: os.path.exists(YM_PYTHON) and lyricsfetch.signed_in()
        return self.lyr

    def lyr_meta_of(self, f):
        i = self.files.get(f, -1)
        if i >= 0 and self.lib:
            t = self.lib["tracks"][i]
            return {"artist": t.get("a", ""), "title": t.get("t", ""), "album": t.get("al", ""),
                    "duration": t.get("d", 0)}
        return self.lyr_meta.get(f)

    def lyr_prefetch(self, st):
        """A new song started: look up lyrics for it and the next two (each song once, cached)."""
        f = st.get("file")
        if not f:
            return
        if f not in self.files:
            self.lyr_meta[f] = {"artist": st.get("artist", ""), "title": st.get("title", ""),
                                "album": st.get("album", ""), "duration": st.get("duration", 0)}
        r = self.lyr_init()
        r.want(lyrics.song_path(self.music_dir, f), self.lyr_meta_of(f))
        if st.get("pos", -1) >= 0:
            p = st["pos"]
            for s in MPD.songs(self.call(lambda m: m.cmd("playlistinfo", "%d:%d" % (p + 1, p + 3)),
                                         idempotent=True)):
                if s["file"] in self.files:
                    r.want(lyrics.song_path(self.music_dir, s["file"]), self.lyr_meta_of(s["file"]))

    def send_lyrics(self, f, look=True, force=False):
        r = self.lyr_init()
        path = lyrics.song_path(self.music_dir, f)
        self.lyr_view = f
        if look and path:
            r.want(path, self.lyr_meta_of(f), front=True, force=force)
        emit(dict(r.load(path), type="lyrics", file=f))

    def lyr_found(self, path, result, changed):
        """Resolver thread: a lookup ended; refresh the window if it shows that song."""
        if self.lyr_view and lyrics.song_path(self.music_dir, self.lyr_view) == path:
            emit(dict(result, type="lyrics", file=self.lyr_view))

    def send_queue(self):
        items = MPD.songs(self.call(lambda m: m.cmd("playlistinfo"), idempotent=True))
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
            pairs = self.call(lambda m: m.cmd("sticker", "find", "song", "", name), idempotent=True)
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
        # The whole library counts as liked. Favourites (sticker "favourite"; the old "love" still
        # counts until music-smart migrates it) play more often in My Vibe; "ban" = never play.
        favs = sorted(set(self.stickers(FAV)) | set(self.stickers("love")))
        emit({"type": "likes", "files": favs, "bans": self.stickers("ban")})

    def send_playlists(self):
        names = []
        try:
            for k, v in self.call(lambda m: m.cmd("listplaylists"), idempotent=True):
                if k == "playlist":
                    names.append(v)
        except MPDError:
            pass
        pls = []
        for n in sorted(names, key=str.casefold):
            try:
                files = [v for k, v in self.call(lambda m: m.cmd("listplaylist", n), idempotent=True) if k == "file"]
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
        self.ym_cancel_play()
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
            st = self.call(lambda m: m.dict("status"), idempotent=True)
            if "song" in st:
                cmds = [("addid", f, "+0") for f in reversed(files)]
            else:
                cmds = [("addid", f) for f in files]
        else:
            cmds = [("addid", f) for f in files]
        self.call(lambda m: m.batch(cmds))

    def smart(self, action, style=""):
        """My Vibe lives in music-smart: start [style] / reroll / stop (it keeps the queue topped up)."""
        env = dict(os.environ)
        extra = os.environ.get("GLASS_MUSIC_SMART_ENV")
        if extra:
            env.update(json.loads(extra))
        args = [library.MUSIC_SMART, action] + ([style] if style and re.match(r"^[a-z0-9][a-z0-9_-]*$", style) else [])
        try:
            p = subprocess.Popen(args, env=env, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
            threading.Thread(target=p.wait, daemon=True).start()     # reap it (no zombies)
        except OSError as ex:
            emit({"type": "toast", "icon": "warn", "text": f"music-smart: {ex}"})


    # ── Yandex Music (glassmusic.yandex worker) ──────────────────────────────
    def ym_start(self):
        if self.ym is not None and self.ym.poll() is None:
            return True
        if not os.path.exists(YM_PYTHON):
            emit({"type": "ym-status", "available": False, "signed": False,
                  "error": "Yandex Music support is not installed (run install.sh)"})
            return False
        env = dict(os.environ, PYTHONPATH=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   PYTHONUNBUFFERED="1", GLASS_MUSIC_DIR=self.music_dir or "", GLASS_MUSIC_CACHE=CACHE_DIR)
        self.ym = subprocess.Popen([YM_PYTHON, "-m", "glassmusic.yandex", "serve"], env=env, text=True,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        threading.Thread(target=self.ym_reader, args=(self.ym,), daemon=True).start()
        if not getattr(self, "_ym_indexer", False):
            self._ym_indexer = True
            threading.Thread(target=self.ym_indexer, daemon=True).start()
        return True

    def ym_send(self, c):
        if not self.ym_start():
            return
        try:
            self.ym.stdin.write(json.dumps(c, ensure_ascii=False) + "\n")
            self.ym.stdin.flush()
        except (OSError, ValueError):
            self.ym = None
            emit({"type": "toast", "icon": "warn", "text": "The Yandex Music worker stopped; try again"})

    def ym_reader(self, proc):
        for line in proc.stdout:
            try:
                m = json.loads(line)
            except ValueError:
                continue
            t = m.get("type")
            if t == "ym-lyrics" or (t == "ym-error" and m.get("cmd") == "lyrics"):
                if self.lyr is not None:
                    self.lyr.on_ym(m)            # an answer for the lyrics resolver
                continue
            if t == "ym-ready":
                self.ym_index_q.put(m)           # new library files are indexed by MPD first
            elif t == "ym-removed":
                self.ym_index_q.put({"type": "ym-index", "dirs": m.get("rescan", [])})
                emit(dict(m, type="removed"))
                continue
            elif t == "ym-done" and m.get("paths"):
                self.ym_index_q.put(dict(m, type="ym-index"))
            emit(m)

    def ym_indexer(self):
        """Library downloads must be in MPD's database before they can be queued: run `update`
        on the new file and wait for that update job (idle "update"), then hand it to the main loop."""
        m = None
        while True:
            msg = self.ym_index_q.get()
            paths = [msg["path"]] if msg["type"] == "ym-ready" else msg.get("paths", [])
            rels = [os.path.relpath(p, self.music_dir) for p in paths
                    if self.music_dir and p.startswith(self.music_dir.rstrip("/") + "/")]
            dirs = {os.path.dirname(r) for r in rels}
            if "dirs" in msg:            # removals: the folders that changed or disappeared
                dirs = {os.path.relpath(d, self.music_dir) for d in msg["dirs"]
                        if self.music_dir and d.startswith(self.music_dir.rstrip("/") + "/")}
            if dirs:
                try:
                    if m is None or m.stale():
                        m = MPD(self.address)
                    job = 0
                    # update the album folder: MPD skips a file path whose folder it doesn't know yet
                    for d in sorted(dirs):
                        job = max(job, int(m.dict("update", d).get("updating_db", 0) or 0))
                    # a short poll, only while this update job runs (an `idle update` issued after
                    # the job already finished would wait for the next one)
                    deadline = time.time() + 60
                    while time.time() < deadline:
                        cur = int(m.dict("status").get("updating_db", 0) or 0)
                        if not cur or cur > job:
                            break
                        time.sleep(0.1)
                except (MPDError, ConnectionError, OSError) as ex:
                    m = None
                    emit({"type": "log", "msg": f"mpd update: {ex}"})
            if msg["type"] == "ym-ready":
                msg["uri"] = rels[0] if rels else "file://" + msg["path"]
                self.q.put(("ym", msg))

    def remove_songs(self, files, unlike=False, ids=None):
        """Remove songs from disk: library ones to the Trash, temp-cache ones deleted; with unlike,
        the worker first removes them from the Yandex likes (or the daily sync brings them back)."""
        paths, idmap = [], {}
        for f in files:
            p = f[7:] if f.startswith("file://") else (f if os.path.isabs(f) else os.path.join(self.music_dir, f))
            if removal.inside(p, [self.music_dir, YM_TEMP]):
                paths.append(p)
                if ids and ids.get(f):
                    idmap[p] = str(ids[f])
        if not paths:
            return
        # take them out of the queue first (MPD names temp songs by their plain path)
        gone = set(paths) | {os.path.relpath(p, self.music_dir) for p in paths}
        items = MPD.songs(self.call(lambda m: m.cmd("playlistinfo"), idempotent=True))
        ids_q = [s.get("Id") for s in items if s["file"] in gone or s["file"].removeprefix("file://") in gone]
        if ids_q:
            self.call(lambda m: m.batch([("deleteid", i) for i in ids_q if i]))
        if unlike and self.ym_start():
            self.ym_send({"cmd": "remove", "paths": paths, "unlike": True, "ids": idmap})
            return
        removed, failed, rescan = removal.remove(paths, [self.music_dir, YM_TEMP], [self.music_dir])
        self.ym_index_q.put({"type": "ym-index", "dirs": rescan})
        if not getattr(self, "_ym_indexer", False):
            self._ym_indexer = True
            threading.Thread(target=self.ym_indexer, daemon=True).start()
        emit({"type": "removed", "paths": removed, "failed": failed, "unliked": 0, "notFound": 0})

    def ym_cancel_play(self):
        if self.ym_play:
            self.ym_send({"cmd": "cancel", "job": self.ym_play["job"]})
            self.ym_play = None

    def ym_ready(self, m):
        """A downloaded track for a play / next / add job: put it where it belongs in the queue."""
        uri, mode, job = m["uri"], m.get("mode"), m.get("job")
        if os.environ.get("GLASS_MUSIC_DEBUG"):
            emit({"type": "log", "msg": f"ym_ready job={job} mode={mode} idx={m.get('idx')} at={m.get('at')} uri={uri} own={self.ym_play}"})
        if mode == "play":
            if not self.ym_play or self.ym_play["job"] != job:
                return                   # superseded by another play
            if m.get("idx") == m.get("at"):
                r = self.call(lambda c: c.batch([("clear",), ("add", uri), ("play", "0")]))
                self.queue_files = [uri]
                if len(r) < 3:
                    emit({"type": "toast", "icon": "warn", "text": "MPD couldn’t play the downloaded file"})
            else:
                if m["idx"] < m["at"]:   # tracks before the clicked one go in front of it, in order
                    pos = self.ym_play["before"]
                    self.call(lambda c: c.cmd("addid", uri, str(pos)))
                    self.ym_play["before"] += 1
                else:
                    self.call(lambda c: c.cmd("addid", uri))
                self.queue_files = []
        elif mode == "next":
            k = self.ym_next.get(job, 0)
            st = self.call(lambda c: c.dict("status"), idempotent=True)
            self.call(lambda c: c.cmd("addid", uri, "+%d" % k) if "song" in st else c.cmd("addid", uri))
            self.ym_next[job] = k + 1
        elif mode == "add":
            self.call(lambda c: c.cmd("addid", uri))

    # ── commands ─────────────────────────────────────────────────────────────
    def handle(self, c):
        cmd = c.get("cmd")
        if cmd == "hello":
            emit({"type": "hello", "smartState": SMART_STATE,
                  "smartStyles": os.path.join(os.path.dirname(SMART_STATE), "styles.json"), "mpd": self.address})
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
            self.send_lyrics(c.get("file", ""))
        elif cmd == "lyricsfind":        # "Find lyrics" / "Look again": ask the sources now
            self.send_lyrics(c.get("file", ""), force=True)
        elif cmd == "lyricswrong":       # "These lyrics are wrong": next source / candidate
            f = c.get("file", "")
            path = lyrics.song_path(self.music_dir, f)
            if path and self.lyr_init().reject(path, self.lyr_meta_of(f)):
                emit({"type": "toast", "icon": "lyrics", "text": "Looking for other lyrics…"})
            self.send_lyrics(f, look=False)
        elif cmd == "play":
            self.play_files(c.get("files", []), int(c.get("index", 0)), bool(c.get("shuffle")))
        elif cmd == "add":
            self.add_files(c.get("files", []), bool(c.get("next")))
            n = len(c.get("files", []))
            emit({"type": "toast", "icon": "queue",
                  "text": ("Playing next" if c.get("next") else "Added to queue") + (f" · {n} tracks" if n > 1 else "")})
        elif cmd == "toggle":
            st = self.call(lambda m: m.dict("status"), idempotent=True).get("state")
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
            st = self.call(lambda m: m.dict("status"), idempotent=True)
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
        elif cmd in ("fav", "love"):
            f = c.get("file")
            if f:
                if c.get("on", True):
                    self.call(lambda m: m.cmd("sticker", "set", "song", f, FAV, "1"))
                else:
                    for name in (FAV, "love"):
                        try:
                            self.call(lambda m: m.cmd("sticker", "delete", "song", f, name))
                        except MPDError:
                            pass
                emit({"type": "toast", "icon": "star" if c.get("on", True) else "star-outline",
                      "text": "Favourite · My Vibe plays it more often" if c.get("on", True) else "No longer a favourite"})
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
                emit({"type": "toast", "icon": "cancel" if c.get("on", True) else "vibe",
                      "text": "My Vibe will never play this song" if c.get("on", True) else "Back in My Vibe"})
        elif cmd == "mix":           # old name: a style's endless My Vibe queue
            self.smart("start", c.get("mood", ""))
        elif cmd == "smart":
            self.smart(c.get("action", "start"), c.get("style", ""))
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
        elif cmd == "remove":
            self.remove_songs([f for f in c.get("files", []) if isinstance(f, str)],
                              bool(c.get("unlike")), c.get("ids"))
        elif cmd == "ym":
            inner = c.get("ym") or {}
            if inner.get("cmd") == "fetch" and inner.get("mode") == "play":
                self.ym_cancel_play()
                self.ym_play = {"job": inner.get("job"), "before": 0}
            self.ym_send(inner)
        elif cmd == "spawn":
            what = c.get("what")
            if what == "terminal":
                subprocess.Popen([os.path.expanduser("~/.local/bin/music-player")], start_new_session=True,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def on_event(self, changed):
        ch = set(changed)
        # "reconnect" (idle watcher (re)connected: changes during the gap are unknown) needs a fresh
        # status + queue; it can arrive in the same coalesced burst as real changes, which must
        # still be handled, so it is folded in instead of returning early.
        reconnect = "reconnect" in ch
        if "database" in ch:
            self.send_library()
            self.send_queue()
            self.send_home()
        elif "playlist" in ch or reconnect:
            self.send_queue()
        if reconnect or ch & {"player", "mixer", "options", "playlist", "update"}:
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
                if self.ym is not None:
                    try:
                        self.ym.stdin.close()
                    except OSError:
                        pass
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
                elif kind == "ym":
                    self.ym_ready(data)
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
