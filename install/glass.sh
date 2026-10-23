#!/usr/bin/env bash
# Serpantinum — liquid glass edition: installer.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/xDen4ik247/serpantinum/glass/install/glass.sh)"
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/xDen4ik247/serpantinum/glass/install/glass.sh)" _ --dry-run
#   install/glass.sh [options]                     # from a clone of the glass branch
#
# Steps (each one idempotent: a re-run only fixes what differs, and never overwrites your edits):
#   base      upstream Serpantinum, installed/updated by upstream's own installer modules
#   root      ONE sudo/pkexec prompt: glass packages (pacman, official repos), glass login screen, battery tweaks
#   dotfiles  home/ -> $HOME, backups in ~/.config/serp-glass_backup/<date>/
#   shell     the glass changes to Serpantinum as serp-tweaks patches (so updates keep them)
#   apps      the apps you pick: Glass Music, Glass Mail, JP Quiz (--apps, or the menu)
#   extras    the AI features' heavy parts, opt-in: --with llm,notes,dictation,ocr (only while --ai on)
#   services  systemd user units for what is installed
# A first install on a terminal shows a menu (apps, AI features, login screen, battery, zsh); every choice is
# remembered, and `serp-glass` (installed in ~/.local/bin) re-runs this installer later: to update, or to
# change a choice (serp-glass --menu, --ai off|on, --apps ...). Run with --help for the options.

set -uo pipefail

G_REPO_URL="${GLASS_REPO_URL:-https://github.com/xDen4ik247/serpantinum.git}"
G_REF="${GLASS_REF:-glass}"
G_CLONE="${XDG_CACHE_HOME:-$HOME/.cache}/serp-glass"
# The upstream commit the glass branch is built on. Update it whenever the branch is rebased onto upstream.
G_UPSTREAM_BASE=ed1f0658a8b79523e18c9c450af1788da806cd82

# ------------------------------------------------------------------ bootstrap (curl | bash)
G_SELF=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    G_SELF="$(realpath "${BASH_SOURCE[0]}")"
fi
if [ -z "$G_SELF" ] || [ ! -f "$(dirname "$G_SELF")/glass-modules/lib.sh" ]; then
    [ "${GLASS_BOOTSTRAPPED:-0}" = 1 ] && { echo "serp-glass: the clone in $G_CLONE is incomplete" >&2; exit 1; }
    if ! command -v git >/dev/null; then
        echo ":: git is needed to fetch the glass edition"
        sudo pacman -S --needed --noconfirm git || sudo pacman -Syu --needed --noconfirm git || exit 1
    fi
    if [ -d "$G_CLONE/.git" ]; then
        git -C "$G_CLONE" remote set-url origin "$G_REPO_URL"
        git -C "$G_CLONE" fetch -q --depth 1 origin "$G_REF" && git -C "$G_CLONE" reset -q --hard FETCH_HEAD ||
            { echo "serp-glass: can't update $G_CLONE from $G_REPO_URL ($G_REF)" >&2; exit 1; }
    else
        rm -rf "$G_CLONE"
        git clone -q --depth 1 --branch "$G_REF" "$G_REPO_URL" "$G_CLONE" ||
            { echo "serp-glass: can't clone $G_REPO_URL ($G_REF)" >&2; exit 1; }
    fi
    export GLASS_BOOTSTRAPPED=1
    if [ ! -t 0 ] && [ -r /dev/tty ] && { : < /dev/tty; } 2>/dev/null; then
        exec bash "$G_CLONE/install/glass.sh" "$@" < /dev/tty
    fi
    exec bash "$G_CLONE/install/glass.sh" "$@"
fi

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" = 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    echo "serp-glass: needs bash 4.4 or newer" >&2; exit 1
fi

G_INSTALL_DIR="$(dirname "$G_SELF")"
G_ROOT="$(dirname "$G_INSTALL_DIR")"
G_MODULES="$G_INSTALL_DIR/glass-modules"

usage() {
    cat <<'EOF'
Serpantinum — liquid glass edition installer

Usage: glass.sh [options]
  -n, --dry-run          show what would change; change nothing
  -y, --yes              don't ask (saved choices, else the defaults)
      --menu             pick apps / AI features / options in a menu (shown by itself on a first install
                         on a terminal); --no-menu never shows it
  Choices (all remembered for later runs; serp-glass re-runs the installer with them):
      --apps LIST        apps, comma-separated: glass-music, glass-mail, jp-quiz, all or none
                         (default: Glass Music + Glass Mail). An app you drop is removed; its data stays.
      --ai on|off        the AI features (local, on the Intel NPU/GPU): assistant, dictation, OCR, notes.
                         off = nothing AI is installed (no scripts, services, keybinds, NPU packages) and
                         what glass installed for them is removed; --ai on later brings it all back.
                         Default: on with an Intel NPU, else off. --no-ai / --no-npu = --ai off
      --with LIST        the AI features' heavy parts, comma-separated (installed while --ai on):
                           dictation  Whisper dictation (~1.2 GB)
                           ocr        Japanese OCR + JMdict popup (~1 GB kept; ~2.5 GB temporary)
                           llm        local LLM on the Intel GPU (~3.2 GB download + a 10–20 min build)
                           notes      Obsidian AI notes (640 MB; needs llm)
                           all        everything above
      --no-sddm          don't install the glass login screen
      --power auto|yes|no  battery tweaks (udev runtime PM, NMI watchdog off); auto = laptops only
      --no-shell-rc      leave ~/.zshrc, ~/.zshenv, ~/.zprofile and starship.toml alone
      --vault NAME       Obsidian vault folder in ~/Obsidian (default: the only vault there, else "Vault")
      --force            also replace files you edited (they are backed up first)
      --diff             with --dry-run: show the differences
  -v, --verbose          list every file
      --no-root          skip the root step (prints what it would have done)
      --only STEPS       run only these steps, comma-separated: base,root,dotfiles,shell,apps,extras,services
  Base (upstream Serpantinum):
      --skip-base        don't install/update upstream Serpantinum
      --reinstall-base   upstream "Reinstall" (backs up ~/.config/niri first; glass restores its layer)
      --upstream latest  install upstream's newest commit instead of the one glass is built on
      --upstream-menu    show upstream's own installer menu for the base
      --wallpapers few|full|none   upstream wallpaper pack (default: few)
      --telemetry        let upstream's installer send its anonymous install statistics (off by default)
  Other modes:
      --status           show what is installed
      --uninstall        remove the glass layer (upstream Serpantinum stays); add --purge to also
                         delete the models/builds the extras downloaded
  -h, --help
EOF
}

# ------------------------------------------------------------------ options
G_MODE=install G_DRY_RUN=0 G_YES=0 G_FORCE=0 G_SHOW_DIFF=0 G_VERBOSE=0 G_NO_ROOT=0 G_PURGE=0
G_SKIP_BASE=0 G_REINSTALL_BASE=0 G_UPSTREAM_MODE=pinned G_UPSTREAM_MENU=0 G_WALLPAPERS=few G_TELEMETRY=false
G_OPT_SDDM="" G_OPT_POWER="" G_OPT_SHELL_RC="" G_VAULT="" G_WITH_ARG="" G_APPS_ARG="" G_OPT_AI="" G_MENU=auto G_ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) G_DRY_RUN=1 ;;
        -y|--yes) G_YES=1 ;;
        --with) G_WITH_ARG+="${2:-},"; shift ;;
        --with=*) G_WITH_ARG+="${1#*=}," ;;
        --apps) G_APPS_ARG="${2:-}"; [ -n "$G_APPS_ARG" ] || G_APPS_ARG=none; shift ;;
        --apps=*) G_APPS_ARG="${1#*=}"; [ -n "$G_APPS_ARG" ] || G_APPS_ARG=none ;;
        --ai) G_OPT_AI="${2:-}"; shift ;;
        --ai=*) G_OPT_AI="${1#*=}" ;;
        --no-ai|--no-npu) G_OPT_AI=off ;;
        --npu) G_OPT_AI=on ;;
        --menu) G_MENU=yes ;;
        --no-menu) G_MENU=no ;;
        --only) G_ONLY="${2:-}"; shift ;;
        --only=*) G_ONLY="${1#*=}" ;;
        --no-sddm) G_OPT_SDDM=false ;;
        --sddm) G_OPT_SDDM=true ;;
        --power) G_OPT_POWER="${2:-}"; shift ;;
        --power=*) G_OPT_POWER="${1#*=}" ;;
        --no-power) G_OPT_POWER=no ;;
        --no-shell-rc) G_OPT_SHELL_RC=0 ;;
        --shell-rc) G_OPT_SHELL_RC=1 ;;
        --vault) G_VAULT="${2:-}"; shift ;;
        --vault=*) G_VAULT="${1#*=}" ;;
        --force) G_FORCE=1 ;;
        --diff) G_SHOW_DIFF=1 ;;
        -v|--verbose) G_VERBOSE=1 ;;
        --no-root) G_NO_ROOT=1 ;;
        --skip-base) G_SKIP_BASE=1 ;;
        --reinstall-base) G_REINSTALL_BASE=1 ;;
        --upstream) G_UPSTREAM_MODE="${2:-}"; shift ;;
        --upstream=*) G_UPSTREAM_MODE="${1#*=}" ;;
        --upstream-menu) G_UPSTREAM_MENU=1 ;;
        --wallpapers) G_WALLPAPERS="${2:-}"; shift ;;
        --wallpapers=*) G_WALLPAPERS="${1#*=}" ;;
        --telemetry) G_TELEMETRY=true ;;
        --status) G_MODE=status ;;
        --uninstall) G_MODE=uninstall ;;
        --purge) G_PURGE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "serp-glass: unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done
case "$G_UPSTREAM_MODE" in pinned|latest) ;; *) echo "--upstream: pinned or latest" >&2; exit 2 ;; esac
case "$G_WALLPAPERS" in few|full|none) ;; *) echo "--wallpapers: few, full or none" >&2; exit 2 ;; esac
case "${G_OPT_POWER:-auto}" in auto|yes|no) ;; *) echo "--power: auto, yes or no" >&2; exit 2 ;; esac
case "${G_OPT_AI:-on}" in on|off) ;; *) echo "--ai: on or off" >&2; exit 2 ;; esac
for _s in ${G_ONLY//,/ }; do
    case "$_s" in base|root|dotfiles|shell|apps|extras|services) ;; *) echo "--only: base, root, dotfiles, shell, apps, extras, services" >&2; exit 2 ;; esac
done

# ------------------------------------------------------------------ modules
for m in lib base system dotfiles rust speedtest shell services apps extras menu; do
    # shellcheck disable=SC1090
    source "$G_MODULES/$m.sh" || { echo "serp-glass: can't load $G_MODULES/$m.sh" >&2; exit 1; }
done

# Saved choices from earlier runs; the command line wins.
declare -A G_WITH=()
for e in $(g_state_get WITH); do G_WITH[$e]=1; done
# never chosen here before: the extras this machine already has count as chosen (keeps them updated)
grep -qs '^WITH=' "$G_STATE_FILE" || for e in "${G_EXTRAS[@]}"; do g_extra_ready "$e" && G_WITH[$e]=1; done
IFS=',' read -r -a _w <<< "$G_WITH_ARG"
_jpquiz_via_with=0
for e in "${_w[@]}"; do
    e="${e// /}"; [ -n "$e" ] || continue
    case "$e" in
        jpquiz) _jpquiz_via_with=1; continue ;;     # an app now; kept for old command lines
        all) _jpquiz_via_with=1 ;;
    esac
    if [ "$e" != all ] && [ -z "${G_EXTRA_INFO[$e]:-}" ]; then echo "serp-glass: unknown extra '$e' (dictation ocr llm notes jmdict all)" >&2; exit 2; fi
    G_WITH[$e]=1
done
[ "${G_WITH[ocr]:-0}" = 1 ] && G_WITH[jmdict]=1

# Apps: the command line, else the saved choice, else what is installed (an older installer always put
# Glass Music in, JP Quiz with --with jpquiz), else the defaults.
G_APPS=()
if [ -n "$G_APPS_ARG" ]; then
    case "$G_APPS_ARG" in
        all) G_APPS=(glass-music glass-mail jp-quiz) ;;
        none) ;;
        *) IFS=',' read -r -a G_APPS <<< "${G_APPS_ARG// /}" ;;
    esac
elif [ -n "$(g_state_get APPS)" ] || grep -qs '^APPS=' "$G_STATE_FILE"; then
    read -r -a G_APPS <<< "$(g_state_get APPS)"
else
    for a in "${G_APPS_ALL[@]}"; do g_app_installed "$a" && G_APPS+=("$a"); done
    [[ " $(g_state_get WITH) " == *" jpquiz "* ]] && ! g_app_selected jp-quiz && G_APPS+=(jp-quiz)
    if [ ${#G_APPS[@]} -eq 0 ]; then
        if [ -n "$(g_state_get GLASS_COMMIT)" ]; then G_APPS=(glass-music); else G_APPS=(glass-music glass-mail); fi
    fi
fi
[ "$_jpquiz_via_with" = 1 ] && ! g_app_selected jp-quiz && G_APPS+=(jp-quiz)
for a in "${G_APPS[@]}"; do
    [ -n "${G_APP_NAME[$a]:-}" ] || { echo "serp-glass: unknown app '$a' (glass-music glass-mail jp-quiz all none)" >&2; exit 2; }
done

# AI features: the command line, else the saved choice, else on if this machine already has some of them
# or has an Intel NPU.
G_AI="${G_OPT_AI:-$(g_state_get AI)}"
if [ -z "$G_AI" ]; then
    G_AI=off
    if g_has_npu || [ -n "$(g_extras_chosen)" ]; then G_AI=on; fi
    for e in llm dictation ocr; do g_extra_ready "$e" && G_AI=on; done
fi
G_SDDM="${G_OPT_SDDM:-$(g_state_get SDDM)}"; G_SDDM="${G_SDDM:-true}"
G_POWER="${G_OPT_POWER:-$(g_state_get POWER)}"; G_POWER="${G_POWER:-auto}"
G_SHELL_RC="${G_OPT_SHELL_RC:-$(g_state_get SHELL_RC)}"; G_SHELL_RC="${G_SHELL_RC:-1}"
if [ -z "$G_VAULT" ]; then
    G_VAULT=$(g_state_get VAULT)
    if [ -z "$G_VAULT" ]; then
        _v=(); for d in "$HOME"/Obsidian/*/; do [ -d "$d.obsidian" ] && _v+=("$(basename "$d")"); done
        if [ ${#_v[@]} -eq 1 ]; then G_VAULT="${_v[0]}"; else G_VAULT=Vault; fi
    fi
fi
g_extras_resolve

G_GLASS_COMMIT=$(git -C "$G_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)

# ------------------------------------------------------------------ helpers
g_banner() {
    local os cpu gpu
    os=$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release 2>/dev/null)
    cpu=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
    gpu=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -1 | cut -d: -f3 | sed 's/ (rev .*)//' | xargs)
    printf '\n%s%s' "$G_C_BOLD" "$G_C_CYAN"
    cat <<'EOF'
   ┌─────────────────────────────────────────────────────────────┐
   │   S E R P A N T I N U M  ·  liquid glass edition            │
   └─────────────────────────────────────────────────────────────┘
EOF
    printf '%s' "$G_C_RESET"
    printf '   %suser%s %-22s %sos%s  %s\n' "$G_C_BOLD" "$G_C_RESET" "${USER:-$(id -un)}" "$G_C_BOLD" "$G_C_RESET" "${os:-?}"
    printf '   %scpu%s  %s\n   %sgpu%s  %s\n' "$G_C_BOLD" "$G_C_RESET" "${cpu:-?}" "$G_C_BOLD" "$G_C_RESET" "${gpu:-?}"
    printf '   %sglass%s %s  ·  upstream base %s  ·  %s\n' "$G_C_BOLD" "$G_C_RESET" "$G_GLASS_COMMIT" "${G_UPSTREAM_BASE:0:7}" \
        "$( [ "$G_DRY_RUN" = 1 ] && echo "${G_C_MAGENTA}dry run — nothing will change${G_C_RESET}" || echo "$G_MODE")"
}

g_step() { G_STEP_N=$((${G_STEP_N:-0} + 1)); g_section "$G_STEP_N/$G_STEPS  $*"; }

g_preflight() {
    local ok=1 free
    if [ "$(id -u)" = 0 ]; then g_err "run this as your normal user, not root (it asks for root once when needed)"; exit 1; fi
    if ! g_have pacman; then g_err "this installer is for Arch Linux and Arch-based distributions (pacman)"; exit 1; fi
    g_have systemctl || g_warn "no systemd: services are not set up"
    g_have git || g_is_dry || [ -t 0 ] || { g_err "git is missing (sudo pacman -S git)"; ok=0; }
    free=$(df -Pk "$HOME" | awk 'NR==2{print int($4/1048576)}')
    if [ "${free:-0}" -lt 4 ]; then g_warn "only ${free} GB free in $HOME — the base install alone needs ~4 GB"; fi
    if [ -n "$(g_extras_selected)" ] && [ "${free:-0}" -lt 12 ]; then g_warn "only ${free} GB free in $HOME — the extras you chose need several GB"; fi
    if [ "$G_SKIP_BASE" = 1 ] && [ ! -d "$HOME/.local/share/serpantinum" ]; then
        g_warn "--skip-base, but upstream Serpantinum isn't installed: the shell step will have nothing to patch"
    fi
    if [ -e /var/lib/pacman/db.lck ] && ! g_is_dry; then
        g_err "pacman is busy (/var/lib/pacman/db.lck): wait for the other install/update to finish, or remove the lock if none is running"
        ok=0
    fi
    if ! g_is_dry && [ "$G_MODE" = install ] && ! curl -fsI --max-time 10 https://github.com >/dev/null 2>&1; then
        g_err "no internet connection (github.com unreachable): the installer downloads Serpantinum, packages and the apps' crates"
        ok=0
    fi
    [ $ok = 1 ] || exit 1
}

# Is step <name> part of this run (--only)?
g_step_on() { [ -z "$G_ONLY" ] || [[ ",$G_ONLY," == *",$1,"* ]]; }

g_print_plan() {
    local acts
    printf '\n   %sPlan%s\n' "$G_C_BOLD" "$G_C_RESET"
    printf '   %-9s %s\n' base "$(g_base_describe)"
    g_root_plan
    if [ ${#G_ROOT_ACTIONS[@]} -eq 0 ]; then acts="nothing to do (no password needed)"
    elif [ "$G_NO_ROOT" = 1 ]; then acts="skipped (--no-root): ${#G_ROOT_ACTIONS[@]} actions printed only"
    else
        local a short=()
        for a in "${G_ROOT_ACTIONS[@]}"; do
            if [[ "$a" == "install "*" packages: "* ]] && [ "$G_VERBOSE" != 1 ]; then short+=("${a%%:*}"); else short+=("$a"); fi
        done
        acts="one password prompt: $(printf '%s; ' "${short[@]}" | sed 's/; $//')"
    fi
    printf '   %-9s %s\n' root "$acts"
    printf '   %-9s %s\n' dotfiles "niri user layer, kitty, fcitx5, MPD, $( [ "$G_SHELL_RC" = 1 ] && echo "zsh + starship, " )scripts in ~/.local/bin, systemd units (vault: ~/Obsidian/$G_VAULT)"
    printf '   %-9s %s\n' shell "glass changes to Serpantinum as serp-tweaks patches"
    local apps="" a2 dropped=""
    for a2 in "${G_APPS[@]}"; do apps+="${apps:+, }${G_APP_NAME[$a2]}"; done
    for a2 in "${G_APPS_ALL[@]}"; do g_app_selected "$a2" || [ -z "$(g_state_get "APP_$a2")" ] || dropped+="${dropped:+, }${G_APP_NAME[$a2]}"; done
    printf '   %-9s %s%s\n' apps "${apps:-none}" "$( [ -n "$dropped" ] && echo " · remove: $dropped (data stays)")"
    if g_ai_on; then
        local present="" e2
        for e2 in "${G_EXTRAS[@]}"; do [ "${G_WITH[$e2]:-0}" != 1 ] && g_extra_ready "$e2" && present+=" $e2"; done
        printf '   %-9s %s%s\n' AI "on · extras: $( [ -n "$(g_extras_selected)" ] && g_extras_selected | xargs || echo "none selected (see --with)")" \
            "$( [ -n "$present" ] && echo " · already here:$present")"
    else
        printf '   %-9s %s\n' AI "off: no AI scripts, services, keybinds or NPU packages (--ai on brings them back)"
    fi
    [ -n "$G_ONLY" ] && printf '   %-9s %s\n' only "this run does only: ${G_ONLY//,/, }"
    printf '   %-9s %s\n' services "systemd user units for what is installed"
    local e
    for e in $(g_extras_selected); do
        g_extra_ready "$e" && continue
        printf '   %s! %s: %s%s\n' "$G_C_YELLOW" "$e" "${G_EXTRA_INFO[$e]}" "$G_C_RESET"
    done
}

g_ask() {   # question -> 0 yes
    [ "$G_YES" = 1 ] && return 0
    if [ ! -t 0 ]; then g_err "no terminal to ask on — re-run with --yes (or --dry-run first)"; exit 1; fi
    local a; read -r -p "$(printf '\n   %s%s%s [Y/n] ' "$G_C_BOLD" "$1" "$G_C_RESET")" a || return 1
    [[ -z "$a" || "$a" =~ ^[YyДд] ]]
}

g_save_choices() {
    g_is_dry && return 0
    g_state_set WITH "$(g_extras_chosen | xargs)"
    g_state_set APPS "${G_APPS[*]}"
    g_state_set AI "$G_AI"
    g_state_set SOURCE "$G_ROOT"
    g_state_set REPO_URL "$G_REPO_URL"
    g_state_set REF "$G_REF"
    g_state_set SDDM "$G_SDDM"
    g_state_set POWER "$G_POWER"
    g_state_set SHELL_RC "$G_SHELL_RC"
    g_state_set VAULT "$G_VAULT"
}

g_verify() {
    if g_have niri; then
        if niri validate >/dev/null 2>&1; then g_ok "niri config is valid"
        else g_warn "niri validate failed:"; niri validate 2>&1 | grep -v DEBUG | tail -n 8 | sed 's/^/         /'; fi
    fi
    if g_have systemctl && g_user_systemd; then
        local failed; failed=$(systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | xargs)
        if [ -n "$failed" ]; then g_warn "failed user units: $failed (systemctl --user status <unit>)"; else g_ok "no failed user units"; fi
    fi
}

g_summary() {
    printf '\n%s%s── %s ──%s\n' "$G_C_BOLD" "$G_C_CYAN" "$( g_is_dry && echo "dry run: nothing was changed" || echo "done")" "$G_C_RESET"
    printf '   files: %d created, %d updated, %d unchanged, %d kept (your edits), %d removed, %d restored%s\n' \
        "${G_COUNT[created]}" "${G_COUNT[updated]}" "${G_COUNT[unchanged]}" "${G_COUNT[kept]}" "${G_COUNT[removed]}" "${G_COUNT[restored]}" \
        "$( [ "${G_COUNT[left]}" -gt 0 ] && echo ", ${G_COUNT[left]} left (they were there before the installer)")"
    local w n
    if [ ${#G_WARNINGS[@]} -gt 0 ]; then
        printf '   %swarnings:%s\n' "$G_C_YELLOW" "$G_C_RESET"
        for w in "${G_WARNINGS[@]}"; do printf '     - %s\n' "$w"; done
    fi
    for n in "${G_NOTES[@]}"; do printf '   %s\n' "$n"; done
    [ -n "${G_LOG:-}" ] && printf '   log: %s\n' "${G_LOG/#$HOME/\~}"
}

g_status() {
    local e u
    if [ -f "$G_MANIFEST" ]; then
        printf '\n   glass layer: installed from %s on %s\n' "$(g_state_get GLASS_COMMIT)" "$(g_state_get INSTALLED_AT)"
        printf '   options: apps=[%s] ai=%s extras=[%s] sddm=%s power=%s shell-rc=%s vault=%s\n' "$(g_state_get APPS)" \
            "$(g_state_get AI)" "$(g_state_get WITH)" "$(g_state_get SDDM)" "$(g_state_get POWER)" "$(g_state_get SHELL_RC)" "$(g_state_get VAULT)"
    else
        printf '\n   glass layer: not installed by this installer\n'
    fi
    printf '   upstream Serpantinum: %s\n' "$(g_installed_commit || true)"
    printf '   files owned by glass: %s\n' "$( [ -f "$G_MANIFEST" ] && wc -l < "$G_MANIFEST" || echo 0)"
    printf '   apps:\n'
    for e in "${G_APPS_ALL[@]}"; do printf '     %-12s %s\n' "$e" "$(g_app_installed "$e" && echo installed || echo -)"; done
    printf '   AI extras:\n'
    for e in "${G_EXTRAS[@]}"; do printf '     %-12s %s\n' "$e" "$(g_extra_ready "$e" && echo ready || echo -)"; done
    printf '   units:\n'
    for u in "${G_UNITS_ALL[@]}"; do
        local en ac
        en=$(systemctl --user is-enabled "$u" 2>/dev/null); ac=$(systemctl --user is-active "$u" 2>/dev/null)
        printf '     %-26s %s / %s\n' "$u" "${en:--}" "${ac:--}"
    done
}

# ------------------------------------------------------------------ main
G_TMP=$(mktemp -d "${TMPDIR:-/tmp}/serp-glass.XXXXXX") || exit 1
chmod 755 "$G_TMP"   # the root step reads its script from here
trap 'rm -rf "$G_TMP"' EXIT

exec 9>"${XDG_RUNTIME_DIR:-/tmp}/serp-glass-$(id -u).lock"
if ! flock -n 9; then echo "serp-glass: another run of the installer is active" >&2; exit 1; fi

g_manifest_load

if [ "$G_MODE" = status ]; then g_banner; g_status; exit 0; fi

if ! g_is_dry; then
    mkdir -p "$G_STATE_DIR/logs"
    G_LOG="$G_STATE_DIR/logs/$G_MODE-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee >(sed -u 's/\x1b\[[0-9;]*[A-Za-z]//g' >> "$G_LOG")) 2>&1
    G_TEE_PID=$!
    trap 'exec 1>&- 2>&-; wait "$G_TEE_PID" 2>/dev/null; rm -rf "$G_TMP"' EXIT
fi

g_banner
g_preflight

if [ "$G_MODE" = uninstall ]; then
    G_STEPS=6
    if [ ! -f "$G_MANIFEST" ] && [ -z "$(g_state_get GLASS_COMMIT)" ]; then
        g_warn "the glass layer was never installed by this installer (no ${G_MANIFEST/#$HOME/\~}) — only the root parts are checked"
    fi
    printf '\n   Removes what glass installed: dotfiles (originals restored from backups), the Serpantinum patches,\n'
    printf '   the apps, the services it enabled, the login screen and the battery tweaks. Upstream Serpantinum,\n'
    printf '   your settings, music, notes, quiz progress and the packages stay.%s\n' "$( [ "$G_PURGE" = 1 ] && echo " --purge: AI models/builds glass downloaded are deleted.")"
    g_is_dry || g_ask "Remove the glass layer?" || { echo "   nothing changed"; exit 0; }
    g_step "services";  g_services_uninstall
    g_step "apps";      g_apps_uninstall
    g_step "shell";     g_shell_uninstall; g_manifest_save
    g_step "dotfiles";  g_dotfiles_uninstall; g_manifest_save; g_services_reload
    g_step "root";      if [ "$G_NO_ROOT" = 1 ]; then g_info "skipped (--no-root)"; else g_system_uninstall; fi
    g_step "extras";    g_extras_uninstall
    if ! g_is_dry; then
        if [ -f "$G_MANIFEST" ] && [ -s "$G_MANIFEST" ]; then
            g_warn "$(wc -l < "$G_MANIFEST") files were edited after install and stay; the manifest keeps them listed"
        else
            rm -f "$G_MANIFEST" "$G_STATE_FILE"
        fi
    fi
    g_have niri && { niri validate >/dev/null 2>&1 && g_ok "niri config is valid" || g_warn "niri validate failed — check ~/.config/niri/config.kdl"; }
    g_note "backups stay in ~/.config/serp-glass_backup/"
    g_summary
    exit 0
fi

# install / update
g_base_plan
g_step_on base || G_BASE_ACTION=skip
if g_menu_want; then g_menu; fi
g_print_plan
if ! g_is_dry; then
    g_ask "Install the glass edition?" || { echo "   nothing changed"; exit 0; }
    g_sudo_begin || { g_summary; exit 1; }
    if ! g_have git; then   # a clean system: the base step clones upstream, the shell step reads this repo
        g_info "installing git first"
        sudo pacman -S --needed --noconfirm git || sudo pacman -Syu --needed --noconfirm git || { g_err "can't install git"; exit 1; }
        G_GLASS_COMMIT=$(git -C "$G_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
    fi
    trap 'g_sudo_end; exec 1>&- 2>&-; wait "$G_TEE_PID" 2>/dev/null; rm -rf "$G_TMP"' EXIT
fi
G_STEPS=7
g_extras_snapshot

g_step "base: upstream Serpantinum"
g_base_run || { g_err "the base install failed — fix the problem above and re-run (nothing of glass was changed yet)"; g_summary; exit 1; }

g_step "root: packages, login screen, battery tweaks"
if ! g_step_on root; then
    g_info "skipped (--only)"
elif [ "$G_NO_ROOT" = 1 ]; then
    g_root_plan
    if [ ${#G_ROOT_ACTIONS[@]} -gt 0 ]; then
        g_info "skipped (--no-root). Run this yourself as root:  sudo bash $G_TMP/root.sh  (copy it first; it is deleted on exit)"
        sed 's/^/         /' "$G_TMP/root.sh"
    else g_ok "nothing needs root"; fi
else
    g_system_install
fi
g_sudo_end

g_step "dotfiles"
if g_step_on dotfiles; then g_dotfiles_install; g_rust_install; g_speedtest_install; g_manifest_save; else g_info "skipped (--only)"; fi

g_step "shell: glass changes to Serpantinum"
if g_step_on shell; then g_shell_install; g_manifest_save; else g_info "skipped (--only)"; fi

g_step "apps"
if g_step_on apps; then g_apps_install; else g_info "skipped (--only)"; fi

g_step "extras"
if g_step_on extras; then g_extras_install; g_extras_record; else g_info "skipped (--only)"; fi

g_step "services"
if g_step_on services; then g_venvs_install; g_services_install; else g_info "skipped (--only)"; fi

if ! g_is_dry; then
    g_manifest_save
    g_save_choices
    g_state_set GLASS_COMMIT "$G_GLASS_COMMIT"
    g_state_set UPSTREAM_BASE "$G_UPSTREAM_BASE"
    g_state_set INSTALLED_AT "$(date -Iseconds)"
    g_section "check"
    g_verify
    if [ -z "${NIRI_SOCKET:-}" ]; then
        g_note "next: log out and pick the niri session (or reboot) — the glass desktop starts at login"
    else
        g_note "next: log out and back in once so every service and the input method start cleanly"
    fi
    g_note "keys: Mod+Shift+/ shows every shortcut · calendar: run gcal-setup"
    g_note "update or change choices later: serp-glass (or serp-glass --menu, --ai on|off, --apps …)"
fi
g_summary
exit 0
