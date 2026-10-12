#!/usr/bin/env bash
# run_powermode.sh IMPL OUT — power-mode scenarios against a mock UPower (private bus), a fake niri
# and shims for powerprofilesctl / systemctl; IMPL = rust|bash. Writes OUT/report.txt.
set -u
H="$(cd "$(dirname "$0")" && pwd)"; impl=$1; out=$2
rm -rf "$out"; mkdir -p "$out/home/.config" "$out/xdg" "$out/bin"
export HOME="$out/home" XDG_RUNTIME_DIR="$out/xdg" XDG_CONFIG_HOME="$out/home/.config" XDG_STATE_HOME="$out/home/.local/state"
echo balanced > "$out/profile"
cat > "$out/bin/powerprofilesctl" <<SH
#!/bin/sh
echo "powerprofilesctl \$*" >> "$out/calls.log"
case "\$1" in get) cat "$out/profile" ;; set) echo "\$2" > "$out/profile" ;; esac
SH
cat > "$out/bin/systemctl" <<SH
#!/bin/sh
echo "systemctl \$*" >> "$out/calls.log"
case "\$*" in *is-active*) echo active ;; *TimersCalendar*) echo "{ OnCalendar=*-*-* *:00/5:05 ; next_elapse=x }" ;;
  *TimersMonotonic*) printf '{ OnUnitActiveUSec=1h ; next_elapse=x }\n{ OnBootUSec=2min ; next_elapse=2min }\n' ;; esac
exit 0
SH
chmod +x "$out/bin/"*
export PATH="$out/bin:$PATH"
dbus-daemon --session --nofork --address="unix:path=$out/bus" >/dev/null 2>&1 & D=$!
sleep 0.3
export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$out/bus"
python3 "$H/powermode/mock_upower.py" false & U=$!
python3 "$H/fake_niri.py" "$out/niri.sock" "$out/niri.log" "$H/scripts/dwt.jsonl" & N=$!   # (only its outputs are used)
export NIRI_SOCKET="$out/niri.sock"
sleep 0.6
battery() { gdbus call --address "unix:path=$out/bus" --dest org.freedesktop.UPower --object-path /org/freedesktop/UPower --method test.Control.SetOnBattery "$1" >/dev/null; }
if [ "$impl" = rust ]; then PM="$H/../../target/release/power-mode"; else PM="${POWERMODE_SH:-$H/../../reference/power-mode}"; fi
conf() { printf '%s\n' "$@" > "$XDG_CONFIG_HOME/power-mode.conf"; }
R="$out/report.txt"
step() {   # step NAME CMD...
    { echo "### $1"; shift; "$@" 2>&1; echo "rc=$?"
      for f in mode llm.env; do echo "$f: $(cat "$XDG_STATE_HOME/power-mode/$f" 2>/dev/null)"; done
      echo "applied: $(cut -d' ' -f1 "$XDG_STATE_HOME/power-mode/applied" 2>/dev/null)"
      for f in "$XDG_RUNTIME_DIR"/systemd/user/*.timer.d/power-mode.conf; do [ -f "$f" ] && { echo "-- ${f#$XDG_RUNTIME_DIR/}"; cat "$f"; }; done
      echo "calls:"; cat "$out/calls.log" 2>/dev/null; : > "$out/calls.log"
      echo "niri:"; grep -v '"Outputs"\|EventStream' "$out/niri.log" 2>/dev/null; : > "$out/niri.log"
    } >> "$R"
}
conf "SAVE_GCAL_ONCALENDAR='*:0/5:05'     # comment" "SAVE_REFRESH=120.000"
step "save on AC" "$PM" save
step "save again (nothing changes)" "$PM" save
step "perf" "$PM" perf
battery true
step "auto on battery" "$PM" auto
conf "SAVE_REFRESH=60.001"
step "refresh 60" "$PM" apply
conf "SAVE_REFRESH=75"
step "refresh not offered" "$PM" apply
conf "OUTPUT=HDMI-A-1"
step "unknown output" "$PM" apply
conf "SWITCH_PROFILE=0" "SWITCH_TIMERS=0" "SWITCH_REFRESH=0" "SAVE_LLM_IDLE=5min"
step "switches off" "$PM" apply
step "quiet" env QUIET=1 "$PM" apply
step "bad argument" "$PM" bogus
conf ""
"$PM" daemon > "$out/daemon.out" 2>&1 & P=$!
sleep 1.5; battery false; sleep 2; battery true; sleep 2
kill -TERM $P; wait $P 2>/dev/null
{ echo "### daemon"; cat "$out/daemon.out"; echo "calls:"; cat "$out/calls.log"; } >> "$R"
kill $U $N $D 2>/dev/null; pkill -P $$ 2>/dev/null; wait 2>/dev/null
