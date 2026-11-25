# Ctrl+Backspace / Ctrl+Delete delete one word and stop at / . = - (like zsh with its trimmed WORDCHARS).
# (backward-kill-path-component would only stop at / and spaces, so `foo/bar-baz` lost all of `bar-baz`.)
# Ctrl+←/→, Home/End, Shift+Tab and ↑/↓ history search are fish defaults.
function fish_user_key_bindings
    bind ctrl-backspace backward-kill-word
    bind ctrl-h backward-kill-word     # terminals that send ^H for Ctrl+Backspace
    bind ctrl-delete kill-word
end
