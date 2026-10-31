#!/usr/bin/env bash
# run_smartcharge_daemon.sh BIN OUTDIR — the glass-smart-charge daemon against a fake /sys/class/power_supply:
# the limit is written while on battery, a plug on the USB-C supply (ACPI AC0 still offline) counts as AC and is
# logged, a battery held at 97 % on AC shows "drain", SIGTERM exits 0. Sandboxed HOME/XDG_STATE_HOME, fake nmcli
# and systemctl; the real battery is never touched.
set -u
BIN=$1; OUT=$2; S="$OUT/sys"; ST="$OUT/state/glass-smart-charge"
rm -rf "$OUT"; mkdir -p "$S/AC0" "$S/BAT0" "$S/ucsi-source-psy-1" "$ST" "$OUT/bin" "$OUT/home"
echo Mains > "$S/AC0/type"; echo 0 > "$S/AC0/online"
echo USB > "$S/ucsi-source-psy-1/type"; echo System > "$S/ucsi-source-psy-1/scope"; echo 0 > "$S/ucsi-source-psy-1/online"
echo Battery > "$S/BAT0/type"; echo 97 > "$S/BAT0/capacity"; echo Discharging > "$S/BAT0/status"
echo 100 > "$S/BAT0/charge_control_end_threshold"
echo 80 > "$ST/mode"
printf '#!/bin/sh\necho "Home:802-11-wireless"\n' > "$OUT/bin/nmcli"
printf '#!/bin/sh\necho "$@" >> "%s/notify.log"\n' "$OUT" > "$OUT/bin/notify-send"
printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/systemctl"
chmod +x "$OUT/bin/"*
export PATH="$OUT/bin:$PATH" HOME="$OUT/home" XDG_STATE_HOME="$OUT/state" GLASS_SMART_CHARGE_SYS="$S" TZ=Asia/Tokyo
j() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$ST/status.json" "$1"; }
"$BIN" daemon & pid=$!
sleep 1
ok=1
[ "$(cat "$S/BAT0/charge_control_end_threshold")" = 80 ] || { echo "limit not written on battery"; ok=0; }
[ "$(j ac)" = False ] || { echo "ac should be false"; ok=0; }
echo 1 > "$S/ucsi-source-psy-1/online"; echo "Not charging" > "$S/BAT0/status"
kill -USR1 $pid; sleep 1
[ "$(j ac)" = True ] || { echo "USB-C plug not seen as AC"; ok=0; }
[ "$(j code)" = drain ] || { echo "code $(j code), want drain"; ok=0; }
grep -q '"ev": "plug"' "$ST/history.jsonl" 2>/dev/null || { echo "plug not logged"; ok=0; }
[ ! -e "$OUT/notify.log" ] || { echo "notified before 30 min"; ok=0; }
echo 1 > "$S/ucsi-source-psy-1/online"; echo 82 > "$S/BAT0/capacity"; kill -USR1 $pid; sleep 1
[ "$(j code)" = manual80 ] || { echo "code $(j code) at 82 %, want manual80"; ok=0; }
kill -TERM $pid; wait $pid; rc=$?
[ $rc = 0 ] || { echo "exit $rc"; ok=0; }
cat "$ST/status.json"; echo; cat "$ST/history.jsonl"
[ $ok = 1 ]
