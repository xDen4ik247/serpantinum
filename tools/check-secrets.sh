#!/usr/bin/env bash
# check-secrets.sh — scan everything this fork adds or changes (vs. upstream) for secrets and personal data.
# Exit code 1 if anything suspicious is found. Run before every commit / push.
set -uo pipefail
R="$(cd "$(dirname "$0")/.." && pwd)"
cd "$R"
BASE="${1:-f11dab1}"

mapfile -t files < <( { git diff --name-only "$BASE" -- ; git ls-files --others --exclude-standard; } | sort -u )
[ ${#files[@]} -gt 0 ] || { echo "nothing to scan"; exit 0; }

patterns=(
    'calendar\.google\.com/calendar/ical/[^ ]*/private'       # secret iCal links
    'gh[opsur]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'   # GitHub tokens
    'sk-[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}'         # API keys
    'xox[abprs]-[A-Za-z0-9-]{10,}'                             # Slack
    'AKIA[0-9A-Z]{16}'                                         # AWS
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    '(api[_-]?key|apikey|access[_-]?token|auth[_-]?token|secret|passw(or)?d)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"' ]{8,}'
    'TELEMETRY_ID'
    '^[[:space:]]*psk[[:space:]]*='                            # Wi-Fi keys
    'KAGGLE_KEY|"key"[[:space:]]*:[[:space:]]*"[0-9a-f]{32}"'  # kaggle.json
)

# Personal patterns (places, names, addresses) live OUTSIDE the repo so the list itself never leaks.
PRIVATE="${XDG_CONFIG_HOME:-$HOME/.config}/serp-glass/private-patterns"
if [ -f "$PRIVATE" ]; then
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] || patterns+=("(?i)$line")
    done < "$PRIVATE"
else
    echo "note: $PRIVATE not found — only generic patterns are checked"
fi

bad=0
for p in "${patterns[@]}"; do
    if [[ "$p" == "(?i)"* ]]; then
        hits=$(grep -nIiE -- "${p#(?i)}" "${files[@]}" 2>/dev/null || true)
    else
        hits=$(grep -nIE -- "$p" "${files[@]}" 2>/dev/null | grep -v '^tools/check-secrets.sh:' || true)
    fi
    if [ -n "$hits" ]; then
        if [[ "$p" == "(?i)"* ]]; then echo "!! private pattern matched"; else echo "!! pattern: $p"; fi
        echo "$hits" | cut -c1-220 | head -20
        bad=1
    fi
done
big=$(for f in "${files[@]}"; do [ -f "$f" ] && [ "$(stat -c %s "$f")" -gt 2000000 ] && echo "$f"; done)
[ -n "$big" ] && { echo "!! files over 2 MB:"; echo "$big"; bad=1; }
[ $bad = 0 ] && echo "ok: ${#files[@]} files scanned, nothing suspicious"
exit $bad
