#!/usr/bin/env bash
# lib/settings.sh: parser, schema validation, getters, omnishell merge, Ghostty
# rendering and the bootstrap.conf migration.
# shellcheck disable=SC2034  # OUT is read inside the eval'd check expressions
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

echo ">> load, validation and getters"
write '[bootstrap]' 'install_zsh = "yes"' 'assume_yes = true' 'terminals = ["alacritty", "kitty"]' \
  '[ghostty]' 'keybinds = "linux"' 'font_family = "Cascadia Mono NF"' 'font_size = 13' 'background_opacity = 0.9'
settings_load "$F" 2>"$ERR"
check "string getter"                 '[ "$(settings_get bootstrap.install_zsh)" = yes ]'
check "boolean getter"                '[ "$(settings_get bootstrap.assume_yes)" = true ]'
check "list getter is space separated" '[ "$(settings_get bootstrap.terminals)" = "alacritty kitty" ]'
check "string with spaces"            '[ "$(settings_get ghostty.font_family)" = "Cascadia Mono NF" ]'
check "number getter"                 '[ "$(settings_get ghostty.font_size)" = 13 ]'
check "unset key is empty"            '[ -z "$(settings_get ghostty.nothing)" ]'
check "a valid file warns about nothing" '[ ! -s "$ERR" ]'

write '[bootstrap]' 'install_zsh = "maybe"' 'assume_yes = "yes"' 'terminals = "a"' 'nope = 1' \
  '[ghostty]' 'font_size = "big"' 'keybinds = "windows"'
settings_load "$F" 2>"$ERR"
check "bad enum is ignored"        '[ -z "$(settings_get bootstrap.install_zsh)" ]'
check "wrong type is ignored"      '[ -z "$(settings_get bootstrap.assume_yes)" ] && [ -z "$(settings_get bootstrap.terminals)" ]'
check "unknown key is ignored"     '[ -z "$(settings_get bootstrap.nope)" ]'
check "bad number is ignored"      '[ -z "$(settings_get ghostty.font_size)" ]'
check "bad enum warns with the key" 'grep -q "invalid bootstrap.install_zsh value .maybe." "$ERR"'
check "unknown key warns"          'grep -q "unknown key .nope. in \[bootstrap\]" "$ERR"'
check "each rejected key warns once" '[ "$(grep -c "ignored" "$ERR")" = 6 ]'

write '[bootstrap]' 'install_zsh = "no"' 'install_zsh = "yes"'
settings_load "$F" 2>"$ERR"
check "the last assignment wins" '[ "$(settings_get bootstrap.install_zsh)" = yes ]'

settings_load "$WORK/missing.toml" 2>"$ERR"
check "a missing file is not an error" '[ $? -eq 0 ] && [ -z "$(settings_get bootstrap.install_zsh)" ] && [ ! -s "$ERR" ]'
check "the schema lists every key" '[ "$(settings_schema_keys | tr "\n" " ")" = "bootstrap.install_zsh bootstrap.assume_yes bootstrap.terminals ghostty.keybinds ghostty.font_family ghostty.font_size ghostty.background_opacity " ]'

echo ">> omnishell merge"
DEFAULT="$WORK/default.toml"
cat > "$DEFAULT" <<'TOML'
# omnishell configuration (top comment)

[omnishell]
version = 1
shells = ["zsh", "bash"]

[modules.history]
enabled = true
[modules.history.options]
size = 50000

# Prompt: keep this note
[modules.starship]
enabled = true
TOML
merge() { settings_load "$F" 2>/dev/null; settings_merge_omnishell "$DEFAULT"; }
headers() { grep '^\[' <<< "$1" | tr '\n' ' '; }

write '[bootstrap]' 'install_zsh = "yes"'
check "no omnishell overrides: output equals the default" 'merge | cmp -s - "$DEFAULT"'

write '[modules.history.options]' 'size = 10'
OUT="$(merge)"
check "an override replaces the table"       'grep -qx "size = 10" <<< "$OUT" && ! grep -q 50000 <<< "$OUT"'
check "other tables stay"                    'grep -qx "enabled = true" <<< "$OUT" && grep -q "^\[modules.starship\]" <<< "$OUT"'
check "comments stay, also above a table"    'grep -q "top comment" <<< "$OUT" && grep -q "keep this note" <<< "$OUT"'
check "table order is kept"                  '[ "$(headers "$OUT")" = "[omnishell] [modules.history] [modules.history.options] [modules.starship] " ]'

write '[modules.zoxide]' 'enabled = true'
OUT="$(merge)"
check "a new table is appended last"         '[ "$(headers "$OUT")" = "[omnishell] [modules.history] [modules.history.options] [modules.starship] [modules.zoxide] " ]'
check "the default stays intact before it"   '[ "$(head -n "$(wc -l < "$DEFAULT")" <<< "$OUT")" = "$(cat "$DEFAULT")" ]'

write '[omnishell]' 'version = 1' 'shells = ["zsh"]'
OUT="$(merge)"
check "an [omnishell] override replaces the whole table" 'grep -qx "shells = \[\"zsh\"\]" <<< "$OUT" && ! grep -q "bash" <<< "$OUT"'
check "the comment above the replaced table stays"        'grep -q "top comment" <<< "$OUT"'

write '[modules.fzf.options]' 'default_opts = "--height 40% --border"' 'ctrl_r = true' 'depth = [1, 2]' 'q = "a\"b"' 'q = "c\\d"'
OUT="$(merge)"
check "strings are re-quoted"                'grep -qxF "default_opts = \"--height 40% --border\"" <<< "$OUT"'
check "booleans and arrays of numbers"       'grep -qx "ctrl_r = true" <<< "$OUT" && grep -qx "depth = \[1, 2\]" <<< "$OUT"'
check "a duplicate key keeps the last value, once" 'grep -qxF "q = \"c\\\\d\"" <<< "$OUT" && [ "$(grep -c "^q = " <<< "$OUT")" = 1 ]'

echo
if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
