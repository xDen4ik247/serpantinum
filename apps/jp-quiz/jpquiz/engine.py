"""The quiz engine: matchmaking, spaced repetition, unlocks, game layer, persistence.

How the next question is chosen ("skill-based matchmaking"):
  1. Collect candidates: cards in relearning (answered wrong a few minutes
     ago), cards due for review (memory faded to 90 %), and a stratified random
     sample of unlocked items of all question types.
  2. Predict the chance of success p for each one from the rating model
     (+ a memory adjustment for cards you've seen).
  3. Score = closeness of p to the target (75 % by default, nudged up or down by
     a controller that watches your recent success rate) + bonuses for due
     reviews + penalties for repeats + a little randomness; take the best.
"""

from __future__ import annotations

import json
import math
import random
import sqlite3
import time
from collections import Counter, deque
from datetime import datetime

from jpquiz.model import Model, Comp, GUESS, logit, to_rating, sigmoid
from jpquiz.memory import Card, review, grade_from, memory_shift, retrievability, DAY
from jpquiz import anki
from pathlib import Path

CATS = ("particles", "grammar", "kanji", "vocab", "reading")
CAT_NAMES = {"particles": ("Particles", "Частицы"), "grammar": ("Grammar", "Грамматика"),
             "kanji": ("Kanji", "Кандзи"), "vocab": ("Vocabulary", "Лексика"), "reading": ("Reading", "Чтение")}
LEVEL_BASE = {5: -1.0, 4: 0.0, 3: 1.0}
FAST = {"particle": 4, "conj": 5, "gmean": 7, "voice": 6, "form": 5, "order": 12, "odd": 10, "kread": 4,
        "kwrite": 4, "vocab": 5, "meaning": 8, "produce": 9}
KIND_MIX = {"particle": 1.3, "conj": 1.2, "gmean": 1.0, "voice": 0.5, "form": 0.4, "order": 0.8, "odd": 0.4,
            "kread": 1.0, "kwrite": 0.8, "vocab": 1.0, "meaning": 0.9, "produce": 0.7}
KIND_NAMES = {
    "particle": ("Particle", "Частица"), "conj": ("Conjugation", "Спряжение"), "gmean": ("Grammar meaning", "Значение грамматики"),
    "voice": ("Voice", "Залог"), "form": ("Tense & polarity", "Время и отрицание"), "order": ("並べ替え · word order", "並べ替え · порядок слов"),
    "odd": ("Spot the mistake", "Найди ошибку"), "kread": ("Kanji reading", "Чтение кандзи"), "kwrite": ("Kanji writing", "Написание кандзи"),
    "vocab": ("Word in context", "Слово в контексте"), "meaning": ("What does it mean?", "Что это значит?"),
    "produce": ("Say it in Japanese", "Как сказать по-японски?"),
}
PLACEMENT_N = 12
PLACEMENT_KINDS = ("particle", "conj", "gmean", "kread", "kwrite", "vocab", "meaning")
RANKS = [(-99, "N5…"), (-0.49, "N5"), (0.51, "N4"), (1.51, "N3"), (2.4, "N3+")]
DEFAULT_SETTINGS = {"target": 0.75, "lang": "en", "furigana": False, "sound": True, "auto_advance": True,
                    "daily_goal": 30, "anki_auto": False}


def xp_for_level(level: int) -> int:
    return int(round(100 * (level - 1) ** 1.6))


def level_for_xp(xp: int) -> int:
    lv = 1
    while xp_for_level(lv + 1) <= xp:
        lv += 1
    return lv


def rank_for(theta: float) -> str:
    name = RANKS[0][1]
    for th, n in RANKS:
        if theta >= th:
            name = n
    return name


class Item:
    __slots__ = ("id", "key", "kind", "level", "kc", "tags", "cat", "seed", "sid", "flags", "gps")

    def __init__(self, row):
        self.id, self.key, self.kind, self.level, self.kc, tags, self.cat, self.seed, self.sid, self.flags = row
        self.tags = json.loads(tags)
        self.gps = [t[3:] for t in self.tags if t.startswith("gp:")]


SCHEMA = """
CREATE TABLE IF NOT EXISTS comp(key TEXT PRIMARY KEY, mu REAL, var REAL, n INTEGER, t REAL);
CREATE TABLE IF NOT EXISTS card(kc TEXT PRIMARY KEY, s REAL, d REAL, last REAL, reps INTEGER, lapses INTEGER,
                                state TEXT, due REAL, short_due REAL, last_q INTEGER, last_item TEXT);
CREATE TABLE IF NOT EXISTS answers(id INTEGER PRIMARY KEY, ts REAL, item TEXT, kind TEXT, kc TEXT, cat TEXT,
                                   level INTEGER, correct INTEGER, ms INTEGER, p REAL, target REAL, points INTEGER,
                                   mode TEXT, snap TEXT);
CREATE TABLE IF NOT EXISTS unlock(key TEXT PRIMARY KEY, ts REAL, how TEXT);
CREATE TABLE IF NOT EXISTS days(day TEXT PRIMARY KEY, n INTEGER, correct INTEGER, xp INTEGER);
CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT);
"""


class Engine:
    def __init__(self, content_path: str, progress_path: str, now=time.time, seed: int | None = None):
        self.now = now
        self.rng = random.Random(seed)
        self.cdb = sqlite3.connect(f"file:{content_path}?mode=ro", uri=True)
        self.pdb = sqlite3.connect(progress_path)
        self.pdb.executescript(SCHEMA)
        self._load_content()
        self._load_progress()
        self.current = None
        self.last_answered = None
        self.intro_queue: deque = deque()
        self.outbox = anki.Outbox(Path(progress_path).parent)

    # ------------------------------------------------------------------ loading
    def _load_content(self):
        rows = self.cdb.execute("SELECT id,key,kind,level,kc,tags,cat,seed,sid,flags FROM items").fetchall()
        self.items = [Item(r) for r in rows]
        self.by_key = {it.key: it for it in self.items}
        self.by_kc: dict[str, list[Item]] = {}
        for it in self.items:
            self.by_kc.setdefault(it.kc, []).append(it)
        self.kc_label = {r[0]: (r[1], r[2]) for r in self.cdb.execute("SELECT kc,label,label_ru FROM kcs")}
        self.grammar = {}
        for r in self.cdb.execute("SELECT id,level,ord,name,en,ru,explain_en,explain_ru,diff FROM grammar ORDER BY ord"):
            self.grammar[r[0]] = dict(id=r[0], level=r[1], ord=r[2], name=r[3], en=r[4], ru=r[5],
                                      explain_en=r[6], explain_ru=r[7], diff=r[8])
        self.gp_items = Counter(g for it in self.items for g in it.gps)

    def _load_progress(self):
        comps = {k: Comp(mu, var, n, t) for k, mu, var, n, t in self.pdb.execute("SELECT key,mu,var,n,t FROM comp")}
        self.model = Model(comps)
        self.cards: dict[str, Card] = {}
        self.card_item: dict[str, str] = {}
        for row in self.pdb.execute("SELECT kc,s,d,last,reps,lapses,state,due,short_due,last_q,last_item FROM card"):
            self.cards[row[0]] = Card(*row[1:10])
            self.card_item[row[0]] = row[10]
        self.unlocked = {k for (k,) in self.pdb.execute("SELECT key FROM unlock")}
        kv = dict(self.pdb.execute("SELECT key,value FROM kv").fetchall())
        self.settings = {**DEFAULT_SETTINGS, **json.loads(kv.get("settings", "{}"))}
        self.game = {"xp": 0, "streak": 0, "best_streak": 0, "qn": 0, "answered": 0, "correct": 0,
                     "ewma": self.settings["target"], "last_gp_unlock_q": 0, **json.loads(kv.get("game", "{}"))}
        self.recent: deque = deque(maxlen=80)
        for item, kind, kc, correct in self.pdb.execute(
                "SELECT item,kind,kc,correct FROM answers ORDER BY id DESC LIMIT 80").fetchall()[::-1]:
            it = self.by_key.get(item)
            self.recent.append((item, kind, kc, it.sid if it else None, correct))
        self.seen_items = {k for (k,) in self.pdb.execute("SELECT DISTINCT item FROM answers")}
        self.kc_misses = Counter(dict(self.pdb.execute("SELECT kc, COUNT(*) FROM answers WHERE correct=0 GROUP BY kc").fetchall()))
        self.anki_added = set(json.loads(kv.get("anki_added", "[]")))
        self.gp_answers = Counter()
        for item, correct in self.pdb.execute("SELECT item, correct FROM answers"):
            it = self.by_key.get(item)
            if it:
                for g in it.gps:
                    self.gp_answers[g] += 1
        if not self.unlocked:
            now = self.now()
            for cat in CATS:
                self._unlock(f"band:{cat}:5", now, "start")
            for g in self.grammar.values():
                if g["level"] == 5 and g["ord"] <= 7:
                    self._unlock(f"gp:{g['id']}", now, "start")
            self.pdb.commit()
        self._rebuild_pools()

    # ------------------------------------------------------------------ helpers
    def _unlock(self, key, now, how):
        self.unlocked.add(key)
        self.pdb.execute("INSERT OR IGNORE INTO unlock VALUES (?,?,?)", (key, now, how))

    def _eligible(self, it: Item) -> bool:
        if f"band:{it.cat}:{it.level}" not in self.unlocked:
            return False
        for g in it.gps:
            if g in self.grammar and f"gp:{g}" not in self.unlocked:
                return False
        return True

    def _rebuild_pools(self):
        self.pool_by_kind: dict[str, list[Item]] = {}
        for it in self.items:
            if self._eligible(it):
                self.pool_by_kind.setdefault(it.kind, []).append(it)

    def in_placement(self) -> bool:
        return self.game.get("placement_done") is None and self.game["answered"] < PLACEMENT_N

    def target(self) -> float:
        t = self.settings["target"]
        if self.in_placement():
            return 0.6
        adj = 0.8 * (t - self.game["ewma"])
        return min(max(t + adj, t - 0.12), min(0.93, t + 0.12))

    def predict(self, it: Item, now: float) -> tuple[float, list, float]:
        terms = Model.design(it.cat, it.kind, it.tags, it.key)
        shift = memory_shift(self.cards.get(it.kc), now, it.kc)
        p = self.model.predict(terms, it.seed, GUESS.get(it.kind, 0.2), shift)
        return p, terms, shift

    # ------------------------------------------------------------------ selection
    def _candidates(self, now):
        qn = self.game["qn"]
        out: dict[str, tuple[Item, str]] = {}
        if self.in_placement():
            allk = [i for i in self.items if i.kind in PLACEMENT_KINDS]
            for it in self.rng.sample(allk, min(240, len(allk))):
                out[it.key] = (it, "place")
            return out
        # relearning cards
        for kc, c in self.cards.items():
            if c.state == "relearning" and (now >= c.short_due or qn - c.last_q >= 7) and qn - c.last_q >= 3:
                items = [i for i in self.by_kc.get(kc, []) if self._eligible(i)]
                failed = self.card_item.get(kc)
                if failed in self.by_key and qn - c.last_q >= 6:
                    out[failed] = (self.by_key[failed], "relearn")
                for it in self.rng.sample(items, min(3, len(items))):
                    out.setdefault(it.key, (it, "relearn"))
        # due reviews
        due = [(c.r(now), kc) for kc, c in self.cards.items() if c.state == "review" and c.due <= now]
        due.sort()
        for r, kc in due[:24]:
            items = [i for i in self.by_kc.get(kc, []) if self._eligible(i)]
            for it in self.rng.sample(items, min(2, len(items))):
                out.setdefault(it.key, (it, "due"))
        # fresh practice, stratified by question type
        kinds = [k for k in self.pool_by_kind if self.pool_by_kind[k]]
        if kinds:
            weights = [KIND_MIX.get(k, 0.5) for k in kinds]
            for _ in range(160):
                k = self.rng.choices(kinds, weights)[0]
                it = self.rng.choice(self.pool_by_kind[k])
                out.setdefault(it.key, (it, "fresh"))
        return out

    def _score(self, it: Item, why: str, p: float, target: float, now: float) -> float:
        qn = self.game["qn"]
        fit = -((logit(p) - logit(target)) ** 2) / (2 * 0.55 ** 2)
        s = fit
        recent = list(self.recent)
        last_items = {r[0] for r in recent[-60:]}
        if it.key in last_items:
            s -= 4.0
        if it.kc in {r[2] for r in recent[-4:]}:
            s -= 2.5
        if it.sid and it.sid in {r[3] for r in recent[-30:]}:
            s -= 3.0
        if recent and recent[-1][1] == it.kind:
            s -= 0.6
        if len(recent) >= 2 and recent[-2][1] == it.kind:
            s -= 0.4
        if why == "relearn":
            s += 2.5
        elif why == "due":
            c = self.cards.get(it.kc)
            s += 1.0 + (min(1.5, (0.9 - c.r(now)) * 5) if c else 0)
        elif why == "fresh":
            c = self.cards.get(it.kc)
            if c is not None and c.state == "review" and c.due > now:
                s -= 0.7          # known card, not due yet
            if it.key not in self.seen_items:
                s += 0.2
            learning = sum(1 for c in self.cards.values() if c.state == "relearning")
            if c is None and learning > 12:
                s -= 1.5
        # keep the mix of question types close to KIND_MIX
        # variety: every question type keeps showing up (and so keeps calibrating)
        tot = sum(KIND_MIX.values())
        want = KIND_MIX.get(it.kind, 0.5) / tot
        share = sum(1 for r in recent[-30:] if r[1] == it.kind) / max(1, min(30, len(recent)))
        s += 1.5 * max(-1.0, min(1.0, (want - share) / want))
        if it.flags & 1:
            s -= 0.3              # Tom-and-Mary sentences: a bit less often
        s += self.rng.gauss(0, 0.3)
        return s

    def _placement_pick(self, cands, now):
        recent_cats = [self.by_key[r[0]].cat for r in list(self.recent)[-2:] if r[0] in self.by_key]
        best, best_s = None, -1e9
        for key, (it, _) in cands.items():
            if it.key in self.seen_items:
                continue
            terms = Model.design(it.cat, it.kind, it.tags, it.key)
            inf = self.model.info(terms, it.seed, GUESS.get(it.kind, 0.2))
            s = inf - (0.15 if it.cat in recent_cats else 0) + self.rng.gauss(0, 0.02)
            if s > best_s:
                best, best_s = it, s
        return best

    def next(self) -> dict:
        if self.intro_queue:
            return self.intro_queue.popleft()
        now = self.now()
        target = self.target()
        cands = self._candidates(now)
        if self.in_placement():
            it = self._placement_pick(cands, now)
            why = "place"
        else:
            best, best_s = None, -1e9
            for key, (it, why_) in cands.items():
                p, _, _ = self.predict(it, now)
                sc = self._score(it, why_, p, target, now)
                if sc > best_s:
                    best, best_s, why = it, sc, why_
            it = best
        return self._make_question(it, why, target, now)

    def _make_question(self, it: Item, why: str, target: float, now: float) -> dict:
        payload = json.loads(self.cdb.execute("SELECT payload FROM items WHERE id=?", (it.id,)).fetchone()[0])
        p, terms, shift = self.predict(it, now)
        self.game["qn"] += 1
        qid = self.game["qn"]
        q = {"type": "question", "qid": qid, "kind": it.kind, "level": it.level, "cat": it.cat,
             "mode": "placement" if why == "place" else "normal", "why": why,
             "new": it.key not in self.seen_items, "p": round(p, 3), "target": round(target, 3),
             "budget": FAST[it.kind] * 2,
             "kind_name": KIND_NAMES[it.kind], "cat_name": CAT_NAMES[it.cat], "skill": self._tag_label(it.tags[0] if it.tags else it.kc, it.kc),
             "your": round(to_rating(self.model.skill_theta(cat=it.cat, kind=it.kind) +
                                     sum(self.model.theta(f"tag:{t}") for t in it.tags) / max(1, len(it.tags)))),
             "item_rating": round(to_rating(self.model.peek(f"item:{it.key}", it.seed)[0]))}
        ui = {k: v for k, v in payload.items() if k not in ("explain", "explain_ru", "accept", "src", "others_src",
                                                             "wrong", "right", "fixed", "others_en")}
        correct = None
        if it.kind == "order":
            tiles = list(payload["tiles"])
            order = list(range(len(tiles)))
            for _ in range(10):
                self.rng.shuffle(order)
                if order != sorted(order):
                    break
            ui["tiles"] = [tiles[i] for i in order]
            correct = "".join(tiles)
        else:
            choices = list(payload["choices"])
            order = list(range(len(choices)))
            self.rng.shuffle(order)
            ui["choices"] = [choices[i] for i in order]
            if "choices_ru" in payload:
                ui["choices_ru"] = [payload["choices_ru"][i] for i in order]
            correct = order.index(0)
        q["ui"] = ui
        self.current = {"qid": qid, "item": it, "payload": payload, "correct": correct, "p": p, "target": target,
                        "why": why, "t0": now}
        return q

    # ------------------------------------------------------------------ answering
    def peek(self) -> dict:
        """Test hook: the correct answer of the current question (used for screenshots/tests)."""
        cur = self.current
        if not cur:
            return {"type": "peek", "correct": None}
        it = cur["item"]
        if it.kind == "order":
            return {"type": "peek", "correct": cur["payload"]["tiles"], "order": True}
        return {"type": "peek", "correct": cur["correct"]}

    def answer(self, qid: int, choice=None, order=None, skip=False, ms: int = 0) -> dict:
        cur = self.current
        if cur is None or cur["qid"] != qid:
            return {"type": "error", "error": "stale question"}
        self.current = None
        it: Item = cur["item"]
        payload = cur["payload"]
        now = self.now()
        if skip:
            correct = False
        elif it.kind == "order":
            correct = order is not None and "".join(order) == cur["correct"]
        else:
            correct = choice is not None and int(choice) == cur["correct"]
        y = 1 if correct else 0
        secs = max(0.0, ms / 1000.0)
        # ---- ratings
        cat_before = {c: self.model.rating(cat=c) for c in CATS}
        g_before = self.model.rating()
        terms = Model.design(it.cat, it.kind, it.tags, it.key)
        card = self.cards.get(it.kc)
        shift = memory_shift(card, now, it.kc)
        p = cur["p"]
        self.model.update(terms, it.seed, GUESS.get(it.kind, 0.2), y, now, shift)
        cat_after = {c: self.model.rating(cat=c) for c in CATS}
        g_after = self.model.rating()
        # ---- memory
        if card is None:
            card = Card()
            self.cards[it.kc] = card
        grade = grade_from(correct, secs, FAST[it.kind]) if not skip else 1
        review(card, grade, now, self.game["qn"])
        self.card_item[it.kc] = it.key
        # ---- game
        g = self.game
        g["answered"] += 1
        g["ewma"] = 0.9 * g["ewma"] + 0.1 * y
        level_before = level_for_xp(g["xp"])
        rank_before = rank_for(self.model.skill_theta())
        points = 0
        if correct:
            g["streak"] += 1
            g["correct"] += 1
            g["best_streak"] = max(g["best_streak"], g["streak"])
            combo = min(3.0, 1.0 + 0.25 * ((g["streak"] - 1) // 3))
            time_bonus = max(0.0, min(1.0, 1.0 - secs / (2.0 * FAST[it.kind])))
            points = int(round((10 + 30 * (1 - p)) * combo * (1 + 0.5 * time_bonus)))
            g["xp"] += points
        else:
            combo = 1.0
            time_bonus = 0.0
            g["streak"] = 0
        for gp in it.gps:
            self.gp_answers[gp] += 1
        day = datetime.fromtimestamp(now).strftime("%Y-%m-%d")
        self.pdb.execute("INSERT INTO days VALUES (?,1,?,?) ON CONFLICT(day) DO UPDATE SET n=n+1, correct=correct+?, xp=xp+?",
                         (day, y, points, y, points))
        events = []
        level_after = level_for_xp(g["xp"])
        if level_after > level_before:
            events.append({"type": "levelup", "level": level_after})
        mode = "placement" if cur["why"] == "place" else "normal"
        if mode == "placement" and g["answered"] >= PLACEMENT_N:
            g["placement_done"] = now
            events.append(self._placement_summary(now))
        events += self._check_unlocks(now, bulk=(mode == "placement" and g["answered"] >= PLACEMENT_N))
        rank_after = rank_for(self.model.skill_theta())
        if rank_after != rank_before and mode != "placement" and self.model.skill_theta() > -99:
            order_ = [n for _, n in RANKS]
            if order_.index(rank_after) > order_.index(rank_before):
                events.append({"type": "rank", "rank": rank_after})
        self.recent.append((it.key, it.kind, it.kc, it.sid, y))
        self.seen_items.add(it.key)
        snap = {c: round(cat_after[c], 1) for c in CATS}
        snap["g"] = round(g_after, 1)
        self.pdb.execute("INSERT INTO answers(ts,item,kind,kc,cat,level,correct,ms,p,target,points,mode,snap) "
                         "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                         (now, it.key, it.kind, it.kc, it.cat, it.level, y, int(ms), p, cur["target"], points, mode,
                          json.dumps(snap)))
        self._save(terms, it.kc)
        self.last_answered = (it, payload)
        if not correct:
            self.kc_misses[it.kc] += 1
            if self.settings.get("anki_auto") and self.kc_misses[it.kc] >= 2 and it.kc not in self.anki_added:
                r = self.anki_add_last(auto=True)
                events.append({"type": "anki", "auto": True, **r})
        tag_key = it.tags[0] if it.tags else None
        res = {
            "type": "result", "qid": qid, "correct": correct, "skipped": bool(skip),
            "answer": cur["correct"] if it.kind != "order" else payload["tiles"],
            "explain": payload.get("explain", ""), "explain_ru": payload.get("explain_ru", ""),
            "full": payload.get("full") or payload.get("fixed"),
            "en": payload.get("en") or (payload["choices"][0] if it.kind == "meaning" else None),
            "ru": payload.get("ru") or ((payload.get("choices_ru") or [None])[0] if it.kind == "meaning" else None),
            "points": points, "combo": combo, "streak": g["streak"], "best_streak": g["best_streak"],
            "time_bonus": round(time_bonus, 2), "xp": g["xp"], "level": level_after,
            "level_progress": self._level_progress(),
            "rating": {"before": round(g_before), "after": round(g_after)},
            "cat": {"name": CAT_NAMES[it.cat], "before": round(cat_before[it.cat]), "after": round(cat_after[it.cat])},
            "skill": {"label": self._tag_label(tag_key, it.kc),
                      "rating": round(self.model.rating(cat=it.cat, tag=tag_key)) if tag_key else None},
            "p": round(p, 3), "events": events, "today": self._today(),
        }
        if it.kind == "odd":
            res["fixed"] = payload.get("fixed")
            res["wrong"] = payload.get("wrong")
            res["right"] = payload.get("right")
        if it.kind == "produce":
            res["others_en"] = payload.get("others_en")
        return res

    def _placement_summary(self, now):
        th = self.model.skill_theta()
        return {"type": "placement", "rating": round(to_rating(th)), "rank": rank_for(th),
                "cats": [{"name": CAT_NAMES[c], "rating": round(self.model.rating(cat=c))} for c in CATS]}

    def _check_unlocks(self, now, bulk=False) -> list[dict]:
        events = []
        changed = False
        if self.in_placement() and not bulk:
            return events            # placement decides everything at once, at the end
        for cat in CATS:
            th = self.model.skill_theta(cat=cat)
            for lv in (4, 3):
                key = f"band:{cat}:{lv}"
                if key in self.unlocked or f"band:{cat}:{lv + 1}" not in self.unlocked:
                    continue
                if th >= LEVEL_BASE[lv] - 0.35:
                    self._unlock(key, now, "placement" if bulk else "rating")
                    events.append({"type": "unlock", "what": "band", "cat": cat, "cat_name": CAT_NAMES[cat],
                                   "level": lv})
                    changed = True
        th_g = self.model.skill_theta(cat="grammar")
        fresh = sum(1 for gid in self.grammar if f"gp:{gid}" in self.unlocked and self.gp_items[gid] and self.gp_answers[gid] < 4)
        intros = 0
        newly = []
        qn = self.game["qn"]
        for g in sorted(self.grammar.values(), key=lambda x: x["ord"]):
            key = f"gp:{g['id']}"
            if key in self.unlocked or f"band:grammar:{g['level']}" not in self.unlocked:
                continue
            by_rating = th_g >= LEVEL_BASE[g["level"]] + g["diff"] - 0.2
            by_trickle = (not bulk and not self.in_placement() and fresh < 2 and not newly
                          and qn - self.game.get("last_gp_unlock_q", 0) >= 12)
            if self.in_placement() and not bulk:
                continue
            if by_rating or by_trickle:
                self._unlock(key, now, "placement" if bulk else ("rating" if by_rating else "next"))
                newly.append(g)
                changed = True
                self.game["last_gp_unlock_q"] = qn
                if not bulk and intros < 2 and self.gp_items[g["id"]]:
                    self.intro_queue.append(self._intro(g))
                    intros += 1
                    fresh += 1
        if newly:
            events.append({"type": "unlock", "what": "grammar", "bulk": bulk,
                           "items": [{"id": g["id"], "name": g["name"], "en": g["en"], "ru": g["ru"]} for g in newly]})
        if changed:
            self._rebuild_pools()
        return events

    def _intro(self, g) -> dict:
        ex = None
        cands = [it for it in self.items if g["id"] in it.gps and it.kind in ("conj", "gmean", "order", "form", "voice")]
        if cands:
            it = self.rng.choice(cands)
            pl = json.loads(self.cdb.execute("SELECT payload FROM items WHERE id=?", (it.id,)).fetchone()[0])
            ex = {"ja": pl.get("full"), "en": pl.get("en"), "ru": pl.get("ru")}
        return {"type": "intro", "gp": g["id"], "name": g["name"], "en": g["en"], "ru": g["ru"],
                "explain_en": g["explain_en"], "explain_ru": g["explain_ru"], "level": g["level"], "example": ex}

    def _save(self, terms, kc):
        rows = []
        for key, _ in terms:
            c = self.model.comps.get(key)
            if c is not None:
                rows.append((key, c.mu, c.var, c.n, c.t))
        self.pdb.executemany("INSERT OR REPLACE INTO comp VALUES (?,?,?,?,?)", rows)
        c = self.cards[kc]
        self.pdb.execute("INSERT OR REPLACE INTO card VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                         (kc, c.s, c.d, c.last, c.reps, c.lapses, c.state, c.due, c.short_due, c.last_q,
                          self.card_item.get(kc)))
        self.pdb.execute("INSERT OR REPLACE INTO kv VALUES ('game', ?)", (json.dumps(self.game),))
        self.pdb.commit()

    # ------------------------------------------------------------------ info for the UI
    def _tag_label(self, tag: str | None, kc: str) -> list[str]:
        if kc in self.kc_label and (tag is None or not tag.startswith(("k:", "w:"))):
            return list(self.kc_label[kc])
        if not tag:
            return [kc, kc]
        fam, _, rest = tag.partition(":")
        if fam == "gp" and rest in self.grammar:
            g = self.grammar[rest]
            return [f"{g['name']} — {g['en']}", f"{g['name']} — {g['ru']}"]
        if fam == "pt":
            return [f"particle {rest}", f"частица {rest}"]
        if fam == "k":
            return [f"kanji {rest}", f"кандзи {rest}"]
        if fam == "w":
            return [f"word {rest}", f"слово {rest}"]
        if fam == "conj":
            lab = self.kc_label.get(tag)
            return list(lab) if lab else [tag, tag]
        return [tag, tag]

    def _level_progress(self):
        xp = self.game["xp"]
        lv = level_for_xp(xp)
        lo, hi = xp_for_level(lv), xp_for_level(lv + 1)
        return {"level": lv, "xp": xp, "into": xp - lo, "need": hi - lo}

    def _today(self):
        day = datetime.fromtimestamp(self.now()).strftime("%Y-%m-%d")
        row = self.pdb.execute("SELECT n, correct, xp FROM days WHERE day=?", (day,)).fetchone()
        n, c, xp = row if row else (0, 0, 0)
        return {"n": n, "correct": c, "xp": xp, "goal": self.settings["daily_goal"], "streak_days": self._streak_days()}

    def _streak_days(self) -> int:
        days = {d for (d,) in self.pdb.execute("SELECT day FROM days WHERE n >= 10")}
        today = datetime.fromtimestamp(self.now()).date()
        from datetime import timedelta
        n = 0
        d = today
        if d.strftime("%Y-%m-%d") not in days:
            d = d - timedelta(days=1)
        while d.strftime("%Y-%m-%d") in days:
            n += 1
            d = d - timedelta(days=1)
        return n

    def hello(self) -> dict:
        th = self.model.skill_theta()
        return {"type": "hello", "settings": self.settings, "rating": round(to_rating(th)), "rank": rank_for(th),
                "level_progress": self._level_progress(), "streak": self.game["streak"],
                "best_streak": self.game["best_streak"], "today": self._today(),
                "placement": self.in_placement(), "placement_left": max(0, PLACEMENT_N - self.game["answered"]),
                "answered": self.game["answered"],
                "cats": {c: {"name": CAT_NAMES[c], "rating": round(self.model.rating(cat=c))} for c in CATS}}

    def set_settings(self, new: dict) -> dict:
        for k, v in new.items():
            if k in DEFAULT_SETTINGS:
                self.settings[k] = v
        self.settings["target"] = min(0.9, max(0.6, float(self.settings["target"])))
        self.pdb.execute("INSERT OR REPLACE INTO kv VALUES ('settings', ?)", (json.dumps(self.settings),))
        self.pdb.commit()
        return {"type": "settings", "settings": self.settings}

    # ------------------------------------------------------------------ Anki
    def note_for(self, it: Item, payload: dict) -> dict:
        """A note for the shared anki-add helper ("JP Mining" note type, deck Japanese::Quiz)."""
        full = payload.get("full") or payload.get("fixed") or ""
        en = payload.get("en") or (payload["choices"][0] if it.kind == "meaning" else "")
        expl = payload.get("explain", "")

        def at_blank(fill):
            return "".join((f"<b>{fill}</b>" if sg.get("blank") else sg.get("t", "")) for sg in payload.get("sent", []))

        def mark(sub):
            return full.replace(sub, f"<b>{sub}</b>", 1) if sub and sub in full else full

        word, reading, meaning, meaning_ru, sentence, sentence_card = "", "", "", "", full, False
        if it.kind in ("kread", "kwrite"):
            word = payload.get("word", "")
            reading = payload["choices"][0] if it.kind == "kread" else payload.get("reading", "")
            meaning, meaning_ru = payload.get("gloss", ""), payload.get("gloss_ru", "")
            sentence = mark(word)
        elif it.kind == "vocab":
            word, meaning, meaning_ru = payload.get("word", ""), payload.get("gloss", ""), payload.get("gloss_ru", "")
            sentence = at_blank(payload["choices"][0])
        elif it.kind == "particle":
            word, meaning, meaning_ru = payload["choices"][0], expl, payload.get("explain_ru", "")
            sentence, sentence_card = at_blank(payload["choices"][0]), True
        elif it.kind in ("conj", "gmean", "voice", "form", "order", "odd"):
            g = self.grammar.get(payload.get("gp") or (it.gps[0] if it.gps else ""))
            word = g["name"] if g else (payload.get("gp_name") or "")
            meaning = (g["en"] + ". " + g["explain_en"]) if g else expl
            meaning_ru = (g["ru"] + ". " + g["explain_ru"]) if g else payload.get("explain_ru", "")
            if it.kind == "order":
                sentence = mark("".join(payload["tiles"]))
            elif it.kind == "odd":
                sentence = payload["fixed"].replace(payload["right"], f"<b>{payload['right']}</b>", 1)
            else:
                sentence = at_blank(payload["choices"][0])
            sentence_card = True
        else:   # meaning / produce: the whole sentence is the card
            meaning, sentence_card = en, True
        # schema of the shared helper (~/.local/bin/anki-add, note type "JP Mining"):
        # front = Sentence (target in <b>); back = {{furigana:Reading}}, Meaning, SentenceTranslation, Source.
        ru = payload.get("ru", "")
        if it.kind in ("kread", "kwrite") and reading:
            reading_f = f"{word}[{reading}]"
        elif sentence_card or not word:
            reading_f = word or ""          # grammar pattern / particle shown big on the back
        else:
            reading_f = word
        expression = word if not sentence_card else f"{word}【{full[:24]}】" if word else full[:40]
        back = meaning + (f"<br><span style='opacity:.75'>{meaning_ru}</span>" if meaning_ru and meaning_ru != meaning else "")
        if expl and expl not in meaning:
            back += f"<br><small>{expl}</small>"
        src = payload.get("src", {})
        return {"deck": anki.DECK, "expression": expression, "word": word if not sentence_card else "",
                "reading": reading_f, "meaning": back, "sentence": sentence,
                "sentence_translation": en + (f"<br>{ru}" if ru else ""),
                "source": "jp-quiz · Tatoeba #" + str(src.get("ja", "")),
                "tags": ["jp-quiz", it.kind, f"N{it.level}"]}

    def anki_add_last(self, auto: bool = False) -> dict:
        if not self.last_answered:
            return {"type": "anki", "status": "nothing", "message": "Answer a question first."}
        it, payload = self.last_answered
        note = self.note_for(it, payload)
        r = self.outbox.add(note)
        self.anki_added.add(it.kc)
        self.pdb.execute("INSERT OR REPLACE INTO kv VALUES ('anki_added', ?)", (json.dumps(sorted(self.anki_added)),))
        self.pdb.commit()
        return {"type": "anki", "word": note["word"] or note["reading"] or note["expression"][:16], **r}

    def anki_sync(self) -> dict:
        """Read the user's Japanese Anki decks (read-only) and seed the skill and memory model."""
        try:
            data = anki.read_cards()
        except anki.AnkiUnavailable:
            return {"type": "anki_sync", "ok": False, "message": "Anki is not running, so there was nothing to read."}
        now = self.now()
        word_kcs: dict[str, set] = {}
        for kc in self.by_kc:
            fam, _, w = kc.partition(":")
            if fam in ("read", "write", "use"):
                word_kcs.setdefault(w, set()).add(kc)
        tag_words = {t[2:] for it in self.items for t in it.tags if t.startswith("w:")}
        best: dict[str, dict] = {}
        for c in data["cards"]:          # one verdict per word: keep the most informative card
            w = c["word"]
            if w not in word_kcs and w not in tag_words:
                continue
            prev = best.get(w)
            if prev is None or (c["lapses"], c["interval"]) > (prev["lapses"], prev["interval"]):
                best[w] = c
        known = weak = 0
        touched_comps, touched_kcs = set(), set()
        for w, c in best.items():
            verdict = anki.classify(c)
            if verdict == "learning":
                continue
            comp = self.model.get(f"tag:w:{w}")
            if verdict == "known":
                known += 1
                comp.mu, comp.var = max(comp.mu, 0.7), min(comp.var, 0.15)
                for ch in w:
                    if "\u4e00" <= ch <= "\u9fff":
                        kc_ = self.model.get(f"tag:k:{ch}")
                        kc_.mu = max(kc_.mu, 0.35)
                        touched_comps.add(f"tag:k:{ch}")
            else:
                weak += 1
                comp.mu = min(comp.mu, -0.3)
            touched_comps.add(f"tag:w:{w}")
            for kc in word_kcs.get(w, ()):
                card = self.cards.get(kc) or Card()
                if verdict == "known":
                    if card.state == "new" or card.s < c["interval"]:
                        card.state, card.s, card.d = "review", float(min(c["interval"], 365)), 4.0
                        card.last, card.due, card.reps = now, now + min(c["interval"], 365) * DAY, max(card.reps, 1)
                else:      # weak in Anki: due right away, so the quiz reviews it soon
                    card.state, card.s, card.d = "review", 0.5, 8.0
                    card.last, card.due = now - DAY, now - 60
                    card.lapses = max(card.lapses, c["lapses"])
                self.cards[kc] = card
                touched_kcs.add(kc)
        rows = [(k, self.model.comps[k].mu, self.model.comps[k].var, self.model.comps[k].n, self.model.comps[k].t) for k in touched_comps]
        self.pdb.executemany("INSERT OR REPLACE INTO comp VALUES (?,?,?,?,?)", rows)
        for kc in touched_kcs:
            c = self.cards[kc]
            self.pdb.execute("INSERT OR REPLACE INTO card VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                             (kc, c.s, c.d, c.last, c.reps, c.lapses, c.state, c.due, c.short_due, c.last_q, self.card_item.get(kc)))
        summary = {"ts": now, "decks": data["decks"], "cards": len(data["cards"]), "matched": len(best),
                   "known": known, "weak": weak}
        self.pdb.execute("INSERT OR REPLACE INTO kv VALUES ('anki_sync', ?)", (json.dumps(summary, ensure_ascii=False),))
        self.pdb.commit()
        return {"type": "anki_sync", "ok": True, **summary,
                "message": f"Read {len(data['cards'])} cards from {len(data['decks'])} decks: {known} known, {weak} weak words matched."}

    def stats(self) -> dict:
        now = self.now()
        rows = self.pdb.execute("SELECT id, ts, correct, snap, mode FROM answers ORDER BY id DESC LIMIT 600").fetchall()[::-1]
        series = {k: [] for k in ("g",) + CATS}
        for i, (aid, ts, cor, snap, mode) in enumerate(rows):
            sn = json.loads(snap)
            for k in series:
                if k in sn:
                    series[k].append(sn[k])
        acc = [r[2] for r in rows]
        roll = []
        for i in range(len(acc)):
            w = acc[max(0, i - 19):i + 1]
            roll.append(round(sum(w) / len(w), 3))
        cats = {c: {"name": CAT_NAMES[c], "rating": round(self.model.rating(cat=c)),
                    "n": self.model.comps[f"cat:{c}"].n if f"cat:{c}" in self.model.comps else 0,
                    "levels": [lv for lv in (5, 4, 3) if f"band:{c}:{lv}" in self.unlocked]} for c in CATS}
        tags = []
        for key, comp in self.model.comps.items():
            if key.startswith("tag:") and comp.n >= 2:
                tag = key[4:]
                cat = {"pt": "particles", "gp": "grammar", "conj": "grammar", "k": "kanji", "w": "vocab"}.get(tag.split(":")[0], "reading")
                tags.append({"tag": tag, "label": self._tag_label(tag, tag), "n": comp.n,
                             "rating": round(self.model.rating(cat=cat, tag=tag)), "sd": round(math.sqrt(comp.var) * 173.7)})
        particles = sorted([t for t in tags if t["tag"].startswith("pt:")], key=lambda t: -t["rating"])
        grammar = sorted([t for t in tags if t["tag"].startswith(("gp:", "conj:"))], key=lambda t: t["rating"])
        weak = []
        for kc, c in self.cards.items():
            if c.reps >= 1 and (c.lapses > 0 or c.r(now) < 0.85):
                lab = self.kc_label.get(kc, (kc, kc))
                weak.append({"kc": kc, "label": list(lab), "lapses": c.lapses, "reps": c.reps,
                             "r": round(c.r(now), 2), "due_in_h": round((c.due - now) / 3600, 1)})
        weak.sort(key=lambda w: (w["r"] - 0.15 * w["lapses"]))
        cal = self.pdb.execute("SELECT day, n, correct, xp FROM days ORDER BY day DESC LIMIT 140").fetchall()
        n_due = sum(1 for c in self.cards.values() if c.state == "review" and c.due <= now)
        th = self.model.skill_theta()
        return {"type": "stats", "rating": round(to_rating(th)), "rank": rank_for(th), "series": series, "rolling": roll,
                "target": self.settings["target"], "cats": cats, "particles": particles[:16], "grammar": grammar[:14],
                "weak": weak[:10], "calendar": [{"day": d, "n": n, "correct": c, "xp": x} for d, n, c, x in cal],
                "totals": {"answered": self.game["answered"], "correct": self.game["correct"], "xp": self.game["xp"],
                           "best_streak": self.game["best_streak"], "cards": len(self.cards), "due": n_due,
                           "unlocked_gp": sum(1 for k in self.unlocked if k.startswith("gp:")),
                           "total_gp": len(self.grammar)},
                "level_progress": self._level_progress(), "today": self._today(),
                "anki": {"queued": len(self.outbox.pending()),
                         "last_sync": json.loads(dict(self.pdb.execute("SELECT key,value FROM kv").fetchall()).get("anki_sync", "null"))}}
