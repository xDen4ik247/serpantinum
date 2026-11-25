# Python envs in ~/.venvs: mkenv NAME [PYTHON] · workon NAME · rmenv NAME · lsenv · `deactivate` to leave.
function lsenv --description 'list the Python envs in ~/.venvs'
    set -l venvs (set -q VENVS; and echo $VENVS; or echo $HOME/.venvs)
    set -l dirs $venvs/*/
    test (count $dirs) -gt 0; and path basename $dirs
    return 0
end
