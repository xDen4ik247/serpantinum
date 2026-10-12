#!/usr/bin/env bash
# run_autofit.sh IMPL OUT — replay scripts/autofit.jsonl through the fake niri; IMPL = rust|python
set -u
H="$(cd "$(dirname "$0")" && pwd)"; impl=$1; out=$2
rm -rf "$out"; mkdir -p "$out/xdg/niri-autofit" "$out/bin"
printf '#!/bin/sh\necho "$@" >> "%s/notify.log"\n' "$out" > "$out/bin/notify-send"; chmod +x "$out/bin/notify-send"
python3 "$H/fake_niri.py" "$out/niri.sock" "$out/requests.log" "$H/scripts/autofit.jsonl" & F=$!
sleep 0.3
export NIRI_SOCKET="$out/niri.sock" XDG_RUNTIME_DIR="$out/xdg" PATH="$out/bin:$PATH" NIRI_AUTOFIT_DEBUG=1
if [ "$impl" = rust ]; then bin="$H/../../target/release/niri-autofit"; else bin="${AUTOFIT_PY:-$H/../../reference/niri-autofit}"; fi
"$bin" 2> "$out/stderr" & P=$!
# timeline (s after start): 4.2 scrolling on, 5.9 back to auto-fit (see the script's pauses)
sleep 4.2; echo 1 > "$out/xdg/niri-autofit/scroll-ids"; kill -USR1 $P
sleep 1.7; echo "" > "$out/xdg/niri-autofit/scroll-ids"; kill -USR1 $P
sleep 2.5; kill $P $F; wait 2>/dev/null
grep -v '"EventStream"' "$out/requests.log" > "$out/actions.log"
