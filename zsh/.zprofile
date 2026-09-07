# Login-shell PATH setup (kept minimal; shell.d/00-path.sh does the same for
# non-login interactive shells).

[ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH"
[ -d "$HOME/bin" ]        && PATH="$HOME/bin:$PATH"
export PATH
