# Activation hooks for tools that are PLANNED as omnishell modules but not yet
# adopted here: direnv (OMNIS-2), yazi/file-navigator (OMNIS-10). Once each
# module lands, remove its block here and enable it in ../omnishell/config.toml.
# (starship, mise and the Root Loops palette push already moved - see config.toml.)

_os_shell="bash"
[ -n "$ZSH_VERSION" ] && _os_shell="zsh"

# Per-directory environment
command -v direnv >/dev/null 2>&1 && eval "$(direnv hook "$_os_shell")"

# yazi file manager: `y` changes the shell's cwd on quit
if command -v yazi >/dev/null 2>&1; then
  y() {
    tmp="$(mktemp -t yazi-cwd.XXXXXX)"
    yazi "$@" --cwd-file="$tmp"
    if cwd="$(cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
      cd -- "$cwd" || return
    fi
    rm -f -- "$tmp"
  }
fi

unset _os_shell
