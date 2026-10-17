#!/usr/bin/env bash
# Apps: Glass Music, Glass Mail and JP Quiz, each installed by its own install.sh. Which ones is your
# choice (--apps or the menu) and is remembered; an app you deselect later is removed again.
# Your data is never touched: JP Quiz progress (~/.local/share/jp-quiz/progress.db), the music library and
# Glass Music caches, mail accounts (~/.config/glass-mail) and the mail cache.

G_APPS_ALL=(glass-music glass-mail jp-quiz)
declare -A G_APP_NAME=([glass-music]="Glass Music" [glass-mail]="Glass Mail" [jp-quiz]="JP Quiz")
declare -A G_APP_INFO=(
    [glass-music]="music library player: synced lyrics, My Vibe, Yandex Music (Mod+Shift+M)"
    [glass-mail]="mail for any IMAP account, HTML mails in a WebKitGTK view (Mod+I)"
    [jp-quiz]="adaptive Japanese trainer; builds its question bank: ~80 MB download, 5–10 min (Mod+J)"
)
# official-repo packages an app's build or runtime needs on top of the base list (system.sh)
declare -A G_APP_PKGS=([glass-music]="" [glass-mail]="webkit2gtk-4.1" [jp-quiz]="unzip")
# what an app's install.sh puts outside ~/.local/share/<app> ($HOME-relative): removed with the app
declare -A G_APP_FILES=(
    [glass-music]=".local/bin/glass-music .local/share/applications/glass-music.desktop .local/share/icons/hicolor/scalable/apps/glass-music.svg .config/systemd/user/glass-music-yandex-sync.service .config/systemd/user/glass-music-yandex-sync.timer"
    [glass-mail]=".local/bin/glass-mail .local/share/applications/glass-mail.desktop .local/share/icons/hicolor/scalable/apps/glass-mail.svg .config/systemd/user/glass-mail-watch.service"
    [jp-quiz]=".local/bin/jp-quiz .local/share/applications/jp-quiz.desktop .local/share/icons/hicolor/scalable/apps/jp-quiz.svg"
)
declare -A G_APP_UNITS=([glass-music]="glass-music-yandex-sync.timer" [glass-mail]="glass-mail-watch.service" [jp-quiz]="")

G_JQ_SRC="$G_ROOT/apps/jp-quiz"
G_JQ_DIR="$HOME/.local/share/jp-quiz"
G_BUILD="${XDG_CACHE_HOME:-$HOME/.cache}/serp-glass-build"     # build trees + downloads, safe to delete

g_app_selected() { [[ " ${G_APPS[*]:-} " == *" $1 "* ]]; }
g_app_installed() { [ -d "$HOME/.local/share/$1/app" ] && [ -x "$HOME/.local/bin/$1" ]; }

# True when $HOME-relative <rel> is a file an app's install.sh owns (the dotfiles step leaves it alone).
g_app_owned() {
    local a
    for a in "${G_APPS_ALL[@]}"; do [[ " ${G_APP_FILES[$a]} " == *" $1 "* ]] && return 0; done
    return 1
}

g_apps_pkgs() {
    local a
    for a in "${G_APPS_ALL[@]}"; do
        g_app_selected "$a" && [ -n "${G_APP_PKGS[$a]}" ] && printf '%s\n' ${G_APP_PKGS[$a]}
    done
    return 0
}

# Fingerprint of an app's source: an app whose source did not change since glass installed it is not rebuilt.
g_app_stamp() {
    (cd "$G_ROOT/apps/$1" && find . -type f ! -path './data/*' ! -path '*/target/*' ! -path '*/__pycache__/*' ! -name '*.pyc' -print0 |
        sort -z | xargs -0 sha256sum) | sha256sum | cut -c1-16
}

g_apps_install() {
    local a
    for a in "${G_APPS_ALL[@]}"; do
        if g_app_selected "$a"; then
            g_app_install "$a"
        elif [ -n "$(g_state_get "APP_$a")" ]; then
            g_app_remove "$a"          # deselected, and glass installed it earlier
        elif g_app_installed "$a"; then
            g_detail "not selected: ${G_APP_NAME[$a]} (installed by hand, left alone)"
        fi
    done
    return 0
}

g_app_install() {
    local a="$1" name="${G_APP_NAME[$1]}" stamp log="$G_BUILD/$1-install.log"
    stamp=$(g_app_stamp "$a")
    if g_app_installed "$a" && [ "$(g_state_get "APP_$a")" = "$stamp" ] && [ "${G_FORCE:-0}" != 1 ]; then
        g_ok "$name is up to date"
        return 0
    fi
    if g_is_dry; then
        if g_app_installed "$a"; then g_dry "update $name (apps/$a/install.sh; your data stays)"
        else g_dry "install $name: ${G_APP_INFO[$a]}"; fi
        [ "$a" = jp-quiz ] && [ ! -f "$G_JQ_DIR/content.db" ] && g_dry "  + build JP Quiz's question bank (Tatoeba/JMdict/JLPT data)"
        return 0
    fi
    mkdir -p "$G_BUILD"
    g_info "$name: building and installing (log: ${log/#$HOME/\~})"
    if [ "$a" = jp-quiz ]; then
        g_jpquiz_install "$log" || return 1
    elif ! bash "$G_ROOT/apps/$a/install.sh" > "$log" 2>&1; then
        tail -n 15 "$log" | sed 's/^/         /'
        g_warn "$name: install.sh failed (log: ${log/#$HOME/\~}); re-run the installer to retry"
        return 1
    fi
    grep -iE "missing|failed|could not" "$log" | head -n 3 | sed 's/^/         /'
    g_state_set "APP_$a" "$stamp"
    g_ok "$name installed"
}

g_jpquiz_install() {
    local log="$1" bd="$G_BUILD/jp-quiz"
    if [ ! -f "$G_JQ_DIR/content.db" ]; then
        g_jpquiz_build "$bd" || { g_warn "JP Quiz: question bank build failed, app not installed (re-run to retry)"; return 1; }
    else
        # code-only update: reuse the installed question bank
        g_jpquiz_tree "$bd" && cp "$G_JQ_DIR/content.db" "$bd/data/content.db" || { g_warn "JP Quiz: can't prepare $bd"; return 1; }
    fi
    if ! bash "$bd/install.sh" > "$log" 2>&1; then
        tail -n 15 "$log" | sed 's/^/         /'
        g_warn "JP Quiz: install.sh failed (log: ${log/#$HOME/\~})"
        return 1
    fi
}

# Copy the app source into the build dir (keeps data/ = downloads + built content between runs).
g_jpquiz_tree() {
    local bd="$1"
    mkdir -p "$bd/data" && rsync -a --delete --exclude /data/ --exclude target/ --exclude __pycache__ "$G_JQ_SRC/" "$bd/"
}

g_jpquiz_build() {
    local bd="$1" venv="$HOME/.venvs/jp-quiz"
    g_jpquiz_tree "$bd" || return 1
    g_info "JP Quiz: downloading the open data (Tatoeba, JMdict, KANJIDIC, JLPT lists; ~80 MB)"
    if [ ! -f "$bd/data/raw/JMdict.gz" ] || [ ! -f "$bd/data/raw/eng_sentences.tsv.bz2" ]; then
        bash "$bd/build/fetch.sh" || return 1
    fi
    if [ ! -x "$venv/bin/python" ] || ! "$venv/bin/python" -c 'import fugashi, unidic_lite, numpy' 2>/dev/null; then
        g_info "JP Quiz: build environment ${venv/#$HOME/\~} (fugashi, unidic-lite, numpy; ~300 MB)"
        g_have uv || { g_err "uv is missing (pacman -S uv)"; return 1; }
        uv venv -q --seed --python 3.12 "$venv" && uv pip install -q --python "$venv/bin/python" fugashi unidic-lite numpy || return 1
    fi
    g_info "JP Quiz: building the question bank (a few minutes)"
    (cd "$bd" && "$venv/bin/python" -m build.make_content) > "$G_BUILD/jp-quiz-build.log" 2>&1 ||
        { tail -n 20 "$G_BUILD/jp-quiz-build.log"; return 1; }
    [ -f "$bd/data/content.db" ]
}

# Remove an app glass installed (its data stays). Used when it is deselected and by --uninstall.
g_app_remove() {
    local a="$1" name="${G_APP_NAME[$1]}" u f
    if g_is_dry; then g_dry "remove $name (deselected; your data stays)"; return 0; fi
    if g_have systemctl && g_user_systemd; then
        for u in ${G_APP_UNITS[$a]}; do systemctl --user disable --now "$u" >/dev/null 2>&1; done
    fi
    rm -rf "$HOME/.local/share/$a/app"
    [ "$a" = jp-quiz ] && rm -f "$G_JQ_DIR/content.db"
    for f in ${G_APP_FILES[$a]}; do rm -f "$HOME/$f"; done
    g_have systemctl && g_user_systemd && systemctl --user daemon-reload 2>/dev/null
    gtk-update-icon-cache -q -t "$HOME/.local/share/icons/hicolor" 2>/dev/null
    update-desktop-database -q "$HOME/.local/share/applications" 2>/dev/null
    g_state_set "APP_$a" ""
    g_info "removed $name (your data stays)"
    [ "$a" = jp-quiz ] && [ -f "$G_JQ_DIR/progress.db" ] && g_note "JP Quiz progress kept: ~/.local/share/jp-quiz/progress.db"
    return 0
}

g_apps_uninstall() {
    local a
    for a in "${G_APPS_ALL[@]}"; do
        [ -n "$(g_state_get "APP_$a")" ] || [ -d "$HOME/.local/share/$a/app" ] || continue
        g_app_remove "$a"
    done
    return 0
}
