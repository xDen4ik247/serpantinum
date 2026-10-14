#!/usr/bin/env python3
"""A read-only AnkiConnect stand-in: fake_anki.py PORT CARDS_JSON — answers version, deckNames,
findCards and cardsInfo from a JSON file {"decks": [...], "cards": [{deckName, interval, lapses, fields}]}.
Any other action is logged as a violation (jp-quiz must never write to Anki)."""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, data = int(sys.argv[1]), json.load(open(sys.argv[2]))


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        a, p = req["action"], req.get("params", {})
        if a == "version":
            res = 6
        elif a == "deckNames":
            res = data["decks"]
        elif a == "findCards":
            res = list(range(1, len(data["cards"]) + 1))
        elif a == "cardsInfo":
            res = [dict(data["cards"][i - 1], cardId=i) for i in p["cards"]]
        else:
            open(sys.argv[2] + ".violations", "a").write(a + "\n")
            res = None
        body = json.dumps({"result": res, "error": None}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


HTTPServer(("127.0.0.1", port), H).serve_forever()
