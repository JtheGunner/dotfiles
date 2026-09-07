#!/usr/bin/env bash
# Bootstrap this dotfiles repo on a fresh machine.
#
#   git clone https://github.com/JtheGunner/dotfiles ~/.dotfiles
#   ~/.dotfiles/bootstrap.sh
#
# What it does (idempotent - safe to re-run):
#   1. install dependencies via the system package manager
#   2. install omnishell (Homebrew tap, or the curl installer)
#   3. stow every package in this repo into $HOME
#   4. apply the version-controlled omnishell config
#   5. wire ~/.dotfiles/shell.d/* into the detected login shell's rc file
#   6. render Root Loops colors
#
# It never runs `chsh`: whatever your current login shell is (bash or zsh) is
# what gets configured.
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"

# stow packages = every top-level dir that ships real config files.
# Ghostty is the terminal emulator of choice; extra terminal packages can be
# added via DOTFILES_TERMINALS (space-separated).
PACKAGES=(zsh bash git tmux bat starship mise ghostty)
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
# 3. stow
# --------------------------------------------------------------------------
stow_packages() {
  log "stowing: ${PACKAGES[*]}"
  # back up any real file that would collide with a symlink
  for pkg in "${PACKAGES[@]}"; do
    while IFS= read -r rel; do
      target="$HOME/$rel"
      if [ -e "$target" ] && [ ! -L "$target" ]; then
        warn "backing up $target -> $target.pre-dotfiles"
        mv "$target" "$target.pre-dotfiles"
      fi
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
# 5. wire shell.d into the login shell's rc file (after omnishell's block)
# --------------------------------------------------------------------------
wire_shell_d() {
  local login_shell rc
  login_shell="$(basename "${SHELL:-/bin/bash}")"
  case "$login_shell" in
    zsh)  rc="$HOME/.zshrc" ;;
    bash) rc="$HOME/.bashrc" ;;
    *)    warn "unrecognized login shell '$login_shell'; wiring both rc files"; rc="" ;;
  esac

  _insert() {
    local file="$1"
    [ -f "$file" ] || return 0
    if grep -q '# >>> dotfiles >>>' "$file"; then
      log "shell.d block already present in $file"
      return 0
    fi
    log "adding shell.d block to $file"
    cat >> "$file" <<EOF

# >>> dotfiles >>>
for _f in "$DOTFILES"/shell.d/*.sh; do
  [ -r "\$_f" ] && . "\$_f"
done
unset _f
# <<< dotfiles <<<
EOF
  }

  if [ -n "$rc" ]; then
    _insert "$rc"
  else
    _insert "$HOME/.zshrc"
    _insert "$HOME/.bashrc"
  fi
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
  stow_packages
  apply_omnishell
  wire_shell_d
  log "rendering Root Loops colors"
  bash "$DOTFILES/rootloops/apply.sh"
  setup_terminal_app
  log "done. Open a new shell (exec \$SHELL) to pick everything up."
}

main "$@"
