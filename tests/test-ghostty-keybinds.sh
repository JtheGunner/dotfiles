#!/usr/bin/env bash
# Ghostty keybinds: one file per platform, kept in sync, linked by bootstrap.sh.
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY="$DOTFILES/ghostty/.config/ghostty"
MAC="$GHOSTTY/keybinds-mac.conf"
LINUX="$GHOSTTY/keybinds-linux.conf"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

pass() { printf '   ok   %s\n' "$1"; }
fail() { printf '   FAIL %s\n' "$1"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# `keybind = <trigger>=<action>` lines only (not `keybind = clear`)
binds() { grep -E '^keybind = [^=]+=' "$1"; }
triggers() { binds "$1" | sed -E 's/^keybind = ([^=]+)=.*/\1/' | sed -E 's/^global://'; }
actions() { binds "$1" | sed -E 's/^keybind = [^=]+=//' | sort; }

echo ">> files"
check "keybinds-mac.conf exists" "[ -f '$MAC' ]"
check "keybinds-linux.conf exists" "[ -f '$LINUX' ]"

echo ">> main config"
check "has no keybind lines of its own" "! grep -qE '^keybind' '$GHOSTTY/config'"
check "includes the generated keybinds file" \
  "grep -qxF 'config-file = ?~/.config/ghostty-keybinds.conf' '$GHOSTTY/config'"
check "still includes the per-machine overrides last" \
  "[ \"\$(grep -n '^config-file' '$GHOSTTY/config' | tail -1 | cut -d= -f2- | tr -d ' ?')\" = '~/.config/ghostty.local' ]"

echo ">> parity"
check "both files bind the same actions" "[ \"\$(actions '$MAC')\" = \"\$(actions '$LINUX')\" ]"
for f in "$MAC" "$LINUX"; do
  name="$(basename "$f")"
  check "$name binds no trigger twice" "[ -z \"\$(triggers '$f' | sort | uniq -d)\" ]"
done
check "mac keeps the super scheme" "! triggers '$MAC' | grep -q '^ctrl+shift'"
check "linux never uses super" "! grep -q 'super' <(binds '$LINUX')"
check "linux keeps the shell's plain ctrl keys free" \
  "! triggers '$LINUX' | grep -qE '^(global:)?ctrl\\+[a-z]='"
check "mac clears Ghostty's defaults" "grep -qxF 'keybind = clear' '$MAC'"
check "linux keeps Ghostty's defaults" "! grep -qxF 'keybind = clear' '$LINUX'"
check "both send a newline on shift+enter" \
  "grep -qF 'keybind = shift+enter=text:' '$MAC' && grep -qF 'keybind = shift+enter=text:' '$LINUX'"

echo ">> bootstrap"
mkdir -p "$WORK/bin"
for tool in ln rm cat mkdir basename dirname uname id readlink awk mv tr; do
  ln -s "$(command -v "$tool")" "$WORK/bin/$tool"
done
# run setup_ghostty_keybinds as <os> with an optional override, in a fresh $HOME
setup() {
  HOME_DIR="$WORK/home-$1-${2:-auto}"
  mkdir -p "$HOME_DIR/.config"
  env -i PATH="$WORK/bin" HOME="$HOME_DIR" BOOTSTRAP_SOURCE_ONLY=1 ${2:+DOTFILES_GHOSTTY_KEYBINDS=$2} \
    "$BASH" -c ". '$DOTFILES/bootstrap.sh'; OS=$1; setup_ghostty_keybinds" >/dev/null 2>"$WORK/err"
}
target() { readlink "$HOME_DIR/.config/ghostty-keybinds.conf"; }

setup Darwin
check "macOS links keybinds-mac.conf" "[ \"\$(target)\" = '$MAC' ]"
setup Linux
check "Linux links keybinds-linux.conf" "[ \"\$(target)\" = '$LINUX' ]"
setup Darwin linux
check "override linux wins on macOS" "[ \"\$(target)\" = '$LINUX' ]"
setup Linux mac
check "override mac wins on Linux" "[ \"\$(target)\" = '$MAC' ]"
setup Linux bogus
check "invalid override warns" "grep -q 'DOTFILES_GHOSTTY_KEYBINDS' '$WORK/err'"
check "invalid override falls back to the OS default" "[ \"\$(target)\" = '$LINUX' ]"

setup Linux
setup_again() {
  env -i PATH="$WORK/bin" HOME="$HOME_DIR" BOOTSTRAP_SOURCE_ONLY=1 \
    "$BASH" -c ". '$DOTFILES/bootstrap.sh'; OS=Darwin; setup_ghostty_keybinds" >/dev/null 2>"$WORK/err"
}
setup_again
check "re-running relinks to the current OS" "[ \"\$(target)\" = '$MAC' ]"
rm "$HOME_DIR/.config/ghostty-keybinds.conf"
printf 'keybind = ctrl+x=close_surface\n' > "$HOME_DIR/.config/ghostty-keybinds.conf"
setup_again
check "never replaces a regular file" "[ ! -L '$HOME_DIR/.config/ghostty-keybinds.conf' ]"
check "keeps the file content" "grep -q ctrl+x '$HOME_DIR/.config/ghostty-keybinds.conf'"
check "warns about the regular file" "grep -q 'regular file' '$WORK/err'"

echo
if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
