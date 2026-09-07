#!/usr/bin/env bash
# Bootstrap this dotfiles repo on a fresh machine.
#
#   git clone https://github.com/JtheGunner/dotfiles ~/.dotfiles
#   ~/.dotfiles/bootstrap.sh
#
# What it does (idempotent - safe to re-run):
#   1. install dependencies + omnishell + ghostty
#   2. write real ~/.zshrc + ~/.bashrc that source this repo's rc libraries
#   3. stow the config-file packages into $HOME
#   4. apply the version-controlled omnishell config (appends its marker block)
#   5. append the shell.d block to both rc files
#   6. render Root Loops colors + import the macOS Terminal.app profile
#
# ~/.zshrc and ~/.bashrc are GENERATED real files, not stow symlinks: omnishell
# and step 5 append to them, and a symlink would write those edits back into the
# repo. The pristine rc content lives in zsh/zshrc.zsh + bash/bashrc.bash.
#
# It never runs `chsh`: whatever your current login shell is (bash or zsh) is
# what gets configured.
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"

# stow packages = top-level dirs that ship standalone config FILES (not rc files).
# Ghostty is the terminal of choice; extra terminal packages via DOTFILES_TERMINALS.
PACKAGES=(zsh git tmux bat starship mise ghostty)
for t in ${DOTFILES_TERMINALS:-}; do
  case " ${PACKAGES[*]} " in *" $t "*) ;; *) [ -d "$DOTFILES/$t" ] && PACKAGES+=("$t") ;; esac
done
[ -d "$DOTFILES/nvim" ] && PACKAGES+=(nvim)

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }

# --------------------------------------------------------------------------
# 1. dependencies
# --------------------------------------------------------------------------
DEPS=(stow git-delta starship fzf zoxide mise direnv ripgrep fd bat tmux)

install_deps() {
  if command -v brew >/dev/null 2>&1; then
    log "installing deps via Homebrew"
    brew install "${DEPS[@]}" || warn "some brew packages failed"
  elif command -v apt-get >/dev/null 2>&1; then
    log "installing deps via apt"
    # Debian package names differ from brew's in a couple of cases
    sudo apt-get update -qq
    sudo apt-get install -y \
      stow git-delta fzf zoxide direnv ripgrep fd-find bat tmux curl || warn "some apt packages failed"
    # starship + mise are not in Debian stable; use their installers
    command -v starship >/dev/null 2>&1 || curl -sS https://starship.rs/install.sh | sh -s -- -y
    command -v mise >/dev/null 2>&1 || curl -fsSL https://mise.run | sh
  else
    warn "no supported package manager found - install deps manually: ${DEPS[*]}"
  fi
}

# --------------------------------------------------------------------------
# 2. omnishell
# --------------------------------------------------------------------------
install_ghostty() {
  command -v ghostty >/dev/null 2>&1 && { log "ghostty already installed"; return; }
  if [ "$OS" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
    log "installing ghostty (brew cask)"
    brew install --cask ghostty || warn "ghostty cask install failed"
  elif command -v apt-get >/dev/null 2>&1 && apt-cache show ghostty >/dev/null 2>&1; then
    log "installing ghostty (apt)"
    sudo apt-get install -y ghostty || warn "ghostty apt install failed"
  else
    warn "install ghostty manually: https://ghostty.org/download (config is already stowed)"
  fi
}

install_omnishell() {
  if command -v omnishell >/dev/null 2>&1; then
    log "omnishell already installed ($(omnishell version 2>/dev/null || echo '?'))"
    return
  fi
  if command -v brew >/dev/null 2>&1; then
    log "installing omnishell via Homebrew tap"
    brew install jthegunner/tap/omnishell
  else
    log "installing omnishell via curl installer"
    curl -fsSL https://raw.githubusercontent.com/JtheGunner/omnishell/main/install.sh | sh
  fi
}

# --------------------------------------------------------------------------
# 2. real rc files that source this repo's rc libraries
# --------------------------------------------------------------------------
write_rc_base() {
  _base() {
    local rc="$1" lib="$2"
    if [ -f "$rc" ] && grep -q '# >>> dotfiles:base >>>' "$rc"; then
      log "$(basename "$rc") base block already present"
      return 0
    fi
    if [ -e "$rc" ] && [ ! -L "$rc" ]; then
      warn "backing up $rc -> $rc.pre-dotfiles"
      mv "$rc" "$rc.pre-dotfiles"
    elif [ -L "$rc" ]; then
      rm -f "$rc"   # drop a stale symlink from an earlier layout
    fi
    log "writing $rc"
    cat > "$rc" <<EOF
# >>> dotfiles:base >>>
export DOTFILES="$DOTFILES"
[ -r "\$DOTFILES/$lib" ] && . "\$DOTFILES/$lib"
# <<< dotfiles:base <<<
EOF
  }
  _base "$HOME/.zshrc"  "zsh/zshrc.zsh"
  _base "$HOME/.bashrc" "bash/bashrc.bash"
}

# --------------------------------------------------------------------------
# 3. stow
# --------------------------------------------------------------------------
# fully resolve a path (follows symlinks and folded stow dirs)
_realpath() {
  if command -v realpath >/dev/null 2>&1; then realpath "$1" 2>/dev/null
  elif readlink -f / >/dev/null 2>&1; then readlink -f "$1" 2>/dev/null
  else ( cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")" ); fi
}

stow_packages() {
  log "stowing: ${PACKAGES[*]}"
  # Move aside any real file that would collide with a stow symlink. Skip
  # anything that already resolves into $DOTFILES - on a re-run the target is
  # either the stow symlink itself or a child of a folded stow dir.
  local pkg rel target
  for pkg in "${PACKAGES[@]}"; do
    while IFS= read -r rel; do
      target="$HOME/$rel"
      [ -e "$target" ] || continue
      case "$(_realpath "$target")" in "$DOTFILES"/*) continue ;; esac
      warn "backing up $target -> $target.pre-dotfiles"
      mv "$target" "$target.pre-dotfiles"
    done < <(cd "$DOTFILES/$pkg" && find . -type f | sed 's|^\./||')
  done
  ( cd "$DOTFILES" && stow --restow --target="$HOME" "${PACKAGES[@]}" )
}

# --------------------------------------------------------------------------
# 4. omnishell config
# --------------------------------------------------------------------------
apply_omnishell() {
  local cfgdir="${XDG_CONFIG_HOME:-$HOME/.config}/omnishell"
  mkdir -p "$cfgdir"
  cp "$DOTFILES/omnishell/config.toml" "$cfgdir/config.toml"
  log "omnishell init + apply"
  omnishell init -y 2>/dev/null || omnishell init || true
  cp "$DOTFILES/omnishell/config.toml" "$cfgdir/config.toml"   # init may template a fresh one
  omnishell apply -y
}

# --------------------------------------------------------------------------
# 5. append the shell.d block (after omnishell's block) to BOTH rc files,
#    for parity with omnishell (which hooks both zsh and bash)
# --------------------------------------------------------------------------
wire_shell_d() {
  _insert() {
    local file="$1"
    [ -f "$file" ] || return 0
    if grep -q '# >>> dotfiles >>>' "$file"; then
      log "shell.d block already present in $(basename "$file")"
      return 0
    fi
    log "adding shell.d block to $file"
    cat >> "$file" <<EOF

# >>> dotfiles >>>
for _f in "\$DOTFILES"/shell.d/*.sh; do
  [ -r "\$_f" ] && . "\$_f"
done
unset _f
# <<< dotfiles <<<
EOF
  }
  _insert "$HOME/.zshrc"
  _insert "$HOME/.bashrc"
}

# --------------------------------------------------------------------------
# --------------------------------------------------------------------------
# 6. macOS Terminal.app - it ignores OSC palette escapes, so import a profile
# --------------------------------------------------------------------------
setup_terminal_app() {
  [ "$OS" = "Darwin" ] || return 0
  local prof="$DOTFILES/rootloops/RootLoops.terminal"
  [ -f "$prof" ] || return 0
  log "importing Terminal.app profile 'Root Loops'"
  open "$prof" || warn "could not import $prof - open it manually"
  # give Terminal a moment to register the profile, then make it the default
  sleep 1
  defaults write com.apple.Terminal "Default Window Settings" "Root Loops" 2>/dev/null || true
  defaults write com.apple.Terminal "Startup Window Settings" "Root Loops" 2>/dev/null || true
  warn "restart Terminal.app for the 'Root Loops' profile to take effect"
}

main() {
  install_deps
  install_ghostty
  install_omnishell
  write_rc_base
  stow_packages
  apply_omnishell
  wire_shell_d
  log "rendering Root Loops colors"
  bash "$DOTFILES/rootloops/apply.sh"
  setup_terminal_app
  log "done. Open a new shell (exec \$SHELL) to pick everything up."
}

main "$@"
