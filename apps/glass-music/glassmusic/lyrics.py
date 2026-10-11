"""Lyrics for a track: a synced .lrc next to it, else lyrics embedded in the file's tags
(MP4 ©lyr, ID3 USLT, FLAC Vorbis LYRICS), else a plain .txt next to it.

load() returns {"lines": [{"t": seconds, "x": text, "w": [[t, char offset], ...]?}],
"synced": bool, "source": "lrc" | "embedded" | "txt" | ""}. Unsynced lyrics have t = -1
and an empty x marks a stanza break. Dependency-free; reads at most a few MB per file."""

import os
import re
import struct

_TAG = re.compile(r"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]")
_WORD = re.compile(r"<(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)>")
_META = re.compile(r"^\s*\[[a-zA-Z#]+:[^\]]*\]\s*$")
_MAX_TAG_BYTES = 64 << 20


def _secs(m, s):
    return int(m) * 60 + float(s.replace(":", "."))


def parse_lrc(text):
    """Synced lines, sorted; repeated empty lines collapsed; leading blank at 0 s dropped.

    Enhanced-LRC word stamps (<mm:ss.xx>) are removed from the text and kept as
    w = [[time, char offset in x], ...] so the UI can follow the words."""
    offset = 0.0
    m = re.search(r"\[offset:\s*([+-]?\d+)\]", text, re.I)
    if m:
        offset = int(m.group(1)) / 1000.0
    out = []
    for line in text.splitlines():
        times = [_secs(a, b) for a, b in _TAG.findall(line)]
        if not times:
            continue
        body = _TAG.sub("", line)
        words, x, pos = [], "", 0
        for wm in _WORD.finditer(body):
            x += body[pos:wm.start()]
            words.append([round(max(0.0, _secs(*wm.groups()) - offset), 3), len(x)])
            pos = wm.end()
        x += body[pos:]
        lead = len(x) - len(x.lstrip())
        x = x.strip()
        words = [[t, max(0, min(len(x), c - lead))] for t, c in words]
        for t in times:
            r = {"t": round(max(0.0, t - offset), 3), "x": x}
            if words and len(times) == 1:
                r["w"] = words
            out.append(r)
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


def parse_plain(text):
    """Unsynced lyrics: one entry per line, t = -1, single empty entries between stanzas."""
    out = []
    for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if _META.match(line):
            continue
        x = line.strip()
        if not x and (not out or not out[-1]["x"]):
            continue
        out.append({"t": -1, "x": x})
    while out and not out[-1]["x"]:
        out.pop()
    return out


def parse_any(text):
    """(lines, synced) for text that may or may not carry LRC time stamps."""
    if _TAG.search(text):
        lines = parse_lrc(text)
        if any(r["x"] for r in lines):
            return lines, True
    lines = parse_plain(_TAG.sub("", text))
    return lines, False


# ---------------------------------------------------------------- embedded tags

def _mp4_lyrics(fh):
    """The ©lyr text of an MP4/M4A file (moov/udta/meta/ilst/©lyr/data)."""
    def boxes(data, start, end):
        p = start
        while p + 8 <= end:
            size, kind = struct.unpack(">I4s", data[p:p + 8])
            hdr = 8
            if size == 1:
                size = struct.unpack(">Q", data[p + 8:p + 16])[0]
                hdr = 16
            elif size == 0:
                size = end - p
            if size < hdr:
                return
            yield kind, p + hdr, min(end, p + size)
            p += size

    # walk the top level on disk until moov (it may sit after mdat)
    fh.seek(0, 2)
    flen = fh.tell()
    p = 0
    moov = None
    while p + 8 <= flen:
        fh.seek(p)
        h = fh.read(16)
        if len(h) < 8:
            break
        size, kind = struct.unpack(">I4s", h[:8])
        if size == 1 and len(h) >= 16:
            size = struct.unpack(">Q", h[8:16])[0]
        elif size == 0:
            size = flen - p
        if size < 8:
            break
        if kind == b"moov":
            if size > _MAX_TAG_BYTES:
                return ""
            fh.seek(p)
            moov = fh.read(size)
            break
        p += size
    if not moov:
        return ""

    def find(data, start, end, path):
        for kind, a, b in boxes(data, start, end):
            if kind == path[0]:
                if len(path) == 1:
                    return a, b
                if kind == b"meta" and data[a + 4:a + 8] != b"hdlr":
                    a += 4          # full box (iTunes): version + flags
                r = find(data, a, b, path[1:])
                if r:
                    return r
        return None

    hdr = struct.unpack(">I", moov[:4])[0]
    start = 16 if hdr == 1 else 8
    r = find(moov, start, len(moov), [b"udta", b"meta", b"ilst", b"\xa9lyr", b"data"])
    if not r:
        return ""
    a, b = r
    return moov[a + 8:b].decode("utf-8", "replace")     # skip type + locale


def _syncsafe(b):
    return (b[0] << 21) | (b[1] << 14) | (b[2] << 7) | b[3]


def _id3_lyrics(fh):
    """USLT text from an ID3v2.3/2.4 tag at the start of the file."""
    fh.seek(0)
    h = fh.read(10)
    if len(h) < 10 or h[:3] != b"ID3" or h[3] not in (3, 4):
        return ""
    ver, flags, size = h[3], h[5], _syncsafe(h[6:10])
    data = fh.read(min(size, _MAX_TAG_BYTES))
    if flags & 0x80:   # whole-tag unsynchronisation
        data = data.replace(b"\xff\x00", b"\xff")
    p = 0
    if flags & 0x40:   # extended header
        p = _syncsafe(data[:4]) if ver == 4 else struct.unpack(">I", data[:4])[0] + 4
    while p + 10 <= len(data):
        fid = data[p:p + 4]
        if not fid.strip(b"\x00"):
            break
        fsize = _syncsafe(data[p + 4:p + 8]) if ver == 4 else struct.unpack(">I", data[p + 4:p + 8])[0]
        body = data[p + 10:p + 10 + fsize]
        p += 10 + fsize
        if fid != b"USLT" or len(body) < 5:
            continue
        enc, rest = body[0], body[4:]
        if enc in (1, 2):
            # descriptor ends at an aligned 00 00
            i = 0
            while i + 1 < len(rest) and rest[i:i + 2] != b"\x00\x00":
                i += 2
            text = rest[i + 2:]
            codec = "utf-16" if enc == 1 else "utf-16-be"
        else:
            i = rest.find(b"\x00")
            text = rest[i + 1:] if i >= 0 else b""
            codec = "latin-1" if enc == 0 else "utf-8"
        return text.decode(codec, "replace").rstrip("\x00")
    return ""


def _flac_lyrics(fh):
    """LYRICS / UNSYNCEDLYRICS from a FLAC Vorbis comment block."""
    fh.seek(0)
    if fh.read(4) != b"fLaC":
        return ""
    while True:
        h = fh.read(4)
        if len(h) < 4:
            return ""
        last, kind, size = h[0] & 0x80, h[0] & 0x7F, int.from_bytes(h[1:4], "big")
        if kind != 4:
            fh.seek(size, 1)
            if last:
                return ""
            continue
        d = fh.read(size)
        vlen = struct.unpack("<I", d[:4])[0]
        p = 4 + vlen
        n = struct.unpack("<I", d[p:p + 4])[0]
        p += 4
        found = {}
        for _ in range(n):
            ln = struct.unpack("<I", d[p:p + 4])[0]
            kv = d[p + 4:p + 4 + ln].decode("utf-8", "replace")
            p += 4 + ln
            k, _, v = kv.partition("=")
            if k.upper() in ("LYRICS", "UNSYNCEDLYRICS", "SYNCEDLYRICS"):
                found[k.upper()] = v
        return found.get("SYNCEDLYRICS") or found.get("LYRICS") or found.get("UNSYNCEDLYRICS") or ""


def embedded(path):
    try:
        with open(path, "rb") as fh:
            head = fh.read(12)
            if head[:3] == b"ID3":
                return _id3_lyrics(fh)
            if head[:4] == b"fLaC":
                return _flac_lyrics(fh)
            if head[4:8] == b"ftyp":
                return _mp4_lyrics(fh)
    except (OSError, struct.error, IndexError, ValueError):
        pass
    return ""


# ---------------------------------------------------------------- entry point

def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def load(music_dir, rel):
    """Best lyrics for the track at music_dir/rel."""
    empty = {"lines": [], "synced": False, "source": ""}
    if rel.startswith("file:///"):        # a file outside the library (Yandex temp downloads)
        path = rel[7:]
    elif not rel or "://" in rel:
        return empty
    else:
        path = os.path.join(music_dir, rel)
    stem = os.path.splitext(path)[0]
    fallback = None
    text = _read(stem + ".lrc")
    if text is not None:
        lines, synced = parse_any(text)
        if synced:
            return {"lines": lines, "synced": True, "source": "lrc"}
        if lines:
            fallback = {"lines": lines, "synced": False, "source": "lrc"}
    text = embedded(path)
    if text.strip():
        lines, synced = parse_any(text)
        if synced:
            return {"lines": lines, "synced": True, "source": "embedded"}
        if lines and not fallback:
            fallback = {"lines": lines, "synced": False, "source": "embedded"}
    if fallback:
        return fallback
    text = _read(stem + ".txt")
    if text and text.strip():
        lines, synced = parse_any(text)
        if lines:
            return {"lines": lines, "synced": synced, "source": "txt"}
    return empty
