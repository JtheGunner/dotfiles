#!/usr/bin/env bash
# Bootstrap this dotfiles repo on a fresh machine.
#
#   git clone https://github.com/JtheGunner/dotfiles ~/.dotfiles
#   ~/.dotfiles/bootstrap.sh [--yes]
#
# Run it from whichever checkout you want to be live - it installs from there.
# Before changing anything it checks every reference to a checkout (the DOTFILES=
# path in the ~/.zshrc / ~/.bashrc base blocks and every stow link). If any points
# at a *different* checkout, it lists them and asks once whether to switch
# everything to this one; --yes (or DOTFILES_ASSUME_YES=1) answers yes.
#
# What it does (idempotent - safe to re-run):
#   0. check that rc files + stow links all point at this checkout
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

# --yes / -y (or DOTFILES_ASSUME_YES=1): don't prompt - e.g. switch rc files and
# stow links from another checkout to this one without asking.
ASSUME_YES="${DOTFILES_ASSUME_YES:-${ASSUME_YES:-0}}"
if [ -z "${BOOTSTRAP_SOURCE_ONLY:-}" ]; then
  for _arg in "$@"; do
    case "$_arg" in
      -y | --yes) ASSUME_YES=1 ;;
      -h | --help)
        printf 'usage: %s [--yes]\n  --yes  assume "yes" for all prompts (switch rc files + stow links from another checkout to this one)\n' "$(basename "$0")"
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
# starship, mise, tmux, direnv + broot are installed by their omnishell modules
# ('omnishell apply'), not here.
DEPS=(stow git-delta fzf zoxide ripgrep fd bat)

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
    for pkg in stow git-delta fzf zoxide ripgrep fd-find bat curl ca-certificates; do
      $SUDO apt-get install -y -qq "$pkg" >/dev/null 2>&1 || warn "apt: $pkg not installed"
    done
    # starship, mise, tmux, direnv + broot are handled by their omnishell
    # modules: 'omnishell apply' installs from apt/brew/pacman where available
    # (and falls back to a git / cargo build otherwise).
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
# rc file (relative to $HOME) : the rc library its base block sources
RC_BASES=(".zshrc:zsh/zshrc.zsh" ".bashrc:bash/bashrc.bash")

# the dotfiles:base block that points an rc file at this checkout
_rc_base_block() {
  cat <<EOF
# >>> dotfiles:base >>>
export DOTFILES="$DOTFILES"
[ -r "\$DOTFILES/$1" ] && . "\$DOTFILES/$1"
# <<< dotfiles:base <<<
EOF
}

# the DOTFILES= path inside an rc file's base block; empty without a block
_rc_base_path() {
  [ -f "$1" ] || return 0
  awk '/^# >>> dotfiles:base >>>$/ { inside = 1; next }
       /^# <<< dotfiles:base <<<$/ { inside = 0; next }
       inside && /^export DOTFILES=/ {
         sub(/^export DOTFILES="?/, ""); sub(/"?[[:space:]]*$/, ""); print; exit
       }' "$1"
}

# Swap an existing base block for one pointing at this checkout. Only the lines
# between the markers change - the rest of the file is kept byte for byte (head
# and tail, not awk, so a missing final newline survives too).
_replace_rc_base() {
  local rc="$1" lib="$2" start end backup tmp
  start="$(grep -n -m1 '^# >>> dotfiles:base >>>$' "$rc" | cut -d: -f1)"
  end="$(awk -v s="$start" 'NR > s && /^# <<< dotfiles:base <<<$/ { print NR; exit }' "$rc")"
  if [ -z "$start" ] || [ -z "$end" ]; then
    warn "$rc: dotfiles:base block has no end marker - fix it by hand"
    exit 1
  fi
  backup="$rc.pre-dotfiles.$(date +%Y%m%dT%H%M%S)"
  warn "backing up $rc -> $backup"
  cp -p "$rc" "$backup"
  tmp="$(mktemp)"
  {
    if [ "$start" -gt 1 ]; then head -n "$((start - 1))" "$rc"; fi   # BSD head rejects -n 0
    _rc_base_block "$lib"
    tail -n "+$((end + 1))" "$rc"
  } > "$tmp"
  cat "$tmp" > "$rc"   # rewrite in place: keeps the inode and permissions
  rm -f "$tmp"
  log "pointed $(basename "$rc") at $DOTFILES"
}

write_rc_base() {
  local entry rc lib
  for entry in "${RC_BASES[@]}"; do
    rc="$HOME/${entry%%:*}" lib="${entry#*:}"
    if [ -f "$rc" ] && grep -q '^# >>> dotfiles:base >>>$' "$rc"; then
      log "$(basename "$rc") base block already present"
      continue
    fi
    if [ -e "$rc" ] && [ ! -L "$rc" ]; then
      backup_aside "$rc"
    elif [ -L "$rc" ]; then
      rm -f "$rc"   # drop a stale symlink from an earlier layout
    fi
    log "writing $rc"
    _rc_base_block "$lib" > "$rc"
  done
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

# collapse . and .. in an absolute path without touching the filesystem
_normalize_path() {
  local part out=""
  local -a parts=() kept=()
  IFS=/ read -r -a parts <<< "$1"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      '' | .) ;;
      ..) if [ "${#kept[@]}" -gt 0 ]; then unset "kept[$((${#kept[@]} - 1))]"; fi ;;
      *) kept+=("$part") ;;
    esac
  done
  for part in ${kept[@]+"${kept[@]}"}; do out="$out/$part"; done
  printf '%s\n' "${out:-/}"
}

# where a symlink points, as an absolute path - even when the target is gone
_link_target() {
  local link="$1" to dir
  to="$(readlink "$link")" || return 1
  case "$to" in
    /*) ;;
    *) dir="$(cd "$(dirname "$link")" && pwd -P)" || return 1; to="$dir/$to" ;;
  esac
  _normalize_path "$to"
}

# yes/no on the controlling tty (DOTFILES_TTY overrides it, for tests); auto-yes
# with --yes / DOTFILES_ASSUME_YES=1, auto-no when there is no tty to ask
# (non-interactive => the safe choice)
_confirm() {
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  local ans tty="${DOTFILES_TTY:-/dev/tty}"
  { printf '%s [y/N] ' "$1" >> "$tty" && read -r ans < "$tty"; } 2>/dev/null || return 1
  case "$ans" in [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# Classify every path a stow package would occupy:
#   - already a link into THIS checkout             -> nothing to do
#   - a link into ANOTHER checkout (even a deleted one) -> FOREIGN_LINKS / _ROOTS
#   - a real file / unrelated symlink               -> REAL_COLLISIONS
# FOREIGN_LINKS[i] is the link stow created (a folded dir or the leaf itself),
# FOREIGN_ROOTS[i] the checkout it points into.
scan_stow_links() {
  local pkg rel target resolved suffix root link self i known
  FOREIGN_LINKS=() FOREIGN_ROOTS=() REAL_COLLISIONS=()

  # $DOTFILES with every symlink resolved - compare resolved paths to resolved
  # paths, never a resolved path to a raw one.
  self="$(_realpath "$DOTFILES")" || self=""; [ -n "$self" ] || self="$DOTFILES"

  for pkg in "${PACKAGES[@]}"; do
    while IFS= read -r rel; do
      target="$HOME/$rel"
      root=""
      if [ -e "$target" ]; then
        resolved="$(_realpath "$target")" || resolved=""
        suffix="/$pkg/$rel"
        [ "$resolved" = "$self$suffix" ] && continue
        case "$resolved" in
          *"$suffix")
            root="${resolved%"$suffix"}"
            [ "$root" != "$self" ] && [ -f "$root/bootstrap.sh" ] || root="" ;;
        esac
        link="$(_link_component "$target")" || link="$target"
      else
        # nothing there, or a dangling link: a link into a checkout that is gone
        link="$(_link_component "$target")" || continue
        [ ! -e "$link" ] || continue
        resolved="$(_link_target "$link")" || resolved=""
        suffix="/$pkg/${link#"$HOME/"}"
        case "$resolved" in
          *"$suffix") root="${resolved%"$suffix"}"; [ ! -e "$root" ] || root="" ;;
        esac
        [ -n "$root" ] || [ "$link" = "$target" ] || continue
      fi

      if [ -z "$root" ]; then
        REAL_COLLISIONS+=("$target")
        continue
      fi
      known=0
      for ((i = 0; i < ${#FOREIGN_LINKS[@]}; i++)); do
        [ "${FOREIGN_LINKS[$i]}" = "$link" ] && { known=1; break; }
      done
      [ "$known" = 1 ] || { FOREIGN_LINKS+=("$link"); FOREIGN_ROOTS+=("$root"); }
    done < <(cd "$DOTFILES/$pkg" && find . -type f | sed 's|^\./||')
  done
}

# ~/-relative form of a path under $HOME, for messages
_tilde() { case "$1" in "$HOME"/*) printf '%s%s\n' '~' "${1#"$HOME"}" ;; *) printf '%s\n' "$1" ;; esac; }
_missing_mark() { [ -e "$1" ] || printf ' (missing)'; }

# Every run checks ALL references to a checkout - the DOTFILES= path in both rc
# base blocks and every stow link - before anything is written. If any of them
# points at another checkout, list them and ask once whether to switch
# everything to this one; "no" (or no tty) exits without changing anything.
check_checkout_consistency() {
  local self entry rc lib path resolved i
  local -a refs=() stale_rcs=()

  self="$(_realpath "$DOTFILES")" || self=""; [ -n "$self" ] || self="$DOTFILES"

  for entry in "${RC_BASES[@]}"; do
    rc="$HOME/${entry%%:*}"
    path="$(_rc_base_path "$rc")"
    [ -n "$path" ] || continue
    resolved="$(_realpath "$path")" || resolved=""
    [ "$resolved" = "$self" ] && continue
    stale_rcs+=("$entry")
    refs+=("$(_tilde "$rc") (dotfiles:base)  ->  $path$(_missing_mark "$path")")
  done

  scan_stow_links
  for ((i = 0; i < ${#FOREIGN_LINKS[@]}; i++)); do
    refs+=("$(_tilde "${FOREIGN_LINKS[$i]}")  ->  ${FOREIGN_ROOTS[$i]}$(_missing_mark "${FOREIGN_ROOTS[$i]}")")
  done

  [ "${#refs[@]}" -gt 0 ] || return 0

  warn "references to another dotfiles checkout:"
  printf '         %s\n' "${refs[@]}" >&2
  warn "this run installs from: $DOTFILES"
  if ! _confirm " switch everything to $DOTFILES?"; then
    warn "aborted, nothing changed. Re-run from that checkout, or pass --yes to switch to this one."
    exit 1
  fi

  for entry in ${stale_rcs[@]+"${stale_rcs[@]}"}; do
    rc="$HOME/${entry%%:*}" lib="${entry#*:}"
    _replace_rc_base "$rc" "$lib"
  done
  for ((i = 0; i < ${#FOREIGN_LINKS[@]}; i++)); do
    warn "removing old link ${FOREIGN_LINKS[$i]} (stow re-links it)"
    rm "${FOREIGN_LINKS[$i]}"
  done
}

stow_packages() {
  log "stowing: ${PACKAGES[*]}"
  local c
  scan_stow_links

  # check_checkout_consistency already removed these (or stopped the run)
  if [ "${#FOREIGN_LINKS[@]}" -gt 0 ]; then
    warn "stow links into another checkout remain: ${FOREIGN_LINKS[*]}"
    exit 1
  fi

  # Genuine pre-existing config in the way: move it aside so stow can take over.
  for c in ${REAL_COLLISIONS[@]+"${REAL_COLLISIONS[@]}"}; do
    [ -e "$c" ] || [ -L "$c" ] || continue   # a folded parent may already be gone
    backup_aside "$c"
  done

  ( cd "$DOTFILES" && stow --restow --target="$HOME" "${PACKAGES[@]}" )
}

# --------------------------------------------------------------------------
# 3b. git delta config - only when delta is actually installed
# --------------------------------------------------------------------------
GIT_DELTA_HEADER="# GENERATED by bootstrap.sh - included from ~/.config/git/config"

setup_git_delta() {
  local delta_cfg="$HOME/.gitconfig.delta" local_cfg="$HOME/.gitconfig.local"
  # Older runs wrote the delta block to ~/.gitconfig.local, which is now the
  # user's own file. Drop that generated copy so it can't shadow anything.
  if [ -f "$local_cfg" ] && [ "$(head -n1 "$local_cfg")" = "$GIT_DELTA_HEADER" ]; then
    log "removing the old generated $local_cfg (delta moved to $delta_cfg)"
    rm -f "$local_cfg"
  fi
  if ! command -v delta >/dev/null 2>&1; then
    warn "delta not installed - skipping git delta config (git will use less)"
    rm -f "$delta_cfg"   # drop a stale one
    return 0
  fi
  log "writing $delta_cfg"
  cat > "$delta_cfg" <<EOF
$GIT_DELTA_HEADER
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
# 3c. git identity - never shipped by this repo (user.useConfigOnly = true),
#     so offer to write it to the untracked ~/.gitconfig.local.
# --------------------------------------------------------------------------
setup_git_identity() {
  local local_cfg="$HOME/.gitconfig.local" name email
  # An empty ~/.gitconfig makes `git config --global` write there instead of
  # into ~/.config/git/config - the stowed file, i.e. back into this repo.
  [ -e "$HOME/.gitconfig" ] || : > "$HOME/.gitconfig"

  if git config --get user.email >/dev/null 2>&1; then
    log "git identity already set ($(git config --get user.email))"
    return 0
  fi
  if [ "${ASSUME_YES:-0}" = "1" ] || ! { : > /dev/tty; } 2>/dev/null; then
    warn "no git identity - set one before committing:"
    warn "  git config --file ~/.gitconfig.local user.name  'Your Name'"
    warn "  git config --file ~/.gitconfig.local user.email 'you@example.com'"
    return 0
  fi
  printf 'git user.name (empty = skip): ' > /dev/tty
  read -r name < /dev/tty || name=""
  [ -n "$name" ] || { warn "skipped git identity - git will refuse to commit until it is set"; return 0; }
  printf 'git user.email (tip: your GitHub noreply address): ' > /dev/tty
  read -r email < /dev/tty || email=""
  [ -n "$email" ] || { warn "skipped git identity - git will refuse to commit until it is set"; return 0; }
  git config --file "$local_cfg" user.name "$name"
  git config --file "$local_cfg" user.email "$email"
  log "wrote git identity to $local_cfg"
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
  check_checkout_consistency
  install_deps
  install_ghostty
  install_omnishell
  write_rc_base
  stow_packages
  setup_git_delta
  setup_git_identity
  apply_omnishell
  wire_shell_d
  log "rendering Root Loops colors"
  bash "$DOTFILES/rootloops/apply.sh"
  setup_terminal_app
  log "done. Open a new shell (exec \$SHELL) to pick everything up."
}

# BOOTSTRAP_SOURCE_ONLY=1 lets tests source the helpers without running anything.
[ -n "${BOOTSTRAP_SOURCE_ONLY:-}" ] || main "$@"
