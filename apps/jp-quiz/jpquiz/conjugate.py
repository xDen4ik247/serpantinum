"""A small, explicit Japanese conjugator (verbs, i-adjectives, na-adjectives).

Used at content-build time to make distractors: the same verb in the wrong
form (書く -> 書いた instead of 書いて) and classic learner mistakes
(書って, 行いて, 食べって ...).  It works on the *written* dictionary form,
so 来る stays in kanji and くる stays in kana.

Word classes follow JMdict codes:
  v1  ichidan        食べる 見る
  v5k v5g v5s v5t v5n v5b v5m v5r v5u   godan by ending
  v5k-s  行く (te/ta: 行って)
  v5r-i  ある (negative: ない)
  v5aru  くださる いらっしゃる なさる おっしゃる ござる (masu-stem in い)
  vk     来る / くる
  vs-i   する and Noun+する (勉強する)
  adj-i  高い     adj-ix  いい/良い (よ- stem)     adj-na  静か
"""

from __future__ import annotations

GODAN_ROWS = {
    #     a     i     u     e     o
    "う": ("わ", "い", "う", "え", "お"),
    "く": ("か", "き", "く", "け", "こ"),
    "ぐ": ("が", "ぎ", "ぐ", "げ", "ご"),
    "す": ("さ", "し", "す", "せ", "そ"),
    "つ": ("た", "ち", "つ", "て", "と"),
    "ぬ": ("な", "に", "ぬ", "ね", "の"),
    "ぶ": ("ば", "び", "ぶ", "べ", "ぼ"),
    "む": ("ま", "み", "む", "め", "も"),
    "る": ("ら", "り", "る", "れ", "ろ"),
}
CLASS_BY_ENDING = {"う": "v5u", "く": "v5k", "ぐ": "v5g", "す": "v5s", "つ": "v5t",
                   "ぬ": "v5n", "ぶ": "v5b", "む": "v5m", "る": "v5r"}
TE_TA = {  # godan ending -> (te, ta)
    "う": ("って", "った"), "つ": ("って", "った"), "る": ("って", "った"),
    "く": ("いて", "いた"), "ぐ": ("いで", "いだ"), "す": ("して", "した"),
    "ぬ": ("んで", "んだ"), "ぶ": ("んで", "んだ"), "む": ("んで", "んだ"),
}

VERB_FORMS = [
    "dict", "stem", "a_stem", "e_stem", "te", "ta", "nai", "nakatta", "nakute", "naide",
    "masu", "masen", "mashita", "masendeshita", "mashou",
    "potential", "volitional", "ba", "tara", "passive", "causative", "imperative",
]


def uni_ctype_to_class(ctype: str, lemma_base: str) -> str | None:
    """Map a UniDic conjugation type (cType) to a JMdict-style class."""
    if ctype.startswith("五段"):
        if lemma_base in ("行く", "いく", "逝く", "往く"):
            return "v5k-s"
        if lemma_base in ("ある", "有る", "在る"):
            return "v5r-i"
        if lemma_base in ("くださる", "下さる", "いらっしゃる", "なさる", "おっしゃる", "ござる", "御座る"):
            return "v5aru"
        end = lemma_base[-1:]
        return CLASS_BY_ENDING.get(end)
    if ctype.startswith("上一段") or ctype.startswith("下一段"):
        return "v1"
    if ctype.startswith("カ行変格"):
        return "vk"
    if ctype.startswith("サ行変格"):
        return "vs-i"
    if ctype == "形容詞":
        if lemma_base in ("いい", "良い", "よい"):
            return "adj-ix"
        return "adj-i"
    return None


def _godan(base: str, cls: str, form: str) -> str:
    end = base[-1]
    stem = base[:-1]
    a, i, u, e, o = GODAN_ROWS[end]
    if cls == "v5aru":
        i = "い"
    if form == "dict":
        return base
    if form == "stem":
        return stem + i
    if form == "a_stem":
        return "" if cls == "v5r-i" else stem + a
    if form == "e_stem":
        return stem + e
    if form in ("te", "ta", "tara"):
        if cls == "v5k-s":
            te, ta = "って", "った"
        else:
            te, ta = TE_TA[end]
        return stem + {"te": te, "ta": ta, "tara": ta + "ら"}[form]
    if form in ("nai", "nakatta", "nakute", "naide"):
        neg_stem = "" if cls == "v5r-i" else stem + a      # ある -> ない
        tail = {"nai": "ない", "nakatta": "なかった", "nakute": "なくて", "naide": "ないで"}[form]
        return neg_stem + tail
    if form in ("masu", "masen", "mashita", "masendeshita", "mashou"):
        tail = {"masu": "ます", "masen": "ません", "mashita": "ました",
                "masendeshita": "ませんでした", "mashou": "ましょう"}[form]
        return stem + i + tail
    if form == "potential":
        return stem + e + "る"
    if form == "volitional":
        return stem + o + "う"
    if form == "ba":
        return stem + e + "ば"
    if form == "passive":
        return stem + a + "れる"
    if form == "causative":
        return stem + a + "せる"
    if form == "imperative":
        return stem + (i if cls == "v5aru" else e)
    raise ValueError(form)


def _ichidan(base: str, form: str) -> str:
    s = base[:-1]
    return {
        "dict": base, "stem": s, "a_stem": s, "e_stem": s + "れ",
        "te": s + "て", "ta": s + "た", "tara": s + "たら",
        "nai": s + "ない", "nakatta": s + "なかった", "nakute": s + "なくて", "naide": s + "ないで",
        "masu": s + "ます", "masen": s + "ません", "mashita": s + "ました",
        "masendeshita": s + "ませんでした", "mashou": s + "ましょう",
        "potential": s + "られる", "volitional": s + "よう", "ba": s + "れば",
        "passive": s + "られる", "causative": s + "させる", "imperative": s + "ろ",
    }[form]


def _kuru(base: str, form: str) -> str:
    kanji = base.startswith("来")
    k = "来" if kanji else None
    def w(kana_stem: str, tail: str) -> str:
        return (k if kanji else kana_stem) + tail
    return {
        "dict": base, "stem": w("き", ""), "a_stem": w("こ", ""), "e_stem": (base[:-1] + "れ"),
        "te": w("き", "て"), "ta": w("き", "た"),
        "tara": w("き", "たら"), "nai": w("こ", "ない"), "nakatta": w("こ", "なかった"),
        "nakute": w("こ", "なくて"), "naide": w("こ", "ないで"),
        "masu": w("き", "ます"), "masen": w("き", "ません"), "mashita": w("き", "ました"),
        "masendeshita": w("き", "ませんでした"), "mashou": w("き", "ましょう"),
        "potential": w("こ", "られる"), "volitional": w("こ", "よう"), "ba": w("く", "れば"),
        "passive": w("こ", "られる"), "causative": w("こ", "させる"), "imperative": w("こ", "い"),
    }[form]


def _suru(base: str, form: str) -> str:
    if not base.endswith("する"):
        raise ValueError(base)
    p = base[:-2]
    return p + {
        "dict": "する", "stem": "し", "a_stem": "し", "e_stem": "すれ",
        "te": "して", "ta": "した", "tara": "したら",
        "nai": "しない", "nakatta": "しなかった", "nakute": "しなくて", "naide": "しないで",
        "masu": "します", "masen": "しません", "mashita": "しました",
        "masendeshita": "しませんでした", "mashou": "しましょう",
        "potential": "できる", "volitional": "しよう", "ba": "すれば",
        "passive": "される", "causative": "させる", "imperative": "しろ",
    }[form]


def conjugate_verb(base: str, cls: str, form: str) -> str:
    if cls == "v1":
        return _ichidan(base, form)
    if cls == "vk":
        return _kuru(base, form)
    if cls == "vs-i":
        return _suru(base, form)
    if cls.startswith("v5"):
        return _godan(base, cls, form)
    raise ValueError(f"unknown verb class {cls}")


ADJ_FORMS = ["dict", "ku", "kunai", "katta", "kunakatta", "kute", "kereba", "sou"]


def conjugate_adj(base: str, cls: str, form: str) -> str:
    if cls in ("adj-i", "adj-ix"):
        if cls == "adj-ix":
            stem = ("良" if base.startswith("良") else "よ")
        else:
            stem = base[:-1]
        return {
            "dict": base, "ku": stem + "く", "kunai": stem + "くない", "katta": stem + "かった",
            "kunakatta": stem + "くなかった", "kute": stem + "くて", "kereba": stem + "ければ",
            "sou": stem + "さそう" if cls == "adj-ix" else stem + "そう",
        }[form]
    if cls == "adj-na":
        return {
            "dict": base + "だ", "na": base + "な", "de": base + "で", "ni": base + "に",
            "janai": base + "じゃない", "datta": base + "だった", "nara": base + "なら",
            "janakatta": base + "じゃなかった",
        }[form]
    raise ValueError(cls)


# --- classic learner mistakes --------------------------------------------------

def wrong_te_ta(base: str, cls: str, which: str = "te") -> list[str]:
    """Plausible but ungrammatical te/ta forms (for 'choose the correct form')."""
    out: list[str] = []
    v = which == "ta"
    def endings(e: str) -> str:
        if not v:
            return e
        return e[:-1] + ("た" if e.endswith("て") else "だ")
    if cls.startswith("v5"):
        stem = base[:-1]
        end = base[-1]
        correct = conjugate_verb(base, cls, which)
        cands = {stem + endings(t) for t in ("って", "いて", "いで", "して", "んで")}
        cands.add(stem + GODAN_ROWS[end][1] + endings("て"))          # 書きて (masu-stem + て)
        cands.add(base + endings("て"))                                # 書くて
        if cls == "v5k-s":
            cands.add(stem + endings("いて"))                          # 行いて
        if end == "る":
            cands.add(stem + endings("て"))                            # 帰て (treated as ichidan)
        cands.discard(correct)
        out = sorted(cands)
    elif cls == "v1":
        s = base[:-1]
        correct = conjugate_verb(base, cls, which)
        cands = {s + endings("って"), s + endings("いて"), base + endings("て"), s + endings("んで")}
        cands.discard(correct)
        out = sorted(cands)
    elif cls == "vk":
        if base.startswith("来"):
            cands = {"来" + endings("って"), "来る" + endings("て"), "来" + endings("いて")}
        else:
            cands = {"き" + endings("って"), "くる" + endings("て"), "こ" + endings("て")}
        cands.discard(conjugate_verb(base, cls, which))
        out = sorted(cands)
    elif cls == "vs-i":
        p = base[:-2]
        cands = {p + "し" + endings("って"), p + "す" + endings("って"), p + "すて", p + "せて"}
        if v:
            cands = {p + "しった", p + "すった", p + "すた", p + "せた"}
        out = sorted(cands)
    return out


def wrong_adj(base: str, cls: str) -> list[str]:
    """i-adjective / na-adjective mix-ups: 大きいな, 静かい, きれいかった."""
    if cls in ("adj-i", "adj-ix"):
        return [base + "な", base + "だった", base + "じゃない", base + "かった"]
    if cls == "adj-na":
        return [base + "い", base + "かった", base + "くない", base + "くて"]
    return []


def wrong_tai(base: str, cls: str) -> list[str]:
    """食べるたい / 食べてたい-style mistakes."""
    return sorted({base + "たい", conjugate_verb(base, cls, "te") + "たい"})


if __name__ == "__main__":
    for b, c in (("書く", "v5k"), ("行く", "v5k-s"), ("泳ぐ", "v5g"), ("話す", "v5s"), ("待つ", "v5t"),
                 ("死ぬ", "v5n"), ("遊ぶ", "v5b"), ("読む", "v5m"), ("帰る", "v5r"), ("買う", "v5u"),
                 ("ある", "v5r-i"), ("くださる", "v5aru"), ("食べる", "v1"), ("来る", "vk"), ("くる", "vk"),
                 ("勉強する", "vs-i")):
        print(b, [conjugate_verb(b, c, f) for f in VERB_FORMS])
        print("   wrong te:", wrong_te_ta(b, c))
    print(conjugate_adj("高い", "adj-i", "katta"), conjugate_adj("いい", "adj-ix", "kunai"),
          conjugate_adj("静か", "adj-na", "na"))
