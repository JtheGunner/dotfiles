#!/usr/bin/env bash
# Post-conditions of a finished `./bootstrap.sh` run. Run it only on a
# disposable machine (CI, a container) - it inspects the real $HOME:
#
#   ./bootstrap.sh --yes && ./bootstrap.sh --yes && tests/bootstrap-smoke.sh
#
# (bootstrap twice: every check below must also hold after a re-run.)
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

pass() { printf '   ok   %s\n' "$1"; }
fail() { printf '   FAIL %s\n' "$1"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
count() { grep -c -- "$1" "$2" || true; }

echo ">> rc files"
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  name="$(basename "$rc")"
  check "$name is a real file, not a symlink" "[ -f '$rc' ] && [ ! -L '$rc' ]"
  check "$name has one dotfiles:base block" "[ \"\$(count '# >>> dotfiles:base >>>' '$rc')\" = 1 ]"
  check "$name has one shell.d block" "[ \"\$(count '# >>> dotfiles >>>' '$rc')\" = 1 ]"
  # omnishell only hooks shells that are installed
  if [ "$name" = .bashrc ] || command -v zsh >/dev/null 2>&1; then
    check "$name has one omnishell block" "[ \"\$(count '# >>> omnishell' '$rc')\" = 1 ]"
  else
    echo "   skip $name omnishell block (zsh not installed)"
  fi
done

echo ">> stow links"
for path in .config/git/config .config/git/ignore .tmux.conf .config/bat/config .config/ghostty/config .zprofile; do
  check "$path resolves into this checkout" \
    "case \"\$(realpath '$HOME/$path')\" in '$(realpath "$DOTFILES")'/*) true ;; *) false ;; esac"
done

echo ">> omnishell"
check "config.toml is the repo's" \
  "cmp -s '$DOTFILES/omnishell/config.toml' '${XDG_CONFIG_HOME:-$HOME/.config}/omnishell/config.toml'"

echo ">> git"
check "no identity is shipped" "! git config --global user.email >/dev/null"
check "git config --global targets ~/.gitconfig" "[ -f '$HOME/.gitconfig' ]"

echo ">> interactive bash"
type_of() { bash -ic "type -t $1" 2>/dev/null || true; }
check "shell.d fragments load (whatsonport)" "[ \"\$(type_of whatsonport)\" = function ]"
if command -v broot >/dev/null 2>&1; then
  check "omnishell broot module loads (br)" "[ \"\$(type_of br)\" = function ]"
else
  echo "   skip br (broot not installed)"
fi

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
