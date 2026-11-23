#!/usr/bin/env bash
# bootstrap.sh write_rc_base: ~/.bashrc stops early in non-interactive shells. bash reads
# ~/.bashrc for every ssh command, and running the rc libraries there breaks callers that
# expect a quiet shell (Ansible's become prompt detection); ~/.zshrc is interactive-only
# and gets no guard.
# shellcheck disable=SC2034  # variables are read inside the eval'd check expressions
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

pass() { printf '   ok   %s\n' "$1"; }
fail() { printf '   FAIL %s\n' "$1"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# a fake checkout whose rc libraries only leave a marker file behind
CHECKOUT="$WORK/checkout"
mkdir -p "$CHECKOUT/bash" "$CHECKOUT/zsh"
cp "$REPO/bootstrap.sh" "$CHECKOUT/"
cp -R "$REPO/lib" "$CHECKOUT/"
printf 'touch "$MARK"\n' > "$CHECKOUT/bash/bashrc.bash"
printf 'touch "$MARK"\n' > "$CHECKOUT/zsh/zshrc.zsh"

H="$WORK/home"
mkdir -p "$H"
env HOME="$H" BOOTSTRAP_SOURCE_ONLY=1 "$BASH" -c ". '$CHECKOUT/bootstrap.sh'; write_rc_base" > "$WORK/out" 2>&1

echo ">> generated rc files"
check "bashrc has one base block" "[ \"\$(grep -c '^# >>> dotfiles:base >>>\$' '$H/.bashrc')\" = 1 ]"
check "bashrc returns early when not interactive" "grep -qxF 'case \$- in *i*) ;; *) return ;; esac' '$H/.bashrc'"
check "the guard sits after DOTFILES is exported and before the library is sourced" \
    "awk '/^export DOTFILES=/{e=NR} /^case /{g=NR} /^\\[ -r /{s=NR} END{exit !(e<g && g<s)}' '$H/.bashrc'"
check "zshrc has no guard" "! grep -q 'return' '$H/.zshrc'"
check "the checkout path in the block is unchanged" "[ \"\$(grep -c '^export DOTFILES=\"$CHECKOUT\"\$' '$H/.bashrc')\" = 1 ]"

echo ">> behaviour"
MARK="$WORK/mark-noninteractive"
env HOME="$H" MARK="$MARK" "$BASH" -c ". '$H/.bashrc'; echo sourced-ok" > "$WORK/ni.out" 2>&1
check "a non-interactive shell does not load the rc library" "[ ! -e '$MARK' ] && grep -q sourced-ok '$WORK/ni.out'"
MARK="$WORK/mark-interactive"
env HOME="$H" MARK="$MARK" "$BASH" -ic ". '$H/.bashrc'" > /dev/null 2>&1 || true
check "an interactive shell loads the rc library" "[ -e '$MARK' ]"

if [ "$failures" -ne 0 ]; then
  printf 'FAILED: %s\n' "$failures"
  exit 1
fi
echo "PASS: bashrc guard"
