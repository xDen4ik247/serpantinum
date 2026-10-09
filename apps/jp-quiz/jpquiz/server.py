"""JSON-lines bridge between the QML window and the engine (stdin -> stdout).

Requests:  {"cmd": "hello"} | {"cmd": "next"} | {"cmd": "answer", "qid": 3, "choice": 1, "ms": 2300}
           {"cmd": "answer", "qid": 3, "order": ["本を", "読んで", "いる"]} | {"cmd": "skip", "qid": 3}
           {"cmd": "stats"} | {"cmd": "settings", "set": {"target": 0.8}}
Every reply is one JSON object per line, echoing the request's "rid".
"""

from __future__ import annotations

import json
import os
import sys
import traceback
from pathlib import Path

from jpquiz.engine import Engine


def data_dir() -> Path:
    d = Path(os.environ.get("JPQUIZ_DATA", Path.home() / ".local/share/jp-quiz"))
    d.mkdir(parents=True, exist_ok=True)
    return d


def main():
    d = data_dir()
    content = os.environ.get("JPQUIZ_CONTENT", str(d / "content.db"))
    progress = os.environ.get("JPQUIZ_PROGRESS", str(d / "progress.db"))
    eng = Engine(content, progress)
    out = sys.stdout
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            cmd = req.get("cmd")
            if cmd == "hello":
                res = eng.hello()
            elif cmd == "next":
                res = eng.next()
            elif cmd == "answer":
                res = eng.answer(int(req["qid"]), choice=req.get("choice"), order=req.get("order"), ms=int(req.get("ms", 0)))
            elif cmd == "skip":
                res = eng.answer(int(req["qid"]), skip=True, ms=int(req.get("ms", 0)))
            elif cmd == "stats":
                res = eng.stats()
            elif cmd == "settings":
                res = eng.set_settings(req.get("set", {}))
            elif cmd == "anki_add":
                res = eng.anki_add_last()
            elif cmd == "anki_sync":
                res = eng.anki_sync()
            elif cmd == "peek":
                res = eng.peek()
            elif cmd == "quit":
                break
            else:
                res = {"type": "error", "error": f"unknown cmd {cmd}"}
        except Exception as e:  # keep the bridge alive
            res = {"type": "error", "error": repr(e), "trace": traceback.format_exc()[-800:]}
        res["rid"] = req.get("rid") if isinstance(req, dict) else None
        out.write(json.dumps(res, ensure_ascii=False) + "\n")
        out.flush()


if __name__ == "__main__":
    main()
