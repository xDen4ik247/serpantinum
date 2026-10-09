# Read by every zsh (interactive or not). Keep it tiny.
typeset -U path PATH   # no duplicate PATH entries
# ~/.venvs/default is always on PATH, so `python`, `pip install x` and
# `jupyter lab` just work, with no "(base)" in the prompt.
path=("$HOME/.local/bin" "$HOME/.venvs/default/bin" $path)
export EDITOR=nvim VISUAL=nvim
