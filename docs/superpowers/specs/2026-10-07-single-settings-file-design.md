# Single settings file (DOTFI-10)

## Goal

One untracked, per-machine file lists and sets every per-machine choice for the
bootstrap, omnishell and Ghostty. Today these live in `bootstrap.conf`
(`KEY=value`), `omnishell/config.toml` (overwritten on every bootstrap run, so
local edits are lost) and the Ghostty per-machine include.

Native tool files that hold *defaults* (tmux, bat, git, the Ghostty main config)
stay tracked and hand-editable. The settings file holds decisions, not defaults.

## Non-goals

- No generator for tmux, bat or git; they are not per-machine decisions.
- No full TOML support, only the subset below.
- No change to precedence: flag > environment > settings file > default.
- No change to the existing environment variables and flags; they keep working.

## File

`~/.config/dotfiles/config.toml` (override with `DOTFILES_CONFIG`). `bootstrap.sh`
seeds it from `config.toml.example` on the first run, with every option present
and commented out, and never overwrites it.

```toml
[bootstrap]
install_zsh = "ask"        # yes | no | ask
assume_yes  = false
terminals   = []           # extra terminal stow packages

[ghostty]
keybinds           = "auto"   # auto | mac | linux
font_family        = "Cascadia Mono NF"
font_size          = 12
background_opacity = 0.98

[omnishell]                # omnishell's own config, passed through
version = 1
shells  = ["zsh", "bash"]

[modules.history.options]
size = 50000
```

## Format: restricted TOML subset

Accepted: `# comments`, `[table]` and `[a.b]` headers, `key = value` with a string
(`"..."`, escapes `\"` and `\\` only), integer, float, boolean, or a one-line array
of those. Rejected with a warning and ignored: multi-line values, inline tables,
dotted keys, unknown tables outside `bootstrap`, `ghostty`, `omnishell`,
`modules.*`, unknown keys, invalid values. Python's `tomllib` is not an option
(absent before 3.11; Ubuntu 22.04 ships 3.10), so parsing is Bash plus awk.

## Components

| Unit | Responsibility | Depends on |
|---|---|---|
| `lib/settings.sh` | parse the file into `table.key=value` records; typed getters with validation (`settings_get`, `settings_get_bool`, `settings_get_list`); omnishell table merge | bash, awk |
| `config.toml.example` | documents every option with values, default, flag and env variable | - |
| `bootstrap.sh` | sources `lib/settings.sh`, resolves each setting with the existing precedence, seeds the file, migrates the old file, renders omnishell and Ghostty output | `lib/settings.sh` |

`lib/settings.sh` is sourced by `bootstrap.sh` and unit-tested on its own, without
running the bootstrap.

## omnishell merge

Effective omnishell config = the tracked default `omnishell/config.toml` with
table-level overrides from the settings file. A table is the unit: for every
`[omnishell]`, `[modules.X]` or `[modules.X.options]` table present in the settings
file, that whole table replaces the default table of the same name; tables the
default lacks are appended; all other default tables, with their comments, stay as
they are. The result is written to `~/.config/omnishell/config.toml` (as today, both
before and after `omnishell init`) and checked with `omnishell validate`; exit 2
aborts with the validator's output.

## Ghostty rendering

Set values in `[ghostty]` are rendered to `~/.config/ghostty-settings.conf` (outside
the stowed directory, like the keybinds link), one `key = value` line per set
option. The main Ghostty config includes it before `~/.config/ghostty.local`, so
defaults < settings file < hand-written overrides. Unset keys render nothing, so the
tracked defaults apply. `keybinds` replaces `DOTFILES_GHOSTTY_KEYBINDS` as the
setting behind `setup_ghostty_keybinds` (the variable keeps working, with higher
precedence).

## Migration

If `~/.config/dotfiles/bootstrap.conf` exists and `config.toml` does not, the
known keys are converted into a seeded `config.toml` once (`INSTALL_ZSH` to
`install_zsh`, `ASSUME_YES=yes` to `assume_yes = true`, `TERMINALS` to the list),
and the old file is renamed to `bootstrap.conf.migrated`. `bootstrap.conf.example`
is removed.

## Error handling

A missing file is not an error. Every invalid line, key or value produces one
`warn` that names the file, the line and the reason, and is ignored. A failing
`omnishell validate` is the only fatal case. Nothing in the file is ever executed.

## Testing

- `tests/test-settings.sh`: parser (every accepted and rejected form, quoting,
  arrays, comments), getters, precedence, the omnishell table merge (replace,
  append, comments preserved, no change without overrides), Ghostty rendering,
  seeding without overwrite, migration.
- The existing `tests/test-zsh-install.sh` is updated to the TOML keys; its
  precedence cases stay.
- A test keeps `config.toml.example` in sync with the keys the code reads.

## Dependencies and risks

- Needs DOTFI-8 (merged) and the `[ghostty] keybinds` hook from DOTFI-9 (PR #19).
  Until #19 is merged this branch implements bootstrap and omnishell, and adds the
  `[ghostty]` table after rebasing onto it.
- Table-level replacement means overriding one omnishell option requires restating
  that option's whole table. Chosen over key-level merging to keep the awk simple
  and the result predictable.
- `omnishell set` edits to `~/.config/omnishell/config.toml` are overwritten on the
  next bootstrap run, as they are today; the settings file is the place to change
  them, and the README says so.
