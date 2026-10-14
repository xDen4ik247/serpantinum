"""Thinking-time budget, grammar drill, Anki-add for any recent answer, grammar tab, extra stats,
and checks on the built content (sense-matched glosses, no made-up conjugations).

Everything runs on throwaway progress files; the real content DB is opened read-only.
"""

import json
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path

from jpquiz.conjugate import conjugate_verb, VERB_FORMS
from jpquiz.engine import Engine, BUDGET
from tests.sim import make_content

ROOT = Path(__file__).resolve().parent.parent
REAL = ROOT / "data" / "content.db"


class Clock:
    def __init__(self):
        self.t = 1_760_000_000.0

    def __call__(self):
        return self.t


def answer_right(eng, q, ms=3000):
    peek = eng.peek()
    if peek.get("order"):
        return eng.answer(q["qid"], order=peek["correct"], ms=ms)
    return eng.answer(q["qid"], choice=peek["correct"], ms=ms)


class TestEngineFeatures(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="jpq-feat-"))
        os.environ["JPQUIZ_ANKI_ADD"] = str(self.tmp / "missing-helper")    # never reach the real Anki
        content = REAL if REAL.exists() else self.tmp / "content.db"
        if not REAL.exists():
            make_content(content)
        self.clock = Clock()
        self.eng = Engine(str(content), str(self.tmp / "progress.db"), now=self.clock, seed=7)
        for _ in range(14):                                   # get through placement
            q = self.eng.next()
            if q["type"] == "question":
                answer_right(self.eng, q)

    def next_q(self):
        q = self.eng.next()
        while q["type"] != "question":
            q = self.eng.next()
        return q

    def test_budget_is_generous(self):
        q = self.next_q()
        self.assertGreaterEqual(q["budget"], min(BUDGET.values()))
        self.assertGreaterEqual(q["budget"], 20)

    def test_overtime_costs_xp_but_counts(self):
        q = self.next_q()
        r_fast = answer_right(self.eng, q, ms=2000)
        q2 = self.next_q()
        r_slow = answer_right(self.eng, q2, ms=(q2["budget"] + 30) * 1000)
        self.assertTrue(r_fast["correct"] and r_slow["correct"])
        self.assertFalse(r_fast["overtime"])
        self.assertTrue(r_slow["overtime"])
        self.assertEqual(r_fast["time_bonus"], 0.0)       # speed itself earns nothing

    def test_drill_serves_only_that_grammar_point(self):
        gid = next(g for g in self.eng.grammar if self.eng.gp_items[g] >= 5)
        self.eng.set_settings({"focus_gp": gid})
        self.assertIn(f"gp:{gid}", self.eng.unlocked)
        for _ in range(8):
            q = self.next_q()
            it = self.eng.current["item"]
            self.assertIn(gid, it.gps)
            self.assertEqual(q["focus"], gid)
            answer_right(self.eng, q)
        self.eng.set_settings({"focus_gp": None})
        self.assertIsNone(self.eng.next().get("focus"))

    def test_anki_add_any_recent_answer(self):
        q = self.next_q()
        r = answer_right(self.eng, q)
        key = r["key"]
        self.next_q()                                     # moved on: the passed one can still be added
        res = self.eng.anki_add(key)
        self.assertEqual(res["key"], key)
        self.assertIn(self.eng.by_key[key].kc, self.eng.anki_added)
        self.assertIn(key, [x["key"] for x in self.eng.recent_answers(20)])

    def test_grammar_list_and_more_stats(self):
        g = self.eng.grammar_list()
        self.assertEqual(len(g["points"]), len(self.eng.grammar))
        self.assertTrue(any(p["unlocked"] for p in g["points"]))
        st = self.eng.stats()
        more = st["more"]
        for k in ("kinds", "levels", "hours", "calibration", "time", "cards", "forecast", "days14", "recent"):
            self.assertIn(k, more)
        self.assertEqual(len(more["hours"]), 24)
        self.assertEqual(len(more["forecast"]), 7)
        self.assertGreater(sum(k["n"] for k in more["kinds"]), 0)


@unittest.skipUnless(REAL.exists(), "built content missing")
class TestBuiltContent(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.db = sqlite3.connect(f"file:{REAL}?mode=ro", uri=True)

    def test_no_spot_the_mistake_items(self):
        n = self.db.execute("SELECT COUNT(*) FROM items WHERE kind='odd'").fetchone()[0]
        self.assertEqual(n, 0)

    def test_conj_choices_are_real_forms(self):
        classes = ("v1", "v5k", "v5g", "v5s", "v5t", "v5r", "v5u", "v5n", "v5b", "v5m", "v5k-s", "vk", "vs-i", "v5r-i")
        rows = self.db.execute("SELECT payload FROM items WHERE kind='conj'").fetchall()
        for (pl,) in rows:
            pl = json.loads(pl)
            real = set()
            for cls in classes:
                for f in VERB_FORMS:
                    try:
                        real.add(conjugate_verb(pl["dict"], cls, f))
                    except (KeyError, ValueError, IndexError):
                        pass
            self.assertEqual(len(set(pl["choices"])), 4)
            for c in pl["choices"]:
                self.assertIn(c, real, f"{c} is not a real form of {pl['dict']}")

    def test_every_item_has_a_glossary(self):
        n, with_words = self.db.execute(
            "SELECT COUNT(*), SUM(payload LIKE '%\"words\":[{%') FROM items").fetchone()
        self.assertGreater(with_words / n, 0.9)

    def test_sense_matches_the_sentence(self):
        # 「全くそのとおりです」 means "that's right", not "street"
        row = self.db.execute("SELECT payload FROM items WHERE payload LIKE '%全くそのとおりです%' LIMIT 1").fetchone()
        if row is None:
            self.skipTest("sentence not in this build")
        words = json.loads(row[0])["words"]
        g = next(w for w in words if "とおり" in w["w"])
        self.assertNotIn("street", g["g"])


if __name__ == "__main__":
    unittest.main()
