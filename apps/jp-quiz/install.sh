#!/usr/bin/env bash
# Install / update the runnable copy:  ./install.sh
# App code -> ~/.local/share/jp-quiz/app, content DB -> ~/.local/share/jp-quiz/content.db,
# launcher -> ~/.local/bin/jp-quiz, desktop entry -> ~/.local/share/applications/jp-quiz.desktop,
# icon -> ~/.local/share/icons/hicolor/scalable/apps/jp-quiz.svg.
# Your progress (~/.local/share/jp-quiz/progress.db) is never touched.
set -euo pipefail
cd "$(dirname "$0")"
DEST="$HOME/.local/share/jp-quiz"
ICONS="$HOME/.local/share/icons/hicolor/scalable/apps"
mkdir -p "$DEST/app" "$HOME/.local/bin" "$HOME/.local/share/applications" "$ICONS"
[ -f data/content.db ] || { echo "data/content.db missing: run  ~/.venvs/jp-quiz/bin/python -m build.make_content  first"; exit 1; }
rm -rf "$DEST/app.new"
mkdir -p "$DEST/app.new"
cp -r jpquiz qml assets "$DEST/app.new/"
find "$DEST/app.new" -name __pycache__ -prune -exec rm -rf {} +
rm -rf "$DEST/app" && mv "$DEST/app.new" "$DEST/app"
cp data/content.db "$DEST/content.db.new" && mv "$DEST/content.db.new" "$DEST/content.db"
install -m 755 bin/jp-quiz "$HOME/.local/bin/jp-quiz"
install -m 644 jp-quiz.desktop "$HOME/.local/share/applications/jp-quiz.desktop"
install -m 644 assets/icon/jp-quiz.svg "$ICONS/jp-quiz.svg"
gtk-update-icon-cache -q -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
update-desktop-database -q "$HOME/.local/share/applications" 2>/dev/null || true
echo "installed to $DEST (progress kept)"
