"""Dictionary data for the content build.

Sources (all downloaded by build/fetch.sh into data/raw/):
  * JMdict (full, multilingual)      EDRDG, CC BY-SA 4.0
  * KANJIDIC2                        EDRDG, CC BY-SA 4.0
  * KRADFILE / KRADFILE2             EDRDG, CC BY-SA 4.0
  * JLPT vocab lists (J. Waller / tanos.co.uk, CC BY) with JMdict ids added
    by stephenmk/yomitan-jlpt-vocab (CC BY-SA 4.0)
  * JLPT kanji levels (J. Waller via davidluzgouveia/kanji-data, field
    `jlpt_new` only)
"""

from __future__ import annotations

import csv
import gzip
import json
import pickle
import re
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from xml.etree import ElementTree as ET

from jpquiz.kana import kata_to_hira, is_kanji

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"
CACHE = ROOT / "data" / "cache"
CACHE.mkdir(parents=True, exist_ok=True)


@dataclass
class Sense:
    pos: list[str]
    misc: list[str]
    en: list[str]
    ru: list[str]
    stagk: list[str] = field(default_factory=list)
    stagr: list[str] = field(default_factory=list)


@dataclass
class Entry:
    seq: int
    kanji: list[str]
    kanji_info: dict[str, list[str]]
    kanji_pri: dict[str, list[str]]
    readings: list[str]
    reading_restr: dict[str, list[str]]
    reading_info: dict[str, list[str]]
    reading_pri: dict[str, list[str]]
    senses: list[Sense]

    def readings_for(self, keb: str) -> list[str]:
        out = []
        for r in self.readings:
            restr = self.reading_restr.get(r)
            if "nokanji" in self.reading_info.get(r, []):
                continue
            if not restr or keb in restr:
                out.append(r)
        return out

    @property
    def priority(self) -> int:
        """0 = very common ... larger = rarer (rough rank from JMdict pri tags)."""
        best = 99
        for tags in list(self.kanji_pri.values()) + list(self.reading_pri.values()):
            for t in tags:
                if t.startswith("nf"):
                    best = min(best, int(t[2:]))
                elif t in ("news1", "ichi1", "spec1", "gai1"):
                    best = min(best, 24)
                elif t in ("news2", "ichi2", "spec2", "gai2"):
                    best = min(best, 48)
        return best

    def en_gloss(self, n_senses: int = 2, n_gloss: int = 3) -> str:
        parts = []
        for s in self.senses[:n_senses]:
            if s.en:
                parts.append("; ".join(s.en[:n_gloss]))
        return " / ".join(parts)

    def ru_gloss(self, n_gloss: int = 3) -> str:
        for s in self.senses:
            if s.ru:
                return "; ".join(s.ru[:n_gloss])
        return ""

    def pos_set(self) -> set[str]:
        out = set()
        for s in self.senses:
            out.update(s.pos)
        return out


_ENT_RE = re.compile(r"&([A-Za-z0-9_.-]+);")
_XML_STD = {"amp", "lt", "gt", "quot", "apos"}


def _parse_jmdict() -> dict[int, Entry]:
    raw = gzip.open(RAW / "JMdict.gz", "rt", encoding="utf-8").read()
    # Drop the DTD and turn entity references (&v5k;) into their bare codes.
    start = raw.index("<JMdict>")
    body = raw[start:]
    body = _ENT_RE.sub(lambda m: m.group(0) if m.group(1) in _XML_STD else m.group(1), body)
    root = ET.fromstring(body)
    xml_lang = "{http://www.w3.org/XML/1998/namespace}lang"
    out: dict[int, Entry] = {}
    for e in root.iter("entry"):
        seq = int(e.findtext("ent_seq"))
        kanji, kinfo, kpri = [], {}, {}
        for k in e.findall("k_ele"):
            keb = k.findtext("keb")
            kanji.append(keb)
            kinfo[keb] = [x.text for x in k.findall("ke_inf")]
            kpri[keb] = [x.text for x in k.findall("ke_pri")]
        readings, rrestr, rinfo, rpri = [], {}, {}, {}
        for r in e.findall("r_ele"):
            reb = r.findtext("reb")
            readings.append(reb)
            rrestr[reb] = [x.text for x in r.findall("re_restr")]
            rinfo[reb] = [x.text for x in r.findall("re_inf")]
            if r.find("re_nokanji") is not None:
                rinfo[reb].append("nokanji")
            rpri[reb] = [x.text for x in r.findall("re_pri")]
        senses = []
        last_pos: list[str] = []
        for s in e.findall("sense"):
            pos = [x.text for x in s.findall("pos")] or last_pos
            last_pos = pos
            en, ru = [], []
            for g in s.findall("gloss"):
                lang = g.get(xml_lang, "eng")
                if lang == "eng":
                    en.append(g.text or "")
                elif lang == "rus":
                    ru.append(g.text or "")
            senses.append(Sense(
                pos=pos,
                misc=[x.text for x in s.findall("misc")],
                en=en, ru=ru,
                stagk=[x.text for x in s.findall("stagk")],
                stagr=[x.text for x in s.findall("stagr")],
            ))
        # Keep senses that have at least an English or Russian gloss.
        out[seq] = Entry(seq, kanji, kinfo, kpri, readings, rrestr, rinfo, rpri,
                         [s for s in senses if s.en or s.ru])
    return out


def load_jmdict() -> dict[int, Entry]:
    p = CACHE / "jmdict.pkl"
    if p.exists():
        return pickle.load(open(p, "rb"))
    d = _parse_jmdict()
    pickle.dump(d, open(p, "wb"), protocol=pickle.HIGHEST_PROTOCOL)
    return d


@dataclass
class Kanji:
    char: str
    strokes: int
    grade: int | None
    freq: int | None
    jlpt: int | None          # new JLPT level 5..1 (Waller lists)
    on: list[str]             # katakana in KANJIDIC2 -> stored as hiragana
    kun: list[str]            # e.g. "た.べる" -> "たべる" stem info kept separately
    kun_raw: list[str]
    meanings: list[str]
    radicals: list[str] = field(default_factory=list)


def load_kanjidic() -> dict[str, Kanji]:
    p = CACHE / "kanjidic.pkl"
    if p.exists():
        return pickle.load(open(p, "rb"))
    jlpt_new = {}
    kd = json.load(open(RAW / "jlpt" / "kanji-data.json", encoding="utf-8"))
    for ch, v in kd.items():
        if v.get("jlpt_new"):
            jlpt_new[ch] = int(v["jlpt_new"])
    root = ET.parse(gzip.open(RAW / "kanjidic2.xml.gz")).getroot()
    out = {}
    for c in root.iter("character"):
        ch = c.findtext("literal")
        misc = c.find("misc")
        strokes = int(misc.findtext("stroke_count"))
        grade = misc.findtext("grade")
        freq = misc.findtext("freq")
        on, kun_raw, meanings = [], [], []
        rm = c.find("reading_meaning")
        if rm is not None:
            for g in rm.findall("rmgroup"):
                for r in g.findall("reading"):
                    if r.get("r_type") == "ja_on":
                        on.append(kata_to_hira(r.text))
                    elif r.get("r_type") == "ja_kun":
                        kun_raw.append(r.text)
                for m in g.findall("meaning"):
                    if m.get("m_lang") is None:
                        meanings.append(m.text)
        kun = sorted({k.replace("-", "").split(".")[0] for k in kun_raw if k.replace("-", "")})
        out[ch] = Kanji(ch, strokes, int(grade) if grade else None, int(freq) if freq else None,
                        jlpt_new.get(ch), on, kun, kun_raw, meanings)
    # radicals / components
    for fn in ("kradfile", "kradfile2"):
        for line in open(RAW / "krad" / fn, encoding="euc_jp", errors="ignore"):
            if line.startswith("#") or " : " not in line:
                continue
            ch, comps = line.strip().split(" : ", 1)
            if ch in out:
                out[ch].radicals = comps.split()
    pickle.dump(out, open(p, "wb"), protocol=pickle.HIGHEST_PROTOCOL)
    return out


@dataclass
class JlptWord:
    seq: int
    kana: str
    kanji: str
    level: int
    definition: str


def load_jlpt_vocab() -> dict[int, JlptWord]:
    """jmdict_seq -> word; when a word is on several lists the easiest level wins."""
    out: dict[int, JlptWord] = {}
    for level in (1, 2, 3, 4, 5):
        with open(RAW / "jlpt" / f"vocab_n{level}.csv", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                if not row["jmdict_seq"].strip():
                    continue
                seq = int(row["jmdict_seq"])
                w = JlptWord(seq, row["kana"], row["kanji"], level, row["waller_definition"])
                if seq not in out or out[seq].level < level:
                    out[seq] = w
    return out


class Lexicon:
    """Indexes over the dictionaries used by item generation."""

    def __init__(self):
        self.jmdict = load_jmdict()
        self.kanji = load_kanjidic()
        self.jlpt = load_jlpt_vocab()
        self.keb_readings: dict[str, set[str]] = defaultdict(set)
        self.reb_kebs: dict[str, set[str]] = defaultdict(set)
        self.form_entries: dict[str, list[int]] = defaultdict(list)
        self.all_forms: set[str] = set()
        for seq, e in self.jmdict.items():
            for k in e.kanji:
                rs = e.readings_for(k)
                self.keb_readings[k].update(rs)
                for r in rs:
                    self.reb_kebs[r].add(k)
                self.form_entries[k].append(seq)
                self.all_forms.add(k)
            for r in e.readings:
                self.form_entries[r].append(seq)
                self.all_forms.add(r)
        # (written form, reading) -> JLPT level, and written form -> level
        self.jlpt_by_form_reading: dict[tuple[str, str], int] = {}
        self.jlpt_by_form: dict[str, int] = {}
        for seq, w in self.jlpt.items():
            e = self.jmdict.get(seq)
            forms = set()
            if w.kanji:
                forms.add(w.kanji)
            forms.add(w.kana)
            if e:
                forms.update(e.kanji)
                forms.update(e.readings)
            for f in forms:
                key = (f, w.kana)
                if key not in self.jlpt_by_form_reading or self.jlpt_by_form_reading[key] < w.level:
                    self.jlpt_by_form_reading[key] = w.level
                if f not in self.jlpt_by_form or self.jlpt_by_form[f] < w.level:
                    self.jlpt_by_form[f] = w.level
        self.seq_by_form_reading: dict[tuple[str, str], int] = {}
        for seq, w in self.jlpt.items():
            e = self.jmdict.get(seq)
            forms = {w.kana} | ({w.kanji} if w.kanji else set()) | (set(e.kanji) if e else set())
            for f in forms:
                self.seq_by_form_reading.setdefault((f, w.kana), seq)

    def kanji_level(self, ch: str) -> int | None:
        k = self.kanji.get(ch)
        return k.jlpt if k else None

    def word_level(self, written: str, reading: str | None) -> int | None:
        if reading is not None:
            lv = self.jlpt_by_form_reading.get((written, reading))
            if lv is not None:
                return lv
        return self.jlpt_by_form.get(written)

    def word_seq(self, written: str, reading: str) -> int | None:
        return self.seq_by_form_reading.get((written, reading))

    def valid_readings(self, written: str) -> set[str]:
        return self.keb_readings.get(written, set())

    def is_word(self, s: str) -> bool:
        return s in self.all_forms


if __name__ == "__main__":
    import time
    t = time.time()
    lx = Lexicon()
    print(f"jmdict {len(lx.jmdict)} kanji {len(lx.kanji)} jlpt {len(lx.jlpt)} in {time.time()-t:.1f}s")
    for w in ("学校", "行く", "今日", "上手", "何", "時間"):
        print(w, lx.valid_readings(w), lx.word_level(w, None))
    e = lx.jmdict[1206730]
    print(e.kanji, e.readings, e.en_gloss(), "|", e.ru_gloss())
    print(lx.kanji["待"])
