#!/usr/bin/env bash
# bootstrap.sh install_ghostty on apt systems: the community .deb is built for
# Ubuntu, so only Ubuntu and its derivatives (ID=ubuntu or ID_LIKE containing
# ubuntu) try it. Debian and unknown systems warn with the download page.
# shellcheck disable=SC2034  # RC is read inside the eval'd check expressions
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

pass() { printf '   ok   %s\n' "$1"; }
fail() { printf '   FAIL %s\n' "$1"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# dpkg exists so the apt branch is taken; ghostty and apt-cache do not.
mkdir -p "$WORK/bin"
for tool in head rm cat cp mkdir basename dirname uname id tr awk grep sed ln readlink cmp mv mktemp tee git cut touch; do
  ln -s "$(command -v "$tool")" "$WORK/bin/$tool"
done
printf '#!/bin/sh\n' > "$WORK/bin/dpkg"; chmod +x "$WORK/bin/dpkg"

GHOSTTY_ENV=""
# run <os-release file>: install_ghostty with the .deb helper stubbed to a marker
run() {
  rm -f "$WORK/deb-tried"
  RC=0
  # shellcheck disable=SC2086  # GHOSTTY_ENV is a list of NAME=value words
  env -i PATH="$WORK/bin" HOME="$WORK/home" DOTFILES_OS_RELEASE="$1" $GHOSTTY_ENV \
    BOOTSTRAP_SOURCE_ONLY=1 "$BASH" -c ". '$DOTFILES/bootstrap.sh'; OS=Linux
      _install_ghostty_deb() { touch '$WORK/deb-tried'; }; install_ghostty" >"$WORK/out" 2>"$WORK/err" || RC=$?
}
# release <content>: write an os-release file and run against it
release() { printf '%s\n' "$1" > "$WORK/os-release"; run "$WORK/os-release"; }
said() { grep -q -- "$1" "$WORK/out" "$WORK/err"; }

echo ">> Ubuntu"
release $'ID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"\nPRETTY_NAME="Ubuntu 24.04 LTS"'
check "tries the .deb" '[ "$RC" = 0 ] && [ -e "$WORK/deb-tried" ]'

echo ">> Ubuntu derivative"
release $'ID=linuxmint\nID_LIKE="ubuntu debian"\nVERSION_ID="22"'
check "tries the .deb" '[ -e "$WORK/deb-tried" ]'

echo ">> Debian"
release $'ID=debian\nVERSION_ID="12"\nPRETTY_NAME="Debian GNU/Linux 12 (bookworm)"'
check "skips the .deb" '[ "$RC" = 0 ] && [ ! -e "$WORK/deb-tried" ]'
check "names the distribution, not Ubuntu 12" 'said "Debian GNU/Linux 12" && ! said "Ubuntu 12"'
check "points at the download page" 'said "https://ghostty.org/download"'

echo ">> Debian derivative without ubuntu"
release $'ID=raspbian\nID_LIKE=debian\nVERSION_ID="12"'
check "skips the .deb" '[ ! -e "$WORK/deb-tried" ] && said "https://ghostty.org/download"'

echo ">> unknown distribution"
release ""
check "an empty file skips the .deb" '[ "$RC" = 0 ] && [ ! -e "$WORK/deb-tried" ] && said "this distribution"'
run "$WORK/missing"
check "a missing file skips the .deb" '[ "$RC" = 0 ] && [ ! -e "$WORK/deb-tried" ]'

echo ">> switched off"
UBUNTU=$'ID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"'
GHOSTTY_ENV="DOTFILES_INSTALL_GHOSTTY=0"
release "$UBUNTU"
check "the environment skips the .deb on Ubuntu" '[ "$RC" = 0 ] && [ ! -e "$WORK/deb-tried" ]'
check "says that the install is skipped" 'said "skipping ghostty"'
GHOSTTY_ENV=""
release "$UBUNTU"
check "without the switch the .deb is tried again" '[ -e "$WORK/deb-tried" ]'

printf '[bootstrap]\ninstall_ghostty = false\n' > "$WORK/off.toml"
GHOSTTY_ENV="DOTFILES_CONFIG=$WORK/off.toml"
release "$UBUNTU"
check "install_ghostty = false in the settings file skips the .deb" '[ "$RC" = 0 ] && [ ! -e "$WORK/deb-tried" ] && said "skipping ghostty"'
GHOSTTY_ENV=""

# macOS: brew is stubbed to a marker; the cask must not be installed when off
printf '#!/bin/sh\necho "$*" >> "%s/brew-log"\n' "$WORK" > "$WORK/bin/brew"; chmod +x "$WORK/bin/brew"
mac() {
  rm -f "$WORK/brew-log"
  env -i PATH="$WORK/bin" HOME="$WORK/home" $1 BOOTSTRAP_SOURCE_ONLY=1 "$BASH" -c \
    ". '$DOTFILES/bootstrap.sh'; OS=Darwin; install_ghostty" >"$WORK/out" 2>"$WORK/err" || true
}
mac ""
check "macOS installs the cask by default" 'grep -q "install --cask ghostty" "$WORK/brew-log"'
mac "DOTFILES_INSTALL_GHOSTTY=false"
check "macOS does not touch brew when switched off" '[ ! -e "$WORK/brew-log" ] && said "skipping ghostty"'

echo ">> command line"
check "--help lists --ghostty" "bash '$DOTFILES/bootstrap.sh' --help | grep -q -- '--ghostty'"
check "--help lists --no-ghostty" "bash '$DOTFILES/bootstrap.sh' --help | grep -q -- '--no-ghostty'"

echo
if [ "$failures" -eq 0 ]; then echo "all ghostty-install checks passed"; else echo "$failures check(s) failed"; exit 1; fi
