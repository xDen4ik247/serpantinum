"""Anki integration: read-only sync against a mock AnkiConnect, offline behaviour, add-queue."""

import json
import os
import sqlite3
import stat
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from jpquiz import anki
from jpquiz.engine import Engine
from tests.sim import make_content

CARDS = {
    1: {"word": "時間", "interval": 60, "factor": 2600, "lapses": 0},
    2: {"word": "食べる", "interval": 3, "factor": 1700, "lapses": 5},
    3: {"word": "猫", "interval": 100, "factor": 2500, "lapses": 0},
}


class MockAnki(BaseHTTPRequestHandler):
    seen = []

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        MockAnki.seen.append(req["action"])
        a, p = req["action"], req.get("params", {})
        if a == "version":
            res = 6
        elif a == "deckNames":
            res = ["Default", "Japanese::Core 2k", "Japanese::Quiz"]
        elif a == "findCards":
            res = list(CARDS)
        elif a == "cardsInfo":
            res = [{"cardId": i, "deckName": "Japanese::Core 2k", "interval": CARDS[i]["interval"],
                    "factor": CARDS[i]["factor"], "lapses": CARDS[i]["lapses"], "reps": 10,
                    "fields": {"Word": {"value": f"<b>{CARDS[i]['word']}</b>", "order": 0},
                               "Meaning": {"value": "something", "order": 1}}} for i in p["cards"]]
        else:
            res, err = None, "write action not allowed in this mock"
            self._send({"result": res, "error": err})
            return
        self._send({"result": res, "error": None})

    def _send(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, *a):
        pass


def engine_with_words(tmp: Path) -> Engine:
    content = tmp / "content.db"
    make_content(content, n=60)
    db = sqlite3.connect(content)
    extra = [("x:read", "kread", 4, "read:時間", ["k:時", "k:間", "w:時間"], "kanji"),
             ("x:use", "vocab", 5, "use:食べる", ["w:食べる"], "vocab")]
    for key, kind, lv, kc, tags, cat in extra:
        db.execute("INSERT INTO items(key,kind,level,kc,tags,cat,seed,sid,flags,payload) VALUES (?,?,?,?,?,?,?,?,?,?)",
                   (key, kind, lv, kc, json.dumps(tags), cat, 0.0, 1, 0,
                    json.dumps({"choices": ["じかん", "じけん", "しかん", "じがん"], "word": "時間", "full": "時間がない。",
                                "sent": [{"t": "時間", "r": "じかん"}, {"t": "がない。"}], "en": "There is no time.",
                                "gloss": "time"})))
    db.commit()
    db.close()
    return Engine(str(content), str(tmp / "progress.db"), seed=1)


class TestAnki(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = ThreadingHTTPServer(("127.0.0.1", 0), MockAnki)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.url = f"http://127.0.0.1:{cls.srv.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="jpq-anki-"))
        self.old_url = anki.ANKI_URL

    def tearDown(self):
        anki.ANKI_URL = self.old_url
        os.environ.pop("JPQUIZ_ANKI_ADD", None)

    def test_sync_reads_only_and_seeds_model(self):
        anki.ANKI_URL = self.url
        MockAnki.seen.clear()
        eng = engine_with_words(self.tmp)
        r = eng.anki_sync()
        self.assertTrue(r["ok"], r)
        self.assertEqual((r["known"], r["weak"]), (1, 1))
        self.assertTrue(set(MockAnki.seen) <= anki.READ_ACTIONS, MockAnki.seen)
        self.assertNotIn("Japanese::Quiz", r["decks"])
        now = time.time()
        self.assertEqual(eng.cards["read:時間"].state, "review")
        self.assertGreater(eng.cards["read:時間"].due, now + 30 * 86400)        # well known: not due for weeks
        self.assertLessEqual(eng.cards["use:食べる"].due, now)                  # weak: due right away
        self.assertGreaterEqual(eng.model.peek("tag:w:時間")[0], 0.7)
        self.assertLess(eng.model.peek("tag:w:食べる")[0], 0)

    def test_offline_is_harmless(self):
        anki.ANKI_URL = "http://127.0.0.1:9"       # nothing listens there
        eng = engine_with_words(self.tmp)
        r = eng.anki_sync()
        self.assertFalse(r["ok"])
        with self.assertRaises(ValueError):
            anki.invoke("addNote", note={})          # write actions are refused locally

    def test_outbox_queues_then_flushes_through_helper(self):
        os.environ["JPQUIZ_ANKI_ADD"] = str(self.tmp / "missing-helper")
        eng = engine_with_words(self.tmp)
        it = eng.by_key["x:read"]
        payload = json.loads(eng.cdb.execute("SELECT payload FROM items WHERE key='x:read'").fetchone()[0])
        eng.last_answered = (it, payload)
        r = eng.anki_add_last()
        self.assertEqual(r["status"], "queued")
        self.assertEqual(len(eng.outbox.pending()), 1)
        note = eng.outbox.pending()[0]
        self.assertEqual(note["deck"], "Japanese::Quiz")
        self.assertEqual((note["expression"], note["reading"]), ("時間", "時間[じかん]"))
        self.assertIn("<b>時間</b>", note["sentence"])
        # the shared helper appears: the queue is flushed into it
        got = self.tmp / "got.jsonl"
        helper = self.tmp / "anki-add"
        helper.write_text(f"#!/bin/sh\ncat >> {got}\necho >> {got}\n")
        helper.chmod(helper.stat().st_mode | stat.S_IEXEC)
        os.environ["JPQUIZ_ANKI_ADD"] = str(helper)
        r = eng.outbox.flush()
        self.assertEqual((r["sent"], r["queued"]), (1, 0))
        self.assertEqual(json.loads(got.read_text().strip())["expression"], "時間")


if __name__ == "__main__":
    unittest.main()
