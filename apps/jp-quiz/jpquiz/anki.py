"""Anki integration.

* Adding cards: always through the shared helper ~/.local/bin/anki-add (JSON on stdin,
  "JP Mining" note type, it queues by itself while Anki is closed).  Until that helper
  exists, notes wait in ~/.local/share/jp-quiz/anki-queue.jsonl and are flushed later.
* Reading: AnkiConnect on 127.0.0.1:8770, strictly read-only.  Only the actions in
  READ_ACTIONS are ever sent.  When Anki is closed, reads are simply skipped.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

ANKI_URL = os.environ.get("JPQUIZ_ANKI_URL", "http://127.0.0.1:8770")
DECK = os.environ.get("JPQUIZ_ANKI_DECK", "Japanese::Quiz")
READ_ACTIONS = {"version", "deckNames", "findCards", "cardsInfo"}
JP_DECK_RE = re.compile(r"japan|nihon|日本|jlpt|kanji|漢字|vocab|core ?[0-9]|mining|n[1-5]\b|\bjp\b|\bja\b", re.I)
WORD_FIELDS = ("word", "expression", "vocab", "vocabulary", "kanji", "term", "japanese", "単語", "語彙", "front", "key")


class AnkiUnavailable(Exception):
    pass


def helper_path() -> Path:
    return Path(os.environ.get("JPQUIZ_ANKI_ADD", Path.home() / ".local/bin/anki-add"))


def invoke(action: str, timeout: float = 3.0, **params):
    """Call AnkiConnect (read-only actions only)."""
    if action not in READ_ACTIONS:
        raise ValueError(f"jp-quiz never sends the write action {action!r} to AnkiConnect")
    body = json.dumps({"action": action, "version": 6, "params": params}).encode()
    req = urllib.request.Request(ANKI_URL, body, {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            res = json.load(r)
    except (urllib.error.URLError, OSError, TimeoutError, ValueError) as e:
        raise AnkiUnavailable(str(e)) from None
    if isinstance(res, dict) and res.get("error"):
        raise AnkiUnavailable(str(res["error"]))
    return res["result"] if isinstance(res, dict) else res


# ---------------------------------------------------------------------------- adding

class Outbox:
    """Local queue in front of the shared anki-add helper."""

    def __init__(self, data_dir: Path):
        self.path = Path(data_dir) / "anki-queue.jsonl"

    def pending(self) -> list[dict]:
        if not self.path.exists():
            return []
        out = []
        for line in self.path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
        return out

    def _write(self, notes: list[dict]):
        if notes:
            self.path.write_text("".join(json.dumps(n, ensure_ascii=False) + "\n" for n in notes), encoding="utf-8")
        elif self.path.exists():
            self.path.unlink()

    def add(self, note: dict) -> dict:
        notes = self.pending() + [note]
        self._write(notes)
        return self.flush()

    def flush(self) -> dict:
        notes = self.pending()
        helper = helper_path()
        if not notes:
            return {"status": "empty", "sent": 0, "queued": 0}
        if not (helper.exists() and os.access(helper, os.X_OK)):
            return {"status": "queued", "sent": 0, "queued": len(notes),
                    "message": "anki-add helper not installed yet; kept in the quiz's queue"}
        left, sent, err, last = [], 0, "", ""
        for n in notes:
            try:
                p = subprocess.run([str(helper)], input=json.dumps(n, ensure_ascii=False), text=True,
                                   capture_output=True, timeout=20)
            except (OSError, subprocess.TimeoutExpired) as e:
                left.append(n)
                err = str(e)
                continue
            # helper exit codes: 0 added, 2 duplicate, 3 queued by the helper (Anki closed), 1 error
            if p.returncode in (0, 2, 3):
                sent += 1
                try:
                    last = json.loads(p.stdout.strip().splitlines()[-1]).get("status", "")
                except (ValueError, IndexError, AttributeError):
                    last = "added"
            else:
                left.append(n)
                err = (p.stderr or p.stdout).strip()[-200:]
        self._write(left)
        status = "sent" if not left else "partial"
        if status == "sent" and last in ("duplicate", "queued"):
            status = last
        return {"status": status, "sent": sent, "queued": len(left), "message": err}


def _strip(html: str) -> str:
    s = re.sub(r"<[^>]+>", "", html or "")
    s = re.sub(r"\[[^\]]*\]", "", s)          # furigana notation 漢字[かんじ]
    s = s.replace("&nbsp;", " ").strip()
    return re.sub(r"\s+", "", s)


def card_word(fields: dict) -> str | None:
    """Pick the Japanese headword of a note: a named word field, else the first short Japanese field."""
    items = sorted(fields.items(), key=lambda kv: kv[1].get("order", 0))
    named = [(k, v) for k, v in items if k.lower().strip() in WORD_FIELDS]
    for k, v in named + items:
        w = _strip(v.get("value", ""))
        if 1 <= len(w) <= 12 and re.search(r"[぀-ヿ一-鿿]", w) and not re.search(r"[A-Za-z]", w):
            return w
    return None


def read_cards(deck_filter=None, exclude=(DECK, "Japanese::Quiz", "Default")) -> dict:
    """Read review data of the user's Japanese decks. Raises AnkiUnavailable when Anki is closed."""
    invoke("version", timeout=2.0)
    # every deck except the quiz's own; non-Japanese cards drop out in card_word()
    decks = [d for d in invoke("deckNames") if (deck_filter is None or deck_filter.search(d))
             and not any(d == x or d.startswith(x + "::") for x in exclude)]
    if not decks:
        return {"decks": [], "cards": []}
    query = " OR ".join(f'"deck:{d}"' for d in decks)
    ids = invoke("findCards", query=f"({query}) -is:new")
    cards = []
    for i in range(0, len(ids), 400):
        for c in invoke("cardsInfo", cards=ids[i:i + 400], timeout=15.0):
            w = card_word(c.get("fields", {}))
            if not w:
                continue
            cards.append({"word": w, "interval": c.get("interval", 0), "ease": (c.get("factor") or 2500) / 1000.0,
                          "lapses": c.get("lapses", 0), "reps": c.get("reps", 0), "deck": c.get("deckName", "")})
    return {"decks": decks, "cards": cards}


def classify(card: dict) -> str:
    """known / weak / learning from Anki's own review data.

    Ease is ignored on purpose: with FSRS (or after "ease hell") it is often pinned at 1.3/2.5
    and says little.  Interval and lapses are what matter.
    """
    iv, lapses = card["interval"], card["lapses"]
    if lapses >= 6 or (lapses >= 4 and iv < 21):
        return "weak"
    if iv >= 21:
        return "known"
    return "learning"
