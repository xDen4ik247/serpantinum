#!/usr/bin/env bash
# Install / update the runnable copy:  ./install.sh
# App -> ~/.local/share/glass-mail/app, launcher -> ~/.local/bin/glass-mail, desktop entry + icon,
# the mailto: handler and the always-on new-mail watcher (glass-mail-watch.service, IMAP IDLE).
# Accounts live in ~/.config/glass-mail/accounts.json (mode 600), the cache in ~/.cache/glass-mail.
set -euo pipefail
cd "$(dirname "$0")"
DEST="$HOME/.local/share/glass-mail"
ICONS="$HOME/.local/share/icons/hicolor/scalable/apps"
mkdir -p "$DEST" "$HOME/.local/bin" "$HOME/.local/share/applications" "$ICONS"
rm -rf "$DEST/app.new"
mkdir -p "$DEST/app.new"
cp -r glassmail qml assets "$DEST/app.new/"
# the Rust backend (falls back to the Python one in glassmail/ when cargo isn't installed)
if command -v cargo >/dev/null && cargo build --release --quiet --manifest-path backend/Cargo.toml; then
    install -D -m 755 backend/target/release/glass-mail-backend "$DEST/app.new/bin/glass-mail-backend"
else
    echo "cargo missing or the build failed: Glass Mail runs on the Python backend"
fi
# the web view of HTML mails (WebKitGTK; without it HTML mails show in the text view)
if [ -x "$DEST/app.new/bin/glass-mail-backend" ] && pkg-config --exists webkit2gtk-4.1 2>/dev/null \
    && cargo build --release --quiet --manifest-path web/Cargo.toml; then
    install -D -m 755 web/target/release/glass-mail-web "$DEST/app.new/bin/glass-mail-web"
else
    echo "webkit2gtk-4.1 missing or the build failed: HTML mails use the text view"
fi
find "$DEST/app.new" -name __pycache__ -prune -exec rm -rf {} +
rm -f "$DEST/app.new/qml/shaders/"*.frag
# swap in one step (an open window live-reloads; a gap without app/ breaks that reload)
if [ -d "$DEST/app" ] && mv --exchange "$DEST/app.new" "$DEST/app" 2>/dev/null; then
    rm -rf "$DEST/app.new"
else
    rm -rf "$DEST/app" && mv "$DEST/app.new" "$DEST/app"
fi
install -m 755 bin/glass-mail "$HOME/.local/bin/glass-mail"
install -m 644 glass-mail.desktop "$HOME/.local/share/applications/glass-mail.desktop"
install -m 644 assets/icon/glass-mail.svg "$ICONS/glass-mail.svg"
gtk-update-icon-cache -q -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
update-desktop-database -q "$HOME/.local/share/applications" 2>/dev/null || true
xdg-mime default glass-mail.desktop x-scheme-handler/mailto 2>/dev/null || true
UNITS="$HOME/.config/systemd/user"
mkdir -p "$UNITS"
# the watcher replaced the old 5-minute check timer
systemctl --user disable --now glass-mail-check.timer >/dev/null 2>&1 || true
rm -f "$UNITS/glass-mail-check.service" "$UNITS/glass-mail-check.timer"
install -m 644 systemd/glass-mail-watch.service "$UNITS/"
systemctl --user daemon-reload 2>/dev/null && systemctl --user enable glass-mail-watch.service >/dev/null 2>&1 \
    && systemctl --user restart glass-mail-watch.service >/dev/null 2>&1 || true
echo "installed to $DEST/app"
