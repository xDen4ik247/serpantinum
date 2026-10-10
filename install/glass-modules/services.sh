#!/usr/bin/env bash
# Services: the Python environments the scripts expect, then the systemd user units.
#
# Units are enabled only when what they run is actually there, so a machine without the optional
# extras never gets a unit that fails in a loop. On-demand units stay on-demand: the LLM starts from
# npu-llm.socket, the notes embedding server from ai-notes, the greeter sync from greeter-sync.path.

G_VENV_DEFAULT="$HOME/.venvs/default"   # `python`/`pip` for zsh, ai-chat, ai-notes (system site-packages)
G_VENV_GCAL="$HOME/.venvs/gcal"         # gcal-sync (icalendar from pacman via system site-packages)

g_gcal_venv_ok() { [ -x "$G_VENV_GCAL/bin/python" ] && "$G_VENV_GCAL/bin/python" -c 'import icalendar, recurring_ical_events' 2>/dev/null; }

# A venv on the system Python that sees pacman's Python packages. Never touches an existing one.
g_make_system_venv() {   # dir why
    local d="$1" why="$2"
    if [ -x "$d/bin/python" ]; then g_detail "ok        ${d/#$HOME/\~}"; return 0; fi
    if g_is_dry; then g_dry "create ${d/#$HOME/\~} ($why)"; return 0; fi
    if g_have uv; then
        uv venv -q --seed --system-site-packages --python /usr/bin/python3 "$d" ||
            { g_warn "uv venv $d failed"; return 1; }
    else
        /usr/bin/python3 -m venv --system-site-packages "$d" || { g_warn "python -m venv $d failed"; return 1; }
    fi
    g_info "created ${d/#$HOME/\~} ($why)"
}

g_venvs_install() {
    g_make_system_venv "$G_VENV_DEFAULT" "python/pip for your shell, ai-chat, ai-notes"
    if [ -x "$G_VENV_GCAL/bin/python" ] && ! g_is_dry && ! g_gcal_venv_ok; then
        g_warn "${G_VENV_GCAL/#$HOME/\~} exists but can't import icalendar — gcal-sync needs: uv pip install --python $G_VENV_GCAL/bin/python icalendar recurring-ical-events"
    fi
    g_make_system_venv "$G_VENV_GCAL" "gcal-sync (Google Calendar agenda)"
}

# ---------------------------------------------------------------- which units
# Prints "unit<TAB>reason" for every unit glass wants enabled on this machine right now.
g_units_wanted() {
    printf '%s\t%s\n' fcitx5.service "input method (EN/RU/JP)"
    printf '%s\t%s\n' mpd.service "music daemon" mpd-mpris.service "music: media keys + bar player"
    printf '%s\t%s\n' music-smart.service "music: smart shuffle + history"
    printf '%s\t%s\n' gcal-sync.timer "agenda refresh (Google Calendar + Obsidian; idle without a calendar)"
    printf '%s\t%s\n' anki-queue-flush.timer "sends queued Anki notes (no-op when empty)"
    g_has_battery && printf '%s\t%s\n' power-mode.service "battery-aware power switch (laptop)"
    g_unit_shipped sleep-guard.service &&
        printf '%s\t%s\n' sleep-guard.service "locks before sleep, wakes the screens after resume"
    [ -d /var/lib/serp-greeter ] && [ -w /var/lib/serp-greeter ] &&
        printf '%s\t%s\n' greeter-sync.path "copies wallpaper + palette to the login screen"
    g_extra_ready llm       && printf '%s\t%s\n' npu-llm.socket "local LLM, started on the first request"
    g_extra_ready dictation && printf '%s\t%s\n' aidict.service "Whisper dictation daemon (Mod+Z)"
    g_extra_ready ocr       && printf '%s\t%s\n' npu-ocr.service "Japanese OCR daemon (Mod+X)"
    g_extra_ready notes && [ -d "$(g_vault_dir)" ] &&
        printf '%s\t%s\n' ai-notes-watch.service "re-indexes the Obsidian vault while the notes model runs"
    return 0
}

# True when glass ships this unit file (it is installed by the dotfiles step).
g_unit_shipped() { [ -f "$G_ROOT/home/.config/systemd/user/$1" ]; }

# Units that belong to the graphical session: enabled now, started by the next login (starting them over
# ssh or a tty would fail).
G_UNITS_SESSION=" fcitx5.service power-mode.service sleep-guard.service "

# Units we may have enabled in an earlier run (for --uninstall and for features that went away).
G_UNITS_ALL=(fcitx5.service mpd.service mpd-mpris.service music-smart.service gcal-sync.timer anki-queue-flush.timer
             power-mode.service sleep-guard.service greeter-sync.path npu-llm.socket aidict.service npu-ocr.service ai-notes-watch.service)

# Scripts whose running daemon must restart when they change.
declare -A G_UNIT_OF=(
    [.local/bin/music-smart]=music-smart.service
    [.local/bin/power-mode]=power-mode.service
    [.local/bin/sleep-guard]=sleep-guard.service
    [.local/share/aifeat/dictd.py]=aidict.service
    [.local/share/npu-ocr/jocr/server.py]=npu-ocr.service
    [.local/share/npu-ocr/jocr/engine.py]=npu-ocr.service
    [.local/share/ai-notes/ai_notes.py]=ai-notes-watch.service
)

g_user_systemd() { systemctl --user show-environment >/dev/null 2>&1; }
g_graphical() { systemctl --user is-active -q graphical-session.target 2>/dev/null; }

g_services_install() {
    if ! g_have systemctl; then g_warn "no systemd: enable the services in home/.config/systemd/user by hand"; return 0; fi
    if ! g_user_systemd; then
        g_warn "no systemd user manager in this shell (su/sudo?) — run the installer from your own login, or enable later:"
        g_units_wanted | cut -f1 | tr '\n' ' ' | sed 's/^/         systemctl --user enable /'; echo
        return 0
    fi
    g_run systemctl --user daemon-reload

    local unit why enabled_by_us now=() rel u
    read -r -a enabled_by_us <<< "$(g_state_get ENABLED_UNITS)"
    while IFS=$'\t' read -r unit why; do
        [ -n "$unit" ] || continue
        if systemctl --user is-enabled -q "$unit" 2>/dev/null; then
            g_detail "enabled   $unit"
            continue
        fi
        if g_is_dry; then g_dry "enable    $unit — $why"; continue; fi
        if [[ "$G_UNITS_SESSION" == *" $unit "* ]] && ! g_graphical; then
            systemctl --user enable -q "$unit" 2>/dev/null || { g_warn "can't enable $unit"; continue; }
        else
            systemctl --user enable -q --now "$unit" 2>/dev/null || systemctl --user enable -q "$unit" 2>/dev/null ||
                { g_warn "can't enable $unit"; continue; }
        fi
        g_ok "enabled $unit — $why"
        now+=("$unit")
    done < <(g_units_wanted)

    # Units an earlier run enabled whose feature is gone now (e.g. a model was deleted): disable them.
    local wanted; wanted=" $(g_units_wanted | cut -f1 | tr '\n' ' ') "
    for u in "${enabled_by_us[@]}"; do
        [[ "$wanted" == *" $u "* ]] && continue
        if g_is_dry; then g_dry "disable   $u (its feature is no longer installed)"; continue; fi
        systemctl --user disable -q --now "$u" 2>/dev/null && g_info "disabled $u (its feature is no longer installed)"
    done

    # Restart daemons whose unit file or script changed in this run (only if they are running).
    declare -A seen=()
    for rel in "${G_CHANGED[@]}"; do
        u=""
        case "$rel" in
            .config/systemd/user/*.service.d/*) u=$(basename "$(dirname "$rel")" .d) ;;
            .config/systemd/user/*.service|.config/systemd/user/*.socket|.config/systemd/user/*.path|.config/systemd/user/*.timer)
                u=$(basename "$rel") ;;
            *) u="${G_UNIT_OF[$rel]:-}" ;;
        esac
        [ -n "$u" ] && [ -z "${seen[$u]:-}" ] || continue
        seen[$u]=1
        [[ " ${now[*]} " == *" $u "* ]] && continue   # just started with the new files
        systemctl --user is-active -q "$u" 2>/dev/null || continue
        [[ "$u" == *.timer || "$u" == *.socket ]] && continue   # picked up by daemon-reload (a .path re-arms on restart)
        if g_is_dry; then g_dry "restart   $u (updated)"; continue; fi
        systemctl --user try-restart "$u" 2>/dev/null && g_info "restarted $u (updated)"
    done

    if ! g_is_dry; then
        local keep=() x
        for x in "${enabled_by_us[@]}" "${now[@]}"; do
            [[ "$wanted" == *" $x "* ]] && [[ " ${keep[*]} " != *" $x "* ]] && keep+=("$x")
        done
        g_state_set ENABLED_UNITS "${keep[*]}"
    fi
    g_dbus_reload
    g_greeter_refresh
}

# The fcitx5 D-Bus override (~/.local/share/dbus-1/services) is read when the bus reloads its config.
g_dbus_reload() {
    g_is_dry && return 0
    [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus" ] || return 0
    busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ReloadConfig >/dev/null 2>&1 || true
}

# Fill the login screen with the current wallpaper + palette now (greeter-sync.path keeps it fresh later).
g_greeter_refresh() {
    [ -d /var/lib/serp-greeter ] && [ -w /var/lib/serp-greeter ] && [ -x "$HOME/.local/bin/greeter-sync" ] || return 0
    g_is_dry && return 0
    "$HOME/.local/bin/greeter-sync" >/dev/null 2>&1 || true
}

g_services_uninstall() {
    g_have systemctl && g_user_systemd || return 0
    local u units
    read -r -a units <<< "$(g_state_get ENABLED_UNITS)"
    # Disable what glass enabled, plus any enabled unit whose file glass installed (it is about to go).
    for u in "${G_UNITS_ALL[@]}"; do
        systemctl --user is-enabled -q "$u" 2>/dev/null || continue
        [[ " ${units[*]} " == *" $u "* ]] || [ -n "${G_MAN_SHA[.config/systemd/user/$u]:-}" ] || continue
        if g_is_dry; then g_dry "disable   $u"; continue; fi
        systemctl --user disable -q --now "$u" 2>/dev/null && g_info "disabled $u"
    done
    g_is_dry || g_state_set ENABLED_UNITS ""
}

# After the unit files are gone.
g_services_reload() {
    g_have systemctl && g_user_systemd && ! g_is_dry || return 0
    systemctl --user daemon-reload 2>/dev/null
    systemctl --user reset-failed 2>/dev/null
    g_dbus_reload
}
