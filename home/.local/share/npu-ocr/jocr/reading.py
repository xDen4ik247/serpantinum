"""Readings / furigana for Japanese text (fugashi + unidic-lite).

tokens(text) -> [{surface, reading, base, lemma, pos, ruby}] where ruby is a list of
[text, furigana] segments: furigana is "" for kana/punctuation and only covers the kanji runs
(okurigana stays outside), e.g. 食べた -> [["食", "た"], ["べた", ""]].
"""
from __future__ import annotations

import re
import threading

_tagger = None
_lock = threading.Lock()

KANJI = re.compile(r"[㐀-䶿一-鿿豈-﫿々〆ヶ]")


def _get():
    global _tagger
    if _tagger is None:
        import fugashi
        _tagger = fugashi.Tagger()
    return _tagger


def kata2hira(s):
    return "".join(chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in s)


def align(surface, reading):
    """Split a token into [segment, furigana] pairs so furigana only sits over kanji runs."""
    if not reading or not KANJI.search(surface):
        return [[surface, ""]]
    # runs of kanji vs non-kanji
    runs = re.findall(r"[㐀-䶿一-鿿豈-﫿々〆ヶ]+|[^㐀-䶿一-鿿豈-﫿々〆ヶ]+", surface)
    pattern = "".join("(.+?)" if KANJI.match(r) else "(" + re.escape(kata2hira(r)) + ")" for r in runs)
    m = re.fullmatch(pattern, kata2hira(reading))
    if not m:
        return [[surface, reading]]
    out = []
    for r, g in zip(runs, m.groups()):
        out.append([r, g if KANJI.match(r) else ""])
    return out


def tokens(text):
    out = []
    with _lock:
        tag = _get()
        for line_i, line in enumerate(text.split("\n")):
            if line_i:
                out.append({"surface": "\n", "reading": "", "base": "", "lemma": "", "pos": "newline", "ruby": [["\n", ""]]})
            for w in tag(line):
                f = w.feature
                kana = getattr(f, "kana", None) or ""
                reading = kata2hira(kana) if kana and kana != "*" else ""
                base = getattr(f, "orthBase", None) or getattr(f, "lemma", None) or w.surface
                lemma = getattr(f, "lemma", None) or base
                pos = getattr(f, "pos1", None) or ""
                if w.white_space:
                    out.append({"surface": " ", "reading": "", "base": "", "lemma": "", "pos": "space", "ruby": [[" ", ""]]})
                ruby = align(w.surface, reading) if KANJI.search(w.surface) else [[w.surface, ""]]
                out.append({"surface": w.surface, "reading": reading,
                            "base": base if base != "*" else w.surface,
                            "lemma": lemma if lemma != "*" else w.surface, "pos": pos, "ruby": ruby})
    return out


def hiragana(text):
    """Whole text in hiragana (kana readings, punctuation kept)."""
    return "".join(t["reading"] or t["surface"] for t in tokens(text))
