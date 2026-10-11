#!/usr/bin/env bash
# Install / update the runnable copy:  ./install.sh
# App -> ~/.local/share/glass-music/app, launcher -> ~/.local/bin/glass-music,
# desktop entry + icon -> ~/.local/share/{applications,icons}. Caches live in ~/.cache/glass-music.
set -euo pipefail
cd "$(dirname "$0")"
DEST="$HOME/.local/share/glass-music"
ICONS="$HOME/.local/share/icons/hicolor/scalable/apps"
mkdir -p "$DEST" "$HOME/.local/bin" "$HOME/.local/share/applications" "$ICONS"
rm -rf "$DEST/app.new"
mkdir -p "$DEST/app.new"
cp -r glassmusic qml assets "$DEST/app.new/"
find "$DEST/app.new" -name __pycache__ -prune -exec rm -rf {} +
rm -f "$DEST/app.new/qml/shaders/"*.frag
rm -rf "$DEST/app" && mv "$DEST/app.new" "$DEST/app"
install -m 755 bin/glass-music "$HOME/.local/bin/glass-music"
install -m 644 glass-music.desktop "$HOME/.local/share/applications/glass-music.desktop"
install -m 644 assets/icon/glass-music.svg "$ICONS/glass-music.svg"
gtk-update-icon-cache -q -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
update-desktop-database -q "$HOME/.local/share/applications" 2>/dev/null || true

# Yandex Music: yandex-music-downloader (pinned) + mutagen in their own venv, so the app backend
# stays dependency-free. The token lives in ~/.config/glass-music/yandex.json (sign in in the app).
YM_VENV="$DEST/yandex-venv"
YMD="git+https://github.com/llistochek/yandex-music-downloader@v3.5.5"
if command -v uv >/dev/null 2>&1; then
    [ -x "$YM_VENV/bin/python" ] || uv venv -q --python 3.13 "$YM_VENV"
    VIRTUAL_ENV="$YM_VENV" uv pip install -q "$YMD" mutagen \
        || echo "warning: could not install yandex-music-downloader (Yandex Music stays off)" >&2
else
    [ -x "$YM_VENV/bin/python" ] || python3 -m venv "$YM_VENV"
    "$YM_VENV/bin/pip" install -q "$YMD" mutagen \
        || echo "warning: could not install yandex-music-downloader (Yandex Music stays off)" >&2
fi
# daily likes sync (does nothing until signed in, or when "Sync every day" is off)
UNITS="$HOME/.config/systemd/user"
mkdir -p "$UNITS"
install -m 644 systemd/glass-music-yandex-sync.service systemd/glass-music-yandex-sync.timer "$UNITS/"
systemctl --user daemon-reload 2>/dev/null && systemctl --user enable --now glass-music-yandex-sync.timer >/dev/null 2>&1 || true
echo "installed to $DEST/app"
