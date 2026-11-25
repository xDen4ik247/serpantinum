function workon --description 'switch to a Python env from ~/.venvs (no NAME: list them)'
    set -l venvs (set -q VENVS; and echo $VENVS; or echo $HOME/.venvs)
    if test (count $argv) -lt 1
        lsenv; return
    end
    if not test -f $venvs/$argv[1]/bin/activate.fish
        echo "no env '$argv[1]' — see: lsenv" >&2; return 1
    end
    source $venvs/$argv[1]/bin/activate.fish
end
