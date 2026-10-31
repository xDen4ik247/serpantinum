#!/usr/bin/env bash
# run_smartcharge.sh BIN OUTDIR — glass-smart-charge's decision (Rust `decide` vs the Python reference's decide())
# for the same history, calendar and learned speed, over a week of times, several battery levels and places.
# Two histories: a synthetic routine (home: unplug ~09:00 using 70 %, work: ~18:30 using 30 %) and, when it
# exists, a copy of the live one. Sandboxed HOME/XDG_STATE_HOME; nothing reads or writes the real battery.
set -u
BIN=$1; OUT=$2; H="$(cd "$(dirname "$0")" && pwd)"; REF="$H/../../reference/glass-smart-charge"
export TZ=Asia/Tokyo
mkdir -p "$OUT"; fail=0

run_case() {   # NAME HISTORY BASE_TS
    local name=$1 hist=$2 base=$3 d="$OUT/$1"
    mkdir -p "$d/state/glass-smart-charge" "$d/home/.cache/gcal-sync"
    cp "$hist" "$d/state/glass-smart-charge/history.jsonl"
    echo '{"rate_high": 0.55}' > "$d/state/glass-smart-charge/learned.json"
    # calendar: an in-person event in 30 h, an online one in 5 h, an all-day in-person one in 3 days
    python3 -I -c '
import json, sys
b = float(sys.argv[1]) * 1000
d = __import__("datetime").datetime.fromtimestamp(b / 1000 + 3 * 86400).date().isoformat()
json.dump({"events": [
    {"title": "Dentist appointment with a rather long title here", "location": "Clinic", "startMs": b + 30 * 3600e3},
    {"title": "Call", "location": "", "startMs": b + 5 * 3600e3},
    {"title": "Trip", "location": "Hills", "allDay": True, "startDate": d, "endMs": b + 4 * 86400e3}]}, open(sys.argv[2], "w"))
' "$base" "$d/home/.cache/gcal-sync/events.json"
    local locs; locs=$(python3 -I -c '
import json, sys
locs = {"newplace"}
for l in open(sys.argv[1]):
    try: locs.add(json.loads(l)["loc"])
    except (ValueError, KeyError): pass
print(" ".join(sorted(locs)))' "$hist")
    : > "$d/cases"
    for ((t = base; t < base + 7 * 86400; t += 2333)); do
        for cap in 15 79 86 100; do for loc in $locs; do echo "$t $cap $loc" >> "$d/cases"; done; done
    done
    HOME="$d/home" XDG_STATE_HOME="$d/state" python3 -I -c '
import importlib.machinery, json, sys
m = importlib.machinery.SourceFileLoader("gsc", sys.argv[1]).load_module()
for line in open(sys.argv[2]):
    t, cap, loc = line.split()
    print(json.dumps(list(m.decide(float(t), int(cap), loc))))
' "$REF" "$d/cases" > "$d/python.jsonl" || { echo "$name: python reference failed"; return 1; }
    while read -r t cap loc; do
        HOME="$d/home" XDG_STATE_HOME="$d/state" "$BIN" decide "$t" "$cap" "$loc"
    done < "$d/cases" > "$d/rust.jsonl"
    python3 -I -c '
import json, sys, collections
a = [json.loads(l) for l in open(sys.argv[1])]; b = [json.loads(l) for l in open(sys.argv[2])]
bad = [(i, x, y) for i, (x, y) in enumerate(zip(a, b)) if x != y]
codes = collections.Counter(x[1] for x in a)
print(f"{sys.argv[3]}: {len(a)} cases, {len(bad)} differ; codes {dict(codes)}")
for i, x, y in bad[:10]: print("  case", i, "python", x, "rust", y)
sys.exit(1 if bad or len(a) != len(b) or not a else 0)
' "$d/python.jsonl" "$d/rust.jsonl" "$name"
}

# synthetic routine: 21 days before BASE
BASE=1790000000
python3 -I -c '
import json, sys
b = int(sys.argv[1]); out = open(sys.argv[2], "w")
def ev(k, ts, cap, loc): out.write(json.dumps({"ev": k, "ts": ts, "cap": cap, "loc": loc}) + "\n")
for d in range(21, 0, -1):
    day = b - d * 86400 - (b % 86400)
    if d % 7 in (2, 3):   # two days a week only home, late
        ev("unplug", day + 11 * 3600, 100, "home"); ev("plug", day + 15 * 3600, 40, "home"); continue
    ev("unplug", day + 0 * 3600 + 7 * 60 * d % 40, 100, "home")      # 09:00 JST is 00:00 UTC
    ev("plug", day + 1 * 3600, 30, "work")
    ev("unplug", day + 9 * 3600 + 30 * 60, 95, "work")
    ev("plug", day + 11 * 3600, 65, "home")
    ev("unplug", day + 11 * 3600 + 300, 66, "home"); ev("plug", day + 11 * 3600 + 600, 66, "home")   # a jiggle
' "$BASE" "$OUT/synthetic.jsonl"
run_case synthetic "$OUT/synthetic.jsonl" "$BASE" || fail=1
head -n 8 "$OUT/synthetic.jsonl" > "$OUT/learning.jsonl"; echo 'not json' >> "$OUT/learning.jsonl"
run_case learning "$OUT/learning.jsonl" "$BASE" || fail=1
LIVE="${XDG_STATE_HOME:-$HOME/.local/state}/glass-smart-charge/history.jsonl"
if [ -s "$LIVE" ]; then
    cp "$LIVE" "$OUT/live.jsonl"   # frozen copy: the daemon keeps appending
    run_case live "$OUT/live.jsonl" "$(date +%s)" || fail=1
fi
exit $fail
