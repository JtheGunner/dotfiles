# Offer zsh as the default login shell (DOTFI-17)

## Intent

The omnishell modules `autosuggestions` and `syntax-highlighting` (grey inline
suggestions, command colouring) only work in zsh. `bootstrap.sh` can install zsh
but never changes the login shell, so on most Linux machines bash stays active
and those modules have no effect. The bootstrap should offer to make zsh the
login shell when zsh is available.

## Goals

- When zsh is installed and is not the user's login shell, `bootstrap.sh` asks
  whether to make it the login shell and runs `chsh` on a yes.
- The behaviour is configurable the same way as `install_zsh`: flag >
  environment > settings file > default.
- Every failure path degrades to a warning that names the manual command.

## Non-goals

- Editing `/etc/shells` (no `sudo` writes to system files).
- Any special handling of macOS beyond what the login-shell check already gives.
- Changing the login shell of other users, or running `chsh` under `--yes`.

## Anti-goals

- A bootstrap run that aborts because `chsh` failed or no terminal was present.
- A silent login-shell change nobody asked for.

## Constraints

- Settings keys are declared in `SETTINGS_SCHEMA` (`lib/settings.sh`); the
  interactive mode and the settings writers are driven by it.
- `--yes` / `assume_yes` already never install zsh; the same rule applies here.
- `chsh` needs a terminal and a password on most Linux systems and takes effect
  at the next login.

## Approaches considered

1. **Dedicated step with its own setting (chosen).** A new `ensure_default_shell`
   after `ensure_zsh`, with `bootstrap.set_default_shell` (`ask|yes|no`), mirroring
   `install_zsh`. Reuses a proven pattern; the prompt also covers machines where
   zsh was installed long before.
2. **Extend `ensure_zsh`.** Rejected: it returns early when zsh exists, so the
   already-installed case would need a restructure, and installing a package and
   changing the login shell are separate decisions.
3. **Document `chsh` in the README only.** Rejected: it does not remove the
   friction that motivated the ticket.

## Design

- Setting `bootstrap.set_default_shell`, enum `ask|yes|no`, default `ask`; flags
  `--set-default-shell` / `--no-set-default-shell`; environment
  `DOTFILES_SET_DEFAULT_SHELL`. An invalid environment value warns and falls
  back, as for `DOTFILES_INSTALL_ZSH`.
- `ensure_default_shell` runs after `ensure_zsh` in `main()`:
  1. No zsh on `PATH` → return silently (`ensure_zsh` already hinted).
  2. Resolve the current login shell (`getent passwd "$USER"` on Linux,
     `dscl . -read ~ UserShell` on macOS). Already zsh → return, no prompt. This
     is what makes macOS a no-op.
  3. Mode `no` → return. Mode `ask` → no prompt under `--yes` / `assume_yes`
     (return); otherwise `_confirm`. Mode `yes` → proceed.
  4. If the zsh path (`command -v zsh`) is not listed in `/etc/shells`, warn with
     the exact command to add it and the `chsh` command; do not modify the file.
  5. Run `chsh -s <zsh>`. A missing terminal or a non-zero exit only warns, with
     the manual command; the run continues. On success, log that the change
     applies from the next login.
- `--interactive` prompts for the new key through the existing schema-driven
  loop; `config.toml.example`, `--help` and the script header comment document it.
- README: replace "never runs `chsh`" with the new behaviour and correct the
  `completion, history, autosuggestions, syntax-highlighting` row, which names the
  last two as zsh/bash although they are zsh-only.

## Tests

Extend the existing suites with the same style: precedence (flag > env > file >
default, invalid env value) in `tests/test-bootstrap-settings.sh`; schema and
interactive prompt in `tests/test-settings.sh` / `tests/test-interactive.sh`; the
behaviour of `ensure_default_shell` (already zsh, `--yes`, `no`, not in
`/etc/shells`, no terminal, `chsh` failure, success) with stubbed `chsh`, login
shell lookup and `_confirm`.

## Left to the builder

Exact prompt and warning wording, and the name of the login-shell helper. Keep
helpers small and stubbable so tests never touch the real account.
