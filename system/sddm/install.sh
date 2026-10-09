#!/bin/sh
# Install + activate the serp-glass SDDM theme. Run ONCE as root:
#   pkexec sh system/sddm/install.sh
# Does NOT restart sddm — the new greeter appears at the next logout/boot.
# Revert: pkexec rm /etc/sddm.conf.d/20-serp-glass.conf   (material-you config is never modified; a .bak-serp copy is kept anyway)
set -eu
SRC="$(cd "$(dirname "$0")" && pwd)/themes/serp-glass"
DST=/usr/share/sddm/themes/serp-glass
SYNC=/var/lib/serp-greeter
U="${SUDO_USER:-${PKEXEC_UID:+$(id -nu "$PKEXEC_UID")}}"; [ -n "$U" ] || { echo "run via pkexec/sudo from your user"; exit 1; }

[ "$(id -u)" = 0 ] || { echo "run as root (pkexec)"; exit 1; }
[ -f "$SRC/Main.qml" ] || { echo "missing $SRC"; exit 1; }

# 1. theme files (root-owned, world-readable); material-you is left untouched
rm -rf "$DST.new"
cp -r "$SRC" "$DST.new"
rm -f "$DST.new/theme.conf.user"
ln -s "$SYNC/theme.conf.user" "$DST.new/theme.conf.user"
chown -R root:root "$DST.new"
find "$DST.new" -type d -exec chmod 755 {} +
find "$DST.new" -type f -exec chmod 644 {} +
rm -rf "$DST"
mv "$DST.new" "$DST"

# 2. sync dir: owned by the user so greeter-sync works without root afterwards
install -d -m 755 -o "$U" -g "$U" "$SYNC"
runuser -u "$U" -- env HOME=/home/$U /home/$U/.local/bin/greeter-sync --force || true

# 3. back up the old config, then switch the theme
CONF=/etc/sddm.conf.d/10-material-you.conf
[ -f "$CONF" ] && [ ! -f "$CONF.bak-serp" ] && cp -p "$CONF" "$CONF.bak-serp"
cat > /etc/sddm.conf.d/20-serp-glass.conf <<'CFG'
# serp-glass greeter (liquid glass). Delete this file to go back to material-you.
[Theme]
Current=serp-glass
ThemeDir=/usr/share/sddm/themes
CFG
chmod 644 /etc/sddm.conf.d/20-serp-glass.conf

echo "serp-glass installed. Active theme after next logout/boot. Preview:"
echo "  sddm-greeter-qt6 --test-mode --theme $DST"
