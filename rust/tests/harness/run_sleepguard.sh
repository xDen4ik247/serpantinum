#!/usr/bin/env bash
# run_sleepguard.sh IMPL OUT — sleep-guard against a mock logind on a private bus, a fake niri and a
# fake quickshell; IMPL = rust|python. Runs in its own user + mount namespace with a private /tmp,
# because the recovery path removes /tmp/serpantinumd.{lock,pid} (the live shell's files).
#   timeline: 1.5 s suspend (unlocked) · 5 s resume · ~8 s shell found missing -> recovery
#             14 s the shell stops answering -> ~26 s recovery · 28 s answers again · 33 s unlock · 36 s stop
if [ -z "${SG_INNS:-}" ]; then exec env SG_INNS=1 unshare --map-root-user --mount -- "$0" "$@"; fi
mount -t tmpfs tmpfs /tmp || { echo "no private /tmp, refusing to run" >&2; exit 1; }
set -u
H="$(cd "$(dirname "$0")" && pwd)"; impl=$1; out=$2
rm -rf "$out"; mkdir -p "$out/home/.local/share/serpantinum/src/quickshell" "$out/xdg/serpantinum/lock" "$out/bin"
export SG_SANDBOX="$out" HOME="$out/home" XDG_RUNTIME_DIR="$out/xdg"
QML="$HOME/.local/share/serpantinum/src/quickshell/Shell.qml"
cc -O2 -o "$out/bin/quickshell" "$H/sleepguard/fake_quickshell.c"
cat > "$out/bin/pgrep" <<SH
#!/bin/sh
# only patterns that name the sandbox reach the real pgrep
case "\$*" in *"$out"*) exec /usr/bin/pgrep "\$@" ;; esac
echo "pgrep \$*" >> "$out/calls.log"; exit 1
SH
cat > "$out/bin/systemd-run" <<SH
#!/bin/sh
echo "systemd-run \$*" >> "$out/calls.log"; shift 4; exec "\$@"
SH
cat > "$out/bin/serpantinumd" <<SH
#!/bin/sh
echo "serpantinumd \$*" >> "$out/calls.log"; exec quickshell -p "$QML"
SH
chmod +x "$out/bin/"*
export PATH="$out/bin:$PATH"
dbus-daemon --session --nofork --address="unix:path=$out/bus" >/dev/null 2>&1 & D=$!
sleep 0.3
export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$out/bus" DBUS_SESSION_BUS_ADDRESS="unix:path=$out/bus"
python3 "$H/sleepguard/mock_logind.py" "$out/logind.log" & L=$!
FAKE_NIRI_EXEC=1 bash -c 'exec python3 "$0" "$1/niri.wayland-1.$$.sock" "$2"' "$H/fake_niri.py" "$XDG_RUNTIME_DIR" "$out/niri.log" & N=$!
sleep 0.8
emit() { gdbus call --address "unix:path=$out/bus" --dest org.freedesktop.login1 --object-path /org/freedesktop/login1 --method test.Control.Emit "$1" >/dev/null; }
if [ "$impl" = rust ]; then bin=("$H/../../target/release/sleep-guard"); else bin=(python3 "${SLEEPGUARD_PY:-$H/../../reference/sleep-guard}"); fi
"${bin[@]}" > "$out/stdout" 2> "$out/stderr" & P=$!
sleep 1.5; emit true
sleep 3.5; emit false
sleep 9;   echo 1 > "$out/ipc_show_rc"
sleep 14;  echo 0 > "$out/ipc_show_rc"
sleep 5;   rm -f "$XDG_RUNTIME_DIR/serpantinum/lock/locked"
sleep 3;   kill -TERM $P; wait $P; echo "exit $?" >> "$out/stdout"
sleep 0.5
pkill -f "quickshell -p $QML" ; kill $L $N $D; wait 2>/dev/null
ls "$XDG_RUNTIME_DIR" > "$out/xdg.ls"
