# Interactive Install Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `./bootstrap.sh --interactive` asks for the dotfiles-owned settings, lets the user pick modules in `omnishell tui`, and writes both into `~/.config/dotfiles/config.toml` before the normal install runs.

**Architecture:** `lib/settings.sh` gains a prompt-answer-to-TOML-literal converter and two text-level writers (`settings_update_file` for keys, `settings_update_omnishell` for whole omnishell tables) that keep comments and unknown content. `bootstrap.sh` gets the flag, preconditions, an `interactive_settings` step before `install_deps` and an `interactive_modules` step after `install_omnishell`; the TUI edits the live omnishell config, and the result is read back and compared with the tracked default.

**Tech Stack:** Bash 3.2-compatible shell, awk (BWK / mawk compatible), `diff`, the repo's `tests/test-*.sh` style.

**Spec:** `docs/superpowers/specs/2026-10-07-interactive-install-design.md`

## Global Constraints

- `--interactive` together with `--yes` / `-y` is an error (exit 2); without a terminal on stdin and stdout it exits 2 with `--interactive needs a terminal; run without it, or edit <config> by hand` before anything is written.
- `OMNISHELL_MIN_VERSION` is `0.7.0` for every run.
- Prompts: Enter keeps the shown value, `-` unsets the key, an invalid answer is asked again with the same validation as when the file is read (`_settings_value_ok`). Nothing invalid is ever written.
- The settings file is edited as text: comments, commented template lines, unknown tables and unknown keys are kept. A changed file is shown as `diff -u`, confirmed with `[y/N]`, and the previous file is saved as `<file>.bak`. `n` leaves the file untouched and ends the run with exit 0 before anything is installed.
- Omnishell tables are written as a whole table (a table replaces the tracked default as a whole). A table equal to the tracked default drops its override.
- `apply_omnishell` stays the only place that runs `omnishell apply`.
- Precedence unchanged: flag > environment > settings file > default. No new dependency (plain `read`).
- Bash 3.2 and BWK awk / mawk compatible; the settings file is parsed, never executed.
- Code and docs in English; commit messages `<type>: <description>` without trailers; `make lint test` green before each commit.

## Review Focus

- Pressing Enter at every prompt leaves the file byte-identical and writes no `.bak`. Pinned in Task 5.
- An invalid answer is never written: it is asked again and the run continues with the next valid answer. Pinned in Tasks 1 and 5.
- Answering `n` to the diff writes nothing and installs nothing; end of input at a prompt aborts with exit 1 and a message. Pinned in Task 5.
- Comments, commented template lines, unknown tables and a second table are kept when keys are replaced, inserted or cleared. Pinned in Task 2.
- Reverting a module to the tracked default in the TUI drops its override instead of writing a copy of the default. Pinned in Tasks 3 and 5.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/settings.sh` (modify) | `_settings_literal`, `settings_update_file`, `settings_omnishell_changes`, `settings_update_omnishell` |
| `bootstrap.sh` (modify) | `--interactive`, preconditions, `read_conf_values` / `build_packages` / `reload_settings`, `prepare_omnishell_config`, prompts, review step, TUI step, `main()` wiring, minimum version 0.7.0 |
| `config.toml.example` (modify) | one comment line about `--interactive` |
| `README.md` (modify) | version floor, `--interactive` paragraph |
| `tests/test-settings.sh` (modify) | converter and both writers |
| `tests/test-interactive.sh` (create) | arguments, preconditions, prompts, review step, TUI hand-over |
| `tests/test-omnishell-toolchain.sh` (modify) | version floor 0.7.0 |

Code blocks whose first line is `# plan-apply: ...` are applied literally by the executor: `append <file>` appends the block, `insert-before-final <file>` inserts it before the final summary of a test file, `create <file>` writes the file, `python` blocks are run with `python3`.

---

### Task 1: Prompt answer to TOML literal

**Files:**
- Modify: `lib/settings.sh`, `tests/test-settings.sh`

**Interfaces:**
- Produces: `_settings_literal TYPE ANSWER` prints the TOML literal for the answer on stdout and returns 0, or returns 1 (nothing printed) when the answer is empty, contains a control character, or fails `_settings_value_ok`. `TYPE` is a schema type (`enum:a,b`, `bool`, `list`, `string`, `number`, `positive`, `fraction`, `nonneg`, `posint`, `tmuxkey`, `email`). Bool accepts `true|yes|y` / `false|no|n`; a list splits on spaces and commas.

- [ ] **Step 1: Write the failing test**

```bash
# plan-apply: insert-before-final tests/test-settings.sh
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-settings.sh 2>&1 | tail -25`
Expected: FAIL lines for the `_settings_literal` checks (`_settings_literal: command not found`), nothing else new failing.

- [ ] **Step 3: Write minimal implementation**

```bash
# plan-apply: python
import re
p = 'lib/settings.sh'
s = open(p).read()
anchor = "# settings_load FILE: parse and validate into SETTINGS_RECORDS."
assert anchor in s
new = r'''# _settings_literal TYPE ANSWER: the TOML literal for a prompt answer, printed to
# stdout; returns 1 (printing nothing) when the answer is empty, has a control
# character, or is not valid for TYPE by the rules used when the file is read.
_settings_literal() {
  local type="$1" ans="$2" kind value="" item out="" sep="" int_re='^-?[0-9]+$' float_re='^-?[0-9]+\.[0-9]+$'
  [ -n "$ans" ] || return 1
  case "$ans" in *[[:cntrl:]]*) return 1 ;; esac
  case "$type" in
    bool)
      case "$ans" in
        true | yes | y) kind=bool; value=true ;;
        false | no | n) kind=bool; value=false ;;
        *) return 1 ;;
      esac ;;
    list)
      kind=array
      set -f
      for item in ${ans//,/ }; do
        case "$item" in *[\"\\]*) set +f; return 1 ;; esac
        value="${value}${value:+$SETTINGS_RS}s$item"
        out="${out}${sep}\"$item\""; sep=", "
      done
      set +f
      [ -n "$value" ] || return 1 ;;
    number | positive | fraction | nonneg | posint)
      if [[ "$ans" =~ $int_re ]]; then kind=int
      elif [[ "$ans" =~ $float_re ]]; then kind=float
      else return 1; fi
      value="$ans" ;;
    *) kind=str; value="$ans" ;;
  esac
  _settings_value_ok "$type" "$kind" "$value" || return 1
  case "$kind" in
    str) printf '"%s"\n' "$(printf '%s' "$value" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')" ;;
    array) printf '[%s]\n' "$out" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

'''
open(p, 'w').write(s.replace(anchor, new + anchor, 1))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-settings.sh 2>&1 | tail -25`
Expected: all `_settings_literal` checks `ok`, `all checks passed`.

- [ ] **Step 5: Commit**

```bash
git add lib/settings.sh tests/test-settings.sh
git commit -m "feat: convert prompt answers to validated TOML literals"
```

---

### Task 2: Update keys in the settings file

**Files:**
- Modify: `lib/settings.sh`, `tests/test-settings.sh`

**Interfaces:**
- Consumes: `SETTINGS_US` (field separator `\037`).
- Produces: `settings_update_file FILE CHANGES` prints the new file text to stdout. `CHANGES` is newline-separated `table<US>key<US>literal`; an empty literal clears the key. An active `key = value` line of that table is replaced in place (duplicates collapse to one), a missing key is inserted right below its `[table]` header, a missing table is appended (blank line, header, keys), a cleared key loses its active line. Everything else, commented lines included, is copied through. Empty `CHANGES` prints the file as it is.

- [ ] **Step 1: Write the failing test**

```bash
# plan-apply: insert-before-final tests/test-settings.sh
echo ">> settings_update_file"
chg() { printf '%s\037%s\037%s\n' "$@"; }
write '# top comment' '[tmux]' '# mouse is off here' 'mouse = false # was off' 'prefix = "C-a"' '' '[git]' 'user_name = "A"' '#editor = "vi"'
OUT="$(settings_update_file "$F" "$(chg tmux mouse true)")"
check "an active key is replaced in place"        'grep -qx "mouse = true" <<< "$OUT" && ! grep -q "mouse = false" <<< "$OUT"'
check "the comment lines and other keys stay"     'grep -qx "# top comment" <<< "$OUT" && grep -qx "# mouse is off here" <<< "$OUT" && grep -qx "prefix = \"C-a\"" <<< "$OUT"'
check "the key keeps its line"                    '[ "$(sed -n 4p <<< "$OUT")" = "mouse = true" ]'
OUT="$(settings_update_file "$F" "$(chg tmux mode_keys '"vi"')")"
check "a new key goes right below its header"     '[ "$(sed -n 3p <<< "$OUT")" = "mode_keys = \"vi\"" ]'
OUT="$(settings_update_file "$F" "$(chg git editor '"nvim"')")"
check "a commented template line is not touched"  'grep -qx "#editor = \"vi\"" <<< "$OUT" && grep -qx "editor = \"nvim\"" <<< "$OUT"'
OUT="$(settings_update_file "$F" "$(chg ghostty font_size 14)")"
check "a new table is appended after a blank line" '[ "$(tail -3 <<< "$OUT" | head -1)" = "" ] && [ "$(tail -2 <<< "$OUT" | head -1)" = "[ghostty]" ] && [ "$(tail -1 <<< "$OUT")" = "font_size = 14" ]'
OUT="$(settings_update_file "$F" "$(chg tmux prefix '')")"
check "an empty literal clears the key"           '! grep -q "^prefix" <<< "$OUT" && grep -qx "mouse = false # was off" <<< "$OUT"'
OUT="$(settings_update_file "$F" "$(chg tmux prefix '' ; chg tmux mouse true; chg git user_name '"B"')")"
check "several changes in one pass"               'grep -qx "mouse = true" <<< "$OUT" && grep -qx "user_name = \"B\"" <<< "$OUT" && ! grep -q "^prefix" <<< "$OUT"'
OUT="$(settings_update_file "$F" "")"
check "no changes print the file as it is"        '[ "$OUT" = "$(cat "$F")" ]'
write '[tmux]' 'mouse = false' 'mouse = true' 'prefix = "C-b"'
OUT="$(settings_update_file "$F" "$(chg tmux mouse false)")"
check "a repeated key collapses to one line"      '[ "$(grep -c "^mouse" <<< "$OUT")" = 1 ]'
write '[bootstrap]' 'install_zsh = "ask"' '[modules.fzf]' 'enabled = true'
OUT="$(settings_update_file "$F" "$(chg bootstrap terminals '["foot"]')")"
check "an unknown table stays untouched"          'grep -qx "\[modules.fzf\]" <<< "$OUT" && grep -qx "enabled = true" <<< "$OUT"'
printf '%s\n' "$OUT" > "$WORK/updated.toml"
settings_load "$WORK/updated.toml" 2>/dev/null
check "the updated file loads back"               '[ "$(settings_get bootstrap.terminals)" = foot ] && [ "$(settings_get bootstrap.install_zsh)" = ask ]'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-settings.sh 2>&1 | grep -c FAIL`
Expected: a non-zero count (`settings_update_file: command not found` makes the new checks fail).

- [ ] **Step 3: Write minimal implementation**

```bash
# plan-apply: python
p = 'lib/settings.sh'
s = open(p).read()
anchor = "# settings_load FILE: parse and validate into SETTINGS_RECORDS."
assert anchor in s
new = r'''# settings_update_file FILE CHANGES: FILE's text with the key changes applied, on
# stdout. CHANGES is newline-separated table<US>key<US>literal, the literal being
# TOML text ready to write; an empty literal clears the key. An active key line is
# replaced in place (repeats collapse into the first), a missing key goes right
# below its [table] header, a missing table is appended, a cleared key loses its
# active line. Every other line - comments, commented template lines, tables and
# keys the schema does not know - is copied as it is.
settings_update_file() {
  CHG="$2" awk -v us="$SETTINGS_US" '
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function header(line) { return line ~ /^[ \t]*\[[^\[].*\]/ }
    function tname(line,   n) { n = line; sub(/^[ \t]*\[/, "", n); sub(/\].*$/, "", n); return trim(n) }
    function keyof(line,   k) {
      if (line !~ /^[ \t]*[A-Za-z0-9_-]+[ \t]*=/) return ""
      k = line; sub(/^[ \t]*/, "", k); sub(/[ \t]*=.*$/, "", k); return k
    }
    BEGIN {
      n = split(ENVIRON["CHG"], rows, "\n"); nc = 0
      for (i = 1; i <= n; i++) {
        if (rows[i] == "") continue
        split(rows[i], f, us)
        nc++; ct[nc] = f[1]; ck[nc] = f[2]; cl[nc] = f[3]
        want[f[1], f[2]] = nc
      }
    }
    FNR == NR {
      if (header($0)) { t = tname($0); known[t] = 1 }
      else if ((k = keyof($0)) != "") active[t, k] = 1
      next
    }
    FNR == 1 { t = "" }
    header($0) {
      t = tname($0); print
      for (i = 1; i <= nc; i++)
        if (ct[i] == t && cl[i] != "" && !((t, ck[i]) in active) && !(i in done)) {
          print ck[i] " = " cl[i]; done[i] = 1
        }
      next
    }
    (k = keyof($0)) != "" && ((t, k) in want) {
      i = want[t, k]
      if (!(i in done)) { if (cl[i] != "") print k " = " cl[i]; done[i] = 1 }
      next
    }
    { print }
    END {
      for (i = 1; i <= nc; i++) {
        if (cl[i] == "" || (ct[i] in known) || (ct[i] in tdone)) continue
        print ""; print "[" ct[i] "]"; tdone[ct[i]] = 1
        for (j = i; j <= nc; j++) if (ct[j] == ct[i] && cl[j] != "") print ck[j] " = " cl[j]
      }
    }
  ' "$1" "$1"
}

'''
open(p, 'w').write(s.replace(anchor, new + anchor, 1))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-settings.sh 2>&1 | tail -30`
Expected: every `settings_update_file` check `ok`, `all checks passed`. If a check fails on the line numbers (`sed -n 3p` / `4p`), count the fixture lines again before touching the code.

- [ ] **Step 5: Commit**

```bash
git add lib/settings.sh tests/test-settings.sh
git commit -m "feat: update keys in the settings file without losing comments"
```

---

### Task 3: Take over omnishell tables

**Files:**
- Modify: `lib/settings.sh`, `tests/test-settings.sh`

**Interfaces:**
- Consumes: `settings_parse FILE`, `_settings_omnishell_blocks` (reads `SETTINGS_RECORDS`).
- Produces:
  - `settings_omnishell_changes LIVE DEFAULT FILE` prints one `set NAME` or `drop NAME` line per `omnishell` / `modules.*` table of LIVE whose records differ from FILE's override table (or from DEFAULT's table when FILE has no override). `drop` when the LIVE table equals DEFAULT's, else `set`. Tables only in DEFAULT or FILE are ignored.
  - `settings_update_omnishell FILE LIVE DEFAULT` prints FILE's text with the `set` tables written whole (replacing an existing table of that name, else appended) and the `drop` tables removed; blank and comment lines right above the next table stay. With no changes it prints FILE as it is.

- [ ] **Step 1: Write the failing test**

```bash
# plan-apply: insert-before-final tests/test-settings.sh
echo ">> omnishell tables: changes and update"
DEF="$WORK/default.toml"; LIVE="$WORK/live.toml"
printf '%s\n' '[omnishell]' 'x = 1' '' '[modules.starship]' 'enabled = true' '' '[modules.fzf]' 'enabled = true' > "$DEF"
write '[bootstrap]' 'install_zsh = "ask"'
cp "$DEF" "$LIVE"
check "an untouched live config has no changes"    '[ -z "$(settings_omnishell_changes "$LIVE" "$DEF" "$F")" ]'
printf '%s\n' '[omnishell]' 'x = 1' '' '[modules.starship]' 'enabled = true' '' '[modules.fzf]' 'enabled = false' '' '[modules.broot]' 'enabled = true' > "$LIVE"
OUT="$(settings_omnishell_changes "$LIVE" "$DEF" "$F")"
check "a changed and a new table are set"          'grep -qx "set modules.fzf" <<< "$OUT" && grep -qx "set modules.broot" <<< "$OUT" && [ "$(grep -c . <<< "$OUT")" = 2 ]'
OUT="$(settings_update_omnishell "$F" "$LIVE" "$DEF")"
check "the changed table is appended whole"        'grep -qx "\[modules.fzf\]" <<< "$OUT" && grep -qx "enabled = false" <<< "$OUT" && grep -qx "\[modules.broot\]" <<< "$OUT"'
check "the other tables of the file stay"          'grep -qx "\[bootstrap\]" <<< "$OUT" && grep -qx "install_zsh = \"ask\"" <<< "$OUT"'
check "an unchanged table is not written"          '! grep -q "modules.starship" <<< "$OUT"'
write '# my notes' '[bootstrap]' 'install_zsh = "ask"' '' '# fzf is off on this laptop' '[modules.fzf]' 'enabled = false' '' '# keep this' '[git]' 'editor = "vi"'
cp "$DEF" "$LIVE"
OUT="$(settings_omnishell_changes "$LIVE" "$DEF" "$F")"
check "reverting a table to the default drops it"  '[ "$OUT" = "drop modules.fzf" ]'
OUT="$(settings_update_omnishell "$F" "$LIVE" "$DEF")"
check "the override table is removed"              '! grep -q "modules.fzf" <<< "$OUT" && ! grep -q "enabled = false" <<< "$OUT"'
check "comments and the next table survive"        'grep -qx "# keep this" <<< "$OUT" && grep -qx "\[git\]" <<< "$OUT" && grep -qx "# my notes" <<< "$OUT"'
printf '%s\n' '[omnishell]' 'x = 1' '' '[modules.starship]' 'enabled = false' '' '[modules.fzf]' 'enabled = false' > "$LIVE"
write '[modules.fzf]' 'enabled = false' '' '[git]' 'editor = "vi"'
OUT="$(settings_omnishell_changes "$LIVE" "$DEF" "$F")"
check "a table equal to the override is skipped"   '! grep -q "modules.fzf" <<< "$OUT" && grep -qx "set modules.starship" <<< "$OUT"'
OUT="$(settings_update_omnishell "$F" "$LIVE" "$DEF")"
printf '%s\n' "$OUT" > "$WORK/merged.toml"
check "a replaced table keeps its place"           '[ "$(grep -n "^\[" <<< "$OUT" | cut -d: -f2 | tr "\n" " ")" = "[modules.fzf] [git] [modules.starship] " ]'
write '[git]' 'editor = "vi"'
check "no changes print the file as it is"         '[ "$(settings_update_omnishell "$F" "$DEF" "$DEF")" = "$(cat "$F")" ]'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-settings.sh 2>&1 | grep -c FAIL`
Expected: non-zero (the two functions do not exist yet).

- [ ] **Step 3: Write minimal implementation**

```bash
# plan-apply: python
p = 'lib/settings.sh'
s = open(p).read()
anchor = "# Ghostty `key = value` lines for the [ghostty] values that are set."
assert anchor in s
new = r'''# sorted records of one table of FILE
_settings_table_records() {
  settings_parse "$1" 2>/dev/null | awk -F"$SETTINGS_US" -v t="$2" '$1 == t' | sort
}

# settings_omnishell_changes LIVE DEFAULT FILE: "set NAME" or "drop NAME" for every
# omnishell / modules.* table of LIVE that differs from what FILE says today (its
# own table of that name, else the one in DEFAULT). A table equal to DEFAULT's is
# dropped from FILE, any other one is set whole.
settings_omnishell_changes() {
  local live="$1" default="$2" file="$3" t now cur
  while IFS= read -r t; do
    now="$(_settings_table_records "$live" "$t")"
    cur="$(_settings_table_records "$file" "$t")"
    [ -n "$cur" ] || cur="$(_settings_table_records "$default" "$t")"
    [ "$now" = "$cur" ] && continue
    if [ "$now" = "$(_settings_table_records "$default" "$t")" ]; then echo "drop $t"; else echo "set $t"; fi
  done < <(settings_parse "$live" 2>/dev/null |
    awk -F"$SETTINGS_US" '($1 == "omnishell" || $1 ~ /^modules\./) && !($1 in seen) { seen[$1] = 1; print $1 }')
}

# settings_update_omnishell FILE LIVE DEFAULT: FILE's text with the omnishell
# tables of LIVE taken over (see settings_omnishell_changes), on stdout. A "set"
# table replaces the table of that name as a whole, or is appended; a "drop" table
# is removed. Blank and comment lines right above the next table stay where they are.
settings_update_omnishell() {
  local file="$1" live="$2" default="$3" changes sets drops saved blocks
  changes="$(settings_omnishell_changes "$live" "$default" "$file")"
  if [ -z "$changes" ]; then cat "$file"; return 0; fi
  sets="$(printf '%s\n' "$changes" | awk '$1 == "set" { printf "%s ", $2 }')"
  drops="$(printf '%s\n' "$changes" | awk '$1 == "drop" { printf "%s ", $2 }')"
  saved="$SETTINGS_RECORDS"
  SETTINGS_RECORDS="$(settings_parse "$live" 2>/dev/null |
    awk -F"$SETTINGS_US" -v sel="$sets" 'BEGIN { n = split(sel, a, " "); for (i = 1; i <= n; i++) w[a[i]] = 1 } ($1 in w)')"$'\n'
  blocks="$(_settings_omnishell_blocks)"
  SETTINGS_RECORDS="$saved"
  OVR="$blocks" DROP="$drops" awk '
    function blank_or_comment(s) { return s ~ /^[ \t]*(#.*)?$/ }
    function header(line) { return line ~ /^[ \t]*\[[^\[].*\]/ }
    function tname(line,   n) { n = line; sub(/^[ \t]*\[/, "", n); sub(/\].*$/, "", n); gsub(/^[ \t]+|[ \t]+$/, "", n); return n }
    BEGIN {
      n = split(ENVIRON["OVR"], ol, "\n"); cur = ""
      for (i = 1; i <= n; i++) {
        if (ol[i] ~ /^\[/) { cur = substr(ol[i], 2, length(ol[i]) - 2); oorder[++no] = cur; otext[cur] = ol[i] "\n" }
        else if (ol[i] != "") otext[cur] = otext[cur] ol[i] "\n"
      }
      m = split(ENVIRON["DROP"], dl, " ")
      for (i = 1; i <= m; i++) if (dl[i] != "") drop[dl[i]] = 1
      skipping = 0; pend = ""
    }
    header($0) {
      printf "%s", pend; pend = ""; skipping = 0
      name = tname($0)
      if (name in used) { skipping = 1; next }
      if (name in otext) { printf "%s", otext[name]; used[name] = 1; skipping = 1; next }
      if (name in drop) { skipping = 1; next }
      print; next
    }
    skipping { if (blank_or_comment($0)) pend = pend $0 "\n"; else pend = ""; next }
    { print }
    END {
      printf "%s", pend
      for (i = 1; i <= no; i++) if (!(oorder[i] in used)) printf "\n%s", otext[oorder[i]]
    }
  ' "$file"
}

'''
open(p, 'w').write(s.replace(anchor, new + anchor, 1))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-settings.sh 2>&1 | tail -30`
Expected: every check in the section `ok`, `all checks passed`. The placement check expects the order `[modules.fzf] [git] [modules.starship]`: fzf replaced where it was, starship appended at the end.

- [ ] **Step 5: Commit**

```bash
git add lib/settings.sh tests/test-settings.sh
git commit -m "feat: take over omnishell tables into the settings file"
```

---

### Task 4: Flag, preconditions and re-loadable settings in bootstrap.sh

**Files:**
- Modify: `bootstrap.sh`, `tests/test-omnishell-toolchain.sh`
- Create: `tests/test-interactive.sh`

**Interfaces:**
- Produces:
  - `INTERACTIVE_FLAG` (`1` with `--interactive`, else empty); `--interactive` plus `--yes` / `-y` exits 2 from `parse_args`.
  - `interactive_tty` (true when stdin and stdout are terminals; tests redefine it) and `check_interactive_preconditions` (exit 2 with the message from Global Constraints).
  - `read_conf_values` (sets `CONF_*` from the loaded settings), `build_packages` (builds `PACKAGES` from `CONF_TERMINALS`), `reload_settings` (`settings_load`, `read_conf_values`, `resolve_assume_yes`, `build_packages`).
  - `prepare_omnishell_config` (validate the merged config or exit 2, then write it to the live path); `apply_omnishell` calls it first.
  - `OMNISHELL_MIN_VERSION="0.7.0"`.

- [ ] **Step 1: Write the failing test**

```bash
# plan-apply: create tests/test-interactive.sh
#!/usr/bin/env bash
# bootstrap.sh --interactive: arguments, preconditions, prompts, settings update and
# the hand-over to omnishell tui.
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
for tool in head rm cat cp mkdir basename dirname uname id tr awk grep sed ln readlink cmp mv mktemp tee git diff sort; do
  ln -s "$(command -v "$tool")" "$WORK/bin/$tool"
done

CONF="$WORK/cfg/config.toml"
OUT=""; RC=0
fresh() { rm -rf "${WORK:?}/cfg" "${WORK:?}/home"; mkdir -p "$WORK/cfg" "$WORK/home/.config"; cp "$DOTFILES/config.toml.example" "$CONF"; }
# <stdin text> <shell code>: run the code with bootstrap.sh sourced and a terminal
# assumed; the text (printf %b) is the user's typing
ix_run() {
  RC=0
  OUT="$(printf '%b' "$1" | env -i PATH="$WORK/bin" HOME="$WORK/home" DOTFILES_CONFIG="$CONF" BOOTSTRAP_SOURCE_ONLY=1 \
    "$BASH" -c ". '$DOTFILES/bootstrap.sh'; INTERACTIVE_FLAG=1; interactive_tty() { return 0; }; $2" 2>"$WORK/err")" || RC=$?
}

echo ">> arguments and preconditions"
fresh
RC=0; OUT="$(env -i PATH="$PATH" HOME="$WORK/home" DOTFILES_CONFIG="$CONF" "$DOTFILES/bootstrap.sh" --interactive --yes 2>&1 </dev/null)" || RC=$?
check "--interactive with --yes is an error"          '[ "$RC" = 2 ] && grep -q "contradict" <<< "$OUT"'
RC=0; OUT="$(env -i PATH="$PATH" HOME="$WORK/home" DOTFILES_CONFIG="$CONF" "$DOTFILES/bootstrap.sh" --interactive 2>&1 </dev/null)" || RC=$?
check "--interactive without a terminal is an error"  '[ "$RC" = 2 ] && grep -q "needs a terminal" <<< "$OUT"'
check "the error names the settings file"             'grep -qF "$CONF" <<< "$OUT"'
check "and nothing was written"                       '[ ! -e "$WORK/home/.zshrc" ] && cmp -s "$CONF" "$DOTFILES/config.toml.example"'
check "--help lists --interactive"                    '"$DOTFILES/bootstrap.sh" --help | grep -q -- --interactive'
ix_run '' 'printf %s "$OMNISHELL_MIN_VERSION"'
check "omnishell 0.7.0 is the floor"                  '[ "$OUT" = 0.7.0 ]'

echo ">> reloading settings"
fresh
ix_run '' 'printf "[bootstrap]\nterminals = [\"bash\"]\ninstall_zsh = \"yes\"\n" > "$BOOTSTRAP_CONFIG"; reload_settings; printf "%s|%s" "$CONF_INSTALL_ZSH" "${PACKAGES[*]}"'
check "reload_settings picks up values and packages"  '[ "$OUT" = "yes|zsh git tmux bat ghostty bash" ]'

echo
if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-interactive.sh 2>&1 | tail -15`
Expected: the `--interactive` checks FAIL (`unknown argument`), the floor check FAILs with `0.6.0`, the reload check FAILs.

- [ ] **Step 3: Write minimal implementation**

```bash
# plan-apply: python
p = 'bootstrap.sh'
s = open(p).read()

def sub(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)

# flag, usage, conflict with --yes
sub('ASSUME_YES_FLAG=""\nparse_args() {', 'ASSUME_YES_FLAG=""\nINTERACTIVE_FLAG=""\nparse_args() {')
sub('      -y | --yes) ASSUME_YES_FLAG=1 ;;\n', '      -y | --yes) ASSUME_YES_FLAG=1 ;;\n      --interactive) INTERACTIVE_FLAG=1 ;;\n')
sub('usage: $(basename "$0") [--yes] [--install-zsh | --no-install-zsh]',
    'usage: $(basename "$0") [--interactive] [--yes] [--install-zsh | --no-install-zsh]')
sub('  --no-install-zsh  never install zsh\nUSAGE',
    '  --no-install-zsh  never install zsh\n  --interactive     ask for the settings and pick the omnishell modules in its TUI; writes them to the\n                    settings file after showing a diff (needs a terminal, cannot be combined with --yes)\nUSAGE')
sub("""      *) printf 'bootstrap.sh: unknown argument: %s\\n' "$arg" >&2; exit 2 ;;
    esac
  done
}""", """      *) printf 'bootstrap.sh: unknown argument: %s\\n' "$arg" >&2; exit 2 ;;
    esac
  done
  if [ -n "$INTERACTIVE_FLAG" ] && [ -n "$ASSUME_YES_FLAG" ]; then
    printf 'bootstrap.sh: --interactive and --yes contradict each other\\n' >&2
    exit 2
  fi
}""")

# CONF_* values as a function
sub('''CONF_INSTALL_ZSH="$(settings_get bootstrap.install_zsh)"
CONF_ASSUME_YES="$(settings_get bootstrap.assume_yes)"
CONF_TERMINALS="$(settings_get bootstrap.terminals)"
CONF_GHOSTTY_KEYBINDS="$(settings_get ghostty.keybinds)"
''', '''read_conf_values() {
  CONF_INSTALL_ZSH="$(settings_get bootstrap.install_zsh)"
  CONF_ASSUME_YES="$(settings_get bootstrap.assume_yes)"
  CONF_TERMINALS="$(settings_get bootstrap.terminals)"
  CONF_GHOSTTY_KEYBINDS="$(settings_get ghostty.keybinds)"
}
read_conf_values
''')

# PACKAGES as a function
sub('''PACKAGES=(zsh git tmux bat ghostty)
set -f
for t in ${DOTFILES_TERMINALS:-$CONF_TERMINALS}; do
  case "$t" in
    *[!A-Za-z0-9_.-]*) warn "ignoring terminal '$t': not a valid package name"; continue ;;
  esac
  case " ${PACKAGES[*]} " in *" $t "*) ;; *) [ -d "$DOTFILES/$t" ] && PACKAGES+=("$t") ;; esac
done
set +f
[ -d "$DOTFILES/nvim" ] && PACKAGES+=(nvim)
''', '''build_packages() {
  local t
  PACKAGES=(zsh git tmux bat ghostty)
  set -f
  for t in ${DOTFILES_TERMINALS:-$CONF_TERMINALS}; do
    case "$t" in
      *[!A-Za-z0-9_.-]*) warn "ignoring terminal '$t': not a valid package name"; continue ;;
    esac
    case " ${PACKAGES[*]} " in *" $t "*) ;; *) [ -d "$DOTFILES/$t" ] && PACKAGES+=("$t") ;; esac
  done
  set +f
  [ -d "$DOTFILES/nvim" ] && PACKAGES+=(nvim)
  return 0
}
build_packages

# read the settings file again after --interactive changed it
reload_settings() {
  settings_load "$BOOTSTRAP_CONFIG"
  read_conf_values
  resolve_assume_yes
  build_packages
}
''')

# minimum version
sub('OMNISHELL_MIN_VERSION="0.6.0"', 'OMNISHELL_MIN_VERSION="0.7.0"')
sub('# ARM, with release binaries for starship and mise (armv7) there. What has no',
    '# ARM, with release binaries for starship and mise (armv7) there; 0.7.0 adds\n# `omnishell tui`, which --interactive hands the module selection to. What has no')

# prepare_omnishell_config
sub('''apply_omnishell() {
  _validate_omnishell_config || {
    warn "the omnishell config is invalid - fix the [omnishell] / [modules.*] tables in $BOOTSTRAP_CONFIG (the current omnishell config was left as it is)"
    exit 2
  }
  _write_omnishell_config
  log "omnishell init + apply"''', '''# the merged config, validated first, at the live path
prepare_omnishell_config() {
  _validate_omnishell_config || {
    warn "the omnishell config is invalid - fix the [omnishell] / [modules.*] tables in $BOOTSTRAP_CONFIG (the current omnishell config was left as it is)"
    exit 2
  }
  _write_omnishell_config
}

apply_omnishell() {
  prepare_omnishell_config
  log "omnishell init + apply"''')

# preconditions
sub('''main() {
  check_checkout_consistency''', '''# both ends must be a terminal for the prompts and the TUI (tests redefine this)
interactive_tty() { [ -t 0 ] && [ -t 1 ]; }

check_interactive_preconditions() {
  [ -n "$INTERACTIVE_FLAG" ] || return 0
  interactive_tty && return 0
  printf 'bootstrap.sh: --interactive needs a terminal; run without it, or edit %s by hand\\n' "$BOOTSTRAP_CONFIG" >&2
  exit 2
}

main() {
  check_interactive_preconditions
  check_checkout_consistency''')
open(p, 'w').write(s)

# the toolchain test follows the new floor
p = 'tests/test-omnishell-toolchain.sh'
s = open(p).read()
for old, new in [
    ('NEW_OMNISHELL="$WORK/omnishell-0.6.0"', 'NEW_OMNISHELL="$WORK/omnishell-0.7.0"'),
    ('echo "0.6.0 (commit abc, built now)"', 'echo "0.7.0 (commit abc, built now)"'),
    ('omnishell_stub "$BIN" 0.6.0\nstub curl \'exit 1\'', 'omnishell_stub "$BIN" 0.7.0\nstub curl \'exit 1\''),
    ('check "0.6.0 is kept"                  \'[ "$RC" = 0 ] && grep -q "already installed (0.6.0" <<< "$OUT"\'',
     'check "0.7.0 is kept"                  \'[ "$RC" = 0 ] && grep -q "already installed (0.7.0" <<< "$OUT"\''),
    ('grep -q "below the minimum 0.6.0"', 'grep -q "below the minimum 0.7.0"'),
    ('grep -q "0.5.0" <<< "$OUT" && grep -q "0.6.0" <<< "$OUT"', 'grep -q "0.5.0" <<< "$OUT" && grep -q "0.7.0" <<< "$OUT"'),
]:
    assert s.count(old) == 1, old
    s = s.replace(old, new)
open(p, 'w').write(s)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-interactive.sh 2>&1 | tail -15; bash tests/test-omnishell-toolchain.sh 2>&1 | tail -5; bash tests/test-bootstrap-settings.sh 2>&1 | tail -3`
Expected: all three end with `all checks passed`. The `bash tests/test-interactive.sh` run needs `tests/` files to be executable-agnostic (invoked with `bash`).

- [ ] **Step 5: Commit**

```bash
git add bootstrap.sh tests/test-interactive.sh tests/test-omnishell-toolchain.sh
git commit -m "feat: add the --interactive flag, preconditions and omnishell 0.7.0 floor"
```

---

### Task 5: Prompts, review step and the TUI hand-over

**Files:**
- Modify: `bootstrap.sh`, `tests/test-interactive.sh`

**Interfaces:**
- Consumes: Tasks 1 to 4.
- Produces: `interactive_collect` (sets `INTERACTIVE_CHANGES`), `interactive_settings` (collect, update, review, reload), `interactive_modules` (live config, `omnishell tui`, take over, review, reload), `_review_and_install NEWFILE [NOTE]` (returns 0 when written or unchanged, 1 when declined), `_prompt_line PROMPT` (sets `REPLY`; end of input exits 1). `main()` runs `interactive_settings` after `seed_bootstrap_config` and `interactive_modules` after `install_omnishell`.

- [ ] **Step 1: Write the failing test**

```bash
# plan-apply: insert-before-final tests/test-interactive.sh
# the user's typing: N empty answers
empties() { local i; for ((i = 0; i < $1; i++)); do printf '\\n'; done; }

echo ">> prompts: Enter keeps everything"
fresh
ix_run "$(empties 20)" 'interactive_settings; echo AFTER'
check "Enter at every prompt leaves the file byte-identical" 'cmp -s "$CONF" "$DOTFILES/config.toml.example"'
check "no backup is made and the run continues"             '[ ! -e "$CONF.bak" ] && grep -q AFTER <<< "$OUT"'
check "the prompts show table.key and unset"                'grep -q "bootstrap.install_zsh" <<< "$OUT" && grep -q "\[unset\]" <<< "$OUT"'

echo ">> prompts: answers are validated and written"
fresh
ix_run "yes\n\nfoot, kitty\nbogus\nlinux\n$(empties 16)y\n" 'interactive_settings; printf "%s|%s" "$CONF_INSTALL_ZSH" "$CONF_TERMINALS"'
check "the run succeeds and reloads the settings"           '[ "$RC" = 0 ] && grep -q "yes|foot kitty\$" <<< "$OUT"'
check "install_zsh is written"                              'grep -qx "install_zsh = \"yes\"" "$CONF"'
check "the list is written"                                 'grep -qx "terminals = \[\"foot\", \"kitty\"\]" "$CONF"'
check "an invalid answer is asked again"                    'grep -q "invalid value for ghostty.keybinds" "$WORK/err" || grep -q "invalid value for ghostty.keybinds" <<< "$OUT"'
check "the valid retry is written"                          'grep -qx "keybinds = \"linux\"" "$CONF" && ! grep -q bogus "$CONF"'
check "the old file is kept as .bak"                        'cmp -s "$CONF.bak" "$DOTFILES/config.toml.example"'
check "the template comments are still there"               'grep -q "^# Install zsh when it is missing" "$CONF"'

echo ">> prompts: a dash clears a key"
fresh
printf '[bootstrap]\ninstall_zsh = "yes"\n# note\n' > "$CONF"
ix_run "-\n$(empties 19)y\n" 'interactive_settings'
check "the key is gone and the rest stays"                  '! grep -q install_zsh "$CONF" && grep -qx "# note" "$CONF" && grep -qx "\[bootstrap\]" "$CONF"'

echo ">> review: declining and end of input"
fresh
ix_run "yes\n$(empties 19)n\n" 'interactive_settings; echo AFTER'
check "n ends the run with exit 0"                          '[ "$RC" = 0 ] && ! grep -q AFTER <<< "$OUT" && grep -q "nothing written" <<< "$OUT"'
check "n leaves the file untouched"                         'cmp -s "$CONF" "$DOTFILES/config.toml.example" && [ ! -e "$CONF.bak" ]'
check "the diff was shown"                                  'grep -q "^+install_zsh = \"yes\"" <<< "$OUT"'
fresh
ix_run "yes\n" 'interactive_settings; echo AFTER'
check "end of input aborts with exit 1 and a message"       '[ "$RC" = 1 ] && grep -q "input closed" "$WORK/err" && ! grep -q AFTER <<< "$OUT"'
check "and writes nothing"                                  'cmp -s "$CONF" "$DOTFILES/config.toml.example"'

echo ">> modules: the TUI hand-over"
printf '#!/bin/sh\necho "$*" >> "%s/omnishell.log"\ncase "$1" in\n  validate) exit 0 ;;\n  tui) . "%s/tui.sh" ;;\nesac\n' "$WORK" "$WORK" > "$WORK/bin/omnishell"
chmod +x "$WORK/bin/omnishell"
LIVE="$WORK/home/.config/omnishell/config.toml"

fresh; : > "$WORK/omnishell.log"
printf 'printf "\\n[modules.testmod]\\nenabled = true\\n" >> "%s"\n' "$LIVE" > "$WORK/tui.sh"
ix_run "y\n" 'interactive_modules; echo AFTER'
check "a module added in the TUI is written to the file"    'grep -qx "\[modules.testmod\]" "$CONF" && grep -qx "enabled = true" "$CONF"'
check "the tui ran once and apply never ran"                '[ "$(grep -c "^tui" "$WORK/omnishell.log")" = 1 ] && ! grep -q "^apply" "$WORK/omnishell.log"'
check "the old file is kept as .bak"                        'cmp -s "$CONF.bak" "$DOTFILES/config.toml.example"'
check "the run continues"                                   'grep -q AFTER <<< "$OUT"'

fresh
: > "$WORK/tui.sh"
ix_run "" 'interactive_modules; echo AFTER'
check "a TUI that changes nothing leaves the file alone"    'cmp -s "$CONF" "$DOTFILES/config.toml.example" && grep -q "no changes" <<< "$OUT" && grep -q AFTER <<< "$OUT"'

fresh
printf '[modules.starship]\nenabled = false\n' >> "$CONF"
printf 'cp "%s/omnishell/config.toml" "%s"\n' "$DOTFILES" "$LIVE" > "$WORK/tui.sh"
ix_run "y\n" 'interactive_modules'
check "reverting a module to the default drops its override" '! grep -q "modules.starship" "$CONF"'

fresh
printf 'printf "\\n[modules.testmod]\\nenabled = true\\n" >> "%s"\n' "$LIVE" > "$WORK/tui.sh"
ix_run "n\n" 'interactive_modules; echo AFTER'
check "n keeps the file and ends the run with exit 0"       '[ "$RC" = 0 ] && ! grep -q AFTER <<< "$OUT" && cmp -s "$CONF" "$DOTFILES/config.toml.example"'
check "the diff note says the machine may be ahead"         'grep -q "already follows" <<< "$OUT"'

fresh
printf 'exit 3\n' > "$WORK/tui.sh"
ix_run "" 'interactive_modules; echo AFTER'
check "a failing TUI stops with its exit code"              '[ "$RC" = 3 ] && ! grep -q AFTER <<< "$OUT" && grep -q "exited with 3" "$WORK/err"'
check "and the file is untouched"                           'cmp -s "$CONF" "$DOTFILES/config.toml.example"'

fresh; : > "$WORK/omnishell.log"
ix_run "" 'INTERACTIVE_FLAG=; interactive_settings; interactive_modules; echo AFTER'
check "both steps do nothing without --interactive"         '[ "$RC" = 0 ] && grep -q AFTER <<< "$OUT" && [ ! -s "$WORK/omnishell.log" ] && cmp -s "$CONF" "$DOTFILES/config.toml.example"'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-interactive.sh 2>&1 | grep -c FAIL`
Expected: non-zero (`interactive_settings: command not found`).

- [ ] **Step 3: Write minimal implementation**

```bash
# plan-apply: python
p = 'bootstrap.sh'
s = open(p).read()
anchor = '''# both ends must be a terminal for the prompts and the TUI (tests redefine this)'''
assert s.count(anchor) == 1
new = r'''# --------------------------------------------------------------------------
# --interactive: ask for the settings, pick the modules in `omnishell tui`, and
# write both into the settings file (after a diff and a confirmation)
# --------------------------------------------------------------------------
INTERACTIVE_CHANGES=""

# PROMPT: reads one line into REPLY; end of input aborts before anything changes
_prompt_line() {
  printf '%s' "$1"
  IFS= read -r REPLY || {
    printf '\n' >&2
    warn "input closed - nothing was written or installed"
    exit 1
  }
}

# Ask for every [bootstrap] / [ghostty] / [tmux] / [git] key of the schema.
# Enter keeps the value, "-" unsets it; INTERACTIVE_CHANGES collects table<US>key<US>literal.
interactive_collect() {
  local key type table name current hint literal
  log "dotfiles settings: Enter keeps the shown value, - unsets it"
  # the schema comes in on fd 3: the prompts below read the user's typing from stdin
  while IFS=' ' read -r key type <&3; do
    table="${key%%.*}"; name="${key#*.}"
    case "$table" in bootstrap | ghostty | tmux | git) ;; *) continue ;; esac
    current="$(settings_get "$key")"
    case "$type" in
      list) hint="names separated by spaces or commas" ;;
      *) hint="${type#enum:}" ;;
    esac
    while :; do
      _prompt_line "$key ($hint) [${current:-unset}]: "
      case "$REPLY" in
        "") break ;;
        -) INTERACTIVE_CHANGES="${INTERACTIVE_CHANGES}${table}${SETTINGS_US}${name}${SETTINGS_US}"$'\n'; break ;;
      esac
      if literal="$(_settings_literal "$type" "$REPLY")"; then
        INTERACTIVE_CHANGES="${INTERACTIVE_CHANGES}${table}${SETTINGS_US}${name}${SETTINGS_US}${literal}"$'\n'
        break
      fi
      warn "invalid value for $key (expected $hint)"
    done
  done 3<<< "$SETTINGS_SCHEMA"
}

# NEWFILE [NOTE]: show the diff against the settings file and ask before replacing
# it (the old one is kept as .bak). Returns 0 when written or unchanged, 1 when declined.
_review_and_install() {
  local new="$1"
  if cmp -s "$BOOTSTRAP_CONFIG" "$new"; then
    log "no changes to $BOOTSTRAP_CONFIG"
    return 0
  fi
  diff -u "$BOOTSTRAP_CONFIG" "$new" || true
  [ -z "${2:-}" ] || log "$2"
  _prompt_line "Write these changes to $BOOTSTRAP_CONFIG? [y/N] "
  case "$REPLY" in y | Y | yes | YES) ;; *) return 1 ;; esac
  { cp "$BOOTSTRAP_CONFIG" "$BOOTSTRAP_CONFIG.bak" && cat "$new" > "$BOOTSTRAP_CONFIG"; } || {
    warn "cannot write $BOOTSTRAP_CONFIG"
    exit 1
  }
}

# before anything is installed: the dotfiles-owned prompts
interactive_settings() {
  [ -n "$INTERACTIVE_FLAG" ] || return 0
  local tmp
  interactive_collect
  if [ -z "$INTERACTIVE_CHANGES" ]; then
    log "settings unchanged"
    return 0
  fi
  tmp="$(mktemp)"
  settings_update_file "$BOOTSTRAP_CONFIG" "$INTERACTIVE_CHANGES" > "$tmp"
  if ! _review_and_install "$tmp"; then
    rm -f "$tmp"
    log "nothing written, nothing installed"
    exit 0
  fi
  rm -f "$tmp"
  reload_settings
}

# after omnishell is installed: the module selection in its TUI. The TUI edits
# the live omnishell config (merged from the tracked default and the settings
# file); what it leaves behind is compared with the default and written back.
interactive_modules() {
  [ -n "$INTERACTIVE_FLAG" ] || return 0
  local live tmp rc=0
  prepare_omnishell_config
  live="${XDG_CONFIG_HOME:-$HOME/.config}/omnishell/config.toml"
  log "omnishell tui: Space toggles a module, o edits its options, a previews the plan, q quits"
  omnishell tui || rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "omnishell tui exited with $rc - the module selection was not taken over"
    exit "$rc"
  fi
  tmp="$(mktemp)"
  settings_update_omnishell "$BOOTSTRAP_CONFIG" "$live" "$DOTFILES/omnishell/config.toml" > "$tmp"
  if ! _review_and_install "$tmp" "this machine already follows what you chose in the TUI (a applies it); y keeps it in $BOOTSTRAP_CONFIG too, n leaves the file as it was"; then
    rm -f "$tmp"
    log "nothing written, nothing installed"
    exit 0
  fi
  rm -f "$tmp"
  reload_settings
}

'''
s = s.replace(anchor, new + anchor)
old = '''  check_checkout_consistency
  seed_bootstrap_config
  install_deps
  ensure_zsh
  install_ghostty
  install_omnishell
  write_rc_base'''
assert s.count(old) == 1
s = s.replace(old, '''  check_checkout_consistency
  seed_bootstrap_config
  interactive_settings
  install_deps
  ensure_zsh
  install_ghostty
  install_omnishell
  interactive_modules
  write_rc_base''')
open(p, 'w').write(s)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-interactive.sh 2>&1 | tail -45`
Expected: every check `ok`, `all checks passed`. A failing "Enter at every prompt" check usually means the schema has a different key count than 20; count `bash -c '. lib/settings.sh; settings_schema_keys | wc -l'` and fix the fixture, not the code.

- [ ] **Step 5: Commit**

```bash
git add bootstrap.sh tests/test-interactive.sh
git commit -m "feat: prompt for settings and hand module selection to omnishell tui"
```

---

### Task 6: Docs and full run

**Files:**
- Modify: `README.md`, `config.toml.example`

**Interfaces:**
- Consumes: the finished `--interactive` behaviour.

- [ ] **Step 1: Write the failing test**

```bash
# plan-apply: insert-before-final tests/test-interactive.sh
echo ">> docs"
check "the README names --interactive"                      'grep -q -- "--interactive" "$DOTFILES/README.md"'
check "the README names the 0.7.0 floor"                    'grep -q "omnishell 0.7.0 or newer" "$DOTFILES/README.md" && ! grep -q "0\.6\.0" "$DOTFILES/README.md"'
check "the template mentions --interactive"                 'grep -q -- "--interactive" "$DOTFILES/config.toml.example"'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-interactive.sh 2>&1 | tail -6`
Expected: the three `docs` checks FAIL.

- [ ] **Step 3: Write minimal implementation**

```bash
# plan-apply: python
p = 'README.md'
s = open(p).read()
def sub(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)
sub('**omnishell 0.6.0 or newer is required**', '**omnishell 0.7.0 or newer is required**')
sub("source build where no distro package exists. `bootstrap.sh` upgrades an older\ninstall, or stops with a message if it can't.",
    "source build where no distro package exists, and 0.7.0 is the first with\n`omnishell tui`, which `--interactive` uses. `bootstrap.sh` upgrades an older\ninstall, or stops with a message if it can't.")
sub('(upgrading it below 0.6.0)', '(upgrading it below 0.7.0)')
sub('prompt with "yes" (and skip the identity prompt). `--yes` never installs zsh.',
    'prompt with "yes" (and skip the identity prompt). `--yes` never installs zsh.\n\nPass `--interactive` to be asked instead of editing the settings file: it prompts\nfor every `[bootstrap]`, `[ghostty]`, `[tmux]` and `[git]` key (Enter keeps the\nshown value, `-` unsets it, invalid answers are asked again), then opens\n`omnishell tui` for the module selection. Both are written to\n`~/.config/dotfiles/config.toml` as a diff you confirm; comments and unknown\ncontent stay, and the previous file is kept as `config.toml.bak`. It needs a\nterminal and cannot be combined with `--yes`. Answering `n` ends the run before\nanything is installed.')
open(p, 'w').write(s)

p = 'config.toml.example'
s = open(p).read()
old = '# Precedence: command-line flag > environment variable > this file > default.\n'
assert s.count(old) == 1
s = s.replace(old, old + '# ./bootstrap.sh --interactive asks for these settings and for the omnishell modules\n# and writes the answers here (comments stay, the old file is kept as config.toml.bak).\n')
open(p, 'w').write(s)
```

- [ ] **Step 4: Run the full suite**

Run: `make lint test 2>&1 | tail -30`
Expected: shellcheck clean, every `tests/test-*.sh` ends with `all checks passed`. The template-sync test must still pass: the new template lines are comments, and the README key table is unchanged.

- [ ] **Step 5: Commit**

```bash
git add README.md config.toml.example tests/test-interactive.sh
git commit -m "docs: document the interactive install mode"
```
