#!/usr/bin/env bash
# bootstrap.sh and the settings file: template, seeding, migration, resolved
# settings. (omnishell and Ghostty output are covered further down.)
# shellcheck disable=SC2034  # OUT and RC are read inside the eval'd check expressions
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

pass() { printf '   ok   %s\n' "$1"; }
fail() { printf '   FAIL %s\n' "$1"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# shellcheck source=../lib/settings.sh
. "$DOTFILES/lib/settings.sh"

# A PATH with only what bootstrap.sh and the library need when sourced.
mkdir -p "$WORK/bin"
for tool in head rm cat cp mkdir basename dirname uname id tr awk grep sed ln readlink cmp mv mktemp tee; do
  ln -s "$(command -v "$tool")" "$WORK/bin/$tool"
done

CONF="$WORK/cfg/config.toml"
OUT=""; RC=0
fresh() { rm -rf "${WORK:?}/cfg" "${WORK:?}/home"; mkdir -p "$WORK/cfg" "$WORK/home/.config"; }
conf() { printf '%s\n' "$@" > "$CONF"; }
# <env assignments> <shell code>: source bootstrap.sh against the test settings file
sh_run() {
  RC=0
  OUT="$(env -i PATH="$WORK/bin" HOME="$WORK/home" DOTFILES_CONFIG="$CONF" BOOTSTRAP_SOURCE_ONLY=1 $1 \
    "$BASH" -c ". '$DOTFILES/bootstrap.sh'; $2" 2>"$WORK/err")" || RC=$?
}

echo ">> template"
TEMPLATE="$DOTFILES/config.toml.example"
for key in $(settings_schema_keys); do
  check "the template documents $key" "grep -qE '^#[[:space:]]*${key##*.}[[:space:]]*=' '$TEMPLATE'"
done
check "the template has everything commented out" "! grep -qvE '^[[:space:]]*(#|\$)' '$TEMPLATE'"
fresh; cp "$TEMPLATE" "$CONF"
sh_run '' 'printf "%s|%s|%s" "$CONF_INSTALL_ZSH" "$CONF_ASSUME_YES" "$CONF_TERMINALS"'
check "the template loads without warnings or values" '[ "$OUT" = "||" ] && [ ! -s "$WORK/err" ]'

echo ">> resolved settings"
fresh; conf '[bootstrap]' 'assume_yes = true'
sh_run '' 'printf %s "$ASSUME_YES"'
check "assume_yes = true sets ASSUME_YES=1"        '[ "$OUT" = 1 ]'
sh_run 'DOTFILES_ASSUME_YES=0' 'printf %s "$ASSUME_YES"'
check "DOTFILES_ASSUME_YES=0 beats the file"        '[ "$OUT" = 0 ]'
fresh; conf '[bootstrap]' 'assume_yes = "maybe"'
sh_run '' 'printf %s "$ASSUME_YES"'
check "an invalid assume_yes falls back to 0"       '[ "$OUT" = 0 ]'
check "an invalid assume_yes warns"                 'grep -q "invalid bootstrap.assume_yes" "$WORK/err"'
fresh; conf '[bootstrap]' 'terminals = ["rootloops", "nonexistent"]'
sh_run '' 'printf "%s " "${PACKAGES[@]}"'
check "terminals adds an existing package dir"      'grep -qw rootloops <<< "$OUT"'
check "terminals ignores a missing dir"             '! grep -qw nonexistent <<< "$OUT"'
fresh; conf '[bootstrap]' 'install_zsh = "yes"'
sh_run '' '_install_zsh_mode'
check "install_zsh comes from the file"             '[ "$OUT" = yes ]'
sh_run 'DOTFILES_INSTALL_ZSH=no' '_install_zsh_mode'
check "DOTFILES_INSTALL_ZSH beats the file"         '[ "$OUT" = no ]'
sh_run 'DOTFILES_INSTALL_ZSH=bogus' '_install_zsh_mode'
check "an invalid env value warns and falls back to the file" '[ "$OUT" = yes ] && grep -q "DOTFILES_INSTALL_ZSH" "$WORK/err"'

echo ">> seeding"
fresh; rm -rf "$WORK/cfg"
sh_run '' 'seed_bootstrap_config'
check "creates the file and its directory from the template" 'cmp -s "$CONF" "$TEMPLATE"'
printf '[bootstrap]\ninstall_zsh = "yes"\n' > "$CONF"
sh_run '' 'seed_bootstrap_config'
check "never overwrites an existing file"           '[ "$(cat "$CONF")" = "$(printf "[bootstrap]\ninstall_zsh = \"yes\"")" ]'

echo ">> migration of bootstrap.conf"
fresh; rm -f "$CONF"
printf 'INSTALL_ZSH=yes\n' > "$WORK/cfg/bootstrap.conf"
sh_run '' '_install_zsh_mode'
check "the legacy value is picked up in the same run" '[ "$(tail -n 1 <<< "$OUT")" = yes ]'
check "config.toml exists and the legacy file is renamed" '[ -f "$CONF" ] && [ -f "$WORK/cfg/bootstrap.conf.migrated" ] && [ ! -e "$WORK/cfg/bootstrap.conf" ]'
cp "$CONF" "$WORK/first"
sh_run '' 'true'
check "a second run changes nothing"                'cmp -s "$CONF" "$WORK/first"'
fresh; rm -f "$CONF"
cp "$DOTFILES/config.toml.example" "$WORK/cfg/bootstrap.conf"
sh_run '' 'seed_bootstrap_config'
check "a commented-out legacy file leads to the plain template" 'cmp -s "$CONF" "$TEMPLATE"'

echo ">> omnishell config"
cat > "$WORK/bin/omnishell" <<'SH'
#!/bin/sh
echo "$*" >> "$OMNISHELL_LOG"
case "$1" in
  validate) exit "${OMNISHELL_VALIDATE_RC:-0}" ;;
esac
exit 0
SH
chmod +x "$WORK/bin/omnishell"
LOG="$WORK/omnishell.log"
OMNI_CONF="$WORK/home/.config/omnishell/config.toml"

fresh; : > "$LOG"; conf '[modules.history.options]' 'size = 10'
sh_run "OMNISHELL_LOG=$LOG" 'apply_omnishell'
check "apply_omnishell writes the merged config"      'grep -qx "size = 10" "$OMNI_CONF" && ! grep -q 50000 "$OMNI_CONF"'
check "the rest of the default is kept"               'grep -q "^\[modules.starship\]" "$OMNI_CONF" && grep -q "^\[omnishell\]" "$OMNI_CONF"'
check "omnishell validate runs, before apply"         '[ "$(grep -n "^validate" "$LOG" | cut -d: -f1)" -lt "$(grep -n "^apply" "$LOG" | cut -d: -f1)" ]'
cp "$OMNI_CONF" "$WORK/omni.first"
: > "$LOG"
sh_run "OMNISHELL_LOG=$LOG" 'apply_omnishell'
check "a second run writes the identical config"      'cmp -s "$OMNI_CONF" "$WORK/omni.first"'

fresh; conf '[bootstrap]' 'install_zsh = "ask"'
sh_run "OMNISHELL_LOG=$LOG" 'apply_omnishell'
check "without overrides the config equals the repo default" 'cmp -s "$OMNI_CONF" "$DOTFILES/omnishell/config.toml"'

fresh; : > "$LOG"; conf '[omnishell]' 'shells = ["zsh"]'
sh_run "OMNISHELL_LOG=$LOG OMNISHELL_VALIDATE_RC=2" 'apply_omnishell; echo not-reached'
check "a failing validate aborts with exit 2"         '[ "$RC" = 2 ] && ! grep -q not-reached <<< "$OUT"'
check "the message points at the settings file"       'grep -q "config.toml" "$WORK/err"'
check "apply is not reached"                          '! grep -q "^apply" "$LOG"'

echo ">> ghostty settings"
GHOSTTY_OUT="$WORK/home/.config/ghostty-settings.conf"
fresh; conf '[ghostty]' 'font_size = 13' 'font_family = "Cascadia Mono NF"'
sh_run '' 'render_ghostty_settings'
check "writes the generated include"                  'grep -qx "font-size = 13" "$GHOSTTY_OUT" && grep -qx "font-family = \"Cascadia Mono NF\"" "$GHOSTTY_OUT"'
check "the first line marks it as generated"          'head -n 1 "$GHOSTTY_OUT" | grep -q "^# GENERATED"'
conf '[bootstrap]' 'install_zsh = "ask"'
sh_run '' 'render_ghostty_settings'
check "clearing the settings removes the generated file" '[ ! -e "$GHOSTTY_OUT" ]'
fresh; conf '[ghostty]' 'font_size = 13'
printf 'font-size = 99\n' > "$GHOSTTY_OUT"
sh_run '' 'render_ghostty_settings'
check "a hand-written file is left untouched"         '[ "$(cat "$GHOSTTY_OUT")" = "font-size = 99" ]'
check "and the user is told"                          'grep -q "not generated by bootstrap.sh" "$WORK/err"'

fresh; conf '[ghostty]' 'keybinds = "linux"'
sh_run '' 'OS=Darwin; setup_ghostty_keybinds'
check "[ghostty] keybinds picks the scheme"           '[ "$(readlink "$WORK/home/.config/ghostty-keybinds.conf")" = "$DOTFILES/ghostty/.config/ghostty/keybinds-linux.conf" ]'
sh_run 'DOTFILES_GHOSTTY_KEYBINDS=mac' 'OS=Darwin; setup_ghostty_keybinds'
check "DOTFILES_GHOSTTY_KEYBINDS beats the file"      '[ "$(readlink "$WORK/home/.config/ghostty-keybinds.conf")" = "$DOTFILES/ghostty/.config/ghostty/keybinds-mac.conf" ]'
check "the Ghostty config includes the generated file before ghostty.local" \
  '[ "$(grep -n "^config-file" "$DOTFILES/ghostty/.config/ghostty/config" | cut -d: -f2- | tr -d " ?" | tr "\n" " ")" = "config-file=~/.config/ghostty-keybinds.conf config-file=~/.config/ghostty-settings.conf config-file=~/.config/ghostty.local " ]'

echo
if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
