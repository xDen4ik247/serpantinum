#!/usr/bin/env bash
# Apps: Glass Music (always) and JP Quiz (opt-in: --with jpquiz), installed by their own install.sh.
# Your data is never touched: JP Quiz progress (~/.local/share/jp-quiz/progress.db), the music library,
# Glass Music caches.

G_GM_SRC="$G_ROOT/apps/glass-music"
G_GM_DIR="$HOME/.local/share/glass-music"
G_JQ_SRC="$G_ROOT/apps/jp-quiz"
G_JQ_DIR="$HOME/.local/share/jp-quiz"
G_BUILD="${XDG_CACHE_HOME:-$HOME/.cache}/serp-glass-build"     # build trees + downloads, safe to delete
G_ICONS="$HOME/.local/share/icons/hicolor/scalable/apps"

# 0 when the installed app (<dir>/app) has exactly the repo's code. Args: src dst part...
g_app_current() {
    local src="$1" dst="$2" p; shift 2
    [ -d "$dst" ] || return 1
    for p in "$@"; do
        diff -rq -x __pycache__ -x '*.pyc' -x '*.frag' "$src/$p" "$dst/$p" >/dev/null 2>&1 || return 1
    done
}

g_apps_install() {
    g_glass_music_install
    if g_want_jpquiz; then g_jpquiz_install; fi
}

g_glass_music_install() {
    if g_app_current "$G_GM_SRC" "$G_GM_DIR/app" glassmusic qml assets && cmp -s "$G_GM_SRC/assets/icon/glass-music.svg" "$G_ICONS/glass-music.svg"; then
        g_ok "Glass Music is up to date"
        return 0
    fi
    if g_is_dry; then g_dry "install Glass Music (apps/glass-music/install.sh -> ~/.local/share/glass-music/app)"; return 0; fi
    if bash "$G_GM_SRC/install.sh" >/dev/null; then g_ok "Glass Music installed (Mod+Shift+M)"
    else g_warn "Glass Music install.sh failed"; fi
}

g_jpquiz_install() {
    local bd="$G_BUILD/jp-quiz"
    if [ -f "$G_JQ_DIR/content.db" ] && g_app_current "$G_JQ_SRC" "$G_JQ_DIR/app" jpquiz qml assets &&
       cmp -s "$G_JQ_SRC/assets/icon/jp-quiz.svg" "$G_ICONS/jp-quiz.svg"; then
        g_ok "JP Quiz is up to date"
        return 0
    fi
    if [ ! -f "$G_JQ_DIR/content.db" ]; then
        if g_is_dry; then
            g_dry "build JP Quiz's question bank (downloads ~80 MB of Tatoeba/JMdict/JLPT data, ~5–10 min) and install the app"
            return 0
        fi
        g_jpquiz_build "$bd" || { g_warn "JP Quiz: question bank build failed — app not installed (re-run to retry)"; return 1; }
    else
        if g_is_dry; then g_dry "update the JP Quiz app (keeps its question bank and your progress)"; return 0; fi
        # code-only update: reuse the installed question bank
        g_jpquiz_tree "$bd" && cp "$G_JQ_DIR/content.db" "$bd/data/content.db" || { g_warn "JP Quiz: can't prepare $bd"; return 1; }
    fi
    if bash "$bd/install.sh" >/dev/null; then g_ok "JP Quiz installed (Mod+J; your progress is kept)"
    else g_warn "JP Quiz install.sh failed"; fi
}

# Copy the app source into the build dir (keeps data/ = downloads + built content between runs).
g_jpquiz_tree() {
    local bd="$1"
    mkdir -p "$bd/data" && rsync -a --delete --exclude /data/ --exclude __pycache__ "$G_JQ_SRC/" "$bd/"
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

g_apps_uninstall() {
    local d
    for d in "$G_GM_DIR/app" "$G_JQ_DIR/app" "$G_JQ_DIR/content.db"; do
        [ -e "$d" ] || continue
        if g_is_dry; then g_dry "remove    ${d/#$HOME/\~}"; continue; fi
        rm -rf "$d" && g_info "removed ${d/#$HOME/\~}"
    done
    for d in "$G_ICONS/glass-music.svg" "$G_ICONS/jp-quiz.svg"; do
        [ -e "$d" ] || continue
        if g_is_dry; then g_dry "remove    ${d/#$HOME/\~}"; else rm -f "$d"; fi
    done
    g_is_dry || { gtk-update-icon-cache -q -t "$HOME/.local/share/icons/hicolor" 2>/dev/null; update-desktop-database -q "$HOME/.local/share/applications" 2>/dev/null; } || true
    [ -f "$G_JQ_DIR/progress.db" ] && g_note "JP Quiz progress kept: ~/.local/share/jp-quiz/progress.db"
    return 0
}
