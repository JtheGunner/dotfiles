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
check "the schema lists every key" '[ "$(settings_schema_keys | tr "\n" " ")" = "bootstrap.install_zsh bootstrap.assume_yes bootstrap.terminals ghostty.keybinds ghostty.font_family ghostty.font_size ghostty.background_opacity tmux.prefix tmux.mouse tmux.mode_keys tmux.base_index tmux.escape_time tmux.history_limit tmux.status_position git.user_name git.user_email git.signing_key git.default_branch git.editor git.pull_rebase " ]'

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

echo ">> ghostty rendering"
write '[ghostty]' 'font_family = "Cascadia Mono NF"' 'font_size = 13' 'background_opacity = 0.9' 'keybinds = "linux"'
settings_load "$F" 2>/dev/null
OUT="$(settings_render_ghostty)"
check "renders the three values, no keybinds" '[ "$OUT" = "font-family = \"Cascadia Mono NF\"
font-size = 13
background-opacity = 0.9" ]'
write '[ghostty]' 'keybinds = "linux"'
settings_load "$F" 2>/dev/null
check "renders nothing without rendered keys" '[ -z "$(settings_render_ghostty)" ]'
write '[ghostty]' 'font_family = "A \"B\" \\ C"'
settings_load "$F" 2>/dev/null
check "quotes and backslashes are escaped" '[ "$(settings_render_ghostty)" = "font-family = \"A \\\"B\\\" \\\\ C\"" ]'

echo ">> legacy migration"
mkdir -p "$WORK/mig"
LEG="$WORK/mig/bootstrap.conf"
NEW="$WORK/mig/config.toml"
printf '# note\nINSTALL_ZSH = yes # why\nASSUME_YES=no\nTERMINALS=alacritty kitty bad"name\n' > "$LEG"
settings_migrate_legacy "$LEG" "$NEW" >/dev/null 2>"$ERR"
settings_load "$NEW" 2>/dev/null
check "writes config.toml"                  '[ -f "$NEW" ]'
check "INSTALL_ZSH is migrated"             '[ "$(settings_get bootstrap.install_zsh)" = yes ]'
check "ASSUME_YES=no becomes false"         '[ "$(settings_get bootstrap.assume_yes)" = false ]'
check "TERMINALS becomes a list"            '[ "$(settings_get bootstrap.terminals)" = "alacritty kitty" ]'
check "an invalid terminal name is skipped with a warning" 'grep -q "bad" "$ERR"'
check "the legacy file is renamed"          '[ ! -e "$LEG" ] && [ -f "$LEG.migrated" ]'

rm -f "$NEW" "$LEG.migrated"
printf '# INSTALL_ZSH=ask\n#TERMINALS=\n' > "$LEG"
settings_migrate_legacy "$LEG" "$NEW" >/dev/null 2>&1
check "a commented-out legacy file creates no config.toml" '[ ! -e "$NEW" ] && [ -f "$LEG.migrated" ]'

rm -f "$LEG.migrated"
printf 'INSTALL_ZSH=yes\n' > "$LEG"
printf '[bootstrap]\nassume_yes = true\n' > "$NEW"
cp "$NEW" "$NEW.bak"
settings_migrate_legacy "$LEG" "$NEW" >/dev/null 2>&1
check "an existing config.toml is never touched" 'cmp -s "$NEW" "$NEW.bak" && [ -f "$LEG" ]'

echo ">> parser: control characters"
printf '[bootstrap]\nx = "a\037b"\ny = ["p\036Zq"]\nz = 1\n' > "$F"
OUT="$(rec)"
check "a control character in a string rejects the line" '! grep -q "^bootstrap|x|" <<< "$OUT" && ! grep -q "^bootstrap|y|" <<< "$OUT"'
check "and warns about it"                               'grep -q "control character" "$ERR"'
check "other lines still parse"                          'grep -qxF "bootstrap|z|int|1" <<< "$OUT"'

echo ">> number ranges"
rng() {   # <key> <value> -> ok | ignored
  write '[ghostty]' "$1 = $2"
  settings_load "$F" 2>/dev/null
  if [ -n "$(settings_get "ghostty.$1")" ]; then echo ok; else echo ignored; fi
}
check "font_size 12.5 is accepted"          '[ "$(rng font_size 12.5)" = ok ]'
check "font_size 0 is ignored"              '[ "$(rng font_size 0)" = ignored ]'
check "font_size -3 is ignored"             '[ "$(rng font_size -3)" = ignored ]'
check "background_opacity 0 is accepted"    '[ "$(rng background_opacity 0)" = ok ]'
check "background_opacity 0.98 is accepted" '[ "$(rng background_opacity 0.98)" = ok ]'
check "background_opacity 1 is accepted"    '[ "$(rng background_opacity 1)" = ok ]'
check "background_opacity 7 is ignored"     '[ "$(rng background_opacity 7)" = ignored ]'
check "background_opacity -0.1 is ignored"  '[ "$(rng background_opacity -0.1)" = ignored ]'

echo ">> old KEY=value format"
write 'INSTALL_ZSH=yes' 'ASSUME_YES=no'
settings_load "$F" 2>"$ERR"
check "an old-format file is called out once" '[ "$(grep -c "old bootstrap.conf format" "$ERR")" = 1 ]'
write '[bootstrap]' 'install_zsh = "yes"'
settings_load "$F" 2>"$ERR"
check "a TOML file gets no such hint"         '! grep -q "old bootstrap.conf format" "$ERR"'

echo ">> legacy file leftovers"
rm -rf "$WORK/mig2"; mkdir -p "$WORK/mig2"
LEG2="$WORK/mig2/bootstrap.conf"
NEW2="$WORK/mig2/config.toml"
printf 'INSTALL_ZSH=yes\n' > "$LEG2"
printf '[bootstrap]\n' > "$NEW2"
settings_migrate_legacy "$LEG2" "$NEW2" >/dev/null 2>"$ERR"
check "a bootstrap.conf left next to config.toml is called out" 'grep -q "is ignored" "$ERR"'
settings_migrate_legacy "$NEW2" "$NEW2" >/dev/null 2>"$ERR"
check "the same path is not reported as ignored"                '! grep -q "is ignored" "$ERR"'
rm -f "$NEW2"
printf 'OLDER\n' > "$LEG2.migrated"
settings_migrate_legacy "$LEG2" "$NEW2" >/dev/null 2>&1
check "an existing bootstrap.conf.migrated is kept"             '[ "$(cat "$LEG2.migrated")" = OLDER ]'
check "the retired file gets another name"                      'grep -qx "INSTALL_ZSH=yes" "$LEG2.migrated.1"'

echo ">> tmux and git keys"
val() {   # <table> <key> <toml value> -> the value settings_get returns, empty when rejected
  write "[$1]" "$2 = $3"
  settings_load "$F" 2>/dev/null
  settings_get "$1.$2"
}
for k in 'C-b' 'M-a' 'C-Space' 'F5' 'F12'; do
  check "tmux.prefix accepts $k" "[ \"\$(val tmux prefix '\"$k\"')\" = '$k' ]"
done
for k in 'ctrl-b' 'C-ab' 'F13' ''; do
  check "tmux.prefix rejects '$k'" "[ -z \"\$(val tmux prefix '\"$k\"')\" ]"
done
check "tmux.mouse accepts a boolean"          '[ "$(val tmux mouse false)" = false ]'
check "tmux.mouse rejects a string"           '[ -z "$(val tmux mouse "\"yes\"")" ]'
check "tmux.mode_keys accepts emacs"          '[ "$(val tmux mode_keys "\"emacs\"")" = emacs ]'
check "tmux.mode_keys rejects nano"           '[ -z "$(val tmux mode_keys "\"nano\"")" ]'
check "tmux.base_index accepts 0"             '[ "$(val tmux base_index 0)" = 0 ]'
check "tmux.base_index rejects -1"            '[ -z "$(val tmux base_index -1)" ]'
check "tmux.base_index rejects a string"      '[ -z "$(val tmux base_index "\"1\"")" ]'
check "tmux.escape_time accepts 0"            '[ "$(val tmux escape_time 0)" = 0 ]'
check "tmux.history_limit accepts 50000"      '[ "$(val tmux history_limit 50000)" = 50000 ]'
check "tmux.history_limit rejects 0"          '[ -z "$(val tmux history_limit 0)" ]'
check "tmux.status_position accepts top"      '[ "$(val tmux status_position "\"top\"")" = top ]'
check "tmux.status_position rejects middle"   '[ -z "$(val tmux status_position "\"middle\"")" ]'
check "git.user_email accepts a@b.c"          '[ "$(val git user_email "\"a@b.c\"")" = a@b.c ]'
check "git.user_email rejects a space"        '[ -z "$(val git user_email "\"a b@c.d\"")" ]'
check "git.user_email rejects no @"           '[ -z "$(val git user_email "\"nobody\"")" ]'
check "git.user_email rejects a bare @"       '[ -z "$(val git user_email "\"@\"")" ]'
check "git.pull_rebase accepts a boolean"     '[ "$(val git pull_rebase true)" = true ]'
check "git.default_branch accepts a string"   '[ "$(val git default_branch "\"trunk\"")" = trunk ]'
check "git.editor accepts a string"           '[ "$(val git editor "\"nvim -f\"")" = "nvim -f" ]'

echo ">> tmux and git rendering"
write '[tmux]' 'prefix = "C-b"' 'mouse = false' 'mode_keys = "emacs"' 'base_index = 0' \
  'escape_time = 10' 'history_limit = 20000' 'status_position = "top"'
settings_load "$F" 2>/dev/null
check "settings_render_tmux prints every command in order" '[ "$(settings_render_tmux)" = "unbind C-a
set -g prefix C-b
bind C-b send-prefix
set -g mouse off
set-window-option -g mode-keys emacs
set -g base-index 0
set -sg escape-time 10
set -g history-limit 20000
set -g status-position top" ]'
write '[tmux]' 'mouse = true'
settings_load "$F" 2>/dev/null
check "a single key renders a single command"             '[ "$(settings_render_tmux)" = "set -g mouse on" ]'
write '[bootstrap]' 'install_zsh = "ask"'
settings_load "$F" 2>/dev/null
check "no tmux keys render nothing"                       '[ -z "$(settings_render_tmux)" ]'

if command -v tmux >/dev/null 2>&1; then
  write '[tmux]' 'prefix = "C-a"' 'mouse = false' 'history_limit = 777'
  settings_load "$F" 2>/dev/null
  settings_render_tmux > "$WORK/tmux-settings.conf"
  SOCK="dotfiles-test-$$"
  tmux_show() {
    tmux -L "$SOCK" -f /dev/null new-session -d 'sleep 30' \; source-file "$WORK/tmux-settings.conf" \; show-options -gv "$1" 2>/dev/null
    tmux -L "$SOCK" kill-server 2>/dev/null || true
  }
  check "real tmux accepts the generated file and keeps prefix C-a" '[ "$(tmux_show prefix)" = C-a ]'
  check "real tmux applies history-limit"                           '[ "$(tmux_show history-limit)" = 777 ]'
  tmux -L "$SOCK" kill-server 2>/dev/null || true
else
  pass "tmux is not installed - syntax check skipped"
fi

write '[git]' 'user_name = "Ada \"A\" \\ #1"' 'user_email = "ada@example.com"' 'default_branch = "trunk"' \
  'editor = "nvim -f"' 'pull_rebase = true' 'signing_key = "~/.ssh/id.pub"'
settings_load "$F" 2>/dev/null
check "settings_render_git prints key and value records, no signing" '[ "$(settings_render_git | tr "\037" "|")" = "user.name|Ada \"A\" \\ #1
user.email|ada@example.com
init.defaultBranch|trunk
core.editor|nvim -f
pull.rebase|true" ]'
write '[bootstrap]' 'install_zsh = "ask"'
settings_load "$F" 2>/dev/null
check "no git keys render nothing"                                    '[ -z "$(settings_render_git)" ]'

echo ">> _settings_literal"
lit() { _settings_literal "$@" 2>/dev/null; }
check "enum answer becomes a quoted string"       '[ "$(lit enum:yes,no,ask yes)" = "\"yes\"" ]'
check "enum rejects a value outside the list"     '! lit enum:yes,no,ask maybe >/dev/null'
check "bool accepts yes and prints true"          '[ "$(lit bool yes)" = true ]'
check "bool accepts false"                        '[ "$(lit bool false)" = false ]'
check "bool rejects maybe"                        '! lit bool maybe >/dev/null'
check "list splits on spaces and commas"         '[ "$(lit list "a, b c")" = "[\"a\", \"b\", \"c\"]" ]'
check "list rejects a quote"                      '! lit list "a\"b" >/dev/null'
check "list rejects an empty list"                '! lit list " , " >/dev/null'
check "positive number stays bare"                '[ "$(lit positive 13.5)" = 13.5 ]'
check "positive rejects 0"                        '! lit positive 0 >/dev/null'
check "fraction rejects 1.5"                      '! lit fraction 1.5 >/dev/null'
check "nonneg rejects a float"                    '! lit nonneg 1.5 >/dev/null'
check "posint rejects text"                       '! lit posint abc >/dev/null'
check "string escapes a quote and a backslash"    '[ "$(lit string "a\"b\\c")" = "\"a\\\"b\\\\c\"" ]'
check "tmuxkey accepts C-a"                       '[ "$(lit tmuxkey C-a)" = "\"C-a\"" ]'
check "tmuxkey rejects ctrl-a"                    '! lit tmuxkey ctrl-a >/dev/null'
check "email rejects a missing at-sign"           '! lit email nobody >/dev/null'
check "an empty answer is rejected"               '! lit string "" >/dev/null'
check "a control character is rejected"           '! lit string "$(printf "a\tb")" >/dev/null'

echo
if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
