# Interactive Mode Minors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the remaining minors of the interactive mode and the settings writers listed in DOTFI-14.

**Architecture:** Small local changes: the interactive traps call one abort function (hook, then exit code), the staging file joins the temp file list, `_tracked_tmux_prefix` matches more spellings, both text-level writers learn to keep a BOM and (for the omnishell writer) CRLF through one `emit()` function, and a read-only settings directory gets a clear message and a README note.

**Tech Stack:** Bash 3.2-compatible shell, awk (BWK / mawk compatible), the repo's `tests/test-*.sh` style.

**Spec:** the design approved in chat for DOTFI-14; the ticket lists the acceptance criteria. Context: `docs/superpowers/specs/2026-10-07-interactive-install-design.md` and `docs/superpowers/plans/2026-10-08-settings-minors.md`.

## Global Constraints

- No new settings keys, flags or environment variables.
- Bash 3.2 and BWK awk / mawk compatible (the Ubuntu CI job runs the awk code under mawk); the settings file is parsed, never executed.
- Unchanged output for files without a BOM and without CRLF.
- A read-only settings directory is documented and reported, not worked around: the backup and the replacement file are created next to the settings file.
- Code and docs in English; commit messages `<type>: <description>` without trailers; `make lint test` green before each commit; run `shellcheck -x bootstrap.sh lib/settings.sh` as well (the Ubuntu runner reports more than the local version, for example SC2119 / SC2120).

## Review Focus

- INT, TERM and HUP at the module review reset the live omnishell config, exit with 130, 143 and 129, and leave no temp file. Pinned in Task 1.
- A normal run without `--interactive` sets no trap. Pinned in Task 1.
- A BOM plus CRLF settings file keeps the BOM first and CRLF on every line through both writers. Pinned in Task 3.
- `_tracked_tmux_prefix` ignores comments and options that are not `prefix`. Pinned in Task 2.
- A read-only settings directory fails before anything is changed and the message names the directory. Pinned in Task 4.

---

## File Structure

| File | Responsibility |
|---|---|
| `bootstrap.sh` (modify) | `_interactive_abort` and the signal traps, staging file registration, `_tracked_tmux_prefix` matching, the write error message |
| `lib/settings.sh` (modify) | `emit()`, BOM and CRLF handling in `settings_update_file` and `settings_update_omnishell` |
| `README.md` (modify) | the directory of the settings file must be writable |
| `tests/test-interactive.sh`, `tests/test-bootstrap-settings.sh`, `tests/test-settings.sh` (modify) | one failing test per change |

Code blocks whose first line is `# plan-apply: ...` are applied literally by the executor: `insert-before-final <file>` inserts the block before the final summary of a test file, `python` blocks are run with `python3`.

---

### Task 1: Signals run the abort hook; the staging file is cleaned up

**Files:**
- Modify: `bootstrap.sh`, `tests/test-interactive.sh`

**Interfaces:**
- Produces: `_interactive_abort CODE` runs `PROMPT_ABORT_HOOK` when one is set, then exits with CODE. `_interactive_traps` maps INT to 130, TERM to 143 and HUP to 129 through it (the EXIT trap still removes the temp files). `_write_settings_file` adds its staging file to `INTERACTIVE_TMPFILES` right after `mktemp`.

- [ ] **Step 1: Write the failing test**

```bash
# plan-apply: insert-before-final tests/test-interactive.sh
echo ">> signals: abort hook, exit codes, cleanup"
sig_case() {   # <signal> <expected exit code>: the signal arrives while a module review is open
  fresh
  ix_run "" 'prepare_omnishell_config; _interactive_traps; _interactive_mktemp t; : > "$t"
    printf "\n[modules.testmod]\nenabled = true\n" >> "$HOME/.config/omnishell/config.toml"
    PROMPT_ABORT_HOOK=_write_omnishell_config; kill -'"$1"' $$; echo not-reached'
  check "$1 exits with $2"                                  "[ \"\$RC\" = $2 ]"
  check "$1 does not let the run continue"                  '! grep -q not-reached <<< "$OUT"'
  check "$1 removes the temp files"                         '[ -z "$(ls -A "$WORK/tmp")" ]'
  check "$1 resets the live omnishell config"               '! grep -q testmod "$LIVE"'
}
sig_case INT 130
sig_case TERM 143
sig_case HUP 129
fresh
ix_run "" '_write_settings_file "$BOOTSTRAP_CONFIG"; printf %s "$INTERACTIVE_TMPFILES"'
check "the staging file is registered for cleanup"          'grep -q "config.toml\." <<< "$OUT"'
fresh
# only our own traps count: a runner may start the shell with SIGPIPE ignored, which `trap -p` also lists;
# the output goes to a file because bash 3.2 does not show the traps inside a pipeline
ix_run "" 'INTERACTIVE_FLAG=; interactive_settings; interactive_modules; trap -p EXIT INT TERM HUP > "$HOME/traps"; grep -c _interactive "$HOME/traps" || true'
check "a run without --interactive installs no trap"        '[ "$OUT" = 0 ]'
ix_run "" '_interactive_traps; trap -p EXIT INT TERM HUP > "$HOME/traps"; grep -c _interactive "$HOME/traps" || true'
check "the same probe sees the four traps once they are set" '[ "$OUT" = 4 ]'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-interactive.sh 2>&1 | sed -n '/signals: abort hook/,$p'`
Expected: INT / TERM / HUP checks FAIL (exit code 130 for all, the live config keeps `testmod`), the staging file check FAILs; the no-trap check passes already (it guards against a regression).

- [ ] **Step 3: Write minimal implementation**

```bash
# plan-apply: python
p = 'bootstrap.sh'
s = open(p).read()
def sub(old, new):
    global s
    assert s.count(old) == 1, old[:70]
    s = s.replace(old, new)
sub('''# temp files go away on exit, end of input and Ctrl-C alike
_interactive_traps() {
  trap _interactive_cleanup EXIT
  trap 'exit 130' INT TERM HUP
}''', '''# a signal during a review undoes what the hook undoes, then leaves with the
# signal's conventional exit code; the EXIT trap removes the temp files
_interactive_abort() {
  [ -z "$PROMPT_ABORT_HOOK" ] || "$PROMPT_ABORT_HOOK"
  exit "$1"
}

# temp files go away on exit, end of input and signals alike
_interactive_traps() {
  trap _interactive_cleanup EXIT
  trap '_interactive_abort 130' INT
  trap '_interactive_abort 143' TERM
  trap '_interactive_abort 129' HUP
}''')
sub('''  staged="$(mktemp "$target.XXXXXX")" || return 1
''', '''  staged="$(mktemp "$target.XXXXXX")" || return 1
  INTERACTIVE_TMPFILES="${INTERACTIVE_TMPFILES}${staged}"$'\\n'
''')
open(p, 'w').write(s)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-interactive.sh 2>&1 | tail -4`
Expected: `all checks passed`. If a signal check hangs or fails only under bash 3.2 (`/bin/bash`), run the file once with `/bin/bash tests/test-interactive.sh` and rule on it in the ledger before changing the code.

- [ ] **Step 5: Commit**

```bash
git add bootstrap.sh tests/test-interactive.sh
git commit -m "fix: reset the live omnishell config on signals and clean up the staging file"
```

---

### Task 2: More spellings of the tracked tmux prefix

**Files:**
- Modify: `bootstrap.sh`, `tests/test-bootstrap-settings.sh`

**Interfaces:**
- Produces: `_tracked_tmux_prefix FILE` prints the key of the first `set` or `set-option` line whose flags contain `g` (`-g`, `-sg`, `-gq`) and whose option is `prefix`; nothing for comments, other options (`prefix2`) and flags without `g`.

- [ ] **Step 1: Write the failing test**

```bash
# plan-apply: insert-before-final tests/test-bootstrap-settings.sh
echo ">> tracked prefix spellings"
fresh
tp() { printf '%s\n' "$@" > "$WORK/tp.conf"; sh_run '' '_tracked_tmux_prefix "'"$WORK"'/tp.conf"'; }
tp 'set -g prefix C-a'
check "set -g prefix"                              '[ "$OUT" = C-a ]'
tp 'set-option -g prefix C-x'
check "set-option -g prefix"                       '[ "$OUT" = C-x ]'
tp 'set -sg prefix M-a'
check "set -sg prefix"                             '[ "$OUT" = M-a ]'
tp 'set -gq prefix C-y'
check "set -gq prefix"                             '[ "$OUT" = C-y ]'
tp '# set -g prefix C-q' 'set -g prefix C-w'
check "a commented line is ignored"                '[ "$OUT" = C-w ]'
tp 'set -g prefix2 C-b'
check "prefix2 is not the prefix"                  '[ -z "$OUT" ]'
tp 'set -s prefix C-z'
check "a flag without g is not matched"            '[ -z "$OUT" ]'
tp 'bind prefix C-u'
check "other commands are not matched"             '[ -z "$OUT" ]'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-bootstrap-settings.sh 2>&1 | sed -n '/tracked prefix spellings/,$p'`
Expected: FAIL for `set-option`, `-sg` and `-gq`; the other checks pass.

- [ ] **Step 3: Write minimal implementation**

```bash
# plan-apply: python
p = 'bootstrap.sh'
s = open(p).read()
old = '''  awk '$1 == "set" && $2 == "-g" && $3 == "prefix" { print $4; exit }' "$1" 2>/dev/null || true'''
assert s.count(old) == 1
s = s.replace(old, '''  awk '($1 == "set" || $1 == "set-option") && $2 ~ /^-[a-zA-Z]*g[a-zA-Z]*$/ && $3 == "prefix" { print $4; exit }' "$1" 2>/dev/null || true''')
open(p, 'w').write(s)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-bootstrap-settings.sh 2>&1 | tail -3; shellcheck -x bootstrap.sh lib/settings.sh | grep -E 'SC2119|SC2120' | head -2`
Expected: `all checks passed` and no ShellCheck output.

- [ ] **Step 5: Commit**

```bash
git add bootstrap.sh tests/test-bootstrap-settings.sh
git commit -m "fix: recognise set-option and combined flags for the tracked tmux prefix"
```

---

### Task 3: The writers keep a BOM, the omnishell writer keeps CRLF

**Files:**
- Modify: `lib/settings.sh`, `tests/test-settings.sh`

**Interfaces:**
- Consumes: `settings_update_file FILE CHANGES`, `settings_update_omnishell FILE LIVE DEFAULT`.
- Produces: both writers recognise a UTF-8 BOM before the first line (for header detection) and print it again, first, in their output. `settings_update_omnishell` ends every table block it writes with the file's line ending (CR when the first line ends with CR), including the blank line that separates an appended table.

- [ ] **Step 1: Write the failing test**

```bash
# plan-apply: insert-before-final tests/test-settings.sh
echo ">> writers: BOM, and CRLF in the omnishell writer"
BOM="$(printf '\357\273\277')"
printf '%s[bootstrap]\nassume_yes = false\n' "$BOM" > "$F"
OUT="$(settings_update_file "$F" "$(chg bootstrap assume_yes true)")"
check "settings_update_file keeps a BOM first"                   '[ "$(printf %s "$OUT" | head -c 3)" = "$BOM" ]'
check "and edits the table in place, without a second one"       '[ "$(grep -c "bootstrap\]" <<< "$OUT")" = 1 ] && grep -qx "assume_yes = true" <<< "$OUT"'
printf '%s[bootstrap]\nassume_yes = false\n' "$BOM" > "$F"
check "a BOM file without changes is printed byte-identical"     'settings_update_file "$F" "" | cmp -s - "$F"'

printf '%s\n' '[modules.tmux]' 'enabled = false' > "$DEF"
printf '%s\n' '[modules.tmux]' 'enabled = true' '' '[modules.broot]' 'enabled = true' > "$LIVE"
printf '%s[bootstrap]\r\nassume_yes = false\r\n\r\n[modules.tmux]\r\nenabled = false\r\n' "$BOM" > "$F"
OUT="$(settings_update_omnishell "$F" "$LIVE" "$DEF")"
check "settings_update_omnishell keeps a BOM first"              '[ "$(printf %s "$OUT" | head -c 3)" = "$BOM" ]'
check "the replaced and the appended table use the file CR"      '[ "$(grep -c "${CR}\$" <<< "$OUT")" = "$(grep -c "" <<< "$OUT")" ]'
check "the new values are there"                                 'grep -q "^enabled = true" <<< "$OUT" && grep -q "\[modules.broot\]" <<< "$OUT"'
check "no second tmux table appears"                             '[ "$(grep -c "modules.tmux\]" <<< "$OUT")" = 1 ]'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-settings.sh 2>&1 | sed -n '/BOM, and CRLF/,$p'`
Expected: FAIL for the BOM-first checks, the in-place edit (a second `[bootstrap]` appears), the CRLF line endings and the single tmux table; the byte-identical check passes already.

- [ ] **Step 3: Write minimal implementation**

```bash
# plan-apply: python
import re
p = 'lib/settings.sh'
s = open(p).read()

# --- settings_update_file ---
m = re.search(r'settings_update_file\(\) \{.*?\n\}\n', s, re.S)
assert m
fn = m.group(0)
def sub(text, old, new, count=1):
    assert text.count(old) == count, (old, text.count(old))
    return text.replace(old, new)
fn = sub(fn, '''    # lines this script writes end like the file does
    function out(s) { printf "%s%s\\n", s, cr }''', '''    # all output goes through emit(); the BOM of the file is printed once, first
    function emit(s) { printf "%s%s", pre, s; pre = "" }
    # lines this script writes end like the file does
    function out(s) { emit(s cr "\\n") }''')
fn = sub(fn, '''      n = split(ENVIRON["CHG"], rows, "\\n"); nc = 0; cr = ""; nt = 0''', '''      n = split(ENVIRON["CHG"], rows, "\\n"); nc = 0; cr = ""; nt = 0; pre = ""; bom = "\\357\\273\\277"''')
fn = sub(fn, '''    FNR == NR {
      lines++''', '''    FNR == NR {
      if (FNR == 1 && substr($0, 1, length(bom)) == bom) $0 = substr($0, length(bom) + 1)
      lines++''')
fn = sub(fn, '''    FNR == 1 { t = "" }''', '''    FNR == 1 {
      t = ""
      if (substr($0, 1, length(bom)) == bom) { pre = bom; $0 = substr($0, length(bom) + 1) }
    }''')
fn = sub(fn, '''      t = tname($0); print
''', '''      t = tname($0); emit($0 "\\n")
''')
fn = sub(fn, '''    bracket($0) { t = ""; print; next }''', '''    bracket($0) { t = ""; emit($0 "\\n"); next }''')
fn = sub(fn, '''    { print }
    END {''', '''    { emit($0 "\\n") }
    END {''')
s = s[:m.start()] + fn + s[m.end():]

# --- settings_update_omnishell ---
m = re.search(r'settings_update_omnishell\(\) \{.*?\n\}\n', s, re.S)
assert m
fn = m.group(0)
fn = sub(fn, '''    function bracket(line) { return line ~ /^[ \\t]*\\[/ }
''', '''    function bracket(line) { return line ~ /^[ \\t]*\\[/ }
    # all output goes through emit(); the BOM of the file is printed once, first
    function emit(s) { printf "%s%s", pre, s; pre = "" }
    # generated lines end like the file does
    function crlf(t) { if (cr != "") gsub(/\\n/, cr "\\n", t); return t }
''')
fn = sub(fn, '''      skipping = 0; pend = ""
    }''', '''      skipping = 0; pend = ""; pre = ""; cr = ""; bom = "\\357\\273\\277"
    }
    FNR == 1 {
      if (substr($0, 1, length(bom)) == bom) { pre = bom; $0 = substr($0, length(bom) + 1) }
      if ($0 ~ /\\r$/) cr = "\\r"
    }''')
fn = sub(fn, '''    header($0) {
      printf "%s", pend; pend = ""; skipping = 0''', '''    header($0) {
      emit(pend); pend = ""; skipping = 0''')
fn = sub(fn, '''      if (name in otext) { printf "%s", otext[name]; used[name] = 1; skipping = 1; next }''', '''      if (name in otext) { emit(crlf(otext[name])); used[name] = 1; skipping = 1; next }''')
fn = sub(fn, '''      print; next
    }
    bracket($0) { printf "%s", pend; pend = ""; skipping = 0; print; next }''', '''      emit($0 "\\n"); next
    }
    bracket($0) { emit(pend); pend = ""; skipping = 0; emit($0 "\\n"); next }''')
fn = sub(fn, '''    { print }
    END {
      printf "%s", pend''', '''    { emit($0 "\\n") }
    END {
      emit(pend)''')
fn = sub(fn, '''{ printf "%s%s", sep, otext[oorder[i]]; sep = "\\n" }''', '''{ emit(crlf(sep otext[oorder[i]])); sep = "\\n" }''')
s = s[:m.start()] + fn + s[m.end():]
open(p, 'w').write(s)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-settings.sh 2>&1 | tail -3; bash tests/test-interactive.sh 2>&1 | tail -2; bash tests/test-bootstrap-settings.sh 2>&1 | tail -2`
Expected: all three end with `all checks passed`, including every earlier writer check (output for files without BOM and CRLF is unchanged).

- [ ] **Step 5: Commit**

```bash
git add lib/settings.sh tests/test-settings.sh
git commit -m "fix: keep a BOM in both settings writers and CRLF in the omnishell writer"
```

---

### Task 4: A read-only settings directory is reported and documented

**Files:**
- Modify: `bootstrap.sh`, `README.md`, `tests/test-interactive.sh`

**Interfaces:**
- Produces: the failed write names the directory: `cannot write <file> (its directory <dir> must be writable: the backup and the replacement file are created there)`. The README interactive paragraph says the directory must be writable.

- [ ] **Step 1: Write the failing test**

```bash
# plan-apply: insert-before-final tests/test-interactive.sh
echo ">> a settings directory that is not writable"
if [ "$(id -u)" -ne 0 ]; then
  fresh; chmod a-w "$WORK/cfg"
  ix_run "yes\n$(empties 19)y\n" 'interactive_settings'
  chmod u+w "$WORK/cfg"
  check "the write fails and the message names the directory"   '[ "$RC" = 1 ] && grep -q "must be writable" "$WORK/err" && grep -qF "$WORK/cfg" "$WORK/err"'
  check "the settings file is untouched"                        'cmp -s "$CONF" "$DOTFILES/config.toml.example"'
fi
check "the README says the directory must be writable"          'grep -q "must be writable" "$DOTFILES/README.md"'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-interactive.sh 2>&1 | sed -n '/not writable/,$p'`
Expected: FAIL for the message check and the README check; the untouched-file check passes. (Running as root skips the first two, then only the README check applies.)

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
('''    warn "cannot write $BOOTSTRAP_CONFIG"
    exit 1''', '''    warn "cannot write $BOOTSTRAP_CONFIG (its directory $(dirname "$BOOTSTRAP_CONFIG") must be writable: the backup and the replacement file are created there)"
    exit 1'''),
])
edit('README.md', [
('terminal and cannot be combined with `--yes`. Answering `n` at the settings diff',
 'terminal and cannot be combined with `--yes`. The directory of the settings file\nmust be writable, because the backup and the replacement file are created next to\nit. Answering `n` at the settings diff'),
])
```

- [ ] **Step 4: Run the full suite**

Run: `make lint test > /tmp/dotfi14.log 2>&1; echo "make rc=$?"; grep -c FAIL /tmp/dotfi14.log; shellcheck -x bootstrap.sh lib/settings.sh | grep -cE 'SC[0-9]+'`
Expected: `make rc=0`, `0`, `0`.

- [ ] **Step 5: Commit**

```bash
git add bootstrap.sh README.md tests/test-interactive.sh
git commit -m "docs: report and document a read-only settings directory"
```
