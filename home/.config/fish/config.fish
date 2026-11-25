# ~/.config/fish/config.fish — Serpantinum Glass's everyday shell (kitty runs fish).
# zsh stays installed as the login shell and for scripts: ~/.zshrc / ~/.zshenv are kept as they were.
# Autosuggestions, syntax colors and ↑/↓ history search are built into fish; nothing to source for them.
# Functions (mkenv, workon, …) live in functions/, one file each, loaded on first use.

# ── Environment (every fish, interactive or not: same job as ~/.zshenv) ────────
# ~/.venvs/default is always on PATH, so `python`, `pip install x` and `jupyter lab` just work.
fish_add_path --global --path --move $HOME/.local/bin $HOME/.venvs/default/bin
set -gx EDITOR nvim
set -gx VISUAL nvim
# kitty sets $SHELL to the shell it runs. Tools that call `$SHELL -c '…'` (Claude Code, some installers)
# expect POSIX syntax, so children keep seeing zsh, the login shell.
test -x /usr/bin/zsh; and set -gx SHELL /usr/bin/zsh

status is-interactive; or return

# ── Interactive ────────────────────────────────────────────────────────────────
set -g __serp_cache (set -q XDG_CACHE_HOME; and echo $XDG_CACHE_HOME; or echo $HOME/.cache)/fish
test -d $__serp_cache; or mkdir -p $__serp_cache
set -g VENVS $HOME/.venvs

# Tool init scripts are cached and regenerated only when the tool itself updates.
function __serp_cached_init --argument-names name bin
    set -l f $__serp_cache/init-$name.fish
    if not test -s $f; or test (path mtime $bin) -gt (path mtime $f)
        $argv[3..] >$f
    end
    source $f
end

set -gx FZF_DEFAULT_COMMAND 'fd --type f --hidden --exclude .git'
set -gx FZF_CTRL_T_COMMAND $FZF_DEFAULT_COMMAND
set -gx FZF_ALT_C_COMMAND 'fd --type d --hidden --exclude .git'
# Colors are terminal palette slots, so fzf follows the wallpaper theme too.
set -gx FZF_DEFAULT_OPTS '--height 45% --layout reverse --border rounded --info inline-right
  --color fg:7,bg:-1,hl:2,fg+:15,bg+:0,hl+:2,info:8,prompt:2,pointer:3,marker:3,spinner:3,header:8,border:8,gutter:-1'
set -gx FZF_CTRL_T_OPTS "--preview 'bat -n --color=always {} 2>/dev/null' --preview-window right,55%"
set -gx BAT_THEME ansi
set -gx VIRTUAL_ENV_DISABLE_PROMPT 1   # the prompt shows the env itself

__serp_cached_init fzf /usr/bin/fzf fzf --fish                               # Ctrl+R history, Ctrl+T files, Alt+C dirs
__serp_cached_init zoxide /usr/bin/zoxide zoxide init fish --cmd cd          # `cd proj` jumps to your most-used match; `cdi` to pick
__serp_cached_init starship /usr/bin/starship starship init fish --print-full-init
# "foo: not found" → which package has it: fish's own handler asks pkgfile.

# ── Colors ─────────────────────────────────────────────────────────────────────
# Named colors are the terminal's 16 palette slots, which the wallpaper theme rewrites, so the
# command line recolors with the wallpaper. Global (not universal) so this file stays the source of truth.
set -g fish_color_normal normal
set -g fish_color_command green --bold
set -g fish_color_keyword magenta --bold
set -g fish_color_param cyan
set -g fish_color_option cyan
set -g fish_color_quote yellow
set -g fish_color_redirection magenta
set -g fish_color_end magenta
set -g fish_color_operator blue
set -g fish_color_escape blue
set -g fish_color_comment brblack --italics
set -g fish_color_error red --bold
set -g fish_color_valid_path --underline
set -g fish_color_autosuggestion brblack     # palette "outline" grey; → or End accepts
set -g fish_color_selection --background=brblack
set -g fish_color_search_match --background=magenta brgreen --bold
set -g fish_color_history_current --bold
set -g fish_color_cancel red
set -g fish_pager_color_prefix green --bold --underline
set -g fish_pager_color_completion normal
set -g fish_pager_color_description brblack --italics
set -g fish_pager_color_progress black --background=green
set -g fish_pager_color_selected_background --background=black
set -g fish_pager_color_selected_prefix brgreen --bold --underline

# ── Aliases ────────────────────────────────────────────────────────────────────
alias ls 'eza --icons=auto --group-directories-first'
alias ll 'eza -l --icons=auto --group-directories-first --git --time-style=relative'
alias la 'eza -la --icons=auto --group-directories-first --git --time-style=relative'
alias lt 'eza --tree --level=2 --icons=auto --group-directories-first'
alias cat 'bat -pp'   # plain output; behaves exactly like cat when piped
alias grep 'grep --color=auto'
alias diff 'diff --color=auto'
alias ip 'ip -color=auto'
