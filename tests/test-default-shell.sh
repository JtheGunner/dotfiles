#!/usr/bin/env bash
# bootstrap.sh ensure_default_shell: zsh becomes the login shell only when it is
# installed, is not the login shell yet, and the mode (flag > env > settings file
# > ask) or the answer says so. --yes alone never runs chsh; every failure path
# warns and exits 0.
# shellcheck disable=SC2034  # RC is read inside the eval'd check expressions
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

pass() { printf '   ok   %s\n' "$1"; }
fail() { printf '   FAIL %s\n' "$1"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# A PATH with only what bootstrap.sh and the library need when sourced. zsh,
# chsh, getent and dscl exist only when a scenario puts a fake one in $WORK/bin.
mkdir -p "$WORK/bin"
for tool in head rm cat cp mkdir basename dirname uname id tr awk grep sed ln readlink cmp mv mktemp tee git; do
  ln -s "$(command -v "$tool")" "$WORK/bin/$tool"
done
CHSH_LOG="$WORK/chsh.log"
ZSH="$WORK/bin/zsh"

with_zsh()  { printf '#!/bin/sh\n' > "$ZSH"; chmod +x "$ZSH"; }
with_chsh() { printf '#!/bin/sh\necho "$@" >> "%s"\nexit %s\n' "$CHSH_LOG" "${1:-0}" > "$WORK/bin/chsh"; chmod +x "$WORK/bin/chsh"; }
called()    { [ -s "$CHSH_LOG" ]; }
said()      { cat "$WORK/out" "$WORK/err" | grep -q -- "$1"; }

# one fresh scenario: no zsh, no chsh, empty log, no settings file, no tty answers
reset() {
  rm -f "$ZSH" "$WORK/bin/chsh" "$WORK/bin/getent" "$WORK/bin/dscl" "$CHSH_LOG" "$WORK/config.toml" "$WORK/no-tty" "$WORK/tty-yes" "$WORK/tty-no"
  : > "$WORK/out"; : > "$WORK/err"
}
config() { printf '%s\n' "$@" > "$WORK/config.toml"; }

# Stubs every scenario starts from: the login shell is bash, zsh is listed in
# /etc/shells and a terminal is present. Scenarios redefine what they test.
STUBS='_login_shell() { echo /bin/bash; }; _shell_listed() { return 0; }; interactive_tty() { return 0; };'

# run <env assignments> <shell code>: source bootstrap.sh and run the code. DOTFILES_TTY
# points at a missing file, so a prompt can never read an answer unless a scenario
# gives it one. The exit code lands in RC.
run() {
  RC=0
  env -i PATH="$WORK/bin" HOME="$WORK/home" DOTFILES_CONFIG="$WORK/config.toml" \
    DOTFILES_TTY="$WORK/no-tty" BOOTSTRAP_SOURCE_ONLY=1 $1 \
    "$BASH" -c ". '$DOTFILES/bootstrap.sh'; $2" >"$WORK/out" 2>"$WORK/err" || RC=$?
}

echo ">> no zsh"
reset; with_chsh
run "" "$STUBS ensure_default_shell"
check "does nothing and stays quiet" '[ "$RC" = 0 ] && ! called && [ ! -s "$WORK/err" ]'

echo ">> zsh is already the login shell"
for path in /usr/bin/zsh /bin/zsh /home/linuxbrew/.linuxbrew/bin/zsh; do
  reset; with_zsh; with_chsh
  run "" "$STUBS _login_shell() { echo $path; }; ensure_default_shell"
  check "$path: no prompt, no chsh" '[ "$RC" = 0 ] && ! called && [ ! -s "$WORK/err" ]'
done

echo ">> the login shell cannot be determined"
reset; with_zsh; with_chsh
run "" "$STUBS _login_shell() { :; }; ensure_default_shell"
check "an empty login shell is skipped silently" '[ "$RC" = 0 ] && ! called && [ ! -s "$WORK/err" ]'

echo ">> _login_shell"
reset; printf '#!/bin/sh\necho "jeff:x:1000:1000::/home/jeff:/usr/bin/zsh"\n' > "$WORK/bin/getent"; chmod +x "$WORK/bin/getent"
run "" 'OS=Linux; _login_shell'
check "Linux reads the passwd entry" '[ "$(cat "$WORK/out")" = /usr/bin/zsh ]'
reset; printf '#!/bin/sh\nexit 2\n' > "$WORK/bin/getent"; chmod +x "$WORK/bin/getent"
run "SHELL=/bin/bash" 'OS=Linux; _login_shell'
check "an empty passwd lookup falls back to SHELL" '[ "$(cat "$WORK/out")" = /bin/bash ]'
reset
run "SHELL=" 'OS=Linux; _login_shell'
check "no getent and no SHELL prints nothing" '[ "$RC" = 0 ] && [ ! -s "$WORK/out" ]'
reset; printf '#!/bin/sh\necho "UserShell: /bin/zsh"\n' > "$WORK/bin/dscl"; chmod +x "$WORK/bin/dscl"
run "" 'OS=Darwin; _login_shell'
check "macOS reads the directory service" '[ "$(cat "$WORK/out")" = /bin/zsh ]'

echo ">> ask with a terminal"
reset; with_zsh; with_chsh; printf 'y\n' > "$WORK/tty-yes"
run "DOTFILES_TTY=$WORK/tty-yes" "$STUBS ensure_default_shell"
check "answering yes runs chsh -s with the zsh path" '[ "$RC" = 0 ] && [ "$(cat "$CHSH_LOG")" = "-s $ZSH" ]'
check "and says the change applies at the next login" 'said "next login"'
run "DOTFILES_TTY=$WORK/tty-yes" "$STUBS ensure_default_shell; echo changed=\$LOGIN_SHELL_CHANGED"
check "a successful chsh sets LOGIN_SHELL_CHANGED" 'said "changed=1"'
reset; with_zsh; with_chsh; printf 'n\n' > "$WORK/tty-no"
run "DOTFILES_TTY=$WORK/tty-no" "$STUBS ensure_default_shell; echo changed=\$LOGIN_SHELL_CHANGED"
check "answering no does not run chsh" '[ "$RC" = 0 ] && ! called'
check "and leaves LOGIN_SHELL_CHANGED at 0" 'said "changed=0"'
reset; with_zsh; with_chsh 1; printf 'y\n' > "$WORK/tty-yes"
run "DOTFILES_TTY=$WORK/tty-yes" "$STUBS ensure_default_shell; echo changed=\$LOGIN_SHELL_CHANGED"
check "a failing chsh leaves LOGIN_SHELL_CHANGED at 0" 'said "changed=0"'

echo ">> ask without an answer"
reset; with_zsh; with_chsh
run "ASSUME_YES=1" "$STUBS ensure_default_shell"
check "--yes alone does not run chsh" '[ "$RC" = 0 ] && ! called'
check "--yes alone prints the manual command" 'said "chsh -s"'
reset; with_zsh; with_chsh
run "" "$STUBS ensure_default_shell"
check "no terminal answer does not run chsh" '[ "$RC" = 0 ] && ! called'
check "no terminal answer prints the manual command" 'said "chsh -s"'

echo ">> mode no"
reset; with_zsh; with_chsh; config '[bootstrap]' 'set_default_shell = "no"'
run "" "$STUBS ensure_default_shell"
check "set_default_shell = no does not run chsh" '[ "$RC" = 0 ] && ! called'
reset; with_zsh; with_chsh; config '[bootstrap]' 'set_default_shell = "yes"'
run "" "$STUBS SET_DEFAULT_SHELL_FLAG=no; ensure_default_shell"
check "--no-set-default-shell beats the file" '[ "$RC" = 0 ] && ! called'

echo ">> mode yes"
reset; with_zsh; with_chsh
run "DOTFILES_SET_DEFAULT_SHELL=yes ASSUME_YES=1" "$STUBS ensure_default_shell"
check "an explicit yes runs chsh even with --yes" '[ "$RC" = 0 ] && [ "$(cat "$CHSH_LOG")" = "-s $ZSH" ]'
reset; with_zsh; with_chsh
run "DOTFILES_SET_DEFAULT_SHELL=yes" "$STUBS interactive_tty() { return 1; }; ensure_default_shell"
check "without a terminal chsh is not run" '[ "$RC" = 0 ] && ! called'
check "and the manual command is printed" 'said "chsh -s $ZSH"'

echo ">> failure paths exit 0 with a warning"
reset; with_zsh; with_chsh
run "DOTFILES_SET_DEFAULT_SHELL=yes" "$STUBS _shell_listed() { return 1; }; ensure_default_shell"
check "a path missing from /etc/shells does not run chsh" '[ "$RC" = 0 ] && ! called'
check "and the warning names the path and /etc/shells" 'said "$ZSH" && said "/etc/shells"'
reset; with_zsh
run "DOTFILES_SET_DEFAULT_SHELL=yes" "$STUBS ensure_default_shell"
check "a missing chsh exits 0" '[ "$RC" = 0 ]'
check "and the warning has the manual command" 'said "chsh -s"'
reset; with_zsh; with_chsh 1
run "DOTFILES_SET_DEFAULT_SHELL=yes" "$STUBS ensure_default_shell"
check "a failing chsh exits 0" '[ "$RC" = 0 ] && called'
check "and the warning has the manual command" 'said "chsh -s"'

echo ">> re-run after a successful change"
reset; with_zsh; with_chsh
run "DOTFILES_SET_DEFAULT_SHELL=yes" "$STUBS ensure_default_shell; _login_shell() { echo $ZSH; }; ensure_default_shell"
check "chsh runs once" '[ "$RC" = 0 ] && [ "$(wc -l < "$CHSH_LOG" | tr -d " ")" = 1 ]'

echo ">> command line"
check "--help lists --set-default-shell" \
  "bash '$DOTFILES/bootstrap.sh' --help | grep -q -- '--set-default-shell'"
check "--help lists --no-set-default-shell" \
  "bash '$DOTFILES/bootstrap.sh' --help | grep -q -- '--no-set-default-shell'"

echo
if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
