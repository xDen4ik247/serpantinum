#!/usr/bin/env bash
# The choices menu: apps, AI features, desktop options. Shown on a terminal for a first install, or with
# --menu (serp-glass --menu); plain bash, so it works on a bare TTY before anything is installed.
# Toggling only changes G_APPS / G_AI / G_WITH / G_SDDM / G_POWER / G_SHELL_RC; glass.sh saves them.

g_menu_want() {
    case "${G_MENU:-auto}" in
        yes) [ -t 0 ] && [ -t 1 ] || { g_warn "--menu needs a terminal; using the saved choices"; return 1; } ;;
        no) return 1 ;;
        *) [ "${G_YES:-0}" != 1 ] && ! g_is_dry && [ -t 0 ] && [ -t 1 ] && [ -z "$(g_state_get GLASS_COMMIT)" ] || return 1 ;;
    esac
}

g_menu_box() { [ "$1" = 1 ] && printf '%s[x]%s' "$G_C_GREEN" "$G_C_RESET" || printf '[ ]'; }

g_menu_draw() {
    local i=0 a e on hw
    printf '\n   %sWhat should the glass edition install?%s\n' "$G_C_BOLD" "$G_C_RESET"
    printf '\n   %sApps%s\n' "$G_C_BOLD" "$G_C_RESET"
    for a in "${G_APPS_ALL[@]}"; do
        i=$((i + 1)); on=0; g_app_selected "$a" && on=1
        printf '   %2d %s %-13s %s%s%s\n' "$i" "$(g_menu_box $on)" "${G_APP_NAME[$a]}" "$G_C_DIM" "${G_APP_INFO[$a]}" "$G_C_RESET"
    done
    if g_has_npu; then hw="Intel NPU found"; elif g_has_intel_gpu; then hw="no NPU: dictation/OCR run on the GPU/CPU"; else hw="no Intel NPU/GPU: slow on the CPU"; fi
    printf '\n   %sAI features%s %s(local, on the Intel NPU/GPU; %s)%s\n' "$G_C_BOLD" "$G_C_RESET" "$G_C_DIM" "$hw" "$G_C_RESET"
    i=$((i + 1)); on=0; g_ai_on && on=1
    printf '   %2d %s %-13s %s%s%s\n' "$i" "$(g_menu_box $on)" "AI features" "$G_C_DIM" "assistant, dictation, OCR, notes: keys, scripts, services. Off = nothing AI is installed" "$G_C_RESET"
    for e in dictation ocr llm notes; do
        i=$((i + 1)); on=0; [ "${G_WITH[$e]:-0}" = 1 ] && g_ai_on && on=1
        printf '   %2d   %s %-11s %s%s%s\n' "$i" "$(g_menu_box $on)" "$e" "$G_C_DIM" "$(g_menu_extra_line "$e")" "$G_C_RESET"
    done
    printf '\n   %sDesktop%s\n' "$G_C_BOLD" "$G_C_RESET"
    i=$((i + 1)); on=0; [ "${G_SDDM:-true}" = true ] && on=1
    printf '   %2d %s %-13s %s%s%s\n' "$i" "$(g_menu_box $on)" "login screen" "$G_C_DIM" "the glass SDDM greeter (your wallpaper + colours)" "$G_C_RESET"
    i=$((i + 1)); on=0; g_want_power && on=1
    printf '   %2d %s %-13s %s%s%s\n' "$i" "$(g_menu_box $on)" "battery" "$G_C_DIM" "laptop power saving + smart charging$(g_has_battery || echo " (no battery here)")" "$G_C_RESET"
    i=$((i + 1)); on=0; [ "${G_SHELL_RC:-1}" = 1 ] && on=1
    printf '   %2d %s %-13s %s%s%s\n' "$i" "$(g_menu_box $on)" "zsh config" "$G_C_DIM" "~/.zshrc, ~/.zshenv, ~/.zprofile, starship prompt (yours are backed up)" "$G_C_RESET"
}

g_menu_extra_line() {
    case "$1" in
        dictation) echo "Whisper speech-to-text, Mod+Z: ~1.2 GB" ;;
        ocr)       echo "Japanese OCR + JMdict popup, Mod+X: ~1 GB (2.5 GB while it is set up)" ;;
        llm)       echo "local assistant (Qwen3.5-4B), Mod+A: ~3.2 GB + a 10–20 min build, 16 GB RAM" ;;
        notes)     echo "ask your Obsidian vault, Mod+N: 640 MB (needs llm)" ;;
    esac
}

g_menu_toggle() {   # item number
    local n="$1" a
    local apps_n=${#G_APPS_ALL[@]}
    if [ "$n" -ge 1 ] && [ "$n" -le "$apps_n" ]; then
        a="${G_APPS_ALL[$((n - 1))]}"
        if g_app_selected "$a"; then
            local keep=() x; for x in "${G_APPS[@]}"; do [ "$x" = "$a" ] || keep+=("$x"); done
            G_APPS=("${keep[@]}")
        else
            G_APPS+=("$a")
        fi
        return 0
    fi
    case $((n - apps_n)) in
        1) if g_ai_on; then G_AI=off; else G_AI=on; fi ;;
        2|3|4|5)
            local e; e=$(echo dictation ocr llm notes | cut -d' ' -f$((n - apps_n - 1)))
            if [ "${G_WITH[$e]:-0}" = 1 ] && g_ai_on; then
                G_WITH[$e]=0
                [ "$e" = llm ] && G_WITH[notes]=0          # notes needs llm
                [ "$e" = ocr ] && G_WITH[jmdict]=0         # the dictionary only serves the OCR popup
            else
                G_AI=on; G_WITH[$e]=1
                [ "$e" = notes ] && G_WITH[llm]=1
                [ "$e" = ocr ] && G_WITH[jmdict]=1
            fi ;;
        6) if [ "${G_SDDM:-true}" = true ]; then G_SDDM=false; else G_SDDM=true; fi ;;
        7) if g_want_power; then G_POWER=no; else G_POWER=yes; fi ;;
        8) if [ "${G_SHELL_RC:-1}" = 1 ]; then G_SHELL_RC=0; else G_SHELL_RC=1; fi ;;
        *) return 1 ;;
    esac
}

g_menu() {
    local choice n bad
    while true; do
        g_menu_draw
        printf '\n   Toggle with the numbers (e.g. "3 5"), Enter = continue with this, q = quit: '
        read -r choice || exit 1
        case "$choice" in
            "") break ;;
            q|Q) echo "   nothing changed"; exit 0 ;;
        esac
        bad=""
        for n in ${choice//,/ }; do
            [[ "$n" =~ ^[0-9]+$ ]] && g_menu_toggle "$n" || bad+=" $n"
        done
        [ -n "$bad" ] && printf '   %sunknown:%s%s\n' "$G_C_YELLOW" "$bad" "$G_C_RESET"
    done
    # drop extras whose dependency was unticked
    [ "${G_WITH[llm]:-0}" = 1 ] || G_WITH[notes]=0
    local e; for e in "${!G_WITH[@]}"; do [ "${G_WITH[$e]}" = 1 ] || unset 'G_WITH[$e]'; done
    G_MENU_SHOWN=1
}
