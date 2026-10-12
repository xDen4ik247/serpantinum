#!/usr/bin/env bash
# tests/run-all.sh [OUTDIR] [--live] — the Rust helpers against the implementations they replace.
#
# Unit tests, then one differential test per helper: the same input goes through the original
# (bash/Python, from src/ and rust/reference/) and the Rust binary, and their observable behaviour
# is compared: stdout, files written, niri requests, D-Bus inhibitors, commands run.
# Everything runs in sandboxes (own HOME / XDG dirs, a fake niri socket, private D-Bus buses, and a
# private /tmp for sleep-guard); nothing touches the running desktop.
#   --live   also compare serp-niri-state with the running niri (read-only)
#   WELLBEING_DB=path   history to test serp-wellbeing on (a copy is used); default: the live one if present
set -u
H="$(cd "$(dirname "$0")/harness" && pwd)"; R="$(cd "$H/../.." && pwd)"
OUT="${1:-$(mktemp -d)}"; [ "${1:-}" = --live ] && OUT="$(mktemp -d)"; mkdir -p "$OUT"
LIVE=0; for a in "$@"; do [ "$a" = --live ] && LIVE=1; done
cargo build --release --quiet --manifest-path "$R/Cargo.toml" || { echo "build failed"; exit 1; }
pass=0; fail=0
check() {
    local name=$1; shift
    if "$@" > "$OUT/$name.log" 2>&1; then echo "PASS  $name"; pass=$((pass + 1))
    else echo "FAIL  $name  (log: $OUT/$name.log)"; fail=$((fail + 1)); fi
}
same_json() { python3 -c "import json,sys; a,b=(json.load(open(f)) for f in sys.argv[1:]); sys.exit(a != b)" "$1" "$2"; }

t_unit() { cargo test --release --quiet --manifest-path "$R/Cargo.toml"; }

t_focus() {
    "$H/run_focus.sh" bash "$OUT/focus-bash" && "$H/run_focus.sh" rust "$OUT/focus-rust" || return 1
    local n='s/"timestamp":[0-9]+,//' f=xdg/serpantinum/focustime
    diff <(sed -E "$n" "$OUT/focus-bash/stdout") <(sed -E "$n" "$OUT/focus-rust/stdout") &&
    diff <(sed -E "$n" "$OUT/focus-bash/$f/focus_state.json") <(sed -E "$n" "$OUT/focus-rust/$f/focus_state.json") &&
    diff <(sed -E "$n" "$OUT/focus-bash/$f/focus_events.jsonl") <(sed -E "$n" "$OUT/focus-rust/$f/focus_events.jsonl") &&
    [ "$(wc -l < "$OUT/focus-rust/stdout")" -ge 10 ]
}

t_wellbeing() {
    local db="${WELLBEING_DB:-$HOME/.local/state/serpantinum/focustime/focustime.db}"
    if [ ! -f "$db" ]; then   # no history here: start from an empty database
        db="$OUT/empty.db"; python3 -c "import sqlite3,sys; sqlite3.connect(sys.argv[1]).execute('create table if not exists x(y)')" "$db"
    fi
    # one frozen snapshot: the live daemon keeps writing, so both sides must read the same history
    python3 -c "import sqlite3,sys; sqlite3.connect(sys.argv[1]).backup(sqlite3.connect(sys.argv[2]))" "$db" "$OUT/wellbeing-snap.db" &&
    "$H/wellbeing_diff.sh" "$OUT/wellbeing-snap.db" "$OUT/wellbeing"
}

t_wellbeing_names() {
    local d="$OUT/names"; mkdir -p "$d/run" "$d/state"
    python3 - > "$d/corpus.jsonl" <<'PY'
import json
ts = ["(3) Inbox — Mozilla Firefox", "[12] chat", "Title (4)", "a - b - c", "x | y", "a — b", "   spaced   ", "", "trailing (12)",
      "Ünïcödé — Браузер", "a very long terminal title that keeps going and going", "abc\t-\tdef", "foo -bar", "QS-Master",
      "(1)(2) x", "x\x1c", "Exactly twenty-five chars", "Exactly twenty-six chars!", "日本語のタイトル — アプリ", None]
for a in ["firefox", "kitty", "", "  spaced-app ", "ÉCLAIR", "org.quickshell", "Unknown", "Desktop", None]:
    for t in ts:
        print(json.dumps({"id": 1, "app_id": a, "title": t}))
print("null")
PY
    local env=(env HOME="$d" QS_RUN_FOCUSTIME="$d/run" QS_STATE_FOCUSTIME="$d/state")
    "${env[@]}" python3 -I "$H/wellbeing_ref.py" "$R/../src/quickshell/guide/wellbeing/focus_daemon.py" resolve < "$d/corpus.jsonl" > "$d/py.txt" &&
    "${env[@]}" "$R/target/release/serp-wellbeing" --resolve < "$d/corpus.jsonl" > "$d/rs.txt" &&
    python3 -c "import json,sys; a,b=([json.loads(l) for l in open(f)] for f in sys.argv[1:]); print(len(a), 'names'); sys.exit(a != b or len(a) < 100)" "$d/py.txt" "$d/rs.txt"
}

t_wellbeing_daemon() {
    "$H/run_wellbeing_live.sh" "$OUT/wellbeing-live" > "$OUT/wellbeing-live.txt" && cat "$OUT/wellbeing-live.txt" &&
    grep -q "('kitty', 5, 'zsh')\|('kitty', 6, 'zsh')" "$OUT/wellbeing-live.txt" &&
    grep -q "zsh daily limit reached" "$OUT/wellbeing-live.txt" && grep -q "^exit 0" "$OUT/wellbeing-live.txt"
}

t_autofit() {
    "$H/run_autofit.sh" python "$OUT/autofit-py" && "$H/run_autofit.sh" rust "$OUT/autofit-rust" || return 1
    diff "$OUT/autofit-py/actions.log" "$OUT/autofit-rust/actions.log" && [ "$(wc -l < "$OUT/autofit-rust/actions.log")" -ge 20 ] &&
    # the reference shells out to `niri msg event-stream`, which complains when the fake socket closes
    local noise='/^Error: error reading event from niri/,$d'
    diff <(sed "$noise" "$OUT/autofit-py/stderr") <(sed "$noise" "$OUT/autofit-rust/stderr")
}

t_dwt() {
    "$H/run_dwt.sh" python "$OUT/dwt-py" && "$H/run_dwt.sh" rust "$OUT/dwt-rust" || return 1
    local f=home/.config/niri/user/input.kdl strip='/bad pattern\|^    \|^error:/d'
    diff <(sed "$strip" "$OUT/dwt-py/stderr") <(sed "$strip" "$OUT/dwt-rust/stderr") &&
    # the 20 ms trace poll may or may not catch the restore-on-exit write: compare the common prefix,
    # the final file is compared exactly below
    local n; n=$(( $(wc -l < "$OUT/dwt-py/trace") < $(wc -l < "$OUT/dwt-rust/trace") ? $(wc -l < "$OUT/dwt-py/trace") : $(wc -l < "$OUT/dwt-rust/trace") ))
    [ "$n" -ge 6 ] && diff <(head -n "$n" "$OUT/dwt-py/trace") <(head -n "$n" "$OUT/dwt-rust/trace") && cmp "$OUT/dwt-py/$f" "$OUT/dwt-rust/$f" &&
    grep -q "bad pattern" "$OUT/dwt-rust/stderr" && [ "$(grep -c 'dwt O' "$OUT/dwt-rust/stderr")" -ge 6 ]
}

t_sleepguard() {
    "$H/run_sleepguard.sh" python "$OUT/sg-py" && "$H/run_sleepguard.sh" rust "$OUT/sg-rust" || return 1
    local d
    for d in sg-py sg-rust; do
        sed -E 's/after [0-9.]+s/after Ns/; s/\(pid [0-9]+\)/(pid N)/' "$OUT/$d/stdout" > "$OUT/$d/n.stdout"
        # logind events without times; durations to whole seconds
        sed -E 's/^ *[0-9.]+ //' "$OUT/$d/logind.log" | python3 -c "
import re,sys
for l in sys.stdin: print(re.sub(r'([0-9]+\.[0-9])s', lambda m: '%ds' % round(float(m.group(1))), l.rstrip()))" > "$OUT/$d/n.logind"
        grep -v EventStream "$OUT/$d/niri.log" | sed "s|$OUT/$d|SB|g" > "$OUT/$d/n.niri"
        sed "s|$OUT/$d|SB|g" "$OUT/$d/calls.log" | uniq > "$OUT/$d/n.calls"
    done
    for f in n.stdout n.logind n.niri n.calls; do diff "$OUT/sg-py/$f" "$OUT/sg-rust/$f" || return 1; done
    grep -q "shell restarted" "$OUT/sg-rust/stdout" && grep -q "release block after 4s" "$OUT/sg-rust/n.logind"
}

t_powermode() {
    "$H/run_powermode.sh" bash "$OUT/pm-bash" && "$H/run_powermode.sh" rust "$OUT/pm-rust" || return 1
    diff "$OUT/pm-bash/report.txt" "$OUT/pm-rust/report.txt" && grep -q '60.001 (transient)' "$OUT/pm-rust/report.txt"
}

t_live_niri_state() {
    python3 - "$R/target/release/serp-niri-state" <<'PY'
import json, subprocess, sys
K = ["id", "workspace_id", "app_id", "is_focused", "is_floating"]
ws = json.loads(subprocess.check_output(["niri", "msg", "-j", "workspaces"]))
win = json.loads(subprocess.check_output(["niri", "msg", "-j", "windows"]))
ref = {"workspaces": sorted(ws, key=lambda w: w["id"]), "windows": sorted(({k: w.get(k) for k in K} for w in win), key=lambda w: w["id"])}
got = json.loads(subprocess.check_output([sys.argv[1], "--once"]))
got = {"workspaces": sorted(got["workspaces"], key=lambda w: w["id"]), "windows": sorted(got["windows"], key=lambda w: w["id"])}
print(len(ref["workspaces"]), "workspaces,", len(ref["windows"]), "windows")
sys.exit(got != ref)
PY
}

check unit t_unit
check serp-focus t_focus
check serp-wellbeing-history t_wellbeing
check serp-wellbeing-names t_wellbeing_names
check serp-wellbeing-daemon t_wellbeing_daemon
check niri-autofit t_autofit
check niri-dwt-toggle t_dwt
check sleep-guard t_sleepguard
check power-mode t_powermode
[ "$LIVE" = 1 ] && check serp-niri-state-live t_live_niri_state
echo "$pass passed, $fail failed  (logs: $OUT)"
[ "$fail" = 0 ]
