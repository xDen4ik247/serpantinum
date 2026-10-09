# ~/.zshrc — fast zsh with fish-like comforts (target: < 60 ms to start).
# Plugins come from pacman, so they update with the system. PATH is in ~/.zshenv.
# Old setup (oh-my-zsh + conda): ~/backups/pre-tweaks-20261005

ZCACHE=${XDG_CACHE_HOME:-$HOME/.cache}/zsh
[[ -d $ZCACHE ]] || mkdir -p $ZCACHE

# ── Greeting ────────────────────────────────────────────────────────────────
# fastfetch once per kitty window: not for `zsh -c …` (e.g. the Claude window)
# and not in shells started from inside another shell.
if [[ -z $ZSH_EXECUTION_STRING && -n $KITTY_WINDOW_ID && -z $ZSH_GREETED ]]; then
  export ZSH_GREETED=1
  fastfetch
fi

# ── History & options ───────────────────────────────────────────────────────
HISTFILE=~/.zsh_history
HISTSIZE=100000
SAVEHIST=100000
setopt extended_history share_history hist_ignore_all_dups hist_ignore_space \
       hist_reduce_blanks hist_verify
setopt autocd interactive_comments no_beep
WORDCHARS=${WORDCHARS//[\/.=-]/}   # Ctrl+←/→ and Ctrl+Backspace stop at / . = -

# ── Completion ──────────────────────────────────────────────────────────────
autoload -Uz compinit
_zfresh=($ZCACHE/zcompdump(N.mh-24))   # rebuild the cache at most once a day
if (( $#_zfresh )); then compinit -C -d $ZCACHE/zcompdump; else compinit -d $ZCACHE/zcompdump; fi
unset _zfresh
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'
zstyle ':completion:*' list-colors ''
zstyle ':completion:*' group-name ''
zstyle ':completion:*:descriptions' format '%F{4}── %d%f'
zstyle ':completion:*:warnings' format '%F{1}no matches%f'
zstyle ':completion:*' squeeze-slashes true
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path $ZCACHE/compcache

# ── Keys ────────────────────────────────────────────────────────────────────
bindkey -e
bindkey '^[[1;5C' forward-word         # Ctrl+→
bindkey '^[[1;5D' backward-word        # Ctrl+←
bindkey '^H'      backward-kill-word   # Ctrl+Backspace
bindkey '^[[3;5~' kill-word            # Ctrl+Delete
bindkey '^[[3~'   delete-char          # Delete
bindkey '^[[H' beginning-of-line; bindkey '^[OH' beginning-of-line   # Home
bindkey '^[[F' end-of-line;       bindkey '^[OF' end-of-line         # End
bindkey '^[[Z' reverse-menu-complete                                 # Shift+Tab

# ── Tools ───────────────────────────────────────────────────────────────────
# Init scripts are cached and regenerated only when the tool itself updates.
_cached_init() {   # name binary command...
  local f=$ZCACHE/init-$1.zsh bin=$2; shift 2
  [[ -s $f && $f -nt $bin ]] || "$@" >| $f
  source $f
}
export FZF_DEFAULT_COMMAND='fd --type f --hidden --exclude .git'
export FZF_CTRL_T_COMMAND=$FZF_DEFAULT_COMMAND
export FZF_ALT_C_COMMAND='fd --type d --hidden --exclude .git'
# Colors are terminal palette slots, so fzf follows the wallpaper theme too.
export FZF_DEFAULT_OPTS='--height 45% --layout reverse --border rounded --info inline-right
  --color fg:7,bg:-1,hl:2,fg+:15,bg+:0,hl+:2,info:8,prompt:2,pointer:3,marker:3,spinner:3,header:8,border:8,gutter:-1'
export FZF_CTRL_T_OPTS="--preview 'bat -n --color=always {} 2>/dev/null' --preview-window right,55%"
export BAT_THEME=ansi
export VIRTUAL_ENV_DISABLE_PROMPT=1   # the prompt shows the env itself

[[ -t 0 ]] && _cached_init fzf /usr/bin/fzf fzf --zsh         # Ctrl+R history, Ctrl+T files, Alt+C dirs
_cached_init zoxide   /usr/bin/zoxide   zoxide init zsh --cmd cd        # `cd proj` jumps to your most-used match; `cdi` to pick
_cached_init starship /usr/bin/starship starship init zsh --print-full-init
source /usr/share/doc/pkgfile/command-not-found.zsh                    # "foo: not found" → which package has it

# ── Aliases ─────────────────────────────────────────────────────────────────
alias ls='eza --icons=auto --group-directories-first'
alias ll='eza -l --icons=auto --group-directories-first --git --time-style=relative'
alias la='eza -la --icons=auto --group-directories-first --git --time-style=relative'
alias lt='eza --tree --level=2 --icons=auto --group-directories-first'
alias cat='bat -pp'   # plain output; behaves exactly like cat when piped
alias grep='grep --color=auto'
alias diff='diff --color=auto'
alias ip='ip -color=auto'

# ── Python ──────────────────────────────────────────────────────────────────
# ~/.venvs/default is always on PATH (see ~/.zshenv). Extra envs live in ~/.venvs:
#   mkenv NAME [PYTHON]   create one (pip included) and switch to it, e.g. `mkenv ml 3.12`
#   workon NAME           switch to an env (Tab completes); `deactivate` to leave
#   rmenv NAME            delete an env      lsenv   list envs
VENVS=$HOME/.venvs
mkenv() {
  [[ -n $1 ]] || { print -u2 "usage: mkenv NAME [PYTHON_VERSION]"; return 1; }
  [[ ! -e $VENVS/$1 ]] || { print -u2 "env '$1' already exists — use: workon $1"; return 1; }
  uv venv --seed ${2:+--python $2} "$VENVS/$1" && workon "$1"
}
workon() {
  [[ -n $1 ]] || { lsenv; return; }
  [[ -f $VENVS/$1/bin/activate ]] || { print -u2 "no env '$1' — see: lsenv"; return 1; }
  source "$VENVS/$1/bin/activate"
}
rmenv() {
  [[ -n $1 && $1 != default ]] || { print -u2 "usage: rmenv NAME (the default env stays)"; return 1; }
  [[ -d $VENVS/$1 ]] || { print -u2 "no env '$1'"; return 1; }
  [[ $VIRTUAL_ENV == $VENVS/$1 ]] && deactivate
  rm -rf "$VENVS/$1" && print "removed $1"
}
lsenv() { print -l $VENVS/*(N/:t) }
_venv_names() { compadd -- $VENVS/*(N/:t) }
compdef _venv_names workon rmenv

# ── Fish-like typing (keep these last) ──────────────────────────────────────
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=60
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'   # palette "outline" grey; → or End accepts
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
source /usr/share/zsh/plugins/zsh-history-substring-search/zsh-history-substring-search.zsh
HISTORY_SUBSTRING_SEARCH_HIGHLIGHT_FOUND='bg=5,fg=10,bold'
HISTORY_SUBSTRING_SEARCH_HIGHLIGHT_NOT_FOUND='fg=1,bold'
HISTORY_SUBSTRING_SEARCH_ENSURE_UNIQUE=1
bindkey '^[[A' history-substring-search-up;   bindkey '^[OA' history-substring-search-up     # ↑
bindkey '^[[B' history-substring-search-down; bindkey '^[OB' history-substring-search-down   # ↓
