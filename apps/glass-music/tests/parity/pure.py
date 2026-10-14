"""Pure-function parity: the Python modules vs the Rust backend's --pure hook, over the real library
(read-only: song files, .lrc / .txt and covers are only read).

    python -m tests.parity.pure [MUSIC_DIR] [LIBRARY_JSON]
"""
import hashlib
import json
import os
import random
import subprocess
import sys
import time

from glassmusic import lyrics, lyricsfetch, search, thumbs

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUST = os.path.join(ROOT, "backend/target/release/glass-music-backend")
HOME = os.path.expanduser("~")


class Rust:
    def __init__(self):
        self.p = subprocess.Popen([RUST, "--pure"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

    def __call__(self, **kw):
        self.p.stdin.write(json.dumps(kw, ensure_ascii=False) + "\n")
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())


def queries(lib):
    rnd = random.Random(1)
    qs = ["", " ", "a", "the", "nebula", "небула", "туигдф", "ё", "Ёлка", "ﾃｽﾄ", "テスト", "てすと", "ß", "ǅ", "_", "--", "!!!", "x.y/z",
          "shch", "Щука", "yo", "ja", "ju", "kh", "AC/DC", "  multiple   words  ", "100%", "№1", "Ⅻ", "½", "㉑", "ﬁ"]
    for t in lib["tracks"]:
        qs.append(t["t"])
        qs.append(t["a"])
    for a in lib["albums"]:
        qs.append(a["n"])
    out = []
    for q in qs:
        out.append(q)
        if q:
            out.append(q[: max(1, len(q) // 2)])
            out.append(q.upper())
            w = q.split()
            if len(w) > 1:
                out.append(" ".join(reversed(w)))
    rnd.shuffle(out)
    return list(dict.fromkeys(out))


def main():
    music = sys.argv[1] if len(sys.argv) > 1 else HOME + "/Music"
    libpath = sys.argv[2] if len(sys.argv) > 2 else HOME + "/.cache/glass-music/library.json"
    with open(libpath, encoding="utf-8") as fh:
        lib = json.load(fh)["lib"]
    rs = Rust()
    stats = {}
    bad = []
    timing = {}

    def check(kind, py, rsv, ctx):
        stats[kind] = stats.get(kind, 0) + 1
        if json.loads(json.dumps(py)) != rsv:
            bad.append((kind, ctx, py, rsv))

    # strings
    for q in queries(lib) + ["ΟΔΟΣ", "ΣΑΣ.", "İstanbul", "ǈ", "ꭰ", "ﬃ", "𐐀"]:
        check("casefold", q.casefold(), rs(fn="casefold", s=q), q)
        check("lower", q.lower(), rs(fn="lower", s=q), q)
    # search
    t0 = time.time()
    idx = search.Index(lib)
    rs(fn="index", lib=lib)
    qs = queries(lib)
    for q in qs:
        check("norm", search.norm(q), rs(fn="norm", s=q), q)
        check("variants", [list(v) for v in search.variants(q)], rs(fn="variants", s=q), q)
        check("search", idx.search(q), rs(fn="search", q=q), q)
    timing["search"] = time.time() - t0
    # lyrics on every song
    files = [os.path.join(music, t["f"]) for t in lib["tracks"]]
    t0 = time.time()
    for p in files:
        check("embedded", lyrics.embedded(p), rs(fn="embedded", path=p), p)
        check("load_path", lyrics.load_path(p), rs(fn="load_path", path=p), p)
        for ext in (".lrc", ".txt"):
            txt = lyrics._read(os.path.splitext(p)[0] + ext)
            if txt:
                lines, synced = lyrics.parse_any(txt)
                check("parse_any", [lines, synced], rs(fn="parse_any", text=txt), p + ext)
    timing["lyrics"] = time.time() - t0
    # tricky LRC / plain texts
    for txt in ["[00:01.00]a\n[00:01.00]\n\n[00:02]b", "[offset:+500]\n[00:01.20]x <00:01.50>y <00:02.00> z", "[ar:x]\nplain\n\n\nline",
                "[01:02:03]x", "[0:5]x\r\n[0:4]y\r[0:3]z", "  [00:00.00]  \n[00:00.10]\n[00:03.00]hi", "[٠١:٠٢.٣]arabic digits",
                "[00:01.00][00:05.00]chorus <00:01.20>w", "﻿[00:01.00]bom", "[re:Glass Music · LRCLIB]\n[00:01.00]x", ""]:
        check("parse_any", list(lyrics.parse_any(txt)), rs(fn="parse_any", text=txt), txt)
    # resolver matching
    tr = lib["tracks"]
    rnd = random.Random(2)
    for t in tr:
        for s in (t["t"], t["a"], t["al"], t["t"] + " (feat. Somebody)", t["t"] + " - 2011 Remaster", t["t"] + " ft. X y"):
            check("lfnorm", lyricsfetch._norm(s), rs(fn="lfnorm", s=s), s)
        o = rnd.choice(tr)
        meta = {"artist": t["a"], "title": t["t"], "album": t["al"], "duration": t["d"]}
        for title, artist, dur in ((t["t"], t["a"], t["d"]), (t["t"], o["a"], t["d"] + 2.5), (o["t"], t["a"], t["d"]),
                                   (t["t"].upper(), t["a"] + " & Friend", t["d"] + 4), (t["t"], None, None), (None, t["a"], 0)):
            check("matches", lyricsfetch.matches(meta, title, artist, dur),
                  rs(fn="matches", meta=meta, title=title, artist=artist, duration=dur), (title, artist, dur))
    # covers: dominant colour + thumbnail pixels (Pillow vs the Rust port)
    t0 = time.time()
    from PIL import Image
    for a in lib["albums"]:
        check("hash_colour", thumbs._hash_colour(a["k"]), rs(fn="hash_colour", s=a["k"]), a["k"])
        if not a["c"]:
            continue
        with Image.open(a["c"]) as im:
            im = im.convert("RGB")
            col = thumbs._dominant(im)
            im.thumbnail((thumbs.SIZE, thumbs.SIZE), Image.LANCZOS)
            py = {"c": col, "w": im.width, "h": im.height, "px": hashlib.sha1(im.tobytes()).hexdigest()}
        check("cover", py, rs(fn="dominant", path=a["c"]), a["c"])
    timing["covers"] = time.time() - t0

    for kind, n in sorted(stats.items()):
        nb = sum(1 for b in bad if b[0] == kind)
        print(f"{kind:12} {n:6} checked, {nb} differ")
    for kind, ctx, py, rsv in bad[:40]:
        print(f"\n--- {kind}: {str(ctx)[:200]}\n  py {json.dumps(py, ensure_ascii=False)[:600]}\n  rs {json.dumps(rsv, ensure_ascii=False)[:600]}")
    print({k: round(v, 1) for k, v in timing.items()})
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
