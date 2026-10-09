"""Unit tests for rating, memory, conjugation, romaji, and a simulated learner.

Run:  python -m unittest discover -s tests -v      (from the project root)
"""

import math
import tempfile
import unittest
from pathlib import Path

from jpquiz.model import Model, sigmoid, to_rating
from jpquiz.memory import Card, review, retrievability, grade_from, DAY
from jpquiz.conjugate import conjugate_verb, conjugate_adj, wrong_te_ta
from jpquiz.kana import romaji_to_hiragana, normalize_reading
from tests.sim import Learner, run


class TestModel(unittest.TestCase):
    def setUp(self):
        self.m = Model()
        self.terms = Model.design("grammar", "conj", ["gp:te-iru"], "x1")

    def test_correct_answer_raises_skill_and_lowers_item(self):
        before_skill = self.m.skill_theta(cat="grammar")
        before_item = self.m.peek("item:x1", 0.0)[0]
        self.m.update(self.terms, 0.0, 0.2, 1, now=1000.0)
        self.assertGreater(self.m.skill_theta(cat="grammar"), before_skill)
        self.assertLess(self.m.peek("item:x1", 0.0)[0], before_item)

    def test_wrong_answer_lowers_skill(self):
        before = self.m.skill_theta()
        self.m.update(self.terms, 0.0, 0.2, 0, now=1000.0)
        self.assertLess(self.m.skill_theta(), before)

    def test_uncertainty_shrinks(self):
        v0 = self.m.get("g").var
        for i in range(10):
            self.m.update(self.terms, 0.0, 0.2, i % 2, now=1000.0 + i)
        self.assertLess(self.m.get("g").var, v0)

    def test_surprise_moves_more(self):
        easy = Model.design("grammar", "conj", [], "easy")
        hard = Model.design("grammar", "conj", [], "hard")
        m1, m2 = Model(), Model()
        m1.update(easy, -3.0, 0.2, 0, now=1.0)   # failing an easy item: big drop
        m2.update(hard, +3.0, 0.2, 0, now=1.0)   # failing a hard item: tiny drop
        self.assertLess(m1.skill_theta(), m2.skill_theta())

    def test_prediction_includes_guessing(self):
        p = self.m.predict(self.terms, 50.0, 0.2)
        self.assertAlmostEqual(p, 0.2, places=3)

    def test_rating_scale(self):
        self.assertEqual(round(to_rating(0.0)), 1500)
        self.assertEqual(round(to_rating(1.0)), 1674)


class TestMemory(unittest.TestCase):
    def test_retrievability_at_stability_is_90(self):
        self.assertAlmostEqual(retrievability(3.0, 3.0), 0.9, places=6)

    def test_success_grows_stability_failure_shrinks(self):
        c = review(Card(), 3, now=0.0, qn=1)
        s1 = c.s
        c = review(c, 3, now=s1 * DAY, qn=2)
        self.assertGreater(c.s, s1 * 1.5)
        s2 = c.s
        c = review(c, 1, now=c.last + s2 * DAY, qn=3)
        self.assertLess(c.s, s2)
        self.assertEqual(c.state, "relearning")
        self.assertLess(c.short_due - c.last, 600)

    def test_first_wrong_answer_comes_back_soon(self):
        c = review(Card(), 1, now=0.0, qn=1)
        self.assertLess(c.s, 0.01)

    def test_grades(self):
        self.assertEqual(grade_from(False, 1, 4), 1)
        self.assertEqual(grade_from(True, 2, 4), 4)
        self.assertEqual(grade_from(True, 8, 4), 3)
        self.assertEqual(grade_from(True, 30, 4), 2)


class TestLanguage(unittest.TestCase):
    def test_te_forms(self):
        cases = {("書く", "v5k"): "書いて", ("泳ぐ", "v5g"): "泳いで", ("話す", "v5s"): "話して", ("待つ", "v5t"): "待って",
                 ("死ぬ", "v5n"): "死んで", ("遊ぶ", "v5b"): "遊んで", ("読む", "v5m"): "読んで", ("帰る", "v5r"): "帰って",
                 ("買う", "v5u"): "買って", ("行く", "v5k-s"): "行って", ("食べる", "v1"): "食べて", ("来る", "vk"): "来て",
                 ("勉強する", "vs-i"): "勉強して"}
        for (b, c), want in cases.items():
            self.assertEqual(conjugate_verb(b, c, "te"), want)
            self.assertNotIn(want, wrong_te_ta(b, c))

    def test_other_forms(self):
        self.assertEqual(conjugate_verb("行く", "v5k-s", "volitional"), "行こう")
        self.assertEqual(conjugate_verb("ある", "v5r-i", "nai"), "ない")
        self.assertEqual(conjugate_verb("話す", "v5s", "potential"), "話せる")
        self.assertEqual(conjugate_verb("くる", "vk", "nai"), "こない")
        self.assertEqual(conjugate_verb("する", "vs-i", "ba"), "すれば")
        self.assertEqual(conjugate_adj("いい", "adj-ix", "katta"), "よかった")
        self.assertEqual(conjugate_adj("高い", "adj-i", "kunai"), "高くない")

    def test_romaji(self):
        self.assertEqual(romaji_to_hiragana("gakkou"), "がっこう")
        self.assertEqual(romaji_to_hiragana("shinbun"), "しんぶん")
        self.assertEqual(romaji_to_hiragana("kon'nichiha"), "こんにちは")
        self.assertEqual(romaji_to_hiragana("kyou"), "きょう")
        self.assertEqual(normalize_reading("ジカン"), "じかん")


class TestSimulatedLearner(unittest.TestCase):
    """The engine should find a learner's level and keep success near the target."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="jpq-test-"))

    def test_converges_and_holds_target(self):
        eng, log, _ = run(Learner(theta=0.3, seed=3), n=500, target=0.75, tmp=self.tmp / "a")
        late = log[200:]
        rate = sum(r["ok"] for r in late) / len(late)
        self.assertLess(abs(rate - 0.75), 0.07, f"success rate {rate:.3f}")
        cat_err = sum(r["cat_err"] for r in log[-100:]) / 100
        self.assertLess(cat_err, 0.5, f"category skill error {cat_err:.2f} logits")
        mae = sum(abs(r["p_pred"] - r["p_true"]) for r in late) / len(late)
        self.assertLess(mae, 0.13, f"prediction MAE {mae:.3f}")

    def test_placement_orders_learners(self):
        ests = []
        for th, seed in ((-1.3, 11), (0.3, 12), (1.8, 13)):
            eng, log, _ = run(Learner(theta=th, seed=seed, spread=0.2), n=12, tmp=self.tmp / f"p{seed}")
            ests.append(log[-1]["est"])
            self.assertLess(abs(log[-1]["est"] - log[-1]["true"]), 1.0,
                            f"placement estimate {log[-1]['est']:.2f} vs true {log[-1]['true']:.2f}")
        self.assertTrue(ests[0] < ests[1] < ests[2], ests)

    def test_target_is_respected(self):
        rates = {}
        for target in (0.65, 0.85):
            eng, log, _ = run(Learner(theta=0.5, seed=21), n=450, target=target, tmp=self.tmp / f"t{target}")
            late = log[150:]
            rates[target] = sum(r["ok"] for r in late) / len(late)
            self.assertLess(abs(rates[target] - target), 0.08, f"target {target}: {rates[target]:.3f}")
        self.assertLess(rates[0.65], rates[0.85])

    def test_tracks_an_improving_learner(self):
        eng, log, _ = run(Learner(theta=-0.5, seed=31, learn_rate=0.003), n=500, tmp=self.tmp / "learn")
        # true skill rose by 1.5 logits; the estimate should follow most of it
        rise_true = log[-1]["true"] - log[30]["true"]
        rise_est = log[-1]["est"] - log[30]["est"]
        self.assertGreater(rise_est, 0.7 * rise_true, f"estimate rose {rise_est:.2f} vs true {rise_true:.2f}")


if __name__ == "__main__":
    unittest.main()
