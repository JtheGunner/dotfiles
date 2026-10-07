# Single Settings File Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `bootstrap.conf` with one untracked TOML settings file, `~/.config/dotfiles/config.toml`, that sets bootstrap options, omnishell module overrides and Ghostty values.

**Architecture:** A new `lib/settings.sh` (sourced by `bootstrap.sh`, unit-tested on its own) parses a restricted TOML subset with awk into records, validates `[bootstrap]` / `[ghostty]` keys against a schema, merges `[omnishell]` / `[modules.*]` tables over the tracked `omnishell/config.toml`, and renders Ghostty values. `bootstrap.sh` keeps its precedence (flag > environment > settings file > default) and gains seeding, one-time migration of `bootstrap.conf`, the omnishell merge plus `omnishell validate`, and a generated Ghostty include.

**Tech Stack:** Bash (3.2 compatible: no associative arrays, no `printf -v`-only tricks), POSIX awk (BWK awk on macOS, mawk on Debian/Ubuntu), the repo's `tests/test-*.sh` style, `omnishell validate`.

**Spec:** `docs/superpowers/specs/2026-10-07-single-settings-file-design.md`

## Global Constraints

- Settings file: `~/.config/dotfiles/config.toml`; `DOTFILES_CONFIG` overrides the path.
- Precedence everywhere: command-line flag > environment variable > settings file > default.
- Existing flags and environment variables keep working unchanged.
- Parsing is Bash plus awk only; never `source` or `eval` the settings file; no Python `tomllib`.
- TOML subset: `# comments`, `[table]` / `[a.b]` headers, `key = value` with string (escapes `\"` and `\\` only), integer, float, boolean, or a one-line array of those.
- Accepted tables: `bootstrap`, `ghostty`, `omnishell`, `modules.*`. Anything else is warned about and ignored.
- A table in the settings file replaces the whole same-named table in `omnishell/config.toml`; new tables are appended; everything else (including comments) stays.
- Only a failing `omnishell validate` (exit 2) is fatal; everything else is one `warn` and ignored.
- The settings file is seeded from `config.toml.example` (every option present, commented out), never overwritten. `bootstrap.conf` is migrated once and renamed `bootstrap.conf.migrated`; `bootstrap.conf.example` is removed.
- Generated Ghostty include: `~/.config/ghostty-settings.conf`, outside the stowed directory, loaded before `~/.config/ghostty.local`.
- Code and docs in English, commit messages `<type>: <description>` without trailers, `make lint test` green before every commit.

## Review Focus

- CRLF line endings and a UTF-8 BOM in the settings file (Windows editors): parsed like LF / no BOM. Pinned in Task 1.
- `#` and `=` inside quoted strings (font names, option values): preserved. Pinned in Task 1.
- A settings file whose `[omnishell]` table omits `version` / `shells`: `omnishell validate` fails and the bootstrap aborts with a message pointing at the settings file. Pinned in Task 6.
- A hand-written `~/.config/ghostty-settings.conf` already exists: left untouched with a warning; a stale *generated* one disappears when the settings are cleared. Pinned in Task 6.
- Running the bootstrap twice: the merged omnishell config is identical, migration does not repeat, a commented-out legacy `bootstrap.conf` (the seeded template) does not create an empty `config.toml`. Pinned in Tasks 4 and 6.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/settings.sh` (create) | parse, validate, query, merge, render, migrate; no side effects on source |
| `tests/test-settings.sh` (create) | unit tests for `lib/settings.sh` |
| `tests/test-bootstrap-settings.sh` (create) | bootstrap integration: template, seeding, migration, omnishell apply, Ghostty include |
| `config.toml.example` (create) | documents every option, all commented out |
| `bootstrap.sh` (modify) | source the library, resolve settings, seed, migrate, merge, render |
| `tests/test-zsh-install.sh` (modify) | config fixtures in TOML; drop the template/seeding cases that move |
| `ghostty/.config/ghostty/config` (modify) | include the generated settings file |
| `Makefile` (modify) | lint `lib/settings.sh` |
| `README.md` (modify) | document the settings file |
| `bootstrap.conf.example` (delete) | replaced by `config.toml.example` |

---

### Task 1: TOML subset parser

**Files:**
- Create: `lib/settings.sh`
- Create: `tests/test-settings.sh`
- Modify: `Makefile` (the `BASH_SCRIPTS` line)

**Interfaces:**
- Produces: `settings_parse FILE` prints records `table<US>key<US>kind<US>value` on stdout (`US` = `$'\037'`); `kind` is `str|int|float|bool|array`; array values are elements joined by `RS` (`$'\036'`), each element prefixed with `s` (string) or `r` (raw number/bool). Every rejected line prints `FILE:LINE: <reason> - ignored` on stderr. Globals `SETTINGS_US`, `SETTINGS_RS`.

- [ ] **Step 1: Write the failing test**

Create `tests/test-settings.sh`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-settings.sh`
Expected: FAIL at the `. lib/settings.sh` line (`No such file or directory`), exit non-zero.

- [ ] **Step 3: Write the parser**

Create `lib/settings.sh`:

```bash
# shellcheck shell=bash
# Settings file support for bootstrap.sh: a restricted TOML subset parsed with awk
# (no associative arrays, no gawk extensions - macOS ships bash 3.2 and BWK awk).
# Sourced, never executed; defining the functions has no side effects.
#
# Records: table<US>key<US>kind<US>value
#   US = $'\037'; kind = str | int | float | bool | array
#   array values: elements joined by RS = $'\036', each prefixed "s" (string) or
#   "r" (raw number / boolean).

SETTINGS_US=$'\037'
SETTINGS_RS=$'\036'
SETTINGS_FILE=""
SETTINGS_RECORDS=""

if ! command -v warn >/dev/null 2>&1; then warn() { printf 'warn: %s\n' "$*" >&2; }; fi
if ! command -v log >/dev/null 2>&1; then log() { printf '==> %s\n' "$*"; }; fi

# settings_parse FILE: syntax check and normalisation. Records go to stdout; every
# rejected line becomes "FILE:LINE: <reason> - ignored" on stderr.
settings_parse() {
  awk '
    function warn(msg) { printf "%s:%d: %s - ignored\n", FILENAME, FNR, msg > "/dev/stderr" }
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    # drop a trailing # comment that is not inside a string
    function strip_comment(s,   i, c, q, out) {
      q = 0; out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\" && q) { out = out c substr(s, i + 1, 1); i++; continue }
        if (c == "\"") q = !q
        if (c == "#" && !q) break
        out = out c
      }
      return out
    }
    # one scalar -> SK (kind) and SV (value); returns 0 when invalid
    function scalar(v,   i, c, n, out) {
      if (v ~ /^"/) {
        out = ""; i = 2
        while (i <= length(v)) {
          c = substr(v, i, 1)
          if (c == "\\") {
            n = substr(v, i + 1, 1)
            if (n != "\"" && n != "\\") return 0
            out = out n; i += 2; continue
          }
          if (c == "\"") {
            if (i != length(v)) return 0
            SK = "str"; SV = out; return 1
          }
          out = out c; i++
        }
        return 0
      }
      if (v ~ /^-?[0-9]+$/) { SK = "int"; SV = v; return 1 }
      if (v ~ /^-?[0-9]+\.[0-9]+$/) { SK = "float"; SV = v; return 1 }
      if (v == "true" || v == "false") { SK = "bool"; SV = v; return 1 }
      return 0
    }
    # one-line array of scalars -> SK = array, SV = prefixed elements joined by RS
    function array(v,   inner, i, c, q, tok, out, n) {
      inner = trim(substr(v, 2, length(v) - 2))
      if (inner == "") { SK = "array"; SV = ""; return 1 }
      out = ""; n = 0; tok = ""; q = 0
      for (i = 1; i <= length(inner) + 1; i++) {
        c = (i <= length(inner)) ? substr(inner, i, 1) : ","
        if (c == "\\" && q) { tok = tok c substr(inner, i + 1, 1); i++; continue }
        if (c == "\"") q = !q
        if (c == "," && !q) {
          if (!scalar(trim(tok))) return 0
          out = out (n++ ? "\036" : "") (SK == "str" ? "s" : "r") SV
          tok = ""; continue
        }
        tok = tok c
      }
      if (q) return 0
      SK = "array"; SV = out
      return 1
    }
    FNR == 1 && substr($0, 1, 3) == "\357\273\277" { $0 = substr($0, 4) }
    { line = trim(strip_comment($0)) }
    line == "" { next }
    line ~ /^\[/ {
      if (line !~ /^\[[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*\]$/) { warn("invalid table header"); skip = 1; table = ""; next }
      table = substr(line, 2, length(line) - 2)
      if (table != "bootstrap" && table != "ghostty" && table != "omnishell" && table !~ /^modules\./) {
        warn("unknown table [" table "]"); skip = 1; next
      }
      skip = 0; next
    }
    skip { next }
    {
      eq = index(line, "=")
      if (eq == 0) { warn("not a key = value line"); next }
      key = trim(substr(line, 1, eq - 1)); v = trim(substr(line, eq + 1))
      if (table == "") { warn("key outside a table"); next }
      if (key !~ /^[A-Za-z0-9_-]+$/) { warn("unsupported key \"" key "\""); next }
      if (v ~ /^\[/ && v ~ /\]$/) ok = array(v); else ok = scalar(v)
      if (!ok) { warn("invalid value for " key); next }
      printf "%s\037%s\037%s\037%s\n", table, key, SK, SV
    }
  ' "$1"
}
```

In `Makefile`, add `lib/settings.sh` to the `BASH_SCRIPTS` list:

```make
BASH_SCRIPTS := bootstrap.sh lib/settings.sh rootloops/apply.sh rootloops/gen-vte-terminal.sh bash/bashrc.bash $(wildcard bash/bashrc-*.bash) $(wildcard tests/*.sh)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-settings.sh`
Expected: every line `ok`, ending with `all checks passed`.

- [ ] **Step 5: Lint and commit**

```bash
make lint
git add lib/settings.sh tests/test-settings.sh Makefile
git commit -m "feat: add a restricted TOML parser for the settings file"
```

---

### Task 2: Schema validation and getters

**Files:**
- Modify: `lib/settings.sh` (append)
- Modify: `tests/test-settings.sh` (insert before the final `echo` / failures block)

**Interfaces:**
- Consumes: `settings_parse` from Task 1.
- Produces:
  - `settings_load FILE` fills `SETTINGS_RECORDS` (newline-separated records) from `FILE`, validating `[bootstrap]` and `[ghostty]` keys against the schema and passing every other table through; missing file is not an error.
  - `settings_get table.key` prints the value (arrays space-separated, booleans `true` / `false`), empty when unset; the last assignment wins.
  - `settings_schema_keys` prints one `table.key` per line.
  - `SETTINGS_SCHEMA` (key and type per line), `_settings_type table.key`.

- [ ] **Step 1: Write the failing test**

Insert into `tests/test-settings.sh` before the final `echo` / failures block:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-settings.sh`
Expected: FAIL with `settings_load: command not found` (the script aborts under `set -e`).

- [ ] **Step 3: Write the implementation**

Append to `lib/settings.sh`:

```bash

# Known keys of [bootstrap] and [ghostty], with the value type each one takes:
#   enum:a,b,c | bool | list | string | number
SETTINGS_SCHEMA='bootstrap.install_zsh enum:yes,no,ask
bootstrap.assume_yes bool
bootstrap.terminals list
ghostty.keybinds enum:auto,mac,linux
ghostty.font_family string
ghostty.font_size number
ghostty.background_opacity number'

settings_schema_keys() { printf '%s\n' "$SETTINGS_SCHEMA" | awk '{ print $1 }'; }

_settings_type() { printf '%s\n' "$SETTINGS_SCHEMA" | awk -v k="$1" '$1 == k { print $2 }'; }

# _settings_value_ok TYPE KIND VALUE
_settings_value_ok() {
  case "$1" in
    enum:*) [ "$2" = str ] || return 1
            case ",${1#enum:}," in *",$3,"*) return 0 ;; esac
            return 1 ;;
    bool) [ "$2" = bool ] ;;
    list) [ "$2" = array ] ;;
    string) [ "$2" = str ] ;;
    number) [ "$2" = int ] || [ "$2" = float ] ;;
    *) return 1 ;;
  esac
}

# settings_load FILE: parse and validate into SETTINGS_RECORDS. [bootstrap] and
# [ghostty] keys must be in the schema with the right type; omnishell and
# modules.* tables pass through (omnishell validate checks those later).
settings_load() {
  local table key kind value type
  SETTINGS_FILE="$1"
  SETTINGS_RECORDS=""
  [ -r "$1" ] || return 0
  while IFS="$SETTINGS_US" read -r table key kind value; do
    case "$table" in
      bootstrap | ghostty)
        type="$(_settings_type "$table.$key")"
        if [ -z "$type" ]; then
          warn "$1: unknown key '$key' in [$table] - ignored"
          continue
        fi
        if ! _settings_value_ok "$type" "$kind" "$value"; then
          warn "$1: invalid $table.$key value '${value//$SETTINGS_RS/,}' (expected ${type#enum:}) - ignored"
          continue
        fi ;;
    esac
    SETTINGS_RECORDS="${SETTINGS_RECORDS}${table}${SETTINGS_US}${key}${SETTINGS_US}${kind}${SETTINGS_US}${value}"$'\n'
  done < <(settings_parse "$1")
}

# settings_get table.key: the value; arrays space-separated; empty when unset.
settings_get() {
  printf '%s' "$SETTINGS_RECORDS" | awk -F"$SETTINGS_US" -v t="${1%.*}" -v k="${1##*.}" -v rs="$SETTINGS_RS" '
    $1 == t && $2 == k { v = $4; kind = $3 }
    END {
      if (kind == "array") {
        n = split(v, a, rs); out = ""
        for (i = 1; i <= n; i++) out = out (i > 1 ? " " : "") substr(a[i], 2)
        v = out
      }
      printf "%s", v
    }'
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-settings.sh`
Expected: all checks `ok`, `all checks passed`.

- [ ] **Step 5: Lint and commit**

```bash
make lint
git add lib/settings.sh tests/test-settings.sh
git commit -m "feat: validate settings against a schema and expose getters"
```

---

### Task 3: omnishell table merge

**Files:**
- Modify: `lib/settings.sh` (append)
- Modify: `tests/test-settings.sh` (insert before the final block)

**Interfaces:**
- Consumes: `SETTINGS_RECORDS` from `settings_load` (Task 2).
- Produces: `settings_merge_omnishell DEFAULT_FILE` prints the effective omnishell config on stdout: the default with every `omnishell` / `modules.*` table of the loaded settings replacing the same-named default table, unmatched override tables appended, all other lines (comments included) unchanged. Without overrides the output equals the default byte for byte.

- [ ] **Step 1: Write the failing test**

Insert before the final block of `tests/test-settings.sh`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-settings.sh`
Expected: FAIL with `settings_merge_omnishell: command not found`.

- [ ] **Step 3: Write the implementation**

Append to `lib/settings.sh`:

```bash

# TOML text for the omnishell / modules.* tables of the loaded settings, built
# from the validated records (never from raw file text). One table after the
# other, in order of first appearance; a repeated key keeps its last value.
_settings_omnishell_blocks() {
  printf '%s' "$SETTINGS_RECORDS" | awk -F"$SETTINGS_US" -v rs="$SETTINGS_RS" '
    function quote(s,   i, c, out) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\" || c == "\"") out = out "\\"
        out = out c
      }
      return "\"" out "\""
    }
    function element(e) { return substr(e, 1, 1) == "s" ? quote(substr(e, 2)) : substr(e, 2) }
    function render(kind, v,   n, a, i, out) {
      if (kind == "str") return quote(v)
      if (kind != "array") return v
      n = split(v, a, rs); out = ""
      for (i = 1; i <= n; i++) out = out (i > 1 ? ", " : "") element(a[i])
      return "[" out "]"
    }
    $1 == "omnishell" || $1 ~ /^modules\./ {
      if (!($1 in seen)) { seen[$1] = 1; tables[++nt] = $1 }
      tk = $1 SUBSEP $2
      if (!(tk in val)) klist[$1, ++kc[$1]] = $2
      val[tk] = render($3, $4)
    }
    END {
      for (i = 1; i <= nt; i++) {
        t = tables[i]; print "[" t "]"
        for (j = 1; j <= kc[t]; j++) print klist[t, j] " = " val[t SUBSEP klist[t, j]]
      }
    }'
}

# settings_merge_omnishell DEFAULT_FILE: the default config with the omnishell and
# modules.* tables of the loaded settings laid over it. A table replaces the
# default table of the same name as a whole; override tables the default lacks
# are appended; every other line, comments included, is kept as it is. Comment and
# blank lines directly above a table travel with that table.
settings_merge_omnishell() {
  OVR="$(_settings_omnishell_blocks)" awk '
    function blank_or_comment(s) { return s ~ /^[ \t]*(#.*)?$/ }
    function flush(   i) {
      printf "%s", lead
      if (bhas && (bh in otext)) { printf "%s", otext[bh]; used[bh] = 1; return }
      for (i = 1; i <= bc; i++) print bl[i]
    }
    BEGIN {
      n = split(ENVIRON["OVR"], ol, "\n"); cur = ""
      for (i = 1; i <= n; i++) {
        if (ol[i] ~ /^\[/) {
          cur = substr(ol[i], 2, length(ol[i]) - 2)
          if (!(cur in otext)) oorder[++no] = cur
          otext[cur] = otext[cur] ol[i] "\n"
        } else if (ol[i] != "") otext[cur] = otext[cur] ol[i] "\n"
      }
      lead = ""; bh = ""; bhas = 0; bc = 0
    }
    /^\[[^\[]/ {
      k = bc
      while (k > 0 && blank_or_comment(bl[k])) k--
      newlead = ""
      for (i = k + 1; i <= bc; i++) newlead = newlead bl[i] "\n"
      bc = k
      flush()
      name = substr($0, 2); sub(/\].*$/, "", name); gsub(/^[ \t]+|[ \t]+$/, "", name)
      lead = newlead; bh = name; bhas = 1; bc = 1; bl[1] = $0
      next
    }
    { bc++; bl[bc] = $0 }
    END {
      flush()
      for (i = 1; i <= no; i++) if (!(oorder[i] in used)) printf "\n%s", otext[oorder[i]]
    }
  ' "$1"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-settings.sh`
Expected: all checks `ok`. If `a duplicate key keeps the last value, once` fails because of backslash quoting in the test expression, print `$OUT` and fix the expected string, not the awk.

- [ ] **Step 5: Lint and commit**

```bash
make lint
git add lib/settings.sh tests/test-settings.sh
git commit -m "feat: merge omnishell overrides from the settings file"
```

---

### Task 4: Ghostty rendering and legacy migration

**Files:**
- Modify: `lib/settings.sh` (append)
- Modify: `tests/test-settings.sh` (insert before the final block)

**Interfaces:**
- Consumes: `settings_get`, `warn`, `log`.
- Produces:
  - `settings_render_ghostty` prints Ghostty `key = value` lines for the set `ghostty.font_family` / `font_size` / `background_opacity` (nothing when none is set).
  - `settings_migrate_legacy LEGACY NEW`: when `LEGACY` exists and `NEW` does not, converts the known `KEY=value` lines into `NEW` and renames `LEGACY` to `LEGACY.migrated`; a legacy file with no active key is only renamed (no `NEW`); otherwise it does nothing.

- [ ] **Step 1: Write the failing test**

Insert before the final block of `tests/test-settings.sh`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-settings.sh`
Expected: FAIL with `settings_render_ghostty: command not found`.

- [ ] **Step 3: Write the implementation**

Append to `lib/settings.sh`:

```bash

# Ghostty `key = value` lines for the [ghostty] values that are set. `keybinds`
# is not rendered: setup_ghostty_keybinds links the matching keybinds file.
settings_render_ghostty() {
  local v
  v="$(settings_get ghostty.font_family)"
  if [ -n "$v" ]; then
    v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
    printf 'font-family = "%s"\n' "$v"
  fi
  v="$(settings_get ghostty.font_size)"
  [ -z "$v" ] || printf 'font-size = %s\n' "$v"
  v="$(settings_get ghostty.background_opacity)"
  [ -z "$v" ] || printf 'background-opacity = %s\n' "$v"
}

# settings_migrate_legacy LEGACY NEW: one-time conversion of the old KEY=value
# bootstrap.conf. Only runs when LEGACY exists and NEW does not. A legacy file
# without an active key (the seeded template) is renamed, not converted.
settings_migrate_legacy() {
  local legacy="$1" new="$2" line key value t list="" install="" assume="" terminals=""
  { [ -f "$legacy" ] && [ ! -e "$new" ]; } || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"; key="${key//[[:space:]]/}"
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
    case "$key" in
      INSTALL_ZSH) case "$value" in yes | no | ask) install="$value" ;; esac ;;
      ASSUME_YES) case "$value" in yes) assume=true ;; no) assume=false ;; esac ;;
      TERMINALS) terminals="$value" ;;
    esac
  done < "$legacy"
  for t in $terminals; do
    case "$t" in
      *[!A-Za-z0-9_.-]*) warn "$legacy: skipped terminal '$t' (not a valid package name)" ;;
      *) list="${list:+$list, }\"$t\"" ;;
    esac
  done
  if [ -z "$install$assume$list" ]; then
    mv "$legacy" "$legacy.migrated"
    return 0
  fi
  mkdir -p "$(dirname "$new")"
  {
    printf '# Migrated from bootstrap.conf. config.toml.example lists every option.\n[bootstrap]\n'
    [ -z "$install" ] || printf 'install_zsh = "%s"\n' "$install"
    [ -z "$assume" ] || printf 'assume_yes = %s\n' "$assume"
    [ -z "$list" ] || printf 'terminals = [%s]\n' "$list"
  } > "$new"
  mv "$legacy" "$legacy.migrated"
  log "migrated $legacy to $new"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-settings.sh`
Expected: all checks `ok`.

- [ ] **Step 5: Lint and commit**

```bash
make lint
git add lib/settings.sh tests/test-settings.sh
git commit -m "feat: render Ghostty settings and migrate bootstrap.conf"
```

---

### Task 5: Bootstrap reads the TOML settings file

**Files:**
- Create: `config.toml.example`
- Create: `tests/test-bootstrap-settings.sh`
- Modify: `bootstrap.sh`
- Modify: `tests/test-zsh-install.sh`
- Delete: `bootstrap.conf.example`

**Interfaces:**
- Consumes: `settings_migrate_legacy`, `settings_load`, `settings_get`, `settings_schema_keys` (Tasks 1, 2, 4).
- Produces: `bootstrap.sh` sets `BOOTSTRAP_CONFIG` (`${DOTFILES_CONFIG:-$HOME/.config/dotfiles/config.toml}`), `CONF_INSTALL_ZSH`, `CONF_ASSUME_YES` (`true` / `false` / empty), `CONF_TERMINALS`, `CONF_GHOSTTY_KEYBINDS`; `seed_bootstrap_config` copies `config.toml.example`.

- [ ] **Step 1: Write the template and the failing integration test**

Create `config.toml.example`:

```toml
# Settings for bootstrap.sh - machine-specific, not version-controlled.
#
# bootstrap.sh copies this template to ~/.config/dotfiles/config.toml on the first
# run and never overwrites that file afterwards. Remove the leading "# " from a
# table header and a key to change a setting.
#
# Format: a small TOML subset - [tables], key = value with strings, numbers,
# booleans and one-line arrays, and # comments. The file is parsed, never
# executed; unknown tables, unknown keys and invalid values are reported and
# ignored.
# Precedence: command-line flag > environment variable > this file > default.

# [bootstrap]
#
# Install zsh when it is missing: "yes", "no" or "ask". Only an explicit "yes"
# installs it; --yes alone never does. "ask" prompts when a terminal is available
# and otherwise prints a hint.
# Flags: --install-zsh / --no-install-zsh    Environment: DOTFILES_INSTALL_ZSH
#install_zsh = "ask"
#
# Answer "yes" to every prompt, e.g. switch rc files and stow links from another
# checkout to this one.
# Flag: --yes    Environment: DOTFILES_ASSUME_YES (1 or 0)
#assume_yes = false
#
# Extra terminal stow packages (Ghostty is always stowed).
# Environment: DOTFILES_TERMINALS (space-separated)
#terminals = []

# [ghostty]
#
# Keybind scheme: "auto" (macOS: mac, otherwise linux), "mac" or "linux".
# Environment: DOTFILES_GHOSTTY_KEYBINDS
#keybinds = "auto"
#
# Written to ~/.config/ghostty-settings.conf; an unset key keeps the default from
# the tracked Ghostty config. Hand-written overrides in ~/.config/ghostty.local
# still win.
#font_family = "Cascadia Mono NF"
#font_size = 12
#background_opacity = 0.98

# omnishell: a table below replaces the whole table of the same name in the
# tracked omnishell/config.toml - restate every key you want to keep. Tables the
# default does not have are added. `omnishell validate` checks the result.
#
# [modules.history.options]
# size = 50000
#
# [modules.zoxide]
# enabled = false
```

Create `tests/test-bootstrap-settings.sh`:

```bash
#!/usr/bin/env bash
# bootstrap.sh and the settings file: template, seeding, migration, resolved
# settings. (omnishell and Ghostty output are covered further down.)
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
for tool in head rm cat cp mkdir basename dirname uname id tr awk grep sed ln readlink cmp mv mktemp tee; do
  ln -s "$(command -v "$tool")" "$WORK/bin/$tool"
done

CONF="$WORK/cfg/config.toml"
OUT=""; RC=0
fresh() { rm -rf "$WORK/cfg" "$WORK/home"; mkdir -p "$WORK/cfg" "$WORK/home/.config"; }
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
check "the legacy value is picked up in the same run" '[ "$OUT" = yes ]'
check "config.toml exists and the legacy file is renamed" '[ -f "$CONF" ] && [ -f "$WORK/cfg/bootstrap.conf.migrated" ] && [ ! -e "$WORK/cfg/bootstrap.conf" ]'
cp "$CONF" "$WORK/first"
sh_run '' 'true'
check "a second run changes nothing"                'cmp -s "$CONF" "$WORK/first"'
fresh; rm -f "$CONF"
cp "$DOTFILES/config.toml.example" "$WORK/cfg/bootstrap.conf"
sh_run '' 'seed_bootstrap_config'
check "a commented-out legacy file leads to the plain template" 'cmp -s "$CONF" "$TEMPLATE"'

echo
if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-bootstrap-settings.sh`
Expected: FAIL (the template checks may pass, the `sh_run` checks fail because `bootstrap.sh` still reads `bootstrap.conf` and `CONF_*` keep the old semantics).

- [ ] **Step 3: Change `bootstrap.sh`**

(a) Header comment, the zsh paragraph: replace
`# or INSTALL_ZSH=yes in ~/.config/dotfiles/bootstrap.conf) - never by --yes alone.`
with
`# or install_zsh = "yes" in ~/.config/dotfiles/config.toml) - never by --yes alone.`

(b) Replace everything between the `warn()` definition and the line `# --install-zsh / --no-install-zsh: explicit zsh choice, beats env and config file.` with:

```bash

# Settings file (untracked, per machine, seeded from config.toml.example): a
# restricted TOML subset parsed by lib/settings.sh, never sourced. Precedence
# everywhere: flag > environment > settings file > default.
# shellcheck source=lib/settings.sh
. "$DOTFILES/lib/settings.sh"
BOOTSTRAP_CONFIG="${DOTFILES_CONFIG:-$HOME/.config/dotfiles/config.toml}"
settings_migrate_legacy "$(dirname "$BOOTSTRAP_CONFIG")/bootstrap.conf" "$BOOTSTRAP_CONFIG"
settings_load "$BOOTSTRAP_CONFIG"
CONF_INSTALL_ZSH="$(settings_get bootstrap.install_zsh)"
CONF_ASSUME_YES="$(settings_get bootstrap.assume_yes)"
CONF_TERMINALS="$(settings_get bootstrap.terminals)"
CONF_GHOSTTY_KEYBINDS="$(settings_get ghostty.keybinds)"

# --yes / -y (or DOTFILES_ASSUME_YES=1, or assume_yes = true in the settings file):
# don't prompt - e.g. switch rc files and stow links from another checkout to this
# one without asking.
if [ -n "${DOTFILES_ASSUME_YES:-${ASSUME_YES:-}}" ]; then
  ASSUME_YES="${DOTFILES_ASSUME_YES:-$ASSUME_YES}"
elif [ "$CONF_ASSUME_YES" = true ]; then
  ASSUME_YES=1
else
  ASSUME_YES=0
fi
```

(c) In the ghostty keybinds function, replace the first `local` line's scheme default so the settings file feeds it:

```bash
  local scheme="${DOTFILES_GHOSTTY_KEYBINDS:-${CONF_GHOSTTY_KEYBINDS:-auto}}" link="$HOME/.config/ghostty-keybinds.conf"
```

(d) In `_install_zsh_mode`, replace the env validation (`_valid_config_value` is gone) with:

```bash
_install_zsh_mode() {
  local mode="$INSTALL_ZSH_FLAG"
  if [ -z "$mode" ] && [ -n "${DOTFILES_INSTALL_ZSH:-}" ]; then
    case "$DOTFILES_INSTALL_ZSH" in
      yes | no | ask) mode="$DOTFILES_INSTALL_ZSH" ;;
      *) warn "invalid DOTFILES_INSTALL_ZSH value '$DOTFILES_INSTALL_ZSH' (use yes, no or ask) - ignored" ;;
    esac
  fi
  printf '%s' "${mode:-${CONF_INSTALL_ZSH:-ask}}"
}
```

(e) Replace `seed_bootstrap_config`:

```bash
seed_bootstrap_config() {
  [ -e "$BOOTSTRAP_CONFIG" ] && return 0
  mkdir -p "$(dirname "$BOOTSTRAP_CONFIG")"
  cp "$DOTFILES/config.toml.example" "$BOOTSTRAP_CONFIG"
  log "wrote $BOOTSTRAP_CONFIG (all settings commented out)"
}
```

(f) `git rm bootstrap.conf.example`.

- [ ] **Step 4: Convert `tests/test-zsh-install.sh` to TOML**

Edit `tests/test-zsh-install.sh`:

1. Replace every `$WORK/bootstrap.conf` with `$WORK/config.toml` (in `reset`, `config`, and `run`).
2. Convert each fixture line (exact replacements):
   - `config 'INSTALL_ZSH=yes'` -> `config '[bootstrap]' 'install_zsh = "yes"'` (same for `no` and `ask`, every occurrence; use `sed -i.bak -E "s/config 'INSTALL_ZSH=(yes|no|ask)'/config '[bootstrap]' 'install_zsh = \"\1\"'/" tests/test-zsh-install.sh && rm tests/test-zsh-install.sh.bak`)
   - `config '# machine settings' '' 'INSTALL_ZSH=yes'` -> `config '# machine settings' '' '[bootstrap]' 'install_zsh = "yes"'`
   - `config 'INSTALL_ZSH = yes  # padded'` -> `config '[bootstrap]' 'install_zsh = "yes"  # padded'`
   - `config 'INSTALL_ZSH=maybe'` -> `config '[bootstrap]' 'install_zsh = "maybe"'`; the warn check `grep -q \"invalid INSTALL_ZSH\"` -> `grep -q \"invalid bootstrap.install_zsh\"`
   - `config 'FOO=bar' '$(touch '"$WORK"'/pwned)'` -> `config '[bootstrap]' 'foo = "bar"' '$(touch '"$WORK"'/pwned)'` (the `unknown key` check stays)
3. Delete the whole block from `echo ">> settings template and other keys"` up to, but not including, `echo ">> command line"`; those cases now live in `tests/test-bootstrap-settings.sh`.

- [ ] **Step 5: Run everything**

Run: `make lint test`
Expected: `tests/test-settings.sh`, `tests/test-bootstrap-settings.sh`, `tests/test-zsh-install.sh` and the other tests all pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: read the bootstrap options from a TOML settings file"
```

---

### Task 6: Apply omnishell and Ghostty settings

**Files:**
- Modify: `bootstrap.sh` (`apply_omnishell`, new `render_ghostty_settings`, `main`)
- Modify: `ghostty/.config/ghostty/config`
- Modify: `tests/test-bootstrap-settings.sh` (insert before the final block)

**Interfaces:**
- Consumes: `settings_merge_omnishell`, `settings_render_ghostty` (Tasks 3, 4), `BOOTSTRAP_CONFIG`.
- Produces: `_write_omnishell_config` (writes the merged config to `${XDG_CONFIG_HOME:-$HOME/.config}/omnishell/config.toml`), `apply_omnishell` runs `omnishell validate` after the final write and exits 2 on failure, `render_ghostty_settings` (writes or removes `~/.config/ghostty-settings.conf`), both wired into `main`.

- [ ] **Step 1: Write the failing tests**

Insert into `tests/test-bootstrap-settings.sh` before the final block:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-bootstrap-settings.sh`
Expected: FAIL (`render_ghostty_settings: command not found`, merged config not written).

- [ ] **Step 3: Implement**

(a) In `bootstrap.sh`, add a helper above `apply_omnishell` and use it in both places:

```bash
# the tracked omnishell default with the settings file's omnishell / modules.*
# tables laid over it
_write_omnishell_config() {
  local cfgdir="${XDG_CONFIG_HOME:-$HOME/.config}/omnishell"
  mkdir -p "$cfgdir"
  settings_merge_omnishell "$DOTFILES/omnishell/config.toml" > "$cfgdir/config.toml"
}
```

Replace the start of `apply_omnishell` (up to and including the second `cp`) with:

```bash
apply_omnishell() {
  _write_omnishell_config
  log "omnishell init + apply"
  omnishell init -y 2>/dev/null || omnishell init || true
  _write_omnishell_config   # init may template a fresh one
  omnishell validate || {
    warn "the omnishell config is invalid - fix the [omnishell] / [modules.*] tables in $BOOTSTRAP_CONFIG"
    exit 2
  }
```

(keep the rest of the function, from `# exit 1 = degraded module(s)` on, unchanged).

(b) Add after `setup_ghostty_keybinds`:

```bash
# --------------------------------------------------------------------------
# 3a'. ghostty values from the [ghostty] table of the settings file, written to
#      a generated include outside the stowed directory (it is loaded before
#      ~/.config/ghostty.local, so hand-written overrides still win). A file
#      this script did not generate is never touched.
# --------------------------------------------------------------------------
GHOSTTY_SETTINGS_MARK="# GENERATED by bootstrap.sh from the [ghostty] table of the settings file - do not edit"

render_ghostty_settings() {
  local out="$HOME/.config/ghostty-settings.conf" body
  body="$(settings_render_ghostty)"
  if [ -e "$out" ] && ! head -n 1 "$out" | grep -qxF "$GHOSTTY_SETTINGS_MARK"; then
    warn "$out is not generated by bootstrap.sh - left untouched"
    return 0
  fi
  if [ -z "$body" ]; then
    rm -f "$out"
    return 0
  fi
  mkdir -p "$(dirname "$out")"
  printf '%s\n%s\n' "$GHOSTTY_SETTINGS_MARK" "$body" > "$out"
  log "wrote $out"
}
```

and in `main`, after `setup_ghostty_keybinds`, add `  render_ghostty_settings`.

(c) In `ghostty/.config/ghostty/config`, insert between the keybinds include block and the per-machine overrides block:

```
# Values from the [ghostty] table of ~/.config/dotfiles/config.toml, generated by
# bootstrap.sh (font, size, opacity). Loaded before the per-machine overrides below.
config-file = ?~/.config/ghostty-settings.conf

```

- [ ] **Step 4: Run everything**

Run: `make lint test`
Expected: all tests pass, including `tests/test-omnishell-toolchain.sh` (its omnishell stubs return 0 for `validate`) and `tests/test-ghostty-keybinds.sh` (the per-machine include is still last).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: apply omnishell and Ghostty settings from the settings file"
```

---

### Task 7: Documentation

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the behavior from Tasks 1-6.

- [ ] **Step 1: Update the README**

Replace the `## ⚙️ Bootstrap configuration` section (from its heading to the next `---`) with:

````markdown
## ⚙️ Settings file

Every per-machine choice lives in one untracked file:
`~/.config/dotfiles/config.toml`. The first run copies
[`config.toml.example`](config.toml.example) there with every option commented
out, so the file itself shows what is available. An existing file is never
overwritten. Point `DOTFILES_CONFIG` at another path to use a different file.

| Table / key                        | Values                          | Default | Command line                         | Environment             |
|------------------------------------|---------------------------------|---------|--------------------------------------|-------------------------|
| `[bootstrap]` `install_zsh`        | `"yes"` · `"no"` · `"ask"`      | `"ask"` | `--install-zsh` / `--no-install-zsh` | `DOTFILES_INSTALL_ZSH`  |
| `[bootstrap]` `assume_yes`         | `true` · `false`                | `false` | `--yes`                              | `DOTFILES_ASSUME_YES`   |
| `[bootstrap]` `terminals`          | list of package names           | `[]`    | -                                    | `DOTFILES_TERMINALS`    |
| `[ghostty]` `keybinds`             | `"auto"` · `"mac"` · `"linux"`  | `"auto"`| -                                    | `DOTFILES_GHOSTTY_KEYBINDS` |
| `[ghostty]` `font_family`, `font_size`, `background_opacity` | string, number, number | the tracked Ghostty config | - | - |
| `[omnishell]`, `[modules.*]`       | omnishell's own config          | `omnishell/config.toml` | - | - |

Precedence: command line, then environment, then the settings file, then the default.

```toml
# ~/.config/dotfiles/config.toml
[bootstrap]
install_zsh = "yes"
terminals = ["alacritty", "kitty"]

[ghostty]
font_size = 13

[modules.history.options]
size = 10000
```

> [!NOTE]
> zsh is installed only on an **explicit "yes"**; `--yes` / `assume_yes` alone never
> installs it. With `"ask"` (the default), `bootstrap.sh` prompts when a terminal is
> available and otherwise prints a hint and carries on, so bash stays fully usable.
> zsh is installed with `brew` or `apt-get`; `chsh` is never run.

**omnishell.** `omnishell/config.toml` stays the tracked default. A table in your
settings file replaces the whole table of the same name, so restate every key you
want to keep; tables the default does not have are added. The merged result is
written to `~/.config/omnishell/config.toml` on every run and checked with
`omnishell validate`; an invalid result stops the bootstrap. Change modules here,
not with `omnishell set`, which the next run would overwrite.

**Ghostty.** The `[ghostty]` values are written to the generated
`~/.config/ghostty-settings.conf`, loaded after the tracked config and before your
hand-written `~/.config/ghostty.local`.

The file is a small TOML subset (tables, strings, numbers, booleans, one-line
arrays, `#` comments), parsed line by line and never executed; unknown tables, keys
and invalid values are reported and ignored. An old `~/.config/dotfiles/bootstrap.conf`
is converted once and renamed `bootstrap.conf.migrated`.
````

Then update the other mentions:
- Install step 2 link text: `(see [Settings file](#️-settings-file))`.
- The terminals sentence: `... or `terminals` in the [settings file](#️-settings-file).`
- File tree: replace the `bootstrap.conf.example` line with `config.toml.example      template for ~/.config/dotfiles/config.toml (all options, commented out)` and add `lib/settings.sh            settings file parser, merge and migration (sourced by bootstrap.sh)`.

- [ ] **Step 2: Verify**

Run: `grep -n "bootstrap.conf" README.md`
Expected: only the migration sentence mentions `bootstrap.conf`.

Run: `make lint test`
Expected: all green.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document the settings file"
```
