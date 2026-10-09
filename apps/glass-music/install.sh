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
echo "installed to $DEST/app"
