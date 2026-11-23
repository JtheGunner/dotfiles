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

echo ">> skip lists"
fresh; conf '[bootstrap]' 'skip_packages = ["FZF", "bat", "fzf"]'
sh_run '' 'skipped_packages'
check "names are lower-cased, de-duplicated, in input order" '[ "$OUT" = "fzf bat" ] && [ ! -s "$WORK/err" ]'

fresh; conf '[bootstrap]' 'skip_stow = ["git"]'
sh_run 'DOTFILES_SKIP_STOW=tmux' 'skipped_stow'
check "the environment beats the file" '[ "$(tail -1 <<<"$OUT")" = tmux ]'
sh_run 'DOTFILES_SKIP_STOW=' 'skipped_stow'
check "an empty environment value falls back to the file" '[ "$(tail -1 <<<"$OUT")" = git ]'

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
check "skipped packages leave PACKAGES" 'grep -q "^zsh git ghostty" <<<"$(tail -1 <<<"$OUT")" && ! tail -1 <<<"$OUT" | grep -qE "(^| )(tmux|bat)( |$)"'
check "each skipped package is logged exactly once" '[ "$(grep -c "skipping stow package tmux (skip_stow)" <<<"$OUT")" = 1 ] && [ "$(grep -c "skipping stow package bat (skip_stow)" <<<"$OUT")" = 1 ]'

sh_run 'DOTFILES_TERMINALS=omnishell' 'echo "${PACKAGES[*]}"'
check "terminals are still added next to a skip" 'tail -1 <<<"$OUT" | grep -q "^zsh git ghostty omnishell"'

sh_run '' 'reload_settings; echo "${PACKAGES[*]}"'
check "reload_settings keeps the filter without logging again" '[ "$(grep -c "skipping stow package tmux" <<<"$OUT")" = 1 ] && ! tail -1 <<<"$OUT" | grep -qE "(^| )tmux( |$)"'

sh_run 'DOTFILES_SKIP_STOW=git' 'echo "${PACKAGES[*]}"; DOTFILES_SKIP_STOW=bat; reload_settings; echo "${PACKAGES[*]}"'
check "reload_settings applies a changed list and logs the new name" '[ "$(grep -c "skipping stow package" <<<"$OUT")" = 2 ] && grep -q "skipping stow package bat" <<<"$OUT" && tail -1 <<<"$OUT" | grep -q "^zsh git tmux ghostty"'

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

echo ">> main guards the generated config per stow package"
STEPS="check_interactive_preconditions check_checkout_consistency seed_bootstrap_config interactive_settings install_deps ensure_zsh ensure_default_shell install_ghostty install_omnishell interactive_modules write_rc_base stow_packages setup_ghostty_keybinds render_ghostty_settings render_tmux_settings render_git_settings setup_git_delta setup_git_identity setup_git_signing_key apply_omnishell wire_shell_d setup_terminal_app finish"
# <skip_stow list>: run main with every step stubbed; OUT lists the steps that ran
main_run() {
  fresh; conf '[bootstrap]' "skip_stow = [$1]"
  sh_run '' 'for f in '"$STEPS"'; do eval "$f() { echo call:$f; }"; done; bash() { :; }; main'
}
main_run ''
check "main runs every step by default" '[ "$(grep -c "^call:" <<<"$OUT")" = 23 ]'
main_run '"git"'
check "skip git drops the four git steps only" '[ "$(grep -c "^call:" <<<"$OUT")" = 19 ] && ! grep -qE "^call:(render_git_settings|setup_git_delta|setup_git_identity|setup_git_signing_key)$" <<<"$OUT"'
main_run '"tmux"'
check "skip tmux drops render_tmux_settings only" '[ "$(grep -c "^call:" <<<"$OUT")" = 22 ] && ! grep -q "^call:render_tmux_settings$" <<<"$OUT"'
main_run '"ghostty"'
check "skip ghostty drops keybinds and settings but keeps install_ghostty" '[ "$(grep -c "^call:" <<<"$OUT")" = 21 ] && ! grep -qE "^call:(setup_ghostty_keybinds|render_ghostty_settings)$" <<<"$OUT" && grep -q "^call:install_ghostty$" <<<"$OUT"'

if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
