# New omnishell default modules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable the omnishell modules `navi`, `tealdeer`, `you-should-use` and `dynamic-completion` in the default `omnishell/config.toml` and raise the omnishell floor to 0.10.0.

**Architecture:** Four new `[modules.*]` tables in the tracked default config. All four modules first shipped in omnishell 0.10.0, so `OMNISHELL_MIN_VERSION` in `bootstrap.sh` and the README follow. Shell-specific modules (`you-should-use`: zsh, `dynamic-completion`: bash) are enabled globally; omnishell applies each only to its own shell.

**Tech Stack:** TOML, bash, the repo's `tests/test-*.sh` harness (`make test`).

**Spec:** Agreed in chat on YouTrack issue DOTFI-26; the issue description is the requirement list. No separate spec file.

## Global Constraints

- Language: English for code, comments, docs and git (user-facing text excepted).
- `ble-sh` stays disabled: omnishell rejects `ble-sh` together with `fzf` (`omnishell validate`: "conflicts with fzf"), and `navi` requires `fzf`.
- `bash-completion` needs no change: the already enabled `completion` module installs and loads `bash-completion@2`.
- `dynamic-completion.commands` is exactly `["terraform", "vault", "aws=aws_completer", "mc"]` (an implementer's call; binaries not on `PATH` are skipped silently).
- `OMNISHELL_MIN_VERSION` becomes `0.10.0`.
- No `ignored_aliases` for `you-should-use` for now.
- `config.toml.example` has no omnishell module entries; leave it unchanged unless a test shows otherwise.
- Commit format `<type>: <description>`, English, no attribution trailers.

## Review Focus

- A bash-only module (`dynamic-completion`) and a zsh-only module (`you-should-use`) enabled globally must not break `omnishell validate` for either shell.
- `ble-sh` accidentally enabled together with `fzf` (config error) must be caught by a test.
- Docs naming a stale floor (`0.9.0`) anywhere after the bump.
- A host with omnishell below 0.10.0 must be upgraded by `bootstrap.sh`, not silently accept the new config.
- `navi` enabled while `fzf` is off would fail validation; `fzf` must stay enabled.

---

### Task 1: Enable the four modules in the default config

**Files:**
- Modify: `omnishell/config.toml`
- Test: `tests/test-optional-parts.sh` (next to the `zsh-completions` assertion at line 239)

**Interfaces:**
- Consumes: nothing.
- Produces: default config with `[modules.navi]`, `[modules.tealdeer]`, `[modules.you-should-use]`, `[modules.dynamic-completion]` all `enabled = true`; `[modules.ble-sh]` absent.

- [ ] **Step 1: Write the failing tests** in `tests/test-optional-parts.sh`, after the existing `zsh-completions` check. Add a helper `module_enabled() { awk -v m="$1" '$0 == "[modules." m "]" {f=1; next} /^\[/ {f=0} f && /^enabled = true/ {ok=1} END {exit !ok}' "$DOTFILES/omnishell/config.toml"; }` and checks named:
  - `omnishell/config.toml enables navi`, `... tealdeer`, `... you-should-use`, `... dynamic-completion` (each `module_enabled <name>`).
  - `dynamic-completion lists the self-completing CLIs`: the config contains `commands = ["terraform", "vault", "aws=aws_completer", "mc"]`.
  - `ble-sh stays off (it conflicts with fzf)`: `! grep -q '^\[modules\.ble-sh\]' "$DOTFILES/omnishell/config.toml"`.
  - `fzf stays enabled (navi requires it)`: `module_enabled fzf`.
  - `the default config validates`: runs only when `omnishell` is on `PATH` and `omnishell version` reports 0.10.0 or newer; copies the default config to `$WORK/validate/omnishell/config.toml` and asserts `XDG_CONFIG_HOME=$WORK/validate omnishell validate` exits 0. Otherwise prints a skip line and does not count as a failure.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test-optional-parts.sh`
Expected: the four `enables ...` checks and the `commands` check FAIL; `ble-sh stays off` and `fzf stays enabled` pass.

- [ ] **Step 3: Add the module tables to `omnishell/config.toml`**, after `[modules.zsh-completions]`: `navi` and `tealdeer` (comment: Ctrl+G cheatsheet browser needing fzf; tldr client), `you-should-use` (comment: zsh only, reminds of an existing alias), `dynamic-completion` with `[modules.dynamic-completion.options]` `commands` as in Global Constraints (comment: bash only, `complete -C` for CLIs that complete themselves). Add one comment near `fzf` or at the top: `ble-sh` is not enabled because it conflicts with `fzf`, which `navi` needs.

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/test-optional-parts.sh && bash tests/test-bootstrap-settings.sh`
Expected: all checks `ok`, no `FAIL` (the second file compares the live config with the repo default and must stay green).

- [ ] **Step 5: Commit**

```bash
git add omnishell/config.toml tests/test-optional-parts.sh
git commit -m "feat: enable the omnishell navi, tealdeer, you-should-use and dynamic-completion modules"
```

### Task 2: Raise the omnishell floor to 0.10.0

**Files:**
- Modify: `bootstrap.sh:206-225` (comment block and `OMNISHELL_MIN_VERSION`)
- Modify: `tests/test-interactive.sh:46`, `tests/test-interactive.sh:140`
- Modify: `tests/test-omnishell-toolchain.sh:21-22`, `:67-70`, `:80`, `:89`

**Interfaces:**
- Consumes: Task 1's config (modules that need 0.10.0).
- Produces: `OMNISHELL_MIN_VERSION="0.10.0"`; README floor wording is Task 3.

- [ ] **Step 1: Update the tests first.** In `test-omnishell-toolchain.sh` the stub "new omnishell" becomes 0.10.0 (`NEW_OMNISHELL`, its `echo`), the "current version" case uses a 0.10.0 stub and message `already installed (0.10.0`, the "too old" case uses `0.9.0` (the release just below the floor) and expects `below the minimum 0.10.0`, the "stuck" case expects `0.10.0` in the output. In `test-interactive.sh` the floor check expects `0.10.0` and the README check expects `omnishell 0.10.0 or newer`.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test-omnishell-toolchain.sh; bash tests/test-interactive.sh`
Expected: the floor / upgrade checks FAIL, others pass.

- [ ] **Step 3: Set `OMNISHELL_MIN_VERSION="0.10.0"` in `bootstrap.sh`** and extend the comment above it by one clause: 0.10.0 adds the `navi`, `tealdeer`, `you-should-use` and `dynamic-completion` modules the default config enables.

- [ ] **Step 4: Run to verify the toolchain test passes**

Run: `bash tests/test-omnishell-toolchain.sh`
Expected: no `FAIL`. (`test-interactive.sh` still fails its README check until Task 3.)

- [ ] **Step 5: Commit**

```bash
git add bootstrap.sh tests/test-omnishell-toolchain.sh tests/test-interactive.sh
git commit -m "chore: require omnishell 0.10.0 for the new default modules"
```

### Task 3: Document the modules and the new floor

**Files:**
- Modify: `README.md` (layer table line 25, floor paragraph lines 31-41, bootstrap step 2 line 82 and step 6 line 86, "Modules" table around line 383)

**Interfaces:**
- Consumes: Task 1 (modules) and Task 2 (floor).
- Produces: README text matching both.

- [ ] **Step 1: The failing test already exists** (`the README names the 0.10.0 floor` in `tests/test-interactive.sh`, Task 2). Run it to confirm it fails.

Run: `bash tests/test-interactive.sh`
Expected: only the README floor check FAILs.

- [ ] **Step 2: Edit `README.md`:**
  - Layer table: add `navi`, `tealdeer`, `you-should-use` and `dynamic-completion` to the omnishell rc-lines list.
  - Floor paragraph: "omnishell 0.10.0 or newer is required" and add that before 0.10.0 there are no `navi`, `tealdeer`, `you-should-use` and `dynamic-completion` modules.
  - Step 2: "upgrading it below 0.10.0". Step 6: list the new modules among those omnishell installs where relevant (`navi`, `tealdeer`, `you-should-use`).
  - Modules table: add rows for the four modules (what it does; options: `navi` Ctrl+G, `you-should-use` zsh only, `dynamic-completion` bash only with `commands`). Add a one-line note under the table that `ble-sh` is not enabled because it conflicts with `fzf`, which `navi` needs.

- [ ] **Step 3: Run the full suite and lint**

Run: `make lint && make test`
Expected: lint clean, every test file ends without `FAIL`.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document the new omnishell default modules and the 0.10.0 floor"
```
