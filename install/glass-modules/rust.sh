#!/usr/bin/env bash
# Rust helpers (rust/): event-driven replacements for the bash/Python pollers of the shell and the
# niri daemons. Built with cargo into ~/.cache and installed into ~/.local/bin through g_put (backups,
# manifest, service restarts). Without cargo, or if the build fails, the four daemons that must exist
# (niri-autofit, niri-dwt-toggle, sleep-guard, power-mode) come from rust/reference/ (the Python/bash
# versions), and the shell falls back to its own scripts for the serp-* helpers.

G_RUST_BINS=(serp-niri-state serp-focus serp-wellbeing serp-sysdata serp-kblocks niri-autofit niri-dwt-toggle sleep-guard power-mode)
G_RUST_REFERENCE=(niri-autofit niri-dwt-toggle sleep-guard power-mode)

g_rust_install() {
    local target="${XDG_CACHE_HOME:-$HOME/.cache}/serp-glass/rust-target" b
    if g_is_dry; then
        g_have cargo && g_dry "build rust/ (cargo --release) and install ${#G_RUST_BINS[@]} helpers into ~/.local/bin" \
                     || g_dry "no cargo: install the reference scripts of ${G_RUST_REFERENCE[*]}"
        return 0
    fi
    if g_have cargo && cargo build --release --quiet --manifest-path "$G_ROOT/rust/Cargo.toml" --target-dir "$target" 2> "$G_TMP/cargo.log"; then
        for b in "${G_RUST_BINS[@]}"; do
            g_put ".local/bin/$b" "$target/release/$b" 755
        done
        g_ok "Rust helpers built and installed (${#G_RUST_BINS[@]})"
        return 0
    fi
    if g_have cargo; then
        g_warn "building rust/ failed (see below); using the Python/bash versions of ${G_RUST_REFERENCE[*]}"
        tail -n 15 "$G_TMP/cargo.log" | sed 's/^/         /'
    else
        g_warn "cargo not found: using the Python/bash versions of ${G_RUST_REFERENCE[*]} (install rust and re-run for the Rust helpers)"
    fi
    for b in "${G_RUST_REFERENCE[@]}"; do
        g_put ".local/bin/$b" "$G_ROOT/rust/reference/$b" 755
    done
}
