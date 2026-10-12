#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/caching.sh"
# glass: serp-wellbeing (Rust) on niri; the Python daemon everywhere else or when it isn't installed
if [ -n "$NIRI_SOCKET" ] && command -v serp-wellbeing >/dev/null 2>&1; then
    exec serp-wellbeing
fi
exec python3 "$(dirname "$0")/focus_daemon.py" 
