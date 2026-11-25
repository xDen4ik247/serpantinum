function mkenv --description 'create a Python env in ~/.venvs (pip included) and switch to it: mkenv NAME [PYTHON]'
    set -l venvs (set -q VENVS; and echo $VENVS; or echo $HOME/.venvs)
    if test (count $argv) -lt 1
        echo "usage: mkenv NAME [PYTHON_VERSION]" >&2; return 1
    end
    if test -e $venvs/$argv[1]
        echo "env '$argv[1]' already exists — use: workon $argv[1]" >&2; return 1
    end
    set -l py
    set -q argv[2]; and set py --python $argv[2]
    uv venv --seed $py $venvs/$argv[1]; and workon $argv[1]
end
