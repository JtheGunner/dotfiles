#!/usr/bin/env bash
# Bootstrap this dotfiles repo on a fresh machine.
#
#   git clone https://github.com/JtheGunner/dotfiles ~/.dotfiles
#   ~/.dotfiles/bootstrap.sh [--yes]
#
# Run it from whichever checkout you want to be live - it stows from there. If a
# previous run installed from a *different* checkout, it stops and asks before
# repointing every stow link at this one; --yes (or DOTFILES_ASSUME_YES=1) skips
# the prompt.
#
# What it does (idempotent - safe to re-run):
#   1. install dependencies + omnishell + ghostty
#   2. write real ~/.zshrc + ~/.bashrc that source this repo's rc libraries
#   3. stow the config-file packages into $HOME (repointing an older checkout)
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

# --yes / -y (or DOTFILES_ASSUME_YES=1): don't prompt - e.g. repoint stow links
# from an older checkout to this one without asking.
ASSUME_YES="${DOTFILES_ASSUME_YES:-${ASSUME_YES:-0}}"
if [ -z "${BOOTSTRAP_SOURCE_ONLY:-}" ]; then
  for _arg in "$@"; do
    case "$_arg" in
      -y | --yes) ASSUME_YES=1 ;;
      -h | --help)
        printf 'usage: %s [--yes]\n  --yes  assume "yes" for all prompts (repoint existing stow links to this checkout)\n' "$(basename "$0")"
        exit 0 ;;
      *) printf 'bootstrap.sh: unknown argument: %s\n' "$_arg" >&2; exit 2 ;;
    esac
  done
  unset _arg
fi

# use sudo only when not root and it's available (CI / containers run as root)
if [ "$(id -u)" -eq 0 ]; then SUDO=""
elif command -v sudo >/dev/null 2>&1; then SUDO="sudo"
else SUDO=""; fi

# the omnishell installer drops its binary here on non-brew systems (and
# omnishell's own module installs may too); make sure this script can see them
export PATH="$HOME/.local/bin:$PATH"

# stow packages = top-level dirs that ship standalone config FILES (not rc files).
# Ghostty is the terminal of choice; extra terminal packages via DOTFILES_TERMINALS.
PACKAGES=(zsh git tmux bat ghostty)
for t in ${DOTFILES_TERMINALS:-}; do
  case " ${PACKAGES[*]} " in *" $t "*) ;; *) [ -d "$DOTFILES/$t" ] && PACKAGES+=("$t") ;; esac
done
[ -d "$DOTFILES/nvim" ] && PACKAGES+=(nvim)

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }

# move a path aside without ever clobbering an existing backup
backup_aside() {
  local src="$1" dst="$1.pre-dotfiles"
  [ -e "$dst" ] && dst="$1.pre-dotfiles.$(date +%Y%m%dT%H%M%S)"
  warn "backing up $src -> $dst"
  mv "$src" "$dst"
}

# --------------------------------------------------------------------------
# 1. dependencies
# --------------------------------------------------------------------------
# starship, mise + tmux are installed by their omnishell modules
# ('omnishell apply'), not here.
DEPS=(stow git-delta fzf zoxide direnv ripgrep fd bat)

install_deps() {
  if command -v brew >/dev/null 2>&1; then
    log "installing deps via Homebrew"
    brew install "${DEPS[@]}" || warn "some brew packages failed"
  elif command -v apt-get >/dev/null 2>&1; then
    log "installing deps via apt"
    $SUDO apt-get update -qq || warn "apt-get update failed"
    # install one at a time so a single unavailable package doesn't sink the rest
    # (Debian names: fd -> fd-find, delta -> git-delta; bat/fd binaries are
    #  batcat/fdfind, which omnishell's modern-aliases module handles)
    for pkg in stow git-delta fzf zoxide direnv ripgrep fd-find bat curl ca-certificates; do
      $SUDO apt-get install -y -qq "$pkg" >/dev/null 2>&1 || warn "apt: $pkg not installed"
    done
    # starship, mise + tmux are handled by their omnishell modules: 'omnishell
    # apply' installs from apt/brew/pacman where available (starship/mise fall
    # back to a git + cargo build otherwise).
  else
    warn "no supported package manager found - install deps manually: ${DEPS[*]}"
  fi

  # stow is essential; everything else degrades gracefully
  command -v stow >/dev/null 2>&1 || {
    warn "GNU stow is not installed and could not be installed automatically."
    warn "Install it (e.g. 'apt-get install stow' / 'brew install stow') and re-run."
    exit 1
  }
}

# --------------------------------------------------------------------------
# 1b. omnishell + ghostty
# --------------------------------------------------------------------------
# Ubuntu/Debian have no official ghostty package; use the community .deb from
# github.com/mkasberg/ghostty-ubuntu (the standard route for Ubuntu).
_install_ghostty_deb() {
  command -v curl >/dev/null 2>&1 || return 1
  local ver arch url tmp rc
  ver="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}")"
  arch="$(dpkg --print-architecture 2>/dev/null)"
  [ -n "$ver" ] && [ -n "$arch" ] || return 1
  url="$(curl -fsSL https://api.github.com/repos/mkasberg/ghostty-ubuntu/releases/latest \
        | grep -oE "https://[^\"]*ghostty_[^\"]*_${arch}_${ver}\.deb" | head -1)"
  [ -n "$url" ] || { warn "no ghostty .deb for Ubuntu $ver/$arch"; return 1; }
  tmp="$(mktemp --suffix=.deb)"
  curl -fsSL -o "$tmp" "$url" || { rm -f "$tmp"; return 1; }
  $SUDO apt-get install -y -qq "$tmp"; rc=$?
  rm -f "$tmp"
  return $rc
}

install_ghostty() {
  command -v ghostty >/dev/null 2>&1 && { log "ghostty already installed"; return; }
  if [ "$OS" = "Darwin" ]; then
    if command -v brew >/dev/null 2>&1; then
      log "installing ghostty (brew cask)"
      brew install --cask ghostty || warn "ghostty cask install failed"
    else
      warn "install ghostty manually: https://ghostty.org/download"
    fi
  elif command -v apt-get >/dev/null 2>&1 && apt-cache show ghostty >/dev/null 2>&1; then
    log "installing ghostty (apt)"
    $SUDO apt-get install -y -qq ghostty || warn "ghostty apt install failed"
  elif command -v dpkg >/dev/null 2>&1; then
    log "installing ghostty (mkasberg/ghostty-ubuntu .deb)"
    _install_ghostty_deb || warn "ghostty install failed - get it at https://ghostty.org/download"
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
      backup_aside "$rc"
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

# The first symlinked path component at or above $HOME - i.e. the link stow
# actually created (a folded package dir, or the leaf link itself). Empty when
# $1 reaches $HOME without crossing a symlink.
_link_component() {
  local p="$1"
  while [ -n "$p" ] && [ "$p" != "$HOME" ] && [ "$p" != "/" ]; do
    [ -L "$p" ] && { printf '%s\n' "$p"; return 0; }
    p="$(dirname "$p")"
  done
  return 1
}

# yes/no on the controlling tty; auto-yes with --yes / DOTFILES_ASSUME_YES=1,
# auto-no when there is no tty to ask (non-interactive => the safe choice)
_confirm() {
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  local ans
  { printf '%s [y/N] ' "$1" > /dev/tty && read -r ans < /dev/tty; } 2>/dev/null || return 1
  case "$ans" in [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

stow_packages() {
  log "stowing: ${PACKAGES[*]}"
  local pkg rel target resolved suffix root link c self
  local -a foreign_links=() foreign_roots=() real_collisions=()

  # $DOTFILES with every symlink resolved - compare resolved paths to resolved
  # paths, never a resolved path to a raw one (that mismatch was the old bug).
  self="$(_realpath "$DOTFILES")"; [ -n "$self" ] || self="$DOTFILES"

  # Classify every path a package would occupy:
  #   - already a link into THIS checkout          -> nothing to do
  #   - a link into ANOTHER dotfiles checkout       -> a prior install elsewhere
  #   - a real file / unrelated symlink             -> genuine pre-existing config
  for pkg in "${PACKAGES[@]}"; do
    while IFS= read -r rel; do
      target="$HOME/$rel"
      [ -e "$target" ] || [ -L "$target" ] || continue
      resolved="$(_realpath "$target")"
      suffix="/$pkg/$rel"
      case "$resolved" in
        "$self/$pkg/$rel")
          continue ;;
        *"$suffix")
          root="${resolved%"$suffix"}"
          if [ "$root" != "$self" ] && [ -f "$root/bootstrap.sh" ]; then
            link="$(_link_component "$target")" || link="$target"
            foreign_links+=("$link")
            case " ${foreign_roots[*]:-} " in
              *" $root "*) ;;
              *) foreign_roots+=("$root") ;;
            esac
            continue
          fi ;;
      esac
      real_collisions+=("$target")
    done < <(cd "$DOTFILES/$pkg" && find . -type f | sed 's|^\./||')
  done

  # A previous install rooted at a different checkout: repoint it here, or stop.
  if [ "${#foreign_roots[@]}" -gt 0 ]; then
    warn "existing dotfiles install detected, linked from:"
    printf '         %s\n' "${foreign_roots[@]}" >&2
    warn "this run installs from: $DOTFILES"
    if _confirm " repoint every stow link to $DOTFILES (removes the old links)?"; then
      printf '%s\n' "${foreign_links[@]}" | sort -u | while IFS= read -r link; do
        [ -n "$link" ] || continue
        if [ -L "$link" ]; then
          warn "removing old link $link"
          rm "$link"
        else
          warn "expected a symlink at $link - leaving it for stow to report"
        fi
      done
    else
      warn "aborted. Re-run from that checkout, or pass --yes to repoint here."
      exit 1
    fi
  fi

  # Genuine pre-existing config in the way: move it aside so stow can take over.
  if [ "${#real_collisions[@]}" -gt 0 ]; then
    for c in "${real_collisions[@]}"; do
      [ -e "$c" ] || [ -L "$c" ] || continue   # a folded parent may already be gone
      backup_aside "$c"
    done
  fi

  ( cd "$DOTFILES" && stow --restow --target="$HOME" "${PACKAGES[@]}" )
}

# --------------------------------------------------------------------------
# 3b. git delta config - only when delta is actually installed
# --------------------------------------------------------------------------
setup_git_delta() {
  local local_cfg="$HOME/.gitconfig.local"
  if ! command -v delta >/dev/null 2>&1; then
    warn "delta not installed - skipping git delta config (git will use less)"
    [ -f "$local_cfg" ] && : > "$local_cfg"   # neutralise a stale one
    return 0
  fi
  log "writing $local_cfg (delta)"
  cat > "$local_cfg" <<'EOF'
# GENERATED by bootstrap.sh - included from ~/.config/git/config
[core]
	pager = delta
[interactive]
	diffFilter = delta --color-only
[delta]
	line-numbers = true
	navigate = true
	light = false
	syntax-theme = ansi
EOF
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
  # exit 1 = degraded module(s) (e.g. eza is not in Debian stable) - a state, not
  # a crash; keep going. exit >=2 = config/other error - abort.
  omnishell apply -y || {
    local rc=$?
    [ "$rc" -eq 1 ] || { warn "omnishell apply failed (exit $rc)"; exit "$rc"; }
    warn "omnishell reported degraded module(s); continuing - see 'omnishell doctor'"
  }
}

# --------------------------------------------------------------------------
# 5. append the shell.d block (after omnishell's block) to BOTH rc files,
#    for parity with omnishell (which hooks both zsh and bash).
#    Also sources ~/.<shell>rc.local last: the machine-specific escape hatch
#    (per-host PATH, tool completions, secrets) that must NOT be in the repo.
# --------------------------------------------------------------------------
wire_shell_d() {
  _insert() {
    local file="$1" localrc="$2"
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
[ -r "$localrc" ] && . "$localrc"   # machine-specific, not version-controlled
# <<< dotfiles <<<
EOF
  }
  _insert "$HOME/.zshrc"  "\$HOME/.zshrc.local"
  _insert "$HOME/.bashrc" "\$HOME/.bashrc.local"
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
  setup_git_delta
  apply_omnishell
  wire_shell_d
  log "rendering Root Loops colors"
  bash "$DOTFILES/rootloops/apply.sh"
  setup_terminal_app
  log "done. Open a new shell (exec \$SHELL) to pick everything up."
}

# BOOTSTRAP_SOURCE_ONLY=1 lets tests source the helpers without running anything.
[ -n "${BOOTSTRAP_SOURCE_ONLY:-}" ] || main "$@"
