#!/usr/bin/env bash
# run_wellbeing_live.sh OUT — run the serp-wellbeing daemon ~14 s against the fake niri in a sandbox:
# kitty focused 0-6 s, session locked 6-9 s, firefox after; app limit 3 s for kitty (notify-send stubbed).
set -u
H="$(cd "$(dirname "$0")" && pwd)"; out=$1; rm -rf "$out"; mkdir -p "$out"/{home,run,state,xdg/serpantinum/lock,bin}
cat > "$out/bin/notify-send" <<'SH'
#!/bin/sh
echo "$*" >> "$(dirname "$0")/../notify.log"
SH
chmod +x "$out/bin/notify-send"
echo '{"wellbeing": {"excludedApps": ["steam"], "overallDailyLimit": 0, "appLimits": {"kitty": 3}}}' > "$out/home/settings.json"
python3 - "$out/script.jsonl" <<'PY'
import json, sys
f = open(sys.argv[1], "w")
w = lambda i, a, t, foc: {"id": i, "app_id": a, "title": t, "workspace_id": 1, "is_focused": foc, "is_floating": False, "layout": {}}
f.write(json.dumps({"WorkspacesChanged": {"workspaces": [{"id": 1, "idx": 1, "output": "eDP-1", "is_active": True, "is_focused": True, "active_window_id": 1}]}}) + "\n")
f.write(json.dumps({"WindowsChanged": {"windows": [w(1, "kitty", "zsh", True), w(2, "firefox", "Docs — Mozilla Firefox", False)]}}) + "\n")
for _ in range(9):
    f.write(json.dumps({"sleep": 1.0}) + "\n")
    f.write(json.dumps({"WindowOpenedOrChanged": {"window": w(1, "kitty", "zsh", True)}}) + "\n")   # spinner-like churn
f.write(json.dumps({"WindowFocusChanged": {"id": 2}}) + "\n")
PY
python3 "$H/fake_niri.py" "$out/niri.sock" "$out/requests.log" "$out/script.jsonl" & F=$!
sleep 0.3
env PATH="$out/bin:$PATH" NIRI_SOCKET="$out/niri.sock" HOME="$out/home" XDG_RUNTIME_DIR="$out/xdg" \
    QS_RUN_FOCUSTIME="$out/run" QS_STATE_FOCUSTIME="$out/state" QS_SETTINGS="$out/home/settings.json" \
    "$H/../../target/release/serp-wellbeing" & P=$!
sleep 6; touch "$out/xdg/serpantinum/lock/locked"
sleep 3; rm "$out/xdg/serpantinum/lock/locked"
sleep 5.2; kill -TERM $P; wait $P; echo "exit $?"
kill $F
python3 - "$out" <<'PY'
import json, sqlite3, sys
o = sys.argv[1]
rows = sqlite3.connect(o + "/state/focustime.db").execute("SELECT app_class, seconds, app_title FROM focus_log").fetchall()
print("focus_log:", rows)
print("state current:", json.load(open(o + "/run/focustime_state.json"))["current"])
print("notify:", open(o + "/notify.log").read().strip() if __import__("os").path.exists(o + "/notify.log") else None)
print("niri requests:", sum(1 for _ in open(o + "/requests.log")))
PY
