#!/usr/bin/env bash
# Optional base packages and stow packages: skip list validation.
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
for tool in head rm cat cp mkdir basename dirname uname id tr awk grep sed ln readlink cmp mv mktemp tee git find chmod stat; do
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

echo ">> skip lists"
fresh; conf '[bootstrap]' 'skip_packages = ["FZF", "bat", "fzf"]'
sh_run '' 'skipped_packages'
check "names are lower-cased, de-duplicated, in input order" '[ "$OUT" = "fzf bat" ] && [ ! -s "$WORK/err" ]'

fresh; conf '[bootstrap]' 'skip_stow = ["git"]'
sh_run 'DOTFILES_SKIP_STOW=tmux' 'skipped_stow'
check "the environment beats the file" '[ "$OUT" = tmux ]'
sh_run 'DOTFILES_SKIP_STOW=' 'skipped_stow'
check "an empty environment value falls back to the file" '[ "$OUT" = git ]'

fresh; conf '[bootstrap]' 'skip_packages = ["stow", "curl", "nope"]'
sh_run '' 'skipped_packages'
check "unknown package names give an empty list" '[ -z "$OUT" ]'
for name in stow curl nope; do
  check "unknown package '$name' is warned about" "grep -q \"ignoring skip_packages '$name': not one of fzf zoxide ripgrep fd bat git-delta\" '$WORK/err'"
done

fresh; conf '[bootstrap]' 'skip_stow = ["zsh"]'
sh_run '' 'skipped_stow'
check "zsh is not skippable" '[ -z "$OUT" ]'
check "skipping zsh warns" "grep -q \"ignoring skip_stow 'zsh': not one of git tmux bat ghostty\" '$WORK/err'"

fresh; : > "$CONF"
sh_run 'DOTFILES_SKIP_STOW=*' 'skipped_stow'
check "a glob is rejected, not expanded" '[ -z "$OUT" ] && grep -q "ignoring skip_stow" "$WORK/err"'

sh_run '' '_is_in_list bat "fzf bat" && ! _is_in_list ba "fzf bat" && echo yes'
check "_is_in_list matches whole words" '[ "$OUT" = yes ]'

echo ">> install_deps honours skip_packages"
CALLS="$WORK/calls"
# <manager: brew|apt> <env assignments>: run install_deps against stub package managers
deps_run() {
  rm -rf "$WORK/stubs"; mkdir -p "$WORK/stubs" "$WORK/cfg" "$WORK/home/.config"; : > "$CALLS"
  local tool
  for tool in "$WORK"/bin/*; do ln -s "$(readlink "$tool")" "$WORK/stubs/$(basename "$tool")"; done
  local stubbed=(stow)
  if [ "$1" = brew ]; then stubbed+=(brew); else stubbed+=(apt-get apt-cache curl cargo); fi
  for tool in "${stubbed[@]}"; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 0\n' "$tool" "$CALLS" > "$WORK/stubs/$tool"
    chmod +x "$WORK/stubs/$tool"
  done
  RC=0
  OUT="$(env -i PATH="$WORK/stubs" HOME="$WORK/home" DOTFILES_CONFIG="$CONF" BOOTSTRAP_SOURCE_ONLY=1 $2 \
    "$BASH" -c ". '$DOTFILES/bootstrap.sh'; SUDO=''; install_deps" 2>"$WORK/err")" || RC=$?
}

fresh
deps_run apt ''
cp "$CALLS" "$WORK/apt-default"
for pkg in stow git-delta fzf zoxide ripgrep fd-find bat; do
  check "default apt installs $pkg" "grep -q '^apt-get install .* $pkg\$' '$CALLS'"
done

conf '[bootstrap]' 'skip_packages = ["fzf", "git-delta"]'
deps_run apt ''
check "apt skips fzf and git-delta" '! grep -q -E "^apt-get install .* (fzf|git-delta)$" "$CALLS"'
for pkg in stow zoxide bat; do
  check "apt still installs $pkg when others are skipped" "grep -q '^apt-get install .* $pkg\$' '$CALLS'"
done
check "the skip is logged" 'grep -q "skipping package fzf (skip_packages)" <<<"$OUT"'
check "every skipped name is logged" 'grep -q "skipping package git-delta (skip_packages)" <<<"$OUT"'

conf '[bootstrap]' 'skip_packages = ["fd"]'
deps_run apt ''
check "apt drops fd-find when fd is skipped" '! grep -q "fd-find" "$CALLS" && grep -q "^apt-get install .* bat\$" "$CALLS"'

deps_run brew ''
check "brew drops fd when fd is skipped" 'grep -qx "brew install stow git-delta fzf zoxide ripgrep bat" "$CALLS"'

conf '[bootstrap]' 'skip_packages = []'
deps_run brew ''
check "brew installs the full list by default" 'grep -qx "brew install stow git-delta fzf zoxide ripgrep fd bat" "$CALLS"'
deps_run apt ''
check "apt calls are unchanged without a skip list" 'grep "^apt-get install" "$CALLS" | cmp -s - <(grep "^apt-get install" "$WORK/apt-default")'

echo ">> skip_stow filters the stow packages"
fresh; : > "$CONF"
sh_run '' 'echo "${PACKAGES[*]}"'
check "PACKAGES default is unchanged" 'grep -q "^zsh git tmux bat ghostty" <<<"$OUT" && ! grep -q "skipping stow" <<<"$OUT"'

fresh; conf '[bootstrap]' 'skip_stow = ["tmux", "bat"]'
sh_run '' 'echo "${PACKAGES[*]}"'
check "skipped packages leave PACKAGES" 'grep -q "^zsh git ghostty" <<<"$OUT" && ! grep -qE "(^| )(tmux|bat)( |$)" <<<"$OUT"'
check "building the packages does not log" '! grep -q "skipping stow" <<<"$OUT"'

sh_run 'DOTFILES_TERMINALS=omnishell' 'echo "${PACKAGES[*]}"'
check "terminals are still added next to a skip" 'grep -q "^zsh git ghostty omnishell" <<<"$OUT"'

sh_run '' 'reload_settings; echo "${PACKAGES[*]}"'
check "reload_settings keeps the filter" '! grep -qE "(^| )tmux( |$)" <<<"$OUT" && ! grep -q "skipping stow" <<<"$OUT"'

sh_run 'DOTFILES_SKIP_STOW=git' 'echo "${PACKAGES[*]}"; DOTFILES_SKIP_STOW=bat; reload_settings; echo "${PACKAGES[*]}"'
check "reload_settings applies a changed list" 'tail -1 <<<"$OUT" | grep -q "^zsh git tmux ghostty" && [ "$(sed -n 1p <<<"$OUT")" = "zsh tmux bat ghostty" ]'

fresh; conf '[bootstrap]' 'skip_packages = ["nope"]' 'skip_stow = ["nada"]'
sh_run '' 'reload_settings; reload_settings; echo "$SKIP_PACKAGES_ACTIVE|$SKIP_STOW_ACTIVE"'
check "an invalid name warns once per settings load" '[ "$(grep -c "ignoring skip_packages" "$WORK/err")" = 3 ] && [ "$(grep -c "ignoring skip_stow" "$WORK/err")" = 3 ]'
sh_run '' 'warn_skipped_packages_needed_by_modules; warn_skipped_packages_needed_by_modules'
check "callers read the validated lists without warning again" '[ "$(grep -c "ignoring skip_packages" "$WORK/err")" = 1 ]'

fresh; : > "$CONF"
sh_run '' 'stow_package_enabled git && echo yes'
check "stow_package_enabled is true by default" '[ "$OUT" = yes ]'
conf '[bootstrap]' 'skip_stow = ["git"]'
sh_run '' 'stow_package_enabled git || echo no; stow_package_enabled tmux && echo tmux-yes'
check "stow_package_enabled is false for a skipped package only" '[ "$(tail -2 <<<"$OUT" | tr "\n" " ")" = "no tmux-yes " ]'

echo ">> install_ghostty is independent of skip_stow"
fresh; conf '[bootstrap]' 'skip_stow = ["ghostty"]'
rm -rf "$WORK/stubs"; mkdir -p "$WORK/stubs"; : > "$CALLS"
for tool in "$WORK"/bin/*; do ln -s "$(readlink "$tool")" "$WORK/stubs/$(basename "$tool")"; done
printf '#!/bin/sh\necho "brew $*" >> "%s"\nexit 0\n' "$CALLS" > "$WORK/stubs/brew"; chmod +x "$WORK/stubs/brew"
RC=0
OUT="$(env -i PATH="$WORK/stubs" HOME="$WORK/home" DOTFILES_CONFIG="$CONF" BOOTSTRAP_SOURCE_ONLY=1 \
  "$BASH" -c ". '$DOTFILES/bootstrap.sh'; OS=Darwin; install_ghostty" 2>"$WORK/err")" || RC=$?
check "install_ghostty still installs the cask" 'grep -qx "brew install --cask ghostty" "$CALLS"'

echo ">> terminal_app_profile switches the Terminal.app import"
# <env assignments> <OS>: run setup_terminal_app with open/defaults/sleep stubbed; OUT is stdout, CALLS the commands run
term_run() {
  : > "$CALLS"
  sh_run "$1" 'OS='"$2"'; open() { echo "open $*" >> "'"$CALLS"'"; }; defaults() { echo "defaults $*" >> "'"$CALLS"'"; }; sleep() { echo "sleep $*" >> "'"$CALLS"'"; }; setup_terminal_app'
}
fresh; : > "$CONF"
term_run '' Darwin
check "the profile is imported by default" 'grep -q "^open " "$CALLS" && grep -q "^defaults " "$CALLS" && ! grep -q "skipping Terminal.app" <<<"$OUT"'

fresh; conf '[bootstrap]' 'terminal_app_profile = false'
term_run '' Darwin
check "file false skips open, defaults and sleep and logs it" '[ ! -s "$CALLS" ] && grep -q "skipping Terminal.app profile (terminal_app_profile)" <<<"$OUT"'

term_run 'DOTFILES_TERMINAL_APP_PROFILE=1' Darwin
check "the environment beats a file false" 'grep -q "^open " "$CALLS"'

fresh; conf '[bootstrap]' 'terminal_app_profile = true'
term_run 'DOTFILES_TERMINAL_APP_PROFILE=no' Darwin
check "the environment can switch it off" '[ ! -s "$CALLS" ] && grep -q "skipping Terminal.app profile" <<<"$OUT"'

fresh; conf '[bootstrap]' 'terminal_app_profile = false'
term_run 'DOTFILES_TERMINAL_APP_PROFILE=bogus' Darwin
check "an invalid value warns and falls back to the file" '[ ! -s "$CALLS" ] && grep -q "invalid DOTFILES_TERMINAL_APP_PROFILE value .bogus." "$WORK/err"'

term_run 'DOTFILES_TERMINAL_APP_PROFILE=' Darwin
check "an empty environment value falls back to the file" '[ ! -s "$CALLS" ]'

for setting in true false; do
  fresh; conf '[bootstrap]' "terminal_app_profile = $setting"
  term_run '' Linux
  check "on Linux nothing runs or is logged (file $setting)" '[ ! -s "$CALLS" ] && ! grep -q "Terminal.app" <<<"$OUT"'
done

echo ">> fix_completion_permissions closes writable Homebrew completion directories"
PREFIX="$WORK/prefix"
# GNU stat first: its -f means "filesystem status" and exits 0, so BSD's -f must come second
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
# a Homebrew-like tree whose share/ and share/zsh/ are writable by the group
open_tree() {
  rm -rf "$PREFIX"
  mkdir -p "$PREFIX/share/zsh/site-functions" "$PREFIX/share/man"
  chmod 775 "$PREFIX/share" "$PREFIX/share/zsh"
  chmod 777 "$PREFIX/share/zsh/site-functions"
  chmod 775 "$PREFIX/share/man"
}
# <env assignments> <code run before the step>: run the step with a stubbed brew
perm_run() {
  sh_run "$1" 'brew() { [ "$1" = --prefix ] && echo "'"$PREFIX"'"; }; '"${2:-:}"'; fix_completion_permissions'
}
fresh; : > "$CONF"; open_tree
perm_run '' ''
check "share, share/zsh and its subdirectories lose group and other write" '[ "$(mode_of "$PREFIX/share")" = 755 ] && [ "$(mode_of "$PREFIX/share/zsh")" = 755 ] && [ "$(mode_of "$PREFIX/share/zsh/site-functions")" = 755 ]'
check "directories outside share/zsh are left alone" '[ "$(mode_of "$PREFIX/share/man")" = 775 ]'
check "the change is logged once" 'grep -q "removed group/other write permission from 3 directories" <<<"$OUT"'
perm_run '' ''
check "a second run changes nothing and prints nothing" '[ "$RC" = 0 ] && [ -z "$OUT" ]'

fresh; conf '[bootstrap]' 'fix_completion_permissions = false'; open_tree
perm_run '' ''
check "file false leaves the permissions and logs the skip" '[ "$(mode_of "$PREFIX/share")" = 775 ] && grep -q "skipping completion directory permissions (fix_completion_permissions)" <<<"$OUT"'
perm_run 'DOTFILES_FIX_COMPLETION_PERMISSIONS=1' ''
check "the environment beats a file false" '[ "$(mode_of "$PREFIX/share")" = 755 ]'

fresh; conf '[bootstrap]' 'fix_completion_permissions = true'; open_tree
perm_run 'DOTFILES_FIX_COMPLETION_PERMISSIONS=no' ''
check "the environment can switch it off" '[ "$(mode_of "$PREFIX/share")" = 775 ]'
fresh; conf '[bootstrap]' 'fix_completion_permissions = false'; open_tree
perm_run 'DOTFILES_FIX_COMPLETION_PERMISSIONS=bogus' ''
check "an invalid value warns and falls back to the file" '[ "$(mode_of "$PREFIX/share")" = 775 ] && grep -q "invalid DOTFILES_FIX_COMPLETION_PERMISSIONS value .bogus." "$WORK/err"'

fresh; conf '[modules.zsh-completions]' 'enabled = false'; open_tree
perm_run '' ''
check "nothing happens while the zsh-completions module is off" '[ "$(mode_of "$PREFIX/share")" = 775 ] && [ -z "$OUT" ]'

fresh; : > "$CONF"; open_tree
sh_run '' 'fix_completion_permissions'
check "nothing happens without Homebrew" '[ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(mode_of "$PREFIX/share")" = 775 ]'

fresh; : > "$CONF"; open_tree
perm_run '' '_dir_is_mine() { return 1; }'
check "a directory owned by someone else is only reported, with the command" '[ "$(mode_of "$PREFIX/share")" = 775 ] && grep -q "sudo chmod go-w" "$WORK/err" && ! grep -q "removed group/other" <<<"$OUT"'

fresh; : > "$CONF"; open_tree
mkdir "$PREFIX/share/zsh/odd dir'x"; chmod 777 "$PREFIX/share/zsh/odd dir'x"
perm_run '' '_dir_is_mine() { return 1; }'
check "a suggested command quotes an unusual directory name" 'grep -qF "sudo chmod go-w $(printf "%q" "$PREFIX/share/zsh/odd dir'"'"'x")" "$WORK/err"'

check "omnishell/config.toml enables the zsh-completions module" 'awk "/^\[modules\.zsh-completions\]/ {f=1; next} /^\[/ {f=0} f && /^enabled = true/ {ok=1} END {exit !ok}" "$DOTFILES/omnishell/config.toml"'

echo ">> main guards the generated config per stow package"
STEPS="check_interactive_preconditions check_checkout_consistency seed_bootstrap_config interactive_settings install_deps ensure_zsh ensure_default_shell install_ghostty install_omnishell interactive_modules write_rc_base stow_packages setup_ghostty_keybinds render_ghostty_settings render_tmux_settings render_git_settings setup_git_delta setup_git_identity setup_git_signing_key fix_completion_permissions apply_omnishell wire_shell_d setup_terminal_app finish"
# <skip_stow list>: run main with every step stubbed; OUT lists the steps that ran
main_run() {
  fresh; conf '[bootstrap]' "skip_stow = [$1]"
  sh_run '' 'for f in '"$STEPS"'; do eval "$f() { echo call:$f; }"; done; bash() { :; }; main'
}
main_run ''
check "main runs every step by default" '[ "$(grep -c "^call:" <<<"$OUT")" = 24 ]'
main_run '"git"'
check "skip git drops the four git steps only" '[ "$(grep -c "^call:" <<<"$OUT")" = 20 ] && ! grep -qE "^call:(render_git_settings|setup_git_delta|setup_git_identity|setup_git_signing_key)$" <<<"$OUT"'
main_run '"tmux", "bat"'
check "main logs each skipped stow package once, in the final settings" '[ "$(grep -c "^.*skipping stow package tmux (skip_stow)" <<<"$OUT")" = 1 ] && [ "$(grep -c "skipping stow package bat (skip_stow)" <<<"$OUT")" = 1 ]'
main_run '"tmux"'
check "skip tmux drops render_tmux_settings only" '[ "$(grep -c "^call:" <<<"$OUT")" = 23 ] && ! grep -q "^call:render_tmux_settings$" <<<"$OUT"'
main_run '"ghostty"'
check "skip ghostty drops keybinds and settings but keeps install_ghostty" '[ "$(grep -c "^call:" <<<"$OUT")" = 22 ] && ! grep -qE "^call:(setup_ghostty_keybinds|render_ghostty_settings)$" <<<"$OUT" && grep -q "^call:install_ghostty$" <<<"$OUT"'

echo ">> warn when a skipped package is still used by an enabled module"
# the warning goes to stderr; sh_run keeps it in $WORK/err
warn_run() { sh_run '' 'warn_skipped_packages_needed_by_modules'; }
fresh; conf '[bootstrap]' 'skip_packages = ["fzf"]'
warn_run
check "skipping fzf names the enabled fzf module" 'grep -q "skipped package fzf is still used by the enabled omnishell module fzf; disable the module in \[modules.fzf\] or install fzf yourself" "$WORK/err"'

fresh; conf '[bootstrap]' 'skip_packages = ["fzf"]' '[modules.fzf]' 'enabled = false'
warn_run
check "disabling the module in the settings file removes the warning" '[ ! -s "$WORK/err" ] && [ -z "$OUT" ]'

fresh; conf '[bootstrap]' 'skip_packages = ["git-delta", "ripgrep"]'
warn_run
check "packages without a module never warn" '[ ! -s "$WORK/err" ]'

fresh; conf '[bootstrap]' 'skip_packages = ["bat"]'
warn_run
check "bat warns once and names the first enabled module" '[ "$(grep -c "skipped package bat" "$WORK/err")" = 1 ] && grep -q "enabled omnishell module colorized-man; disable the module in \[modules.colorized-man\]" "$WORK/err"'

fresh; conf '[bootstrap]' 'skip_packages = ["bat"]' '[modules.colorized-man]' 'enabled = false'
warn_run
check "bat falls through to the next enabled module" 'grep -q "enabled omnishell module modern-aliases" "$WORK/err"'

fresh; conf '[bootstrap]' 'skip_packages = ["fd"]'
warn_run
check "fd maps to modern-aliases" 'grep -q "skipped package fd is still used by the enabled omnishell module modern-aliases" "$WORK/err"'

fresh; : > "$CONF"
warn_run
check "no skip list prints nothing" '[ ! -s "$WORK/err" ] && [ -z "$OUT" ]'

if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
