#!/usr/bin/env bash
# run_focus.sh IMPL OUTDIR — run a focus tracker against the scripted fake niri; IMPL = rust|bash
set -u
H="$(cd "$(dirname "$0")" && pwd)"; impl=$1; out=$2
rm -rf "$out"; mkdir -p "$out/run"
python3 "$H/fake_niri.py" "$out/niri.sock" "$out/requests.log" "$H/scripts/focus.jsonl" & F=$!
sleep 0.3
# sandbox the runtime dir too: caching.sh re-derives the run dirs from it
mkdir -p "$out/xdg"
export NIRI_SOCKET="$out/niri.sock" XDG_RUNTIME_DIR="$out/xdg" QS_RUN_FOCUSTIME="$out/xdg/serpantinum/focustime"
if [ "$impl" = rust ]; then cmd=("$H/../../target/release/serp-focus"); else cmd=(bash "${FOCUS_SH:-$H/../../../src/scripts/current_focus.sh}"); fi
"${cmd[@]}" > "$out/stdout" & P=$!
sleep "${RUN_SECS:-6}"
kill -TERM $P; sleep 0.2; kill $F 2>/dev/null
wait 2>/dev/null
