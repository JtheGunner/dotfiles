#!/usr/bin/env bash
# shell.d fragments and the zsh rc library, exercised in every shell they
# claim to support.
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DOTFILES   # zsh/zshrc.zsh reads it
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

pass() { printf '   ok   %s\n' "$1"; }
fail() { printf '   FAIL %s\n' "$1"; failures=$((failures + 1)); }
expect() {   # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1"; printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; fi
}

# fake docker that echoes its arguments
mkdir -p "$WORK/bin"
printf '#!/bin/sh\necho "docker $*"\n' > "$WORK/bin/docker"
chmod +x "$WORK/bin/docker"

shells="sh bash"
command -v zsh >/dev/null 2>&1 && shells="$shells zsh"

for sh in $shells; do
  echo ">> shell.d/20-docker.sh in $sh"
  in_shell() { PATH="$WORK/bin:$PATH" "$sh" -c ". '$DOTFILES/shell.d/20-docker.sh'; $1" 2>&1; }

  expect "dsd deploys from the default stacks dir" \
    "docker stack deploy traefik -c /var/data/config/traefik/traefik.yml" \
    "$(in_shell 'dsd traefik')"
  expect "dsd honours DOCKER_STACKS_DIR" \
    "docker stack deploy web -c /srv/stacks/web/web.yml" \
    "$(in_shell 'DOCKER_STACKS_DIR=/srv/stacks dsd web')"
  expect "dsd takes an explicit compose file" \
    "docker stack deploy web -c ./web.yml" \
    "$(in_shell 'dsd web ./web.yml')"
  expect "dsr removes a stack" "docker stack rm web" "$(in_shell 'dsr web')"
  expect "dsd without a stack prints usage and fails" \
    "usage: dsd <stack> [compose-file] rc=2" "$(in_shell 'dsd; echo "rc=$?"' | tr '\n' ' ' | sed 's/ $//')"
  expect "dsr without a stack prints usage and fails" \
    "usage: dsr <stack> rc=2" "$(in_shell 'dsr; echo "rc=$?"' | tr '\n' ' ' | sed 's/ $//')"
  mkdir -p "$WORK/empty"   # a PATH with no docker on it, wherever docker lives
  expect "no docker helpers without docker" "absent" \
    "$(PATH="$WORK/empty" "$(command -v "$sh")" -c ". '$DOTFILES/shell.d/20-docker.sh'; command -v dsd >/dev/null && echo present || echo absent")"
done

if command -v zsh >/dev/null 2>&1; then
  echo ">> zsh/zshrc.zsh"
  # compinit runs AFTER the library (omnishell's completion module) and resets
  # _comp_options; globdots must still be there once the first prompt is due.
  actual="$(zsh -f -c "
    . '$DOTFILES/zsh/zshrc.zsh' 2>/dev/null
    autoload -Uz compinit && compinit -D -u
    for f in \$precmd_functions; do \$f; done
    (( \${_comp_options[(Ie)globdots]} )) && print -n globdots || print -n missing
    (( \$+functions[_dotfiles_comp_globdots] )) && print ' hook-left' || print ' hook-gone'
  ")"
  expect "globdots survives a later compinit; one-shot hook removes itself" "globdots hook-gone" "$actual"
else
  echo ">> zsh not installed - zsh tests skipped"
fi

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
