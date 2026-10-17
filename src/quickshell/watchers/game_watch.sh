#!/usr/bin/env bash
# Prints 1 while any game window is open on niri, 0 otherwise (only on change).
# A window is a game if its app_id looks like one (steam_app_*, gamescope, *.exe)
# or its process was started by Steam / Lutris (SteamGameId / LUTRIS_GAME_UUID in its env).

command -v niri >/dev/null || { echo 0; exec sleep infinity; }

is_game_pid() {
    [ -r "/proc/$1/environ" ] || return 1
    tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | grep -qE '^(SteamGameId=[1-9]|LUTRIS_GAME_UUID=.)'
}

check() {
    local app pid
    while IFS=$'\t' read -r app pid; do
        case "${app,,}" in
            steam|steamwebhelper) continue ;;
            steam_app_*|gamescope|*.exe) echo 1; return ;;
        esac
        [ -n "$pid" ] && [ "$pid" != null ] && is_game_pid "$pid" && { echo 1; return; }
    done < <(niri msg -j windows 2>/dev/null | jq -r '.[] | [(.app_id // ""), (.pid // "null" | tostring)] | @tsv')
    echo 0
}

last=""
emit() {
    local s; s=$(check)
    [ "$s" != "$last" ] && { echo "$s"; last="$s"; }
}

emit
niri msg -j event-stream 2>/dev/null \
    | jq --unbuffered -c 'select(has("WindowOpenedOrChanged") or has("WindowClosed") or has("WindowsChanged")) | 1' \
    | while read -r _; do emit; done
