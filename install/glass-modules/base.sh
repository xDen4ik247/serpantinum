#!/usr/bin/env bash
# Base layer: plain upstream Serpantinum, installed by upstream's own installer modules.
#
# Why "upstream first, then overlay" (and not deploying this fork's src/ directly):
#   `serpantinum update`, the upstream installer and `serp-tweaks` all assume that
#   ~/.local/state/serpantinum/version names an *upstream* commit and that
#   ~/.cache/serpantinum-installer is a clone of upstream. If we deployed the fork's src/ as the
#   base, the version file would name a fork commit, the next upstream update would find no common
#   history, do a full redeploy and silently drop every glass change. So the base is upstream at the
#   commit the glass branch is built on (UPSTREAM_BASE), installed exactly the upstream way, and the
#   glass changes go on top as serp-tweaks patches (shell.sh) — the same layout `serp-tweaks save`
#   produces, so `serp-tweaks update` / `sync` keep working.

G_UP_SLUG="ilyamiro/serpantinum"
G_UP_URL="https://github.com/$G_UP_SLUG.git"
G_UP_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/serpantinum-installer"   # the same clone upstream's installer uses
G_UP_VERSION_FILE="$HOME/.local/state/serpantinum/version"

g_installed_commit() { sed -n 's/^SERPANTINUM_COMMIT="\(.*\)"$/\1/p' "$G_UP_VERSION_FILE" 2>/dev/null; }

# Make sure the upstream clone exists and contains $1 (fetches if needed). Never moves it in dry-run.
g_upstream_cache() {
    local want="$1"
    if [ -d "$G_UP_CACHE/.git" ] && git -C "$G_UP_CACHE" cat-file -e "$want^{commit}" 2>/dev/null; then
        return 0
    fi
    if g_is_dry; then
        g_dry "would clone/fetch $G_UP_URL into ${G_UP_CACHE/#$HOME/\~}"
        return 1
    fi
    if [ ! -d "$G_UP_CACHE/.git" ]; then
        g_info "cloning upstream Serpantinum into ${G_UP_CACHE/#$HOME/\~}"
        rm -rf "$G_UP_CACHE"
        git clone -q "$G_UP_URL" "$G_UP_CACHE" || { g_err "git clone $G_UP_URL failed"; return 1; }
    else
        git -C "$G_UP_CACHE" remote set-url origin "$G_UP_URL" 2>/dev/null
        git -C "$G_UP_CACHE" fetch -q origin || g_warn "git fetch in $G_UP_CACHE failed"
    fi
    git -C "$G_UP_CACHE" cat-file -e "$want^{commit}" 2>/dev/null || { g_err "upstream commit $want not found"; return 1; }
}

# Decide what to do with the base. Sets G_BASE_ACTION (install|update|keep|reinstall) and G_BASE_TARGET.
g_base_plan() {
    local state cur
    # Upstream's detect_install_state() calls an install "current" as soon as ~/.local/state/serpantinum/version
    # exists, but sourcing upstream's own scripts (caching.sh, via i18n.sh) creates that file with only a version
    # line — so a fresh install looks like an update and upstream skips deploying the niri/kitty configs. A real
    # install always records SERPANTINUM_COMMIT, so that is what counts here.
    if grep -qs '^SERPANTINUM_COMMIT=' "$G_UP_VERSION_FILE"; then state=current
    elif [ -f "$HOME/.local/state/imperative-dots-version" ] || [ -f "$HOME/.config/hypr/settings.json" ]; then state=legacy
    else state=fresh; fi
    G_BASE_STATE="$state"
    cur=$(g_installed_commit)
    G_BASE_CURRENT="$cur"

    if [ "${G_UPSTREAM_MODE:-pinned}" = latest ]; then
        G_BASE_TARGET="origin/HEAD"
    else
        G_BASE_TARGET="$G_UPSTREAM_BASE"
    fi

    if [ "${G_SKIP_BASE:-0}" = 1 ]; then G_BASE_ACTION=skip; return; fi
    if [ "${G_REINSTALL_BASE:-0}" = 1 ]; then G_BASE_ACTION=reinstall; return; fi
    case "$state" in
        fresh|legacy) G_BASE_ACTION=install ;;
        current)
            if [ -z "$cur" ] || [ "$cur" = unknown ]; then
                G_BASE_ACTION=keep; g_warn "installed Serpantinum commit unknown — keeping it (use --reinstall-base to redo it)"
            elif [ "${G_UPSTREAM_MODE:-pinned}" = latest ]; then
                G_BASE_ACTION=update
            elif [ -d "$G_UP_CACHE/.git" ] && git -C "$G_UP_CACHE" cat-file -e "$cur^{commit}" 2>/dev/null \
                 && git -C "$G_UP_CACHE" cat-file -e "$G_UPSTREAM_BASE^{commit}" 2>/dev/null; then
                if [ "$(git -C "$G_UP_CACHE" rev-parse "$cur")" = "$(git -C "$G_UP_CACHE" rev-parse "$G_UPSTREAM_BASE")" ]; then
                    G_BASE_ACTION=keep
                elif git -C "$G_UP_CACHE" merge-base --is-ancestor "$G_UPSTREAM_BASE" "$cur"; then
                    G_BASE_ACTION=keep   # newer upstream than the glass base: never downgrade; patches still apply (or are reported)
                else
                    G_BASE_ACTION=update # older than the glass base: bring it up to the base
                fi
            elif [[ "$G_UPSTREAM_BASE" == "$cur"* ]]; then
                G_BASE_ACTION=keep
            else
                G_BASE_ACTION=update
            fi ;;
    esac
}

g_base_describe() {
    local short="${G_UPSTREAM_BASE:0:7}"
    case "$G_BASE_ACTION" in
        skip)      echo "skipped (--skip-base)" ;;
        keep)      echo "keep the installed upstream Serpantinum (${G_BASE_CURRENT:-?}; glass base is $short)" ;;
        install)   echo "install upstream Serpantinum at $short with upstream's installer modules (state: $G_BASE_STATE)" ;;
        update)    echo "update upstream Serpantinum ${G_BASE_CURRENT:-?} -> ${G_BASE_TARGET:0:7} (upstream update path)" ;;
        reinstall) echo "reinstall upstream Serpantinum at ${G_BASE_TARGET:0:7} (upstream reinstall: niri config backed up to ~/.config/niri_backup)" ;;
    esac
}

# Run upstream's installer modules (the same sequence as upstream install/install.sh, minus its
# interactive menu unless --upstream-menu) from the upstream clone checked out at the target commit.
g_base_run() {
    case "$G_BASE_ACTION" in skip|keep) return 0 ;; esac
    if g_is_dry; then g_dry "would run upstream's installer modules: $(g_base_describe)"; return 0; fi

    g_upstream_cache "$G_UPSTREAM_BASE" || return 1
    local target
    target=$(git -C "$G_UP_CACHE" rev-parse "$G_BASE_TARGET") || { g_err "can't resolve $G_BASE_TARGET"; return 1; }
    # Point the clone at the target exactly like upstream's own `git reset --hard origin/HEAD` does.
    git -C "$G_UP_CACHE" reset -q --hard "$target" || { g_err "can't check out $target in $G_UP_CACHE"; return 1; }
    g_info "upstream clone at $(git -C "$G_UP_CACHE" log --oneline -1)"

    (
        set -e
        set +u
        export REPO_SLUG="$G_UP_SLUG"
        PROJECT_ROOT="$G_UP_CACHE"
        INSTALL_DIR="$G_UP_CACHE/install"
        MODULES_DIR="$INSTALL_DIR/modules"
        export SERPANTINUM_DIR="$PROJECT_ROOT/src"
        export I18N_DIR="$PROJECT_ROOT/src/assets/languages"
        source "$PROJECT_ROOT/src/scripts/i18n.sh"
        for m in deps state migrate deploy version config service ui; do source "$MODULES_DIR/$m.sh"; done

        G_TEL_ID=$(get_telemetry_id)   # upstream keeps its anonymous install id in the version file
        ENABLE_TELEMETRY="${G_TELEMETRY:-false}"
        check_supported_os
        bootstrap_installer_deps

        INSTALL_STATE="$G_BASE_STATE"   # decided before upstream's scripts could create the version file (see g_base_plan)
        OLD_VERSION=$(get_installed_version)
        OLD_COMMIT=$(get_installed_commit)
        TARGET_VERSION=$(get_target_version "$PROJECT_ROOT" "$REPO_SLUG")
        TARGET_COMMIT=$(get_target_commit "$PROJECT_ROOT" "$REPO_SLUG")

        init_compositor_detection
        if [ "${G_UPSTREAM_MENU:-0}" = 1 ]; then
            OPT_SDDM="${G_SDDM:-true}"
            run_installer_ui
            [[ " ${SELECTED_COMPOSITORS[*]} " == *" niri "* ]] || { echo "the glass edition needs niri — select it in the compositor menu" >&2; exit 1; }
        else
            SELECTED_COMPOSITORS=(niri)
            OPT_SDDM="${G_SDDM:-true}"
            REPLACE_DM="${G_REPLACE_DM:-false}"
            SDDM_WAYLAND=false
            INSTALL_FULL_WALLPAPERS=$([ "${G_WALLPAPERS:-few}" = full ] && echo true || echo false)
            IS_REINSTALL=$([ "$G_BASE_ACTION" = reinstall ] && echo true || echo false)
        fi

        if [ "$ENABLE_TELEMETRY" = true ] && [ -f "$MODULES_DIR/telemetry.sh" ]; then
            bash "$MODULES_DIR/telemetry.sh" --mode init --version "$TARGET_VERSION" --id "$G_TEL_ID" --enabled "$ENABLE_TELEMETRY"
        fi

        if [[ "$INSTALL_STATE" == "legacy" ]]; then
            migrate_legacy "${SELECTED_COMPOSITORS[@]}"
        elif [[ "$INSTALL_STATE" == "fresh" || "$IS_REINSTALL" == true ]]; then
            backup_compositors "${SELECTED_COMPOSITORS[@]}"
        fi

        install_dependencies "$INSTALL_STATE" "$IS_REINSTALL" "${SELECTED_COMPOSITORS[@]}"
        deploy_package "$PROJECT_ROOT" "$OLD_COMMIT" "$TARGET_COMMIT" "$IS_REINSTALL" "$INSTALL_STATE" "${SELECTED_COMPOSITORS[@]}"
        setup_sddm "$PROJECT_ROOT" "$INSTALL_STATE" "$IS_REINSTALL"
        if [ "${G_WALLPAPERS:-few}" != none ]; then
            install_wallpapers "$INSTALL_FULL_WALLPAPERS"
        fi
        WALLPAPER_DIR=$(get_wallpaper_dir)
        mkdir -p "$WALLPAPER_DIR"
        init_serpantinum_config "$PROJECT_ROOT" "$WALLPAPER_DIR" "$INSTALL_STATE" "$IS_REINSTALL"
        setup_services
        write_version_state "$TARGET_VERSION" "$TARGET_COMMIT" "$G_TEL_ID" "$ENABLE_TELEMETRY" "${SELECTED_COMPOSITORS[*]}"
        if [[ "$INSTALL_STATE" == "legacy" || "$INSTALL_STATE" == "fresh" || "$IS_REINSTALL" == true ]]; then
            rm -f "$HOME/.local/state/serpantinum/first_launch.done" "$HOME/.local/state/quickshell/first_launch.done"
        fi
        if [ "$ENABLE_TELEMETRY" = true ] && [ -f "$MODULES_DIR/telemetry.sh" ]; then
            bash "$MODULES_DIR/telemetry.sh" --mode done --version "$TARGET_VERSION" --old-version "$OLD_VERSION" --install-state "$INSTALL_STATE" --compositor "${SELECTED_COMPOSITORS[*]}" --id "$G_TEL_ID" --enabled "$ENABLE_TELEMETRY" --failed "${FAILED_PKGS[*]}"
        fi
        if [ ${#FAILED_PKGS[@]} -gt 0 ]; then
            echo "upstream packages that failed to install: ${FAILED_PKGS[*]}" >&2
        fi
        cleanup_terminal 2>/dev/null || true
    )
    local rc=$?
    [ $rc = 0 ] || { g_err "upstream installer modules failed (exit $rc)"; return $rc; }
    g_ok "upstream Serpantinum $(g_installed_commit) installed"
}
