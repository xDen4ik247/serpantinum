"""Tatoeba JA-EN(-RU) sentence pairs, filtered and tokenized with UniDic.

Tatoeba (https://tatoeba.org) sentences are CC BY 2.0 FR; each item keeps the
sentence ids so attribution can be shown.  Tokenization uses fugashi +
unidic-lite (build-time only, from ~/.venvs/jp-quiz).
"""

from __future__ import annotations

import bz2
import pickle
import re
import tarfile
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

from jpquiz.kana import kata_to_hira, is_kanji, is_kana

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"
CACHE = ROOT / "data" / "cache"

BAD_TAGS = {
    "@needs native check", "not a sentence", "@possible copyright infringement",
    "@change", "@check translation", "Classical Japanese (Bungo)", "old kana",
    "dialectal", "old-fashioned", "@delete", "@check", "proverb", "translated-proverb",
    "@needs native check (pronunciation)", "Osaka-ben", "Kansai-ben", "@fixme",
    "not for WWWJDIC", "@not a sentence", "humour", "joke", "poetry", "slang",
}


@dataclass
class Tok:
    s: str        # surface
    b: str        # base / dictionary form as written (orthBase)
    l: str        # UniDic lemma (normalized, may carry -suffix)
    p1: str
    p2: str
    p3: str
    ct: str       # conjugation type, e.g. 五段-カ行
    cf: str       # conjugation form, e.g. 連用形-促音便
    r: str        # reading of the surface (hiragana)
    rb: str       # reading of the base form (hiragana)

    @property
    def is_content(self) -> bool:
        return self.p1 in ("名詞", "動詞", "形容詞", "形状詞", "副詞", "代名詞", "連体詞", "感動詞", "接続詞")


@dataclass
class Sentence:
    id: int
    ja: str
    en: str
    en_id: int
    ru: str | None
    ru_id: int | None
    owner: str
    tags: set
    toks: list[Tok]


def _read_tsv_bz2(path: Path):
    with bz2.open(path, "rt", encoding="utf-8") as f:
        for line in f:
            yield line.rstrip("\n").split("\t")


_ALLOWED = re.compile(r"^[぀-ヿ㐀-䶿一-鿿々〆ー、。？！「」・…０-９]+$")


def _clean_en(s: str) -> str:
    return s.strip()


def load_pairs() -> list[dict]:
    """Japanese sentences that have a direct English translation."""
    tags = defaultdict(set)
    for row in _read_tsv_bz2(RAW / "jpn_tags.tsv.bz2"):
        if len(row) >= 2:
            tags[int(row[0])].add(row[1])
    jpn = {}
    for row in _read_tsv_bz2(RAW / "jpn_sentences_detailed.tsv.bz2"):
        sid, lang, text, owner = int(row[0]), row[1], row[2], row[3]
        jpn[sid] = (text, owner)
    links_en = defaultdict(list)
    for a, b in _read_tsv_bz2(RAW / "jpn-eng_links.tsv.bz2"):
        links_en[int(a)].append(int(b))
    links_ru = defaultdict(list)
    for a, b in _read_tsv_bz2(RAW / "jpn-rus_links.tsv.bz2"):
        links_ru[int(a)].append(int(b))
    need_en = {i for v in links_en.values() for i in v}
    need_ru = {i for v in links_ru.values() for i in v}
    eng = {}
    for row in _read_tsv_bz2(RAW / "eng_sentences.tsv.bz2"):
        i = int(row[0])
        if i in need_en:
            eng[i] = row[2]
    rus = {}
    for row in _read_tsv_bz2(RAW / "rus_sentences.tsv.bz2"):
        i = int(row[0])
        if i in need_ru:
            rus[i] = row[2]
    out = []
    for sid, (text, owner) in jpn.items():
        if sid not in links_en:
            continue
        if tags.get(sid, set()) & BAD_TAGS:
            continue
        ens = sorted(i for i in links_en[sid] if i in eng)
        if not ens:
            continue
        # The lowest id is usually the original pair (Tanaka corpus) -> most literal.
        en_id = ens[0]
        rus_ids = sorted(i for i in links_ru.get(sid, []) if i in rus)
        out.append(dict(id=sid, ja=text, owner=owner, tags=tags.get(sid, set()),
                        en=_clean_en(eng[en_id]), en_id=en_id,
                        ru=rus[rus_ids[0]] if rus_ids else None,
                        ru_id=rus_ids[0] if rus_ids else None))
    return out


def prefilter(p: dict) -> bool:
    ja = p["ja"]
    if not (5 <= len(ja) <= 34):
        return False
    if not _ALLOWED.match(ja):
        return False
    if ja.count("「") != ja.count("」"):
        return False
    if not (ja.endswith("。") or ja.endswith("？") or ja.endswith("！")):
        return False
    en = p["en"]
    if len(en) > 110 or len(en) < 3:
        return False
    if "\"" in en and en.count("\"") % 2:
        return False
    return True


def tokenize_all(pairs: list[dict]) -> list[Sentence]:
    import fugashi
    tagger = fugashi.Tagger()
    out = []
    for p in pairs:
        toks = []
        for w in tagger(p["ja"]):
            f = w.feature
            if f.pos1 is None:
                toks = None
                break
            toks.append(Tok(
                s=w.surface, b=f.orthBase or w.surface, l=(f.lemma or w.surface),
                p1=f.pos1, p2=f.pos2 or "*", p3=f.pos3 or "*",
                ct=f.cType or "*", cf=f.cForm or "*",
                r=kata_to_hira(f.kana or ""), rb=kata_to_hira(f.kanaBase or ""),
            ))
        if not toks:
            continue
        out.append(Sentence(p["id"], p["ja"], p["en"], p["en_id"], p["ru"], p["ru_id"],
                            p["owner"], p["tags"], toks))
    return out


def load_corpus(force: bool = False) -> list[Sentence]:
    path = CACHE / "corpus.pkl"
    if path.exists() and not force:
        return pickle.load(open(path, "rb"))
    pairs = [p for p in load_pairs() if prefilter(p)]
    sents = tokenize_all(pairs)
    pickle.dump(sents, open(path, "wb"), protocol=pickle.HIGHEST_PROTOCOL)
    return sents


if __name__ == "__main__":
    import time
    t = time.time()
    sents = load_corpus(force=True)
    print(len(sents), "sentences in", round(time.time() - t, 1), "s")
    for s in sents[:5]:
        print(s.id, s.ja, "|", s.en, "|", s.ru)
        print("   ", " ".join(f"{t.s}/{t.p1}" for t in s.toks))
