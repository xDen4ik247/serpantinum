"""Lazy cover thumbnails + a dominant colour per album, cached on disk.

~/.cache/glass-music/thumbs/<sha1(album)>.jpg (256 px) and index.json {album: {p, c, mt}}.
A thumbnail is made only when the UI first shows that album; stale ones (cover mtime
changed) are remade."""

import colorsys
import hashlib
import json
import os
import threading

try:
    from PIL import Image
except Exception:  # Pillow missing: use the original covers, colour from a hash
    Image = None

SIZE = 256


class Thumbs:
    def __init__(self, cache_dir, emit):
        self.dir = os.path.join(cache_dir, "thumbs")
        os.makedirs(self.dir, exist_ok=True)
        self.index_path = os.path.join(self.dir, "index.json")
        self.emit = emit
        self.lock = threading.Lock()
        self.cv = threading.Condition(self.lock)
        self.todo = []
        self.pending = set()
        try:
            with open(self.index_path, encoding="utf-8") as fh:
                self.index = json.load(fh)
        except Exception:
            self.index = {}
        threading.Thread(target=self._run, daemon=True).start()

    def known(self, albums):
        """Cached entries that are still valid, for the initial library message."""
        out = {}
        for a in albums:
            e = self.index.get(a["k"])
            if e and a["c"] and os.path.exists(e["p"]):
                try:
                    if abs(os.path.getmtime(a["c"]) - e["mt"]) < 1:
                        out[a["k"]] = {"p": e["p"], "c": e["c"]}
                except OSError:
                    pass
        return out

    def request(self, items):
        """items: [(album key, cover path)]"""
        with self.cv:
            for k, src in items:
                if k in self.pending or not src:
                    continue
                self.pending.add(k)
                self.todo.append((k, src))
            self.cv.notify()

    def _run(self):
        try:
            os.nice(5)
        except OSError:
            pass
        while True:
            with self.cv:
                while not self.todo:
                    self.cv.wait()
                batch, self.todo = self.todo[:24], self.todo[24:]
            out = {}
            for k, src in batch:
                try:
                    out[k] = self._make(k, src)
                except Exception:
                    out[k] = {"p": src, "c": _hash_colour(k)}
            with self.lock:
                for k, _ in batch:
                    self.pending.discard(k)
                try:
                    tmp = self.index_path + ".tmp"
                    with open(tmp, "w", encoding="utf-8") as fh:
                        json.dump(self.index, fh, ensure_ascii=False)
                    os.replace(tmp, self.index_path)
                except OSError:
                    pass
            self.emit({"type": "thumbs", "items": out})

    def _make(self, key, src):
        mt = os.path.getmtime(src)
        e = self.index.get(key)
        if e and abs(e["mt"] - mt) < 1 and os.path.exists(e["p"]):
            return {"p": e["p"], "c": e["c"]}
        if Image is None:
            res = {"p": src, "c": _hash_colour(key)}
        else:
            dst = os.path.join(self.dir, hashlib.sha1(key.encode()).hexdigest() + ".jpg")
            with Image.open(src) as im:
                im = im.convert("RGB")
                col = _dominant(im)
                im.thumbnail((SIZE, SIZE), Image.LANCZOS)
                im.save(dst + ".tmp", "JPEG", quality=88)
            os.replace(dst + ".tmp", dst)
            res = {"p": dst, "c": col}
        self.index[key] = dict(res, mt=mt)
        return res


def _dominant(im):
    """A pleasant accent colour: saturation/brightness-weighted average of a tiny copy."""
    small = im.resize((24, 24))
    tot = [0.0, 0.0, 0.0]
    wsum = 0.0
    for r, g, b in small.getdata():
        h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
        w = (s ** 1.5) * (v ** 0.8) + 0.02
        tot[0] += r * w
        tot[1] += g * w
        tot[2] += b * w
        wsum += w
    r, g, b = (c / wsum / 255 for c in tot)
    h, l, s = colorsys.rgb_to_hls(r, g, b)
    l = min(0.62, max(0.38, l))
    s = min(0.85, s * 1.25)
    r, g, b = colorsys.hls_to_rgb(h, l, s)
    return "#%02x%02x%02x" % (round(r * 255), round(g * 255), round(b * 255))


def _hash_colour(key):
    h = int(hashlib.md5(key.encode()).hexdigest()[:6], 16) / 0xFFFFFF
    r, g, b = colorsys.hls_to_rgb(h, 0.5, 0.5)
    return "#%02x%02x%02x" % (round(r * 255), round(g * 255), round(b * 255))
