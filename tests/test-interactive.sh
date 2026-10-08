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
for tool in head rm cat cp mkdir basename dirname uname id tr awk grep sed ln readlink cmp mv tee git diff sort; do
  ln -s "$(command -v "$tool")" "$WORK/bin/$tool"
done
# macOS mktemp ignores TMPDIR when it gets no template; this one honours it, so the tests can see leaks
printf '#!/bin/sh\nREAL="%s"\ncase "$*" in\n  "") exec "$REAL" "${TMPDIR:-/tmp}/tmp.XXXXXX" ;;\n  "-d") exec "$REAL" -d "${TMPDIR:-/tmp}/tmp.XXXXXX" ;;\nesac\nexec "$REAL" "$@"\n' "$(command -v mktemp)" > "$WORK/bin/mktemp"
chmod +x "$WORK/bin/mktemp"

CONF="$WORK/cfg/config.toml"
OUT=""; RC=0
fresh() { rm -rf "${WORK:?}/cfg" "${WORK:?}/home" "${WORK:?}/tmp"; mkdir -p "$WORK/cfg" "$WORK/home/.config" "$WORK/tmp"; cp "$DOTFILES/config.toml.example" "$CONF"; }
# <stdin text> <shell code>: run the code with bootstrap.sh sourced and a terminal
# assumed; the text (printf %b) is the user's typing
ix_run() {
  RC=0
  OUT="$(printf '%b' "$1" | env -i PATH="$WORK/bin" HOME="$WORK/home" DOTFILES_CONFIG="$CONF" TMPDIR="$WORK/tmp" BOOTSTRAP_SOURCE_ONLY=1 \
    "$BASH" -c ". '$DOTFILES/bootstrap.sh'; INTERACTIVE_FLAG=1; interactive_tty() { return 0; }; $2" 2>"$WORK/err")" || RC=$?
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

# the user's typing: N empty answers
empties() { local i; for ((i = 0; i < $1; i++)); do printf '\\n'; done; }

echo ">> prompts: Enter keeps everything"
fresh
ix_run "$(empties 20)" 'interactive_settings; echo AFTER'
check "Enter at every prompt leaves the file byte-identical" 'cmp -s "$CONF" "$DOTFILES/config.toml.example"'
check "no backup is made and the run continues"             '[ ! -e "$CONF.bak" ] && grep -q AFTER <<< "$OUT"'
check "the prompts show table.key and unset"                'grep -q "bootstrap.install_zsh" <<< "$OUT" && grep -q "\[unset\]" <<< "$OUT"'

echo ">> prompts: answers are validated and written"
fresh
ix_run "yes\n\nfoot, kitty\nbogus\nlinux\n$(empties 16)y\n" 'interactive_settings; printf "%s|%s" "$CONF_INSTALL_ZSH" "$CONF_TERMINALS"'
check "the run succeeds and reloads the settings"           '[ "$RC" = 0 ] && grep -q "yes|foot kitty\$" <<< "$OUT"'
check "install_zsh is written"                              'grep -qx "install_zsh = \"yes\"" "$CONF"'
check "the list is written"                                 'grep -qx "terminals = \[\"foot\", \"kitty\"\]" "$CONF"'
check "an invalid answer is asked again"                    'grep -q "invalid value for ghostty.keybinds" "$WORK/err" || grep -q "invalid value for ghostty.keybinds" <<< "$OUT"'
check "the valid retry is written"                          'grep -qx "keybinds = \"linux\"" "$CONF" && ! grep -q bogus "$CONF"'
check "the old file is kept as .bak"                        'cmp -s "$CONF.bak" "$DOTFILES/config.toml.example"'
check "the template comments are still there"               'grep -q "^# Install zsh when it is missing" "$CONF"'

echo ">> prompts: a dash clears a key"
fresh
printf '[bootstrap]\ninstall_zsh = "yes"\n# note\n' > "$CONF"
ix_run "-\n$(empties 19)y\n" 'interactive_settings'
check "the key is gone and the rest stays"                  '! grep -q install_zsh "$CONF" && grep -qx "# note" "$CONF" && grep -qx "\[bootstrap\]" "$CONF"'

echo ">> review: declining and end of input"
fresh
ix_run "yes\n$(empties 19)n\n" 'interactive_settings; echo AFTER'
check "n ends the run with exit 0"                          '[ "$RC" = 0 ] && ! grep -q AFTER <<< "$OUT" && grep -q "nothing written" <<< "$OUT"'
check "n leaves the file untouched"                         'cmp -s "$CONF" "$DOTFILES/config.toml.example" && [ ! -e "$CONF.bak" ]'
check "the diff was shown"                                  'grep -q "^+install_zsh = \"yes\"" <<< "$OUT"'
fresh
ix_run "yes\n" 'interactive_settings; echo AFTER'
check "end of input aborts with exit 1 and a message"       '[ "$RC" = 1 ] && grep -q "input closed" "$WORK/err" && ! grep -q AFTER <<< "$OUT"'
check "and writes nothing"                                  'cmp -s "$CONF" "$DOTFILES/config.toml.example"'

echo ">> modules: the TUI hand-over"
printf '#!/bin/sh\necho "$*" >> "%s/omnishell.log"\ncase "$1" in\n  validate) exit 0 ;;\n  tui) . "%s/tui.sh" ;;\nesac\n' "$WORK" "$WORK" > "$WORK/bin/omnishell"
chmod +x "$WORK/bin/omnishell"
LIVE="$WORK/home/.config/omnishell/config.toml"

fresh; : > "$WORK/omnishell.log"
printf 'printf "\\n[modules.testmod]\\nenabled = true\\n" >> "%s"\n' "$LIVE" > "$WORK/tui.sh"
ix_run "y\n" 'interactive_modules; echo AFTER'
check "a module added in the TUI is written to the file"    'grep -qx "\[modules.testmod\]" "$CONF" && grep -qx "enabled = true" "$CONF"'
check "the tui ran once and apply never ran"                '[ "$(grep -c "^tui" "$WORK/omnishell.log")" = 1 ] && ! grep -q "^apply" "$WORK/omnishell.log"'
check "the old file is kept as .bak"                        'cmp -s "$CONF.bak" "$DOTFILES/config.toml.example"'
check "the run continues"                                   'grep -q AFTER <<< "$OUT"'

fresh
: > "$WORK/tui.sh"
ix_run "" 'interactive_modules; echo AFTER'
check "a TUI that changes nothing leaves the file alone"    'cmp -s "$CONF" "$DOTFILES/config.toml.example" && grep -q "no changes" <<< "$OUT" && grep -q AFTER <<< "$OUT"'

fresh
printf '[modules.starship]\nenabled = false\n' >> "$CONF"
printf 'cp "%s/omnishell/config.toml" "%s"\n' "$DOTFILES" "$LIVE" > "$WORK/tui.sh"
ix_run "y\n" 'interactive_modules'
check "reverting a module to the default drops its override" '! grep -q "modules.starship" "$CONF"'

fresh
printf 'printf "\\n[modules.testmod]\\nenabled = true\\n" >> "%s"\n' "$LIVE" > "$WORK/tui.sh"
ix_run "n\n" 'interactive_modules; echo AFTER'
check "n keeps the file and ends the run with exit 0"       '[ "$RC" = 0 ] && ! grep -q AFTER <<< "$OUT" && cmp -s "$CONF" "$DOTFILES/config.toml.example"'
check "the diff note says the machine may be ahead"         'grep -q "already follows" <<< "$OUT"'

fresh
printf 'exit 3\n' > "$WORK/tui.sh"
ix_run "" 'interactive_modules; echo AFTER'
check "a failing TUI stops with its exit code"              '[ "$RC" = 3 ] && ! grep -q AFTER <<< "$OUT" && grep -q "exited with 3" "$WORK/err"'
check "and the file is untouched"                           'cmp -s "$CONF" "$DOTFILES/config.toml.example"'

fresh; : > "$WORK/omnishell.log"
ix_run "" 'INTERACTIVE_FLAG=; interactive_settings; interactive_modules; echo AFTER'
check "both steps do nothing without --interactive"         '[ "$RC" = 0 ] && grep -q AFTER <<< "$OUT" && [ ! -s "$WORK/omnishell.log" ] && cmp -s "$CONF" "$DOTFILES/config.toml.example"'

echo ">> docs"
check "the README names --interactive"                      'grep -q -- "--interactive" "$DOTFILES/README.md"'
check "the README names the 0.7.0 floor"                    'grep -q "omnishell 0.7.0 or newer" "$DOTFILES/README.md" && ! grep -q "0\.6\.0" "$DOTFILES/README.md"'
check "the template mentions --interactive"                 'grep -q -- "--interactive" "$DOTFILES/config.toml.example"'

echo ">> modules: a declined selection does not linger"
fresh
printf 'printf "\\n[modules.testmod]\\nenabled = true\\n" >> "%s"\n' "$LIVE" > "$WORK/tui.sh"
ix_run "n\n" 'interactive_modules'
check "n resets the live omnishell config to the settings file" '! grep -q testmod "$LIVE"'
check "and says what happened"                                 'grep -q "left as it was" <<< "$OUT"'
fresh
ix_run "" 'interactive_modules'
check "end of input aborts with exit 1"                        '[ "$RC" = 1 ]'
check "end of input resets the live omnishell config too"     '! grep -q testmod "$LIVE"'
check "the message does not claim nothing was installed"       'grep -q "was not changed" "$WORK/err" && ! grep -q "nothing was written or installed" "$WORK/err"'
check "the README tells both n cases apart"                    'grep -q "settings diff" "$DOTFILES/README.md" && grep -q "module diff" "$DOTFILES/README.md"' 

echo ">> hardening: temp files, atomic write, one backup"
fresh
ix_run "yes\n$(empties 19)" 'interactive_settings'
check "end of input at the settings review leaves no temp file" '[ "$RC" = 1 ] && [ -z "$(ls -A "$WORK/tmp")" ]'
fresh
printf 'printf "\\n[modules.testmod]\\nenabled = true\\n" >> "%s"\n' "$LIVE" > "$WORK/tui.sh"
ix_run "" 'interactive_modules'
check "end of input at the module review leaves no temp file"   '[ "$RC" = 1 ] && [ -z "$(ls -A "$WORK/tmp")" ]'
fresh
ix_run "yes\n$(empties 19)n\n" 'interactive_settings'
check "declining leaves no temp file either"                    '[ "$RC" = 0 ] && [ -z "$(ls -A "$WORK/tmp")" ]'
fresh; chmod 644 "$CONF"
ix_run "yes\n$(empties 19)y\n" 'interactive_settings'
check "the write leaves no staging file next to the settings file" '[ "$(ls "$WORK/cfg" | tr "\n" " ")" = "config.toml config.toml.bak " ]'
check "and keeps the file mode"                                 '[ "$(ls -l "$CONF" | cut -c1-10)" = "-rw-r--r--" ]'
fresh
ix_run "yes\n$(empties 19)y\ny\n" 'interactive_settings; interactive_modules'
check "both steps write: both changes are in the file"          'grep -qx "install_zsh = \"yes\"" "$CONF" && grep -qx "\[modules.testmod\]" "$CONF"'
check "and the .bak still holds the original"                   'cmp -s "$CONF.bak" "$DOTFILES/config.toml.example"'

echo
if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
