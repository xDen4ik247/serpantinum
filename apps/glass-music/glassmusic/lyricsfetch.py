"""Lyrics resolver: finds lyrics for songs that have none (or only plain ones), once, in the background.

Chain: the song's own lyrics (.lrc / tag / .txt, glassmusic.lyrics) -> Yandex Music (the signed-in
worker: the song's own Yandex track, else a catalogue match by artist + title + duration) -> LRCLIB
(lrclib.net, public) -> plain lyrics from any of them. Synced beats plain; nothing is ever made up:
a song with no lyrics anywhere stays without (and is asked again after a while).

Only artist, title, album and duration leave the machine. Results are written once:
synced -> <song>.lrc next to the file, plain -> <song>.txt, both marked "[re:Glass Music · <source>]"
and never over an existing file (a song folder that isn't writable gets them in the cache instead).
"These lyrics are wrong": the text's hash is remembered as rejected for that song and the next
candidate is used. A file this resolver wrote is moved to the cache; the user's own files are never
touched (the replacement then lives in the cache and wins over them).

CLI (coverage / bulk fill):  python -m glassmusic.lyricsfetch scan [--limit N] [--no-yandex] [--dry-run]
"""

import hashlib
import json
import os
import queue
import re
import sys
import threading
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

from . import lyrics

HOME = os.path.expanduser("~")
UA = "GlassMusic/1.0 (+https://github.com/xDen4ik247/serpantinum)"
LRCLIB = os.environ.get("GLASS_MUSIC_LRCLIB", "https://lrclib.net/api")   # tests point it at a fake
RETRY_MISS = 14 * 86400         # nothing found: ask again after two weeks
RETRY_PLAIN = 30 * 86400        # only plain lyrics: look for synced ones again after a month
YM_TIMEOUT = 25


def _norm(s):
    s = unicodedata.normalize("NFKC", s or "").lower().replace("ё", "е")
    s = re.sub(r"\s*[\(\[][^\)\]]*(feat|ft\.|with|prod|remaster|version|edit|live|explicit|bonus)[^\)\]]*[\)\]]", "", s)
    s = re.sub(r"\s+-\s+.*(remaster|version|edit|mix|live).*$", "", s)
    s = re.sub(r"\s+(feat\.?|ft\.)\s.*$", "", s)
    return re.sub(r"[^\w]+", "", s)


def _artists(s):
    parts = re.split(r"\s*(?:,|&|;|/| x | feat\.? | ft\. | и | and )\s*", (s or "").lower())
    return {_norm(p) for p in parts if _norm(p)}


def matches(meta, title, artist, duration):
    """Is a catalogue hit the same song as meta (title, an artist in common, duration ±3 s)?"""
    if _norm(title) != _norm(meta.get("title")) or not _norm(title):
        return False
    a, b = _artists(meta.get("artist")), _artists(artist)
    if a and b and not (a & b) and _norm(meta.get("artist")) != _norm(artist):
        return False
    d = meta.get("duration") or 0
    return not (d and duration and abs(float(duration) - float(d)) > 3.0)


def _key(path):
    return hashlib.sha1(path.encode("utf-8")).hexdigest()[:16]


class Resolver:
    def __init__(self, music_dir, cache_dir, on_found=None, ym_send=None, log=None):
        self.music_dir = music_dir
        self.dir = os.path.join(cache_dir, "lyrics")
        self.state_path = os.path.join(self.dir, "state.json")
        self.on_found = on_found            # fn(path, result) when a lookup changed a song's lyrics
        self.ym_send = ym_send              # fn(request dict) -> None, or None without Yandex
        self.log = log or (lambda msg: None)
        self.q = queue.PriorityQueue()
        self.queued = {}
        self.busy = None
        self.n = 0
        self.lock = threading.Lock()
        self.ym_waits = {}
        self.ym_rid = 0
        self.ym_ok = lambda: True          # e.g. signed in to Yandex Music
        try:
            with open(self.state_path, encoding="utf-8") as fh:
                self.state = json.load(fh)
        except (OSError, ValueError):
            self.state = {}
        self.thread = None

    # ── state ────────────────────────────────────────────────────────────
    def _save(self):
        os.makedirs(self.dir, exist_ok=True)
        tmp = self.state_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(self.state, fh, ensure_ascii=False)
        os.replace(tmp, self.state_path)

    def rejected(self, path):
        return set(self.state.get(path, {}).get("rej", []))

    def override(self, path):
        """A replacement kept in the cache (song folder read-only, or the user's own file rejected)."""
        k = _key(path)
        for ext in (".lrc", ".txt"):
            p = os.path.join(self.dir, "over", k + ext)
            if os.path.exists(p):
                return p
        return ""

    # ── what the UI shows ────────────────────────────────────────────────
    def load(self, path):
        """lyrics.load_path() plus a cached replacement, minus rejected texts; adds the lookup state."""
        skip = self.rejected(path)
        r = lyrics.load_path(path, skip)
        ov = self.override(path)
        if ov and not r["synced"]:
            text = lyrics._read(ov) or ""
            lines, synced = lyrics.parse_any(text)
            if lines and lyrics.text_hash(lines) not in skip and (synced or not r["lines"]):
                r = {"lines": lines, "synced": synced, "source": "cache", "origin": lyrics.origin_of(text),
                     "hash": lyrics.text_hash(lines)}
        st = self.state.get(path, {})
        r["instrumental"] = not r["lines"] and st.get("res") == "instrumental"
        r["pending"] = path in self.queued or self.busy == path
        r["looked"] = bool(st.get("t"))
        return r

    # ── queueing ─────────────────────────────────────────────────────────
    def due(self, path, cur=None):
        """Should a lookup run for this song now? (no synced lyrics, not asked recently)"""
        if not path or not os.path.exists(path):
            return False
        cur = cur or self.load(path)
        if cur["synced"]:
            return False
        st = self.state.get(path, {})
        age = time.time() - st.get("t", 0)
        return age > (RETRY_PLAIN if cur["lines"] else RETRY_MISS)

    def want(self, path, meta, front=False, force=False):
        """Queue a lookup (front: the song on screen; force: the user asked)."""
        if not path or not meta or not meta.get("title"):
            return False
        if not force and not self.due(path):
            return False
        with self.lock:
            if path in self.queued or self.busy == path:
                return True
            self.n += 1
            self.queued[path] = True
            self.q.put((0 if front else 1, self.n, path, meta, force))
        self._start()
        return True

    def reject(self, path, meta):
        """The shown lyrics are wrong: remember their hash, drop our own copy, look again."""
        cur = self.load(path)
        if not cur["hash"]:
            return False
        st = self.state.setdefault(path, {})
        st["rej"] = sorted(set(st.get("rej", [])) | {cur["hash"]})
        st.pop("t", None)
        # a file we wrote goes to the cache (recoverable); the user's own files stay untouched
        stem = os.path.splitext(path)[0]
        for p in (stem + ".lrc", stem + ".txt", self.override(path)):
            if p and os.path.exists(p) and lyrics.origin_of(lyrics._read(p) or ""):
                lines, _ = lyrics.parse_any(lyrics._read(p) or "")
                if lyrics.text_hash(lines) == cur["hash"]:
                    os.makedirs(os.path.join(self.dir, "rejected"), exist_ok=True)
                    os.replace(p, os.path.join(self.dir, "rejected", _key(path) + "-" + cur["hash"] + os.path.splitext(p)[1]))
        self._save()
        self.want(path, meta, front=True, force=True)
        return True

    def _start(self):
        if self.thread is None or not self.thread.is_alive():
            self.thread = threading.Thread(target=self._loop, daemon=True)
            self.thread.start()

    def _loop(self):
        while True:
            try:
                _, _, path, meta, force = self.q.get(timeout=60)
            except queue.Empty:
                return                      # idle: the thread ends, the next want() starts one
            with self.lock:
                self.queued.pop(path, None)
                self.busy = path
            try:
                changed = self.resolve(path, meta)
            except Exception as ex:          # network trouble etc.: try again another time
                self.log(f"lyrics lookup failed: {type(ex).__name__}: {ex}")
                changed = False
            finally:
                with self.lock:
                    self.busy = None
            if self.on_found:
                try:
                    self.on_found(path, self.load(path), changed)
                except Exception:
                    pass

    # ── the chain ────────────────────────────────────────────────────────
    def candidates(self, path, meta):
        """(source, text, synced) in order of preference, fetched lazily."""
        plain = []
        if self.ym_send and self.ym_ok():
            r = self.ask_ym({"cmd": "lyrics", "path": path, "artist": meta.get("artist", ""),
                             "title": meta.get("title", ""), "duration": meta.get("duration", 0)})
            if r and r.get("lrc"):
                yield "Yandex Music", r["lrc"], True
            if r and r.get("text"):
                plain.append(("Yandex Music", r["text"]))
        hits = self.lrclib(meta)
        for h in hits:
            if h.get("syncedLyrics"):
                yield "LRCLIB", h["syncedLyrics"], True
        for h in hits:
            if h.get("plainLyrics"):
                plain.append(("LRCLIB", h["plainLyrics"]))
        for src, text in plain:
            yield src, text, False
        if any(h.get("instrumental") for h in hits):
            yield "LRCLIB", "", None         # instrumental

    def resolve(self, path, meta):
        cur = self.load(path)
        skip = self.rejected(path)
        st = self.state.setdefault(path, {})
        found = None
        for src, text, synced in self.candidates(path, meta):
            if synced is None:
                if not cur["lines"] and not found:
                    found = (src, "", None)
                break
            lines, really = lyrics.parse_any(text)
            if not lines or lyrics.text_hash(lines) in skip or lyrics.text_hash(lines) == cur["hash"]:
                continue
            if really or not (cur["lines"] or found):
                found = (src, text, really)
                if really:
                    break
        st["t"] = int(time.time())
        if not found:
            st["res"] = "synced" if cur["synced"] else ("plain" if cur["lines"] else "none")
            self._save()
            return False
        src, text, synced = found
        if synced is None:
            st["res"] = "instrumental"
            self._save()
            return True
        self.write(path, src, text, synced)
        st["res"], st["src"] = ("synced" if synced else "plain"), src
        self._save()
        return True

    def write(self, path, src, text, synced):
        """<song>.lrc / .txt next to the song when free, else the cache (never overwrite)."""
        body = "[re:%s · %s]\n%s\n" % (lyrics.MARK, src, text.strip())
        stem, ext = os.path.splitext(path)[0], (".lrc" if synced else ".txt")
        target = stem + ext
        if os.path.exists(target) or not os.access(os.path.dirname(path), os.W_OK):
            target = os.path.join(self.dir, "over", _key(path) + ext)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            other = os.path.join(self.dir, "over", _key(path) + (".txt" if synced else ".lrc"))
            if synced and os.path.exists(other):
                os.remove(other)            # our cached plain copy is superseded
        tmp = target + ".part"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(body)
        os.replace(tmp, target)
        self.log(f"lyrics: {'synced' if synced else 'plain'} from {src} -> {os.path.basename(target)}")

    # ── sources ──────────────────────────────────────────────────────────
    def lrclib(self, meta):
        """LRCLIB hits for the song: the exact signature first, then search results that match."""
        q = {"artist_name": meta.get("artist", ""), "track_name": meta.get("title", "")}
        out = []
        if meta.get("album") and meta.get("duration"):
            r = _get(LRCLIB + "/get?" + urllib.parse.urlencode(dict(q, album_name=meta["album"],
                                                                    duration=round(meta["duration"]))))
            if r:
                out.append(r)
        res = _get(LRCLIB + "/search?" + urllib.parse.urlencode(q)) or []
        seen = {r.get("id") for r in out}
        for r in res:
            if r.get("id") not in seen and matches(meta, r.get("trackName"), r.get("artistName"), r.get("duration")):
                out.append(r)
        return out

    def ask_ym(self, req):
        with self.lock:
            self.ym_rid += 1
            rid = self.ym_rid
            ev = threading.Event()
            self.ym_waits[rid] = [ev, None]
        try:
            self.ym_send(dict(req, rid="lyr%d" % rid))
        except Exception:
            self.ym_waits.pop(rid, None)
            return None
        ev.wait(YM_TIMEOUT)
        return self.ym_waits.pop(rid, [None, None])[1]

    def on_ym(self, m):
        """A reply from the Yandex worker (ym-lyrics, or ym-error for a lyrics request)."""
        rid = str(m.get("rid", ""))
        if not rid.startswith("lyr"):
            return
        w = self.ym_waits.get(int(rid[3:]))
        if w:
            w[1] = m if m.get("type") == "ym-lyrics" else None
            w[0].set()


def _get(url, tries=3):
    for i in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=15) as r:
                return json.load(r)
        except urllib.error.HTTPError as ex:
            if ex.code == 404:
                return None
            if ex.code < 500 and ex.code != 429:
                raise
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if i == tries - 1:
                raise
        time.sleep(1.5 * (i + 1))
    raise ConnectionError("LRCLIB unavailable")


# ── CLI: bulk fill for the whole library ─────────────────────────────────────

class _YmPipe:
    """The Yandex worker as a child process (CLI only; the app relays through its own one)."""

    def __init__(self, resolver):
        import subprocess
        py = os.environ.get("GLASS_MUSIC_YM_PYTHON", HOME + "/.local/share/glass-music/yandex-venv/bin/python")
        env = dict(os.environ, PYTHONPATH=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   PYTHONUNBUFFERED="1", GLASS_MUSIC_DIR=resolver.music_dir)
        self.p = subprocess.Popen([py, "-m", "glassmusic.yandex", "serve"], env=env, text=True,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.r = resolver
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.p.stdout:
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if m.get("type") in ("ym-lyrics", "ym-error"):
                self.r.on_ym(m)

    def send(self, c):
        self.p.stdin.write(json.dumps(c, ensure_ascii=False) + "\n")
        self.p.stdin.flush()


def main(argv):
    if not argv or argv[0] != "scan":
        print(__doc__)
        return 2
    cache = os.environ.get("GLASS_MUSIC_CACHE", os.path.join(os.environ.get("XDG_CACHE_HOME", HOME + "/.cache"), "glass-music"))
    with open(os.path.join(cache, "library.json"), encoding="utf-8") as fh:
        d = json.load(fh)
    music_dir, tracks = d["dir"], d["lib"]["tracks"]
    limit = int(argv[argv.index("--limit") + 1]) if "--limit" in argv else 0
    r = Resolver(music_dir, cache, log=lambda m: None)
    if "--no-yandex" not in argv and signed_in():
        r.ym_send = _YmPipe(r).send
    todo = []
    for t in tracks:
        p = lyrics.song_path(music_dir, t["f"])
        if r.due(p):
            todo.append((p, {"artist": t.get("a", ""), "title": t.get("t", ""), "album": t.get("al", ""),
                             "duration": t.get("d", 0)}))
    if limit:
        todo = todo[:limit]
    print(f"{len(todo)} songs to look up (of {len(tracks)})", flush=True)
    stats = {}
    for i, (p, meta) in enumerate(todo, 1):
        if "--dry-run" in argv:
            continue
        try:
            r.resolve(p, meta)
            res = r.state.get(p, {}).get("res", "?") + ":" + r.state.get(p, {}).get("src", "-")
        except Exception as ex:
            res = "error:" + type(ex).__name__
        stats[res] = stats.get(res, 0) + 1
        if i % 25 == 0 or i == len(todo):
            print(f"[{i}/{len(todo)}] {stats}", flush=True)
        time.sleep(0.2)
    return 0


def signed_in():
    try:
        with open(os.path.join(os.environ.get("XDG_CONFIG_HOME", HOME + "/.config"), "glass-music", "yandex.json"),
                  encoding="utf-8") as fh:
            return bool(json.load(fh).get("token"))
    except (OSError, ValueError):
        return False


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
