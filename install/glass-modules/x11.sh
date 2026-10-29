#!/usr/bin/env bash
# X11 apps (XWayland). niri starts xwayland-satellite by itself when an X11 app opens (the package comes with the
# root step). serp-x11 (rust/) makes those apps the right size on a scaled screen: the Steam scale in niri's
# environment (~/.config/niri/user/x11.kdl), a scale wrapper for apps that bundle their own old Qt5 and
# the DPI of Wine/Lutris prefixes. It runs at every login (user/autostart.kdl); this runs it once right away.

g_x11_sync() {
    local bin="$HOME/.local/bin/serp-x11"
    if g_is_dry; then
        g_dry "serp-x11 sync: Steam scale, old-Qt5 app wrappers and Wine DPI from the display scale"
        [ -x "$bin" ] && "$bin" sync --dry-run --quiet | sed 's/^/           /'
        return 0
    fi
    if [ ! -x "$bin" ]; then
        g_warn "serp-x11 isn't built (no cargo?): X11 apps work, but Steam/Wine/old Qt5 apps stay small on a scaled screen"
        return 0
    fi
    if "$bin" sync --quiet > "$G_TMP/x11.log" 2>&1; then
        if [ -s "$G_TMP/x11.log" ]; then sed 's/^serp-x11: /         /' "$G_TMP/x11.log"; fi
        g_ok "X11 apps set up for the display scale (serp-x11 status shows it)"
    else
        sed 's/^/         /' "$G_TMP/x11.log"
        g_warn "serp-x11 sync reported a problem (above); it runs again at the next login"
    fi
    return 0
}

g_x11_uninstall() {
    local bin="$HOME/.local/bin/serp-x11"
    [ -x "$bin" ] || return 0
    if g_is_dry; then
        "$bin" undo --dry-run | sed 's/^/           /'
        return 0
    fi
    "$bin" undo | sed 's/^serp-x11: /         /' || g_warn "serp-x11 undo reported a problem (above)"
    return 0
}
