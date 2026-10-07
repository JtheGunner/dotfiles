# Interactive install mode (DOTFI-7)

## Goal

`./bootstrap.sh --interactive` walks through the install and fills the one settings
file `~/.config/dotfiles/config.toml` (DOTFI-10, DOTFI-12): first the dotfiles-owned
tables (`[bootstrap]`, `[ghostty]`, `[tmux]`, `[git]`), then the module selection in
`omnishell tui`, then the normal install. Everything is pre-filled with what the file
says today (or the machine's current state), so pressing Enter all the way through
gives the same result as a run without `--interactive`.

## Non-goals

- No change to the TUI itself (omnishell v0.7.0 ships it as is).
- No write-back into the repo: `omnishell/config.toml` stays the tracked default.
- No new dependency (no `gum`); prompts are plain bash `read`.
- No change to precedence (flag > environment > settings file > default).

## What `omnishell tui` does (v0.7.0)

- No flags. It edits the omnishell `config.toml` under `XDG_CONFIG_HOME`
  (default `~/.config/omnishell/config.toml`), and Space / `o` write it at once.
- `a` previews the plan; confirming closes the UI and runs `omnishell apply`, which
  asks again. `q` quits without applying.
- Needs a terminal on stdin and stdout, otherwise exit 2. A missing or malformed
  config stops it before the screen is taken over.
- It cannot be told to skip its own `apply`, and it has no separate config path.

## Flow

1. **Preconditions** (before anything is written):
   - `--interactive` with `--yes` / `-y` is an error (exit 2): the two contradict each
     other. `[bootstrap] assume_yes` or `DOTFILES_ASSUME_YES` in the environment does
     not conflict; the prompts below still run, only the existing y/N questions are
     answered by it.
   - No terminal on stdin or stdout: exit 2 with
     `--interactive needs a terminal; run without it, or edit <config> by hand`.
   - `OMNISHELL_MIN_VERSION` rises to `0.7.0` for every run (the module list is the same
     for `--interactive` and not). An older omnishell is upgraded by `install_omnishell`
     as today; if it stays older, `--interactive` stops with a message naming the
     version it needs.
2. **dotfiles-owned prompts** (new `interactive_collect`, right after
   `seed_bootstrap_config`, before `install_deps`, because `install_zsh` and `terminals`
   change what the next steps do): for every key of the `bootstrap`,
   `ghostty`, `tmux` and `git` tables in `SETTINGS_SCHEMA`, in schema order:
   - the prompt shows table.key, the type or the allowed values, and the current
     value in brackets: the settings file value, else the environment/flag value that
     applies, else the effective default (`install_zsh` shows `no`, an unset `git`
     key shows `unset`).
   - Enter keeps the current value. A value is validated with `_settings_value_ok`
     (the same rule as when the file is read) and asked again on error. A single `-`
     clears the key (removes it from the file).
   - The result is a list of `table.key<US>kind<US>value` changes against the file.
3. **Write the file** (`settings_update_file`): the changes are applied to the file
   text, not to a parsed copy:
   - an existing active `key = value` line is replaced in place, keeping its comment;
   - a new key goes right below its `[table]` header, which is appended when the table
     does not exist;
   - a cleared key loses its active line, commented template lines stay;
   - everything else, comments and tables the schema does not know included, is kept.
   Before writing, a unified diff is shown and `Write these changes to <file>? [y/N]`
   asked. `n` leaves the file untouched and the run stops there (exit 0, nothing
   installed). With no changes there is no diff and no question. The previous file is
   saved as `<file>.bak` (overwritten each time).
4. **Live omnishell config for the TUI**: `_validate_omnishell_config` and
   `_write_omnishell_config` run as in `apply_omnishell` (validation in a scratch dir
   first), so `~/.config/omnishell/config.toml` is default + the file's tables. The
   state of that file is remembered.
5. **`omnishell tui`** runs on it. A non-zero exit (the TUI itself failed) stops with
   a warning; the settings file is not touched by this step. Quitting with `q` is exit
   0 and counts as a normal end.
6. **Take over the module selection** (`settings_update_omnishell`): the live config
   after the TUI and the tracked default are both read with `settings_parse`. For every
   `omnishell` and `modules.*` table:
   - same records as the default: the override is dropped from the settings file;
   - different from the default: the whole table is written to the file, replacing an
     existing override table of that name (tables replace the default as a whole, as in
     `settings_merge_omnishell`);
   - a table the TUI removed from the live config: the override stays as it is.
   The same diff and `[y/N]` question as in step 3 applies. Answering `n` leaves the
   file as it was and the run stops (exit 0).
7. **The rest of the install** runs as today. `apply_omnishell` writes the merged
   config again (now from the updated file) and applies once. If the user already
   pressed `a` in the TUI, that apply made the shells current and the second one finds
   nothing to do; the run is idempotent.

`main()` order with `--interactive`: `check_checkout_consistency`, `seed_bootstrap_config`,
**`interactive_collect` + `settings_update_file` (steps 2 and 3, then `settings_load` again
so the new values apply)**, `install_deps`, `ensure_zsh`, `install_ghostty`,
`install_omnishell`, **live config + `omnishell tui` + `settings_update_omnishell`
(steps 4 to 6)**, `write_rc_base`, `stow_packages`, the render steps, `apply_omnishell`,
`wire_shell_d`, finish. The answers are written before anything is installed, so they
survive a failed install; a later run starts from them.

## Error handling

- An invalid answer is asked again; the run never writes an invalid value.
- A file that cannot be written (read-only, unwritable directory) stops with a message
  naming the file; nothing is installed yet at that point.
- A malformed existing file keeps working as today (bad lines are ignored with a warning);
  `settings_update_file` copies those lines through unchanged.
- Ctrl-C or end of input at a prompt aborts with exit 130 / 1 before anything is
  written or installed.
- A failed `omnishell validate` of the merged config stops, as in `apply_omnishell`.

## Testing

- `tests/test-settings.sh`: `settings_update_file` (replace in place, keep comment, new
  key under header, new table, clear, unknown tables and comments kept, `.bak` made,
  idempotent when nothing changes) and `settings_update_omnishell` (table equal to the
  default drops the override, changed table replaces, new table appended).
- `tests/test-interactive.sh`: `omnishell` is a stub that edits the live config, `/dev/tty`
  checks go through a seam so tests can run without a terminal. Cases: Enter through
  everything leaves the file byte-identical; invalid answer asked again; `-` clears;
  `--interactive --yes` is an error; no terminal is an error; omnishell too old; `n` to
  the diff leaves file and system untouched; a TUI that enables a module writes the
  table; a TUI that reverts a table drops the override; `apply` runs once.
- Template and README sync tests keep passing; `--help` lists `--interactive`.
- Manual (not automatable): one real run on the macOS and the Linux machine.

## Risks

- The seam for "is a terminal" must not hide a real bug: the real check (`[ -t 0 ] && [ -t 1 ]`)
  is a single line and tested for both outcomes.
- Records from the live config go through `settings_parse`, which only knows the restricted
  TOML subset. A module option written by the TUI in a form outside that subset is
  reported with a warning and the table is left out of the update (the live config stays
  as the TUI wrote it for this run, the file does not change).
- Pressing `a` in the TUI applies the live config, which is the merged one; if the user
  then answers `n` in step 6, the machine is ahead of the file until the next run. The
  diff question says so.
