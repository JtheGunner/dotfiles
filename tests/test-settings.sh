#!/usr/bin/env bash
# lib/settings.sh: parser, schema validation, getters, omnishell merge, Ghostty
# rendering and the bootstrap.conf migration.
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

F="$WORK/config.toml"
ERR="$WORK/err"
write() { printf '%s\n' "$@" > "$F"; }
# readable records: field separator -> |, array separator -> ~
rec() { settings_parse "$F" 2>"$ERR" | tr '\037\036' '|~'; }
OUT=""

echo ">> parser: value forms"
write '[bootstrap]' 'install_zsh = "yes"' 'assume_yes = true' 'terminals = ["a", "b"]' 'size = 12' 'ratio = -0.5'
OUT="$(rec)"
check "string"             'grep -qxF "bootstrap|install_zsh|str|yes" <<< "$OUT"'
check "boolean"            'grep -qxF "bootstrap|assume_yes|bool|true" <<< "$OUT"'
check "array of strings"   'grep -qxF "bootstrap|terminals|array|sa~sb" <<< "$OUT"'
check "integer"            'grep -qxF "bootstrap|size|int|12" <<< "$OUT"'
check "negative float"     'grep -qxF "bootstrap|ratio|float|-0.5" <<< "$OUT"'
check "a valid file warns about nothing" '[ ! -s "$ERR" ]'

write '[bootstrap]' 'y = []' 'z = [1, "a,b", true]'
OUT="$(rec)"
check "empty array"                     'grep -qxF "bootstrap|y|array|" <<< "$OUT"'
check "mixed array, comma in a string"  'grep -qxF "bootstrap|z|array|r1~sa,b~rtrue" <<< "$OUT"'

echo ">> parser: comments, quoting, whitespace"
write '[bootstrap]' 'x = "a # b = c" # trailing' '# whole line' ''
OUT="$(rec)"
check "# and = inside a string are kept" 'grep -qxF "bootstrap|x|str|a # b = c" <<< "$OUT"'
write '[bootstrap]' 'x = "say \"hi\" \\ done"'
OUT="$(rec)"
check "escaped quote and backslash"      'grep -qxF "bootstrap|x|str|say \"hi\" \\ done" <<< "$OUT"'
write '[bootstrap]' $'\tx\t=\t1\t'
OUT="$(rec)"
check "tabs around the key and value"    'grep -qxF "bootstrap|x|int|1" <<< "$OUT"'
printf '[bootstrap]\r\ninstall_zsh = "yes"\r\n' > "$F"
OUT="$(rec)"
check "CRLF line endings"                'grep -qxF "bootstrap|install_zsh|str|yes" <<< "$OUT"'
printf '\357\273\277[bootstrap]\nx = 1\n' > "$F"
OUT="$(rec)"
check "UTF-8 BOM before the first table" 'grep -qxF "bootstrap|x|int|1" <<< "$OUT"'
printf '[bootstrap]\nx = 1' > "$F"
OUT="$(rec)"
check "no trailing newline"              'grep -qxF "bootstrap|x|int|1" <<< "$OUT"'
write '[modules.history.options]' 'size = 5'
OUT="$(rec)"
check "nested modules table"             'grep -qxF "modules.history.options|size|int|5" <<< "$OUT"'

echo ">> parser: rejected input"
bad() {   # <label> <line> <warning regex>
  write '[bootstrap]' "$2"
  OUT="$(rec)"
  check "$1: no record" '[ -z "$OUT" ]'
  check "$1: warns" "grep -q '$3' '$ERR'"
}
bad "empty value"               'x ='                    'invalid value'
bad "unsupported escape"        'x = "a\nb"'             'invalid value'
bad "unterminated string"       'x = "abc'               'invalid value'
bad "text after the string"     'x = "a" b'              'invalid value'
bad "inline table"              'x = { a = 1 }'          'invalid value'
bad "multi-line array"          'x = ['                  'invalid value'
bad "unterminated array string" 'x = ["a, "b"]'          'invalid value'
bad "dotted key"                'a.b = 1'                'unsupported key'
bad "line without ="            'just text'              'not a key = value'

write 'x = 1'
OUT="$(rec)"
check "key outside a table: no record" '[ -z "$OUT" ]'
check "key outside a table: warns"     'grep -q "outside a table" "$ERR"'

write '[nope]' 'x = 1' '[bootstrap]' 'y = 2'
OUT="$(rec)"
check "unknown table: its keys are skipped"        '! grep -q "x|" <<< "$OUT"'
check "unknown table: later tables still parse"    'grep -qxF "bootstrap|y|int|2" <<< "$OUT"'
check "unknown table: warns"                       'grep -q "unknown table" "$ERR"'
write '[[array.of.tables]]' 'x = 1'
OUT="$(rec)"
check "array of tables is rejected" '[ -z "$OUT" ] && grep -q "invalid table header" "$ERR"'

echo
if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
