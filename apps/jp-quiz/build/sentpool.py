"""Level every corpus sentence (N5/N4/N3) and prepare display segments with furigana."""

from __future__ import annotations

from dataclasses import dataclass, field

from jpquiz.kana import is_kanji, is_katakana, is_kana, kata_to_hira

FUNC_P1 = {"助詞", "助動詞", "補助記号", "記号", "空白"}
AUX_LEMMAS = {"居る", "有る", "為る", "成る", "仕舞う", "置く", "見る", "行く", "来る", "上げる", "呉れる",
              "貰う", "下さる", "頂く", "無い", "良い", "知れる", "御座る", "出来る", "過ぎる", "易い", "難い",
              "欲しい", "為さる", "様", "そう-様態", "そう-伝聞", "事", "物", "方", "筈", "積り", "為", "所", "訳"}
PLACE_OK = {"日本", "東京", "京都", "大阪", "中国", "韓国", "英国", "北海道", "九州", "富士", "横浜", "名古屋", "奈良",
            "神戸", "沖縄", "広島", "札幌", "福岡"}
NAMES_HEAVY = ("トム", "メアリー", "メアリ", "ジョン", "ボブ", "ケン", "ジム")


@dataclass
class PoolSentence:
    s: object                 # corpus.Sentence
    level: int                # 5..3
    tok_levels: list[int]
    kanji_level: int
    names: bool = False
    extra: dict = field(default_factory=dict)


def word_level(lx, t) -> int:
    """JLPT level of a token: 5 (N5) .. 1 (N1); 0 = unknown/rare."""
    if t.p1 in FUNC_P1:
        return 5
    if t.p1 == "接尾辞" or t.p1 == "接頭辞":
        ks = [lx.kanji_level(c) or 0 for c in t.s if is_kanji(c)]
        return min(ks) if ks else 5
    if t.p2 == "数詞":
        return 5
    if t.l in AUX_LEMMAS and t.p2 in ("非自立可能", "助動詞語幹"):
        return 5
    if t.p2 == "固有名詞":
        if all(is_katakana(c) for c in t.s):
            return 5
        if t.s in PLACE_OK:
            return 4
        return 0
    base, rb = t.b, t.rb
    lv = lx.word_level(base, rb) or lx.word_level(t.s, t.r)
    if not lv:
        lemma = t.l.split("-")[0]
        lv = lx.word_level(lemma, rb)
    if not lv and all(is_katakana(c) for c in t.s) and len(t.s) >= 2:
        # common loanwords: accept when JMdict marks them as frequent
        lv = 4 if _freq_rank(lx, t.s) <= 12 else 0
    if not lv:
        r = _freq_rank(lx, base)
        if r <= 10:
            lv = 3
    return lv or 0


def _freq_rank(lx, form: str) -> int:
    best = 99
    for seq in lx.form_entries.get(form, [])[:6]:
        e = lx.jmdict.get(seq)
        if e:
            best = min(best, e.priority)
    return best


def kanji_level(lx, text: str) -> int:
    lv = 5
    for c in text:
        if is_kanji(c):
            k = lx.kanji_level(c)
            if not k:
                return 0
            lv = min(lv, k)
    return lv


MAXLEN = {5: 24, 4: 30, 3: 34}
DOUBLED = __import__("re").compile(r"(にに|をを|がが|でで|へへ|とと(?!も))")


def build_pool(lx, sents) -> list[PoolSentence]:
    out = []
    for s in sents:
        if any(t.p2 in ("句点",) and t.s in ("。", "？", "！") for t in s.toks[:-1]):
            continue  # one sentence only
        lvls = [word_level(lx, t) for t in s.toks]
        wl = min(lvls) if lvls else 0
        kl = kanji_level(lx, s.ja)
        lv = min(wl, kl)
        if lv < 3:
            continue
        if len(s.ja) > MAXLEN[lv]:
            continue
        if "(" in s.en or "[" in s.en or len(s.en) > 100:
            continue
        if DOUBLED.search(s.ja):
            continue
        names = any(n in s.ja for n in NAMES_HEAVY)
        out.append(PoolSentence(s, lv, lvls, kl, names))
    return out


# --------------------------------------------------------------------------
# Display segments: [{"t": "食", "r": "た"}, {"t": "べます"}]
# --------------------------------------------------------------------------

def ruby_split(surface: str, reading: str) -> list[dict]:
    """Align a token's reading to its kanji part (strip shared kana prefix/suffix)."""
    if not any(is_kanji(c) for c in surface) or not reading:
        return [{"t": surface}]
    r = kata_to_hira(reading)
    s = surface
    pre = ""
    while s and r and is_kana(s[0]) and kata_to_hira(s[0]) == r[0]:
        pre += s[0]
        s, r = s[1:], r[1:]
    post = ""
    while s and r and is_kana(s[-1]) and kata_to_hira(s[-1]) == r[-1]:
        post = s[-1] + post
        s, r = s[:-1], r[:-1]
    segs = []
    if pre:
        segs.append({"t": pre})
    if s:
        # mixed kanji+kana inside (e.g. 取り扱い) - keep a single ruby over the block
        segs.append({"t": s, "r": r} if r else {"t": s})
    if post:
        segs.append({"t": post})
    return segs


def segments(toks, a: int = 0, b: int | None = None) -> list[dict]:
    b = len(toks) if b is None else b
    out = []
    for t in toks[a:b]:
        reading = t.r if t.p1 not in FUNC_P1 else ""
        if t.p1 == "補助記号" or not any(is_kanji(c) for c in t.s):
            out.append({"t": t.s})
        else:
            out.extend(ruby_split(t.s, reading))
    # merge adjacent plain-text segments
    merged = []
    for seg in out:
        if merged and "r" not in seg and "r" not in merged[-1] and "blank" not in merged[-1] and "hl" not in merged[-1]:
            merged[-1] = {"t": merged[-1]["t"] + seg["t"]}
        else:
            merged.append(dict(seg))
    return merged


def sentence_with(toks, span: tuple | None, marker: str, extra: dict | None = None) -> list[dict]:
    """Segments with toks[span] replaced by a marker segment ("blank" or "hl")."""
    if span is None:
        return segments(toks)
    a, b = span
    seg = {marker: True}
    if extra:
        seg.update(extra)
    return segments(toks, 0, a) + [seg] + segments(toks, b)
