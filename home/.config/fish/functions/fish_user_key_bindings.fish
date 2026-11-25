# Ctrl+Backspace / Ctrl+Delete stop at / . = - (like zsh with its trimmed WORDCHARS).
# Ctrl+←/→, Home/End, Shift+Tab and ↑/↓ history search are fish defaults.
function fish_user_key_bindings
    bind ctrl-backspace backward-kill-path-component
    bind ctrl-h backward-kill-path-component     # terminals that send ^H for Ctrl+Backspace
    bind ctrl-delete kill-path-component
end
