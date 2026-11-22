# Default Login Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `bootstrap.sh` offers to make zsh the login shell when zsh is installed and is not the current login shell.

**Architecture:** A new setting `bootstrap.set_default_shell` (`ask|yes|no`) resolves like `install_zsh` (flag > environment > settings file > default). A new step `ensure_default_shell` runs right after `ensure_zsh` in `main()` and calls `chsh`; every failure path only warns.

**Tech Stack:** bash (`bootstrap.sh`, `lib/settings.sh`), the repo's plain-bash test scripts (`tests/test-*.sh`, run with `make test`), ShellCheck (`make lint`).

**Spec:** `docs/superpowers/specs/2026-11-22-default-login-shell-design.md`

## Global Constraints

- Setting key `bootstrap.set_default_shell`, enum `ask|yes|no`, default `ask`.
- Flags `--set-default-shell` / `--no-set-default-shell`; environment `DOTFILES_SET_DEFAULT_SHELL`.
- Precedence: flag > environment > settings file > default. An invalid environment value warns and is ignored.
- `--yes` / `assume_yes` never run `chsh`; only mode `yes` or an interactive answer does.
- `/etc/shells` is never modified.
- No failure (no terminal, `chsh` missing or failing, path not in `/etc/shells`) may make `bootstrap.sh` exit non-zero (`set -euo pipefail` is active).
- Git artifacts, comments, identifiers: English. Follow the style of the surrounding code (`ensure_zsh`, `_install_zsh_mode`).

## Review Focus

- Login shell lookup returns nothing (no passwd entry, `getent` missing): fall back to `$SHELL`; if that is empty too, skip silently, no prompt.
- Login shell is already zsh under another path (`/bin/zsh`, `/usr/bin/zsh`, Linuxbrew): no prompt, no `chsh` (compare the basename, not the path).
- `chsh` is not installed or exits non-zero: warning with the manual command, bootstrap exits 0.
- Re-run after a successful change: the login shell now reads as zsh, so nothing is asked.
- `DOTFILES_SET_DEFAULT_SHELL` holds an invalid value: warning, falls back to the settings file.

---

### Task 1: The setting, its resolution and the flags

**Files:**
- Modify: `lib/settings.sh` (`SETTINGS_SCHEMA`, line ~114)
- Modify: `bootstrap.sh` (header comment, `parse_args` and its usage text, `read_conf_values`, new `_default_shell_mode`)
- Modify: `config.toml.example`, `README.md` (settings table, ~line 161)
- Test: `tests/test-bootstrap-settings.sh`, `tests/test-settings.sh`, `tests/test-interactive.sh`

**Interfaces:**
- Produces: global `SET_DEFAULT_SHELL_FLAG` (`""|yes|no`); global `CONF_SET_DEFAULT_SHELL` (value of `bootstrap.set_default_shell`, may be empty); `_default_shell_mode` prints `yes`, `no` or `ask` (precedence above, default `ask`).

- [ ] **Step 1: Write the failing tests**
  - `tests/test-bootstrap-settings.sh`, next to the `_install_zsh_mode` checks (lines ~60-66), same `sh_run` style: `set_default_shell comes from the file` (`'[bootstrap]' 'set_default_shell = "yes"'` → `_default_shell_mode` prints `yes`); `DOTFILES_SET_DEFAULT_SHELL beats the file` (`=no` → `no`); `an invalid env value warns and falls back to the file` (`=bogus` → `yes` and `$WORK/err` mentions `DOTFILES_SET_DEFAULT_SHELL`); `the default is ask` (no file → `ask`). A flag-precedence check sets `SET_DEFAULT_SHELL_FLAG=no` before calling `_default_shell_mode` with the env set to `yes` and expects `no`.
  - `tests/test-settings.sh:124`: add `bootstrap.set_default_shell` immediately after `bootstrap.install_zsh` in the expected key list.
  - `tests/test-interactive.sh`: the schema now has 21 keys, so every positional answer list grows by one prompt directly after the `install_zsh` answer: `empties 20` → `empties 21`; in the "answers are validated" scenario insert one more blank line after `yes` (`"yes\n\n\nfoot, kitty\nbogus\nlinux\n$(empties 16)y\n"`); `"-\n$(empties 19)y\n"` → `empties 20`; `"yes\n$(empties 19)n\n"` → `empties 20`. Update any further scenario in the file the same way until the whole file passes.
  - The existing template loop in `tests/test-bootstrap-settings.sh:36` already requires `config.toml.example` to document every schema key, so it fails until Step 3.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test-bootstrap-settings.sh; bash tests/test-settings.sh; bash tests/test-interactive.sh`
Expected: FAIL lines for the new key (`_default_shell_mode: command not found`, schema list, prompt counts).

- [ ] **Step 3: Implement**
  - `lib/settings.sh`: add `bootstrap.set_default_shell enum:yes,no,ask` as the second line of `SETTINGS_SCHEMA`.
  - `bootstrap.sh`: `SET_DEFAULT_SHELL_FLAG=""` next to `INSTALL_ZSH_FLAG`; in `parse_args` add `--set-default-shell) SET_DEFAULT_SHELL_FLAG=yes ;;` and `--no-set-default-shell) SET_DEFAULT_SHELL_FLAG=no ;;`; extend the usage line and the `--help` text (one line per flag, stating that `--yes` does not change the login shell); `read_conf_values` gets `CONF_SET_DEFAULT_SHELL="$(settings_get bootstrap.set_default_shell)"`; `_default_shell_mode()` mirrors `_install_zsh_mode` (own invalid-value warning naming `DOTFILES_SET_DEFAULT_SHELL`).
  - `bootstrap.sh` header comment: replace the "It never runs `chsh`" paragraph with: the login shell is only changed on an explicit "yes" (flag, environment or settings file) or an interactive answer, never by `--yes` alone. Add the new flags to the usage line at the top.
  - `config.toml.example`: after the `install_zsh` block add a commented block for `set_default_shell` in the same style (values, `--yes` rule, flags, environment variable).
  - `README.md` settings table: add the row `[bootstrap] set_default_shell` | `"yes"` · `"no"` · `"ask"` | `"ask"` | `--set-default-shell` / `--no-set-default-shell` | `DOTFILES_SET_DEFAULT_SHELL`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: all scripts report no `FAIL` lines.

- [ ] **Step 5: Commit**

```bash
git add lib/settings.sh bootstrap.sh config.toml.example README.md tests
git commit -m "feat: add the set_default_shell setting, flags and environment variable"
```

---

### Task 2: `ensure_default_shell` and the user-facing docs

**Files:**
- Modify: `bootstrap.sh` (new functions after `ensure_zsh`, call in `main()` right after `ensure_zsh`)
- Modify: `README.md` (step list, line ~86 "It never runs `chsh`", the NOTE at ~189, the `autosuggestions` row at ~330)
- Create: `tests/test-default-shell.sh`

**Interfaces:**
- Consumes: `_default_shell_mode` (Task 1), `_confirm`, `interactive_tty`, `warn`, `log`, `ASSUME_YES`.
- Produces: `ensure_default_shell` (no arguments, always returns 0). Stubbable helpers (tests redefine them after sourcing `bootstrap.sh`): `_login_shell` prints the current login shell path or nothing; `_shell_listed PATH` returns 0 when `PATH` is listed in `/etc/shells`.

- [ ] **Step 1: Write the failing tests** in the new `tests/test-default-shell.sh`, modelled on `tests/test-zsh-install.sh` (restricted `PATH` in `$WORK/bin`, `env -i`, sourcing with `BOOTSTRAP_SOURCE_ONLY=1`, `pass`/`fail`/`check`, final `exit` on `failures`). A fake `zsh` and a recording `chsh` (`$WORK/bin/chsh` appends its arguments to `$WORK/chsh.log`, exit code configurable) are created per scenario; `_login_shell`, `_shell_listed` and `interactive_tty` are redefined inside the `-c` snippet. One `run` helper takes env assignments and the snippet that sets up the stubs, then calls `ensure_default_shell`. Scenarios, each asserting exit 0 and the `chsh` log:
  - no zsh on `PATH` → `chsh` not called, no output on stderr.
  - login shell `/usr/bin/zsh` or `/bin/zsh` or `/home/linuxbrew/.linuxbrew/bin/zsh` (three checks) → not called, no prompt.
  - login shell empty and `$SHELL` empty → not called, silent; login shell empty but `SHELL=/bin/bash` → treated as bash (prompt path).
  - login shell `/bin/bash`, mode `ask`, answer `y` (`DOTFILES_TTY` file with `y`) → `chsh -s <path of the fake zsh>` called once; stdout/stderr mentions "next login".
  - same, answer `n` → not called, exit 0.
  - mode `ask` with `ASSUME_YES=1` → not called, a hint naming `chsh -s` is printed.
  - mode `ask` without a terminal (`DOTFILES_TTY` missing) → not called, hint printed.
  - mode `no` (settings file) → not called; `--no-set-default-shell` flag beats `set_default_shell = "yes"` → not called.
  - mode `yes` with `ASSUME_YES=1` → called (explicit setting wins over `--yes`).
  - mode `yes`, `interactive_tty` false → not called, warning with the manual `chsh -s <path>` command.
  - zsh path not listed (`_shell_listed` returns 1) → not called, warning contains the path and `/etc/shells`, `/etc/shells` untouched.
  - `chsh` missing from `PATH`, and `chsh` exiting 1 → warning with the manual command, exit 0.
  - after a successful run the stub `_login_shell` is switched to print the zsh path; a second `ensure_default_shell` does not call `chsh` again.

- [ ] **Step 2: Run the new test to verify it fails**

Run: `bash tests/test-default-shell.sh`
Expected: FAIL (`ensure_default_shell: command not found`).

- [ ] **Step 3: Implement in `bootstrap.sh`**
  - `_login_shell()`: on Linux `getent passwd "$(id -un)"` field 7; on macOS (`OS=Darwin`) `dscl . -read "/Users/$(id -un)" UserShell` second field; both fall back to `"${SHELL:-}"`; prints the path or nothing.
  - `_shell_listed PATH`: `grep -qxF "$1" /etc/shells`.
  - `ensure_default_shell()` (no arguments, returns 0 on every path), in this order: zsh not on `PATH` → return; basename of `_login_shell` is `zsh` or `_login_shell` is empty → return; mode from `_default_shell_mode`: `no` → return; `ask` → return with a hint (`log`/`warn` naming `chsh -s <path>`) when `ASSUME_YES` is `1` or `_confirm "zsh is not your login shell - make it the default?"` fails; `yes` → continue. Then: `_shell_listed` false → `warn` with the path, `/etc/shells` and the manual commands, return; `interactive_tty` false or `chsh` not on `PATH` → `warn` with the manual `chsh -s <path>`, return; run `chsh -s "$zsh" || warn ...`, on success `log` that it takes effect at the next login. Use `command -v zsh` for the path.
  - `main()`: call `ensure_default_shell` on the line after `ensure_zsh`.
  - Update the step list comment at the top of `bootstrap.sh` (step 1 mentions the optional login shell change).

- [ ] **Step 4: Update `README.md`**
  - Install step 2: add that it offers to make zsh the login shell.
  - Replace "It never runs `chsh`, and re-running it is safe." with a sentence stating the login shell only changes when you agree (setting `set_default_shell` or the prompt) and that re-running is safe.
  - Replace the NOTE ending "`chsh` is never run." with the new behaviour (prompt only when zsh is installed and not the login shell, `--yes` alone never does it, takes effect at the next login, warning with the manual command on failure).
  - Row ~330: split into `completion`, `history` (zsh/bash) and `autosuggestions`, `syntax-highlighting` (zsh only), keeping the table columns aligned.

- [ ] **Step 5: Run everything**

Run: `make lint && make test`
Expected: ShellCheck clean, no `FAIL` lines.

- [ ] **Step 6: Commit**

```bash
git add bootstrap.sh README.md tests/test-default-shell.sh
git commit -m "feat: offer to make zsh the default login shell"
```
