#!/usr/bin/env bash
# Shared helpers for the glass installer: output, dry-run, backups, the install manifest and templating.
# Sourced by install/glass.sh (bash, `set -uo pipefail`, no `set -e`: every step checks its own result).

G_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/serp-glass"
G_MANIFEST="$G_STATE_DIR/manifest.tsv"      # <path relative to $HOME> TAB <sha256 we wrote> TAB <backup of the original | - | adopted>
G_STATE_FILE="$G_STATE_DIR/state"           # key="value" lines: glass commit, upstream base, chosen options
G_BACKUP_DIR="$HOME/.config/serp-glass_backup/backup_$(date +%Y%m%d_%H%M%S)"   # same scheme as upstream's *_backup dirs

# Counters for the summary (bash 4 associative array).
declare -A G_COUNT=([created]=0 [updated]=0 [unchanged]=0 [kept]=0 [removed]=0 [restored]=0 [left]=0)
G_WARNINGS=()
G_NOTES=()
G_CHANGED=()   # $HOME-relative paths created/updated in this run (services restarts what depends on them)

if [ -t 1 ]; then
    G_C_RESET=$'\e[0m' G_C_BOLD=$'\e[1m' G_C_DIM=$'\e[2m' G_C_CYAN=$'\e[36m' G_C_GREEN=$'\e[32m'
    G_C_YELLOW=$'\e[33m' G_C_RED=$'\e[31m' G_C_MAGENTA=$'\e[35m' G_C_BLUE=$'\e[34m'
else
    G_C_RESET='' G_C_BOLD='' G_C_DIM='' G_C_CYAN='' G_C_GREEN='' G_C_YELLOW='' G_C_RED='' G_C_MAGENTA='' G_C_BLUE=''
fi

g_section() { printf '\n%s%s==> %s%s\n' "$G_C_BOLD" "$G_C_CYAN" "$*" "$G_C_RESET"; }
g_info()    { printf '%s[ INFO ]%s %s\n' "$G_C_CYAN" "$G_C_RESET" "$*"; }
g_ok()      { printf '%s[  OK  ]%s %s\n' "$G_C_GREEN" "$G_C_RESET" "$*"; }
g_dry()     { printf '%s[ DRY  ]%s %s\n' "$G_C_MAGENTA" "$G_C_RESET" "$*"; }
g_warn()    { printf '%s[ WARN ]%s %s\n' "$G_C_YELLOW" "$G_C_RESET" "$*"; G_WARNINGS+=("$*"); }
g_err()     { printf '%s[ FAIL ]%s %s\n' "$G_C_RED" "$G_C_RESET" "$*" >&2; G_WARNINGS+=("ERROR: $*"); }
g_note()    { G_NOTES+=("$*"); }
g_detail()  { [ "${G_VERBOSE:-0}" = 1 ] && printf '         %s%s%s\n' "$G_C_DIM" "$*" "$G_C_RESET"; return 0; }

g_is_dry() { [ "${G_DRY_RUN:-0}" = 1 ]; }

# Run a command, or only print it in dry-run mode.
g_run() {
    if g_is_dry; then g_dry "would run: $*"; return 0; fi
    "$@"
}

g_sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

g_have() { command -v "$1" >/dev/null 2>&1; }

# Ask a yes/no question on the terminal (default yes). Non-interactive: use $2 (default: no).
g_confirm() {
    local q="$1" def="${2:-n}" ans=""
    if [ "${G_YES:-0}" = 1 ]; then return 0; fi
    if [ -t 0 ]; then
        read -r -p "$q [Y/n] " ans || ans=n
        [[ -z "$ans" || "$ans" =~ ^[YyДд] ]]
        return
    fi
    [ "$def" = y ]
}

# ---------------------------------------------------------------- manifest
g_manifest_load() {
    declare -gA G_MAN_SHA=() G_MAN_BAK=()
    [ -f "$G_MANIFEST" ] || return 0
    local p s b
    while IFS=$'\t' read -r p s b; do
        [ -n "$p" ] || continue
        G_MAN_SHA[$p]="$s"; G_MAN_BAK[$p]="${b:--}"
    done < "$G_MANIFEST"
}

g_manifest_set() {   # rel sha [backup]
    G_MAN_SHA[$1]="$2"
    [ -n "${3:-}" ] && [ "${3:-}" != - ] && G_MAN_BAK[$1]="$3"
    [ -n "${G_MAN_BAK[$1]:-}" ] || G_MAN_BAK[$1]=-
}

g_manifest_del() { unset 'G_MAN_SHA[$1]' 'G_MAN_BAK[$1]'; }

g_manifest_save() {
    g_is_dry && return 0
    mkdir -p "$G_STATE_DIR"
    local p tmp="$G_MANIFEST.tmp.$$"
    for p in "${!G_MAN_SHA[@]}"; do
        printf '%s\t%s\t%s\n' "$p" "${G_MAN_SHA[$p]}" "${G_MAN_BAK[$p]:--}"
    done | sort > "$tmp" && mv -f "$tmp" "$G_MANIFEST"
}

g_state_set() {   # key value
    g_is_dry && return 0
    mkdir -p "$G_STATE_DIR"
    touch "$G_STATE_FILE"
    local tmp="$G_STATE_FILE.tmp.$$"
    grep -v "^$1=" "$G_STATE_FILE" > "$tmp" 2>/dev/null || true
    printf '%s="%s"\n' "$1" "$2" >> "$tmp"
    mv -f "$tmp" "$G_STATE_FILE"
}

g_state_get() { sed -n "s/^$1=\"\(.*\)\"\$/\1/p" "$G_STATE_FILE" 2>/dev/null | tail -1; }

# ---------------------------------------------------------------- backups
# Copy $HOME/<rel> into this run's backup dir (keeps the relative path). Prints the backup path.
g_backup() {
    local rel="$1" dst="$G_BACKUP_DIR/$1"
    mkdir -p "$(dirname "$dst")"
    cp -a "$HOME/$rel" "$dst" && printf '%s' "$dst"
}

# ---------------------------------------------------------------- templating
# The repo stores paths as /home/user and the Obsidian vault as "Vault" (anonymised). Render them for this user.
g_sed_esc() { printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }

g_render() {   # src -> stdout
    local v h
    v=$(g_sed_esc "${G_VAULT:-Vault}")
    h=$(g_sed_esc "$HOME")
    if grep -qI . "$1" 2>/dev/null || [ ! -s "$1" ]; then
        sed -e "s|/home/user/|$h/|g" -e "s|/home/user\b|$h|g" \
            -e "s|Obsidian/Vault\b|Obsidian/$v|g" -e "s|vault=Vault&|vault=$v\&|g" "$1"
    else
        cat "$1"   # binary (compiled shaders): as is
    fi
}

# Install one file under $HOME from rendered content in $2.
#   g_put <rel> <rendered tmp file> <mode>
# Rules (idempotent, never loses data):
#   * same content already there            -> unchanged (and adopted into the manifest)
#   * missing                               -> created
#   * last written by us and not edited     -> updated
#   * edited by you since we wrote it       -> kept; the new version goes next to it as <file>.glass-new
#                                              (use --force to back up + replace instead)
#   * there before us (not in the manifest) -> backed up to ~/.config/serp-glass_backup/<date>/, then replaced
g_put() {
    local rel="$1" new="$2" mode="${3:-644}" dst="$HOME/$1" cur_sha new_sha bak=-
    new_sha=$(g_sha "$new")
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        cur_sha=$(g_sha "$dst")
        if [ "$cur_sha" = "$new_sha" ] && [ ! -L "$dst" ]; then
            G_COUNT[unchanged]=$((G_COUNT[unchanged] + 1))
            g_is_dry || { [ "$(stat -c %a "$dst")" = "$mode" ] || chmod "$mode" "$dst"; }
            # identical file that was there before glass: adopt it, but --uninstall leaves it alone
            if [ -z "${G_MAN_SHA[$rel]:-}" ]; then g_manifest_set "$rel" "$new_sha" adopted; else g_manifest_set "$rel" "$new_sha"; fi
            g_detail "ok        ~/$rel"
            return 0
        fi
        if [ -n "${G_MAN_SHA[$rel]:-}" ] && [ "${G_MAN_SHA[$rel]}" != "$cur_sha" ] && [ "${G_FORCE:-0}" != 1 ] &&
           ! g_is_upstream_copy "$rel" "$dst"; then
            G_COUNT[kept]=$((G_COUNT[kept] + 1))
            if g_is_dry; then
                g_dry "keep      ~/$rel (edited by you; new version would go to ~/$rel.glass-new)"
                g_show_diff "$dst" "$new"
            else
                cp "$new" "$dst.glass-new" && chmod "$mode" "$dst.glass-new"
                g_warn "kept your edited ~/$rel — the new glass version is ~/$rel.glass-new (merge by hand, or re-run with --force)"
            fi
            return 0
        fi
        G_COUNT[updated]=$((G_COUNT[updated] + 1))
        G_CHANGED+=("$rel")
        if g_is_dry; then
            if [ -n "${G_MAN_SHA[$rel]:-}" ]; then g_dry "update    ~/$rel"; else g_dry "replace   ~/$rel (backup first: not installed by glass)"; fi
            g_show_diff "$dst" "$new"
            return 0
        fi
        if [ -z "${G_MAN_SHA[$rel]:-}" ] || [ "${G_MAN_SHA[$rel]}" != "$cur_sha" ]; then
            bak=$(g_backup "$rel") || bak=-
            g_info "backed up ~/$rel -> ${bak/#$HOME/\~}"
        fi
        [ -L "$dst" ] && rm -f "$dst"
        install -D -m "$mode" "$new" "$dst" || { g_err "can't write ~/$rel"; return 1; }
        g_manifest_set "$rel" "$new_sha" "$bak"
        g_detail "updated   ~/$rel"
        return 0
    fi
    G_COUNT[created]=$((G_COUNT[created] + 1))
    G_CHANGED+=("$rel")
    if g_is_dry; then g_dry "create    ~/$rel"; return 0; fi
    install -D -m "$mode" "$new" "$dst" || { g_err "can't write ~/$rel"; return 1; }
    g_manifest_set "$rel" "$new_sha"
    g_detail "created   ~/$rel"
}

# True when ~/<rel> is exactly the file upstream's installer deploys there (an upstream reinstall put it
# back): that is not an edit of yours, so glass may replace it again.
g_is_upstream_copy() {   # rel path
    local up
    case "$1" in
        .config/niri/*) up="compositors/niri/${1#.config/niri/}" ;;
        .config/kitty/*|.config/cava/*|.config/fastfetch/*) up="config/${1#.config/}" ;;
        *) return 1 ;;
    esac
    local commit; commit=$(sed -n 's/^SERPANTINUM_COMMIT="\(.*\)"$/\1/p' "$HOME/.local/state/serpantinum/version" 2>/dev/null)
    [ -n "$commit" ] && [ -d "${G_UP_CACHE:-}/.git" ] || return 1
    cmp -s <(git -C "$G_UP_CACHE" show "$commit:$up" 2>/dev/null) "$2"
}

g_show_diff() {   # cur new
    [ "${G_SHOW_DIFF:-0}" = 1 ] || return 0
    if grep -qI . "$1" 2>/dev/null; then
        diff -u --label current --label glass "$1" "$2" | head -n 60 | sed 's/^/           /'
    else
        echo "           (binary file differs)"
    fi
}
