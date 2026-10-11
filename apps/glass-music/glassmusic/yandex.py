"""Yandex Music for Glass Music.

Search and browse read api.music.yandex.ru (the JSON the music.yandex.ru site itself loads its
pages from) through the yandex_music library that ships with yandex-music-downloader. Every
download is `yandex-music-downloader -u <music.yandex.ru link>` into ~/Music (or a temp cache,
see settings), and afterwards each new .lrc is embedded into its audio file's tags (lrcput).
Nothing streams: MPD only ever plays local files.

Runs in its own venv (install.sh), separate from the dependency-free app backend:
  python -m glassmusic.yandex serve        JSON-lines worker spawned by glassmusic.server
  python -m glassmusic.yandex sync         download new liked tracks (+ chosen playlists); the timer
  python -m glassmusic.yandex embed [DIR]  embed every .lrc that differs from its file's lyrics tag
  python -m glassmusic.yandex login        read a token (or the sign-in redirect URL) from stdin
  python -m glassmusic.yandex status       account + settings as JSON
"""

import fcntl
import json
import logging
import os
import queue
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import traceback

from ymd import core

from . import removal
from yandex_music import Client
from yandex_music.exceptions import NetworkError, YandexMusicError

HOME = os.path.expanduser("~")
CONF = os.environ.get("GLASS_MUSIC_YM_CONF", HOME + "/.config/glass-music/yandex.json")
CACHE = os.environ.get("GLASS_MUSIC_CACHE",
                       os.path.join(os.environ.get("XDG_CACHE_HOME", HOME + "/.cache"), "glass-music"))
TEMP = os.environ.get("GLASS_MUSIC_YM_TEMP", os.path.join(CACHE, "yandex-temp"))
LOCK = os.path.join(CACHE, "yandex-sync.lock")
DOWNLOADER = os.environ.get("GLASS_MUSIC_YM_DOWNLOADER",
                            os.path.join(os.path.dirname(sys.executable), "yandex-music-downloader"))
SITE = "https://music.yandex.ru"
# yandex_music's client id for the implicit OAuth flow (the token ends up in the redirect URL)
SIGNIN_URL = "https://oauth.yandex.ru/authorize?response_type=token&client_id=23cabbbdc6cd418abb4b39c32c41195d"
DEFAULTS = {"storage": "library", "quality": 2, "temp_limit_mb": 2048, "auto_sync": True,
            "sync_likes": True, "sync_playlists": [], "embed_lyrics": True}
AUDIO = (".m4a", ".flac", ".mp3")
_DL_LINE = re.compile(r"^(?:\[(\d+)/(\d+)\] )?\[[^\]]*\] Загружается (.+)$")
_KEEP_FRESH = 6 * 3600          # temp files used this recently are never pruned
_children = set()               # running downloader processes (killed when the worker exits)

logging.getLogger("yandex_music").setLevel(logging.CRITICAL)
_out_lock = threading.Lock()
_api_lock = threading.Lock()


def make_client(token):
    """A yandex_music Client whose requests go one at a time (the API answers parallel calls from
    one token with 429 "Concurrency limit exceeded") and retry a 429 / network error a few times."""
    c = Client(token)
    c.request.set_timeout(20)
    orig = c.request._request_wrapper

    def wrapper(*a, **k):
        for i in range(5):
            with _api_lock:
                try:
                    return orig(*a, **k)
                except YandexMusicError as ex:
                    if i == 4 or not ("429" in str(ex) or isinstance(ex, NetworkError)):
                        raise
            time.sleep(0.3 * (2 ** i))
    c.request._request_wrapper = wrapper
    return c.init()


def emit(obj):
    data = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    with _out_lock:
        sys.stdout.write(data + "\n")
        sys.stdout.flush()


# ── settings ────────────────────────────────────────────────────────────────

def load_conf():
    try:
        with open(CONF, encoding="utf-8") as fh:
            c = json.load(fh)
    except (OSError, ValueError):
        c = {}
    return dict(DEFAULTS, **c)


def save_conf(c):
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    tmp = CONF + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(c, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, CONF)


def public_conf(c):
    return {k: v for k, v in c.items() if k != "token"}


def parse_token(text):
    """A bare token, or the whole sign-in redirect URL (…#access_token=…&…)."""
    text = (text or "").strip()
    m = re.search(r"access_token=([^&\s]+)", text)
    return m.group(1) if m else text


def music_dir():
    d = os.environ.get("GLASS_MUSIC_DIR", "")
    if not d:
        try:
            from .mpdclient import MPD
            d = MPD().dict("config").get("music_directory", "")
        except Exception:
            d = ""
    return os.path.expanduser(d or HOME + "/Music")


# ── lrcput: .lrc next to the file -> its lyrics tag ──────────────────────────

def _lyrics_tag(path):
    """(mutagen file, current lyrics) for an audio file, or (None, None)."""
    from mutagen.flac import FLAC
    from mutagen.id3 import ID3NoHeaderError
    from mutagen.mp3 import MP3
    from mutagen.mp4 import MP4
    ext = os.path.splitext(path)[1].lower()
    try:
        if ext == ".m4a":
            f = MP4(path)
            return f, "".join((f.tags or {}).get("\xa9lyr", []))
        if ext == ".flac":
            f = FLAC(path)
            return f, "".join(f.get("lyrics", []))
        if ext == ".mp3":
            f = MP3(path)
            if f.tags is None:
                f.add_tags()
            return f, "".join(str(fr) for fr in f.tags.getall("USLT"))
    except (ID3NoHeaderError, Exception):
        pass
    return None, None


def embed_lrc(path):
    """Embed path's sibling .lrc into its tags if they differ. True if the file was written."""
    lrc = os.path.splitext(path)[0] + ".lrc"
    try:
        with open(lrc, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return False
    if not text.strip():
        return False
    f, cur = _lyrics_tag(path)
    if f is None or (cur or "").strip() == text.strip():
        return False
    from mutagen.flac import FLAC
    from mutagen.id3 import USLT
    from mutagen.mp4 import MP4
    if isinstance(f, MP4):
        if f.tags is None:
            f.add_tags()
        f.tags["\xa9lyr"] = text
    elif isinstance(f, FLAC):
        f["lyrics"] = text
    else:
        f.tags.delall("USLT")
        f.tags.add(USLT(encoding=3, lang="XXX", desc="", text=text))
    f.save()
    return True


def embed_tree(root, log=None):
    """lrcput over a whole tree (skips hidden dirs). Returns (checked, written, failed)."""
    checked = written = 0
    failed = []
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if not x.startswith(".")]
        names = set(files)
        for n in files:
            stem, ext = os.path.splitext(n)
            if ext.lower() not in AUDIO or stem + ".lrc" not in names:
                continue
            checked += 1
            p = os.path.join(d, n)
            try:
                if embed_lrc(p):
                    written += 1
                    if log:
                        log(p)
            except Exception as ex:
                failed.append(f"{p}: {ex}")
    return checked, written, failed


# ── Yandex ──────────────────────────────────────────────────────────────────

class YM:
    def __init__(self):
        self.conf = load_conf()
        self.lib = music_dir()
        self._client = None
        self.tracks = {}          # track id -> yandex_music Track (for local paths + links)
        self.canon = {}           # track id -> Track as the downloader sees it (client.tracks)
        self.likes = None

    def client(self):
        if self._client is None:
            tok = self.conf.get("token")
            if not tok:
                raise YandexMusicError("Not signed in to Yandex Music")
            self._client = make_client(tok)
        return self._client

    def login(self):
        acc = self.client().me.account if self.client().me else None
        return (acc.login or acc.display_name or "") if acc else ""

    # paths ---------------------------------------------------------------
    def base(self, t):
        return str(core.prepare_base_path(core.DEFAULT_PATH_PATTERN, t))

    def find(self, t):
        """(absolute path, "lib" | "tmp") of a downloaded copy of track t, or ("", "").

        A search / playlist result can list a track under another album (a compilation) than
        the one the downloader files it under (tracks(id).albums[0]); both are checked."""
        bases = [self.base(t)]
        full = self.canon.get(str(t.id))
        if full is not None and full is not t:
            bases.append(self.base(full))
        for root, kind in ((self.lib, "lib"), (TEMP, "tmp")):
            for b in bases:
                for s in AUDIO:
                    p = os.path.join(root, b + s)
                    if os.path.isfile(p):
                        return p, kind
        return "", ""

    @staticmethod
    def link(t):
        al = t.albums[0].id if t.albums else None
        return f"{SITE}/album/{al}/track/{t.id}" if al else f"{SITE}/track/{t.id}"

    @staticmethod
    def cover(uri, size="200x200"):
        return "https://" + uri.replace("%%", size) if uri else ""

    def track_obj(self, t):
        self.tracks[str(t.id)] = t
        al = t.albums[0] if t.albums else None
        path, kind = self.find(t)
        li = t.lyrics_info
        return {"id": str(t.id), "t": core.full_title(t),
                "a": ", ".join(a.name for a in (t.artists or []) if a.name),
                "ar": [{"id": str(a.id), "n": a.name} for a in (t.artists or []) if a.name][:3],
                "al": core.full_title(al) if al else "", "alId": str(al.id) if al else "",
                "y": (al.year if al else None) or "", "d": round((t.duration_ms or 0) / 1000),
                "c": self.cover(t.cover_uri or (al.cover_uri if al else None)),
                "ok": bool(t.available), "have": kind, "path": path, "url": self.link(t),
                "lrc": bool(li and li.has_available_sync_lyrics),
                "liked": self.likes is not None and str(t.id) in self.likes}

    def album_obj(self, a):
        return {"kind": "album", "id": str(a.id), "n": core.full_title(a),
                "s": ", ".join(x.name for x in (a.artists or []) if x.name),
                "y": a.year or "", "c": self.cover(a.cover_uri), "url": f"{SITE}/album/{a.id}",
                "nt": a.track_count or 0}

    def artist_obj(self, a):
        c = a.cover.uri if a.cover and a.cover.uri else (a.og_image or "")
        return {"kind": "artist", "id": str(a.id), "n": a.name, "c": self.cover(c),
                "url": f"{SITE}/artist/{a.id}"}

    @staticmethod
    def playlist_link(p):
        """The site's playlist link (the downloader resolves /playlists/<uuid>; the old
        /users/<login>/playlists/<kind> form loses the owner in its URL parser)."""
        if p.playlist_uuid:
            return f"{SITE}/playlists/{p.playlist_uuid}"
        return f"{SITE}/users/{p.owner.login if p.owner else ''}/playlists/{p.kind}"

    def playlist_obj(self, p):
        c = p.cover.uri if p.cover and p.cover.uri else (p.og_image or "")
        return {"kind": "playlist", "id": f"{p.owner.uid if p.owner else p.uid}:{p.kind}", "n": p.title,
                "s": (p.owner.name or owner) if p.owner else "", "c": self.cover(c),
                "url": self.playlist_link(p), "nt": p.track_count or 0}

    def full_tracks(self, ids):
        out = []
        ids = [str(i) for i in ids]
        for i in range(0, len(ids), 100):
            out += self.client().tracks(ids[i:i + 100])
        return out

    def track_id_of(self, path):
        """Yandex track id of a local file: the downloader's link tag (newer downloads), else the
        liked track whose downloader path is this file."""
        try:
            import mutagen
            f = mutagen.File(path)
            tags = f.tags if f is not None else None
            vals = []
            if tags is not None:
                for k in ("\xa9cmt", "comment", "COMMENT"):
                    v = tags.get(k) if hasattr(tags, "get") else None
                    if v:
                        vals += [str(x) for x in (v if isinstance(v, list) else [v])]
                if hasattr(tags, "getall"):
                    vals += [str(fr.url) for fr in tags.getall("WOAF")]
            for v in vals:
                m = re.search(r"music\.yandex\.\w+/(?:album/\d+/)?track/(\d+)", v)
                if m:
                    return m.group(1)
        except Exception:
            pass
        return self.liked_paths().get(os.path.splitext(os.path.realpath(path))[0])

    def liked_paths(self):
        """{library path without extension: track id} for every liked track (cached)."""
        if getattr(self, "_liked_paths", None) is None:
            out = {}
            for t in self.full_tracks(self.liked_ids()):
                for root in (self.lib, TEMP):
                    out[os.path.realpath(os.path.join(root, self.base(t)))] = str(t.id)
            self._liked_paths = out
        return self._liked_paths

    def liked_ids(self, refresh=False):
        if self.likes is None or refresh:
            tl = self.client().users_likes_tracks()
            self.likes = [str(x.id) for x in (tl.tracks if tl else [])]
        return self.likes

    # browse --------------------------------------------------------------
    def search(self, q):
        try:
            self.liked_ids()
        except YandexMusicError:
            pass
        r = self.client().search(q, type_="all")
        out = {"tracks": [], "albums": [], "artists": [], "playlists": [], "best": None}
        if not r:
            return out
        if r.tracks:
            out["tracks"] = [self.track_obj(t) for t in r.tracks.results[:20]]
        if r.albums:
            out["albums"] = [self.album_obj(a) for a in r.albums.results[:12]]
        if r.artists:
            out["artists"] = [self.artist_obj(a) for a in r.artists.results[:12]]
        if r.playlists:
            out["playlists"] = [self.playlist_obj(p) for p in r.playlists.results[:8]]
        b = r.best
        if b and b.result is not None:
            fn = {"track": self.track_obj, "album": self.album_obj, "artist": self.artist_obj,
                  "playlist": self.playlist_obj}.get(b.type)
            if fn:
                out["best"] = dict(fn(b.result), type=b.type)
        return out

    def open(self, kind, id_):
        c = self.client()
        try:
            self.liked_ids()
        except YandexMusicError:
            pass
        if kind == "album":
            a = c.albums_with_tracks(id_)
            tracks = []
            for vol in (a.volumes or []):
                for t in vol:
                    if t.albums:
                        t.albums[0].volumes = a.volumes
                    tracks.append(t)
            return dict(self.album_obj(a), tracks=[self.track_obj(t) for t in tracks],
                        sub="Album · " + ", ".join(x.name for x in (a.artists or []) if x.name))
        if kind == "artist":
            ar = c.artists([id_])[0]
            top = c.artists_tracks(id_, page_size=50)
            albums = c.artists_direct_albums(id_, page_size=50, sort_by="year")
            return dict(self.artist_obj(ar), sub="Artist",
                        tracks=[self.track_obj(t) for t in (top.tracks if top else [])],
                        albums=[self.album_obj(a) for a in (albums.albums if albums else [])])
        if kind == "playlist":
            uid, _, k = id_.partition(":")
            p = c.users_playlists(k, uid)
            ids = [ts.id for ts in (p.tracks or p.fetch_tracks())]
            return dict(self.playlist_obj(p), sub="Playlist · " + (p.owner.name if p.owner else ""),
                        tracks=[self.track_obj(t) for t in self.full_tracks(ids)])
        if kind == "likes":
            return {"kind": "likes", "id": "likes", "n": "Liked on Yandex", "sub": "Your Yandex Music likes",
                    "c": "", "url": "", "tracks": [self.track_obj(t) for t in self.full_tracks(self.liked_ids(True))]}
        raise ValueError(kind)

    def my_playlists(self):
        likes = self.client().users_playlists(3)
        out = [{"kind": "likes", "id": "likes", "n": "Liked on Yandex", "nt": len(self.liked_ids()),
                "url": self.playlist_link(likes), "sync": bool(self.conf.get("sync_likes"))}]
        chosen = set(map(str, self.conf.get("sync_playlists", [])))
        for p in self.client().users_playlists_list():
            o = self.playlist_obj(p)
            o["sync"] = o["id"] in chosen
            out.append(o)
        return out

    # downloads -----------------------------------------------------------
    def run_downloader(self, url, dest, on_line=None, stop=None, lyrics=True):
        """yandex-music-downloader -u url; returns the files it wrote (absolute paths).

        A failing lyrics fetch fails the whole track in the downloader (Yandex's lyrics storage
        sometimes answers 500), so a failed run is retried once without lyrics."""
        q = int(self.conf.get("quality", 2))
        args = [DOWNLOADER, "--quality", str(q), "--skip-existing", "--lyrics-format", "lrc" if lyrics else "none",
                "--tries", "3", "--retry-delay", "2",
                "--dir", dest, "--token", self.conf.get("token", ""), "-u", url]
        os.makedirs(dest, exist_ok=True)
        p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                             start_new_session=True, env=dict(os.environ, PYTHONUNBUFFERED="1"))
        _children.add(p)
        wrote, tail = [], []
        try:
            for line in p.stdout:
                line = line.rstrip("\n")
                if stop is not None and stop():
                    p.send_signal(signal.SIGTERM)
                    break
                m = _DL_LINE.match(line)
                if m:
                    path = m.group(3)
                    wrote.append(path if os.path.isabs(path) else os.path.join(dest, path))
                    if on_line:
                        on_line(int(m.group(1) or 0), int(m.group(2) or 0), os.path.basename(path))
                elif line.strip():
                    tail = (tail + [line])[-4:]
        finally:
            rc = p.wait()
            _children.discard(p)
        if stop is not None and stop():
            self.clean_tmp(dest)
            return []
        if rc != 0:
            self.clean_tmp(dest)
            if lyrics:
                emit({"type": "ym-log", "msg": f"downloader failed ({' '.join(tail)[-200:]}); retrying without lyrics"})
                return [x for x in wrote if os.path.isfile(x)] + self.run_downloader(url, dest, on_line, stop, lyrics=False)
            raise RuntimeError("downloader: " + (" ".join(tail)[-300:] or f"exit {rc}"))
        for path in wrote:
            if self.conf.get("embed_lyrics", True):
                try:
                    embed_lrc(path)
                except Exception as ex:
                    emit({"type": "ym-log", "msg": f"lyrics embed failed: {path}: {ex}"})
        return [p for p in wrote if os.path.isfile(p)]

    @staticmethod
    def clean_tmp(dest):
        for d, _, files in os.walk(dest):
            for n in files:
                if n.startswith(".yandex-music-downloader.") and n.endswith(".tmp"):
                    try:
                        os.remove(os.path.join(d, n))
                    except OSError:
                        pass

    def get_track(self, tid):
        t = self.tracks.get(str(tid))
        if t is None:
            t = self.full_tracks([tid])[0]
            self.tracks[str(tid)] = t
        return t

    def fetch(self, tid, storage=None, stop=None):
        """A local file for track tid, downloading it if needed. storage: library | temp.
        Saving to the library moves an existing temp copy instead of downloading again."""
        storage = storage or self.conf.get("storage", "library")
        t = self.get_track(tid)
        if str(tid) not in self.canon:
            self.canon[str(tid)] = self.full_tracks([tid])[0]
        path, kind = self.find(t)
        if path and not (kind == "tmp" and storage == "library"):
            if kind == "tmp":
                os.utime(path)
            return path
        if path:   # temp -> library
            dst = os.path.join(self.lib, os.path.relpath(path, TEMP))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            for ext in ("", ".lrc"):
                src = path if not ext else os.path.splitext(path)[0] + ext
                if os.path.isfile(src):
                    shutil.move(src, dst if not ext else os.path.splitext(dst)[0] + ext)
            for cov in ("cover.jpg", "cover.png"):
                s, d = os.path.join(os.path.dirname(path), cov), os.path.join(os.path.dirname(dst), cov)
                if os.path.isfile(s) and not os.path.exists(d):
                    shutil.copy2(s, d)
            return dst
        if not t.available:
            raise RuntimeError(f"“{core.full_title(t)}” is not available on Yandex Music")
        dest = self.lib if storage == "library" else TEMP
        wrote = [p for p in self.run_downloader(self.link(t), dest, stop=stop) if p.lower().endswith(AUDIO)]
        path = wrote[0] if wrote else self.find(t)[0]
        if not path:
            if stop is not None and stop():
                return ""
            raise RuntimeError(f"download of “{core.full_title(t)}” produced no file")
        if dest == TEMP:
            self.prune_temp()
        return path

    def prune_temp(self, protect=()):
        limit = int(self.conf.get("temp_limit_mb", 2048)) << 20
        files, total = [], 0
        for d, _, names in os.walk(TEMP):
            for n in names:
                p = os.path.join(d, n)
                try:
                    st = os.stat(p)
                except OSError:
                    continue
                total += st.st_size
                if os.path.splitext(n)[1].lower() in AUDIO:
                    files.append((max(st.st_mtime, st.st_atime), st.st_size, p))
        now = time.time()
        for used, size, p in sorted(files):
            if total <= limit:
                break
            if now - used < _KEEP_FRESH or p in protect:
                continue
            for x in (p, os.path.splitext(p)[0] + ".lrc"):
                try:
                    total -= os.path.getsize(x)
                    os.remove(x)
                except OSError:
                    pass
        # drop emptied album dirs (only covers left)
        for d, dirs, names in os.walk(TEMP, topdown=False):
            if d != TEMP and not dirs and all(not n.lower().endswith(AUDIO) for n in names):
                shutil.rmtree(d, ignore_errors=True)
        return total

    def temp_size(self):
        n = 0
        for d, _, names in os.walk(TEMP):
            for x in names:
                try:
                    n += os.path.getsize(os.path.join(d, x))
                except OSError:
                    pass
        return n

    def sync(self, progress=None, stop=None):
        """Liked tracks + chosen playlists into the library, through the downloader by link."""
        os.makedirs(CACHE, exist_ok=True)
        lockf = open(LOCK, "w")
        try:
            fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise RuntimeError("a sync is already running")
        try:
            urls = []
            if self.conf.get("sync_likes", True):
                urls.append(("Liked", self.playlist_link(self.client().users_playlists(3))))
            for pid in self.conf.get("sync_playlists", []):
                uid, _, kind = str(pid).partition(":")
                try:
                    p = self.client().users_playlists(kind, uid)
                    if p:
                        urls.append((p.title, self.playlist_link(p)))
                except YandexMusicError as ex:
                    emit({"type": "ym-log", "msg": f"playlist {pid}: {ex}"})
            new = []
            for name, url in urls:
                if stop is not None and stop():
                    break
                def line(i, n, f, name=name):
                    if progress:
                        progress(name, i, n, f)
                new += self.run_downloader(url, self.lib, on_line=line, stop=stop)
            if self.conf.get("embed_lyrics", True):
                embed_tree(self.lib)       # also lyrics that arrived without a new download
            self.conf["last_sync"] = int(time.time())
            self.conf["last_sync_new"] = len(new)
            c = load_conf()
            c.update(last_sync=self.conf["last_sync"], last_sync_new=len(new))
            save_conf(c)
            return new
        finally:
            fcntl.flock(lockf, fcntl.LOCK_UN)
            lockf.close()

    def mpd_update(self, paths):
        """Ask MPD to index new library files (it may also see them through inotify)."""
        try:
            from .mpdclient import MPD
            m = MPD()
            dirs = sorted({os.path.relpath(os.path.dirname(p), self.lib) for p in paths
                           if p.startswith(self.lib + os.sep)})
            for d in dirs[:200]:
                m.cmd("update", d)
            if len(dirs) > 200:
                m.cmd("update")
        except Exception as ex:
            emit({"type": "ym-log", "msg": f"mpd update: {ex}"})


# ── serve: the worker behind glassmusic.server ───────────────────────────────

class Worker:
    def __init__(self):
        self.ym = YM()
        self.browse_q = queue.Queue()
        self.dl_q = queue.Queue()
        self.play_gen = 0         # a new play job supersedes the running one
        self.cancelled = set()

    def status(self):
        c = self.ym.conf
        out = {"type": "ym-status", "signed": bool(c.get("token")), "conf": public_conf(c),
               "downloader": os.path.exists(DOWNLOADER), "temp": TEMP, "tempSize": self.ym.temp_size(),
               "signin": SIGNIN_URL, "lib": self.ym.lib}
        if c.get("token"):
            try:
                cl = self.ym.client()
                out["name"] = self.ym.login()
                out["plus"] = bool(cl.me.plus and cl.me.plus.has_plus)
            except Exception as ex:
                out["error"] = str(ex)
        emit(out)

    def browse_loop(self):
        while True:
            c = self.browse_q.get()
            # searches: only the newest one matters
            if c.get("cmd") == "search":
                while True:
                    try:
                        n = self.browse_q.get_nowait()
                    except queue.Empty:
                        break
                    if n.get("cmd") == "search":
                        c = n
                    else:
                        self.browse_q.put(n)
                        break
            try:
                self.browse(c)
            except Exception as ex:
                emit({"type": "ym-error", "cmd": c.get("cmd"), "rid": c.get("rid", 0), "text": str(ex)})

    def browse(self, c):
        cmd = c.get("cmd")
        if cmd == "search":
            emit(dict(self.ym.search(c.get("q", "")), type="ym-search", q=c.get("q", ""), rid=c.get("rid", 0)))
        elif cmd == "open":
            emit(dict(self.ym.open(c.get("kind"), str(c.get("id"))), type="ym-page", rid=c.get("rid", 0)))
        elif cmd == "playlists":
            emit({"type": "ym-playlists", "items": self.ym.my_playlists()})
        elif cmd == "status":
            self.status()
        elif cmd == "remove":
            self.remove(c)
        elif cmd == "like":
            tid, on = str(c.get("id")), bool(c.get("on", True))
            cl = self.ym.client()
            (cl.users_likes_tracks_add if on else cl.users_likes_tracks_remove)(tid)
            likes = self.ym.liked_ids()
            if on and tid not in likes:
                likes.insert(0, tid)
            elif not on and tid in likes:
                likes.remove(tid)
            emit({"type": "ym-liked", "id": tid, "on": on})
            emit({"type": "toast", "icon": "heart" if on else "heart-outline",
                  "text": "Liked on Yandex Music" if on else "Removed from your Yandex likes"})

    def remove(self, c):
        """Unlike the songs on Yandex (so the daily sync leaves them out), then remove the files."""
        paths = [p for p in c.get("paths", []) if isinstance(p, str)]
        ids, unliked = {}, 0
        if c.get("unlike"):
            for p in paths:
                tid = c.get("ids", {}).get(p) or self.ym.track_id_of(p)
                if tid:
                    ids[p] = str(tid)
        removed, failed, rescan = removal.remove(paths, [self.ym.lib, TEMP], [self.ym.lib])
        gone = [ids[p] for p in removed if p in ids]
        if gone:
            try:
                self.ym.client().users_likes_tracks_remove(gone)
                unliked = len(gone)
                if self.ym.likes is not None:
                    self.ym.likes = [x for x in self.ym.likes if x not in set(gone)]
                for tid in gone:
                    emit({"type": "ym-liked", "id": tid, "on": False})
            except Exception as ex:
                emit({"type": "ym-log", "msg": f"unlike failed: {ex}"})
        emit({"type": "ym-removed", "paths": removed, "failed": failed, "rescan": rescan,
              "unliked": unliked, "notFound": len([p for p in removed if p not in ids]) if c.get("unlike") else 0})

    def dl_loop(self):
        while True:
            c = self.dl_q.get()
            job = c.get("job", 0)
            try:
                if c.get("cmd") == "fetch":
                    self.fetch_job(c)
                elif c.get("cmd") == "download":
                    self.download_job(c)
                elif c.get("cmd") == "sync":
                    self.sync_job(job)
            except Exception as ex:
                emit({"type": "ym-done", "job": job, "mode": c.get("mode", c.get("cmd")), "ok": False, "text": str(ex)})
                emit({"type": "ym-log", "msg": traceback.format_exc(limit=3)})

    def fetch_job(self, c):
        """Tracks for play / add / next / save, the clicked one first, then the rest in order."""
        job, mode, ids = c.get("job", 0), c.get("mode", "play"), [str(i) for i in c.get("ids", [])]
        at = max(0, min(int(c.get("at", 0)), len(ids) - 1)) if ids else 0
        gen = self.play_gen if mode == "play" else None
        stop = (lambda: (gen is not None and gen != self.play_gen) or job in self.cancelled)
        order = list(range(at, len(ids))) + list(range(0, at))
        storage = "library" if mode == "save" else None
        done, failed, saved = 0, [], []
        for n, i in enumerate(order):
            if stop():
                return
            t = self.ym.tracks.get(ids[i])
            emit({"type": "ym-progress", "job": job, "mode": mode, "done": n, "total": len(order),
                  "text": core.full_title(t) if t else ""})
            try:
                path = self.ym.fetch(ids[i], storage, stop=stop)
            except Exception as ex:
                failed.append(str(ex))
                emit({"type": "ym-log", "msg": f"fetch {ids[i]}: {ex}"})
                continue
            if not path or stop():
                return
            t = self.ym.tracks.get(ids[i])
            done += 1
            saved.append(path)
            emit({"type": "ym-ready", "job": job, "mode": mode, "idx": i, "at": at, "id": ids[i], "path": path,
                  "lib": path.startswith(self.ym.lib + os.sep),
                  "t": core.full_title(t) if t else "", "c": self.ym.cover(t.cover_uri) if t else ""})
        emit({"type": "ym-done", "job": job, "mode": mode, "ok": not failed, "n": done,
              "text": failed[0] if failed else ""})

    def download_job(self, c):
        """Save a whole album / artist / playlist link to the library."""
        job, url, title = c.get("job", 0), c.get("url", ""), c.get("title", "")
        if not url.startswith(SITE + "/"):
            raise ValueError("not a music.yandex.ru link")
        def line(i, n, f):
            emit({"type": "ym-progress", "job": job, "mode": "download", "done": i, "total": n, "text": f})
        emit({"type": "ym-progress", "job": job, "mode": "download", "done": 0, "total": 0, "text": title})
        new = self.ym.run_downloader(url, self.ym.lib, on_line=line, stop=lambda: job in self.cancelled)
        emit({"type": "ym-done", "job": job, "mode": "download", "ok": True, "n": len(new), "text": title,
              "paths": new})

    def sync_job(self, job):
        def prog(name, i, n, f):
            emit({"type": "ym-progress", "job": job, "mode": "sync", "done": i, "total": n, "text": f"{name}: {f}"})
        emit({"type": "ym-progress", "job": job, "mode": "sync", "done": 0, "total": 0, "text": "Checking your likes…"})
        new = self.ym.sync(prog, stop=lambda: job in self.cancelled)
        emit({"type": "ym-done", "job": job, "mode": "sync", "ok": True, "n": len(new), "paths": new})
        self.status()

    def handle(self, c):
        cmd = c.get("cmd")
        if cmd in ("search", "open", "playlists", "like", "status", "remove"):
            self.browse_q.put(c)
        elif cmd in ("fetch", "download", "sync"):
            if cmd == "fetch" and c.get("mode") == "play":
                self.play_gen += 1
            self.dl_q.put(c)
        elif cmd == "cancel":
            self.cancelled.add(c.get("job"))
        elif cmd == "login":
            tok = parse_token(c.get("token", ""))
            try:
                cl = make_client(tok)
                if not (cl.me and cl.me.account and cl.me.account.uid):
                    raise YandexMusicError("this token is not signed in")
            except Exception as ex:
                emit({"type": "toast", "icon": "warn", "text": f"Yandex sign-in failed: {ex}"})
                return
            conf = load_conf()
            conf["token"] = tok
            save_conf(conf)
            self.ym.conf, self.ym._client, self.ym.likes = conf, cl, None
            emit({"type": "toast", "icon": "account", "text": "Signed in to Yandex Music"})
            self.status()
        elif cmd == "logout":
            conf = load_conf()
            conf.pop("token", None)
            save_conf(conf)
            self.ym.conf, self.ym._client, self.ym.likes = conf, None, None
            self.status()
        elif cmd == "settings":
            conf = load_conf()
            for k in DEFAULTS:
                if k in c.get("set", {}):
                    conf[k] = c["set"][k]
            save_conf(conf)
            tok = self.ym.conf.get("token")
            self.ym.conf = conf
            if conf.get("token") != tok:
                self.ym._client = None
            self.status()
        elif cmd == "cleartemp":
            shutil.rmtree(TEMP, ignore_errors=True)
            emit({"type": "toast", "icon": "delete", "text": "Temporary Yandex downloads cleared"})
            self.status()
        elif cmd == "prune":
            self.ym.prune_temp(set(c.get("protect", [])))

    def run(self):
        threading.Thread(target=self.browse_loop, daemon=True).start()
        threading.Thread(target=self.dl_loop, daemon=True).start()
        self.browse_q.put({"cmd": "status"})
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                self.handle(json.loads(line))
            except Exception as ex:
                emit({"type": "ym-error", "text": str(ex)})
        kill_children()


def kill_children():
    for p in list(_children):
        try:
            p.terminate()
            p.wait(3)
        except Exception:
            try:
                p.kill()
            except Exception:
                pass


# ── CLI ─────────────────────────────────────────────────────────────────────

def main(argv):
    cmd = argv[0] if argv else "serve"
    signal.signal(signal.SIGTERM, lambda *_: (kill_children(), os._exit(143)))
    if cmd == "serve":
        Worker().run()
        return 0
    if cmd == "embed":
        root = argv[1] if len(argv) > 1 else music_dir()
        checked, written, failed = embed_tree(root, log=lambda p: print("embedded", p))
        print(f"{checked} files with .lrc, {written} updated, {len(failed)} failed")
        for f in failed:
            print("  failed:", f)
        return 1 if failed else 0
    if cmd == "login":
        tok = parse_token(sys.stdin.readline())
        make_client(tok)
        conf = load_conf()
        conf["token"] = tok
        save_conf(conf)
        print("signed in")
        return 0
    ym = YM()
    if cmd == "status":
        print(json.dumps({"signed": bool(ym.conf.get("token")), "login": ym.login() if ym.conf.get("token") else "",
                          "conf": public_conf(ym.conf), "temp": TEMP, "lib": ym.lib}, ensure_ascii=False, indent=1))
        return 0
    if cmd == "sync":
        if "--if-auto" in argv and not ym.conf.get("auto_sync", True):
            print("auto sync is off")
            return 0
        if not ym.conf.get("token"):
            print("not signed in (glass-music → Yandex Music, or: python -m glassmusic.yandex login)")
            return 0
        new = ym.sync(lambda name, i, n, f: print(f"[{name} {i}/{n}] {f}", flush=True))
        ym.mpd_update(new)
        print(f"{len(new)} new tracks")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
