"""Instant search over artists, albums and tracks (Latin, Cyrillic, Japanese).

Every key is normalised the same way (NFKC, casefold, ё→е, katakana→hiragana, punctuation
dropped). A query is tried as typed, with the keyboard layout swapped (typing Russian on the
US layout and back) and transliterated (Latin ↔ Cyrillic), so "небула", "nebula" and "туигдф"
all find nebula.
"""

import re
import unicodedata

_PUNCT = re.compile(r"[^\w\s]+", re.UNICODE)
_SPACES = re.compile(r"[\s_]+")

US = "`qwertyuiop[]asdfghjkl;'zxcvbnm,./"
RU = "ёйцукенгшщзхъфывапролджэячсмитьбю."
_US2RU = {a: b for a, b in zip(US, RU)}
_RU2US = {b: a for a, b in zip(US, RU)}

_RU2LAT = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z",
    "и": "i", "й": "i", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
    "с": "s", "т": "t", "у": "u", "ф": "f", "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sch",
    "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
}
_LAT2RU = [
    ("shch", "щ"), ("sch", "щ"), ("zh", "ж"), ("kh", "х"), ("ts", "ц"), ("ch", "ч"), ("sh", "ш"),
    ("yu", "ю"), ("ya", "я"), ("yo", "ё"), ("ye", "е"), ("ju", "ю"), ("ja", "я"),
    ("a", "а"), ("b", "б"), ("v", "в"), ("w", "в"), ("g", "г"), ("d", "д"), ("e", "е"), ("z", "з"),
    ("i", "и"), ("j", "й"), ("y", "ы"), ("k", "к"), ("c", "к"), ("q", "к"), ("l", "л"), ("m", "м"),
    ("n", "н"), ("o", "о"), ("p", "п"), ("r", "р"), ("s", "с"), ("t", "т"), ("u", "у"), ("f", "ф"),
    ("h", "х"), ("x", "кс"),
]


def norm(s):
    if not s:
        return ""
    s = unicodedata.normalize("NFKC", s).casefold().replace("ё", "е")
    # katakana → hiragana so either script finds the other
    s = "".join(chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in s)
    s = _PUNCT.sub(" ", s)
    return _SPACES.sub(" ", s).strip()


def _swap_layout(q):
    if any(c in _RU2US for c in q):
        return "".join(_RU2US.get(c, c) for c in q)
    return "".join(_US2RU.get(c, c) for c in q)


def _translit(q):
    if any("Ѐ" <= c <= "ӿ" for c in q):
        return "".join(_RU2LAT.get(c, c) for c in q)
    out, i = [], 0
    while i < len(q):
        for lat, cyr in _LAT2RU:
            if q.startswith(lat, i):
                out.append(cyr)
                i += len(lat)
                break
        else:
            out.append(q[i])
            i += 1
    return "".join(out)


def variants(query):
    q = norm(query)
    if not q:
        return []
    out = [(q, 1.0)]
    raw = query.casefold()
    sw = norm(_swap_layout(raw))
    if sw and sw != q:
        out.append((sw, 0.8))
    tr = norm(_translit(q))
    if tr and tr not in (q, sw):
        out.append((tr, 0.7))
    return out


def score_key(key, q):
    """0 = no match; higher is better."""
    if not key:
        return 0
    if key == q:
        return 100
    if key.startswith(q):
        return 80 + 10 * len(q) / max(1, len(key))
    i = key.find(" " + q)
    if i >= 0:
        return 60 - min(10, i / 4)
    i = key.find(q)
    if i >= 0:
        return 40 - min(10, i / 4)
    # every word of the query is somewhere in the key
    words = q.split()
    if len(words) > 1 and all(w in key for w in words):
        return 30
    return 0


class Index:
    def __init__(self, lib):
        self.tracks = [(i, norm(t["t"]), norm(t["a"] + " " + t["al"])) for i, t in enumerate(lib["tracks"])]
        self.albums = [(a["k"], norm(a["n"]), norm(a["ar"])) for a in lib["albums"]]
        self.artists = [(a["n"], norm(a["n"])) for a in lib["artists"]]

    def search(self, query, limit_tracks=60, limit_albums=24, limit_artists=18):
        vs = variants(query)
        if not vs:
            return {"artists": [], "albums": [], "tracks": [], "top": None}

        def best(*keys):
            b = 0
            for q, w in vs:
                for j, k in enumerate(keys):
                    s = score_key(k, q) * w * (1.0 if j == 0 else 0.55)
                    if s > b:
                        b = s
            return b

        ar = sorted(((best(k), n) for n, k in self.artists), key=lambda x: -x[0])
        ar = [(s, n) for s, n in ar if s > 0][:limit_artists]
        al = sorted(((best(k, a), key) for key, k, a in self.albums), key=lambda x: -x[0])
        al = [(s, k) for s, k in al if s > 0][:limit_albums]
        tr = sorted(((best(k, a), i) for i, k, a in self.tracks), key=lambda x: -x[0])
        tr = [(s, i) for s, i in tr if s > 0][:limit_tracks]
        top = None
        cands = []
        if ar:
            cands.append((ar[0][0] + 6, "artist", ar[0][1]))
        if al:
            cands.append((al[0][0] + 2, "album", al[0][1]))
        if tr:
            cands.append((tr[0][0], "track", tr[0][1]))
        if cands:
            s, kind, ref = max(cands, key=lambda c: c[0])
            top = {"kind": kind, "ref": ref}
        return {"artists": [n for _, n in ar], "albums": [k for _, k in al],
                "tracks": [i for _, i in tr], "top": top}
