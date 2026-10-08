#!/usr/bin/env bash
# Bootstrap this dotfiles repo on a fresh machine.
#
#   git clone https://github.com/JtheGunner/dotfiles ~/.dotfiles
#   ~/.dotfiles/bootstrap.sh [--yes] [--install-zsh | --no-install-zsh]
#
# Run it from whichever checkout you want to be live - it installs from there.
# Before changing anything it checks every reference to a checkout (the DOTFILES=
# path in the ~/.zshrc / ~/.bashrc base blocks and every stow link). If any points
# at a *different* checkout, it lists them and asks once whether to switch
# everything to this one; --yes (or DOTFILES_ASSUME_YES=1) answers yes.
#
# What it does (idempotent - safe to re-run):
#   0. check that rc files + stow links all point at this checkout
#   1. install dependencies + omnishell (>= 0.6.0, upgraded if older) + ghostty;
#      on apt systems with a CPU omnishell has no release binaries for (not
#      x86_64 / arm64) also a Rust toolchain for its git + cargo fallbacks
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
# zsh is installed only on an explicit "yes" (--install-zsh, DOTFILES_INSTALL_ZSH=yes
# or install_zsh = "yes" in ~/.config/dotfiles/config.toml) - never by --yes alone.
#
# It never runs `chsh`: whatever your current login shell is (bash or zsh) is
# what gets configured.
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }

# Command line: --yes / -y and --install-zsh / --no-install-zsh beat the environment
# and the settings file. Parsed before anything is migrated or written, so --help
# and a mistyped flag change nothing.
INSTALL_ZSH_FLAG=""
ASSUME_YES_FLAG=""
INTERACTIVE_FLAG=""
parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -y | --yes) ASSUME_YES_FLAG=1 ;;
      --interactive) INTERACTIVE_FLAG=1 ;;
      --install-zsh) INSTALL_ZSH_FLAG=yes ;;
      --no-install-zsh) INSTALL_ZSH_FLAG=no ;;
      -h | --help)
        cat <<USAGE
usage: $(basename "$0") [--interactive] [--yes] [--install-zsh | --no-install-zsh]
  --yes             assume "yes" for all prompts (switch rc files + stow links from another checkout to this one);
                    does NOT install zsh
  --install-zsh     install zsh if it is missing, without asking
  --no-install-zsh  never install zsh
  --interactive     ask for the settings and pick the omnishell modules in its TUI; writes them to the
                    settings file after showing a diff (needs a terminal, cannot be combined with --yes)
USAGE
        exit 0 ;;
      *) printf 'bootstrap.sh: unknown argument: %s\n' "$arg" >&2; exit 2 ;;
    esac
  done
  if [ -n "$INTERACTIVE_FLAG" ] && [ -n "$ASSUME_YES_FLAG" ]; then
    printf 'bootstrap.sh: --interactive and --yes contradict each other\n' >&2
    exit 2
  fi
}
[ -n "${BOOTSTRAP_SOURCE_ONLY:-}" ] || parse_args "$@"

# Settings file (untracked, per machine, seeded from config.toml.example): a
# restricted TOML subset parsed by lib/settings.sh, never sourced. Precedence
# everywhere: flag > environment > settings file > default.
# shellcheck source=lib/settings.sh
. "$DOTFILES/lib/settings.sh"
BOOTSTRAP_CONFIG="${DOTFILES_CONFIG:-$HOME/.config/dotfiles/config.toml}"
settings_migrate_legacy "$(dirname "$BOOTSTRAP_CONFIG")/bootstrap.conf" "$BOOTSTRAP_CONFIG"
settings_load "$BOOTSTRAP_CONFIG"
read_conf_values() {
  CONF_INSTALL_ZSH="$(settings_get bootstrap.install_zsh)"
  CONF_ASSUME_YES="$(settings_get bootstrap.assume_yes)"
  CONF_TERMINALS="$(settings_get bootstrap.terminals)"
  CONF_GHOSTTY_KEYBINDS="$(settings_get ghostty.keybinds)"
}
read_conf_values

# ASSUME_YES: --yes, then DOTFILES_ASSUME_YES / ASSUME_YES=1, then assume_yes = true
# in the settings file. Don't prompt - e.g. switch rc files and stow links from
# another checkout to this one without asking.
ASSUME_YES_ENV="${DOTFILES_ASSUME_YES:-${ASSUME_YES:-}}"
resolve_assume_yes() {
  if [ -n "$ASSUME_YES_FLAG" ]; then ASSUME_YES=1
  elif [ -n "$ASSUME_YES_ENV" ]; then ASSUME_YES="$ASSUME_YES_ENV"
  elif [ "$CONF_ASSUME_YES" = true ]; then ASSUME_YES=1
  else ASSUME_YES=0; fi
}
resolve_assume_yes

# use sudo only when not root and it's available (CI / containers run as root)
if [ "$(id -u)" -eq 0 ]; then SUDO=""
elif command -v sudo >/dev/null 2>&1; then SUDO="sudo"
else SUDO=""; fi

# the omnishell installer drops its binary here on non-brew systems (and
# omnishell's own module installs may too); make sure this script can see them
export PATH="$HOME/.local/bin:$PATH"

# stow packages = top-level dirs that ship standalone config FILES (not rc files).
# Ghostty is the terminal of choice; extra terminal packages via DOTFILES_TERMINALS
# or `terminals` in the [bootstrap] table of the settings file. Names are plain
# package directory names; globbing is off while the list is split.
build_packages() {
  local t
  PACKAGES=(zsh git tmux bat ghostty)
  set -f
  for t in ${DOTFILES_TERMINALS:-$CONF_TERMINALS}; do
    case "$t" in
      *[!A-Za-z0-9_.-]*) warn "ignoring terminal '$t': not a valid package name"; continue ;;
    esac
    case " ${PACKAGES[*]} " in *" $t "*) ;; *) [ -d "$DOTFILES/$t" ] && PACKAGES+=("$t") ;; esac
  done
  set +f
  [ -d "$DOTFILES/nvim" ] && PACKAGES+=(nvim)
  return 0
}
build_packages

# read the settings file again after --interactive changed it
reload_settings() {
  settings_load "$BOOTSTRAP_CONFIG"
  read_conf_values
  resolve_assume_yes
  build_packages
}

# omnishell 0.3.0 introduced the modules omnishell/config.toml enables (starship,
# root-loops, tmux, broot, direnv, mise, colorized-man); 0.5.0 installs mise,
# starship and broot from an upstream release binary on Linux x86_64 / arm64
# instead of a cargo build; 0.6.0 is the first release that installs on 32-bit
# ARM, with release binaries for starship and mise (armv7) there; 0.7.0 adds
# `omnishell tui`, which --interactive hands the module selection to. What has no
# binary (broot on 32-bit ARM, mise on armv6, everything on other CPUs) still
# builds from source, which needs Rust 1.95 for mise / starship (broot: 1.85) -
# newer than what Debian / Ubuntu LTS ship as `cargo`.
OMNISHELL_MIN_VERSION="0.7.0"
RUST_MIN_VERSION="1.95"

# What a cargo build of mise needs besides Rust: a C toolchain, cmake (libz-ng-sys),
# pkg-config + OpenSSL headers (openssl-sys). Only installed where omnishell has
# to build from source (see needs_source_builds).
APT_BUILD_DEPS=(build-essential cmake pkg-config libssl-dev)

# output of the last `omnishell apply`, for the degraded-module summary at the end
APPLY_REPORT=""


# true when dotted version $1 >= $2: numeric per field, missing fields count as 0,
# a trailing suffix such as "-rc1" is ignored
_version_ge() {
  local -a a=() b=()
  local i x y
  IFS=. read -r -a a <<< "${1#v}"
  IFS=. read -r -a b <<< "${2#v}"
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    x="${a[i]:-0}"; x="${x%%[!0-9]*}"
    y="${b[i]:-0}"; y="${y%%[!0-9]*}"
    if ((10#${x:-0} > 10#${y:-0})); then return 0; fi
    if ((10#${x:-0} < 10#${y:-0})); then return 1; fi
  done
  return 0
}

# move a path aside without ever clobbering an existing backup
backup_aside() {
  local src="$1" dst="$1.pre-dotfiles"
  [ -e "$dst" ] && dst="$1.pre-dotfiles.$(date +%Y%m%dT%H%M%S)"
  warn "backing up $src -> $dst"
  mv "$src" "$dst"
}

# --------------------------------------------------------------------------
# 0b. seed the settings file with every available option (commented out), so
#     the options are discoverable on the machine. Never overwrites it.
# --------------------------------------------------------------------------
seed_bootstrap_config() {
  [ -e "$BOOTSTRAP_CONFIG" ] && return 0
  mkdir -p "$(dirname "$BOOTSTRAP_CONFIG")"
  cp "$DOTFILES/config.toml.example" "$BOOTSTRAP_CONFIG"
  log "wrote $BOOTSTRAP_CONFIG (all settings commented out)"
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
    local pkgs=(stow git-delta fzf zoxide ripgrep fd-find bat curl ca-certificates)
    # starship, mise, tmux, direnv + broot are handled by their omnishell
    # modules: 'omnishell apply' installs from apt/brew/pacman where available,
    # then an upstream release binary (x86_64 / arm64), and only otherwise falls
    # back to a git + cargo build - which needs a recent Rust toolchain plus the
    # build dependencies to be there already.
    if needs_source_builds; then
      pkgs+=("${APT_BUILD_DEPS[@]}")
    fi
    for pkg in "${pkgs[@]}"; do
      $SUDO apt-get install -y -qq "$pkg" >/dev/null 2>&1 || warn "apt: $pkg not installed"
    done
    if needs_source_builds; then
      ensure_rust_toolchain
    fi
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
# 1a. optional zsh install. Mode (yes | no | ask), highest precedence first:
#     --install-zsh / --no-install-zsh, DOTFILES_INSTALL_ZSH, INSTALL_ZSH in
#     the untracked settings file (see BOOTSTRAP_CONFIG), default ask. --yes
#     never counts as a "yes" for zsh.
# --------------------------------------------------------------------------
_install_zsh_mode() {
  local mode="$INSTALL_ZSH_FLAG"
  if [ -z "$mode" ] && [ -n "${DOTFILES_INSTALL_ZSH:-}" ]; then
    case "$DOTFILES_INSTALL_ZSH" in
      yes | no | ask) mode="$DOTFILES_INSTALL_ZSH" ;;
      *) warn "invalid DOTFILES_INSTALL_ZSH value '$DOTFILES_INSTALL_ZSH' (use yes, no or ask) - ignored" ;;
    esac
  fi
  printf '%s' "${mode:-${CONF_INSTALL_ZSH:-ask}}"
}

_install_zsh_package() {
  if command -v brew >/dev/null 2>&1; then
    brew install zsh
  elif command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get install -y -qq zsh
  else
    return 1
  fi
}

_zsh_hint() {
  warn "zsh is not installed ($1) - ~/.zshrc is written but unused until you install it"
  warn "  e.g. 'sudo apt-get install zsh' / 'brew install zsh', or re-run with --install-zsh"
}

ensure_zsh() {
  command -v zsh >/dev/null 2>&1 && return 0
  case "$(_install_zsh_mode)" in
    no) _zsh_hint "INSTALL_ZSH=no"; return 0 ;;
    ask)
      # --yes is not a "yes" for zsh: only an explicit setting installs it
      if [ "${ASSUME_YES:-0}" = "1" ] || ! _confirm "zsh is not installed - install it now?"; then
        _zsh_hint "not requested"
        return 0
      fi ;;
  esac
  log "installing zsh"
  _install_zsh_package || warn "zsh could not be installed - install it manually"
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

# True on CPUs omnishell ships no release binaries for (32-bit ARM, riscv64, ...):
# there its modules fall back to a cargo build. x86_64 and arm64 never need one.
needs_source_builds() {
  case "$(uname -m)" in
    x86_64 | amd64 | aarch64 | arm64) return 1 ;;
    *) return 0 ;;
  esac
}

# Rust >= $RUST_MIN_VERSION via rustup, for omnishell's git + cargo fallbacks. The
# distro cargo (1.75 on Ubuntu 24.04) is too old to build starship / broot / mise.
# Only touches machines where cargo is missing or too old; --no-modify-path keeps
# rustup out of the shell rc files (omnishell installs the built binaries itself).
ensure_rust_toolchain() {
  export PATH="$HOME/.cargo/bin:$PATH"
  local ver
  ver="$(cargo --version 2>/dev/null | awk '{print $2}' || true)"   # no cargo: empty, not a pipefail abort
  if [ -n "$ver" ] && _version_ge "$ver" "$RUST_MIN_VERSION"; then
    return 0
  fi
  if command -v rustup >/dev/null 2>&1; then
    log "updating the Rust toolchain (rustup; need >= $RUST_MIN_VERSION, have ${ver:-none})"
    rustup update stable || warn "rustup update failed - starship / broot / mise may not build"
    return 0
  fi
  command -v curl >/dev/null 2>&1 || { warn "curl missing - cannot install Rust; starship / broot / mise may not build"; return 0; }
  log "installing the Rust toolchain (rustup; need >= $RUST_MIN_VERSION, have ${ver:-none})"
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --no-modify-path \
    || warn "rustup install failed - starship / broot / mise may not build"
}

_omnishell_version() {
  omnishell version 2>/dev/null | awk 'NR == 1 { sub(/^v/, "", $1); print $1 }' || true
}

install_omnishell() {
  local ver
  if command -v omnishell >/dev/null 2>&1; then
    ver="$(_omnishell_version)"
    if [ -z "$ver" ] || _version_ge "$ver" "$OMNISHELL_MIN_VERSION"; then
      log "omnishell already installed ($(omnishell version 2>/dev/null || echo '?'))"
      return
    fi
    warn "omnishell $ver is below the minimum $OMNISHELL_MIN_VERSION - upgrading"
  fi
  if command -v brew >/dev/null 2>&1; then
    log "installing omnishell via Homebrew tap"
    brew upgrade jthegunner/tap/omnishell 2>/dev/null || brew install jthegunner/tap/omnishell
  else
    log "installing omnishell via curl installer"
    curl -fsSL https://raw.githubusercontent.com/JtheGunner/omnishell/main/install.sh | sh
  fi
  hash -r
  ver="$(_omnishell_version)"
  if [ -n "$ver" ] && ! _version_ge "$ver" "$OMNISHELL_MIN_VERSION"; then
    warn "omnishell $ver is still below the minimum $OMNISHELL_MIN_VERSION."
    warn "another omnishell earlier on PATH ($(command -v omnishell)) may shadow the new one - remove or update it and re-run."
    exit 1
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
# 3a. ghostty keybinds - one file per platform; the main config includes
#     ~/.config/ghostty-keybinds.conf, which links to the right one. It lives
#     outside the stowed ~/.config/ghostty directory so the link never lands
#     in the repo. DOTFILES_GHOSTTY_KEYBINDS=auto|mac|linux overrides the OS.
# --------------------------------------------------------------------------
setup_ghostty_keybinds() {
  local scheme="${DOTFILES_GHOSTTY_KEYBINDS:-${CONF_GHOSTTY_KEYBINDS:-auto}}" link="$HOME/.config/ghostty-keybinds.conf"
  case "$scheme" in
    auto | mac | linux) ;;
    *) warn "invalid DOTFILES_GHOSTTY_KEYBINDS value '$scheme' (use auto, mac or linux) - using auto"
       scheme=auto ;;
  esac
  if [ "$scheme" = auto ]; then
    if [ "$OS" = Darwin ]; then scheme=mac; else scheme=linux; fi
  fi
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    warn "$link is a regular file - left untouched (delete it to use the $scheme keybinds)"
    return 0
  fi
  mkdir -p "$(dirname "$link")"
  ln -sfn "$DOTFILES/ghostty/.config/ghostty/keybinds-$scheme.conf" "$link"
  log "ghostty keybinds: $scheme"
}

# --------------------------------------------------------------------------
# 3a'. ghostty values from the [ghostty] table of the settings file, written to
#      a generated include outside the stowed directory (it is loaded before
#      ~/.config/ghostty.local, so hand-written overrides still win). A file
#      this script did not generate is never touched.
# --------------------------------------------------------------------------
render_ghostty_settings() {
  local out="$HOME/.config/ghostty-settings.conf" body tmp
  body="$(settings_render_ghostty)"
  if ! _generated_or_absent "$out"; then
    warn "$out is not generated by bootstrap.sh - left untouched"
    return 0
  fi
  if [ -z "$body" ]; then
    rm -f "$out"
    return 0
  fi
  tmp="$(mktemp)" || { warn "could not write $out - skipped"; return 0; }
  printf '%s\n%s\n' "$GENERATED_MARK" "$body" > "$tmp"
  _install_generated "$out" "$tmp"
}

# --------------------------------------------------------------------------
# 3a''. tmux and git values from the [tmux] / [git] tables of the settings file,
#       written to generated includes outside the stowed directories; the tracked
#       tmux.conf and git config include them. A file this script did not generate
#       is never touched, and with no key set a generated file is removed.
# --------------------------------------------------------------------------
GENERATED_MARK="# GENERATED by bootstrap.sh from the settings file - do not edit"

# true when $1 does not exist or was generated by this script (any wording of the mark)
_generated_or_absent() { [ ! -e "$1" ] || head -n 1 "$1" | grep -q '^# GENERATED by bootstrap\.sh'; }

# move the finished file $2 into place as $1; a failure is a warning, never fatal
_install_generated() {
  if mkdir -p "$(dirname "$1")" 2>/dev/null && mv -f "$2" "$1" 2>/dev/null; then
    log "wrote $1"
  else
    rm -f "$2"
    warn "could not write $1 - skipped"
  fi
}

# the prefix the tracked tmux.conf sets, so the generated file can unbind it
_tracked_tmux_prefix() {
  awk '$1 == "set" && $2 == "-g" && $3 == "prefix" { print $4; exit }' "${1:-$DOTFILES/tmux/.tmux.conf}" 2>/dev/null || true
}

render_tmux_settings() {
  local out="$HOME/.config/tmux-settings.conf" body tmp
  body="$(settings_render_tmux "$(_tracked_tmux_prefix)")"
  if ! _generated_or_absent "$out"; then
    warn "$out is not generated by bootstrap.sh - left untouched"
    return 0
  fi
  if [ -z "$body" ]; then
    rm -f "$out"
    return 0
  fi
  tmp="$(mktemp)" || { warn "could not write $out - skipped"; return 0; }
  printf '%s\n%s\n' "$GENERATED_MARK" "$body" > "$tmp"
  _install_generated "$out" "$tmp"
}

# warn when the user's own ~/.gitconfig.local sets $1: it is included last, so it
# wins over the settings file
_warn_if_local_overrides() {
  local local_cfg="$HOME/.gitconfig.local"
  [ -f "$local_cfg" ] || return 0
  if git config --file "$local_cfg" --get "$1" >/dev/null 2>&1; then
    warn "$1 is also set in $local_cfg, which overrides the settings file"
  fi
}

render_git_settings() {
  local out="$HOME/.gitconfig.settings" records signing key value tmp
  records="$(settings_render_git)"
  signing="$(settings_get git.signing_key)"
  if ! _generated_or_absent "$out"; then
    warn "$out is not generated by bootstrap.sh - left untouched"
    return 0
  fi
  if [ -z "$records$signing" ]; then
    rm -f "$out"
    return 0
  fi
  tmp="$(mktemp)" || { warn "could not write $out - skipped"; return 0; }
  printf '%s\n' "$GENERATED_MARK" > "$tmp"
  while IFS="$SETTINGS_US" read -r key value; do
    [ -n "$key" ] || continue
    git config --file "$tmp" "$key" "$value" || warn "could not write $key to the git settings"
    _warn_if_local_overrides "$key"
  done <<< "$records"
  if [ -n "$signing" ]; then
    write_git_signing_config "$signing" "$tmp" || warn "could not write the signing key to the git settings"
    _warn_if_local_overrides user.signingkey
  fi
  # every value was skipped (for example a missing signing key): no marker-only file
  if [ -z "$(git config --file "$tmp" --list 2>/dev/null)" ]; then
    rm -f "$tmp" "$out"
    return 0
  fi
  _install_generated "$out" "$tmp"
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
  local local_cfg="$HOME/.gitconfig.local" name="" email="" have_name have_email
  # An empty ~/.gitconfig makes `git config --global` write there instead of
  # into ~/.config/git/config - the stowed file, i.e. back into this repo.
  [ -e "$HOME/.gitconfig" ] || : > "$HOME/.gitconfig"

  have_name="$(git config --get user.name 2>/dev/null || true)"
  have_email="$(git config --get user.email 2>/dev/null || true)"
  if [ -n "$have_name" ] && [ -n "$have_email" ]; then
    log "git identity already set ($have_email)"
    return 0
  fi
  if [ "${ASSUME_YES:-0}" = "1" ] || ! { : > /dev/tty; } 2>/dev/null; then
    if [ -z "$have_name$have_email" ]; then
      warn "no git identity - set one before committing:"
    else
      warn "git identity incomplete - set the missing part before committing:"
    fi
    [ -n "$have_name" ] || warn "  git config --file ~/.gitconfig.local user.name  'Your Name'"
    [ -n "$have_email" ] || warn "  git config --file ~/.gitconfig.local user.email 'you@example.com'"
    return 0
  fi
  if [ -z "$have_name" ]; then
    printf 'git user.name (empty = skip): ' > /dev/tty
    read -r name < /dev/tty || name=""
    [ -n "$name" ] || { warn "skipped git identity - git will refuse to commit until it is set"; return 0; }
  fi
  if [ -z "$have_email" ]; then
    printf 'git user.email (tip: your GitHub noreply address): ' > /dev/tty
    read -r email < /dev/tty || email=""
    [ -n "$email" ] || { warn "skipped git identity - git will refuse to commit until it is set"; return 0; }
  fi
  [ -z "$name" ] || git config --file "$local_cfg" user.name "$name"
  [ -z "$email" ] || git config --file "$local_cfg" user.email "$email"
  log "wrote git identity to $local_cfg"
}

# --------------------------------------------------------------------------
# 3d. optional SSH commit signing - only the public key path is asked for; the
#     rest of the signing config is derived from it. Written to the untracked
#     ~/.gitconfig.local, never to the stowed git config.
# --------------------------------------------------------------------------
write_git_signing_config() {
  local local_cfg="${2:-$HOME/.gitconfig.local}" key_path="${1:-}" key_file
  [ -n "$key_path" ] || return 0
  key_file="${key_path/#\~/$HOME}"
  case "$key_file" in
    *.pub) ;;
    *) warn "signing key must be a public key file (*.pub): $key_path - skipped"; return 0 ;;
  esac
  [ -f "$key_file" ] || { warn "signing key not found: $key_path - skipped"; return 0; }
  git config --file "$local_cfg" gpg.format ssh
  git config --file "$local_cfg" user.signingkey "$key_path"
  git config --file "$local_cfg" commit.gpgsign true
  git config --file "$local_cfg" tag.gpgsign true
  log "wrote ssh signing config to $local_cfg"
}

setup_git_signing_key() {
  local key_path
  if git config --get user.signingkey >/dev/null 2>&1; then
    log "git signing key already set ($(git config --get user.signingkey))"
    return 0
  fi
  if [ "${ASSUME_YES:-0}" = "1" ] || ! { : > /dev/tty; } 2>/dev/null; then
    return 0
  fi
  printf 'git ssh signing key, public key path (empty = skip signing): ' > /dev/tty
  read -r key_path < /dev/tty || key_path=""
  write_git_signing_config "$key_path"
}

# --------------------------------------------------------------------------
# 4. omnishell config
# --------------------------------------------------------------------------
# the tracked omnishell default with the settings file's omnishell / modules.*
# tables laid over it
_write_omnishell_config() {
  local cfgdir="${XDG_CONFIG_HOME:-$HOME/.config}/omnishell"
  mkdir -p "$cfgdir"
  settings_merge_omnishell "$DOTFILES/omnishell/config.toml" > "$cfgdir/config.toml"
}

# validate the merged config in a scratch XDG dir first, so a bad setting never
# replaces the working ~/.config/omnishell/config.toml
_validate_omnishell_config() {
  local tmp rc=0
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/omnishell"
  settings_merge_omnishell "$DOTFILES/omnishell/config.toml" > "$tmp/omnishell/config.toml"
  XDG_CONFIG_HOME="$tmp" omnishell validate || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# the merged config, validated first, at the live path
prepare_omnishell_config() {
  _validate_omnishell_config || {
    warn "the omnishell config is invalid - fix the [omnishell] / [modules.*] tables in $BOOTSTRAP_CONFIG (the current omnishell config was left as it is)"
    exit 2
  }
  _write_omnishell_config
}

apply_omnishell() {
  prepare_omnishell_config
  log "omnishell init + apply"
  omnishell init -y 2>/dev/null || omnishell init || true
  _write_omnishell_config   # init may template a fresh one
  # exit 1 = degraded module(s) (e.g. eza is not in Debian stable) - a state, not
  # a crash; keep going and list them again at the end (a long run buries them
  # mid-log). exit >=2 = config/other error - abort.
  local log_file rc=0
  log_file="$(mktemp)"
  omnishell apply -y 2>&1 | tee "$log_file" || rc="${PIPESTATUS[0]}"
  APPLY_REPORT="$(cat "$log_file")"
  rm -f "$log_file"
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    warn "omnishell apply failed (exit $rc)"
    exit "$rc"
  fi
  [ "$rc" -eq 0 ] || warn "omnishell reported degraded module(s); continuing"
}

# the `degraded <module> <reason>` lines of an `omnishell apply` report
_degraded_lines() {
  printf '%s\n' "$1" | grep -E '^[[:space:]]+degraded[[:space:]]' || true
}

_degraded_count() {
  _degraded_lines "$1" | grep -c . || true
}

# module + reason of every degraded module; prints nothing when there are none
_degraded_summary() {
  [ "$(_degraded_count "$1")" -gt 0 ] || return 0
  warn "degraded omnishell module(s) - not installed or not active:"
  _degraded_lines "$1" | awk '{ name = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); printf "         %-14s %s\n", name, $0 }' >&2
  warn "see 'omnishell doctor' for details; fix the cause and re-run ./bootstrap.sh"
}

finish() {
  local degraded
  degraded="$(_degraded_count "$APPLY_REPORT")"
  _degraded_summary "$APPLY_REPORT"
  if [ "$degraded" -gt 0 ]; then
    log "done with $degraded degraded module(s). Open a new shell (exec \$SHELL) to pick up the rest."
  else
    log "done. Open a new shell (exec \$SHELL) to pick everything up."
  fi
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

# --------------------------------------------------------------------------
# --interactive: ask for the settings, pick the modules in `omnishell tui`, and
# write both into the settings file (after a diff and a confirmation)
# --------------------------------------------------------------------------
INTERACTIVE_CHANGES=""
PROMPT_ABORT_HOOK=""   # a function to run when the input ends at a prompt
BACKUP_MADE=""         # the first backup of a run keeps the original settings file
INTERACTIVE_TMPFILES=""

# NAME: make a temp file, remember it for the exit trap, store its path in NAME
# (no command substitution: the record has to survive in this shell)
_interactive_mktemp() {
  local f
  f="$(mktemp)" || return 1
  INTERACTIVE_TMPFILES="${INTERACTIVE_TMPFILES}${f}"$'\n'
  printf -v "$1" '%s' "$f"
}

_interactive_cleanup() {
  local f
  while IFS= read -r f; do
    [ -z "$f" ] || rm -f "$f"
  done <<< "$INTERACTIVE_TMPFILES"
}

# temp files go away on exit, end of input and Ctrl-C alike
_interactive_traps() {
  trap _interactive_cleanup EXIT
  trap 'exit 130' INT TERM HUP
}

# NEW replaces the settings file: the first call of a run keeps the original as
# .bak, the content goes in through a temp file next to the target and a rename,
# so an interrupted write cannot leave half a file
_write_settings_file() {
  local staged target="$BOOTSTRAP_CONFIG" link hops=0
  # a symlinked settings file stays a symlink: the rename happens next to the real file
  while [ -L "$target" ] && [ "$hops" -lt 10 ]; do
    link="$(readlink "$target")" || return 1
    case "$link" in
      /*) target="$link" ;;
      *) target="$(dirname "$target")/$link" ;;
    esac
    hops=$((hops + 1))
  done
  if [ -z "$BACKUP_MADE" ]; then
    cp "$BOOTSTRAP_CONFIG" "$BOOTSTRAP_CONFIG.bak" || return 1
    BACKUP_MADE=1
  fi
  staged="$(mktemp "$target.XXXXXX")" || return 1
  if cp -p "$target" "$staged" && cat "$1" > "$staged" && mv -f "$staged" "$target"; then
    return 0
  fi
  rm -f "$staged"
  return 1
}

# PROMPT: reads one line into REPLY; end of input aborts before anything changes
_prompt_line() {
  printf '%s' "$1"
  IFS= read -r REPLY || {
    printf '\n' >&2
    [ -z "$PROMPT_ABORT_HOOK" ] || "$PROMPT_ABORT_HOOK"
    warn "input closed - $BOOTSTRAP_CONFIG was not changed"
    exit 1
  }
}

# Ask for every [bootstrap] / [ghostty] / [tmux] / [git] key of the schema.
# Enter keeps the value, "-" unsets it; INTERACTIVE_CHANGES collects table<US>key<US>literal.
interactive_collect() {
  local key type table name current hint literal
  log "dotfiles settings: Enter keeps the shown value, - unsets it"
  # the schema comes in on fd 3: the prompts below read the user's typing from stdin
  while IFS=' ' read -r key type <&3; do
    table="${key%%.*}"; name="${key#*.}"
    case "$table" in bootstrap | ghostty | tmux | git) ;; *) continue ;; esac
    current="$(settings_get "$key")"
    case "$type" in
      list) hint="names separated by spaces or commas" ;;
      *) hint="${type#enum:}" ;;
    esac
    while :; do
      _prompt_line "$key ($hint) [${current:-unset}]: "
      case "$REPLY" in
        "") break ;;
        -) INTERACTIVE_CHANGES="${INTERACTIVE_CHANGES}${table}${SETTINGS_US}${name}${SETTINGS_US}"$'\n'; break ;;
      esac
      if literal="$(_settings_literal "$type" "$REPLY")"; then
        INTERACTIVE_CHANGES="${INTERACTIVE_CHANGES}${table}${SETTINGS_US}${name}${SETTINGS_US}${literal}"$'\n'
        break
      fi
      warn "invalid value for $key (expected $hint)"
    done
  done 3<<< "$SETTINGS_SCHEMA"
}

# NEWFILE [NOTE]: show the diff against the settings file and ask before replacing
# it (the old one is kept as .bak). Returns 0 when written or unchanged, 1 when declined.
_review_and_install() {
  local new="$1"
  if cmp -s "$BOOTSTRAP_CONFIG" "$new"; then
    log "no changes to $BOOTSTRAP_CONFIG"
    return 0
  fi
  diff -u "$BOOTSTRAP_CONFIG" "$new" || true
  [ -z "${2:-}" ] || log "$2"
  _prompt_line "Write these changes to $BOOTSTRAP_CONFIG? [y/N] "
  case "$REPLY" in y | Y | yes | YES) ;; *) return 1 ;; esac
  _write_settings_file "$new" || {
    warn "cannot write $BOOTSTRAP_CONFIG"
    exit 1
  }
}

# before anything is installed: the dotfiles-owned prompts
interactive_settings() {
  [ -n "$INTERACTIVE_FLAG" ] || return 0
  local tmp
  _interactive_traps
  interactive_collect
  if [ -z "$INTERACTIVE_CHANGES" ]; then
    log "settings unchanged"
    return 0
  fi
  _interactive_mktemp tmp
  settings_update_file "$BOOTSTRAP_CONFIG" "$INTERACTIVE_CHANGES" > "$tmp"
  if ! _review_and_install "$tmp"; then
    rm -f "$tmp"
    log "nothing written, nothing installed"
    exit 0
  fi
  rm -f "$tmp"
  reload_settings
}

# after omnishell is installed: the module selection in its TUI. The TUI edits
# the live omnishell config (merged from the tracked default and the settings
# file); what it leaves behind is compared with the default and written back.
interactive_modules() {
  [ -n "$INTERACTIVE_FLAG" ] || return 0
  local live tmp rc=0
  _interactive_traps
  prepare_omnishell_config
  live="${XDG_CONFIG_HOME:-$HOME/.config}/omnishell/config.toml"
  log "omnishell tui: Space toggles a module, o edits its options, a previews the plan, q quits"
  omnishell tui || rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "omnishell tui exited with $rc - the module selection was not taken over"
    exit "$rc"
  fi
  _interactive_mktemp tmp
  settings_update_omnishell "$BOOTSTRAP_CONFIG" "$live" "$DOTFILES/omnishell/config.toml" > "$tmp"
  # a declined or aborted review must not leave the TUI's selection in the live config
  PROMPT_ABORT_HOOK=_write_omnishell_config
  if ! _review_and_install "$tmp" "if you pressed a in the TUI this machine already follows your choice; y keeps it in $BOOTSTRAP_CONFIG too, n leaves the file as it was and resets the omnishell config to it"; then
    rm -f "$tmp"
    PROMPT_ABORT_HOOK=""
    _write_omnishell_config
    log "$BOOTSTRAP_CONFIG left as it was, the omnishell config reset to it; the rest of the install was skipped"
    exit 0
  fi
  PROMPT_ABORT_HOOK=""
  rm -f "$tmp"
  reload_settings
}

# both ends must be a terminal for the prompts and the TUI (tests redefine this)
interactive_tty() { [ -t 0 ] && [ -t 1 ]; }

check_interactive_preconditions() {
  [ -n "$INTERACTIVE_FLAG" ] || return 0
  interactive_tty && return 0
  printf 'bootstrap.sh: --interactive needs a terminal; run without it, or edit %s by hand\n' "$BOOTSTRAP_CONFIG" >&2
  exit 2
}

main() {
  check_interactive_preconditions
  check_checkout_consistency
  seed_bootstrap_config
  interactive_settings
  install_deps
  ensure_zsh
  install_ghostty
  install_omnishell
  interactive_modules
  write_rc_base
  stow_packages
  setup_ghostty_keybinds
  render_ghostty_settings
  render_tmux_settings
  render_git_settings
  setup_git_delta
  setup_git_identity
  setup_git_signing_key
  apply_omnishell
  wire_shell_d
  log "rendering Root Loops colors"
  bash "$DOTFILES/rootloops/apply.sh"
  setup_terminal_app
  finish
}

# BOOTSTRAP_SOURCE_ONLY=1 lets tests source the helpers without running anything.
[ -n "${BOOTSTRAP_SOURCE_ONLY:-}" ] || main "$@"
