"""Library index: one MPD `listallinfo` turned into compact tracks / albums / artists,
cached as JSON and reused while MPD's database timestamp (`db_update`) is unchanged."""

import importlib.machinery
import importlib.util
import json
import os
import re
import sys
from collections import Counter, defaultdict

from .mpdclient import MPD

VERSION = 4
MUSIC_SMART = os.environ.get("GLASS_MUSIC_SMART_BIN", os.path.expanduser("~/.local/bin/music-smart"))
MOOD_LABEL = {"heavy": "Heavy", "rock": "Rock", "alt": "Alt & indie", "rap": "Rap",
              "electronic": "Electronic", "pop": "Pop", "chill": "Chill"}

_ms = None


def music_smart():
    """music-smart as a module (read-only use of its mood rules and weighting model)."""
    global _ms
    if _ms is None:
        try:
            old = sys.dont_write_bytecode
            sys.dont_write_bytecode = True
            loader = importlib.machinery.SourceFileLoader("music_smart", MUSIC_SMART)
            spec = importlib.util.spec_from_loader("music_smart", loader)
            mod = importlib.util.module_from_spec(spec)
            loader.exec_module(mod)
            _ms = mod
        except Exception:
            _ms = False
        finally:
            sys.dont_write_bytecode = old
    return _ms or None


def mood_of(genres):
    ms = music_smart()
    if ms:
        return ms.mood_of(genres)
    return "alt"


def _int(v, default=0):
    try:
        return int(str(v).split("/")[0])
    except (TypeError, ValueError):
        return default


def build(mpd, music_dir):
    songs = MPD.songs(mpd.cmd("listallinfo"))
    tracks = []
    for s in songs:
        f = s["file"]
        if f.startswith(".") or "/." in f:
            continue
        parts = f.split("/")
        artists = [a.strip() for v in s.get("Artist", []) for a in v.split(";") if a.strip()]
        primary = parts[0] if len(parts) > 1 else (artists[0] if artists else "Unknown artist")
        base = os.path.splitext(parts[-1])[0]
        title = s.get("Title") or re.sub(r"^\d+\s*-\s*", "", base)
        try:
            dur = round(float(s.get("duration") or s.get("Time") or 0), 2)
        except ValueError:
            dur = 0.0
        genres = s.get("Genre", [])
        tracks.append({
            "f": f,
            "t": title,
            "a": ", ".join(artists) or primary,
            "as": artists or [primary],
            "p": primary,
            "al": s.get("Album") or (parts[-2] if len(parts) > 2 else ""),
            "k": os.path.dirname(f),
            "n": _int(s.get("Track"), 0),
            "dn": _int(s.get("Disc"), 1),
            "d": dur,
            "y": (s.get("Date") or "")[:4],
            "g": genres[0] if genres else "",
            "m": mood_of(genres),
            "ad": s.get("Added") or s.get("Last-Modified") or "",
            "l": os.path.exists(os.path.join(music_dir, os.path.splitext(f)[0] + ".lrc")),
        })
    tracks.sort(key=lambda t: (t["p"].casefold(), t["k"].casefold(), t["dn"], t["n"], t["t"].casefold()))

    by_album = defaultdict(list)
    for i, t in enumerate(tracks):
        by_album[t["k"]].append(i)
    albums = []
    for k, idx in by_album.items():
        ts = [tracks[i] for i in idx]
        aa = Counter(", ".join(t["as"]) for t in ts).most_common(1)[0][0]
        cover = os.path.join(music_dir, k, "cover.jpg")
        albums.append({
            "k": k,
            "n": ts[0]["al"] or os.path.basename(k),
            "p": ts[0]["p"],
            "ar": aa,
            "y": max((t["y"] for t in ts), default=""),
            "c": cover if os.path.exists(cover) else "",
            "tr": idx,
            "d": round(sum(t["d"] for t in ts)),
            "m": Counter(t["m"] for t in ts).most_common(1)[0][0],
            "ad": max(t["ad"] for t in ts),
            "single": len(ts) <= 3,
        })
    albums.sort(key=lambda a: (a["p"].casefold(), a["y"], a["n"].casefold()))

    by_artist = defaultdict(list)
    for a in albums:
        by_artist[a["p"]].append(a)
    feat = defaultdict(list)
    for i, t in enumerate(tracks):
        for name in t.get("as", ()):
            if name.casefold() != t["p"].casefold():
                feat[name.casefold()].append(i)
    artists = []
    for name, als in by_artist.items():
        als_sorted = sorted(als, key=lambda a: (a["y"], a["ad"]), reverse=True)
        cover = next((a["k"] for a in als_sorted if a["c"]), "")
        artists.append({
            "n": name,
            "al": [a["k"] for a in als_sorted],
            "nt": sum(len(a["tr"]) for a in als),
            "c": cover,
            "ap": feat.get(name.casefold(), [])[:60],
            "m": Counter(a["m"] for a in als).most_common(1)[0][0],
        })
    artists.sort(key=lambda a: a["n"].casefold())
    for t in tracks:            # keep the cached / sent JSON small
        del t["ad"]
        if len(t["as"]) < 2:
            del t["as"]
    moods = Counter(t["m"] for t in tracks)
    return {"v": VERSION, "tracks": tracks, "albums": albums, "artists": artists,
            "moods": [{"id": m, "label": MOOD_LABEL.get(m, m), "n": moods.get(m, 0)}
                      for m in MOOD_LABEL if moods.get(m, 0) > 0]}


def load(mpd, music_dir, cache_dir, force=False):
    """Return (library, from_cache)."""
    stamp = mpd.dict("stats").get("db_update", "")
    path = os.path.join(cache_dir, "library.json")
    if not force:
        try:
            with open(path, encoding="utf-8") as fh:
                c = json.load(fh)
            if c.get("v") == VERSION and c.get("stamp") == stamp and c.get("dir") == music_dir:
                return c["lib"], True
        except Exception:
            pass
    lib = build(mpd, music_dir)
    os.makedirs(cache_dir, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({"v": VERSION, "stamp": stamp, "dir": music_dir, "lib": lib}, fh, ensure_ascii=False,
                  separators=(",", ":"))
    os.replace(tmp, path)
    return lib, False
