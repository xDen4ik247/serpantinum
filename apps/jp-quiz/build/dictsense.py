"""Context-matched dictionary glosses: the JMdict sense a word has *in this sentence*.

For every content word of a sentence we look up its JMdict entries (filtered by the
reading UniDic gave it), then score each sense against the sentence's own English
(and Russian) translation: a sense whose glosses share words with the translation
wins ("通り" in "全くそのとおりです" -> "that's right", not "street").  Senses that are
archaic/rare only win when they match.  Multi-word expressions in JMdict (その通り,
気を付ける, ...) are recognised and glossed as one unit.
"""

from __future__ import annotations

import re

from jpquiz.kana import is_kanji, kata_to_hira

FUNC_P1 = {"助詞", "助動詞", "補助記号", "記号", "空白", "接頭辞", "接尾辞"}
CONTENT_P1 = {"名詞", "動詞", "形容詞", "形状詞", "副詞", "代名詞", "連体詞", "感動詞", "接続詞"}
EN_STOP = {"a", "an", "the", "to", "of", "be", "is", "are", "was", "were", "one's", "oneself", "something", "someone",
           "somebody", "sth", "it", "in", "on", "at", "for", "with", "by", "as", "or", "and", "that", "this", "do",
           "does", "did", "not", "no", "i", "you", "he", "she", "we", "they", "me", "him", "her", "us", "them", "my",
           "your", "his", "its", "our", "their", "have", "has", "had", "up", "out", "etc", "esp", "e.g", "from",
           "very", "so", "get", "go", "make"}
BAD_MISC = {"arch", "obs", "rare", "obsc", "dated", "sl", "vulg", "derog", "joc", "m-sl"}
IRREG = {"went": "go", "gone": "go", "saw": "see", "seen": "see", "came": "come", "ate": "eat", "eaten": "eat",
         "bought": "buy", "took": "take", "taken": "take", "gave": "give", "given": "give", "made": "make",
         "said": "say", "told": "tell", "thought": "think", "knew": "know", "known": "know", "got": "get",
         "found": "find", "left": "leave", "felt": "feel", "spoke": "speak", "spoken": "speak", "wrote": "write",
         "written": "write", "ran": "run", "sat": "sit", "stood": "stand", "understood": "understand",
         "brought": "bring", "began": "begin", "begun": "begin", "broke": "break", "broken": "break",
         "drank": "drink", "drunk": "drink", "drove": "drive", "driven": "drive", "fell": "fall", "fallen": "fall",
         "flew": "fly", "flown": "fly", "forgot": "forget", "forgotten": "forget", "heard": "hear", "held": "hold",
         "kept": "keep", "lost": "lose", "met": "meet", "paid": "pay", "sold": "sell", "sent": "send",
         "slept": "sleep", "spent": "spend", "taught": "teach", "wore": "wear", "worn": "wear", "won": "win",
         "chose": "choose", "chosen": "choose", "caught": "catch", "built": "build", "became": "become",
         "grew": "grow", "grown": "grow", "hid": "hide", "hidden": "hide", "rode": "ride", "rose": "rise",
         "sang": "sing", "sung": "sing", "swam": "swim", "threw": "throw", "thrown": "throw", "woke": "wake",
         "lent": "lend", "lay": "lie", "hung": "hang", "children": "child", "men": "man", "women": "woman",
         "people": "person", "feet": "foot", "teeth": "tooth", "mice": "mouse", "better": "good", "best": "good",
         "worse": "bad", "worst": "bad", "taller": "tall", "bigger": "big", "older": "old", "younger": "young",
         "isn't": "be", "wasn't": "be", "don't": "do", "didn't": "do", "can't": "can", "won't": "will",
         "lying": "lie", "dying": "die", "tying": "tie", "led": "lead", "fed": "feed", "fought": "fight", "dug": "dig", "shot": "shoot", "stuck": "stick",
         "struck": "strike", "swept": "sweep", "wept": "weep", "bit": "bite", "bitten": "bite", "blew": "blow",
         "drew": "draw", "drawn": "draw", "froze": "freeze", "shook": "shake", "stole": "steal", "tore": "tear",
         "torn": "tear", "meant": "mean", "dealt": "deal", "built-in": "build", "ought": "should"}
WORD_RE = re.compile(r"[a-z][a-z'-]*")
RU_RE = re.compile(r"[а-яё]+")
PAREN_RE = re.compile(r"\([^)]*\)")
FORMAL = {"こと", "もの", "ところ", "わけ", "はず", "ため", "よう", "ほう", "つもり", "の", "ん"}
# UniDic's formal readings -> the everyday ones learners expect
READING_FIX = {"私": "わたし", "日本": "にほん", "日本人": "にほんじん", "日本語": "にほんご", "何": "なに"}


def en_stem(w: str) -> str:
    w = w.lower().strip("'")
    if w.endswith("'s"):
        w = w[:-2]
    if w in IRREG:
        return IRREG[w]
    for suf, rep in (("ies", "y"), ("ied", "y"), ("ing", ""), ("ness", ""), ("edly", ""), ("ed", ""), ("ly", ""),
                     ("es", ""), ("s", "")):
        if w.endswith(suf) and len(w) - len(suf) >= 3:
            w = w[: -len(suf)] + rep
            break
    if len(w) > 3 and w[-1] == w[-2] and w[-1] not in "aeiouls":
        w = w[:-1]          # stopped -> stopp -> stop
    if len(w) > 4 and w.endswith("e"):
        w = w[:-1]          # make/making -> mak, use/used -> us (both sides get the same treatment)
    return w


def en_bag(text: str) -> set[str]:
    out = {en_stem(w) for w in WORD_RE.findall(text.lower()) if w not in EN_STOP}
    return {w for w in out if w not in EN_STOP and "'" not in w}


def ru_stem(w: str) -> str:
    return w[:5] if len(w) > 5 else (w[:-1] if len(w) > 3 else w)


def ru_bag(text: str) -> set[str]:
    return {ru_stem(w) for w in RU_RE.findall(text.lower()) if len(w) > 2}


_RU_NUM = re.compile(r"^\s*(\d+[.)]?;?\s*)+")
_RU_BRACE = re.compile(r"\{[^}]*\}")
_RU_TAGS = re.compile(r"\((?:прям\.|перен\.|прям\. и перен\.|уст\.|разг\.|кн\.|см\.[^)]*|ср\.[^)]*)\)\s*")


_RU_JA = re.compile(r"\[[^\]]*\]|[\u3040-\u30ff\u4e00-\u9fff～〜]+")


_RU_DBL = re.compile(r"\(\([^()]*\)[^()]*\)\s*|\(тж\.\)\s*")


def clean_ru(g: str) -> str:
    g = _RU_BRACE.sub("", g)
    g = _RU_DBL.sub("", g)
    g = _RU_JA.sub("", g)
    g = g.lstrip(" :;,")
    g = _RU_TAGS.sub("", g)
    g = _RU_NUM.sub("", g)
    g = re.sub(r"\s+", " ", g).strip(" ;,.")
    return g


def _gloss_text(glosses: list[str], n: int = 3) -> str:
    seen, out = set(), []
    for g in glosses:
        g = g.strip()
        if g and g.lower() not in seen:
            seen.add(g.lower())
            out.append(g)
        if len(out) >= n:
            break
    return "; ".join(out)


_LATIN = re.compile(r"[A-Za-z]")
_EN_NOTE = re.compile(r"\s*\(en: [^)]*\)")


def _short(text: str, parts: int = 3, chars: int = 80, ru: bool = False) -> str:
    """At most `parts` ;-separated meanings and about `chars` characters."""
    out = []
    for p in (x.strip() for x in text.split(";")):
        if ru:
            p = _EN_NOTE.sub("", p).strip()
            if _LATIN.search(p):
                continue          # example fragments like "K К. сейчас вышел по делу"
            if p.count("(") > p.count(")"):
                p += ")"
        if p and p not in out:
            out.append(p)
        if len(out) >= parts:
            break
    s = "; ".join(out)
    while len(out) > 1 and len(s) > chars:
        out.pop()
        s = "; ".join(out)
    return s


class Glosser:
    def __init__(self, lx):
        self.lx = lx
        self.cache: dict[tuple, dict | None] = {}

    # ------------------------------------------------------------------ entries
    def entries(self, written: str, reading: str | None):
        """JMdict entries for (written form, reading), most likely first."""
        lx = self.lx
        seqs = lx.form_entries.get(written, [])
        out = []
        for seq in seqs:
            e = lx.jmdict.get(seq)
            if not e:
                continue
            if reading:
                if written in e.kanji:
                    if reading not in e.readings_for(written):
                        continue
                elif reading not in e.readings and written not in e.readings:
                    continue
            out.append(e)
        if not out and reading and written != reading:
            return self.entries(written, None)
        # the JLPT lists only help for kanji spellings: their kana keys collide (その -> 園)
        jl = lx.word_seq(written, reading) if reading and any(is_kanji(c) for c in written) else None

        def rank(e):
            kana_only = written not in e.kanji
            uk = any("uk" in s.misc for s in e.senses[:2])
            common = 0 if e.priority <= 24 else (1 if e.priority <= 48 else 2)   # とき: 時, not 朱鷺 (ibis)
            jlpt = lx.jlpt.get(e.seq)                                          # 立つ (N5) before 建つ (N4)
            return (0 if e.seq == jl else 1, common, -(jlpt.level if jlpt else 0),
                    0 if (not kana_only or uk or not e.kanji) else 1, e.priority)
        out.sort(key=rank)
        return out

    # ------------------------------------------------------------------ senses
    def best_sense(self, e, written: str, reading: str | None, en: str, ru: str | None, pos_hint: str = "",
                   avoid: frozenset = frozenset()):
        enb = en_bag(en)
        enl = " " + en.lower() + " "
        best, best_s = None, -1e9
        en_senses = [(i, s) for i, s in enumerate(e.senses) if s.en]
        for rank_i, (i, s) in enumerate(en_senses):
            if s.stagk and written not in s.stagk and written in e.kanji:
                continue
            if s.stagr and reading and reading not in s.stagr:
                continue
            score = -0.12 * rank_i
            hit, words = 0.0, set()
            for g in s.en:
                core = PAREN_RE.sub("", g).strip().lower()
                gb = en_bag(core)
                if not gb:
                    continue
                share = len(gb & (enb - avoid)) / len(gb)
                fb = en_bag(g.lower())          # "to tell (a lie)": the bracket is often the key word
                if fb != gb:
                    share = max(share, 0.8 * len(fb & (enb - avoid)) / len(fb))
                if len(core) > 3 and (" " + core + " ") in enl and not (gb & avoid):
                    share = max(share, 1.2)
                if share > hit:
                    hit, words = share, (gb | fb) & enb
            score += 1.5 * hit
            if set(s.misc) & BAD_MISC and hit == 0:
                score -= 1.0
            if pos_hint and s.pos:
                if pos_hint == "v" and not any(p.startswith("v") for p in s.pos):
                    score -= 0.6
                elif pos_hint == "n" and not any(p.startswith("n") or p == "pn" for p in s.pos):
                    score -= 0.4
                elif pos_hint == "adj" and not any(p.startswith("adj") for p in s.pos):
                    score -= 0.4
                elif pos_hint == "adv" and not any(p.startswith("adv") for p in s.pos):
                    score -= 0.3
            if score > best_s:
                best, best_s = (i, s, hit, words), score
        en_txt = _short(_gloss_text(best[1].en)) if best else ""
        matched = bool(best and best[2] > 0)
        # Russian senses are separate blocks in JMdict: pick the one that matches the RU sentence.
        ru_txt = ""
        ru_senses = [s for s in e.senses if s.ru and not (s.stagr and reading and reading not in s.stagr)
                     and not (s.stagk and written in e.kanji and written not in s.stagk)]
        if ru_senses:
            rb = ru_bag(ru) if ru else set()
            pick, pick_s = None, -1e9
            for j, s in enumerate(ru_senses):
                if any("(ономат.)" in g for g in s.ru) and not any("on-mim" in m for m in s.misc):
                    continue          # JMdict glitch: onomatopoeia glosses attached to the wrong entry
                cleaned = [clean_ru(g) for g in s.ru]
                cleaned = [c for c in cleaned if c and RU_RE.search(PAREN_RE.sub("", c).lower())]  # not just "(связ.:)"
                if not cleaned:
                    continue
                hit = max((len(ru_bag(c) & rb) / max(1, len(ru_bag(c))) for c in cleaned), default=0)
                sc = 1.5 * hit - 0.1 * j
                if sc > pick_s:
                    pick, pick_s = cleaned, sc
            if pick:
                ru_txt = _short("; ".join(pick), ru=True)
            # without a Russian sentence to check against, only trust the Russian of the main sense
            if not ru and best and best[0] > 0 and best[2] > 0:
                ru_txt = ""
        return en_txt, ru_txt, matched, (best[3] if best else set())

    def gloss(self, written: str, reading: str | None, en: str, ru: str | None, pos_hint: str = "",
              avoid: frozenset = frozenset()):
        """(en, ru, matched, matched_words, reading) for a word in a sentence; None if JMdict doesn't know it.

        `avoid`: translation words already explained by other words of the sentence (覚える must
        not take "thought" when 思う is right there)."""
        key = (written, reading, en, ru, pos_hint, avoid)
        if key in self.cache:
            return self.cache[key]
        best = None
        cands = self.entries(written, reading)
        if pos_hint:                     # a verb in the sentence wants a verb entry
            pref = {"v": ("v",), "adj": ("adj",), "n": ("n", "pn"), "adv": ("adv",)}[pos_hint]
            fit = [e for e in cands if any(p.startswith(pref) for s in e.senses[:3] for p in s.pos)]
            cands = fit or cands
        kana = not any(is_kanji(c) for c in written)
        for k, e in enumerate(cands[:8 if kana else 4]):
            en_t, ru_t, matched, words = self.best_sense(e, written, reading, en, ru, pos_hint, avoid)
            if not en_t:
                continue
            rd = reading if (reading and (written not in e.kanji or reading in e.readings_for(written))) else \
                (e.readings_for(written) or e.readings or [""])[0]
            if best is None or (matched and not best[2]):
                best = (en_t, ru_t, matched, frozenset(words), rd)
            if matched or (k >= 1 and not kana):
                break
        self.cache[key] = best
        return best

    # ------------------------------------------------------------------ sentence glossary
    def expression_at(self, toks, i):
        """Longest JMdict set expression (2-4 tokens) starting at token i: (end, form, reading)."""
        lx = self.lx
        t0 = toks[i]
        # verb/adjective + auxiliary spans are grammar (ついてる, しまった), and so are そうだ / ようだ
        if t0.p1 in ("動詞", "形容詞") or t0.p2 in ("助動詞語幹",) or t0.p1 not in CONTENT_P1:
            return None
        for n in (4, 3, 2):
            j = i + n
            if j > len(toks):
                continue
            span = toks[i:j]
            if any(t.p1 in ("補助記号", "記号") for t in span):
                continue
            tail_func = span[-1].p1 in ("助動詞", "助詞")
            for last_base in (False, True):
                form = "".join(t.s for t in span[:-1]) + (span[-1].b if last_base else span[-1].s)
                reading = "".join(t.r for t in span[:-1]) + (span[-1].rb if last_base else span[-1].r)
                for cand in (form, reading):
                    for seq in lx.form_entries.get(cand, [])[:3]:
                        e = lx.jmdict.get(seq)
                        if not e:
                            continue
                        if not any("exp" in s.pos or "adv" in s.pos or "int" in s.pos for s in e.senses[:2]):
                            continue
                        if tail_func and ((e.priority > 24 and not any(is_kanji(c) for c in cand))
                                          or not any("adv" in s.pos for s in e.senses[:2])):
                            continue      # 後で yes; random noun+particle no
                        if cand == reading and kata_to_hira(reading) not in e.readings:
                            continue
                        return j, cand, reading
        return None

    def _units(self, s):
        """Content words of a sentence as (written, reading, hint, surface, is_expression)."""
        toks = s.toks
        out, seen = [], set()
        i = 0
        while i < len(toks):
            t = toks[i]
            expr = self.expression_at(toks, i)
            if expr:
                j, form, reading = expr
                if form not in seen and self.entries(form, reading):
                    seen.add(form)
                    out.append((form, reading, "", None, True))
                    i = j
                    continue
            i += 1
            if t.p1 not in CONTENT_P1 or t.p2 == "数詞" or (t.p1 == "接続詞" and len(t.s) == 1):
                continue
            if t.p2 == "固有名詞" and not any(is_kanji(c) for c in t.s):
                continue          # katakana names
            if t.p2 == "非自立可能" and t.p1 in ("動詞", "形容詞", "名詞") or t.s in FORMAL or t.p2 == "助動詞語幹":
                continue          # いる/ある/こと/もの used as auxiliaries
            verbish = t.p1 in ("動詞", "形容詞")
            written = t.b if verbish else t.s
            reading = t.rb if verbish else t.r
            reading = READING_FIX.get(written, reading)
            if written in seen or (len(written) == 1 and not any(is_kanji(c) for c in written)):
                continue
            if (not any(is_kanji(c) for c in written) and len(written) <= 2 and not all("ァ" <= c <= "ヺ" or c == "ー" for c in written)
                    and not self.lx.word_level(written, reading)):
                continue          # stray kana fragments (いな in やいなや)
            hint = {"動詞": "v", "形容詞": "adj", "名詞": "n", "形状詞": "adj", "副詞": "adv"}.get(t.p1, "")
            if not self.entries(written, reading) and verbish and t.l:
                written, reading = t.l.split("-")[0], None
            seen.add(written)
            out.append((written, reading, hint, t.s if verbish and t.s != t.b else None, False))
        return out

    def words(self, s, limit: int = 9) -> list[dict]:
        """Glossary of the sentence's content words, each in the sense it has here."""
        units = self._units(s)[:limit]
        # pass 1: each word on its own
        first = [self.gloss(w, r, s.en, s.ru, h) for w, r, h, _, _ in units]
        out = []
        for k, ((w, r, h, surface, expr), g) in enumerate(zip(units, first)):
            if not g:
                continue
            # pass 2: translation words claimed by the *other* words are off-limits for this one
            # (only words of the same part of speech compete: 思う vs 覚える for "thought", but 嘘 + つく
            # may both point at "lie")
            others = frozenset().union(*(o[3] for m, o in enumerate(first) if o and m != k and units[m][2] == h))
            if g[3] & others:
                g = self.gloss(w, r, s.en, s.ru, h, avoid=others) or g
            rd = g[4] if any(is_kanji(c) for c in w) else ""
            item = {"w": w, "r": READING_FIX.get(w, rd), "g": g[0], "gr": g[1]}
            if surface:
                item["s"] = surface          # as it appears in the sentence (読ん -> 読む)
            if expr:
                item["x"] = 1
            out.append(item)
        return out
