# zsh interactive config LIBRARY - not stowed. bootstrap.sh writes a real
# ~/.zshrc that does `source "$DOTFILES/zsh/zshrc.zsh"`, so omnishell and the
# shell.d block can be appended to a real file without writing back into this
# repo (which a stow symlink would do).
#
# Layering (top to bottom = runs first to last):
#   1. this file        - env, keybindings, zsh-native completion styling
#   2. zshrc-<os>.zsh   - OS-specific bits
#   3. # >>> omnishell   - plugin inits, history, fzf, zoxide, ... (managed by omnishell apply)
#   4. # >>> dotfiles    - $DOTFILES/shell.d/*  (personal layer; added by bootstrap.sh)
#
# Adapted from hamvocke/dotfiles; anything omnishell now owns was removed here.

# Uncomment + run `zprof` in a new shell to profile startup time.
# zmodload zsh/zprof

export TERM=${TERM:-xterm-256color}

# nvim as the standard editor
if command -v nvim >/dev/null 2>&1; then
  export VISUAL=nvim
  alias vim='nvim'
else
  export VISUAL=vim
fi
export EDITOR="$VISUAL"

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# vim is great, but emacs keybindings on the command line are better.
# zsh auto-selects vi mode when $EDITOR looks like vi; ask for emacs explicitly.
bindkey -e
bindkey "^[[3~" delete-char   # <Delete> deletes forward instead of inserting ~

# Modified arrow keys: word-wise motion, and never leak the raw CSI tail
# (";3C", ";5D", ...) as literal text when a terminal sends an unbound sequence.
# Modifier codes: 3 = Alt/Option, 5 = Ctrl.
bindkey "^[[1;3C" forward-word      ; bindkey "^[[1;5C" forward-word
bindkey "^[[1;3D" backward-word     ; bindkey "^[[1;5D" backward-word
bindkey "^[[1;3H" beginning-of-line ; bindkey "^[[H" beginning-of-line
bindkey "^[[1;3F" end-of-line       ; bindkey "^[[F" end-of-line
bindkey "^[OH"   beginning-of-line  ; bindkey "^[[1~" beginning-of-line   # alt Home encodings
bindkey "^[OF"   end-of-line        ; bindkey "^[[4~" end-of-line         # alt End encodings
bindkey "^[[1;5H" beginning-of-line ; bindkey "^[[1;5F" end-of-line       # Ctrl+Home / Ctrl+End
bindkey "^H"      backward-kill-word                                      # Ctrl+Backspace (^H)
bindkey "^[[3;5~" kill-word         ; bindkey "^[[3;3~" kill-word         # Ctrl/Alt+Delete = kill word

#------------------------------------------------------
# Completion (zsh-native styling; omnishell's `completion` module runs compinit
# and sets the case-insensitive matcher)
#------------------------------------------------------
zmodload zsh/complist
# Include dotfiles in completion. compinit resets _comp_options and omnishell
# runs it after this file, so append once, right before the first prompt.
autoload -Uz add-zsh-hook
_dotfiles_comp_globdots() {
  _comp_options+=(globdots)
  add-zsh-hook -d precmd _dotfiles_comp_globdots
  unfunction _dotfiles_comp_globdots
}
add-zsh-hook precmd _dotfiles_comp_globdots
setopt MENU_COMPLETE                  # highlight first match immediately
setopt AUTO_LIST                       # list choices on ambiguous completion
zstyle ':completion:*' menu select
zstyle ':completion:*' complete-options true
zstyle ':completion:*' group-name ''
zstyle ':completion:*:*:*:*:descriptions' format '%F{green}-> %d%f'

# OS-specific configuration ($DOTFILES is exported by the generated ~/.zshrc)
: "${DOTFILES:=$HOME/.dotfiles}"
case "$(uname)" in
  Darwin) [ -f "$DOTFILES/zsh/zshrc-mac.zsh" ]   && source "$DOTFILES/zsh/zshrc-mac.zsh" ;;
  Linux)  [ -f "$DOTFILES/zsh/zshrc-linux.zsh" ] && source "$DOTFILES/zsh/zshrc-linux.zsh" ;;
esac
