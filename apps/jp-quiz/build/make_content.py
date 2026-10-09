"""Build data/content.db from the raw sources.

    ~/.venvs/jp-quiz/bin/python -m build.make_content

Needs data/raw/ (see build/fetch.sh) and the build-only packages fugashi,
unidic-lite and numpy.  The app itself only reads the finished SQLite file.
"""

from __future__ import annotations

import json
import random
import sqlite3
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

from build.lexicon import Lexicon
from build.corpus import load_corpus
from build.sentpool import build_pool
from build.grammar import GPS
from build import gen

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "data" / "content.db"
CONTENT_VERSION = 1

CAPS = {  # kind: (total cap, per-kc cap)
    "particle": (7000, 500), "conj": (4500, 380), "gmean": (3000, 400), "voice": (1500, 500),
    "form": (1800, 700), "order": (3000, 300), "odd": (1000, 200), "kread": (3500, 5),
    "kwrite": (2500, 4), "vocab": (4500, 6), "meaning": (4000, 1), "produce": (2600, 1),
}
NAMES_SHARE = 0.18


class Similarity:
    """PPMI co-occurrence vectors over content lemmas (orthBase forms) for related-word distractors."""

    def __init__(self, sents, vocab_limit=9000, ctx_limit=2500):
        cnt = Counter()
        docs = []
        for s in sents:
            ws = {t.b for t in s.toks if t.p1 in ("名詞", "動詞", "形容詞", "形状詞") and t.p2 not in ("固有名詞", "数詞", "非自立可能")}
            docs.append(ws)
            cnt.update(ws)
        vocab = [w for w, _ in cnt.most_common(vocab_limit)]
        ctx = [w for w, _ in cnt.most_common(ctx_limit)]
        self.vi = {w: i for i, w in enumerate(vocab)}
        ci = {w: i for i, w in enumerate(ctx)}
        M = np.zeros((len(vocab), len(ctx)), dtype=np.float32)
        for ws in docs:
            rows = [self.vi[w] for w in ws if w in self.vi]
            cols = [ci[w] for w in ws if w in ci]
            if rows and cols:
                M[np.ix_(rows, cols)] += 1
        total = M.sum()
        pw = M.sum(1, keepdims=True) / total
        pc = M.sum(0, keepdims=True) / total
        with np.errstate(divide="ignore", invalid="ignore"):
            pmi = np.log((M / total) / (pw * pc))
        pmi[~np.isfinite(pmi)] = 0
        pmi = np.maximum(pmi, 0)
        norms = np.linalg.norm(pmi, axis=1, keepdims=True)
        norms[norms == 0] = 1
        self.V = pmi / norms

    def neighbors(self, word, candidates):
        i = self.vi.get(word)
        if i is None:
            return None
        idx = [(c, self.vi[c]) for c in candidates if c in self.vi]
        if not idx:
            return None
        sims = self.V[[j for _, j in idx]] @ self.V[i]
        order = np.argsort(-sims)
        # skip the most similar few (likely synonyms), keep related-but-different words
        ranked = [idx[k][0] for k in order]
        return ranked[2:60]


def main():
    t0 = time.time()
    rng = random.Random(20261007)
    lx = Lexicon()
    sents = load_corpus()
    print(f"[{time.time()-t0:.0f}s] corpus {len(sents)}", flush=True)
    pool = build_pool(lx, sents)
    lvl = Counter(p.level for p in pool)
    print(f"[{time.time()-t0:.0f}s] pool {len(pool)} {dict(lvl)}", flush=True)
    real = gen.RealForms(lx)
    print(f"[{time.time()-t0:.0f}s] real forms {len(real.forms)}", flush=True)
    pmodel = gen.ParticleModel(sents)
    sim = Similarity(sents)
    print(f"[{time.time()-t0:.0f}s] models ready", flush=True)

    raw = defaultdict(list)
    for it in gen.gen_particles(pool, pmodel, rng):
        raw["particle"].append(it)
    print(f"[{time.time()-t0:.0f}s] particle {len(raw['particle'])}", flush=True)
    for it in gen.gen_conj(pool, real, rng):
        raw["conj"].append(it)
    for it in gen.gen_gmean(pool, rng):
        raw["gmean"].append(it)
    for it in gen.gen_voice(pool, rng):
        raw["voice"].append(it)
    for it in gen.gen_form(pool, rng):
        raw["form"].append(it)
    for it in gen.gen_order(pool, rng):
        raw["order"].append(it)
    for it in gen.gen_odd(pool, real, rng):
        raw["odd"].append(it)
    print(f"[{time.time()-t0:.0f}s] grammar " + " ".join(f"{k}={len(raw[k])}" for k in ("conj", "gmean", "voice", "form", "order", "odd")), flush=True)
    for it in gen.gen_kanji(pool, lx, real, rng):
        raw[it["kind"]].append(it)
    print(f"[{time.time()-t0:.0f}s] kread={len(raw['kread'])} kwrite={len(raw['kwrite'])}", flush=True)
    for it in gen.gen_vocab(pool, lx, rng, sim):
        raw["vocab"].append(it)
    print(f"[{time.time()-t0:.0f}s] vocab={len(raw['vocab'])}", flush=True)
    for it in gen.gen_meaning(pool, rng):
        raw[it["kind"]].append(it)
    print(f"[{time.time()-t0:.0f}s] meaning={len(raw['meaning'])} produce={len(raw['produce'])}", flush=True)

    # ---- caps and balance
    final = []
    for kind, items in raw.items():
        total_cap, kc_cap = CAPS[kind]
        rng.shuffle(items)
        # interleave levels so caps keep all three levels
        per_kc = Counter()
        names = 0
        kept = []
        by_level = defaultdict(list)
        for it in items:
            by_level[it["level"]].append(it)
        queues = [by_level[l] for l in (5, 4, 3)]
        while any(queues) and len(kept) < total_cap:
            for q in queues:
                if not q or len(kept) >= total_cap:
                    continue
                it = q.pop()
                if per_kc[it["kc"]] >= kc_cap:
                    continue
                if it["names"] and names >= NAMES_SHARE * total_cap:
                    continue
                per_kc[it["kc"]] += 1
                names += it["names"]
                kept.append(it)
        final.extend(kept)
        print(f"  {kind:9s} raw {len(items):6d} kept {len(kept):5d}  levels {dict(Counter(i['level'] for i in kept))}")

    write_db(final, lx)
    print(f"[{time.time()-t0:.0f}s] wrote {OUT} with {len(final)} items")


def kc_label(kc: str, lx):
    kind, _, rest = kc.partition(":")
    if kind == "pt":
        q, _, usage = rest.partition(":")
        names = {"time": "time", "dest": "destination", "exist": "existence", "recip": "recipient", "become": "result",
                 "means": "means", "place": "place of action", "scope": "scope", "path": "path", "leave": "leaving",
                 "stative": "likes/abilities", "qword": "after question words", "relcl": "in modifying clauses",
                 "with": "together with", "and": "and (list)", "quote": "quotation", "gen": ""}
        names_ru = {"time": "время", "dest": "направление", "exist": "нахождение", "recip": "адресат",
                    "become": "результат", "means": "средство", "place": "место действия", "scope": "рамки",
                    "path": "путь", "leave": "откуда", "stative": "объект чувства/умения", "qword": "после вопр. слов",
                    "relcl": "в придаточном", "with": "вместе с", "and": "и (перечисление)", "quote": "цитата", "gen": ""}
        lab = f"{q} · {names.get(usage, usage)}" if names.get(usage) else q
        lab_ru = f"{q} · {names_ru.get(usage, usage)}" if names_ru.get(usage) else q
        return lab, lab_ru
    if kind == "gp":
        g = next((g for g in GPS if g.id == rest), None)
        return (f"{g.name} — {g.en}", f"{g.name} — {g.ru}") if g else (rest, rest)
    if kind == "conj":
        from build.gen import TE_RULE
        return (f"te/ta-form: {TE_RULE.get(rest, (rest,))[0]}", f"て/た-форма: {TE_RULE.get(rest, ('', rest))[1]}")
    if kind == "read":
        return (f"reading of {rest}", f"чтение {rest}")
    if kind == "write":
        return (f"writing {rest}", f"написание {rest}")
    if kind == "use":
        return (f"word {rest}", f"слово {rest}")
    if kind == "sent":
        return ("sentence", "предложение")
    return (kc, kc)


def write_db(items, lx):
    if OUT.exists():
        OUT.unlink()
    db = sqlite3.connect(OUT)
    db.executescript("""
    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE items(id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL, kind TEXT NOT NULL, level INTEGER NOT NULL,
                       kc TEXT NOT NULL, tags TEXT NOT NULL, cat TEXT NOT NULL, seed REAL NOT NULL, sid INTEGER,
                       flags INTEGER NOT NULL DEFAULT 0, payload TEXT NOT NULL);
    CREATE INDEX items_kc ON items(kc);
    CREATE TABLE kcs(kc TEXT PRIMARY KEY, label TEXT, label_ru TEXT, level INTEGER, n_items INTEGER);
    CREATE TABLE grammar(id TEXT PRIMARY KEY, level INTEGER, ord INTEGER, name TEXT, en TEXT, ru TEXT,
                         explain_en TEXT, explain_ru TEXT, diff REAL);
    """)
    rows = []
    kc_n = Counter()
    kc_level = {}
    for it in items:
        flags = (1 if it["names"] else 0)
        rows.append((it["key"], it["kind"], it["level"], it["kc"], json.dumps(it["tags"], ensure_ascii=False),
                     it["cat"], it["seed"], it["sid"], flags, json.dumps(it["payload"], ensure_ascii=False, separators=(",", ":"))))
        kc_n[it["kc"]] += 1
        kc_level[it["kc"]] = max(kc_level.get(it["kc"], 0), it["level"])
    db.executemany("INSERT INTO items(key,kind,level,kc,tags,cat,seed,sid,flags,payload) VALUES (?,?,?,?,?,?,?,?,?,?)", rows)
    db.executemany("INSERT INTO kcs VALUES (?,?,?,?,?)",
                   [(kc, *kc_label(kc, lx), kc_level[kc], n) for kc, n in kc_n.items()])
    db.executemany("INSERT INTO grammar VALUES (?,?,?,?,?,?,?,?,?)",
                   [(g.id, g.level, g.order, g.name, g.en, g.ru, g.explain_en, g.explain_ru, g.diff) for g in GPS])
    db.executemany("INSERT INTO meta VALUES (?,?)", [
        ("content_version", str(CONTENT_VERSION)), ("built", time.strftime("%Y-%m-%d %H:%M")),
        ("licenses", "Tatoeba sentences CC BY 2.0 FR (tatoeba.org); JMdict/KANJIDIC2/KRADFILE (EDRDG) CC BY-SA 4.0; "
                     "JLPT lists by Jonathan Waller (tanos.co.uk) CC BY, JMdict ids by stephenmk/yomitan-jlpt-vocab CC BY-SA 4.0"),
    ])
    db.commit()
    db.execute("VACUUM")
    db.close()


if __name__ == "__main__":
    main()
