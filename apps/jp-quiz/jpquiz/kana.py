"""Kana helpers: script detection, hiragana/katakana conversion, romaji -> kana.

The romaji converter powers the IME-free answer box: the UI sends raw
keystrokes (no input method involved) and we turn them into hiragana ourselves,
so the user's fcitx5/mozc state never matters.
"""

from __future__ import annotations

HIRA_START, HIRA_END = 0x3041, 0x3096
KATA_START, KATA_END = 0x30A1, 0x30F6


def is_hiragana(ch: str) -> bool:
    return HIRA_START <= ord(ch) <= HIRA_END or ch in "ゝゞ"


def is_katakana(ch: str) -> bool:
    return KATA_START <= ord(ch) <= KATA_END or ch in "ーヽヾ"


def is_kana(ch: str) -> bool:
    return is_hiragana(ch) or is_katakana(ch)


def is_kanji(ch: str) -> bool:
    o = ord(ch)
    return (0x4E00 <= o <= 0x9FFF) or (0x3400 <= o <= 0x4DBF) or ch in "々〆"


def has_kanji(text: str) -> bool:
    return any(is_kanji(c) for c in text)


def kata_to_hira(text: str) -> str:
    out = []
    for c in text:
        o = ord(c)
        if KATA_START <= o <= KATA_END:
            out.append(chr(o - 0x60))
        else:
            out.append(c)
    return "".join(out)


def hira_to_kata(text: str) -> str:
    out = []
    for c in text:
        o = ord(c)
        if HIRA_START <= o <= HIRA_END:
            out.append(chr(o + 0x60))
        else:
            out.append(c)
    return "".join(out)


# --- romaji -> hiragana -------------------------------------------------------

_ROMAJI = {
    "a": "あ", "i": "い", "u": "う", "e": "え", "o": "お",
    "ka": "か", "ki": "き", "ku": "く", "ke": "け", "ko": "こ",
    "ga": "が", "gi": "ぎ", "gu": "ぐ", "ge": "げ", "go": "ご",
    "sa": "さ", "si": "し", "shi": "し", "su": "す", "se": "せ", "so": "そ",
    "za": "ざ", "zi": "じ", "ji": "じ", "zu": "ず", "ze": "ぜ", "zo": "ぞ",
    "ta": "た", "ti": "ち", "chi": "ち", "tu": "つ", "tsu": "つ", "te": "て", "to": "と",
    "da": "だ", "di": "ぢ", "du": "づ", "de": "で", "do": "ど",
    "na": "な", "ni": "に", "nu": "ぬ", "ne": "ね", "no": "の",
    "ha": "は", "hi": "ひ", "hu": "ふ", "fu": "ふ", "he": "へ", "ho": "ほ",
    "ba": "ば", "bi": "び", "bu": "ぶ", "be": "べ", "bo": "ぼ",
    "pa": "ぱ", "pi": "ぴ", "pu": "ぷ", "pe": "ぺ", "po": "ぽ",
    "ma": "ま", "mi": "み", "mu": "む", "me": "め", "mo": "も",
    "ya": "や", "yu": "ゆ", "yo": "よ",
    "ra": "ら", "ri": "り", "ru": "る", "re": "れ", "ro": "ろ",
    "la": "ら", "li": "り", "lu": "る", "le": "れ", "lo": "ろ",
    "wa": "わ", "wo": "を", "we": "うぇ", "wi": "うぃ",
    "nn": "ん", "n'": "ん", "xn": "ん",
    "kya": "きゃ", "kyu": "きゅ", "kyo": "きょ",
    "gya": "ぎゃ", "gyu": "ぎゅ", "gyo": "ぎょ",
    "sha": "しゃ", "shu": "しゅ", "sho": "しょ", "she": "しぇ",
    "sya": "しゃ", "syu": "しゅ", "syo": "しょ",
    "ja": "じゃ", "ju": "じゅ", "jo": "じょ", "je": "じぇ",
    "jya": "じゃ", "jyu": "じゅ", "jyo": "じょ",
    "zya": "じゃ", "zyu": "じゅ", "zyo": "じょ",
    "cha": "ちゃ", "chu": "ちゅ", "cho": "ちょ", "che": "ちぇ",
    "tya": "ちゃ", "tyu": "ちゅ", "tyo": "ちょ",
    "cya": "ちゃ", "cyu": "ちゅ", "cyo": "ちょ",
    "dya": "ぢゃ", "dyu": "ぢゅ", "dyo": "ぢょ",
    "nya": "にゃ", "nyu": "にゅ", "nyo": "にょ",
    "hya": "ひゃ", "hyu": "ひゅ", "hyo": "ひょ",
    "bya": "びゃ", "byu": "びゅ", "byo": "びょ",
    "pya": "ぴゃ", "pyu": "ぴゅ", "pyo": "ぴょ",
    "mya": "みゃ", "myu": "みゅ", "myo": "みょ",
    "rya": "りゃ", "ryu": "りゅ", "ryo": "りょ",
    "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ",
    "thi": "てぃ", "dhi": "でぃ", "twu": "とぅ", "dwu": "どぅ",
    "va": "ゔぁ", "vi": "ゔぃ", "vu": "ゔ", "ve": "ゔぇ", "vo": "ゔぉ",
    "xa": "ぁ", "xi": "ぃ", "xu": "ぅ", "xe": "ぇ", "xo": "ぉ",
    "xya": "ゃ", "xyu": "ゅ", "xyo": "ょ", "xtu": "っ", "xtsu": "っ",
    "ltu": "っ", "lya": "ゃ", "lyu": "ゅ", "lyo": "ょ",
    "-": "ー",
}
_MAXLEN = max(len(k) for k in _ROMAJI)
_CONSONANTS = set("bcdfghjklmpqrstvwxyz")


def romaji_to_hiragana(text: str, final: bool = True) -> str:
    """Convert romaji to hiragana, IME-style.

    `final=False` keeps a dangling consonant (e.g. the "k" while typing "ka")
    as Latin so the UI can show it as pending input, and leaves a lone trailing
    "n" alone (it may still become "na"/"ni"...).
    """
    s = text.lower()
    out: list[str] = []
    i = 0
    while i < len(s):
        c = s[i]
        # double consonant -> small tsu (but "nn" is ん)
        if c in _CONSONANTS and c != "n" and i + 1 < len(s) and s[i + 1] == c:
            out.append("っ")
            i += 1
            continue
        if c == "t" and s[i:i + 3] == "tch":  # "matcha"
            out.append("っ")
            i += 1
            continue
        # n before a consonant (other than y/n) or apostrophe -> ん
        if c == "n" and i + 1 < len(s) and s[i + 1] in _CONSONANTS and s[i + 1] not in "ny":
            out.append("ん")
            i += 1
            continue
        matched = False
        for ln in range(min(_MAXLEN, len(s) - i), 0, -1):
            chunk = s[i:i + ln]
            if chunk in _ROMAJI:
                out.append(_ROMAJI[chunk])
                i += ln
                matched = True
                break
        if matched:
            continue
        if c == "n":
            if i == len(s) - 1:
                out.append("ん" if final else "n")
            else:
                out.append("ん")
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def normalize_reading(text: str) -> str:
    """Canonical form for comparing typed readings: hiragana, no spaces."""
    t = text.strip().replace(" ", "").replace("　", "")
    if any("a" <= ch.lower() <= "z" for ch in t):
        t = romaji_to_hiragana(t)
    return kata_to_hira(t)
