#!/usr/bin/env bash
# bootstrap.sh omnishell + toolchain handling: the minimum omnishell version,
# the Rust toolchain omnishell's git + cargo fallbacks need (on CPUs without
# release binaries only), and the summary of
# degraded modules at the end of a run. Everything runs against stub binaries in
# a throwaway PATH - nothing is installed.
# SC2034: OUT / RC are read inside the eval'd check expressions.
# shellcheck disable=SC2034
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

pass() { printf '   ok   %s\n' "$1"; }
fail() { printf '   FAIL %s\n' "$1"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# the omnishell an upgrade would install
NEW_OMNISHELL="$WORK/omnishell-0.6.0"
printf '#!/bin/sh\n[ "$1" = version ] && echo "0.6.0 (commit abc, built now)"\n' > "$NEW_OMNISHELL"
chmod +x "$NEW_OMNISHELL"

# a fresh stub dir (BIN) and HOME for each case
new_case() {
  BIN="$WORK/bin-$1"; H="$WORK/home-$1"
  rm -rf "$BIN" "$H"
  mkdir -p "$BIN" "$H/.local/bin"
  CALLS="$WORK/calls-$1"; : > "$CALLS"
}

stub() {   # <name> <script body>   - stub binary that logs its calls
  printf '#!/bin/sh\necho "%s $*" >> "%s"\n%s\n' "$1" "$CALLS" "$2" > "$BIN/$1"
  chmod +x "$BIN/$1"
}

omnishell_stub() {   # <dir> <version>
  mkdir -p "$1"
  printf '#!/bin/sh\n[ "$1" = version ] && echo "%s (commit abc, built now)"\n' "$2" > "$1/omnishell"
  chmod +x "$1/omnishell"
}

# Run a bootstrap.sh function with only the stub dir (plus system essentials) on PATH.
OUT=""; RC=0
run_fn() {   # <fn> [args...]
  RC=0
  OUT="$(env -i HOME="$H" PATH="$BIN:/usr/bin:/bin" BOOTSTRAP_SOURCE_ONLY=1 \
    "$BASH" -c ". '$REPO/bootstrap.sh'; $*" 2>&1)" || RC=$?
}

echo ">> _version_ge"
new_case vge
run_fn '_version_ge 0.5.0 0.3.0 && echo yes'
check "0.5.0 >= 0.3.0"          '[ "$OUT" = yes ]'
run_fn '_version_ge 0.3.0 0.3.0 && echo yes'
check "0.3.0 >= 0.3.0"          '[ "$OUT" = yes ]'
run_fn '_version_ge 0.2.1 0.3.0 || echo no'
check "0.2.1 < 0.3.0"           '[ "$OUT" = no ]'
run_fn '_version_ge 0.10.0 0.9.5 && echo yes'
check "0.10.0 >= 0.9.5 (numeric, not lexical)" '[ "$OUT" = yes ]'
run_fn '_version_ge 1.75.0 1.95 || echo no'
check "1.75.0 < 1.95 (different field counts)" '[ "$OUT" = no ]'

echo ">> install_omnishell: current version"
new_case current
omnishell_stub "$BIN" 0.6.0
stub curl 'exit 1'
run_fn install_omnishell
check "0.6.0 is kept"                  '[ "$RC" = 0 ] && grep -q "already installed (0.6.0" <<< "$OUT"'
check "no installer was fetched"       '! grep -q "^curl" "$CALLS"'

echo ">> install_omnishell: too old, curl installer upgrades it"
new_case upgrade
omnishell_stub "$BIN" 0.5.0
# the stub installer drops a newer omnishell into ~/.local/bin, which comes first on PATH
stub curl "echo 'mkdir -p \"\$HOME/.local/bin\"; cp \"$NEW_OMNISHELL\" \"\$HOME/.local/bin/omnishell\"'"
run_fn install_omnishell
check "old version triggers the upgrade" 'grep -q "^curl .*omnishell/main/install.sh" "$CALLS"'
check "reports the upgrade"            'grep -q "below the minimum 0.6.0" <<< "$OUT"'
check "run succeeds"                   '[ "$RC" = 0 ]'

echo ">> install_omnishell: too old and the upgrade does not help"
new_case stuck
omnishell_stub "$BIN" 0.5.0
stub curl 'echo true'
run_fn install_omnishell
check "stops instead of carrying on"   '[ "$RC" -ne 0 ]'
check "names the version and the fix"  'grep -q "0.5.0" <<< "$OUT" && grep -q "0.6.0" <<< "$OUT"'

echo ">> install_omnishell: Homebrew upgrades it"
new_case brew
omnishell_stub "$BIN" 0.5.0
stub brew "[ \"\$1\" = upgrade ] && cp \"$NEW_OMNISHELL\" \"\$(dirname \"\$0\")/omnishell\"; exit 0"
run_fn install_omnishell
check "brew upgrade is used"           'grep -q "^brew upgrade .*omnishell" "$CALLS"'
check "no curl installer"              '! grep -q "^curl" "$CALLS"'
check "run succeeds"                   '[ "$RC" = 0 ]'

echo ">> ensure_rust_toolchain"
new_case rust-missing
stub curl "echo 'echo rustup-init >> \"$CALLS\"'"
run_fn ensure_rust_toolchain
check "no cargo -> rustup is installed" 'grep -q "^curl .*sh.rustup.rs" "$CALLS" && grep -q "^rustup-init" "$CALLS"'

new_case rust-old
stub cargo 'echo "cargo 1.75.0 (abc 2024-01-01)"'
stub curl "echo 'echo rustup-init >> \"$CALLS\"'"
run_fn ensure_rust_toolchain
check "cargo 1.75 is too old -> rustup is installed" 'grep -q "^rustup-init" "$CALLS"'

new_case rust-below-mise
stub cargo 'echo "cargo 1.90.0 (abc 2025-09-01)"'
stub curl "echo 'echo rustup-init >> \"$CALLS\"'"
run_fn ensure_rust_toolchain
check "cargo 1.90 is too old for mise -> rustup is installed" 'grep -q "^rustup-init" "$CALLS"'

new_case rust-ok
stub cargo 'echo "cargo 1.95.0 (abc 2026-01-01)"'
stub curl 'exit 1'
run_fn ensure_rust_toolchain
check "cargo 1.95 is left alone"       '[ "$RC" = 0 ] && ! grep -q "^curl" "$CALLS"'

new_case rust-existing-rustup
stub cargo 'echo "cargo 1.75.0 (abc 2024-01-01)"'
stub rustup 'exit 0'
stub curl 'exit 1'
run_fn ensure_rust_toolchain
check "existing rustup is updated, not reinstalled" 'grep -q "^rustup update stable" "$CALLS" && ! grep -q "^curl" "$CALLS"'

echo ">> degraded module summary"
APPLY_OUT='  unchanged  completion
  degraded  broot  package install failed: apt: sudo apt-get install -y -- broot: exit status 100
  applied  direnv
  degraded  mise  fallback install failed: fallback run "cargo install --locked": exec: "cargo": executable file not found in $PATH
  applied  root-loops
error: one or more modules are degraded'
new_case summary
run_fn "_degraded_summary '$APPLY_OUT'"
check "lists every degraded module"    'grep -q "broot" <<< "$OUT" && grep -q "mise" <<< "$OUT"'
check "ignores healthy modules"        '! grep -q "direnv" <<< "$OUT" && ! grep -q "root-loops" <<< "$OUT"'
check "carries the reason"             'grep -q "executable file not found" <<< "$OUT"'
check "points to omnishell doctor"     'grep -q "omnishell doctor" <<< "$OUT"'

run_fn "_degraded_summary '  applied  direnv'"
check "nothing degraded -> silent"     '[ -z "$OUT" ]'

run_fn "_degraded_count '$APPLY_OUT'"
check "counts degraded modules"        '[ "$OUT" = 2 ]'

echo ">> apply_omnishell + finish"
omnishell_apply_stub() {   # <exit code> <report>
  printf '#!/bin/sh\ncase "$1" in\n  init) exit 0 ;;\n  apply) printf "%%s\\n" "%s"; exit %s ;;\nesac\n' "$2" "$1" > "$BIN/omnishell"
  chmod +x "$BIN/omnishell"
}
DEGRADED_REPORT=$'  applied  direnv\n  degraded  starship  package install failed: apt: exit status 100'

new_case apply-degraded
omnishell_apply_stub 1 "$DEGRADED_REPORT"
run_fn 'apply_omnishell; echo "report=[$(printf "%s" "$APPLY_REPORT" | tr "\n" "|")]"; finish'
check "degraded apply (exit 1) does not abort"  '[ "$RC" = 0 ]'
check "keeps the apply report"                  'grep -q "report=\[  applied  direnv|  degraded  starship" <<< "$OUT"'
check "summary names the module"                'grep -q "starship  *package install failed" <<< "$OUT"'
check "closing line counts the degraded modules" 'grep -q "done with 1 degraded module(s)" <<< "$OUT"'

new_case apply-ok
omnishell_apply_stub 0 "  applied  direnv"
run_fn 'apply_omnishell; finish'
check "clean apply ends with a plain done"      '[ "$RC" = 0 ] && grep -q "done\. Open a new shell" <<< "$OUT" && ! grep -q "degraded" <<< "$OUT"'

new_case apply-broken
omnishell_apply_stub 2 "error: bad config"
run_fn 'apply_omnishell; echo not-reached'
check "config error (exit 2) aborts with its exit code" '[ "$RC" = 2 ] && ! grep -q not-reached <<< "$OUT"'

echo ">> needs_source_builds"
for arch in x86_64 aarch64 arm64; do
  new_case "arch-$arch"
  stub uname "echo $arch"
  run_fn needs_source_builds
  check "$arch has release binaries -> no source build" '[ "$RC" != 0 ]'
done
for arch in armv6l armv7l riscv64; do
  new_case "arch-$arch"
  stub uname "echo $arch"
  run_fn needs_source_builds
  check "$arch has no release binaries -> source build" '[ "$RC" = 0 ]'
done

echo ">> install_deps (apt): build dependencies only where omnishell builds from source"
apt_case() {   # <case> <arch>
  new_case "$1"
  stub uname "echo $2"
  stub apt-get 'exit 0'
  stub apt-cache 'exit 0'
  stub stow 'exit 0'
  stub cargo 'echo "cargo 1.75.0 (abc 2024-01-01)"'
  stub curl 'exit 1'
  # SUDO is cleared so the stub apt-get is the only thing that runs
  run_fn 'SUDO=""; install_deps'
}
apt_case apt-armv7 armv7l
for dep in build-essential cmake pkg-config libssl-dev; do
  check "armv7l: apt installs $dep" "grep -q '^apt-get install .* $dep\$' '$CALLS'"
done
check "armv7l: the Rust toolchain is ensured" 'grep -q "^curl .*sh.rustup.rs" "$CALLS"'

for arch in x86_64 aarch64; do
  apt_case "apt-$arch" "$arch"
  check "$arch: base packages are still installed" "grep -q '^apt-get install .* stow\$' '$CALLS'"
  check "$arch: no build dependencies" '! grep -q -E "^apt-get install .* (build-essential|cmake|pkg-config|libssl-dev)$" "$CALLS"'
  check "$arch: no Rust toolchain" '! grep -q "^curl" "$CALLS"'
done

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "all ok"
