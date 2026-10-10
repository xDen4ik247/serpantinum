#!/usr/bin/env bash
# sync-from-system.sh — copy the live desktop setup from this machine into the repo.
#
#   tools/sync-from-system.sh            copy everything, then show `git status`
#
# It only READS from $HOME and only WRITES inside the repo. It never copies secrets or
# personal data: no models, databases, caches, calendar links, notes, music, backups,
# Wi-Fi profiles or private working notes. Location data in settings.json is stripped, and
# every copied file is run through private anonymisation rules
# (~/.config/serp-glass/anon.sed, kept outside the repo).
# Review `git diff` and run tools/check-secrets.sh before committing.
set -euo pipefail

R="$(cd "$(dirname "$0")/.." && pwd)"
H="$HOME"
RS=(rsync -a --exclude=__pycache__ --exclude='*.pyc')

copy() {   # copy <path relative to $HOME> [dest dir inside repo, default home/]
    local src="$H/$1" dst="$R/${2:-home}/$1"
    [ -e "$src" ] || { echo "  skip (missing): ~/$1"; return 0; }
    mkdir -p "$(dirname "$dst")"
    if [ -d "$src" ]; then "${RS[@]}" "$src/" "$dst/"; else "${RS[@]}" "$src" "$dst"; fi
}

echo ":: Serpantinum source (installed tree -> src/)"
"${RS[@]}" --exclude=version.txt "$H/.local/share/serpantinum/src/" "$R/src/"

echo ":: dotfiles -> home/"
copy .config/niri/config.kdl
copy .config/niri/user
copy .config/kitty/user.conf
copy .config/fcitx5/profile
copy .config/fcitx5/config
copy .config/fcitx5/conf/mozc.conf
copy .config/fcitx5/conf/notifications.conf
copy .config/autostart/org.fcitx.Fcitx5.desktop
copy .local/share/dbus-1/services/org.fcitx.Fcitx5.service
copy .config/mpd/mpd.conf
copy .config/rmpc
copy .config/starship.toml
copy .zshrc
copy .zshenv
copy .zprofile
copy .local/share/applications/jp-quiz.desktop
copy .local/share/applications/glass-music.desktop

# Serpantinum settings without the exact location
python3 - "$H/.config/serpantinum/settings.json" "$R/home/.config/serpantinum/settings.json" <<'EOF'
import json, os, sys
d = json.load(open(sys.argv[1]))
d.get("general", {}).pop("location", None)
def strip(o):   # drop runtime timestamps (when features were last used)
    if isinstance(o, dict):
        for k in [k for k in o if k.endswith(("StartTime", "EndTime", "updated_at", "LastUsed"))]:
            o.pop(k)
        for v in o.values(): strip(v)
    elif isinstance(o, list):
        for v in o: strip(v)
strip(d)
os.makedirs(os.path.dirname(sys.argv[2]), exist_ok=True)
json.dump(d, open(sys.argv[2], "w"), indent=2, ensure_ascii=False)
open(sys.argv[2], "a").write("\n")
EOF

echo ":: systemd user units"
mkdir -p "$R/home/.config/systemd/user"
for u in "$H"/.config/systemd/user/*.service "$H"/.config/systemd/user/*.timer "$H"/.config/systemd/user/*.path "$H"/.config/systemd/user/*.socket; do
    [ -f "$u" ] && "${RS[@]}" "$u" "$R/home/.config/systemd/user/"
done
copy .config/systemd/user/mpd.service.d
copy .config/systemd/user/mpd-mpris.service.d

echo ":: scripts (~/.local/bin, our own only)"
for s in niri-autofit niri-dwt-toggle fcitx-layout ime-fix serp-tweaks niri-keys \
         music-ctl music-player music-smart \
         gcal-setup gcal-sync \
         ai ai-chat aidict aipanel ai-notes ai-notes-panel anki-add jocr \
         greeter-sync jp-quiz glass-music power-mode niri-focus-or-run sleep-guard; do
    copy ".local/bin/$s"
done

echo ":: feature code (~/.local/share, sources only)"
copy .local/share/aifeat
copy .local/share/ai-notes/ai_notes.py
copy .local/share/ai-notes/ui
copy .local/share/gcal-sync/gcal_sync.py
copy .local/share/gcal-sync/gcal_parse.py
for f in gcal_rec.py gcal_store.py gcal_google.py; do copy ".local/share/gcal-sync/$f"; done
copy .local/share/gcal-sync/tests
copy .local/share/npu-ocr/jocr
copy .local/share/npu-ocr/ui

echo ":: apps (committed files of ~/Projects/<app> only)"
for app in jp-quiz glass-music; do
    if git -C "$H/Projects/$app" rev-parse -q --verify HEAD >/dev/null 2>&1; then
        rm -rf "$R/apps/$app" && mkdir -p "$R/apps/$app"
        git -C "$H/Projects/$app" archive HEAD | tar -x -C "$R/apps/$app"
    fi
done

echo ":: SDDM greeter theme -> system/"
if [ -d /usr/share/sddm/themes/serp-glass ]; then
    mkdir -p "$R/system/sddm/themes/serp-glass"
    "${RS[@]}" --no-links --exclude=theme.conf.user --exclude="assets/bg*.jpg" /usr/share/sddm/themes/serp-glass/ "$R/system/sddm/themes/serp-glass/"
fi
[ -f /etc/sddm.conf.d/20-serp-glass.conf ] && { mkdir -p "$R/system/sddm/sddm.conf.d"; cp /etc/sddm.conf.d/20-serp-glass.conf "$R/system/sddm/sddm.conf.d/"; }

echo ":: root config (battery)"
for f in /etc/udev/rules.d/60-battery-pci-runtime-pm.rules /etc/sysctl.d/60-battery.conf; do
    [ -f "$f" ] && { mkdir -p "$R/system$(dirname "$f")"; cp "$f" "$R/system$f"; }
done

echo ":: anonymise"
ANON="${XDG_CONFIG_HOME:-$HOME/.config}/serp-glass/anon.sed"
if [ -f "$ANON" ]; then
    pat=$(sed -n 's/^s|\([^|]*\)|.*/\1/p' "$ANON" | paste -sd'|')
    git -C "$R" diff --name-only f11dab1 -- home system src apps docs tools 2>/dev/null > /tmp/.sync-files.$$
    git -C "$R" ls-files --others --exclude-standard -- home system src apps docs tools >> /tmp/.sync-files.$$
    (cd "$R" && sort -u /tmp/.sync-files.$$ | while read -r f; do [ -f "$f" ] && grep -qIE "$pat" "$f" && sed -i -f "$ANON" "$f"; done)
    rm -f /tmp/.sync-files.$$
else
    echo "!! $ANON not found — files NOT anonymised, do not commit"
fi

echo
git -C "$R" status --short | head -40
echo "(review with git diff; run tools/check-secrets.sh before committing)"
