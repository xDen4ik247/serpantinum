#!/usr/bin/env bash
# `speedtest`: a terminal network speed tester (ratatui TUI with live gauges and graphs, Cloudflare servers).
# It is the cloudflare-speed-cli crate (GPL-3.0, not packaged for pacman), built once with cargo into
# ~/.cache and installed as ~/.local/bin/speedtest through g_put (backups, manifest, --uninstall).
# `speedtest --text` / `--json` print the result without the TUI. A failed build only warns.

G_SPEEDTEST_CRATE=cloudflare-speed-cli
G_SPEEDTEST_VERSION=1.0.10

g_speedtest_install() {
    local want="$G_SPEEDTEST_CRATE-$G_SPEEDTEST_VERSION" root="${XDG_CACHE_HOME:-$HOME/.cache}/serp-glass-build/speedtest"
    if [ "$(g_state_get SPEEDTEST)" = "$want" ] && [ -x "$HOME/.local/bin/speedtest" ] && [ "${G_FORCE:-0}" != 1 ]; then
        g_ok "speedtest is up to date ($want)"
        return 0
    fi
    if g_is_dry; then
        g_have cargo && g_dry "build $want (cargo, about 3 minutes) and install it as ~/.local/bin/speedtest" \
                     || g_dry "no cargo: skip the speedtest tool"
        return 0
    fi
    if ! g_have cargo; then
        g_warn "cargo not found: skipping the speedtest tool (install rust and re-run)"
        return 0
    fi
    g_info "speedtest: building $want (about 3 minutes, once)"
    if cargo install "$G_SPEEDTEST_CRATE" --version "$G_SPEEDTEST_VERSION" --locked --root "$root" --force --quiet 2> "$G_TMP/speedtest.log" &&
       [ -x "$root/bin/$G_SPEEDTEST_CRATE" ]; then
        g_put ".local/bin/speedtest" "$root/bin/$G_SPEEDTEST_CRATE" 755 &&
            g_state_set SPEEDTEST "$want" && g_ok "speedtest installed (run: speedtest)"
        return 0
    fi
    g_warn "building $want failed (no network?), so no speedtest tool; re-run the installer to retry"
    tail -n 10 "$G_TMP/speedtest.log" | sed 's/^/         /'
    return 0
}
