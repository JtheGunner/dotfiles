#!/usr/bin/env bash
# bootstrap.sh checkout consistency: every run checks that the rc base blocks
# and the stow links all point at the checkout it runs from, and asks once
# before switching them over.
# SC2034: OUT / expected_rest are read inside the eval'd check expressions.
# SC2088: "~/..." in check names and patterns is display text, not a path.
# shellcheck disable=SC2034,SC2088
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

pass() { printf '   ok   %s\n' "$1"; }
fail() { printf '   FAIL %s\n' "$1"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

PACKAGES="zsh git tmux bat ghostty"

# a fake checkout: this repo's bootstrap.sh + its stow packages
make_checkout() {
  mkdir -p "$1"
  cp "$REPO/bootstrap.sh" "$1/"
  for pkg in $PACKAGES; do cp -R "$REPO/$pkg" "$1/"; done
}
make_checkout "$WORK/A"
make_checkout "$WORK/B"

# fresh $HOME per case
new_home() {
  H="$WORK/home-$1"
  mkdir -p "$H/.config"
  TTY="$WORK/tty-$1"
  : > "$TTY"
}

# rc file with a base block for checkout $2, surrounded by other content
write_rc() {   # <rc> <checkout> <lib>
  cat > "$1" <<EOF
# >>> dotfiles:base >>>
export DOTFILES="$2"
[ -r "\$DOTFILES/$3" ] && . "\$DOTFILES/$3"
# <<< dotfiles:base <<<

# >>> omnishell >>>
eval "\$(omnishell init zsh)"
# <<< omnishell <<<

alias mine='echo my own line'   # trailing spaces and no final newline follow
# >>> dotfiles >>>
for _f in "\$DOTFILES"/shell.d/*.sh; do
  [ -r "\$_f" ] && . "\$_f"
done
# <<< dotfiles <<<
EOF
  printf 'export LAST_LINE=1' >> "$1"
}
write_rcs() {  # <checkout>
  write_rc "$H/.zshrc"  "$1" zsh/zshrc.zsh
  write_rc "$H/.bashrc" "$1" bash/bashrc.bash
}

# relative symlinks like stow makes: leaf links and folded package dirs
link_stow() {  # <checkout name under $WORK>
  local c="$1"
  ln -sfn "../$c/zsh/.zprofile"                 "$H/.zprofile"
  ln -sfn "../$c/tmux/.tmux.conf"               "$H/.tmux.conf"
  ln -sfn "../../$c/git/.config/git"            "$H/.config/git"
  ln -sfn "../../$c/bat/.config/bat"            "$H/.config/bat"
  ln -sfn "../../$c/ghostty/.config/ghostty"    "$H/.config/ghostty"
}

# run check_checkout_consistency from checkout $1; answers come from $TTY
OUT=""; RC=0
run_check() {  # <checkout dir> [env assignments...]
  local dir="$1"; shift
  RC=0
  OUT="$(env -u DOTFILES_ASSUME_YES -u ASSUME_YES HOME="$H" DOTFILES_TTY="$TTY" \
    BOOTSTRAP_SOURCE_ONLY=1 "$@" "$BASH" -c ". '$dir/bootstrap.sh'; check_checkout_consistency; write_rc_base" 2>&1)" || RC=$?
}
answer() { printf '%s\n' "$1" > "$TTY"; }
prompts() { grep -o "switch everything to" "$TTY" | wc -l | tr -d " "; }
base_path() { awk '/^# >>> dotfiles:base >>>/{b=1;next} /^# <<< dotfiles:base <<</{b=0} b && /^export DOTFILES=/{sub(/^export DOTFILES="/,"");sub(/"$/,"");print}' "$1"; }
links_of() { (cd "$H" && for l in .zprofile .tmux.conf .config/git .config/bat .config/ghostty; do
  if [ -L "$l" ]; then printf '%s -> %s\n' "$l" "$(readlink "$l")"; else printf '%s absent\n' "$l"; fi; done); }
snapshot() { { cat "$H/.zshrc" "$H/.bashrc"; links_of; ls -a "$H"; } | cksum; }
stow_points_to() {  # <checkout dir>: every link resolves into it
  local self; self="$(cd "$1" && pwd -P)"
  [ "$(realpath "$H/.tmux.conf")" = "$self/tmux/.tmux.conf" ] &&
  [ "$(realpath "$H/.config/ghostty")" = "$self/ghostty/.config/ghostty" ]
}
no_links_left() { for l in .zprofile .tmux.conf .config/git .config/bat .config/ghostty; do [ ! -L "$H/$l" ] || return 1; done; }

echo ">> consistent install"
new_home consistent; write_rcs "$WORK/B"; link_stow B
before="$(snapshot)"
run_check "$WORK/B"
check "exits 0" "[ $RC -eq 0 ]"
check "no warning" "! grep -q 'another dotfiles checkout' <<<\"\$OUT\""
check "no question" "[ \"\$(prompts)\" = 0 ]"
check "base block reported as already present" "grep -q '.zshrc base block already present' <<<\"\$OUT\""
check "nothing changed" "[ \"\$(snapshot)\" = '$before' ]"

echo ">> only the rc files point elsewhere"
new_home rc-only; write_rcs "$WORK/A"; link_stow B; answer y
run_check "$WORK/B"
check "exits 0" "[ $RC -eq 0 ]"
check "names ~/.zshrc with its target" "grep -q '~/.zshrc .*$WORK/A' <<<\"\$OUT\""
check "names ~/.bashrc with its target" "grep -q '~/.bashrc .*$WORK/A' <<<\"\$OUT\""
check "does not list stow links" "! grep -q '.tmux.conf' <<<\"\$OUT\""
check "asks once" "[ \"\$(prompts)\" = 1 ]"
check "~/.zshrc now points at B" "[ \"\$(base_path '$H/.zshrc')\" = '$WORK/B' ]"
check "~/.bashrc now points at B" "[ \"\$(base_path '$H/.bashrc')\" = '$WORK/B' ]"
check "backs up ~/.zshrc first" "ls '$H'/.zshrc.pre-dotfiles.* >/dev/null 2>&1"
check "backup holds the old path" "grep -qs 'DOTFILES=\"$WORK/A\"' '$H'/.zshrc.pre-dotfiles.*"
check "stow links untouched" "stow_points_to '$WORK/B'"

echo ">> rest of the rc file kept byte for byte"
expected_rest="$(write_rc "$WORK/expected" "$WORK/B" zsh/zshrc.zsh; cat "$WORK/expected"; printf x)"
check "~/.zshrc equals a fresh block for B plus the untouched rest" \
  "[ \"\$(cat '$H/.zshrc'; printf x)\" = \"\$expected_rest\" ]"

echo ">> only the stow links point elsewhere"
new_home stow-only; write_rcs "$WORK/B"; link_stow A; answer y
rc_before="$(cat "$H/.zshrc" "$H/.bashrc" | cksum)"
run_check "$WORK/B"
check "exits 0" "[ $RC -eq 0 ]"
check "names a leaf link with its target" "grep -q '~/.tmux.conf .*$WORK/A' <<<\"\$OUT\""
check "names a folded link with its target" "grep -q '~/.config/ghostty .*$WORK/A' <<<\"\$OUT\""
check "does not list the rc files" "! grep -q '~/.zshrc ' <<<\"\$OUT\""
check "asks once" "[ \"\$(prompts)\" = 1 ]"
check "removes the old links (stow re-links them)" "no_links_left"
check "leaves the rc files alone" "[ \"\$(cat '$H/.zshrc' '$H/.bashrc' | cksum)\" = '$rc_before' ]"
check "writes no rc backup" "! ls '$H'/.zshrc.pre-dotfiles* >/dev/null 2>&1"

echo ">> rc files and stow links both point elsewhere"
new_home both; write_rcs "$WORK/A"; link_stow A; answer y
run_check "$WORK/B"
check "exits 0" "[ $RC -eq 0 ]"
check "asks exactly once" "[ \"\$(prompts)\" = 1 ]"
check "lists rc and stow references" "grep -q '~/.zshrc' <<<\"\$OUT\" && grep -q '~/.tmux.conf' <<<\"\$OUT\""
check "rc files point at B" "[ \"\$(base_path '$H/.zshrc')\" = '$WORK/B' ] && [ \"\$(base_path '$H/.bashrc')\" = '$WORK/B' ]"
check "old links removed" "no_links_left"

echo ">> re-run after the fix is silent"
link_stow B; : > "$TTY"
run_check "$WORK/B"
check "exits 0" "[ $RC -eq 0 ]"
check "no warning" "! grep -q 'another dotfiles checkout' <<<\"\$OUT\""
check "no question" "[ \"\$(prompts)\" = 0 ]"

echo ">> answer no"
new_home no; write_rcs "$WORK/A"; link_stow A; answer n
before="$(snapshot)"
run_check "$WORK/B"
check "exits 1" "[ $RC -eq 1 ]"
check "hints at the other checkout and --yes" "grep -q -- '--yes' <<<\"\$OUT\""
check "nothing changed" "[ \"\$(snapshot)\" = '$before' ]"

echo ">> no tty and no --yes"
new_home no-tty; write_rcs "$WORK/A"; link_stow A
TTY="$WORK/no-such-dir/tty"
before="$(snapshot)"
run_check "$WORK/B"
check "exits 1" "[ $RC -eq 1 ]"
check "nothing changed" "[ \"\$(snapshot)\" = '$before' ]"

echo ">> --yes (DOTFILES_ASSUME_YES=1) without a tty"
new_home assume-yes; write_rcs "$WORK/A"; link_stow A
TTY="$WORK/no-such-dir/tty"
run_check "$WORK/B" DOTFILES_ASSUME_YES=1
check "exits 0" "[ $RC -eq 0 ]"
check "rc files point at B" "[ \"\$(base_path '$H/.zshrc')\" = '$WORK/B' ]"
check "old links removed" "no_links_left"

echo ">> target checkout missing"
make_checkout "$WORK/gone"
new_home missing; write_rcs "$WORK/gone"; link_stow gone; answer y
rm -rf "$WORK/gone"
run_check "$WORK/B"
check "exits 0" "[ $RC -eq 0 ]"
check "marks the rc target (missing)" "grep -q '~/.zshrc .*$WORK/gone (missing)' <<<\"\$OUT\""
check "marks a leaf link target (missing)" "grep -q '~/.tmux.conf .*$WORK/gone (missing)' <<<\"\$OUT\""
check "marks a folded link target (missing)" "grep -q '~/.config/ghostty .*$WORK/gone (missing)' <<<\"\$OUT\""
check "asks once" "[ \"\$(prompts)\" = 1 ]"
check "rc files point at B" "[ \"\$(base_path '$H/.zshrc')\" = '$WORK/B' ]"
check "dangling links removed, not backed up" "no_links_left && ! ls '$H'/.tmux.conf.pre-dotfiles* >/dev/null 2>&1"

echo ">> paths behind symlinks"
ln -s "$WORK" "$WORK/alias"
new_home symlinked; write_rcs "$WORK/alias/B"; link_stow B
run_check "$WORK/alias/B"
check "rc via a symlinked path, run via a symlinked path: no warning" \
  "[ $RC -eq 0 ] && ! grep -q 'another dotfiles checkout' <<<\"\$OUT\""
run_check "$WORK/B"
check "rc via a symlinked path, run via the real path: no warning" \
  "[ $RC -eq 0 ] && ! grep -q 'another dotfiles checkout' <<<\"\$OUT\""
check "no question" "[ \"\$(prompts)\" = 0 ]"

if command -v stow >/dev/null 2>&1; then
  echo ">> switch, then stow re-links into this checkout"
  new_home restow; write_rcs "$WORK/A"; link_stow A; answer y
  RC=0
  OUT="$(env -u DOTFILES_ASSUME_YES -u ASSUME_YES HOME="$H" DOTFILES_TTY="$TTY" BOOTSTRAP_SOURCE_ONLY=1 \
    "$BASH" -c ". '$WORK/B/bootstrap.sh'; check_checkout_consistency; stow_packages" 2>&1)" || RC=$?
  check "exits 0" "[ $RC -eq 0 ]"
  check "stow links resolve into B" "stow_points_to '$WORK/B'"
  check "nothing backed up as a collision" "! ls -a '$H' '$H/.config' | grep -q 'pre-dotfiles\$'"
else
  echo ">> stow not installed - re-link test skipped"
fi

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
