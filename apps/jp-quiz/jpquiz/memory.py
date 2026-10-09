"""FSRS-style memory model for spaced repetition of knowledge components (cards).

A card is a concept the quiz keeps reviewing with different sentences:
"pt:に:time", "gp:te-mo-ii", "read:時間", "use:泳ぐ", ...

Retrievability follows FSRS's power forgetting curve R(t) = (1 + F t / S)^C,
calibrated so R(S) = 0.9: a card is "due" once its stability S has elapsed.
Stability grows after successful recalls (more when the recall was hard,
i.e. R was low = the spacing effect) and collapses after a lapse.  Wrong
answers also schedule a short relearning step a few minutes later.

Parameters are FSRS-5 defaults; times are in days.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

W = [0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192,
     1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621]
F = 19 / 81
C = -0.5
DAY = 86400.0
# first-answer stability (days) by grade 1..4: wrong, hard, good, easy
S0 = {1: 3 / 1440, 2: 0.4, 3: 2.0, 4: 6.0}
RELEARN = 4 * 60.0          # seconds until a failed card comes back
TARGET_R = 0.9


def retrievability(stability_days: float, elapsed_days: float) -> float:
    if stability_days <= 0:
        return 0.0
    return (1 + F * max(0.0, elapsed_days) / stability_days) ** C


def _d0(g: int) -> float:
    return min(10.0, max(1.0, W[4] - math.exp(W[5] * (g - 1)) + 1))


@dataclass
class Card:
    s: float = 0.0          # stability (days)
    d: float = 5.0          # difficulty 1..10
    last: float = 0.0       # unix time of last review
    reps: int = 0
    lapses: int = 0
    state: str = "new"      # new | learning | review | relearning
    due: float = 0.0        # unix time when R drops to TARGET_R
    short_due: float = 0.0  # relearning step (unix time)
    last_q: int = -1        # question counter at last review

    def r(self, now: float) -> float:
        if self.state == "new":
            return 0.0
        return retrievability(self.s, (now - self.last) / DAY)


def grade_from(correct: bool, seconds: float, fast: float) -> int:
    if not correct:
        return 1
    if seconds <= fast:
        return 4
    if seconds <= 3 * fast:
        return 3
    return 2


def review(card: Card, grade: int, now: float, qn: int) -> Card:
    """Update a card after an answer with grade 1..4 (FSRS-5 equations)."""
    if card.state == "new":
        card.s = S0[grade]
        card.d = _d0(grade)
    else:
        elapsed = max(0.0, (now - card.last) / DAY)
        r = retrievability(card.s, elapsed)
        if grade == 1:
            new_s = W[11] * card.d ** (-W[12]) * ((card.s + 1) ** W[13] - 1) * math.exp(W[14] * (1 - r))
            card.s = max(1 / 1440, min(card.s, new_s))
            card.lapses += 1
        else:
            hard = W[15] if grade == 2 else 1.0
            easy = W[16] if grade == 4 else 1.0
            inc = math.exp(W[8]) * (11 - card.d) * card.s ** (-W[9]) * (math.exp(W[10] * (1 - r)) - 1) * hard * easy
            card.s = card.s * (1 + max(inc, 0.05))
        d = card.d - W[6] * (grade - 3)
        card.d = min(10.0, max(1.0, W[7] * _d0(4) + (1 - W[7]) * d))
    card.reps += 1
    card.last = now
    card.last_q = qn
    if grade == 1:
        card.state = "relearning"
        card.short_due = now + RELEARN
    else:
        card.state = "review"
        card.short_due = 0.0
    card.due = now + card.s * DAY
    return card


SPECIFIC = ("read:", "write:", "use:", "sent:")


def memory_shift(card: Card | None, now: float, kc: str = "", weight: float = 0.35) -> float:
    """Logit adjustment for predictions: fresh memories are easier, faded ones harder.

    Only for specific cards (a word's reading, a sentence...).  Broad concepts such
    as a particle or a grammar point are practised constantly; their strength is
    already in the skill ratings, and adding memory on top would double count.
    """
    if card is None or card.state == "new" or not kc.startswith(SPECIFIC):
        return 0.0
    r = min(max(card.r(now), 0.02), 0.995)
    shift = weight * (math.log(r / (1 - r)) - math.log(TARGET_R / (1 - TARGET_R)))
    return max(-1.0, min(0.6, shift))
