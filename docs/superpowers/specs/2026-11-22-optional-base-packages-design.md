# Optional base packages and stow packages (DOTFI-22)

## Intent

`bootstrap.sh` always installs a fixed set of system packages and always stows a fixed set of
config packages. Besides omnishell modules, `install_zsh`, `set_default_shell` and
`install_ghostty`, none of it can be left out through the settings file. The goal is a
switch for every part where leaving it out is meaningful, without changing today's defaults.

## Goals

- Leave out individual system packages from `install_deps` through the settings file.
- Leave out individual stow packages, together with the generated config that only they use.
- Leave out the macOS Terminal.app profile import.
- No setting means exactly today's behaviour.
- A switched-off part is neither installed nor linked, and the log says what was skipped.

## Non-goals

- No uninstall of anything that is already installed or linked.
- No change to the defaults of omnishell modules.
- No switch for `stow`, omnishell, `curl` / `ca-certificates`, or the `zsh` stow package.
- No switch for Root Loops: `rootloops/apply.sh` only generates files inside the repo and does
  not touch the machine.
- No new command line flags for the list keys.

## Approaches considered

| | Idea | Trade-off |
|---|---|---|
| A | One boolean key per part (`install_fzf`, `link_tmux`, …) | clear names, but about ten keys and as many `--interactive` prompts |
| **B** | Two list keys plus one boolean (chosen) | few keys, same shape as `terminals`; allowed names need validation |
| C | B plus switches for git config, tmux config and Root Loops | Root Loops feeds the `ghostty`, `tmux` and `bat` packages, so switching it off is error-prone |

B was chosen by the user.

## Design

New keys in the `[bootstrap]` table, resolved with the usual precedence
(environment > settings file > default; there are no flags for the list keys):

| Key | Type | Default | Environment |
|---|---|---|---|
| `skip_packages` | list | `[]` | `DOTFILES_SKIP_PACKAGES` (space separated) |
| `skip_stow` | list | `[]` | `DOTFILES_SKIP_STOW` (space separated) |
| `terminal_app_profile` | bool | `true` | `DOTFILES_TERMINAL_APP_PROFILE` (`1`/`0`, `true`/`false`, `yes`/`no`) |

`skip_packages` accepts `fzf`, `zoxide`, `ripgrep`, `fd`, `bat` and `git-delta`. `install_deps`
removes the skipped names from `DEPS` and from the apt package list (`fd` maps to `fd-find`).
Any other name, including `stow`, `curl` and `ca-certificates`, is reported with a warning and
ignored.

`skip_stow` accepts `git`, `tmux`, `bat` and `ghostty`. `build_packages` drops the skipped names
from `PACKAGES`, so they are not stowed. The matching generated config is skipped with them:

- `git` skipped: `render_git_settings`, `setup_git_delta`, `setup_git_identity` and
  `setup_git_signing_key` do not run, because they only write files that the stowed git config
  includes.
- `tmux` skipped: `render_tmux_settings` does not run.
- `ghostty` skipped: `setup_ghostty_keybinds` and `render_ghostty_settings` do not run. This is
  independent of `install_ghostty`, which only controls the installation.

Any other name, including `zsh`, is reported with a warning and ignored.

`terminal_app_profile = false` skips `setup_terminal_app`. It has no effect outside macOS.

Each skipped part logs one `skipping <name> (…)` line. If a skipped package is still needed by
an enabled omnishell module (`fzf` with the `fzf` module, `zoxide` with the `zoxide` module,
`bat` with `colorized-man` / `modern-aliases`), `bootstrap.sh` warns once and leaves the module
alone. Switching the module off stays the user's decision.

The three keys join the schema in `lib/settings.sh` (`list`, `list`, `bool`), so
`--interactive`, `config.toml.example` and the README table pick them up. Because
`--interactive` prompts follow the schema order, the keys go after `terminals` and
`install_ghostty`.

## Constraints

- Defaults must not change; the existing tests keep passing.
- Settings parsing stays the restricted TOML subset of `lib/settings.sh`; list values are
  validated in `bootstrap.sh` like `terminals`.
- The stow consistency checks (`check_checkout_consistency`, `scan_stow_links`) work on the
  resulting `PACKAGES`, so a skipped package is neither checked nor linked.

## Left to the builder

- Exact names of helper functions and log wording.
- Where the shared list validation lives (a small helper next to `build_packages`).
- Test layout, following `tests/test-bootstrap-settings.sh`, `tests/test-settings.sh` and
  `tests/test-interactive.sh` (prompt counts shift by three).
- Documentation wording in `README.md` and `config.toml.example`.
