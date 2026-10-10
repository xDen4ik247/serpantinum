#!/usr/bin/env bash
# Everything that needs root, collected into ONE script that runs behind ONE sudo/pkexec prompt:
# glass packages (pacman, official repos only), the serp-glass SDDM greeter, and the battery tweaks.

# Packages the glass layer uses on top of upstream Serpantinum's own list (see system/packages.md).
G_PKGS_BASE=(
    # shell + terminal
    zsh zsh-autosuggestions zsh-completions zsh-history-substring-search zsh-syntax-highlighting
    starship zoxide eza bat fzf pkgfile ttf-jetbrains-mono-nerd
    # tools the scripts call
    rsync patch diffutils jq curl inotify-tools libnotify imagemagick uv
    # python for the helpers (system site-packages; ~/.venvs/default reuses them)
    python python-gobject python-numpy python-rich python-yaml python-pillow
    # music
    mpd mpc mpd-mpris rmpc
    # input method (EN/RU/JP) + CJK font
    fcitx5 fcitx5-mozc fcitx5-qt fcitx5-gtk fcitx5-configtool noto-fonts-cjk
    # typing for dictation / clipboard actions
    wtype
)
G_PKGS_GCAL=(python-icalendar python-recurring-ical-events python-x-wr-timezone)   # unless ~/.venvs/gcal has them
G_PKGS_SDDM=(sddm qt6-declarative qt6-svg qt6-5compat)

G_SDDM_THEME_DST=/usr/share/sddm/themes/serp-glass
G_SDDM_CONF=/etc/sddm.conf.d/20-serp-glass.conf
G_POWER_FILES=(/etc/udev/rules.d/60-battery-pci-runtime-pm.rules /etc/sysctl.d/60-battery.conf)

g_has_npu() { lspci -nn 2>/dev/null | grep -qiE 'Intel.*(NPU|Neural|AI Boost)' || [ -e /dev/accel/accel0 ]; }
g_has_battery() { compgen -G '/sys/class/power_supply/BAT*' >/dev/null; }

g_pkg_list() {
    local p=("${G_PKGS_BASE[@]}")
    g_gcal_venv_ok || p+=("${G_PKGS_GCAL[@]}")
    [ "${G_SDDM:-true}" = true ] && p+=("${G_PKGS_SDDM[@]}")
    printf '%s\n' "${p[@]}"
    g_extras_pkgs
}

# Packages still missing (pacman -T prints the unsatisfied ones).
g_pkg_missing() { pacman -T $(g_pkg_list | sort -u) 2>/dev/null; true; }

g_sddm_theme_current() {   # 0 = installed theme matches the repo
    [ -d "$G_SDDM_THEME_DST" ] && [ -f "$G_SDDM_CONF" ] || return 1
    # assets/ holds the wallpaper copied at install time; metadata.desktop only names the author
    diff -rq -x theme.conf.user -x assets -x metadata.desktop "$G_ROOT/system/sddm/themes/serp-glass" "$G_SDDM_THEME_DST" >/dev/null 2>&1 || return 1
    cmp -s "$G_ROOT/system/sddm/sddm.conf.d/20-serp-glass.conf" "$G_SDDM_CONF" || return 1
    [ -d /var/lib/serp-greeter ] && [ -O /var/lib/serp-greeter ]
}

g_power_current() {
    local f
    for f in "${G_POWER_FILES[@]}"; do cmp -s "$G_ROOT/system$f" "$f" || return 1; done
}

g_want_power() {
    case "${G_POWER:-auto}" in
        yes) return 0 ;; no) return 1 ;;
        *) g_has_battery ;;
    esac
}

# Write the root script for this run into $G_TMP/root.sh. Prints a one-line summary per action.
g_root_plan() {
    local missing f
    G_ROOT_ACTIONS=()
    mapfile -t missing < <(g_pkg_missing)
    {
        echo '#!/bin/bash'
        echo '# serp-glass: the root part of this install (generated; runs once)'
        echo 'set -u; rc=0; ok=()'
        if [ ${#missing[@]} -gt 0 ]; then
            # official repos only: refuse anything that isn't in core/extra/multilib
            printf 'for p in %s; do\n' "${missing[*]}"
            echo '  r=$(pacman -Si "$p" 2>/dev/null | awk "/^Repository/{print \$3; exit}")'
            echo '  case "$r" in core|extra|multilib) ;; *) echo "serp-glass: $p is not in the official repos (${r:-not found}) — skipped"; continue ;; esac'
            echo '  ok+=("$p")'
            echo 'done'
            echo '[ ${#ok[@]} -gt 0 ] && { pacman -S --needed --noconfirm "${ok[@]}" || rc=1; }'
            G_ROOT_ACTIONS+=("install ${#missing[@]} packages: ${missing[*]}")
        fi
        if [ "${G_SDDM:-true}" = true ] && ! g_sddm_theme_current; then
            # system/sddm/install.sh needs SUDO_USER/PKEXEC_UID; both survive into this script
            printf 'sh %q || rc=1\n' "$G_ROOT/system/sddm/install.sh"
            G_ROOT_ACTIONS+=("install the serp-glass SDDM greeter (/usr/share/sddm/themes/serp-glass + $G_SDDM_CONF)")
        fi
        if g_want_power && ! g_power_current; then
            for f in "${G_POWER_FILES[@]}"; do
                printf 'install -D -m 644 %q %q || rc=1\n' "$G_ROOT/system$f" "$f"
            done
            echo 'sysctl -q --system >/dev/null 2>&1 || true'
            echo 'udevadm control --reload 2>/dev/null || true'
            G_ROOT_ACTIONS+=("battery tweaks: PCI runtime PM udev rule + NMI watchdog off (${G_POWER_FILES[*]})")
        fi
        echo 'exit $rc'
    } > "$G_TMP/root.sh"
    chmod 755 "$G_TMP/root.sh"
}

# Run the root script with ONE prompt (sudo on a terminal, pkexec in a graphical session).
g_root_run() {
    local script="$1" why="$2"
    if [ "$(id -u)" = 0 ]; then bash "$script"; return; fi
    if g_have sudo && { [ -t 0 ] || sudo -n true 2>/dev/null; }; then
        sudo -p "[serp-glass] root is needed once for: $why. Password for %u: " env SUDO_USER="$USER" bash "$script"
    elif g_have pkexec && [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
        g_info "a password dialog will ask for root once ($why)"
        pkexec env PKEXEC_UID="$(id -u)" bash "$script"
    else
        g_err "need root for: $why — run this from a terminal (sudo) or a desktop session (pkexec)"
        return 1
    fi
}

g_system_install() {
    g_root_plan
    if [ ${#G_ROOT_ACTIONS[@]} -eq 0 ]; then
        g_ok "packages, greeter and system tweaks already in place — no root needed"
        return 0
    fi
    local a
    for a in "${G_ROOT_ACTIONS[@]}"; do
        if g_is_dry; then g_dry "root: $a"; else g_info "root: $a"; fi
    done
    g_is_dry && return 0
    printf '%s\n' "${G_ROOT_ACTIONS[@]}" > "$G_TMP/root.actions"
    if g_root_run "$G_TMP/root.sh" "glass packages / SDDM greeter / battery tweaks"; then
        g_ok "root step done"
    else
        g_warn "the root step reported a problem (see above); continuing with the user part"
    fi
    if [ "${G_SDDM:-true}" = true ] && g_sddm_theme_current; then g_state_set SDDM_THEME installed; fi
    if g_want_power && g_power_current; then g_state_set POWER_TWEAKS installed; fi
}

g_system_uninstall() {
    local s=()
    {
        echo '#!/bin/bash'
        echo 'set -u'
        if [ -f "$G_SDDM_CONF" ]; then
            echo "rm -f '$G_SDDM_CONF'"
            echo "rm -rf '$G_SDDM_THEME_DST' /var/lib/serp-greeter"
            s+=("remove the serp-glass greeter (SDDM falls back to material-you)")
        fi
        if [ "$(g_state_get POWER_TWEAKS)" = installed ]; then
            local f
            for f in "${G_POWER_FILES[@]}"; do echo "rm -f '$f'"; done
            echo 'sysctl -q kernel.nmi_watchdog=1 2>/dev/null || true; udevadm control --reload 2>/dev/null || true'
            s+=("remove the battery tweaks")
        fi
    } > "$G_TMP/root-uninstall.sh"
    [ ${#s[@]} -gt 0 ] || { g_ok "no root parts to remove"; return 0; }
    if g_is_dry; then for a in "${s[@]}"; do g_dry "root: $a"; done; return 0; fi
    g_root_run "$G_TMP/root-uninstall.sh" "$(IFS=';'; echo "${s[*]}")" && g_ok "root parts removed"
    g_note "packages installed for glass were kept (remove by hand if you like: $(g_pkg_list | tr '\n' ' '))"
}
