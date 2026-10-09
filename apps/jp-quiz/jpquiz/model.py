"""Skill-based matchmaking model.

The chance of answering an item correctly is an IRT/Rasch-style logistic:

    eta = th_global + th_category + th_format + mean(th_tags) - b_item
    P(correct) = c + (1 - c) * sigmoid(eta / sqrt(1 + pi * var(eta) / 8))

* th_* are the learner's skills (global, e.g. "grammar", e.g. "particle quiz",
  e.g. "particle に" or "kanji 時"); b_item is the item's difficulty.
* Every number carries a variance, like Glicko's rating deviation: new skills
  and new items are uncertain, so they move fast; well-known ones move slowly.
* c is the guessing floor of the question format (multiple choice ~ 0.2).

After each answer all involved numbers are updated together with one rank-1
Bayesian (Laplace / extended-Kalman) step, so the evidence is shared between
them in proportion to how uncertain each one is.  Skills also drift a little
over time (process noise), so the model keeps tracking a learner who improves.

Ratings shown in the UI use the Glicko/Elo scale: 1500 + 173.7 * theta.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

SCALE = 400 / math.log(10)      # 173.7 rating points per logit
BASE = 1500.0

# prior (mean, variance) for each component family
PRIORS = {
    "g": (-0.4, 1.2),       # global: start between N5 and N4, very uncertain
    "cat": (0.0, 0.25),
    "kind": (0.0, 0.12),
    "tag": (0.0, 0.30),
    "item": (None, 0.16),   # mean = seeded difficulty (seeds are good to about +-0.4 logits)
}
VAR_FLOOR = {"g": 0.012, "cat": 0.02, "kind": 0.015, "tag": 0.04, "item": 0.05}
VAR_CAP = {"g": 1.2, "cat": 0.4, "kind": 0.2, "tag": 0.5, "item": 0.25}
# process noise: per answer that touches the component, and per day of elapsed time
Q_STEP = {"g": 0.004, "cat": 0.004, "kind": 0.001, "tag": 0.006, "item": 0.0}
Q_DAY = {"g": 0.01, "cat": 0.01, "kind": 0.002, "tag": 0.02, "item": 0.0}

GUESS = {"particle": 0.2, "conj": 0.2, "gmean": 0.2, "voice": 0.2, "form": 0.22, "order": 0.02,
         "odd": 0.2, "kread": 0.2, "kwrite": 0.2, "vocab": 0.2, "meaning": 0.22, "produce": 0.2,
         "typed": 0.0}


def family(key: str) -> str:
    if key == "g":
        return "g"
    return key.split(":", 1)[0]


def sigmoid(x: float) -> float:
    if x >= 0:
        return 1.0 / (1.0 + math.exp(-x))
    z = math.exp(x)
    return z / (1.0 + z)


def logit(p: float) -> float:
    p = min(max(p, 1e-6), 1 - 1e-6)
    return math.log(p / (1 - p))


def to_rating(theta: float) -> float:
    return BASE + SCALE * theta


@dataclass
class Comp:
    mu: float
    var: float
    n: int = 0
    t: float = 0.0     # last update (unix seconds)


class Model:
    """Holds components in memory; the store persists them."""

    def __init__(self, comps: dict[str, Comp] | None = None):
        self.comps: dict[str, Comp] = comps or {}

    # ------------------------------------------------------------------
    def get(self, key: str, seed: float | None = None) -> Comp:
        c = self.comps.get(key)
        if c is None:
            fam = family(key)
            mu, var = PRIORS[fam]
            if fam == "item":
                mu = seed if seed is not None else 0.0
            c = Comp(mu, var)
            self.comps[key] = c
        return c

    def peek(self, key: str, seed: float | None = None) -> tuple[float, float]:
        c = self.comps.get(key)
        if c is not None:
            return c.mu, c.var
        fam = family(key)
        mu, var = PRIORS[fam]
        if fam == "item":
            mu = seed if seed is not None else 0.0
        return mu, var

    @staticmethod
    def design(cat: str, kind: str, tags: list[str], item_key: str) -> list[tuple[str, float]]:
        """(component key, coefficient) pairs that make up eta."""
        terms = [("g", 1.0), (f"cat:{cat}", 1.0), (f"kind:{kind}", 1.0)]
        if tags:
            w = 1.0 / len(tags)
            terms += [(f"tag:{t}", w) for t in tags]
        terms.append((f"item:{item_key}", -1.0))
        return terms

    def eta(self, terms, seed: float) -> tuple[float, float]:
        m = 0.0
        v = 0.0
        for key, a in terms:
            mu, var = self.peek(key, seed)
            m += a * mu
            v += a * a * var
        return m, v

    @staticmethod
    def prob(m: float, v: float, guess: float) -> float:
        p = sigmoid(m / math.sqrt(1.0 + math.pi * v / 8.0))
        return guess + (1.0 - guess) * p

    def predict(self, terms, seed: float, guess: float, mem_shift: float = 0.0) -> float:
        m, v = self.eta(terms, seed)
        return self.prob(m + mem_shift, v, guess)

    def info(self, terms, seed: float, guess: float) -> float:
        """Fisher information of an answer about the learner (for placement)."""
        m, v = self.eta(terms, seed)
        s = sigmoid(m)
        p = guess + (1 - guess) * s
        d = (1 - guess) * s * (1 - s)
        return d * d / max(p * (1 - p), 1e-9)

    # ------------------------------------------------------------------
    def update(self, terms, seed: float, guess: float, y: int, now: float, mem_shift: float = 0.0,
               learner_only: bool = False) -> dict[str, float]:
        """One Bayesian step after observing y (1 correct / 0 wrong). Returns mean changes."""
        comps = []
        for key, a in terms:
            fam = family(key)
            if learner_only and fam == "item":
                continue
            c = self.get(key, seed)
            if fam != "item":
                days = max(0.0, (now - c.t) / 86400.0) if c.t else 0.0
                c.var = min(VAR_CAP[fam], c.var + Q_STEP[fam] + Q_DAY[fam] * min(days, 60.0))
            comps.append((key, a, c, fam))
        m = sum(a * c.mu for _, a, c, _ in comps) + mem_shift
        if learner_only:
            mu_i, var_i = self.peek(next(k for k, _ in terms if family(k) == "item"), seed)
            m -= mu_i
        S = sum(a * a * c.var for _, a, c, _ in comps)
        s = sigmoid(m)
        p = guess + (1 - guess) * s
        ds = (1 - guess) * s * (1 - s)             # dP/deta
        grad = ds / p if y else -ds / (1 - p)       # d log L / d eta
        # observed information (negative second derivative), clipped positive
        info = (ds * ds) / max(p * (1 - p), 1e-9)
        denom = 1.0 + info * S
        deltas = {}
        for key, a, c, fam in comps:
            dmu = c.var * a * grad / denom
            c.mu += dmu
            c.var = max(VAR_FLOOR[fam], c.var - (c.var * a) ** 2 * info / denom)
            c.n += 1
            c.t = now
            deltas[key] = dmu
        return deltas

    # ------------------------------------------------------------------
    def theta(self, key: str) -> float:
        return self.peek(key)[0]

    def skill_theta(self, cat: str | None = None, tag: str | None = None, kind: str | None = None) -> float:
        th = self.peek("g")[0]
        if cat:
            th += self.peek(f"cat:{cat}")[0]
        if kind:
            th += self.peek(f"kind:{kind}")[0]
        if tag:
            th += self.peek(f"tag:{tag}")[0]
        return th

    def rating(self, **kw) -> float:
        return to_rating(self.skill_theta(**kw))
