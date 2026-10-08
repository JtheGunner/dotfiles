# Settings Minors Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the deferred minors of the settings file (PR #22) and the interactive install mode (PR #23) listed in DOTFI-13.

**Architecture:** Small, independent changes in `lib/settings.sh` (validator, tmux renderer, the two text-level writers, table comparison) and `bootstrap.sh` (marker helper, git settings render, interactive temp files / atomic write / one backup per run). No new options and no new interfaces beyond one optional argument and two small helpers.

**Tech Stack:** Bash 3.2-compatible shell, awk (BWK / mawk compatible), the repo's `tests/test-*.sh` style.

**Spec:** the design approved in chat for DOTFI-13 (groups A to D); the ticket lists the acceptance criteria. Context: `docs/superpowers/specs/2026-10-07-tmux-git-settings-design.md` and `docs/superpowers/specs/2026-10-07-interactive-install-design.md`.

## Global Constraints

- No new settings keys, flags or environment variables; precedence unchanged.
- Bash 3.2 and BWK awk / mawk compatible; the settings file is parsed, never executed.
- Existing machines keep working: a Ghostty settings file written with the old marker text still counts as generated.
- Items deliberately not in this branch: the Linux Ghostty bindings (needs a Linux host, stays a manual check on DOTFI-13) and the mawk run (the Ubuntu CI job already runs the tests under mawk).
- Code and docs in English; commit messages `<type>: <description>` without trailers; `make lint test` green before each commit.

## Review Focus

- `history_limit = 999999999` is still accepted, `1000000000` and `007` are rejected, `0` is still valid for `base_index`. Pinned in Task 1.
- A Ghostty settings file with the old marker is replaced or removed like a new one, never reported as "not generated". Pinned in Task 3.
- A CRLF settings file with no changes comes back byte-identical; with changes every line keeps its CR. Pinned in Task 4.
- An interrupted prompt (end of input) leaves nothing in `TMPDIR` and never a half-written settings file. Pinned in Task 5.
- A run that writes in both interactive steps keeps the original file as `.bak`. Pinned in Task 5.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/settings.sh` (modify) | integer rules, `settings_render_tmux` argument, strict header regex and CRLF / empty-file handling in both writers, last-value-wins table records |
| `bootstrap.sh` (modify) | `_tracked_tmux_prefix`, one marker helper, git settings without marker-only files, temp file tracking, atomic write, one backup per run |
| `config.toml.example`, `README.md` (modify) | note on reloading a running tmux after a prefix change |
| `tests/test-settings.sh`, `tests/test-bootstrap-settings.sh`, `tests/test-interactive.sh` (modify) | one failing test per change |

Code blocks whose first line is `# plan-apply: ...` are applied literally by the executor: `insert-before-final <file>` inserts the block before the final summary of a test file, `python` blocks are run with `python3`.

---

### Task 1: Integer rules

**Files:**
- Modify: `lib/settings.sh`, `tests/test-settings.sh`

**Interfaces:**
- Produces: `_settings_value_ok` rejects an `int` with a leading zero (`007`, `-007`) for every numeric type, and `nonneg` / `posint` values longer than 9 characters. `_settings_literal` inherits both.

- [ ] **Step 1: Write the failing test**

```bash
# plan-apply: insert-before-final tests/test-settings.sh
echo ">> integer rules"
check "history_limit accepts nine digits"            '[ "$(val tmux history_limit 999999999)" = 999999999 ]'
check "history_limit rejects ten digits"             '[ -z "$(val tmux history_limit 1000000000)" ]'
check "base_index rejects ten digits"                '[ -z "$(val tmux base_index 1000000000)" ]'
check "base_index rejects a leading zero"            '[ -z "$(val tmux base_index 007)" ]'
check "base_index still accepts 0"                   '[ "$(val tmux base_index 0)" = 0 ]'
check "escape_time rejects a leading zero"           '[ -z "$(val tmux escape_time 010)" ]'
check "a number with a leading zero is rejected"     '[ -z "$(val ghostty font_size 012)" ]'
check "a float like 0.5 is still accepted"           '[ "$(val ghostty background_opacity 0.5)" = 0.5 ]'
check "_settings_literal rejects a leading zero"     '! lit posint 0123 >/dev/null'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-settings.sh 2>&1 | sed -n '/integer rules/,$p'`
Expected: FAIL for the ten-digit, leading-zero and `_settings_literal` checks; the `999999999`, `0` and `0.5` checks already pass.

- [ ] **Step 3: Write minimal implementation**

```bash
# plan-apply: python
p = 'lib/settings.sh'
s = open(p).read()
def sub(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)
sub('''_settings_value_ok() {
  case "$1" in
    enum:*)''', '''_settings_value_ok() {
  # TOML forbids leading zeros, and in shell arithmetic 007 would be octal
  if [ "$2" = int ]; then
    case "$3" in 0[0-9]* | -0[0-9]*) return 1 ;; esac
  fi
  case "$1" in
    enum:*)''')
sub('''    nonneg) [ "$2" = int ] && [ "$3" -ge 0 ] ;;
    posint) [ "$2" = int ] && [ "$3" -gt 0 ] ;;''', '''    nonneg) [ "$2" = int ] && [ "${#3}" -le 9 ] && [ "$3" -ge 0 ] ;;
    posint) [ "$2" = int ] && [ "${#3}" -le 9 ] && [ "$3" -gt 0 ] ;;''')
open(p, 'w').write(s)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-settings.sh 2>&1 | tail -4`
Expected: `all checks passed`.

- [ ] **Step 5: Commit**

```bash
git add lib/settings.sh tests/test-settings.sh
git commit -m "fix: reject out-of-range integers and leading zeros in settings"
```

---

### Task 2: tmux prefix follows the tracked config

**Files:**
- Modify: `lib/settings.sh`, `bootstrap.sh`, `config.toml.example`, `README.md`, `tests/test-settings.sh`, `tests/test-bootstrap-settings.sh`

**Interfaces:**
- Produces: `settings_render_tmux [TRACKED_PREFIX]` (default `C-a`) prints `unbind TRACKED_PREFIX` instead of the fixed `unbind C-a`. `_tracked_tmux_prefix [FILE]` prints the key the tracked `tmux/.tmux.conf` (or FILE) sets with `set -g prefix`, nothing when it finds none.

- [ ] **Step 1: Write the failing tests**

```bash
# plan-apply: insert-before-final tests/test-settings.sh
echo ">> tmux unbind follows the tracked prefix"
write '[tmux]' 'prefix = "C-b"'
settings_load "$F" 2>/dev/null
check "the default unbind is still C-a"              '[ "$(settings_render_tmux | head -1)" = "unbind C-a" ]'
check "the tracked prefix can be passed in"          '[ "$(settings_render_tmux C-z | head -1)" = "unbind C-z" ]'
check "the new prefix is set after the unbind"       '[ "$(settings_render_tmux C-z | sed -n 2,3p | tr "\n" "|")" = "set -g prefix C-b|bind C-b send-prefix|" ]'
```

```bash
# plan-apply: insert-before-final tests/test-bootstrap-settings.sh
echo ">> tmux prefix follows the tracked config"
printf 'set -g prefix C-z\nunbind C-b\n' > "$WORK/tracked.conf"
fresh
sh_run '' '_tracked_tmux_prefix "'"$WORK"'/tracked.conf"'
check "the tracked prefix is read from the file"     '[ "$OUT" = C-z ]'
sh_run '' '_tracked_tmux_prefix'
check "the repo tmux.conf sets C-a"                  '[ "$OUT" = C-a ]'
sh_run '' '_tracked_tmux_prefix /nonexistent'
check "a missing file yields nothing and no error"   '[ -z "$OUT" ] && [ "$RC" = 0 ]'
check "config.toml.example explains reloading"       'grep -q "old prefix" "$TEMPLATE"'
check "the README explains reloading"                'grep -q "old prefix" "$DOTFILES/README.md"'
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-settings.sh 2>&1 | sed -n '/unbind follows/,$p'; bash tests/test-bootstrap-settings.sh 2>&1 | sed -n '/follows the tracked/,$p'`
Expected: FAIL on the passed-in prefix check and on all five bootstrap checks (`_tracked_tmux_prefix: command not found`, missing docs).

- [ ] **Step 3: Write minimal implementation**

```bash
# plan-apply: python
def edit(p, pairs):
    s = open(p).read()
    for old, new in pairs:
        assert s.count(old) == 1, (p, old[:70])
        s = s.replace(old, new)
    open(p, 'w').write(s)

edit('lib/settings.sh', [
('''settings_render_tmux() {
  local v
  v="$(settings_get tmux.prefix)"
  if [ -n "$v" ]; then
    printf 'unbind C-a\\nset -g prefix %s\\nbind %s send-prefix\\n' "$v" "$v"''',
'''settings_render_tmux() {
  local v tracked="${1:-C-a}"
  v="$(settings_get tmux.prefix)"
  if [ -n "$v" ]; then
    printf 'unbind %s\\nset -g prefix %s\\nbind %s send-prefix\\n' "$tracked" "$v" "$v"'''),
])

edit('bootstrap.sh', [
('''render_tmux_settings() {
  local out="$HOME/.config/tmux-settings.conf" body tmp
  body="$(settings_render_tmux)"''',
'''# the prefix the tracked tmux.conf sets, so the generated file can unbind it
_tracked_tmux_prefix() {
  awk '$1 == "set" && $2 == "-g" && $3 == "prefix" { print $4; exit }' "${1:-$DOTFILES/tmux/.tmux.conf}" 2>/dev/null || true
}

render_tmux_settings() {
  local out="$HOME/.config/tmux-settings.conf" body tmp
  body="$(settings_render_tmux "$(_tracked_tmux_prefix)")"'''),
])

edit('config.toml.example', [
('# Prefix key: C-a style, M-x, C-Space or F1 to F12. Default C-a.\n',
 '# Prefix key: C-a style, M-x, C-Space or F1 to F12. Default C-a. A running tmux\n# picks a changed prefix up after "old prefix" + r (reload) or a server restart.\n'),
])

edit('README.md', [
('Root-Loops-flavoured status bar (`prefix r` reloads)',
 'Root-Loops-flavoured status bar (`prefix r` reloads; after changing `prefix` in the settings file, reload once with the old prefix or restart the server)'),
])
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-settings.sh 2>&1 | tail -3; bash tests/test-bootstrap-settings.sh 2>&1 | tail -3`
Expected: both end with `all checks passed`.

- [ ] **Step 5: Commit**

```bash
git add lib/settings.sh bootstrap.sh config.toml.example README.md tests
git commit -m "fix: unbind the tracked tmux prefix instead of a hardcoded C-a"
```

---

### Task 3: One generated-file marker, no marker-only git file

**Files:**
- Modify: `bootstrap.sh`, `tests/test-bootstrap-settings.sh`

**Interfaces:**
- Produces: `_generated_or_absent FILE` is true for a missing file or one whose first line starts with `# GENERATED by bootstrap.sh`, whatever follows. `GHOSTTY_SETTINGS_MARK` is gone; Ghostty writes `GENERATED_MARK` like the others. `render_git_settings` writes nothing (and removes a generated file) when every value was skipped.

- [ ] **Step 1: Write the failing tests**

```bash
# plan-apply: insert-before-final tests/test-bootstrap-settings.sh
echo ">> one generated-file marker"
GHOSTTY_OUT="$WORK/home/.config/ghostty-settings.conf"
fresh; conf '[ghostty]' 'font_size = 13'
mkdir -p "$WORK/home/.config"
printf '%s\nfont-size = 99\n' '# GENERATED by bootstrap.sh from the [ghostty] table of the settings file - do not edit' > "$GHOSTTY_OUT"
sh_run '' 'render_ghostty_settings'
check "a file with the old Ghostty marker is replaced"   '! grep -q "left untouched" "$WORK/err" && grep -qx "font-size = 13" "$GHOSTTY_OUT"'
check "and now carries the shared marker"                '[ "$(head -n 1 "$GHOSTTY_OUT")" = "# GENERATED by bootstrap.sh from the settings file - do not edit" ]'
printf '%s\nfont-size = 99\n' '# GENERATED by bootstrap.sh from the [ghostty] table of the settings file - do not edit' > "$GHOSTTY_OUT"
conf '[bootstrap]' 'install_zsh = "ask"'
sh_run '' 'render_ghostty_settings'
check "a file with the old marker is removed when no key is set" '[ ! -e "$GHOSTTY_OUT" ]'
printf 'font-size = 99\n' > "$GHOSTTY_OUT"; conf '[ghostty]' 'font_size = 13'
sh_run '' 'render_ghostty_settings'
check "a hand-written Ghostty file is still left alone"  'grep -q "left untouched" "$WORK/err" && grep -qx "font-size = 99" "$GHOSTTY_OUT"'

echo ">> no marker-only git settings file"
fresh; conf '[git]' 'signing_key = "~/.ssh/missing.pub"'
sh_run '' 'render_git_settings'
check "only a missing signing key: no file is written"   '[ ! -e "$GIT_OUT" ]'
printf '%s\n' '# GENERATED by bootstrap.sh from the settings file - do not edit' > "$GIT_OUT"
sh_run '' 'render_git_settings'
check "an old marker-only file is removed"               '[ ! -e "$GIT_OUT" ]'
fresh; conf '[git]' 'signing_key = "~/.ssh/missing.pub"' 'editor = "nvim"'
sh_run '' 'render_git_settings'
check "with another value the file is still written"     '[ "$(gitc core.editor)" = nvim ]'
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-bootstrap-settings.sh 2>&1 | sed -n '/one generated-file marker/,$p'`
Expected: FAIL for the old-marker cases (the file is reported as "left untouched") and for the marker-only file cases; the hand-written Ghostty check and the "another value" check pass.

- [ ] **Step 3: Write minimal implementation**

```bash
# plan-apply: python
def edit(p, pairs):
    s = open(p).read()
    for old, new in pairs:
        assert s.count(old) == 1, (p, old[:70])
        s = s.replace(old, new)
    open(p, 'w').write(s)

edit('bootstrap.sh', [
('''GHOSTTY_SETTINGS_MARK="# GENERATED by bootstrap.sh from the [ghostty] table of the settings file - do not edit"

''', ''),
('''  if [ -e "$out" ] && ! head -n 1 "$out" | grep -qxF "$GHOSTTY_SETTINGS_MARK"; then''',
 '''  if ! _generated_or_absent "$out"; then'''),
('''  printf '%s\\n%s\\n' "$GHOSTTY_SETTINGS_MARK" "$body" > "$tmp"''',
 '''  printf '%s\\n%s\\n' "$GENERATED_MARK" "$body" > "$tmp"'''),
('''# true when $1 does not exist or was generated by this script
_generated_or_absent() { [ ! -e "$1" ] || head -n 1 "$1" | grep -qxF "$GENERATED_MARK"; }''',
 '''# true when $1 does not exist or was generated by this script (any wording of the mark)
_generated_or_absent() { [ ! -e "$1" ] || head -n 1 "$1" | grep -q '^# GENERATED by bootstrap\\.sh'; }'''),
('''    _warn_if_local_overrides user.signingkey
  fi
  _install_generated "$out" "$tmp"''', '''    _warn_if_local_overrides user.signingkey
  fi
  # every value was skipped (for example a missing signing key): no marker-only file
  if [ -z "$(git config --file "$tmp" --list 2>/dev/null)" ]; then
    rm -f "$tmp" "$out"
    return 0
  fi
  _install_generated "$out" "$tmp"'''),
])
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-bootstrap-settings.sh 2>&1 | tail -3; grep -c GHOSTTY_SETTINGS_MARK bootstrap.sh`
Expected: `all checks passed`, and `0`.

- [ ] **Step 5: Commit**

```bash
git add bootstrap.sh tests/test-bootstrap-settings.sh
git commit -m "fix: share one generated-file marker and skip marker-only git settings"
```

---

### Task 4: Settings writers: duplicates, CRLF, headers, empty files

**Files:**
- Modify: `lib/settings.sh`, `tests/test-settings.sh`

**Interfaces:**
- Consumes: `settings_update_file`, `settings_omnishell_changes`, `settings_update_omnishell` (existing).
- Produces:
  - `_settings_table_records FILE TABLE` keeps only the last record per key (as the reader does).
  - Both writers recognise a table header with exactly the shape `settings_parse` accepts (no spaces inside the brackets), so `[ bootstrap ]` is an ordinary line.
  - `settings_update_file` ends every line it writes with a CR when the first line of the file does, and adds no leading blank line to an empty file. `settings_update_omnishell` adds none either.

- [ ] **Step 1: Write the failing test**

```bash
# plan-apply: insert-before-final tests/test-settings.sh
echo ">> writers: duplicates, CRLF, headers, empty files"
CR="$(printf '\r')"
printf '%s\n' '[omnishell]' 'x = 1' '' '[modules.tmux]' 'enabled = true' > "$DEF"
printf '%s\n' '[omnishell]' 'x = 1' '' '[modules.tmux]' 'enabled = false' > "$LIVE"
write '[modules.tmux]' 'enabled = true' 'enabled = false'
check "a repeated key in the override counts by its last value" '[ -z "$(settings_omnishell_changes "$LIVE" "$DEF" "$F")" ]'

printf '[tmux]\r\nmouse = false\r\nprefix = "C-a"\r\n' > "$F"
cp "$F" "$WORK/crlf.orig"
check "a CRLF file without changes is printed byte-identical"   'settings_update_file "$F" "" | cmp -s - "$WORK/crlf.orig"'
OUT="$(settings_update_file "$F" "$(chg tmux mouse true; chg tmux mode_keys '"vi"'; chg git editor '"nvim"')")"
check "every line of an updated CRLF file ends with CR"         '[ "$(grep -c "${CR}\$" <<< "$OUT")" = "$(grep -c "" <<< "$OUT")" ]'
check "the replaced value is there"                             'grep -q "^mouse = true" <<< "$OUT"'

write '[ bootstrap ]' 'assume_yes = false'
OUT="$(settings_update_file "$F" "$(chg bootstrap assume_yes true)")"
printf '%s\n' "$OUT" > "$WORK/hdr.toml"
settings_load "$WORK/hdr.toml" 2>/dev/null
check "a header the parser rejects is not taken for the table"  '[ "$(settings_get bootstrap.assume_yes)" = true ]'

: > "$F"
OUT="$(settings_update_file "$F" "$(chg ghostty font_size 14; chg tmux mouse true)")"
check "an empty file gets no leading blank line"                '[ "$(sed -n 1p <<< "$OUT")" = "[ghostty]" ]'
check "a second new table is still separated by a blank line"   '[ "$(sed -n 3p <<< "$OUT")" = "" ] && [ "$(sed -n 4p <<< "$OUT")" = "[tmux]" ]'
printf '%s\n' '[omnishell]' 'x = 1' > "$DEF"
printf '%s\n' '[omnishell]' 'x = 1' '' '[modules.broot]' 'enabled = true' '' '[modules.eza]' 'enabled = true' > "$LIVE"
OUT="$(settings_update_omnishell "$F" "$LIVE" "$DEF")"
check "omnishell tables in an empty file: no leading blank line" '[ "$(sed -n 1p <<< "$OUT")" = "[modules.broot]" ]'
check "and the second table is separated"                       'grep -qx "\[modules.eza\]" <<< "$OUT" && [ "$(sed -n 3p <<< "$OUT")" = "" ]'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-settings.sh 2>&1 | sed -n '/writers: duplicates/,$p'`
Expected: FAIL on the repeated-key, CRLF line-ending, header and both empty-file checks; the byte-identical CRLF check passes already.

- [ ] **Step 3: Write minimal implementation**

```bash
# plan-apply: python
import re
p = 'lib/settings.sh'
s = open(p).read()

# 1. last value per key wins in the table comparison
old = '''_settings_table_records() {
  settings_parse "$1" 2>/dev/null | awk -F"$SETTINGS_US" -v t="$2" '$1 == t' | sort
}'''
assert s.count(old) == 1
s = s.replace(old, '''_settings_table_records() {
  settings_parse "$1" 2>/dev/null | awk -F"$SETTINGS_US" -v t="$2" '
    $1 == t { if (!($2 in seen)) { seen[$2] = 1; order[++n] = $2 } rec[$2] = $0 }
    END { for (i = 1; i <= n; i++) print rec[order[i]] }' | sort
}''')

# 2. both writers: the header shape the parser accepts
hdr_old = r'''    function header(line) { return line ~ /^[ \t]*\[[^\[].*\]/ }'''
hdr_new = r'''    function header(line) { return line ~ /^[ \t]*\[[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*\][ \t\r]*(#.*)?$/ }'''
assert s.count(hdr_old) == 2
s = s.replace(hdr_old, hdr_new)

# 3. settings_update_file: CRLF and no blank line before the first table of an empty file
m = re.search(r'settings_update_file\(\) \{.*?\n\}\n', s, re.S)
assert m
new_fn = r'''settings_update_file() {
  CHG="$2" awk -v us="$SETTINGS_US" '
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function header(line) { return line ~ /^[ \t]*\[[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*\][ \t\r]*(#.*)?$/ }
    function tname(line,   n) { n = line; sub(/^[ \t]*\[/, "", n); sub(/\].*$/, "", n); return trim(n) }
    function keyof(line,   k) {
      if (line !~ /^[ \t]*[A-Za-z0-9_-]+[ \t]*=/) return ""
      k = line; sub(/^[ \t]*/, "", k); sub(/[ \t]*=.*$/, "", k); return k
    }
    # lines this script writes end like the file does
    function out(s) { printf "%s%s\n", s, cr }
    BEGIN {
      n = split(ENVIRON["CHG"], rows, "\n"); nc = 0; cr = ""; nt = 0
      for (i = 1; i <= n; i++) {
        if (rows[i] == "") continue
        split(rows[i], f, us)
        nc++; ct[nc] = f[1]; ck[nc] = f[2]; cl[nc] = f[3]
        want[f[1], f[2]] = nc
      }
    }
    FNR == NR {
      lines++
      if (FNR == 1 && $0 ~ /\r$/) cr = "\r"
      if (header($0)) { t = tname($0); known[t] = 1 }
      else if ((k = keyof($0)) != "") active[t, k] = 1
      next
    }
    FNR == 1 { t = "" }
    header($0) {
      t = tname($0); print
      for (i = 1; i <= nc; i++)
        if (ct[i] == t && cl[i] != "" && !((t, ck[i]) in active) && !(i in done)) {
          out(ck[i] " = " cl[i]); done[i] = 1
        }
      next
    }
    (k = keyof($0)) != "" && ((t, k) in want) {
      i = want[t, k]
      if (!(i in done)) { if (cl[i] != "") out(k " = " cl[i]); done[i] = 1 }
      next
    }
    { print }
    END {
      for (i = 1; i <= nc; i++) {
        if (cl[i] == "" || (ct[i] in known) || (ct[i] in tdone)) continue
        if (lines > 0 || nt > 0) out("")
        out("[" ct[i] "]"); tdone[ct[i]] = 1; nt++
        for (j = i; j <= nc; j++) if (ct[j] == ct[i] && cl[j] != "") out(ck[j] " = " cl[j])
      }
    }
  ' "$1" "$1"
}
'''
s = s[:m.start()] + new_fn + s[m.end():]

# 4. settings_update_omnishell: no leading blank line in an empty file
old = '''      for (i = 1; i <= no; i++) if (!(oorder[i] in used)) printf "\\n%s", otext[oorder[i]]'''
assert s.count(old) == 1
s = s.replace(old, '''      sep = (NR > 0) ? "\\n" : ""
      for (i = 1; i <= no; i++) if (!(oorder[i] in used)) { printf "%s%s", sep, otext[oorder[i]]; sep = "\\n" }''')
open(p, 'w').write(s)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-settings.sh 2>&1 | tail -4`
Expected: `all checks passed`, including every earlier `settings_update_file` and omnishell check.

- [ ] **Step 5: Commit**

```bash
git add lib/settings.sh tests/test-settings.sh
git commit -m "fix: make the settings writers handle CRLF, odd headers and empty files"
```

---

### Task 5: Interactive mode: temp files, atomic write, one backup

**Files:**
- Modify: `bootstrap.sh`, `tests/test-interactive.sh`

**Interfaces:**
- Produces:
  - `_interactive_mktemp NAME` creates a temp file, records it, and stores its path in the variable NAME (no command substitution, so the record survives); `_interactive_cleanup` removes the recorded files; `_interactive_traps` installs `trap _interactive_cleanup EXIT` and `trap 'exit 130' INT TERM HUP`. Both interactive steps call `_interactive_traps` first.
  - `_write_settings_file NEW` replaces the settings file through a temp file in the same directory and `mv`, keeping the file mode. The first call of a run copies the original to `<file>.bak`, later calls leave that backup alone (`BACKUP_MADE`).

- [ ] **Step 1: Write the failing test**

```bash
# plan-apply: python
p = 'tests/test-interactive.sh'
s = open(p).read()
old = 'fresh() { rm -rf "${WORK:?}/cfg" "${WORK:?}/home"; mkdir -p "$WORK/cfg" "$WORK/home/.config"; cp "$DOTFILES/config.toml.example" "$CONF"; }'
assert s.count(old) == 1
s = s.replace(old, 'fresh() { rm -rf "${WORK:?}/cfg" "${WORK:?}/home" "${WORK:?}/tmp"; mkdir -p "$WORK/cfg" "$WORK/home/.config" "$WORK/tmp"; cp "$DOTFILES/config.toml.example" "$CONF"; }')
old = 'DOTFILES_CONFIG="$CONF" BOOTSTRAP_SOURCE_ONLY=1 \\\n    "$BASH" -c ". \'$DOTFILES/bootstrap.sh\'; INTERACTIVE_FLAG=1;'
assert s.count(old) == 1
s = s.replace(old, 'DOTFILES_CONFIG="$CONF" TMPDIR="$WORK/tmp" BOOTSTRAP_SOURCE_ONLY=1 \\\n    "$BASH" -c ". \'$DOTFILES/bootstrap.sh\'; INTERACTIVE_FLAG=1;')
open(p, 'w').write(s)
```

```bash
# plan-apply: insert-before-final tests/test-interactive.sh
echo ">> hardening: temp files, atomic write, one backup"
fresh
ix_run "yes\n$(empties 19)" 'interactive_settings'
check "end of input at the settings review leaves no temp file" '[ "$RC" = 1 ] && [ -z "$(ls -A "$WORK/tmp")" ]'
fresh
printf 'printf "\\n[modules.testmod]\\nenabled = true\\n" >> "%s"\n' "$LIVE" > "$WORK/tui.sh"
ix_run "" 'interactive_modules'
check "end of input at the module review leaves no temp file"   '[ "$RC" = 1 ] && [ -z "$(ls -A "$WORK/tmp")" ]'
fresh
ix_run "yes\n$(empties 19)n\n" 'interactive_settings'
check "declining leaves no temp file either"                    '[ "$RC" = 0 ] && [ -z "$(ls -A "$WORK/tmp")" ]'
fresh; chmod 644 "$CONF"
ix_run "yes\n$(empties 19)y\n" 'interactive_settings'
check "the write leaves no staging file next to the settings file" '[ "$(ls "$WORK/cfg" | tr "\n" " ")" = "config.toml config.toml.bak " ]'
check "and keeps the file mode"                                 '[ "$(ls -l "$CONF" | cut -c1-10)" = "-rw-r--r--" ]'
fresh
ix_run "yes\n$(empties 19)y\ny\n" 'interactive_settings; interactive_modules'
check "both steps write: both changes are in the file"          'grep -qx "install_zsh = \"yes\"" "$CONF" && grep -qx "\[modules.testmod\]" "$CONF"'
check "and the .bak still holds the original"                   'cmp -s "$CONF.bak" "$DOTFILES/config.toml.example"'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-interactive.sh 2>&1 | sed -n '/hardening/,$p'`
Expected: FAIL on both "leaves no temp file" end-of-input checks, the staging-file check is satisfied by accident today, and FAIL on "the .bak still holds the original" (step 6 overwrites it).

- [ ] **Step 3: Write minimal implementation**

```bash
# plan-apply: python
p = 'bootstrap.sh'
s = open(p).read()
def sub(old, new):
    global s
    assert s.count(old) == 1, old[:70]
    s = s.replace(old, new)

sub('''PROMPT_ABORT_HOOK=""   # a function to run when the input ends at a prompt
''', '''PROMPT_ABORT_HOOK=""   # a function to run when the input ends at a prompt
BACKUP_MADE=""         # the first backup of a run keeps the original settings file
INTERACTIVE_TMPFILES=""

# NAME: make a temp file, remember it for the exit trap, store its path in NAME
# (no command substitution: the record has to survive in this shell)
_interactive_mktemp() {
  local f
  f="$(mktemp)" || return 1
  INTERACTIVE_TMPFILES="${INTERACTIVE_TMPFILES}${f}"$'\\n'
  printf -v "$1" '%s' "$f"
}

_interactive_cleanup() {
  local f
  while IFS= read -r f; do
    [ -z "$f" ] || rm -f "$f"
  done <<< "$INTERACTIVE_TMPFILES"
}

# temp files go away on exit, end of input and Ctrl-C alike
_interactive_traps() {
  trap _interactive_cleanup EXIT
  trap 'exit 130' INT TERM HUP
}

# NEW replaces the settings file: the first call of a run keeps the original as
# .bak, the content goes in through a temp file next to the target and a rename,
# so an interrupted write cannot leave half a file
_write_settings_file() {
  local staged
  if [ -z "$BACKUP_MADE" ]; then
    cp "$BOOTSTRAP_CONFIG" "$BOOTSTRAP_CONFIG.bak" || return 1
    BACKUP_MADE=1
  fi
  staged="$(mktemp "$BOOTSTRAP_CONFIG.XXXXXX")" || return 1
  if cp "$BOOTSTRAP_CONFIG" "$staged" && cat "$1" > "$staged" && mv -f "$staged" "$BOOTSTRAP_CONFIG"; then
    return 0
  fi
  rm -f "$staged"
  return 1
}
''')

sub('''  { cp "$BOOTSTRAP_CONFIG" "$BOOTSTRAP_CONFIG.bak" && cat "$new" > "$BOOTSTRAP_CONFIG"; } || {
    warn "cannot write $BOOTSTRAP_CONFIG"
    exit 1
  }''', '''  _write_settings_file "$new" || {
    warn "cannot write $BOOTSTRAP_CONFIG"
    exit 1
  }''')

sub('''  local tmp
  interactive_collect''', '''  local tmp
  _interactive_traps
  interactive_collect''')
sub('''  tmp="$(mktemp)"
  settings_update_file''', '''  _interactive_mktemp tmp
  settings_update_file''')
sub('''  local live tmp rc=0
  prepare_omnishell_config''', '''  local live tmp rc=0
  _interactive_traps
  prepare_omnishell_config''')
sub('''  tmp="$(mktemp)"
  settings_update_omnishell''', '''  _interactive_mktemp tmp
  settings_update_omnishell''')
open(p, 'w').write(s)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-interactive.sh 2>&1 | tail -4; make lint test > /tmp/dotfi13.log 2>&1; echo "make rc=$?"; grep -c FAIL /tmp/dotfi13.log`
Expected: `all checks passed`, `make rc=0`, `0`.

- [ ] **Step 5: Commit**

```bash
git add bootstrap.sh tests/test-interactive.sh
git commit -m "fix: clean up temp files, write atomically and keep one backup per run"
```
