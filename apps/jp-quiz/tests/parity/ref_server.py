#!/usr/bin/env python3
"""The Python engine (jpquiz/server.py) with the Rust binary's test hooks: JPQUIZ_SEED seeds
random.Random, and a request's "_now" field sets the clock. Used by run.py only."""
import json, os, sys, time
sys.path.insert(0, os.environ["JPQUIZ_APP"])
from jpquiz import engine, server

clock = [float(os.environ["JPQUIZ_TEST_NOW"]) if os.environ.get("JPQUIZ_TEST_NOW") else None]
seed = int(os.environ["JPQUIZ_SEED"])


class TestEngine(engine.Engine):
    def __init__(self, content, progress):
        super().__init__(content, progress, now=lambda: clock[0] if clock[0] is not None else time.time(), seed=seed)


class Input:
    def __init__(self, f):
        self.f = f

    def __iter__(self):
        for line in self.f:
            try:
                r = json.loads(line)
                if isinstance(r, dict) and "_now" in r:
                    clock[0] = float(r["_now"])
            except ValueError:
                pass
            yield line


server.Engine = TestEngine
sys.stdin = Input(sys.stdin)
server.main()
