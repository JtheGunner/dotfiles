# tmux and git values in the settings file (DOTFI-12)

## Goal

`~/.config/dotfiles/config.toml` (DOTFI-10) also sets tmux and git values. The
tracked files (`tmux/.tmux.conf`, `git/.config/git/config`) stay the defaults; the
settings file holds per-machine decisions, as it already does for Ghostty.

## Non-goals

- No tmux colours or theme (they come from the Root Loops palette), no git aliases.
- No change to precedence (flag > environment > settings file > default) and no new
  flags or environment variables.
- No change to the interactive git identity and signing prompts; they stay the
  fallback when the settings leave the keys unset.

## Keys

| Table | Key | Type | Becomes |
|---|---|---|---|
| `[tmux]` | `prefix` | tmux key (`C-a`, `M-x`, `C-Space`, `F1`..`F12`) | `unbind C-a`, `set -g prefix X`, `bind X send-prefix` |
| | `mouse` | bool | `set -g mouse on\|off` |
| | `mode_keys` | `vi` \| `emacs` | `set-window-option -g mode-keys X` |
| | `base_index` | integer >= 0 | `set -g base-index N` |
| | `escape_time` | integer >= 0 (ms) | `set -sg escape-time N` |
| | `history_limit` | integer > 0 | `set -g history-limit N` |
| | `status_position` | `top` \| `bottom` | `set -g status-position X` |
| `[git]` | `user_name` | string | `user.name` |
| | `user_email` | string containing `@` and no spaces | `user.email` |
| | `signing_key` | path to a public key (`*.pub`) | `user.signingkey`, `gpg.format ssh`, `commit.gpgsign`, `tag.gpgsign` |
| | `default_branch` | string | `init.defaultBranch` |
| | `editor` | string | `core.editor` |
| | `pull_rebase` | bool | `pull.rebase` |

Every key is optional; an unset key renders nothing, so the tracked default applies.
`lib/settings.sh` gets the two tables, the schema rows and the new value types
(integer >= 0, integer > 0, tmux key, e-mail shape); `config.toml.example` and the
README table list every key (the existing sync test enforces the template).

## Mechanism: generated includes

| | Generated file | Included by | Order, last wins |
|---|---|---|---|
| tmux | `~/.config/tmux-settings.conf` | `source-file -q` at the end of `.tmux.conf` | tracked default, settings, hand-written `~/.tmux.conf.local` (new, optional) |
| git | `~/.gitconfig.settings` | a new `[include]` in the tracked git config | tracked default, `~/.gitconfig.delta`, settings, `~/.gitconfig.local` |

Both files start with a `GENERATED` marker line and live outside the stowed
directories, so nothing lands in the repo. A file without the marker is never
touched (warning); with no keys set a generated file is removed.

- **tmux:** `settings_render_tmux` prints the tmux commands from the table above.
  The bootstrap writes them to the generated file. `prefix r` (reload) sources
  `~/.tmux.conf`, which sources the includes, so reloading picks them up.
- **git:** `settings_render_git` prints one `git-key<US>value` record per setting;
  the bootstrap writes the file with `git config --file`, which handles quoting.
  `signing_key` must be an existing `*.pub` file (same check as
  `write_git_signing_config`), otherwise it is skipped with a warning.
- `main()` renders both right after the Ghostty settings and before
  `setup_git_delta` / `setup_git_identity` / `setup_git_signing_key`, so a set
  `user_email` or `signing_key` makes those prompts skip themselves (they check
  `git config --get`).

## Error handling

Invalid values, unknown keys and unknown tables behave as in DOTFI-10: one `warn`,
ignored. A render problem (unwritable target, missing public key) is a warning,
never fatal.

## Testing

- `tests/test-settings.sh`: schema rows and the new value types (accepted and
  rejected values), `settings_render_tmux` and `settings_render_git` output.
- `tests/test-bootstrap-settings.sh`: generated files are written, idempotent on a
  second run, removed when the keys are cleared, a hand-written file is left alone,
  git identity prompts are skipped when the settings supply the identity.
- tmux syntax of the generated file is checked with a real `tmux` when one is
  installed (skipped otherwise); the tracked `.tmux.conf` include lines are checked
  by grep.

## Risks

- `source-file -q` needs tmux >= 2.x (any current distro); older tmux errors on
  the unknown flag.
- A prefix change leaves the tracked `bind r` etc. untouched; only the prefix and
  its `send-prefix` binding are rewritten.
