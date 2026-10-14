#!/usr/bin/env python3
"""compare_pure.py CORPUS PY_OUT RS_OUT -> mismatch count per function, first examples."""
import json, sys
corpus = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
a = [json.loads(l) for l in open(sys.argv[2], encoding="utf-8")]
b = [json.loads(l) for l in open(sys.argv[3], encoding="utf-8")]
assert len(a) == len(b) == len(corpus), (len(corpus), len(a), len(b))
stats, bad = {}, []
for req, x, y in zip(corpus, a, b):
    s = stats.setdefault(req["fn"], [0, 0])
    s[0] += 1
    if x != y:
        s[1] += 1
        bad.append((req, x, y))
print({k: f"{v[1]} / {v[0]} differ" for k, v in stats.items()})
for req, x, y in bad[:int(sys.argv[4]) if len(sys.argv) > 4 else 3]:
    print("---", req["fn"], repr(req.get("src", req.get("text", "")))[:600])
    print("py:", json.dumps(x, ensure_ascii=False)[:1500])
    print("rs:", json.dumps(y, ensure_ascii=False)[:1500])
sys.exit(1 if bad else 0)
