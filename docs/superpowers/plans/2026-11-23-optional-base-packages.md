# Optional base packages and stow packages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the settings file leave out individual system packages, stow packages and the macOS Terminal.app profile, without changing any default.

**Architecture:** Three new `[bootstrap]` keys (`skip_packages`, `skip_stow`, `terminal_app_profile`) join the schema in `lib/settings.sh`. `bootstrap.sh` resolves each as environment > settings file > default, validates list names against an allowed set (warn and ignore the rest) and applies the result in `install_deps`, `build_packages`, `main()` and `setup_terminal_app`. A final check warns when a skipped package is still needed by an enabled omnishell module.

**Tech Stack:** bash, the restricted TOML subset parser in `lib/settings.sh`, plain-bash tests under `tests/`.

**Spec:** `docs/superpowers/specs/2026-11-22-optional-base-packages-design.md`

## Global Constraints

- Defaults must not change; with no setting every existing test passes unchanged except the prompt counts in `tests/test-interactive.sh`.
- `skip_packages` allowed names: `fzf zoxide ripgrep fd bat git-delta`. `stow`, `curl`, `ca-certificates` and anything else: warn and ignore.
- `skip_stow` allowed names: `git tmux bat ghostty`. `zsh` and anything else: warn and ignore.
- Environment variables: `DOTFILES_SKIP_PACKAGES`, `DOTFILES_SKIP_STOW` (space separated), `DOTFILES_TERMINAL_APP_PROFILE` (`1`/`0`, `true`/`false`, `yes`/`no`). No new command line flags.
- Precedence is environment > settings file > default; an empty environment variable falls back to the file, like `DOTFILES_TERMINALS`.
- Schema order: the new keys follow `bootstrap.install_ghostty` in this order: `skip_packages`, `skip_stow`, `terminal_app_profile` (`--interactive` prompts follow schema order).
- Every skipped part logs one `skipping <name> (<reason>)` line.
- No uninstall; Root Loops (`rootloops/apply.sh`) and omnishell modules stay untouched.
- Git artifacts are English; run `make lint` and all `tests/test-*.sh` before the last commit.

## Review Focus

- A name in the wrong case or listed twice (`["FZF", "fzf", "fzf"]`) must not break the install list. Pinned in Task 2.
- `skip_stow = ["zsh"]` and `skip_packages = ["stow"]` must be ignored with a warning and the mandatory part still installs. Pinned in Task 2.
- `skip_packages = ["fd"]` must drop `fd-find` on apt and `fd` on Homebrew. Pinned in Task 3.
- `skip_stow = ["ghostty"]` must not stop `install_ghostty` and vice versa. Pinned in Task 4.
- `DOTFILES_SKIP_STOW=""` (set but empty) must fall back to the settings file value. Pinned in Task 2.

---

### Task 1: Schema, template, README and interactive prompt counts

**Files:**
- Modify: `lib/settings.sh` (`SETTINGS_SCHEMA`, after `bootstrap.install_ghostty bool`)
- Modify: `bootstrap.sh` (`read_conf_values`)
- Modify: `config.toml.example`, `README.md` (settings table, a short note after the `install_ghostty` note)
- Test: `tests/test-settings.sh`, `tests/test-bootstrap-settings.sh`, `tests/test-interactive.sh`

**Interfaces:**
- Produces: schema keys `bootstrap.skip_packages` (list), `bootstrap.skip_stow` (list), `bootstrap.terminal_app_profile` (bool); shell variables `CONF_SKIP_PACKAGES`, `CONF_SKIP_STOW`, `CONF_TERMINAL_APP_PROFILE` (space separated lists, `true` / `false` / empty) set by `read_conf_values`.

- [ ] **Step 1: Update the tests first.** In `tests/test-settings.sh` extend the "the schema lists every key" expectation with `bootstrap.skip_packages bootstrap.skip_stow bootstrap.terminal_app_profile` directly after `bootstrap.install_ghostty`. In `tests/test-bootstrap-settings.sh` add a check "the new keys load from the file" that writes `skip_packages = ["fzf", "bat"]`, `skip_stow = ["tmux"]`, `terminal_app_profile = false` and asserts `CONF_SKIP_PACKAGES = "fzf bat"`, `CONF_SKIP_STOW = tmux`, `CONF_TERMINAL_APP_PROFILE = false`. In `tests/test-interactive.sh` raise every `empties` count by 3 (22 → 25, 21 → 24) and, in the answers line that types `foot, kitty`, put four empty answers after it (`install_ghostty` plus the three new keys) instead of one.
- [ ] **Step 2: Run** `bash tests/test-settings.sh; bash tests/test-bootstrap-settings.sh; bash tests/test-interactive.sh`. Expected: FAIL (schema list, missing variables, template check "the template documents …").
- [ ] **Step 3: Add the three schema lines** to `SETTINGS_SCHEMA` and read the values in `read_conf_values` into the three `CONF_*` variables.
- [ ] **Step 4: Document the keys** in `config.toml.example` as commented-out entries in the style of `install_ghostty` (each states default, allowed names, environment variable, and that stow and omnishell cannot be skipped) and in the README settings table plus one short note.
- [ ] **Step 5: Run** the three test files again plus `make lint`. Expected: all pass.
- [ ] **Step 6: Commit** `feat: add skip_packages, skip_stow and terminal_app_profile settings`.

### Task 2: Validated skip lists

**Files:**
- Modify: `bootstrap.sh` (new helpers next to `build_packages`)
- Test: `tests/test-optional-parts.sh` (new; harness style of `tests/test-bootstrap-settings.sh`, sourcing `bootstrap.sh` with `BOOTSTRAP_SOURCE_ONLY=1`)

**Interfaces:**
- Produces: `SKIP_PACKAGES_ALLOWED="fzf zoxide ripgrep fd bat git-delta"`, `SKIP_STOW_ALLOWED="git tmux bat ghostty"`.
- Produces: `_skip_list <label> <env-value> <conf-value> <allowed-words>` prints the accepted names space separated, lower-cased, de-duplicated, in input order. It uses the environment value when non-empty, else the file value. Each rejected name produces `warn "ignoring <label> '<name>': not one of <allowed-words>"`. Globbing is off while splitting.
- Produces: `skipped_packages` and `skipped_stow` print the accepted lists using `DOTFILES_SKIP_PACKAGES` / `CONF_SKIP_PACKAGES` and `DOTFILES_SKIP_STOW` / `CONF_SKIP_STOW`; `_is_in_list <word> <list>` returns 0 when the word is in the space separated list.

- [ ] **Step 1: Write the failing tests** in `tests/test-optional-parts.sh`: `_skip_list` returns `fzf bat` for `["FZF", "bat", "fzf"]`; `DOTFILES_SKIP_STOW=tmux` beats `skip_stow = ["git"]`; `DOTFILES_SKIP_STOW=""` falls back to the file value; `skip_packages = ["stow", "curl", "nope"]` yields an empty list and three warnings naming each name; `skip_stow = ["zsh"]` yields an empty list and a warning; `*` is rejected without globbing.
- [ ] **Step 2: Run** `bash tests/test-optional-parts.sh`. Expected: FAIL (functions not defined).
- [ ] **Step 3: Implement** the four functions with the signatures above.
- [ ] **Step 4: Run** the test file. Expected: all checks pass.
- [ ] **Step 5: Commit** `feat: validate the skip lists of skip_packages and skip_stow`.

### Task 3: skip_packages in install_deps

**Files:**
- Modify: `bootstrap.sh` (`install_deps`)
- Test: `tests/test-optional-parts.sh`

**Interfaces:**
- Consumes: `skipped_packages`, `_is_in_list` from Task 2.
- Produces: `install_deps` leaves skipped names out of the Homebrew list (`DEPS`, using the Homebrew name `fd`) and out of the apt list (`fd` maps to `fd-find`; `git-delta` stays `git-delta`). It logs `skipping package <name> (skip_packages)` once per skipped name.

- [ ] **Step 1: Write the failing tests** using the stub style of the `install_deps (apt)` block in `tests/test-omnishell-toolchain.sh` (stubbed `apt-get`, `brew`, `stow`, `uname`, recorded calls): with `skip_packages = ["fzf", "git-delta"]` the apt calls contain neither `fzf` nor `git-delta` but still `stow`, `zoxide`, `bat`; with `["fd"]` the apt calls lack `fd-find` and the brew call lacks `fd`; with no setting the call lists equal today's; the log contains `skipping package fzf`.
- [ ] **Step 2: Run** `bash tests/test-optional-parts.sh`. Expected: FAIL on the new checks.
- [ ] **Step 3: Implement** by filtering the package arrays inside `install_deps` through `_is_in_list` before use; keep the existing `stow` presence check unchanged.
- [ ] **Step 4: Run** `bash tests/test-optional-parts.sh; bash tests/test-omnishell-toolchain.sh`. Expected: pass.
- [ ] **Step 5: Commit** `feat: skip selected system packages in install_deps`.

### Task 4: skip_stow in build_packages and the generated config

**Files:**
- Modify: `bootstrap.sh` (`build_packages`, `main`)
- Test: `tests/test-optional-parts.sh`, `tests/test-bootstrap-settings.sh`

**Interfaces:**
- Consumes: `skipped_stow`, `_is_in_list`.
- Produces: `build_packages` removes skipped names from `PACKAGES` and logs `skipping stow package <name> (skip_stow)`. A new function `stow_package_enabled <name>` returns 0 unless the name is in `skipped_stow`. `main` calls `render_git_settings`, `setup_git_delta`, `setup_git_identity` and `setup_git_signing_key` only when `stow_package_enabled git`; `render_tmux_settings` only when `stow_package_enabled tmux`; `setup_ghostty_keybinds` and `render_ghostty_settings` only when `stow_package_enabled ghostty`. `install_ghostty` is unaffected.

- [ ] **Step 1: Write the failing tests:** `skip_stow = ["tmux", "bat"]` gives `PACKAGES` without those two and with `zsh git ghostty`; `terminals` additions still work; `stow_package_enabled git` is true by default and false when skipped; with `skip_stow = ["ghostty"]` and `install_ghostty` left on, `install_ghostty` still reaches the install path (stubbed `brew`, `OS=Darwin`); a `main` run with all functions stubbed to record calls skips exactly the functions listed above for each of `git`, `tmux`, `ghostty`.
- [ ] **Step 2: Run** the two test files. Expected: FAIL.
- [ ] **Step 3: Implement** the filter in `build_packages`, add `stow_package_enabled`, and guard the calls in `main` as specified.
- [ ] **Step 4: Run** `bash tests/test-optional-parts.sh; bash tests/test-bootstrap-settings.sh; bash tests/test-checkout-consistency.sh`. Expected: pass.
- [ ] **Step 5: Commit** `feat: skip selected stow packages and their generated config`.

### Task 5: terminal_app_profile

**Files:**
- Modify: `bootstrap.sh` (`setup_terminal_app`, new `_terminal_app_profile_enabled`)
- Test: `tests/test-optional-parts.sh`

**Interfaces:**
- Produces: `_terminal_app_profile_enabled` returns 0 unless `DOTFILES_TERMINAL_APP_PROFILE` (non-empty, `1/true/yes` on, `0/false/no` off, other values warn and are ignored) or, failing that, `CONF_TERMINAL_APP_PROFILE = false` switches it off. `setup_terminal_app` returns before `open`, `defaults` and `sleep` when it is off and logs `skipping Terminal.app profile (terminal_app_profile)` on macOS.

- [ ] **Step 1: Write the failing tests** with stubbed `open`, `defaults`, `sleep` and `OS=Darwin`: default imports the profile; file `false` skips; `DOTFILES_TERMINAL_APP_PROFILE=1` beats a file `false`; `=bogus` warns and falls back to the file; on `OS=Linux` nothing is logged and nothing runs either way.
- [ ] **Step 2: Run** the test file. Expected: FAIL.
- [ ] **Step 3: Implement** the helper (same shape as `_install_ghostty_enabled`) and the early return.
- [ ] **Step 4: Run** the test file. Expected: pass.
- [ ] **Step 5: Commit** `feat: add a switch for the Terminal.app profile import`.

### Task 6: Warn when a skipped package is still needed by a module

**Files:**
- Modify: `bootstrap.sh` (new function, called in `apply_omnishell` right after `prepare_omnishell_config`)
- Test: `tests/test-optional-parts.sh`

**Interfaces:**
- Consumes: `skipped_packages`, `settings_merge_omnishell "$DOTFILES/omnishell/config.toml"`.
- Produces: `warn_skipped_packages_needed_by_modules`, which warns once per affected package: `skipped package <name> is still used by the enabled omnishell module <module>; disable the module in [modules.<module>] or install <name> yourself`. Mapping: `fzf` → `fzf`; `zoxide` → `zoxide`; `bat` → `colorized-man`, `modern-aliases`; `ripgrep` and `fd` → `modern-aliases`; `git-delta` has no module. A module counts as enabled when the merged config has `enabled = true` in its `[modules.<name>]` table.

- [ ] **Step 1: Write the failing tests:** with the tracked default config and `skip_packages = ["fzf"]` the warning names `fzf` and module `fzf`; adding `[modules.fzf]` with `enabled = false` in the settings file removes the warning; `skip_packages = ["git-delta"]` never warns; no skip list produces no output.
- [ ] **Step 2: Run** the test file. Expected: FAIL.
- [ ] **Step 3: Implement** the function (awk over the merged config) and call it from `apply_omnishell`.
- [ ] **Step 4: Run** `bash tests/test-optional-parts.sh; bash tests/test-omnishell-toolchain.sh; make lint`. Expected: pass.
- [ ] **Step 5: Commit** `feat: warn when a skipped package is still used by an omnishell module`.

### Task 7: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Run** `make lint` and every `tests/test-*.sh`. Expected: all pass.
- [ ] **Step 2: Run** `bash bootstrap.sh --help` and confirm no new flags appear; confirm `config.toml.example` loads without warnings (covered by `tests/test-bootstrap-settings.sh`).
- [ ] **Step 3: Check the README** settings table, the new note and `config.toml.example` agree on names, defaults and environment variables.
