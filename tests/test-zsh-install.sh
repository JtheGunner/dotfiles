#!/usr/bin/env bash
# bootstrap.sh optional zsh install: only an explicit "yes" (flag, env or config
# file) installs it; --yes alone never does. Flag > env > config file > ask.
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

pass() { printf '   ok   %s\n' "$1"; }
fail() { printf '   FAIL %s\n' "$1"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# A PATH with only what the functions under test need, so `zsh` is present
# exactly when a test puts a fake one in $WORK/bin. apt-get is a recorder.
mkdir -p "$WORK/bin"
for tool in head rm cat cp mkdir basename dirname uname id tr; do
  ln -s "$(command -v "$tool")" "$WORK/bin/$tool"
done
APT_LOG="$WORK/apt.log"
fake_apt()    { printf '#!/bin/sh\necho "$@" >> "%s"\nexit %s\n' "$APT_LOG" "${1:-0}" > "$WORK/bin/apt-get"; chmod +x "$WORK/bin/apt-get"; }
with_zsh()    { printf '#!/bin/sh\n' > "$WORK/bin/zsh"; chmod +x "$WORK/bin/zsh"; }
without_zsh() { rm -f "$WORK/bin/zsh"; }

# one fresh scenario: no zsh, working fake apt-get, empty log, no config file
reset() { without_zsh; fake_apt 0; : > "$APT_LOG"; rm -f "$WORK/bootstrap.conf"; }
config() { printf '%s\n' "$@" > "$WORK/bootstrap.conf"; }
installed() { grep -q 'install.* zsh' "$APT_LOG"; }

# run ensure_zsh non-interactively. $1 = extra env assignments, $2 = shell
# prefix (e.g. a flag variable). DOTFILES_TTY points at a missing file, so a
# prompt can never read an answer.
run() {
  env -i PATH="$WORK/bin" HOME="$WORK/home" DOTFILES_CONFIG="$WORK/bootstrap.conf" \
    DOTFILES_TTY="$WORK/no-tty" BOOTSTRAP_SOURCE_ONLY=1 $1 \
    "$BASH" -c ". '$DOTFILES/bootstrap.sh'; ${2:-}ensure_zsh" 2>"$WORK/err"
}

echo ">> zsh already installed"
reset; with_zsh; config 'INSTALL_ZSH=yes'
run ""
check "does nothing" "[ ! -s '$APT_LOG' ]"

echo ">> default (ask) without a tty"
reset
check "exits 0" "run ''"
check "does not install" "! installed"
check "warns with the manual command" "grep -q 'apt-get install zsh' '$WORK/err'"

echo ">> ask with a tty"
reset; printf 'y\n' > "$WORK/tty-yes"
run "DOTFILES_TTY=$WORK/tty-yes"
check "answering yes installs" "installed"
reset; printf 'n\n' > "$WORK/tty-no"
run "DOTFILES_TTY=$WORK/tty-no"
check "answering no does not install" "! installed"

echo ">> --yes alone never installs"
reset
check "exits 0" "run 'ASSUME_YES=1'"
check "does not install" "! installed"
check "warns" "grep -q 'zsh is not installed' '$WORK/err'"

echo ">> config file"
reset; config '# machine settings' '' 'INSTALL_ZSH=yes'
run ""
check "INSTALL_ZSH=yes installs" "installed"
reset; config 'INSTALL_ZSH = yes  # padded'
run ""
check "tolerates spaces and trailing comments" "installed"
reset; config 'INSTALL_ZSH=no'
run ""
check "INSTALL_ZSH=no does not install" "! installed"
reset; config 'INSTALL_ZSH=ask'
run ""
check "INSTALL_ZSH=ask without a tty does not install" "! installed"
reset; config 'INSTALL_ZSH=no'
run 'ASSUME_YES=1'
check "no wins over --yes" "! installed"
reset; config 'INSTALL_ZSH=yes'
run 'ASSUME_YES=1'
check "yes together with --yes installs" "installed"

echo ">> invalid config"
reset; config 'INSTALL_ZSH=maybe'
check "bad value: exits 0" "run ''"
check "bad value: warns" "grep -q \"invalid INSTALL_ZSH\" '$WORK/err'"
check "bad value: falls back to ask (no install)" "! installed"
reset; config 'FOO=bar' '$(touch '"$WORK"'/pwned)'
check "unknown key: exits 0" "run ''"
check "unknown key: warns" "grep -q 'unknown key' '$WORK/err'"
check "config lines are never executed" "[ ! -e '$WORK/pwned' ]"

echo ">> precedence: flag > env > config"
reset; config 'INSTALL_ZSH=no'
run 'DOTFILES_INSTALL_ZSH=yes'
check "env yes beats config no" "installed"
reset; config 'INSTALL_ZSH=yes'
run 'DOTFILES_INSTALL_ZSH=no'
check "env no beats config yes" "! installed"
reset; config 'INSTALL_ZSH=no'
run 'DOTFILES_INSTALL_ZSH=no' 'INSTALL_ZSH_FLAG=yes; '
check "flag yes beats env no" "installed"
reset; config 'INSTALL_ZSH=yes'
run 'DOTFILES_INSTALL_ZSH=yes' 'INSTALL_ZSH_FLAG=no; '
check "flag no beats env yes" "! installed"

echo ">> install failure"
reset; fake_apt 1; config 'INSTALL_ZSH=yes'
check "exits 0" "run ''"
check "warns" "grep -q 'zsh could not be installed' '$WORK/err'"

echo ">> settings template and other keys"
# evaluate an expression after sourcing bootstrap.sh against the test config
probe() {
  env -i PATH="$WORK/bin" HOME="$WORK/home" DOTFILES_CONFIG="$WORK/bootstrap.conf" \
    BOOTSTRAP_SOURCE_ONLY=1 $1 "$BASH" -c ". '$DOTFILES/bootstrap.sh'; $2" 2>"$WORK/err"
}
keys="$(env -i PATH="$WORK/bin" HOME="$WORK/home" BOOTSTRAP_SOURCE_ONLY=1 \
  "$BASH" -c ". '$DOTFILES/bootstrap.sh'; printf '%s ' \"\${BOOTSTRAP_CONFIG_KEYS[@]}\"" 2>/dev/null)"
check "knows at least one key" "[ -n '$keys' ]"
for key in $keys; do
  check "bootstrap.conf.example documents $key" \
    "grep -qE '^#?$key=' '$DOTFILES/bootstrap.conf.example'"
done
check "the template has every setting commented out" \
  "! grep -qE '^[A-Z_]+=' '$DOTFILES/bootstrap.conf.example'"

reset; cp "$DOTFILES/bootstrap.conf.example" "$WORK/bootstrap.conf"
probe "" 'true'
check "the template loads without warnings" "[ ! -s '$WORK/err' ]"

reset; config 'ASSUME_YES=yes'
check "ASSUME_YES=yes sets ASSUME_YES=1" "[ \"\$(probe '' 'printf %s \"\$ASSUME_YES\"')\" = 1 ]"
check "env DOTFILES_ASSUME_YES=0 beats the config file" \
  "[ \"\$(probe 'DOTFILES_ASSUME_YES=0' 'printf %s \"\$ASSUME_YES\"')\" = 0 ]"
reset; config 'ASSUME_YES=maybe'
probe "" 'true'
check "invalid ASSUME_YES warns" "grep -q 'invalid ASSUME_YES' '$WORK/err'"
check "invalid ASSUME_YES falls back to 0" "[ \"\$(probe '' 'printf %s \"\$ASSUME_YES\"')\" = 0 ]"

reset; config 'TERMINALS=rootloops nonexistent'
check "TERMINALS adds an existing package dir" \
  "probe '' 'printf \"%s \" \"\${PACKAGES[@]}\"' | grep -qw rootloops"
check "TERMINALS ignores a missing dir" \
  "! probe '' 'printf \"%s \" \"\${PACKAGES[@]}\"' | grep -qw nonexistent"

echo ">> seeding the settings file"
reset; rm -rf "$WORK/seed"; SEED="$WORK/seed/dotfiles/bootstrap.conf"
seed() { env -i PATH="$WORK/bin" HOME="$WORK/home" DOTFILES_CONFIG="$SEED" BOOTSTRAP_SOURCE_ONLY=1 \
  "$BASH" -c ". '$DOTFILES/bootstrap.sh'; seed_bootstrap_config" >/dev/null 2>&1; }
seed
check "creates the file and its directory from the template" "cmp -s '$SEED' '$DOTFILES/bootstrap.conf.example'"
printf 'INSTALL_ZSH=yes\n' > "$SEED"
seed
check "never overwrites an existing file" "[ \"\$(cat '$SEED')\" = 'INSTALL_ZSH=yes' ]"

echo ">> command line"
check "--help lists --install-zsh" \
  "bash '$DOTFILES/bootstrap.sh' --help | grep -q -- '--install-zsh'"
check "--help lists --no-install-zsh" \
  "bash '$DOTFILES/bootstrap.sh' --help | grep -q -- '--no-install-zsh'"

echo
if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
