#!/usr/bin/env bash
# bootstrap.sh --interactive: arguments, preconditions, prompts, settings update and
# the hand-over to omnishell tui.
# shellcheck disable=SC2034  # OUT and RC are read inside the eval'd check expressions
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

pass() { printf '   ok   %s\n' "$1"; }
fail() { printf '   FAIL %s\n' "$1"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# A PATH with only what bootstrap.sh and the library need when sourced.
mkdir -p "$WORK/bin"
for tool in head rm cat cp mkdir basename dirname uname id tr awk grep sed ln readlink cmp mv mktemp tee git diff sort; do
  ln -s "$(command -v "$tool")" "$WORK/bin/$tool"
done

CONF="$WORK/cfg/config.toml"
OUT=""; RC=0
fresh() { rm -rf "${WORK:?}/cfg" "${WORK:?}/home"; mkdir -p "$WORK/cfg" "$WORK/home/.config"; cp "$DOTFILES/config.toml.example" "$CONF"; }
# <stdin text> <shell code>: run the code with bootstrap.sh sourced and a terminal
# assumed; the text (printf %b) is the user's typing
ix_run() {
  RC=0
  OUT="$(printf '%b' "$1" | env -i PATH="$WORK/bin" HOME="$WORK/home" DOTFILES_CONFIG="$CONF" BOOTSTRAP_SOURCE_ONLY=1 \
    "$BASH" -c ". '$DOTFILES/bootstrap.sh'; interactive_tty() { return 0; }; $2" 2>"$WORK/err")" || RC=$?
}

echo ">> arguments and preconditions"
fresh
RC=0; OUT="$(env -i PATH="$PATH" HOME="$WORK/home" DOTFILES_CONFIG="$CONF" "$DOTFILES/bootstrap.sh" --interactive --yes 2>&1 </dev/null)" || RC=$?
check "--interactive with --yes is an error"          '[ "$RC" = 2 ] && grep -q "contradict" <<< "$OUT"'
RC=0; OUT="$(env -i PATH="$PATH" HOME="$WORK/home" DOTFILES_CONFIG="$CONF" "$DOTFILES/bootstrap.sh" --interactive 2>&1 </dev/null)" || RC=$?
check "--interactive without a terminal is an error"  '[ "$RC" = 2 ] && grep -q "needs a terminal" <<< "$OUT"'
check "the error names the settings file"             'grep -qF "$CONF" <<< "$OUT"'
check "and nothing was written"                       '[ ! -e "$WORK/home/.zshrc" ] && cmp -s "$CONF" "$DOTFILES/config.toml.example"'
check "--help lists --interactive"                    '"$DOTFILES/bootstrap.sh" --help | grep -q -- --interactive'
ix_run '' 'printf %s "$OMNISHELL_MIN_VERSION"'
check "omnishell 0.7.0 is the floor"                  '[ "$OUT" = 0.7.0 ]'

echo ">> reloading settings"
fresh
ix_run '' 'printf "[bootstrap]\nterminals = [\"bash\"]\ninstall_zsh = \"yes\"\n" > "$BOOTSTRAP_CONFIG"; reload_settings; printf "%s|%s" "$CONF_INSTALL_ZSH" "${PACKAGES[*]}"'
check "reload_settings picks up values and packages"  '[ "$OUT" = "yes|zsh git tmux bat ghostty bash" ]'

echo
if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
