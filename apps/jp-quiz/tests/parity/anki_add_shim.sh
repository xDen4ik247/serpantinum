#!/bin/sh
# Stand-in for ~/.local/bin/anki-add: records the note; the exit code follows the note's tags
# (N3 -> 2 duplicate, N4 -> 3 queued by the helper, else 0 added).
note=$(cat)
echo "$note" >> "$(dirname "$0")/added.jsonl"
case "$note" in
    *'"N3"'*) echo '{"status": "duplicate"}'; exit 2 ;;
    *'"N4"'*) echo '{"status": "queued"}'; exit 3 ;;
esac
echo '{"status": "added"}'
