#!/usr/bin/env bash
# Dotfiles: everything under home/ goes to $HOME (paths rendered for this user), with backups,
# a manifest and pacnew-style handling of files you edited (see g_put in lib.sh).
#
# Optional parts follow the options: files of a switched-off feature (AI, or an app you didn't pick) are
# not installed and are removed again if glass installed them earlier. niri's bind files of such a feature
# become a comment-only stub instead, because config.kdl includes every bind file. Files an app's own
# install.sh puts in place (launcher, desktop entry, units) are left to the apps step.

G_SETTINGS_REL=".config/serpantinum/settings.json"
G_SETTINGS_KEY="$G_SETTINGS_REL#glass-template"   # pseudo manifest entry: the glass settings last merged
# Settings that belong to the machine / the person / the session, never taken from the template.
G_SETTINGS_STRIP='del(.wallpaperDir, .general.language, .general.avatarPath, .general.location, .display,
                     .syspanel, .idle.manualInhibit, .notifications.dnd, .dock.editing)'

# Installed only when missing, never updated or removed: machine-specific files the repo has a neutral
# starting point for (your displays: niri picks each one's preferred mode until you set one).
G_SEED_FILES=" .config/niri/user/output.kdl "

# The optional feature a home/ file belongs to: ai, app:<name>, or nothing (always installed).
g_dotfile_feature() {
    case "$1" in
        .local/bin/ai|.local/bin/ai-chat|.local/bin/aidict|.local/bin/ai-notes|.local/bin/ai-notes-panel|\
        .local/bin/aipanel|.local/bin/jocr|.local/share/aifeat/*|.local/share/ai-notes/*|.local/share/npu-ocr/*|\
        .config/systemd/user/aidict.service|.config/systemd/user/ai-notes-*|.config/systemd/user/npu-llm*|\
        .config/systemd/user/npu-ocr.service|.config/niri/user/binds-ai.kdl|.config/niri/user/binds-notes.kdl)
            echo ai ;;
        .config/niri/user/binds-mail.kdl) echo app:glass-mail ;;
        .config/niri/user/binds-quiz.kdl) echo app:jp-quiz ;;
    esac
}

g_feature_on() {
    case "$1" in
        "") return 0 ;;
        ai) g_ai_on ;;
        app:*) g_app_selected "${1#app:}" ;;
    esac
}

# A niri bind file whose feature is off: installed as a stub (config.kdl includes it unconditionally).
g_dotfile_stub() { [[ "$1" == .config/niri/user/binds-*.kdl ]] && ! g_feature_on "$(g_dotfile_feature "$1")"; }

# Which home/ files to install (relative paths), honouring the options.
g_dotfile_list() {
    (cd "$G_ROOT/home" && find . -type f ! -name '*.pyc' ! -path '*/__pycache__/*' | sed 's|^\./||' | sort) | while IFS= read -r rel; do
        case "$rel" in
            "$G_SETTINGS_REL") continue ;;                                  # merged, not copied
            .zshrc|.zshenv|.zprofile|.config/starship.toml)
                [ "${G_SHELL_RC:-1}" = 1 ] || continue ;;
        esac
        [[ "$G_SEED_FILES" == *" $rel "* ]] && continue                     # g_dotfile_seeds
        g_app_owned "$rel" && continue                                     # the app's install.sh installs it
        g_dotfile_stub "$rel" || g_feature_on "$(g_dotfile_feature "$rel")" || continue
        printf '%s\n' "$rel"
    done
}

g_dotfile_seeds() {
    local rel tmp="$G_TMP/render"
    for rel in $G_SEED_FILES; do
        [ -e "$HOME/$rel" ] || [ -L "$HOME/$rel" ] && continue
        if g_is_dry; then g_dry "create    ~/$rel (starting point, yours from then on)"; continue; fi
        mkdir -p "$(dirname "$HOME/$rel")" "$(dirname "$tmp/$rel")"
        g_render "$G_ROOT/home/$rel" > "$tmp/$rel" && install -m 644 "$tmp/$rel" "$HOME/$rel" && G_COUNT[created]=$((G_COUNT[created] + 1))
    done
}

# Files glass installed earlier that this run no longer wants: a feature was switched off (removed, units
# stopped first; pre-glass originals come back from the backup) or an app's install.sh owns them now
# (they stay; only the manifest forgets them).
g_dotfiles_prune() {
    local -n wanted="$1"
    local rel u
    for rel in "${!G_MAN_SHA[@]}"; do
        case "$rel" in *"#"*|"$G_SP_DIR"/*|"$G_SF_DIR"/*) continue ;; esac
        [ -f "$G_ROOT/home/$rel" ] || continue          # only home/ files (not the Rust helpers, not patches)
        [ -n "${wanted[$rel]:-}" ] && continue
        if g_app_owned "$rel" || [[ "$G_SEED_FILES" == *" $rel "* ]]; then
            g_is_dry || g_manifest_del "$rel"
            continue
        fi
        if [[ "$rel" == .config/systemd/user/* ]] && ! g_is_dry && g_have systemctl && g_user_systemd; then
            u="${rel##*/}"
            systemctl --user disable --now "$u" >/dev/null 2>&1 && g_info "stopped $u ($(g_dotfile_feature "$rel") is off)"
        fi
        g_remove_owned "$rel" adopted-too || true
    done
}

g_dotfiles_install() {
    local rel mode feat tmp="$G_TMP/render" n=0
    declare -A want=()
    mkdir -p "$tmp"
    while IFS= read -r rel; do
        want[$rel]=1
        mkdir -p "$(dirname "$tmp/$rel")"
        if g_dotfile_stub "$rel"; then
            feat=$(g_dotfile_feature "$rel")
            if [ "$feat" = ai ]; then
                printf '// Keybinds of the AI features, which are off on this machine (glass installer).\n// Turn them on with: serp-glass --ai on\n'
            else
                printf '// Keybinds of %s, which is not installed on this machine (glass installer).\n// Pick it with: serp-glass --menu\n' "${G_APP_NAME[${feat#app:}]}"
            fi > "$tmp/$rel"
        else
            g_render "$G_ROOT/home/$rel" > "$tmp/$rel"
        fi
        mode=$(stat -c %a "$G_ROOT/home/$rel")
        [ "$mode" = 755 ] || [ "$mode" = 775 ] && mode=755 || mode=644
        g_put "$rel" "$tmp/$rel" "$mode"
        n=$((n + 1))
    done < <(g_dotfile_list)
    g_dotfile_seeds
    g_dotfiles_prune want
    g_info "$n dotfiles checked (created ${G_COUNT[created]}, updated ${G_COUNT[updated]}, unchanged ${G_COUNT[unchanged]}, kept ${G_COUNT[kept]}, removed ${G_COUNT[removed]})"
    g_settings_merge
    g_kitty_include
    g_user_dirs
}

# Merge the glass settings into ~/.config/serpantinum/settings.json (yours win only where glass has no opinion).
# A template we already merged is not merged again, so changes you make in Settings afterwards stay.
g_settings_merge() {
    local dst="$HOME/$G_SETTINGS_REL" tpl="$G_TMP/settings.glass.json" tsha merged="$G_TMP/settings.merged.json"
    g_render "$G_ROOT/home/$G_SETTINGS_REL" | jq "$G_SETTINGS_STRIP" > "$tpl" || { g_err "settings template is not valid JSON"; return 1; }
    tsha=$(g_sha "$tpl")
    if [ "${G_MAN_SHA[$G_SETTINGS_KEY]:-}" = "$tsha" ] && [ "${G_FORCE:-0}" != 1 ]; then
        g_detail "ok        ~/$G_SETTINGS_REL (glass settings already merged)"
        return 0
    fi
    if [ -s "$dst" ]; then
        jq -s '.[0] * .[1]' "$dst" "$tpl" > "$merged" || { g_err "~/$G_SETTINGS_REL is not valid JSON — not touched"; return 1; }
    else
        cp "$tpl" "$merged"
    fi
    if [ -s "$dst" ] && [ "$(jq -S . "$dst")" = "$(jq -S . "$merged")" ]; then
        g_ok "settings.json already has the glass settings"
        g_manifest_set "$G_SETTINGS_KEY" "$tsha"
        return 0
    fi
    if g_is_dry; then
        g_dry "merge glass settings into ~/$G_SETTINGS_REL"
        [ "${G_SHOW_DIFF:-0}" = 1 ] && [ -s "$dst" ] && diff -u --label current --label merged <(jq -S . "$dst") <(jq -S . "$merged") | head -40 | sed 's/^/           /'
        return 0
    fi
    if [ -s "$dst" ]; then
        local bak; bak=$(g_backup "$G_SETTINGS_REL") && g_info "backed up settings.json -> ${bak/#$HOME/\~}"
    fi
    mkdir -p "$(dirname "$dst")"
    jq . "$merged" > "$dst.tmp.$$" && mv -f "$dst.tmp.$$" "$dst"
    g_manifest_set "$G_SETTINGS_KEY" "$tsha"
    g_ok "merged the glass settings into ~/$G_SETTINGS_REL"
}

# Serpantinum's kitty.conf must include our user.conf (serp-tweaks sync re-adds it after a reinstall, too).
g_kitty_include() {
    local k="$HOME/.config/kitty/kitty.conf"
    [ -f "$k" ] || return 0
    grep -q '^include user.conf' "$k" && return 0
    if g_is_dry; then g_dry "add 'include user.conf' to ~/.config/kitty/kitty.conf"; return 0; fi
    printf '\n# Personal tweaks, kept across Serpantinum updates\ninclude user.conf\n' >> "$k"
    g_info "kitty.conf now includes user.conf"
}

# Directories the services expect. Only created when missing; nothing in them is ever touched.
g_user_dirs() {
    local d
    for d in "$HOME/Music" "$HOME/.local/share/mpd/playlists" "$HOME/.local/state/mpd"; do
        [ -d "$d" ] && continue
        if g_is_dry; then g_dry "mkdir ${d/#$HOME/\~}"; else mkdir -p "$d"; fi
    done
}

g_dotfiles_uninstall() {
    local rel
    for rel in "${!G_MAN_SHA[@]}"; do
        case "$rel" in *"#"*) continue ;; esac               # pseudo entries (settings template)
        case "$rel" in "$G_SP_DIR"/*|"$G_SF_DIR"/*) continue ;; esac   # shell patches: handled by g_shell_uninstall
        g_remove_owned "$rel" || true
        [ -e "$HOME/$rel.glass-new" ] && { g_is_dry || rm -f "$HOME/$rel.glass-new"; }
    done
    # kitty include: harmless without user.conf, but take it out if user.conf is gone
    local k="$HOME/.config/kitty/kitty.conf"
    if [ -f "$k" ] && [ ! -f "$HOME/.config/kitty/user.conf" ] && grep -q '^include user.conf' "$k"; then
        if g_is_dry; then g_dry "remove 'include user.conf' from kitty.conf"
        else sed -i '/^# Personal tweaks, kept across Serpantinum updates$/d; /^include user.conf$/d' "$k"; fi
    fi
    g_is_dry || g_manifest_del "$G_SETTINGS_KEY"
    # empty folders left behind in places only glass uses
    local d
    if ! g_is_dry; then
        for d in .config/niri/user .config/serp-tweaks .config/rmpc .local/share/aifeat .local/share/ai-notes \
                 .local/share/gcal-sync .local/share/npu-ocr .local/share/dbus-1/services; do
            [ -d "$HOME/$d" ] && find "$HOME/$d" -depth -type d -empty -delete 2>/dev/null
        done
    fi
    g_note "~/.config/serpantinum/settings.json keeps the glass settings (plain Serpantinum ignores the extra keys); backups are in ~/.config/serp-glass_backup/"
}
