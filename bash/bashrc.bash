# bash interactive config LIBRARY - not stowed. bootstrap.sh writes a real
# ~/.bashrc that does `source "$DOTFILES/bash/bashrc.bash"`, so omnishell and the
# shell.d block can be appended to a real file without writing back into the repo.
#
# Layering (top to bottom = runs first to last):
#   1. this file        - shell options, completion, base prompt
#   2. bashrc-<os>.bash - OS-specific bits
#   3. # >>> omnishell   - plugin inits, history, fzf, zoxide, ... (managed by omnishell apply)
#   4. # >>> dotfiles    - $DOTFILES/shell.d/*  (personal layer; added by bootstrap.sh)

# If not running interactively, don't do anything
case $- in
  *i*) ;;
    *) return;;
esac

shopt -s histappend       # append, don't overwrite the history file
shopt -s checkwinsize     # keep LINES/COLUMNS current

# make less friendly for non-text input files
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# chroot identifier used by the fallback prompt
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
  debian_chroot=$(cat /etc/debian_chroot)
fi

# Minimal fallback prompt. starship (omnishell's starship module) overrides this
# when installed.
PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '

# color support for ls / grep
if [ -x /usr/bin/dircolors ]; then
  test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
  alias ls='ls --color=auto'
  alias grep='grep --color=auto'
fi

# nvim as editor
if command -v nvim >/dev/null 2>&1; then
  export VISUAL=nvim EDITOR=nvim
  alias vim='nvim'
fi

# programmable completion
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# OS-specific configuration ($DOTFILES is exported by the generated ~/.bashrc)
: "${DOTFILES:=$HOME/.dotfiles}"
case "$(uname)" in
  Darwin) [ -f "$DOTFILES/bash/bashrc-mac.bash" ]   && . "$DOTFILES/bash/bashrc-mac.bash" ;;
  Linux)  [ -f "$DOTFILES/bash/bashrc-linux.bash" ] && . "$DOTFILES/bash/bashrc-linux.bash" ;;
esac
