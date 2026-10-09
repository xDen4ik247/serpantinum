"""Item generators.

Every generator yields plain dicts:
  key    stable id ("pt:4703:3")
  kind   particle | conj | gmean | voice | form | order | odd | kread | kwrite | vocab | meaning | produce
  level  5 (N5) .. 3 (N3)
  kc     spaced-repetition card the item reviews (e.g. "pt:に:time", "gp:te-mo-ii", "read:時間")
  tags   skill tags that get their own ratings ("pt:に", "gp:tara", "k:時", "w:食べる")
  cat    particles | grammar | kanji | vocab | reading
  seed   initial difficulty in logits (calibrated later from answers)
  payload  what the UI renders (choices[0] is the correct answer; the server shuffles)
"""

from __future__ import annotations

import math
import random
import re
from collections import Counter, defaultdict

from jpquiz.conjugate import (conjugate_verb, conjugate_adj, wrong_te_ta, VERB_FORMS)
from jpquiz.kana import is_kanji, kata_to_hira, is_kana, is_hiragana
from build.grammar import (GP_BY_ID, GPS, detect, verb_units, voice_of, keyword_ok, never_contrast,
                           _is_te, _pred_end, Unit)
from build.sentpool import segments, sentence_with, FUNC_P1

LEVEL_BASE = {5: -1.0, 4: 0.0, 3: 1.0}
KIND_OFF = {"particle": 0.0, "conj": 0.0, "gmean": 0.3, "form": -0.6, "voice": 0.4, "order": -0.2,
            "odd": 0.4, "kread": -0.2, "kwrite": 0.1, "vocab": 0.0, "meaning": -0.3, "produce": 0.0}


def seed(level: int, kind: str, extra: float = 0.0, length: int = 14) -> float:
    return round(LEVEL_BASE[level] + KIND_OFF[kind] + extra + 0.02 * max(0, length - 14), 3)


def tr(ps) -> dict:
    s = ps.s
    d = {"en": s.en}
    if s.ru:
        d["ru"] = s.ru
    return d


def src(ps) -> dict:
    s = ps.s
    d = {"ja": s.id, "en": s.en_id}
    if s.ru_id:
        d["ru"] = s.ru_id
    return d


def surf(toks, a, b) -> str:
    return "".join(t.s for t in toks[a:b])


# ===========================================================================
# Real-word check for malformed distractors
# ===========================================================================

class RealForms:
    """Every JMdict headword plus te/ta/masu forms of every JMdict verb."""

    def __init__(self, lx):
        self.forms = set(lx.all_forms)
        cls_map = {"v1": "v1", "v5k": "v5k", "v5g": "v5g", "v5s": "v5s", "v5t": "v5t", "v5n": "v5n",
                   "v5b": "v5b", "v5m": "v5m", "v5r": "v5r", "v5u": "v5u", "v5k-s": "v5k-s", "vk": "vk",
                   "v5r-i": "v5r-i", "v5aru": "v5aru"}
        for e in lx.jmdict.values():
            pos = e.pos_set()
            classes = [cls_map[p] for p in pos if p in cls_map]
            if not classes:
                continue
            for w in e.kanji + e.readings:
                for c in classes:
                    try:
                        for f in ("te", "ta", "stem", "nai", "ba", "volitional", "potential"):
                            self.forms.add(conjugate_verb(w, c, f))
                    except (KeyError, ValueError, IndexError):
                        pass

    def __contains__(self, s: str) -> bool:
        return s in self.forms


# ===========================================================================
# Particles
# ===========================================================================

PARTS = ["は", "が", "を", "に", "で", "へ", "と", "も", "から", "まで", "より", "の", "や", "しか", "だけ"]
CONF = {
    "は": ["が", "を", "も", "に", "で", "の"],
    "が": ["は", "を", "に", "で", "も", "の"],
    "を": ["が", "に", "で", "は", "と"],
    "に": ["で", "を", "へ", "と", "が", "から"],
    "で": ["に", "を", "が", "から", "と"],
    "へ": ["で", "を", "が", "と", "から"],
    "と": ["に", "で", "を", "が", "や", "も"],
    "も": ["は", "が", "を", "に", "と"],
    "から": ["まで", "で", "を", "に", "より"],
    "まで": ["から", "で", "を", "に", "へ"],
    "より": ["から", "と", "で", "に", "まで"],
    "の": ["が", "を", "に", "と", "で"],
    "や": ["と", "も", "を", "に", "の"],
    "しか": ["だけ", "も", "を", "まで", "は"],
    "だけ": ["しか", "も", "を", "まで"],
}
NEVER_P = {frozenset(x) for x in [("に", "へ"), ("と", "や"), ("から", "より"), ("へ", "まで"), ("に", "まで"),
                                  ("しか", "だけ"), ("の", "が"), ("に", "と"), ("を", "から"), ("で", "から")]}
QWORDS = {"誰", "何", "どこ", "どれ", "いつ", "どちら", "どっち", "どの", "どんな", "何処", "何時"}
STATIVE = {"好き", "嫌い", "上手", "下手", "欲しい", "分かる", "出来る", "要る", "見える", "聞こえる", "得意", "苦手",
           "大好き", "大嫌い", "必要"}
MOTION_TO = {"行く", "来る", "帰る", "着く", "入る", "乗る", "戻る", "向かう", "出掛ける", "登る", "上る", "届く", "移る",
             "引っ越す", "近づく", "寄る", "参る", "伺う", "到着"}
EXIST = {"有る", "居る", "住む", "置く", "座る", "泊まる", "勤める", "残る", "並ぶ", "立つ", "掛ける", "生まれる", "住む"}
RECIP = {"上げる", "呉れる", "貰う", "教える", "貸す", "借りる", "言う", "見せる", "送る", "答える", "頼む", "会う",
         "電話", "渡す", "聞く", "尋ねる", "話す", "書く", "出す", "知らせる", "返す", "売る", "習う"}
PATH = {"歩く", "渡る", "通る", "散歩", "走る", "飛ぶ", "曲がる", "泳ぐ", "進む", "越える", "下る"}
LEAVE = {"出る", "降りる", "卒業", "離れる", "出発"}
MEANS = {"バス", "電車", "車", "自転車", "飛行機", "船", "地下鉄", "タクシー", "ペン", "鉛筆", "箸", "はし", "日本語", "英語",
         "手", "電話", "メール", "ナイフ", "足", "徒歩", "新幹線", "フランス語", "中国語", "ドイツ語", "スペイン語", "声", "名前",
         "インターネット", "テレビ", "ラジオ", "カード", "現金", "鉛筆", "ボールペン", "言葉", "一人", "二人", "みんな", "皆"}
TIME_N = {"時", "日", "曜日", "月", "年", "朝", "夜", "晩", "昼", "夕方", "時間", "分", "週末", "誕生日", "春", "夏", "秋",
          "冬", "午前", "午後", "頃", "前", "後", "時代", "今度", "最後", "初め", "休み"}
WITH = {"一緒", "会う", "話す", "結婚", "遊ぶ", "喧嘩", "違う", "同じ", "似る", "別れる", "相談", "付き合う", "踊る", "握手"}
QUOTE = {"言う", "思う", "聞く", "考える", "書く", "答える", "呼ぶ", "叫ぶ", "信じる", "感じる", "決める"}
ALSO_RE = re.compile(r"\b(too|also|either|even|both|neither|nor|as well)\b", re.I)

USAGE_EXPLAIN = {
    ("に", "time"): ("に marks a specific point in time (7時に, 日曜日に).", "に отмечает точное время (7時に, 日曜日に)."),
    ("に", "dest"): ("に marks the destination of movement (学校に行く).", "に — пункт назначения движения (学校に行く)."),
    ("に", "exist"): ("に marks where something exists or stays (部屋にいる, 東京に住む).", "に — место нахождения (部屋にいる, 東京に住む)."),
    ("に", "recip"): ("に marks the person on the receiving end (友達にあげる, 先生に聞く).", "に — адресат действия (友達にあげる)."),
    ("に", "become"): ("に marks the result of a change (医者になる).", "に — результат изменения (医者になる)."),
    ("に", "gen"): ("に marks a target point: time, destination, location of existence or recipient.", "に — целевая точка: время, направление, место нахождения или адресат."),
    ("で", "means"): ("で marks the means or tool (バスで, 日本語で).", "で — средство или инструмент (バスで, 日本語で)."),
    ("で", "place"): ("で marks where an action happens (図書館で勉強する).", "で — место действия (図書館で勉強する)."),
    ("で", "scope"): ("で limits the scope (クラスで一番).", "で — рамки сравнения (クラスで一番)."),
    ("で", "gen"): ("で marks where an action happens or by what means.", "で — место действия или средство."),
    ("を", "path"): ("を marks the space moved through (道を渡る, 公園を歩く).", "を — пространство, через которое движутся (道を渡る)."),
    ("を", "leave"): ("を marks the place you leave (部屋を出る, バスを降りる).", "を — место, которое покидают (部屋を出る)."),
    ("を", "gen"): ("を marks the direct object of an action.", "を — прямое дополнение."),
    ("が", "stative"): ("が marks the object of likes, skills, wants and abilities (猫が好き, 日本語が分かる).", "が — объект с 好き, 上手, 欲しい, 分かる, できる."),
    ("が", "qword"): ("After question words (誰, 何, どこ…) the subject takes が, never は.", "После вопросительных слов (誰, 何…) подлежащее с が, а не は."),
    ("が", "relcl"): ("Inside a clause that modifies a noun, the subject takes が (母が作った料理).", "В определительном придаточном подлежащее — с が (母が作った料理)."),
    ("が", "exist"): ("が marks what exists with ある/いる (猫がいる).", "が — то, что существует (猫がいる)."),
    ("が", "gen"): ("が marks the subject, often new or focused information.", "が — подлежащее, часто новая информация."),
    ("は", "gen"): ("は marks the topic: 'as for X…'.", "は — тема высказывания: «что касается X…»."),
    ("は", "contrast"): ("は after another particle adds contrast (日本では…).", "は после другой частицы — противопоставление (日本では…)."),
    ("と", "with"): ("と means 'together with' a partner (友達と話す).", "と — «вместе с» (友達と話す)."),
    ("と", "and"): ("と joins nouns into a complete list: 'A and B'.", "と соединяет существительные: «A и B» (полный список)."),
    ("と", "quote"): ("と marks a quotation or thought (と言う, と思う).", "と — цитата или мысль (と言う, と思う)."),
    ("と", "gen"): ("と means 'and' (between nouns) or 'with'.", "と — «и» (между существительными) или «с»."),
    ("も", "gen"): ("も means 'also, too' (and with a negative: 'not … either').", "も — «тоже, также» (с отрицанием — «тоже не»)."),
    ("へ", "gen"): ("へ marks a direction: 'toward'.", "へ — направление: «в сторону, к»."),
    ("から", "gen"): ("から marks a starting point: 'from'.", "から — начальная точка: «от, из, с»."),
    ("まで", "gen"): ("まで marks an end point: 'until / as far as'.", "まで — конечная точка: «до»."),
    ("より", "gen"): ("より marks the thing compared against: 'than'.", "より — объект сравнения: «чем»."),
    ("の", "gen"): ("の links nouns: possession or description (私の本).", "の связывает существительные: принадлежность (私の本)."),
    ("や", "gen"): ("や lists examples: 'A, B and so on'.", "や — перечисление примеров: «A, B и т. п.»."),
    ("しか", "gen"): ("しか + negative verb = 'only, nothing but'.", "しか + отрицание = «только, лишь»."),
    ("だけ", "gen"): ("だけ means 'only, just' (with any verb form).", "だけ — «только» (с любой формой глагола)."),
}


def _feat(toks, i):
    t = toks[i]
    p = toks[i - 1] if i > 0 else None
    n = toks[i + 1] if i + 1 < len(toks) else None
    gov = None
    for j in range(i + 1, min(len(toks), i + 9)):
        if toks[j].p1 in ("動詞", "形容詞", "形状詞") or (toks[j].p1 == "名詞" and toks[j].p3 == "サ変可能" and j + 1 < len(toks) and toks[j + 1].l == "為る"):
            gov = toks[j].l
            break
        if toks[j].p1 == "補助記号":
            break
    fp = ("P", p.l if p and p.p1 not in ("動詞", "形容詞", "助動詞") else (p.p1 + (p.cf.split("-")[0] if p and p.cf != "*" else "") if p else "^"))
    fpp = ("PP", (p.p1 + "/" + p.p2) if p else "^")
    fn = ("N", n.l if n and n.p1 not in ("補助記号",) else "$")
    fg = ("G", gov or "-")
    return [fp, fpp, fn, fg], gov


def particle_slot_ok(toks, i) -> bool:
    t = toks[i]
    if t.p1 != "助詞" or t.s not in PARTS:
        return False
    if t.p2 not in ("格助詞", "係助詞", "副助詞"):
        return False
    if i == 0 or i + 1 >= len(toks):
        return False
    p, n = toks[i - 1], toks[i + 1]
    if p.p1 in ("助詞", "補助記号") or n.p1 == "助詞":
        return False
    if n.p1 == "補助記号" and n.s in ("。", "？", "！"):
        return False
    if t.s == "の" and p.p1 in ("動詞", "形容詞", "助動詞"):
        return False   # nominalizer の
    if t.s == "か":
        return False
    return True


class ParticleModel:
    def __init__(self, sents):
        self.c = Counter()
        self.cf = Counter()
        self.cq = Counter()
        self.vals = defaultdict(set)
        for s in sents:
            toks = s.toks
            for i, t in enumerate(toks):
                if particle_slot_ok(toks, i):
                    feats, _ = _feat(toks, i)
                    self.cq[t.s] += 1
                    for f in feats:
                        self.c[(f, t.s)] += 1
                        self.vals[f[0]].add(f[1])
        self.total = sum(self.cq.values())

    def posterior(self, feats, actual: str) -> dict:
        logs = {}
        for q in PARTS:
            cq = self.cq[q] - (1 if q == actual else 0)
            if cq <= 0:
                continue
            lp = math.log(cq / self.total)
            for f in feats:
                cfq = self.c[(f, q)] - (1 if q == actual else 0)
                v = len(self.vals[f[0]]) + 1
                lp += math.log((cfq + 0.3) / (cq + 0.3 * v))
            logs[q] = lp
        m = max(logs.values())
        z = sum(math.exp(x - m) for x in logs.values())
        return {q: math.exp(x - m) / z for q, x in logs.items()}


def particle_usage(toks, i, gov) -> str:
    q = toks[i].s
    p = toks[i - 1]
    g = gov or ""
    if q == "に":
        if p.l in TIME_N or p.p2 == "数詞" or (p.p1 == "接尾辞" and p.l in TIME_N):
            return "time"
        if g in MOTION_TO:
            return "dest"
        if g in EXIST:
            return "exist"
        if g in RECIP:
            return "recip"
        if g == "成る":
            return "become"
        return "gen"
    if q == "で":
        if p.l in MEANS or p.s in MEANS:
            return "means"
        if toks[i + 1].l in ("一番",):
            return "scope"
        if g and g not in EXIST:
            return "place"
        return "gen"
    if q == "を":
        if g in PATH:
            return "path"
        if g in LEAVE:
            return "leave"
        return "gen"
    if q == "が":
        if p.l in QWORDS or p.s in QWORDS:
            return "qword"
        if g in STATIVE:
            return "stative"
        if _in_relative_clause(toks, i):
            return "relcl"
        if g in ("有る", "居る"):
            return "exist"
        return "gen"
    if q == "は":
        return "gen"
    if q == "と":
        if g in WITH:
            return "with"
        if g in QUOTE and (p.p1 in ("補助記号",) or p.s.endswith("」")):
            return "quote"
        nx = toks[i + 1]
        if nx.p1 in ("名詞", "代名詞") and p.p1 in ("名詞", "代名詞"):
            return "and"
        return "gen"
    return "gen"


def _in_relative_clause(toks, i) -> bool:
    """が followed by a predicate in attributive form directly modifying a noun."""
    for j in range(i + 1, min(len(toks) - 1, i + 7)):
        t = toks[j]
        if t.p1 == "補助記号" or (t.p1 == "助詞" and t.s in ("は", "が", "を", "に", "で", "と", "も")):
            return False
        if t.p1 in ("動詞", "形容詞", "助動詞") and t.cf.startswith("連体形"):
            nx = toks[j + 1]
            if nx.p1 in ("名詞", "代名詞") and nx.l not in ("の", "事", "様", "筈", "積り", "為", "方", "所"):
                return True
    return False


def gen_particles(pool, model: ParticleModel, rng: random.Random):
    for ps in pool:
        toks = ps.s.toks
        slots = [i for i in range(len(toks)) if particle_slot_ok(toks, i)]
        rng.shuffle(slots)
        made = 0
        for i in slots:
            if made >= 2:
                break
            q = toks[i].s
            feats, gov = _feat(toks, i)
            post = model.posterior(feats, q)
            if post.get(q, 0) < 0.5:
                continue
            usage = particle_usage(toks, i, gov)
            cands = []
            for d in CONF[q]:
                if frozenset((q, d)) in NEVER_P:
                    continue
                if {q, d} == {"は", "が"} and not (q == "が" and usage in ("qword", "relcl")):
                    continue
                if {q, d} == {"を", "が"} and (gov in STATIVE or any(t.l in ("たい",) for t in toks) or any(
                        u.potential for u in verb_units(toks).values())):
                    continue
                if {q, d} == {"を", "で"} and gov in PATH:
                    continue
                if d == "も" and q != "も" and ALSO_RE.search(ps.s.en):
                    continue
                if q == "も" and not ALSO_RE.search(ps.s.en):
                    cands = []
                    break
                if post.get(d, 0) > 0.03:
                    continue
                cands.append(d)
            if len(cands) < 3:
                continue
            # prefer the classic confusions first (list order), with a little randomness
            ds = cands[:2] + rng.sample(cands[2:], 1) if len(cands) > 3 else cands[:3]
            ex_en, ex_ru = USAGE_EXPLAIN.get((q, usage), USAGE_EXPLAIN[(q, "gen")])
            item = {
                "key": f"pt:{ps.s.id}:{i}", "kind": "particle", "level": ps.level,
                "kc": f"pt:{q}:{usage}", "tags": [f"pt:{q}"], "cat": "particles",
                "seed": seed(ps.level, "particle", P_OFF.get(q, 0) + U_OFF.get(usage, 0), len(ps.s.ja)),
                "sid": ps.s.id, "names": ps.names,
                "payload": {
                    "sent": sentence_with(toks, (i, i + 1), "blank"),
                    **tr(ps), "choices": [q] + ds,
                    "explain": ex_en, "explain_ru": ex_ru,
                    "usage": usage, "full": ps.s.ja, "src": src(ps),
                },
            }
            made += 1
            yield item


P_OFF = {"は": -0.2, "が": 0.0, "を": -0.3, "の": -0.3, "に": 0.1, "で": 0.1, "と": 0.0, "も": -0.2, "へ": 0.0,
         "から": -0.1, "まで": -0.1, "より": 0.2, "や": 0.1, "しか": 0.2, "だけ": 0.1}
U_OFF = {"relcl": 0.4, "qword": 0.2, "stative": 0.3, "path": 0.4, "leave": 0.3, "recip": 0.2, "scope": 0.3,
         "become": 0.0, "time": -0.2, "means": 0.0}


# ===========================================================================
# Conjugation ("choose the correct form")
# ===========================================================================

TE_RULE = {
    "v5k": ("く → いて / いた", "く → いて / いた"), "v5g": ("ぐ → いで / いだ", "ぐ → いで / いだ"),
    "v5s": ("す → して / した", "す → して / した"), "v5t": ("つ → って / った", "つ → って / った"),
    "v5r": ("る (godan) → って / った", "る (годан) → って / った"), "v5u": ("う → って / った", "う → って / った"),
    "v5n": ("ぬ → んで / んだ", "ぬ → んで / んだ"), "v5b": ("ぶ → んで / んだ", "ぶ → んで / んだ"),
    "v5m": ("む → んで / んだ", "む → んで / んだ"), "v5k-s": ("行く is irregular: 行って / 行った", "行く — исключение: 行って / 行った"),
    "v1": ("ichidan: drop る, add て / た", "итидан: る → て / た"), "vk": ("来る → 来て (きて) / 来た", "来る → 来て (きて) / 来た"),
    "vs-i": ("する → して / した", "する → して / した"), "v5r-i": ("ある → あって / あった", "ある → あって / あった"),
    "v5aru": ("くださる → くださって", "くださる → くださって"),
}
FORM_NAME = {"te": "te-form", "ta": "ta-form", "dict": "dictionary form", "stem": "masu-stem", "a_stem": "nai-stem",
             "e_stem": "ba-stem", "volitional": "volitional form", "nai": "nai-form", "naide": "〜ないで",
             "nakute": "〜なくて", "masu": "masu-form"}
FORM_NAME_RU = {"te": "て-форма", "ta": "た-форма", "dict": "словарная форма", "stem": "основа на -и",
                "a_stem": "основа на -а (ない)", "e_stem": "основа на -э (ば)", "volitional": "волевая форма",
                "nai": "ない-форма", "naide": "〜ないで", "nakute": "〜なくて", "masu": "форма на ます"}


def conj_class_tag(cls: str) -> str:
    return "conj:" + {"v5k-s": "v5k", "v5r-i": "v5r", "v5aru": "v5r"}.get(cls, cls)


def _form(base, cls, f):
    if f == "naide":
        return conjugate_verb(base, cls, "nai") + "で"
    if f == "nakute":
        return conjugate_verb(base, cls, "nakute")
    return conjugate_verb(base, cls, f)


DISTRACT_ORDER = {
    "te": ["#bad", "#bad", "ta", "stem", "dict"],
    "ta": ["#bad", "#bad", "te", "dict", "stem"],
    "stem": ["dict", "te", "ta", "a_stem", "e_stem", "volitional"],
    "dict": ["te", "stem", "ta", "volitional", "masu"],
    "a_stem": ["stem", "dict", "e_stem", "te"],
    "e_stem": ["dict", "stem", "a_stem", "ta"],
    "volitional": ["te", "stem", "e_stem", "#volbad"],
    "naide": ["#naite", "nakute", "#dictde", "te"],
    "nakute": ["#naikute", "nai", "#dictkute", "naide"],
}


def conj_distractors(base, cls, slot_form, exclude, real: RealForms, rng):
    correct = _form(base, cls, slot_form)
    out = []
    bad_te = [w for w in wrong_te_ta(base, cls, "te" if slot_form != "ta" else "ta") if w not in real and w != correct]
    rng.shuffle(bad_te)
    for f in DISTRACT_ORDER[slot_form]:
        if len(out) >= 3:
            break
        if f == "#bad":
            if bad_te:
                out.append(bad_te.pop())
            continue
        if f == "#naite":
            s = conjugate_verb(base, cls, "nai") + "て"
        elif f == "#naikute":
            s = conjugate_verb(base, cls, "nai") + "くて"
        elif f == "#dictde":
            s = base + "で"
        elif f == "#dictkute":
            s = base + "くて"
        elif f == "#volbad":
            s = conjugate_verb(base, cls, "e_stem") + "よう"
            if s in real:
                continue
        else:
            if f in exclude:
                continue
            try:
                s = _form(base, cls, f)
            except (KeyError, ValueError):
                continue
        if s and s != correct and s not in out:
            out.append(s)
    if len(out) < 3:
        for f in ("dict", "stem", "te", "ta", "nai", "volitional"):
            if len(out) >= 3:
                break
            if f in exclude or f == slot_form:
                continue
            s = _form(base, cls, f)
            if s != correct and s not in out:
                out.append(s)
    return correct, out[:3]


def gen_conj(pool, real: RealForms, rng):
    for ps in pool:
        toks = ps.s.toks
        for m in detect(toks):
            g = GP_BY_ID[m.gp]
            if not g.slot_form or m.slot is None or m.unit.pos != "v":
                continue
            u = m.unit
            if u.cls in ("v5aru",) or u.potential:
                continue
            a, b = m.slot
            slot_surface = surf(toks, a, b)
            try:
                correct, ds = conj_distractors(u.base, u.cls, g.slot_form, g.exclude, real, rng)
            except (KeyError, ValueError, IndexError):
                continue
            if correct != slot_surface or len(ds) < 3:
                continue
            lv = min(ps.level, g.level)
            rule_en, rule_ru = TE_RULE.get(u.cls, ("", ""))
            fn, fnr = FORM_NAME[g.slot_form], FORM_NAME_RU[g.slot_form]
            ex_en = f"{g.name} needs the {fn}: {u.base} → {correct}. " + (f"Rule: {rule_en}." if g.slot_form in ("te", "ta") else g.explain_en)
            ex_ru = f"{g.name} требует: {fnr}: {u.base} → {correct}. " + (f"Правило: {rule_ru}." if g.slot_form in ("te", "ta") else g.explain_ru)
            yield {
                "key": f"cj:{ps.s.id}:{a}", "kind": "conj", "level": lv,
                "kc": f"gp:{g.id}", "tags": [f"gp:{g.id}", conj_class_tag(u.cls)], "cat": "grammar",
                "seed": seed(lv, "conj", g.diff + (0.25 if g.slot_form in ("te", "ta") and u.cls.startswith("v5") else 0.0), len(ps.s.ja)),
                "sid": ps.s.id, "names": ps.names,
                "payload": {
                    "sent": sentence_with(toks, (a, b), "blank", {"hint": u.base}),
                    **tr(ps), "choices": [correct] + ds, "dict": u.base,
                    "gp": g.id, "gp_name": g.name, "explain": ex_en, "explain_ru": ex_ru,
                    "full": ps.s.ja, "src": src(ps),
                },
            }
            break   # one conj item per sentence


# ===========================================================================
# Meaning-contrast grammar ("pick the ending that matches the translation")
# ===========================================================================

def modal_form(gid, base, cls, polite):
    c = lambda f: conjugate_verb(base, cls, f)
    P = polite
    return {
        "tai": c("stem") + ("たいです" if P else "たい"),
        "nakereba": c("a_stem") + ("なければなりません" if P else "なければならない"),
        "te-mo-ii": c("te") + ("もいいです" if P else "もいい"),
        "te-wa-ikenai": c("te") + ("はいけません" if P else "はいけない"),
        "hou-ga-ii": c("ta") + ("ほうがいいです" if P else "ほうがいい"),
        "tsumori": c("dict") + ("つもりです" if P else "つもりだ"),
        "kamoshirenai": c("dict") + ("かもしれません" if P else "かもしれない"),
    }[gid]


def conn_form(gid, base, cls, past):
    c = lambda f: conjugate_verb(base, cls, f)
    plain = c("ta") if past else c("dict")
    return {
        "tara": c("tara"), "ba": c("ba"), "to-cond": c("dict") + "と", "temo": c("te") + "も",
        "kara-reason": plain + "から", "node": plain + "ので", "noni": plain + "のに", "kedo": plain + "けど",
        "nagara": c("stem") + "ながら", "mae-ni": c("dict") + "前に", "te-kara": c("te") + "から",
        "ato-de": c("ta") + "後で",
    }[gid]


def sou_form(gid, base, cls, polite):
    c = lambda f: conjugate_verb(base, cls, f)
    end = "そうです" if polite else "そうだ"
    return {"sou-looks": c("stem") + end, "sou-hearsay": c("dict") + end,
            "sou-hearsay-past": c("ta") + end,
            "kamoshirenai": c("dict") + ("かもしれません" if polite else "かもしれない")}[gid]


ASPECT_AUX = {"te-miru": ("みる", "v1"), "te-oku": ("おく", "v5k"), "te-shimau": ("しまう", "v5u"),
              "te-give": ("あげる", "v1")}
ASPECT_KW = {"te-shimau": r"\b(accidentally|ended up|end up|by mistake|completely)\b",
             "te-give": r"\bfor (you|him|her|them|someone|somebody|me|us)\b"}


def aspect_form(gid, base, cls, tense, polite):
    aux, acls = ASPECT_AUX[gid]
    f = {("nonpast", False): "dict", ("past", False): "ta", ("nonpast", True): "masu", ("past", True): "mashita"}[(tense, polite)]
    return conjugate_verb(base, cls, "te") + conjugate_verb(aux, acls, f)


MODAL = ["tai", "nakereba", "te-mo-ii", "te-wa-ikenai", "hou-ga-ii", "tsumori", "kamoshirenai"]
CONN = ["tara", "ba", "to-cond", "temo", "kara-reason", "node", "noni", "kedo", "nagara", "mae-ni", "te-kara", "ato-de"]
SOU_ALTS = {"sou-looks": ["sou-hearsay", "sou-hearsay-past", "kamoshirenai"],
            "sou-hearsay": ["sou-looks", "kamoshirenai"]}
EXTRA_KW = {"sou-hearsay-past": GP_BY_ID["sou-hearsay"].kw}


def _kw_ok(en, target_kw, alt_ids, extra=None):
    if not target_kw or not re.search(target_kw, en, re.I):
        return False
    for a in alt_ids:
        kw = (extra or {}).get(a) or (GP_BY_ID[a].kw if a in GP_BY_ID else None) or ASPECT_KW.get(a)
        if kw and re.search(kw, en, re.I):
            return False
    return True


def gen_gmean(pool, rng):
    for ps in pool:
        toks = ps.s.toks
        en = ps.s.en
        made = False
        for m in detect(toks):
            if made:
                break
            g = GP_BY_ID[m.gp]
            u = m.unit
            if u.pos != "v" or u.cls in ("v5aru", "v5r-i") or u.potential:
                continue
            fam = g.family
            if fam == "MODAL":
                end = m.slot[1] if m.slot else None
                if end is None:
                    continue
                span = None
                for k in range(end, min(len(toks), end + 7) + 1):
                    if _pred_end(toks, k) is not None:
                        span = (u.start, k)
                        break
                if span is None:
                    continue
                chunk = surf(toks, *span)
                try:
                    polite = next((p for p in (True, False) if modal_form(g.id, u.base, u.cls, p) == chunk), None)
                except (KeyError, ValueError):
                    continue
                if polite is None:
                    continue
                alts = [x for x in MODAL if x != g.id and not never_contrast(x, g.id)]
                rng.shuffle(alts)
                alts = [x for x in alts if _kw_ok(en, g.kw, [x])][:3]
                if len(alts) < 3 or not _kw_ok(en, g.kw, alts):
                    continue
                choices = [chunk] + [modal_form(x, u.base, u.cls, polite) for x in alts]
            elif fam == "CONN" and m.chunk:
                span = m.chunk
                chunk = surf(toks, *span)
                past = any(t.l == "た" for t in toks[u.head + 1:span[1]]) and g.id in ("kara-reason", "node", "noni", "kedo")
                try:
                    if conn_form(g.id, u.base, u.cls, past) != chunk:
                        continue
                except (KeyError, ValueError):
                    continue
                alts = [x for x in CONN if x != g.id and not never_contrast(x, g.id)]
                rng.shuffle(alts)
                picked = []
                for x in alts:
                    if any(never_contrast(x, y) for y in picked):
                        continue
                    if _kw_ok(en, g.kw, picked + [x]):
                        picked.append(x)
                    if len(picked) == 3:
                        break
                if len(picked) < 3:
                    continue
                alts = picked
                choices = [chunk] + [conn_form(x, u.base, u.cls, past) for x in alts]
            elif fam is None and g.id in ("sou-looks", "sou-hearsay") and m.chunk:
                a, k = m.chunk
                span = None
                for kk in range(k, min(len(toks), k + 3) + 1):
                    if _pred_end(toks, kk) is not None:
                        span = (a, kk)
                        break
                if span is None:
                    continue
                chunk = surf(toks, *span)
                try:
                    polite = next((p for p in (True, False) if sou_form(g.id, u.base, u.cls, p) == chunk), None)
                except (KeyError, ValueError):
                    continue
                if polite is None:
                    continue
                alts = SOU_ALTS[g.id]
                if not _kw_ok(en, g.kw, alts, EXTRA_KW):
                    continue
                choices = [chunk] + [sou_form(x, u.base, u.cls, polite) for x in alts]
                if len(set(choices)) < 3:
                    continue
            elif fam == "ASPECT" and m.slot:
                end = m.slot[1] + 1
                span = None
                for k in range(end, min(len(toks), end + 4) + 1):
                    if _pred_end(toks, k) is not None:
                        span = (u.start, k)
                        break
                if span is None:
                    continue
                chunk = surf(toks, *span)
                try:
                    combo = next(((tn, p) for tn in ("nonpast", "past") for p in (True, False)
                                  if aspect_form(g.id, u.base, u.cls, tn, p) == chunk), None)
                except (KeyError, ValueError):
                    continue
                if combo is None:
                    continue
                tense, polite = combo
                alts = [x for x in ASPECT_AUX if x != g.id]
                if not _kw_ok(en, g.kw, alts):
                    continue
                choices = [chunk] + [aspect_form(x, u.base, u.cls, tense, polite) for x in alts]
            else:
                continue
            uniq = []
            for c in choices:
                if c not in uniq:
                    uniq.append(c)
            if len(uniq) < 3:
                continue
            lv = min(ps.level, g.level)
            yield {
                "key": f"gm:{ps.s.id}:{u.start}", "kind": "gmean", "level": lv,
                "kc": f"gp:{g.id}", "tags": [f"gp:{g.id}"], "cat": "grammar",
                "seed": seed(lv, "gmean", g.diff, len(ps.s.ja)), "sid": ps.s.id, "names": ps.names,
                "payload": {
                    "sent": sentence_with(toks, span, "blank"), **tr(ps), "choices": uniq,
                    "gp": g.id, "gp_name": g.name, "explain": f"{g.name}: {g.en}. {g.explain_en}",
                    "explain_ru": f"{g.name}: {g.ru}. {g.explain_ru}", "full": ps.s.ja, "src": src(ps),
                },
            }
            made = True


# ===========================================================================
# Voice (active / passive / causative / potential)
# ===========================================================================

def derived_verb(base, cls, voice):
    if voice == "active":
        return base, cls
    if cls == "v1":
        s = base[:-1]
        return {"passive": s + "られる", "causative": s + "させる", "potential": s + "られる",
                "caus-passive": s + "させられる"}[voice], "v1"
    if cls == "vs-i":
        p = base[:-2]
        return {"passive": p + "される", "causative": p + "させる", "potential": p + "できる",
                "caus-passive": p + "させられる"}[voice], "v1"
    if cls == "vk":
        k = "来" if base.startswith("来") else "こ"
        return {"passive": k + "られる", "causative": k + "させる", "potential": k + "られる",
                "caus-passive": k + "させられる"}[voice], "v1"
    a = conjugate_verb(base, cls, "a_stem")
    e = conjugate_verb(base, cls, "e_stem")
    cp = a + ("せられる" if base.endswith("す") else "される")
    return {"passive": a + "れる", "causative": a + "せる", "potential": e + "る", "caus-passive": cp}[voice], "v1"


def tr_form(tense, polite, neg):
    return {(False, False, False): "dict", (False, False, True): "nai", (True, False, False): "ta",
            (True, False, True): "nakatta", (False, True, False): "masu", (False, True, True): "masen",
            (True, True, False): "mashita", (True, True, True): "masendeshita"}[(tense == "past", polite, neg)]


VOICE_KW = {"passive": GP_BY_ID["passive"].kw, "causative": GP_BY_ID["causative"].kw,
            "potential": GP_BY_ID["potential"].kw, "caus-passive": GP_BY_ID["caus-passive"].kw}


def gen_voice(pool, rng):
    for ps in pool:
        toks = ps.s.toks
        en = ps.s.en
        units = verb_units(toks)
        for h, u in sorted(units.items(), reverse=True):
            if u.pos != "v" or u.cls in ("v5aru", "v5r-i"):
                continue
            j = h + 1
            while j < len(toks) and toks[j].p1 == "助動詞":
                j += 1
            if _pred_end(toks, j) is None:
                break
            span = (u.start, j)
            chunk = surf(toks, *span)
            lem = [t.l for t in toks[h + 1:j]]
            if any(x not in ("れる", "られる", "せる", "させる", "ます", "た", "ない", "ず") for x in lem):
                break
            voice = voice_of(toks, h, u)
            if u.base == "する" or u.cls == "vk":
                break
            base = u.base
            cls = u.cls
            if u.potential:
                # rebuild the godan base from the lemma (話せる -> 話す)
                lb = toks[h].l.split("-")[0]
                if not lb or lb[-1] not in "うくぐすつぬぶむる":
                    break
                base, cls = lb, ("v5k-s" if lb in ("行く",) else {"う": "v5u", "く": "v5k", "ぐ": "v5g", "す": "v5s",
                                                                  "つ": "v5t", "ぬ": "v5n", "ぶ": "v5b", "む": "v5m",
                                                                  "る": "v5r"}[lb[-1]])
                if base[:-1] != u.base[:len(base) - 1]:
                    break
            if voice == "active":
                break
            polite = "ます" in lem
            past = "た" in lem
            neg = "ない" in lem or "ず" in lem
            tense = "past" if past else "nonpast"
            f = tr_form(tense, polite, neg)
            if voice == "passive" and cls == "v1" and re.search(VOICE_KW["potential"], en, re.I) and not re.search(VOICE_KW["passive"], en, re.I):
                voice = "potential"
            if not re.search(VOICE_KW[voice], en, re.I):
                break
            others = [v for v in ("active", "passive", "causative", "potential") if v != voice]
            ok = True
            for v in others:
                if v != "active" and re.search(VOICE_KW[v], en, re.I):
                    ok = False
            if not ok:
                break
            try:
                db, dc = derived_verb(base, cls, voice)
                if conjugate_verb(db, dc, f) != chunk:
                    break
                choices = [chunk]
                for v in others:
                    vb, vc = derived_verb(base, cls, v)
                    s = conjugate_verb(vb, vc, f)
                    if s not in choices:
                        choices.append(s)
            except (KeyError, ValueError, IndexError):
                break
            if len(choices) < 3:
                break
            gid = {"passive": "passive", "causative": "causative", "potential": "potential", "caus-passive": "caus-passive"}[voice]
            g = GP_BY_ID[gid]
            lv = min(ps.level, g.level)
            yield {
                "key": f"vo:{ps.s.id}:{u.start}", "kind": "voice", "level": lv,
                "kc": f"gp:{gid}", "tags": [f"gp:{gid}"], "cat": "grammar",
                "seed": seed(lv, "voice", g.diff, len(ps.s.ja)), "sid": ps.s.id, "names": ps.names,
                "payload": {
                    "sent": sentence_with(toks, span, "blank"), **tr(ps), "choices": choices[:4],
                    "gp": gid, "gp_name": g.name, "explain": f"{g.name}: {g.en}. {g.explain_en}",
                    "explain_ru": f"{g.name}: {g.ru}. {g.explain_ru}", "full": ps.s.ja, "src": src(ps),
                },
            }
            break


# ===========================================================================
# Tense / polarity of the final predicate
# ===========================================================================

PAST_EN = re.compile(r"\b(was|were|did|had|went|came|saw|ate|drank|bought|made|took|gave|got|said|told|thought|knew|"
                     r"found|left|felt|became|began|brought|wrote|ran|sat|slept|spoke|stood|swam|taught|understood|won|"
                     r"wore|forgot|lost|met|paid|heard|held|kept|meant|sent|sold|spent|broke|chose|drove|fell|flew|"
                     r"grew|hid|hit|hurt|led|lent|rode|rang|rose|shook|shot|sang|stole|threw|woke|built|caught|fought|"
                     r"read yesterday|\w+ed)\b", re.I)
NEG_EN = re.compile(r"\b(not|never|no|nobody|nothing|none|nowhere|neither|nor|without)\b|n't\b", re.I)


def gen_form(pool, rng):
    for ps in pool:
        toks = ps.s.toks
        en = ps.s.en
        units = verb_units(toks)
        if not units:
            continue
        h = max(units)
        u = units[h]
        j = h + 1
        te_iru = False
        if u.pos == "v" and j + 1 < len(toks) and _is_te(toks[j]) and toks[j + 1].l == "居る":
            te_iru = True
            j += 2
        while j < len(toks) and toks[j].p1 == "助動詞" and toks[j].l in ("ます", "た", "ない", "ず", "です"):
            j += 1
        if j < len(toks) and toks[j].p1 == "形容詞" and toks[j].l == "無い" and u.pos == "adj":
            j += 1
            while j < len(toks) and toks[j].p1 == "助動詞" and toks[j].l in ("た", "です"):
                j += 1
        if _pred_end(toks, j) is None:
            continue
        span = (u.start, j)
        chunk = surf(toks, *span)
        lem = [t.l for t in toks[h + 1:j]]
        if u.pos == "v" and u.cls in ("v5aru",):
            continue
        if u.potential:
            continue
        polite = "ます" in lem or "です" in lem
        past = "た" in lem
        neg = "ない" in lem or "ず" in lem or "無い" in lem
        en_past = bool(PAST_EN.search(en)) and not re.search(r"\bwill\b|\bgoing to\b", en, re.I)
        en_neg = bool(NEG_EN.search(en))
        if en_past != past or en_neg != neg:
            continue
        try:
            if u.pos == "v":
                if te_iru:
                    te = conjugate_verb(u.base, u.cls, "te")
                    combos = {(p, n): te + conjugate_verb("いる", "v1", tr_form("past" if p else "nonpast", polite, n))
                              for p in (False, True) for n in (False, True)}
                    gid = "te-iru"
                else:
                    combos = {(p, n): conjugate_verb(u.base, u.cls, tr_form("past" if p else "nonpast", polite, n))
                              for p in (False, True) for n in (False, True)}
                    gid = "polite" if polite else "plain-past-neg"
            else:
                if u.cls not in ("adj-i", "adj-ix"):
                    continue
                fm = {(False, False): "dict", (False, True): "kunai", (True, False): "katta", (True, True): "kunakatta"}
                combos = {(p, n): conjugate_adj(u.base, u.cls, fm[(p, n)]) + ("です" if polite else "")
                          for p in (False, True) for n in (False, True)}
                gid = "adj-forms"
        except (KeyError, ValueError, IndexError):
            continue
        if combos[(past, neg)] != chunk:
            continue
        choices = [chunk] + [v for k, v in combos.items() if k != (past, neg)]
        if len(set(choices)) < 4:
            continue
        g = GP_BY_ID[gid]
        lv = min(ps.level, g.level)
        yield {
            "key": f"fo:{ps.s.id}", "kind": "form", "level": lv,
            "kc": f"gp:{gid}", "tags": [f"gp:{gid}"], "cat": "grammar",
            "seed": seed(lv, "form", 0.0, len(ps.s.ja)), "sid": ps.s.id, "names": ps.names,
            "payload": {
                "sent": sentence_with(toks, span, "blank"), **tr(ps), "choices": choices,
                "gp": gid, "gp_name": g.name, "explain": g.explain_en, "explain_ru": g.explain_ru,
                "full": ps.s.ja, "src": src(ps),
            },
        }


# ===========================================================================
# 並べ替え (sentence ordering)
# ===========================================================================

CONTENT_P1 = ("名詞", "代名詞", "動詞", "形容詞", "形状詞", "副詞", "連体詞", "感動詞", "接続詞", "接頭辞")
FORMAL_N = {"事", "方", "筈", "積り", "為", "前", "後", "時", "所", "様", "物", "訳"}


def bunsetsu(toks):
    chunks, cur = [], []
    for i, t in enumerate(toks):
        starts = False
        if t.p1 in CONTENT_P1:
            prev = toks[i - 1] if i else None
            if prev is None:
                starts = True
            elif prev.p1 == "接頭辞":
                starts = False
            elif t.p1 == "名詞" and prev.p1 == "名詞":
                starts = False
            elif t.p1 in ("動詞", "形容詞") and t.p2 == "非自立可能":
                starts = _is_te(prev)
            elif t.p1 in ("名詞",) and t.p2 == "普通名詞" and t.l in FORMAL_N and prev.p1 in ("動詞", "助動詞", "形容詞"):
                starts = True
            elif t.p1 == "形状詞" and t.p2 == "助動詞語幹":
                starts = False
            else:
                starts = True
        if t.p1 == "接尾辞":
            starts = False
        if starts and cur:
            chunks.append(cur)
            cur = []
        cur.append(i)
    if cur:
        chunks.append(cur)
    return chunks


def gen_order(pool, rng):
    for ps in pool:
        toks = ps.s.toks
        if toks[-1].p1 != "補助記号":
            continue
        ch = bunsetsu(toks[:-1])
        if len(ch) < 3:
            continue
        # tail: predicate chunks + at most one argument chunk in front
        tail = []
        k = len(ch) - 1
        while k >= 0:
            c = ch[k]
            first = toks[c[0]]
            last = toks[c[-1]]
            is_pred = first.p1 in ("動詞", "形容詞", "助動詞") or (first.p1 == "名詞" and first.l in FORMAL_N and k != len(ch) - 1) \
                or (first.p1 == "形状詞") or (first.p1 == "名詞" and k == len(ch) - 1)
            if first.p1 == "副詞":
                break
            if is_pred and not (last.p1 == "助詞" and last.p2 == "格助詞" and first.p1 not in ("動詞", "形容詞") and first.l not in FORMAL_N):
                tail.insert(0, c)
                k -= 1
                continue
            if first.p1 in ("名詞", "代名詞") and last.p1 == "助詞" and last.s in ("を", "に", "が", "で", "へ", "と"):
                tail.insert(0, c)
            break
        if not (3 <= len(tail) <= 5):
            continue
        tiles = ["".join(toks[i].s for i in c) for c in tail]
        if len(set(tiles)) != len(tiles) or any(len(x) > 9 for x in tiles):
            continue
        if not any(toks[c[0]].p1 == "動詞" or toks[c[0]].p1 == "形容詞" for c in tail):
            continue
        a = tail[0][0]
        b = tail[-1][-1] + 1
        gps = sorted({m.gp for m in detect(toks) if m.unit.start >= a})
        lv = ps.level
        for gp in gps:
            lv = min(lv, GP_BY_ID[gp].level)
        kc = f"gp:{gps[0]}" if gps else "order"
        tags = [f"gp:{x}" for x in gps] or ["order"]
        yield {
            "key": f"or:{ps.s.id}", "kind": "order", "level": lv, "kc": kc, "tags": tags, "cat": "grammar",
            "seed": seed(lv, "order", 0.15 * (len(tiles) - 3) + (GP_BY_ID[gps[0]].diff if gps else 0), len(ps.s.ja)),
            "sid": ps.s.id, "names": ps.names,
            "payload": {
                "prefix": segments(toks, 0, a), "suffix": segments(toks, b), "tiles": tiles,
                **tr(ps), "full": ps.s.ja, "src": src(ps),
                "explain": "Japanese is head-final: arguments come first, the verb and its endings close the sentence.",
                "explain_ru": "В японском сказуемое в конце: сначала дополнения, затем глагол и его окончания.",
            },
        }


# ===========================================================================
# Spot the mistake
# ===========================================================================

def gen_odd(pool, real: RealForms, rng, max_items=1200):
    short = [ps for ps in pool if len(ps.s.ja) <= 18]
    by_level = defaultdict(list)
    for ps in short:
        by_level[ps.level].append(ps)
    cands = []
    for ps in short:
        toks = ps.s.toks
        for m in detect(toks):
            g = GP_BY_ID[m.gp]
            if g.slot_form not in ("te", "ta") or not m.slot or m.unit.pos != "v" or m.unit.potential:
                continue
            u = m.unit
            a, b = m.slot
            correct = surf(toks, a, b)
            try:
                if conjugate_verb(u.base, u.cls, g.slot_form) != correct:
                    continue
                bads = [w for w in wrong_te_ta(u.base, u.cls, g.slot_form) if w not in real]
            except (KeyError, ValueError, IndexError):
                continue
            if not bads:
                continue
            cands.append((ps, m, g, correct, bads))
            break
    rng.shuffle(cands)
    for ps, m, g, correct, bads in cands[:max_items]:
        toks = ps.s.toks
        a, b = m.slot
        bad = rng.choice(bads)
        wrong_sent = surf(toks, 0, a) + bad + surf(toks, b, len(toks))
        others = [o for o in by_level[ps.level] if o.s.id != ps.s.id and abs(len(o.s.ja) - len(ps.s.ja)) <= 6]
        if len(others) < 3:
            continue
        picks = rng.sample(others, 3)
        u = m.unit
        rule_en, rule_ru = TE_RULE.get(u.cls, ("", ""))
        yield {
            "key": f"od:{ps.s.id}", "kind": "odd", "level": ps.level,
            "kc": conj_class_tag(u.cls), "tags": [conj_class_tag(u.cls), f"gp:{g.id}"], "cat": "grammar",
            "seed": seed(ps.level, "odd", 0.2 if u.cls.startswith("v5") else 0.0, 16),
            "sid": ps.s.id, "names": ps.names,
            "payload": {
                "choices": [wrong_sent] + [o.s.ja for o in picks],
                "wrong": bad, "right": correct, "fixed": ps.s.ja,
                "explain": f"{bad} ✗ → {correct} ✓ ({u.base}: {rule_en})",
                "explain_ru": f"{bad} ✗ → {correct} ✓ ({u.base}: {rule_ru})",
                "src": src(ps), "others_src": [o.s.id for o in picks],
                **tr(ps),
            },
        }


# ===========================================================================
# Sentence meaning (JA -> EN) and production (EN -> JA)
# ===========================================================================

STOP_LEMMA = {"為る", "有る", "居る", "成る", "事", "物", "私", "此れ", "其れ", "彼", "彼女", "此の", "其の", "言う",
              "思う", "其処", "此処", "今", "人", "何", "僕", "君", "貴方", "所", "時", "方", "様", "良い", "無い"}
WORD_RE = re.compile(r"[a-z']+")


def _en_words(s: str) -> set:
    return set(WORD_RE.findall(s.lower())) - {"the", "a", "an", "to", "is", "are", "was", "were", "i", "you", "he",
                                              "she", "it", "we", "they", "of", "in", "on", "at", "and", "my", "your"}


def gen_meaning(pool, rng, n_meaning=4000, n_produce=2600):
    content = {}
    df = Counter()
    for ps in pool:
        lem = {t.l for t in ps.s.toks if t.p1 in ("名詞", "動詞", "形容詞", "形状詞", "副詞", "代名詞") and t.l not in STOP_LEMMA and t.p2 != "数詞"}
        content[ps.s.id] = lem
        df.update(lem)
    N = len(pool)
    idf = {w: math.log(N / (1 + c)) for w, c in df.items()}
    inv = defaultdict(list)
    for ps in pool:
        for w in content[ps.s.id]:
            if df[w] < 4000:
                inv[w].append(ps)
    byid = {ps.s.id: ps for ps in pool}
    order = list(pool)
    rng.shuffle(order)
    made_m = made_p = 0
    for ps in order:
        if made_m >= n_meaning and made_p >= n_produce:
            break
        if len(ps.s.ja) < 6 or len(ps.s.en) > 80:
            continue
        lem = content[ps.s.id]
        if len(lem) < 2:
            continue
        score = Counter()
        for w in lem:
            for o in inv.get(w, ())[:400]:
                if o.s.id != ps.s.id:
                    score[o.s.id] += idf[w]
        if not score:
            continue
        ew = _en_words(ps.s.en)
        picks = []
        for oid, sc in score.most_common(60):
            o = byid[oid]
            if o.s.ja == ps.s.ja or o.s.en.lower() == ps.s.en.lower():
                continue
            ow = _en_words(o.s.en)
            if not ow or len(ew & ow) / max(1, len(ew | ow)) > 0.5:
                continue
            if any(len(_en_words(p.s.en) & ow) / max(1, len(_en_words(p.s.en) | ow)) > 0.6 for p in picks):
                continue
            if abs(len(o.s.en) - len(ps.s.en)) > 40:
                continue
            picks.append(o)
            if len(picks) == 3:
                break
        if len(picks) < 3:
            continue
        gps = sorted({m.gp for m in detect(ps.s.toks)})
        lv = ps.level
        has_ru = bool(ps.s.ru) and all(p.s.ru for p in picks)
        kind = "meaning" if (made_m < n_meaning and (made_p >= n_produce or rng.random() < 0.6)) else "produce"
        if kind == "meaning":
            made_m += 1
            payload = {"sent": segments(ps.s.toks), "choices": [ps.s.en] + [p.s.en for p in picks],
                       "full": ps.s.ja, "src": src(ps), "others_src": [p.s.id for p in picks]}
            if has_ru:
                payload["choices_ru"] = [ps.s.ru] + [p.s.ru for p in picks]
        else:
            made_p += 1
            payload = {**tr(ps), "choices": [ps.s.ja] + [p.s.ja for p in picks], "full": ps.s.ja,
                       "src": src(ps), "others_src": [p.s.id for p in picks],
                       "others_en": [p.s.en for p in picks]}
        yield {
            "key": f"{'mn' if kind == 'meaning' else 'pr'}:{ps.s.id}", "kind": kind, "level": lv,
            "kc": f"sent:{ps.s.id}", "tags": [f"gp:{g}" for g in gps[:2]] or ["reading"], "cat": "reading",
            "seed": seed(lv, kind, 0.0, len(ps.s.ja)), "sid": ps.s.id, "names": ps.names,
            "payload": payload,
        }


# ===========================================================================
# Kanji in context: reading and writing
# ===========================================================================

VOICE_MAP = {}
for row_a, row_b in (("かきくけこ", "がぎぐげご"), ("さしすせそ", "ざじずぜぞ"), ("たちつてと", "だぢづでど"),
                     ("はひふへほ", "ばびぶべぼ")):
    for x, y in zip(row_a, row_b):
        VOICE_MAP[x] = y
        VOICE_MAP[y] = x
for x, y in zip("はひふへほ", "ぱぴぷぺぽ"):
    VOICE_MAP.setdefault(y, x)
SMALL_Y = set("ゃゅょ")
O_ROW = set("おこそとのほもよろごぞどぼぽょ")
U_ROW = set("うくすつぬふむゆるぐずづぶぷゅ")
E_ROW = set("えけせてねへめれげぜでべぺ")


def reading_perturbations(r: str) -> set[str]:
    out = set()
    n = len(r)
    for i, ch in enumerate(r):
        # long vowel insert / delete
        if ch in O_ROW or ch in U_ROW:
            if i + 1 < n and r[i + 1] == "う":
                out.add(r[:i + 1] + r[i + 2:])
            else:
                out.add(r[:i + 1] + "う" + r[i + 1:])
        if ch in E_ROW:
            if i + 1 < n and r[i + 1] == "い":
                out.add(r[:i + 1] + r[i + 2:])
        # sokuon
        if ch == "っ":
            out.add(r[:i] + r[i + 1:])
        elif i > 0 and ch in "かきくけこさしすせそたちつてとぱぴぷぺぽ" and r[i - 1] not in "っんー":
            out.add(r[:i] + "っ" + r[i:])
        # voicing
        if ch in VOICE_MAP and i <= 2:
            out.add(r[:i] + VOICE_MAP[ch] + r[i + 1:])
        # small ya/yu/yo <-> big
        if ch in SMALL_Y:
            big = {"ゃ": "や", "ゅ": "ゆ", "ょ": "よ"}[ch]
            out.add(r[:i] + big + r[i + 1:])
            out.add(r[:i] + r[i + 1:] if i > 0 else r)
    out.discard(r)
    return {x for x in out if x and len(x) >= 2 and not x.startswith("っ") and "っっ" not in x and not x.endswith("っ")}


def align_reading(word: str, reading: str, lx, depth=0):
    """Split a reading over the word's characters: [(chars, reading_part)], or None."""
    if not word:
        return [] if not reading else None
    if depth > 8:
        return None
    ch = word[0]
    if is_kana(ch):
        h = kata_to_hira(ch)
        if reading.startswith(h):
            rest = align_reading(word[1:], reading[len(h):], lx, depth + 1)
            return None if rest is None else [(ch, h)] + rest
        return None
    k = lx.kanji.get(ch)
    if not k:
        return None
    opts = set(k.on) | set(k.kun)
    more = set()
    for o in opts:
        if not o:
            continue
        if o[0] in VOICE_MAP:
            more.add(VOICE_MAP[o[0]] + o[1:])
        if len(o) >= 2 and o[-1] in "つくきち":
            more.add(o[:-1] + "っ")
    opts |= more
    for o in sorted(opts, key=len, reverse=True):
        if o and reading.startswith(o):
            rest = align_reading(word[1:], reading[len(o):], lx, depth + 1)
            if rest is not None:
                return [(ch, o)] + rest
    return None


def reading_distractors(word: str, reading: str, lx) -> set[str]:
    """JLPT-style wrong readings: long/short vowel, っ, voicing, another on-reading of a kanji."""
    al = align_reading(word, reading, lx)
    out = set()
    if not al:
        for x in reading_perturbations(reading):
            if "っ" not in x or "っ" in reading:
                out.add(x)
        return out
    parts = [p for _, p in al]
    for i, (ch, part) in enumerate(al):
        if not is_kanji(ch) or not part:
            continue
        v = set()
        if part.endswith("う") and len(part) >= 2 and (part[-2] in O_ROW or part[-2] in U_ROW):
            v.add(part[:-1])
        elif part[-1] in O_ROW or part[-1] in U_ROW:
            v.add(part + "う")
        if part.endswith("い") and len(part) >= 2 and part[-2] in E_ROW:
            v.add(part[:-1])
        elif part[-1] in E_ROW:
            v.add(part + "い")
        if part.endswith("っ"):
            v.update({part[:-1] + "つ", part[:-1] + "く"})
        elif part[-1] in "つくちき" and i + 1 < len(al):
            v.add(part[:-1] + "っ")
        if part[0] in VOICE_MAP:
            v.add(VOICE_MAP[part[0]] + part[1:])
        k = lx.kanji.get(ch)
        for o in (k.on if k else []):
            if o and o != part and abs(len(o) - len(part)) <= 1:
                v.add(o)
        for x in v:
            out.add("".join(parts[:i]) + x + "".join(parts[i + 1:]))
    out.discard(reading)
    return {x for x in out if len(x) >= 2 and not x.startswith("っ")}


def kanji_swaps(word: str, reading: str, lx) -> set[str]:
    """Readings with one kanji's part replaced by another reading of the same kanji."""
    al = align_reading(word, reading, lx)
    if not al:
        return set()
    out = set()
    for idx, (ch, part) in enumerate(al):
        k = lx.kanji.get(ch)
        if not k:
            continue
        for alt in list(k.on)[:3] + list(k.kun)[:3]:
            if alt and alt != part:
                new = "".join(p if j != idx else alt for j, (_, p) in enumerate(al))
                out.add(new)
    return out


class KanjiIndex:
    def __init__(self, lx):
        self.lx = lx
        self.pool = [c for c, k in lx.kanji.items() if k.jlpt and k.jlpt >= 3]
        self.by_on = defaultdict(list)
        for c in self.pool:
            for o in lx.kanji[c].on:
                self.by_on[o].append(c)
        self.comp = {c: set(lx.kanji[c].radicals) for c in self.pool}

    def similar(self, ch: str, n=6) -> list[str]:
        k = self.lx.kanji.get(ch)
        if not k:
            return []
        mine = self.comp.get(ch) or set(k.radicals)
        scored = []
        for c in self.pool:
            if c == ch:
                continue
            other = self.comp[c]
            shared = len(mine & other)
            if shared == 0:
                continue
            sc = shared / max(1, len(mine | other)) - 0.03 * abs(self.lx.kanji[c].strokes - k.strokes)
            scored.append((sc, c))
        scored.sort(reverse=True)
        return [c for s, c in scored[:n] if s > 0.2]

    def same_on(self, ch: str) -> list[str]:
        k = self.lx.kanji.get(ch)
        if not k:
            return []
        out = []
        for o in k.on:
            out.extend(c for c in self.by_on.get(o, []) if c != ch)
        return out


def _target_tokens(ps, lx):
    toks = ps.s.toks
    for i, t in enumerate(toks):
        if t.p1 not in ("名詞", "動詞", "形容詞", "形状詞", "副詞") or t.p2 in ("固有名詞", "数詞", "非自立可能"):
            continue
        if t.p1 in ("動詞", "形容詞") and t.s != t.b:
            continue          # only dictionary forms; no verb fragments like 住ん / 払い
        if t.l in FORMAL_N or t.p3 == "助数詞可能" and len(t.s) == 1:
            continue
        if not any(is_kanji(c) for c in t.s) or len(t.s) > 5:
            continue
        if any(is_kanji(c) and not (lx.kanji_level(c) and lx.kanji_level(c) >= 3) for c in t.s):
            continue
        yield i, t


def gen_kanji(pool, lx, real: RealForms, rng):
    kx = KanjiIndex(lx)
    for ps in pool:
        toks = ps.s.toks
        targets = list(_target_tokens(ps, lx))
        rng.shuffle(targets)
        done_read = done_write = False
        for i, t in targets:
            reading = t.r
            if not reading or not all(is_hiragana(c) or c == "ー" for c in reading):
                continue
            base_form = t.b if t.p1 in ("動詞", "形容詞") else t.s
            valid = lx.valid_readings(t.s) | lx.valid_readings(base_form)
            if t.p1 == "名詞" and reading not in lx.valid_readings(t.s):
                continue
            wl = lx.word_level(base_form, t.rb) or lx.word_level(t.s, reading)
            if not wl or wl < 3:
                continue
            lv = min(ps.level, wl)
            kanji_tags = [f"k:{c}" for c in t.s if is_kanji(c)]
            _seqs = lx.form_entries.get(base_form) or lx.form_entries.get(t.s) or []
            _e = lx.jmdict.get(_seqs[0]) if _seqs else None
            gl = {"gloss": _e.en_gloss(1, 3), "gloss_ru": _e.ru_gloss(2)} if _e else {}
            # ---- reading
            if not done_read and len(lx.valid_readings(t.s)) <= 1 or (not done_read and t.p1 != "名詞"):
                cands = reading_distractors(t.s, reading, lx)
                cands = {c for c in cands if c not in valid and c != reading}
                real_words = [c for c in cands if c in lx.reb_kebs]
                other = [c for c in cands if c not in lx.reb_kebs]
                rng.shuffle(real_words)
                rng.shuffle(other)
                ds = (real_words[:2] + other)[:3]
                if len(ds) == 3 and not done_read:
                    done_read = True
                    yield {
                        "key": f"kr:{ps.s.id}:{i}", "kind": "kread", "level": lv,
                        "kc": f"read:{t.s}", "tags": kanji_tags + [f"w:{base_form}"], "cat": "kanji",
                        "seed": seed(lv, "kread", 0.1 * (len(reading) - 3), len(ps.s.ja)),
                        "sid": ps.s.id, "names": ps.names,
                        "payload": {
                            "sent": sentence_with(toks, (i, i + 1), "hl", {"t": t.s}), **tr(ps),
                            "choices": [reading] + ds, "word": t.s, "accept": sorted(valid & {reading}) or [reading], **gl,
                            "explain": f"{t.s} is read 「{reading}」 here.", "explain_ru": f"{t.s} читается здесь как 「{reading}」.",
                            "full": ps.s.ja, "src": src(ps),
                        },
                    }
                    continue
            # ---- writing (choose the kanji)
            if not done_write and t.p1 in ("名詞", "動詞", "形容詞") and len(t.s) >= 2:
                same_entry = set()
                for seq in lx.form_entries.get(base_form, []):
                    e = lx.jmdict.get(seq)
                    if e:
                        same_entry.update(e.kanji)
                cands = []
                # homophones with different meaning
                for keb in lx.reb_kebs.get(reading, ()):
                    if keb in same_entry or keb == t.s or len(keb) != len(t.s):
                        continue
                    if not all((lx.kanji_level(c) or 0) >= 3 for c in keb if is_kanji(c)):
                        continue
                    cands.append(keb)
                # one-kanji substitutions
                for j, c in enumerate(t.s):
                    if not is_kanji(c):
                        continue
                    for alt in kx.similar(c, 5) + kx.same_on(c)[:5]:
                        w = t.s[:j] + alt + t.s[j + 1:]
                        if w != t.s and w not in same_entry and reading not in lx.valid_readings(w):
                            cands.append(w)
                seen = []
                for c in cands:
                    if c not in seen and c != t.s:
                        seen.append(c)
                if len(seen) < 3:
                    continue
                homo = [c for c in seen if c in lx.all_forms][:1]
                rest = [c for c in seen if c not in homo]
                rng.shuffle(rest)
                ds = (homo + rest)[:3]
                done_write = True
                yield {
                    "key": f"kw:{ps.s.id}:{i}", "kind": "kwrite", "level": lv,
                    "kc": f"write:{t.s}", "tags": kanji_tags + [f"w:{base_form}"], "cat": "kanji",
                    "seed": seed(lv, "kwrite", 0.0, len(ps.s.ja)), "sid": ps.s.id, "names": ps.names,
                    "payload": {
                        "sent": sentence_with(toks, (i, i + 1), "hl", {"t": reading, "kana": True}), **tr(ps),
                        "choices": [t.s] + ds, "word": t.s, "reading": reading, **gl,
                        "explain": f"「{reading}」 here is written {t.s}.", "explain_ru": f"「{reading}」 здесь пишется как {t.s}.",
                        "full": ps.s.ja, "src": src(ps),
                    },
                }
            if done_read and done_write:
                break


# ===========================================================================
# Vocabulary in context
# ===========================================================================

def gen_vocab(pool, lx, rng, sim=None):
    # candidate words by POS and level
    nouns_by_level = defaultdict(list)
    verbs_by_level = defaultdict(list)
    adjs_by_level = defaultdict(list)
    for seq, w in lx.jlpt.items():
        if w.level < 3:
            continue
        e = lx.jmdict.get(seq)
        if not e:
            continue
        form = w.kanji or w.kana
        pos = e.pos_set()
        gl = {g.lower() for s in e.senses[:2] for g in s.en}
        if any(p.startswith("v5") or p == "v1" for p in pos) and form[-1] in "うくぐすつぬぶむる":
            cls = "v1" if "v1" in pos else next((p for p in pos if p.startswith("v5")), None)
            if cls in ("v5k-s", "v5r-i", "v5aru") or cls is None:
                continue
            verbs_by_level[w.level].append((form, cls, gl, e))
        elif "adj-i" in pos and form.endswith("い"):
            adjs_by_level[w.level].append((form, "adj-i", gl, e))
        elif "n" in pos and not any(p.startswith("v") for p in pos):
            nouns_by_level[w.level].append((form, "n", gl, e))

    def gloss_words(gl):
        ws = set()
        for g in gl:
            ws |= set(WORD_RE.findall(g)) - {"to", "be", "a", "the", "of", "one's", "something", "someone"}
        return ws

    for ps in pool:
        toks = ps.s.toks
        en_words = _en_words(ps.s.en)
        units = verb_units(toks)
        cand_idx = [i for i, t in enumerate(toks) if t.p1 in ("名詞", "動詞", "形容詞") and t.p2 not in ("固有名詞", "数詞", "非自立可能")
                    and t.l not in STOP_LEMMA and t.l not in FORMAL_N and t.b not in ("つもり", "はず", "こと", "ため", "ほう", "よう", "ところ", "わけ", "もの")]
        rng.shuffle(cand_idx)
        for i in cand_idx[:3]:
            t = toks[i]
            base = t.b
            wl = lx.word_level(base, t.rb)
            if not wl or wl < 3:
                continue
            seqs = lx.form_entries.get(base, [])
            if not seqs:
                continue
            e = lx.jmdict.get(seqs[0])
            my_gl = gloss_words({g.lower() for s in e.senses[:3] for g in s.en})
            if t.p1 == "名詞":
                if t.p3 == "サ変可能" and i + 1 < len(toks) and toks[i + 1].l == "為る":
                    continue
                pool_w = nouns_by_level[wl] + nouns_by_level.get(wl + 1, [])
                span = (i, i + 1)
                correct = t.s
                make = lambda form, cls: form
            elif t.p1 == "動詞":
                u = units.get(i)
                if not u or u.start != i or u.cls in ("v5aru", "v5r-i", "vs-i", "vk") or u.potential:
                    continue
                nx = toks[i + 1] if i + 1 < len(toks) else None
                if nx is not None and _is_te(nx):
                    form, span = "te", (i, i + 2)
                elif nx is not None and nx.l == "た" and nx.p1 == "助動詞" and nx.s in ("た", "だ"):
                    form, span = "ta", (i, i + 2)
                elif t.cf.startswith("連用形") and nx is not None and nx.l in ("ます", "たい", "ながら"):
                    form, span = "stem", (i, i + 1)
                elif t.cf.startswith("未然形") and nx is not None and nx.l == "ない":
                    form, span = "a_stem", (i, i + 1)
                elif t.cf.startswith("終止形") or t.cf.startswith("連体形"):
                    form, span = "dict", (i, i + 1)
                else:
                    continue
                correct = surf(toks, *span)
                try:
                    if conjugate_verb(u.base, u.cls, form) != correct:
                        continue
                except (KeyError, ValueError):
                    continue
                pool_w = verbs_by_level[wl] + verbs_by_level.get(wl + 1, [])
                make = lambda f0, cls, form=form: conjugate_verb(f0, cls, form)
            else:
                cls = "adj-i"
                if t.b in ("いい", "良い", "よい") or not t.b.endswith("い"):
                    continue
                cfm = {"終止形-一般": "dict", "連体形-一般": "dict", "連用形-一般": "ku"}
                form = cfm.get(t.cf)
                nx = toks[i + 1] if i + 1 < len(toks) else None
                if t.cf == "連用形-促音便" and nx is not None and nx.l == "た":
                    form, span = "katta", (i, i + 2)
                elif form:
                    span = (i, i + 1)
                else:
                    continue
                correct = surf(toks, *span)
                if conjugate_adj(t.b, cls, form) != correct:
                    continue
                pool_w = adjs_by_level[wl] + adjs_by_level.get(wl + 1, [])
                make = lambda f0, c, form=form: conjugate_adj(f0, "adj-i", form)
            if len(pool_w) < 10:
                continue
            ranked = None
            if sim is not None:
                ranked = sim.neighbors(t.l, [p[0] for p in pool_w])
            picks = []
            tries = ranked if ranked else rng.sample(pool_w, min(40, len(pool_w)))
            lookup = {p[0]: p for p in pool_w}
            for cand in tries:
                p = lookup.get(cand) if isinstance(cand, str) else cand
                if p is None:
                    continue
                form0, cls0, gl0, e0 = p
                if form0 == base or e0.seq in seqs:
                    continue
                gw = gloss_words(gl0)
                if gw & my_gl or gw & en_words:
                    continue
                try:
                    s = make(form0, cls0)
                except (KeyError, ValueError, IndexError):
                    continue
                if s == correct or s in picks:
                    continue
                picks.append(s)
                if len(picks) == 3:
                    break
            if len(picks) < 3:
                continue
            lv = min(ps.level, wl)
            gloss = e.en_gloss(1, 3)
            yield {
                "key": f"vc:{ps.s.id}:{i}", "kind": "vocab", "level": lv,
                "kc": f"use:{base}", "tags": [f"w:{base}"], "cat": "vocab",
                "seed": seed(lv, "vocab", 0.0, len(ps.s.ja)), "sid": ps.s.id, "names": ps.names,
                "payload": {
                    "sent": sentence_with(toks, span, "blank"), **tr(ps), "choices": [correct] + picks,
                    "word": base, "gloss": gloss, "gloss_ru": e.ru_gloss(2),
                    "explain": f"{base}: {gloss}", "explain_ru": f"{base}: {e.ru_gloss(2) or gloss}",
                    "full": ps.s.ja, "src": src(ps),
                },
            }
            break
