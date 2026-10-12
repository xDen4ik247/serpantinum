#!/usr/bin/env bash
# run_dwt.sh IMPL OUT — replay scripts/dwt.jsonl through the fake niri; IMPL = rust|python
set -u
H="$(cd "$(dirname "$0")" && pwd)"; impl=$1; out=$2
rm -rf "$out"; mkdir -p "$out/home/.config/niri/user" "$out/home/.config/niri-dwt-toggle" "$out/xdg"
printf 'input {\n    touchpad {\n        tap\n        dwt\n        natural-scroll\n    }\n}\n' > "$out/home/.config/niri/user/input.kdl"
printf '# test rules\n^steam_app_\n!^mpv$\ntitle:^retro\n(unclosed\n' > "$out/home/.config/niri-dwt-toggle/overrides.conf"
python3 "$H/fake_niri.py" "$out/niri.sock" "$out/requests.log" "$H/scripts/dwt.jsonl" & F=$!
sleep 0.3
export NIRI_SOCKET="$out/niri.sock" XDG_RUNTIME_DIR="$out/xdg" HOME="$out/home" XDG_CONFIG_HOME="$out/home/.config"
if [ "$impl" = rust ]; then bin="$H/../../target/release/niri-dwt-toggle"; else bin="${DWT_PY:-python3 $H/../../reference/niri-dwt-toggle}"; fi
$bin 2> "$out/stderr" & P=$!
# trace every state of the dwt line
( last=""; while kill -0 $P 2>/dev/null; do s=$(grep -c '^ *dwt' "$out/home/.config/niri/user/input.kdl"); [ "$s" != "$last" ] && echo "$s" >> "$out/trace"; last=$s; sleep 0.02; done ) &
# 5.6 s in: someone comments dwt out by hand right before the ConfigLoaded event
sleep 5.5; sed -i 's|^        dwt$|        // dwt|' "$out/home/.config/niri/user/input.kdl"
sleep 3.4; kill -TERM $P; wait $P; kill $F; wait 2>/dev/null
sed -i 's/^niri-dwt-toggle: //' "$out/stderr"
