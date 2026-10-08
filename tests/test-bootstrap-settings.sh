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
for tool in head rm cat cp mkdir basename dirname uname id tr awk grep sed ln readlink cmp mv mktemp tee git; do
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

echo ">> a failing validate keeps the live omnishell config"
fresh; : > "$LOG"; conf '[modules.zoxide]' 'enabled = true'
mkdir -p "$WORK/home/.config/omnishell"; printf 'OLD\n' > "$OMNI_CONF"
sh_run "OMNISHELL_LOG=$LOG OMNISHELL_VALIDATE_RC=2" 'apply_omnishell; echo not-reached'
check "the live config is untouched"        '[ "$(cat "$OMNI_CONF")" = OLD ]'
check "omnishell init is not run either"    '! grep -q "^init" "$LOG"'

echo ">> arguments are parsed before anything is migrated"
fresh; rm -f "$CONF"; printf 'INSTALL_ZSH=yes\n' > "$WORK/cfg/bootstrap.conf"
env -i PATH="$WORK/bin" HOME="$WORK/home" DOTFILES_CONFIG="$CONF" "$BASH" "$DOTFILES/bootstrap.sh" --help >/dev/null 2>&1 || true
check "--help leaves bootstrap.conf alone"          '[ -f "$WORK/cfg/bootstrap.conf" ] && [ ! -e "$CONF" ]'
env -i PATH="$WORK/bin" HOME="$WORK/home" DOTFILES_CONFIG="$CONF" "$BASH" "$DOTFILES/bootstrap.sh" --bogus >/dev/null 2>&1 || true
check "an unknown flag leaves bootstrap.conf alone" '[ -f "$WORK/cfg/bootstrap.conf" ] && [ ! -e "$CONF" ]'

echo ">> --yes beats the settings file and the environment"
fresh; conf '[bootstrap]' 'assume_yes = false'
sh_run '' 'parse_args --yes; resolve_assume_yes; printf %s "$ASSUME_YES"'
check "--yes beats assume_yes = false"              '[ "$OUT" = 1 ]'
sh_run 'DOTFILES_ASSUME_YES=0' 'parse_args --yes; resolve_assume_yes; printf %s "$ASSUME_YES"'
check "--yes beats DOTFILES_ASSUME_YES=0"           '[ "$OUT" = 1 ]'
sh_run '' 'resolve_assume_yes; printf %s "$ASSUME_YES"'
check "without --yes the file's false stays 0"      '[ "$OUT" = 0 ]'

echo ">> terminal names"
fresh; conf '[bootstrap]' 'terminals = ["*"]'
cd "$DOTFILES"
sh_run '' 'printf "%s " "${PACKAGES[@]}"'
cd "$WORK"
check "a glob is not expanded"                      '! grep -qw rootloops <<< "$OUT"'
check "an invalid name is reported"                 'grep -q "ignoring terminal" "$WORK/err"'
fresh
sh_run 'DOTFILES_TERMINALS=../x' 'printf "%s " "${PACKAGES[@]}"'
check "the environment variable is validated too"   'grep -q "ignoring terminal" "$WORK/err"'

echo ">> template"
check "the template lists the unsupported TOML forms" "grep -q 'Not supported' '$TEMPLATE'"

echo ">> tmux settings"
TMUX_OUT="$WORK/home/.config/tmux-settings.conf"
fresh; conf '[tmux]' 'prefix = "C-b"' 'mouse = false' 'history_limit = 20000'
sh_run '' 'render_tmux_settings'
check "writes the generated tmux file"             'grep -qx "set -g prefix C-b" "$TMUX_OUT" && grep -qx "set -g mouse off" "$TMUX_OUT"'
check "its first line marks it as generated"       'head -n 1 "$TMUX_OUT" | grep -q "^# GENERATED"'
cp "$TMUX_OUT" "$WORK/tmux.first"
sh_run '' 'render_tmux_settings'
check "a second run writes the identical file"     'cmp -s "$TMUX_OUT" "$WORK/tmux.first"'
conf '[bootstrap]' 'install_zsh = "ask"'
sh_run '' 'render_tmux_settings'
check "clearing the keys removes the generated file" '[ ! -e "$TMUX_OUT" ]'
fresh; conf '[tmux]' 'mouse = false'
printf 'set -g mouse on\n' > "$TMUX_OUT"
sh_run '' 'render_tmux_settings'
check "a hand-written file is left untouched"      '[ "$(cat "$TMUX_OUT")" = "set -g mouse on" ]'
check "and the user is told"                       'grep -q "not generated by bootstrap.sh" "$WORK/err"'
check "the tracked tmux config includes the generated file, then ~/.tmux.conf.local last" \
  '[ "$(grep "^source-file -q" "$DOTFILES/tmux/.tmux.conf" | tr "\n" " ")" = "source-file -q ~/.config/tmux-settings.conf source-file -q ~/.tmux.conf.local " ] && [ "$(tail -n 1 "$DOTFILES/tmux/.tmux.conf")" = "source-file -q ~/.tmux.conf.local" ]'

echo ">> git settings"
GIT_OUT="$WORK/home/.gitconfig.settings"
gitc() { HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" GIT_CONFIG_NOSYSTEM=1 git config --file "$GIT_OUT" "$@"; }
fresh; conf '[git]' 'user_name = "Ada \"A\" \\ #1"' 'user_email = "ada@example.com"' 'default_branch = "trunk"' 'pull_rebase = true'
sh_run '' 'render_git_settings'
check "writes the values git reads back"           '[ "$(gitc user.email)" = ada@example.com ] && [ "$(gitc init.defaultBranch)" = trunk ] && [ "$(gitc pull.rebase)" = true ]'
check "quotes, a backslash and # survive in user.name" '[ "$(gitc user.name)" = "Ada \"A\" \\ #1" ]'
check "its first line marks it as generated"       'head -n 1 "$GIT_OUT" | grep -q "^# GENERATED"'
cp "$GIT_OUT" "$WORK/git.first"
sh_run '' 'render_git_settings'
check "a second run writes the identical file"     'cmp -s "$GIT_OUT" "$WORK/git.first"'
printf '[include]\n\tpath = %s\n' "$GIT_OUT" > "$WORK/home/.gitconfig"
sh_run 'GIT_CONFIG_NOSYSTEM=1' 'setup_git_identity'
check "a set user_email makes the identity prompt skip itself" 'grep -q "git identity already set (ada@example.com)" <<< "$OUT"'

fresh; mkdir -p "$WORK/home/.ssh"; printf 'ssh-ed25519 AAAA test\n' > "$WORK/home/.ssh/id.pub"
conf '[git]' 'signing_key = "~/.ssh/id.pub"' 'default_branch = "trunk"'
sh_run '' 'render_git_settings'
check "signing_key sets the ssh signing config"    '[ "$(gitc gpg.format)" = ssh ] && [ "$(gitc commit.gpgsign)" = true ] && [ "$(gitc tag.gpgsign)" = true ] && [ "$(gitc user.signingkey)" = "~/.ssh/id.pub" ]'
fresh
conf '[git]' 'signing_key = "~/.ssh/missing.pub"' 'default_branch = "trunk"'
sh_run '' 'render_git_settings'
check "a missing key is skipped with a warning"    'grep -q "signing key not found" "$WORK/err" && [ -z "$(gitc user.signingkey)" ]'
check "the other git values are still written"     '[ "$(gitc init.defaultBranch)" = trunk ]'
conf '[bootstrap]' 'install_zsh = "ask"'
sh_run '' 'render_git_settings'
check "clearing the keys removes the generated file" '[ ! -e "$GIT_OUT" ]'
fresh; conf '[git]' 'editor = "nvim"'
printf '[core]\n\teditor = vim\n' > "$GIT_OUT"
sh_run '' 'render_git_settings'
check "a hand-written file is left untouched"      '[ "$(gitc core.editor)" = vim ]'
check "the tracked git config includes delta, settings, local in order" \
  '[ "$(grep "path = " "$DOTFILES/git/.config/git/config" | tr -d "\t " | tr "\n" " ")" = "path=~/.gitconfig.delta path=~/.gitconfig.settings path=~/.gitconfig.local " ]'

echo ">> render failures are warnings, never fatal"
fresh; conf '[git]' 'user_name = "A"'
: > "$WORK/home/.gitconfig.settings.lock"
sh_run '' 'render_git_settings'
check "a leftover .lock file does not stop the git render" '[ "$RC" = 0 ] && [ "$(gitc user.name)" = A ]'
fresh; conf '[tmux]' 'mouse = false'
rm -rf "$WORK/home/.config"; : > "$WORK/home/.config"
sh_run '' 'render_tmux_settings; echo after'
check "an unwritable tmux target is a warning"     '[ "$RC" = 0 ] && grep -q after <<< "$OUT" && grep -q "could not write" "$WORK/err"'
fresh; conf '[ghostty]' 'font_size = 13'
rm -rf "$WORK/home/.config"; : > "$WORK/home/.config"
sh_run '' 'render_ghostty_settings; echo after'
check "an unwritable ghostty target is a warning"  '[ "$RC" = 0 ] && grep -q after <<< "$OUT" && grep -q "could not write" "$WORK/err"'

echo ">> git identity from the settings"
ident() {   # <config lines...>: render the settings, then run the identity step non-interactively
  fresh; conf "$@"
  printf '[include]\n\tpath = %s\n' "$WORK/home/.gitconfig.settings" > "$WORK/home/.gitconfig"
  sh_run "ASSUME_YES=1 GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME=$WORK/home/.config" 'render_git_settings; setup_git_identity'
}
ident '[git]' 'user_email = "a@b.c"'
check "only user_email set: the identity is not called complete" '! grep -q "already set" <<< "$OUT"'
check "only user_email set: user.name is named as missing"       'grep -q "user.name" "$WORK/err"'
ident '[git]' 'user_name = "A"'
check "only user_name set: user.email is named as missing"       '! grep -q "already set" <<< "$OUT" && grep -q "user.email" "$WORK/err"'
ident '[git]' 'user_name = "A"' 'user_email = "a@b.c"'
check "both set: the identity is complete"                       'grep -q "already set (a@b.c)" <<< "$OUT"'

echo ">> ~/.gitconfig.local overriding the settings"
fresh; conf '[git]' 'user_email = "new@x.y"'
printf '[user]\n\temail = old@x.y\n' > "$WORK/home/.gitconfig.local"
sh_run '' 'render_git_settings'
check "an overriding value in ~/.gitconfig.local is called out"  'grep -q "user.email is also set in" "$WORK/err"'
fresh; conf '[git]' 'user_email = "new@x.y"'
sh_run '' 'render_git_settings'
check "no warning without a local override"                      '! grep -q "also set in" "$WORK/err"'

echo ">> tmux prefix follows the tracked config"
printf 'set -g prefix C-z\nunbind C-b\n' > "$WORK/tracked.conf"
fresh
sh_run '' '_tracked_tmux_prefix "'"$WORK"'/tracked.conf"'
check "the tracked prefix is read from the file"     '[ "$OUT" = C-z ]'
sh_run '' '_tracked_tmux_prefix'
check "the repo tmux.conf sets C-a"                  '[ "$OUT" = C-a ]'
sh_run '' '_tracked_tmux_prefix /nonexistent'
check "a missing file yields nothing and no error"   '[ -z "$OUT" ] && [ "$RC" = 0 ]'
check "config.toml.example explains reloading"       'grep -q "old prefix" "$TEMPLATE"'
check "the README explains reloading"                'grep -q "old prefix" "$DOTFILES/README.md"'

echo ">> one generated-file marker"
GHOSTTY_OUT="$WORK/home/.config/ghostty-settings.conf"
fresh; conf '[ghostty]' 'font_size = 13'
mkdir -p "$WORK/home/.config"
printf '%s\nfont-size = 99\n' '# GENERATED by bootstrap.sh from the [ghostty] table of the settings file - do not edit' > "$GHOSTTY_OUT"
sh_run '' 'render_ghostty_settings'
check "a file with the old Ghostty marker is replaced"   '! grep -q "left untouched" "$WORK/err" && grep -qx "font-size = 13" "$GHOSTTY_OUT"'
check "and now carries the shared marker"                '[ "$(head -n 1 "$GHOSTTY_OUT")" = "# GENERATED by bootstrap.sh from the settings file - do not edit" ]'
printf '%s\nfont-size = 99\n' '# GENERATED by bootstrap.sh from the [ghostty] table of the settings file - do not edit' > "$GHOSTTY_OUT"
conf '[bootstrap]' 'install_zsh = "ask"'
sh_run '' 'render_ghostty_settings'
check "a file with the old marker is removed when no key is set" '[ ! -e "$GHOSTTY_OUT" ]'
printf 'font-size = 99\n' > "$GHOSTTY_OUT"; conf '[ghostty]' 'font_size = 13'
sh_run '' 'render_ghostty_settings'
check "a hand-written Ghostty file is still left alone"  'grep -q "left untouched" "$WORK/err" && grep -qx "font-size = 99" "$GHOSTTY_OUT"'

echo ">> no marker-only git settings file"
fresh; conf '[git]' 'signing_key = "~/.ssh/missing.pub"'
sh_run '' 'render_git_settings'
check "only a missing signing key: no file is written"   '[ ! -e "$GIT_OUT" ]'
printf '%s\n' '# GENERATED by bootstrap.sh from the settings file - do not edit' > "$GIT_OUT"
sh_run '' 'render_git_settings'
check "an old marker-only file is removed"               '[ ! -e "$GIT_OUT" ]'
fresh; conf '[git]' 'signing_key = "~/.ssh/missing.pub"' 'editor = "nvim"'
sh_run '' 'render_git_settings'
check "with another value the file is still written"     '[ "$(gitc core.editor)" = nvim ]'

echo
if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
