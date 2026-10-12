#!/usr/bin/env bash
# wellbeing_diff.sh REAL_DB OUT — compare serp-wellbeing with focus_daemon.py on a copy of the DB.
set -eu
H="$(cd "$(dirname "$0")" && pwd)"; RS="$H/../../target/release/serp-wellbeing"
PY="${FOCUS_DAEMON_PY:-$H/../../../src/quickshell/guide/wellbeing/focus_daemon.py}"
db=$1; out=$2; rm -rf "$out"; mkdir -p "$out"
[ -f "$db" ] || { echo "no database at $db" >&2; exit 2; }
sandbox() {   # sandbox NAME -> env for one run with its own DB copy
    local d="$out/$1"; mkdir -p "$d/home" "$d/run" "$d/state"
    python3 -c "import sqlite3,sys; s=sqlite3.connect(sys.argv[1]); d=sqlite3.connect(sys.argv[2]); s.backup(d)" "$db" "$d/state/focustime.db"
    echo "HOME=$d/home QS_RUN_FOCUSTIME=$d/run QS_STATE_FOCUSTIME=$d/state QS_SETTINGS=$d/home/settings.json"
}
dumpdb() { python3 - "$1" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
for t in ("focus_log", "focus_hourly", "focus_intervals", "focus_minutes"):
    for r in sorted(c.execute(f"SELECT * FROM {t}").fetchall(), key=repr):
        print(t, r)
PY
}
python3 "$H/gen_wellbeing_replay.py" > "$out/replay.tsv"
fail=0
# 1) full_sync for the last 40 days on the real history
for i in $(seq 0 39); do
    d=$(date -d "-$i day" +%F)
    env $(sandbox py-dump) python3 -I "$H/wellbeing_ref.py" "$PY" dump "$d" > "$out/py-dump.json"
    env $(sandbox rs-dump) "$RS" --dump-sync "$d" > "$out/rs-dump.json"
    python3 -c "import json,sys; a,b=(json.load(open(f)) for f in sys.argv[1:]); sys.exit(a!=b)" "$out/py-dump.json" "$out/rs-dump.json" || { echo "DUMP DIFF $d"; fail=1; }
done
echo "full_sync: 40 days compared"
# 2) replay the same tick timeline through both, then compare state + every table
env $(sandbox py) python3 -I "$H/wellbeing_ref.py" "$PY" replay "$out/replay.tsv" > "$out/py-replay.json"
env $(sandbox rs) "$RS" --replay "$out/replay.tsv" > "$out/rs-replay.json"
python3 -c "import json,sys; a,b=(json.load(open(f)) for f in sys.argv[1:]); sys.exit(a!=b)" "$out/py-replay.json" "$out/rs-replay.json" && echo "replay state: same" || { echo "REPLAY STATE DIFF"; fail=1; }
python3 -c "import json,sys; a,b=(json.load(open(f)) for f in sys.argv[1:]); sys.exit(a!=b)" "$out/py/run/focustime_state.json" "$out/rs/run/focustime_state.json" && echo "state file: same" || { echo "STATE FILE DIFF"; fail=1; }
dumpdb "$out/py/state/focustime.db" > "$out/py-db.txt"; dumpdb "$out/rs/state/focustime.db" > "$out/rs-db.txt"
diff -q "$out/py-db.txt" "$out/rs-db.txt" >/dev/null && echo "database: same ($(wc -l < "$out/rs-db.txt") rows)" || { echo "DB DIFF"; diff "$out/py-db.txt" "$out/rs-db.txt" | head; fail=1; }
exit $fail
