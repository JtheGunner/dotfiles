# Activation hooks for tools that are PLANNED as omnishell modules but not yet
# released: direnv (OMNIS-2), mise (OMNIS-4), starship, yazi/file-navigator
# (OMNIS-10). Once each module lands upstream, remove its block here and enable
# the module in ../omnishell/config.toml instead.

_os_shell="bash"
[ -n "$ZSH_VERSION" ] && _os_shell="zsh"

# Prompt
command -v starship >/dev/null 2>&1 && eval "$(starship init "$_os_shell")"

# Per-directory environment
command -v direnv >/dev/null 2>&1 && eval "$(direnv hook "$_os_shell")"

# Runtime version manager
command -v mise >/dev/null 2>&1 && eval "$(mise activate "$_os_shell")"

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
