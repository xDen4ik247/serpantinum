#!/usr/bin/env bash
# Shell layer: the glass changes to Serpantinum's source, delivered as serp-tweaks patches.
#
# For every file in src/ and bin/ that differs between upstream (UPSTREAM_BASE) and this fork we write
# exactly what `serp-tweaks save` would write (~/.config/serp-tweaks/patches/<path with __>.patch, binary
# files whole in ~/.config/serp-tweaks/files/), then let `serp-tweaks sync` apply them to
# ~/.local/share/serpantinum. After an upstream update `serp-tweaks sync` re-applies them, as on the
# original machine.

G_SP_DIR=".config/serp-tweaks/patches"       # relative to $HOME
G_SF_DIR=".config/serp-tweaks/files"
G_SERP_TARGET="$HOME/.local/share/serpantinum"

# Extract pristine upstream src/ + bin/ at <commit> into <dir> (from this repo if it has the commit,
# else from the upstream clone).
g_extract_upstream() {
    local commit="$1" out="$2"
    mkdir -p "$out"
    if git -C "$G_ROOT" cat-file -e "$commit^{commit}" 2>/dev/null; then
        git -C "$G_ROOT" archive "$commit" src bin | tar -x -C "$out" && return 0
    fi
    if [ -d "$G_UP_CACHE/.git" ] && git -C "$G_UP_CACHE" cat-file -e "$commit^{commit}" 2>/dev/null; then
        git -C "$G_UP_CACHE" archive "$commit" src bin | tar -x -C "$out" && return 0
    fi
    return 1
}

g_upstream_file() {   # commit rel -> stdout (fails if the file isn't in upstream)
    git -C "$G_ROOT" show "$1:$2" 2>/dev/null || git -C "$G_UP_CACHE" show "$1:$2" 2>/dev/null
}

# Build the desired patch set in $G_TMP/patches and $G_TMP/files. Sets G_SHELL_RELS (changed paths).
g_shell_build() {
    local base="$G_TMP/upstream-base" rel name
    G_SHELL_RELS=()
    rm -rf "$base" "$G_TMP/patches" "$G_TMP/files"
    mkdir -p "$G_TMP/patches" "$G_TMP/files"
    g_extract_upstream "$G_UPSTREAM_BASE" "$base" || { g_err "can't read upstream $G_UPSTREAM_BASE (no git history here and no upstream clone)"; return 1; }
    # changed files
    while IFS= read -r rel; do
        G_SHELL_RELS+=("$rel")
        if grep -qI . "$G_ROOT/$rel" 2>/dev/null || [ ! -s "$G_ROOT/$rel" ]; then
            name="${rel//\//__}.patch"
            (cd "$base" && diff -u --label "a/$rel" --label "b/$rel" "$rel" "$G_ROOT/$rel") > "$G_TMP/patches/$name"
        else
            mkdir -p "$(dirname "$G_TMP/files/$rel")" && cp -p "$G_ROOT/$rel" "$G_TMP/files/$rel"
        fi
    done < <({ diff -rq -x __pycache__ -x '*.pyc' -x version.txt "$base/src" "$G_ROOT/src"; diff -rq "$base/bin" "$G_ROOT/bin"; } 2>/dev/null |
             sed -n "s|^Files $base/\(.*\) and .* differ\$|\1|p")
    # added files
    while IFS= read -r rel; do
        G_SHELL_RELS+=("$rel")
        if grep -qI . "$G_ROOT/$rel" 2>/dev/null || [ ! -s "$G_ROOT/$rel" ]; then
            name="${rel//\//__}.patch"
            diff -u --label /dev/null --label "b/$rel" /dev/null "$G_ROOT/$rel" > "$G_TMP/patches/$name"
        else
            mkdir -p "$(dirname "$G_TMP/files/$rel")" && cp -p "$G_ROOT/$rel" "$G_TMP/files/$rel"
        fi
    done < <({ diff -rq -x __pycache__ -x '*.pyc' -x version.txt "$base/src" "$G_ROOT/src"; diff -rq "$base/bin" "$G_ROOT/bin"; } 2>/dev/null |
             sed -n "s|^Only in $G_ROOT/\(.*\): \(.*\)\$|\1/\2|p" |
             while IFS= read -r added; do
                 if [ -d "$G_ROOT/$added" ]; then (cd "$G_ROOT" && find "$added" -type f ! -name '*.pyc' ! -path '*/__pycache__/*'); else echo "$added"; fi
             done)
    # files the fork deleted: not supported by serp-tweaks patches (none today) — say so loudly
    if { diff -rq -x __pycache__ -x '*.pyc' "$base/src" "$G_ROOT/src"; } 2>/dev/null | grep -q "^Only in $base/"; then
        g_warn "the fork deletes upstream files; serp-tweaks can't express that — they stay installed"
    fi
    return 0
}

g_shell_install() {
    local f rel name n_patch=0 n_file=0 reset=0 inst_commit
    g_shell_build || return 1
    for f in "$G_TMP"/patches/*.patch; do
        [ -e "$f" ] || continue
        g_put "$G_SP_DIR/$(basename "$f")" "$f" 644
        n_patch=$((n_patch + 1))
    done
    while IFS= read -r f; do
        rel="${f#"$G_TMP/files/"}"
        g_put "$G_SF_DIR/$rel" "$f" 644
        n_file=$((n_file + 1))
    done < <(find "$G_TMP/files" -type f 2>/dev/null)
    g_info "glass shell changes: $n_patch patches + $n_file binary files for ${#G_SHELL_RELS[@]} files in Serpantinum's source"

    # Stale glass patches (a file the fork no longer changes): drop the patch, restore upstream's file.
    inst_commit=$(g_installed_commit)
    for rel in "${!G_MAN_SHA[@]}"; do
        case "$rel" in "$G_SP_DIR"/*|"$G_SF_DIR"/*) ;; *) continue ;; esac
        if [[ "$rel" == "$G_SP_DIR"/* ]]; then
            [ -e "$G_TMP/patches/${rel#"$G_SP_DIR/"}" ] && continue
            name=$(sed -n '2{s|^+++ b/||p;q}' "$HOME/$rel" 2>/dev/null)   # the patched path, as serp-tweaks reads it
            [ -n "$name" ] || { g_manifest_del "$rel"; continue; }
        else
            [ -e "$G_TMP/files/${rel#"$G_SF_DIR/"}" ] && continue
            name="${rel#"$G_SF_DIR/"}"
        fi
        g_remove_owned "$rel" || continue
        g_restore_upstream_file "$name" "$inst_commit"
    done

    # Installed files that aren't the glass version yet: put upstream's version back first, so the
    # (possibly changed) patch applies cleanly. Files already equal to the glass version are left alone.
    [ -d "$G_SERP_TARGET" ] || { g_is_dry && g_dry "Serpantinum isn't installed yet; patches would be applied after the base install"; return 0; }
    for rel in "${G_SHELL_RELS[@]}"; do
        cmp -s "$G_ROOT/$rel" "$G_SERP_TARGET/$rel" && continue
        reset=$((reset + 1))
        if g_is_dry; then g_dry "would apply the glass change to ~/.local/share/serpantinum/$rel"; continue; fi
        g_restore_upstream_file "$rel" "$inst_commit" quiet
    done
    if [ "$reset" = 0 ]; then
        g_ok "Serpantinum source already has all ${#G_SHELL_RELS[@]} glass changes"
    fi
    g_shell_sync
}

# Put upstream's copy of <rel> back into the installed tree (or delete it if upstream has no such file).
g_restore_upstream_file() {
    local rel="$1" commit="${2:-$G_UPSTREAM_BASE}" quiet="${3:-}" dst="$G_SERP_TARGET/$1"
    [ -n "$commit" ] || commit="$G_UPSTREAM_BASE"
    if g_is_dry; then g_dry "would restore upstream's ~/.local/share/serpantinum/$rel"; return 0; fi
    local tmp="$G_TMP/upstream-file"
    if g_upstream_file "$commit" "$rel" > "$tmp" 2>/dev/null; then
        mkdir -p "$(dirname "$dst")" && cp -f "$tmp" "$dst"
        [[ "$rel" == *.sh || "$rel" == bin/* ]] && chmod +x "$dst"
        [ -n "$quiet" ] || g_info "restored upstream's $rel"
    else
        rm -f "$dst"
        # folders that only held glass files (e.g. new widget faces) go too; stops at the install root
        local d; d=$(dirname "$dst")
        while [ "$d" != "$G_SERP_TARGET" ] && [[ "$d" == "$G_SERP_TARGET"/* ]] && rmdir "$d" 2>/dev/null; do d=$(dirname "$d"); done
        [ -n "$quiet" ] || g_info "removed $rel (not part of upstream)"
    fi
    rm -f "$tmp"
}

g_shell_sync() {
    if g_is_dry; then g_dry "would run: serp-tweaks sync"; return 0; fi
    local st="$HOME/.local/bin/serp-tweaks"
    [ -x "$st" ] || { g_err "~/.local/bin/serp-tweaks missing (dotfiles step failed?)"; return 1; }
    g_info "serp-tweaks sync (re-applies the patches, refreshes ~/.config/niri/config/, validates niri)"
    local out rc
    out=$(PATH="$HOME/.local/bin:$PATH" "$st" sync 2>&1); rc=$?
    printf '%s\n' "$out" | sed 's/^/         /' | grep -v ': already applied$'
    if printf '%s' "$out" | grep -q 'FAILED'; then
        g_warn "some glass patches did not apply (see above) — upstream changed those files"
    fi
    [ $rc = 0 ] || g_warn "serp-tweaks sync exited with $rc"
    # verify
    local rel bad=0
    for rel in "${G_SHELL_RELS[@]}"; do
        cmp -s "$G_ROOT/$rel" "$G_SERP_TARGET/$rel" || { bad=$((bad + 1)); g_detail "differs after sync: $rel"; }
    done
    if [ "$bad" = 0 ]; then g_ok "all ${#G_SHELL_RELS[@]} glass changes are in ~/.local/share/serpantinum"
    else g_warn "$bad of ${#G_SHELL_RELS[@]} glass files differ from the fork after sync (expected only on a newer upstream)"; fi
}

# Remove a file we installed, if it's still exactly what we wrote. Restores the pre-glass original if we backed one up.
g_remove_owned() {
    local rel="$1" dst="$HOME/$1" bak="${G_MAN_BAK[$1]:--}"
    if [ ! -e "$dst" ]; then g_manifest_del "$rel"; return 0; fi
    if [ "$bak" = adopted ]; then   # it was there (identical) before glass ran: not ours to remove
        G_COUNT[left]=$((G_COUNT[left] + 1))
        g_detail "left      ~/$rel (was there before the installer)"
        g_is_dry || g_manifest_del "$rel"
        return 1
    fi
    if [ "$(g_sha "$dst")" != "${G_MAN_SHA[$rel]:-x}" ] && [ "${G_FORCE:-0}" != 1 ]; then
        g_warn "~/$rel was edited after install — left in place"
        G_COUNT[kept]=$((G_COUNT[kept] + 1))
        g_is_dry || g_manifest_del "$rel"
        return 1
    fi
    if g_is_dry; then
        if [ "$bak" != - ] && [ -e "$bak" ]; then g_dry "restore   ~/$rel from ${bak/#$HOME/\~}"; else g_dry "remove    ~/$rel"; fi
        return 0
    fi
    if [ "$bak" != - ] && [ -e "$bak" ]; then
        cp -a "$bak" "$dst" && G_COUNT[restored]=$((G_COUNT[restored] + 1))
        g_detail "restored  ~/$rel"
    else
        rm -f "$dst" && G_COUNT[removed]=$((G_COUNT[removed] + 1))
        g_detail "removed   ~/$rel"
    fi
    g_manifest_del "$rel"
    return 0
}

# --uninstall: drop the glass patches/files we installed and put upstream's files back.
g_shell_uninstall() {
    local rel name inst_commit n=0
    inst_commit=$(g_installed_commit)
    for rel in "${!G_MAN_SHA[@]}"; do
        case "$rel" in "$G_SP_DIR"/*|"$G_SF_DIR"/*) ;; *) continue ;; esac
        if [[ "$rel" == "$G_SP_DIR"/* ]]; then
            name=$(sed -n '2{s|^+++ b/||p;q}' "$HOME/$rel" 2>/dev/null)
        else
            name="${rel#"$G_SF_DIR/"}"
        fi
        g_remove_owned "$rel" || continue
        [ -n "$name" ] && [ -d "$G_SERP_TARGET" ] && g_restore_upstream_file "$name" "$inst_commit" quiet
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] && { if g_is_dry; then g_dry "restore $n Serpantinum source files to upstream"; else g_info "restored $n Serpantinum source files to upstream"; fi; }
    if ! g_is_dry && [ "$n" -gt 0 ]; then
        find "$HOME/$G_SF_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null
        mkdir -p "$HOME/.local/state/serp-tweaks" && echo "$inst_commit" > "$HOME/.local/state/serp-tweaks/synced"
        pgrep -x quickshell >/dev/null && serpantinum reload >/dev/null 2>&1 && g_info "Serpantinum restarted"
    fi
    return 0
}
