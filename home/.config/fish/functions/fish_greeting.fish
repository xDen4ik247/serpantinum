# fastfetch once per kitty window: not for `fish -c …`, not in a shell started from inside another shell.
function fish_greeting
    if set -q KITTY_WINDOW_ID; and not set -q SERP_GREETED; and not set -q ZSH_GREETED
        set -gx SERP_GREETED 1
        command -q fastfetch; and fastfetch
    end
end
