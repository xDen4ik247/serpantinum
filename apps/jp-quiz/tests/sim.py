"""Synthetic learners for testing the matchmaking engine end to end.

A synthetic content DB is generated with known *true* item difficulties; a
learner with known true skills answers with probability
    P = c + (1 - c) * sigmoid(th_global + th_cat + th_tag - b_true)
optionally improving over time.  The real Engine picks the questions.
"""

from __future__ import annotations

import json
import math
import random
import sqlite3
import tempfile
from pathlib import Path

from jpquiz.engine import Engine, CATS, LEVEL_BASE
from jpquiz.model import GUESS, sigmoid

KINDS = {"particles": ["particle"], "grammar": ["conj", "gmean", "order", "form"], "kanji": ["kread", "kwrite"],
         "vocab": ["vocab"], "reading": ["meaning", "produce"]}
TAGS = {"particles": [f"pt:{p}" for p in "はがをにでともへ"], "grammar": [f"gp:g{i}" for i in range(10)],
        "kanji": [f"k:{c}" for c in "日本人時間学生先年月"], "vocab": [f"w:v{i}" for i in range(12)],
        "reading": ["reading"]}


def make_content(path: Path, n=3000, seed=1):
    rng = random.Random(seed)
    db = sqlite3.connect(path)
    db.executescript("""
    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE items(id INTEGER PRIMARY KEY, key TEXT UNIQUE, kind TEXT, level INTEGER, kc TEXT, tags TEXT, cat TEXT,
                       seed REAL, sid INTEGER, flags INTEGER DEFAULT 0, payload TEXT);
    CREATE TABLE kcs(kc TEXT PRIMARY KEY, label TEXT, label_ru TEXT, level INTEGER, n_items INTEGER);
    CREATE TABLE grammar(id TEXT PRIMARY KEY, level INTEGER, ord INTEGER, name TEXT, en TEXT, ru TEXT,
                         explain_en TEXT, explain_ru TEXT, diff REAL);
    """)
    truth = {}
    rows = []
    for i in range(n):
        cat = rng.choice(CATS)
        kind = rng.choice(KINDS[cat])
        level = rng.choice((5, 4, 3))
        tag = rng.choice(TAGS[cat])
        seed_b = LEVEL_BASE[level] + rng.gauss(0, 0.3)
        b_true = seed_b + rng.gauss(0, 0.4)          # seeds are imperfect
        key = f"syn:{i}"
        truth[key] = (b_true, cat, tag, kind)
        payload = {"choices": ["a", "b", "c", "d"], "sent": [{"t": "x"}], "en": "x", "full": "x"}
        if kind == "order":
            payload = {"tiles": ["A", "B", "C"], "prefix": [], "suffix": [], "en": "x", "full": "ABC"}
        rows.append((key, kind, level, f"kc:{tag}:{i % 7}", json.dumps([tag]), cat, round(seed_b, 3), i, 0,
                     json.dumps(payload)))
    db.executemany("INSERT INTO items(key,kind,level,kc,tags,cat,seed,sid,flags,payload) VALUES (?,?,?,?,?,?,?,?,?,?)", rows)
    db.commit()
    db.close()
    return truth


class Learner:
    def __init__(self, theta=0.3, seed=2, learn_rate=0.0, spread=0.35):
        rng = random.Random(seed)
        self.rng = random.Random(seed + 100)
        self.theta = theta
        self.cat = {c: rng.gauss(0, spread) for c in CATS}
        self.tag = {t: rng.gauss(0, spread) for ts in TAGS.values() for t in ts}
        self.learn_rate = learn_rate

    def p(self, b_true, cat, tag, kind):
        g = GUESS.get(kind, 0.2)
        return g + (1 - g) * sigmoid(self.theta + self.cat[cat] + self.tag[tag] - b_true)

    def answer(self, q, truth):
        key = q["_key"]
        b, cat, tag, kind = truth[key]
        ok = self.rng.random() < self.p(b, cat, tag, kind)
        self.theta += self.learn_rate
        return ok


def effective(eng, learner, truth, probe):
    """Mean learner ability (engine estimate vs truth) over a fixed probe set of items, overall and per category."""
    from jpquiz.model import Model
    est_by_cat, true_by_cat = {}, {}
    for key in probe:
        b, cat, tag, kind = truth[key]
        e = sum(a * eng.model.peek(k)[0] for k, a in Model.design(cat, kind, [tag], key) if not k.startswith("item:"))
        t = learner.theta + learner.cat[cat] + learner.tag[tag]
        est_by_cat.setdefault(cat, []).append(e)
        true_by_cat.setdefault(cat, []).append(t)
    est = sum(sum(v) for v in est_by_cat.values()) / len(probe)
    tru = sum(sum(v) for v in true_by_cat.values()) / len(probe)
    cat_err = sum(abs(sum(est_by_cat[c]) / len(est_by_cat[c]) - sum(true_by_cat[c]) / len(true_by_cat[c]))
                  for c in est_by_cat) / len(est_by_cat)
    return est, tru, cat_err


class Clock:
    def __init__(self, t=1_800_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


def run(learner: Learner, n=600, target=0.75, content_seed=1, tmp: Path | None = None, engine_seed=5):
    tmp = Path(tmp or tempfile.mkdtemp(prefix="jpq-sim-"))
    tmp.mkdir(parents=True, exist_ok=True)
    content = tmp / "content.db"
    if not content.exists():
        truth = make_content(content, seed=content_seed)
    else:
        truth = make_content(tmp / "content2.db", seed=content_seed)
        content = tmp / "content2.db"
    clock = Clock()
    eng = Engine(str(content), str(tmp / f"progress-{engine_seed}-{learner.theta:.2f}.db"), now=clock, seed=engine_seed)
    eng.set_settings({"target": target})
    log = []
    probe = random.Random(99).sample(sorted(truth), 300)
    for i in range(n):
        q = eng.next()
        while q["type"] == "intro":
            q = eng.next()
        it = eng.current["item"]
        q["_key"] = it.key
        b, cat, tag, kind = truth[it.key]
        p_true = learner.p(b, cat, tag, kind)
        ok = learner.answer(q, truth)
        secs = 2.0 + 6.0 * learner.rng.random()
        if kind == "order":
            tiles = eng.current["payload"]["tiles"]
            order = tiles if ok else list(reversed(tiles))
            res = eng.answer(q["qid"], order=order, ms=int(secs * 1000))
        else:
            choice = eng.current["correct"] if ok else (eng.current["correct"] + 1) % 4
            res = eng.answer(q["qid"], choice=choice, ms=int(secs * 1000))
        th_true = learner.theta
        est, true_eff, cat_err = effective(eng, learner, truth, probe)
        log.append({"i": i, "ok": ok, "p_pred": q["p"], "p_true": p_true, "mode": q["mode"], "est": est,
                    "true": true_eff, "theta": th_true, "cat_err": cat_err, "level": it.level, "why": q.get("why")})
        clock.t += secs + 3
        if i % 150 == 149:
            clock.t += 14 * 3600           # sleep: come back next day
    return eng, log, truth
