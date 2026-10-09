#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/caching.sh"

COMPOSITOR="$1"
PIPE="$QS_RUN_DIR/qs_kb_wait_$$.fifo"
mkfifo "$PIPE" 2>/dev/null
trap 'rm -f "$PIPE"; kill $(jobs -p) 2>/dev/null; exit 0' EXIT INT TERM

case "$COMPOSITOR" in
    niri)
        niri msg -j event-stream 2>/dev/null | jq --unbuffered -c 'select(has("KeyboardLayoutSwitched"))' > "$PIPE" &
        if command -v fcitx-layout >/dev/null; then
            fcitx-layout watch > "$PIPE" &
            # wake every 30 s anyway via read's own timeout (a `(sleep 30; echo tick)` subshell left
            # its sleep orphaned whenever the watcher was killed)
            READ_TIMEOUT=30
        fi
        ;;
    sway)
        swaymsg -t subscribe -m '["input"]' 2>/dev/null | jq --unbuffered -c 'select(.change == "xkb_layout" or .change == "xkb_keymap")' > "$PIPE" &
        ;;
    *)
        if [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
            LC_ALL=C socat -U - UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock 2>/dev/null | grep --line-buffered "activelayout>>" > "$PIPE" &
        else
            sleep 10 > "$PIPE" &
        fi
        ;;
esac

if [ -n "${READ_TIMEOUT:-}" ]; then
    read -r -t "$READ_TIMEOUT" _ <> "$PIPE"   # read-write open: never blocks, no EOF needed
else
    read -r _ < "$PIPE"
fi
sleep 0.05
