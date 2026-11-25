function rmenv --description 'delete a Python env from ~/.venvs (the default env stays)'
    set -l venvs (set -q VENVS; and echo $VENVS; or echo $HOME/.venvs)
    if test (count $argv) -lt 1; or test "$argv[1]" = default
        echo "usage: rmenv NAME (the default env stays)" >&2; return 1
    end
    if not test -d $venvs/$argv[1]
        echo "no env '$argv[1]'" >&2; return 1
    end
    if test "$VIRTUAL_ENV" = $venvs/$argv[1]; and functions -q deactivate
        deactivate
    end
    rm -rf $venvs/$argv[1]; and echo "removed $argv[1]"
end
