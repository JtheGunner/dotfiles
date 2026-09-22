dotfiles
========

Personal terminal setup for **Debian** and **macOS**, split across five layers:

| Layer                                                    | Owns                                                                                                                                                                                                                   | Mechanism                                                                                                  |
|----------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------|
| **[omnishell](https://github.com/JtheGunner/omnishell)** | rc *lines* - plugin inits, history, completion, `fzf`, `zoxide`, `modern-aliases`, `mise`, `starship` (prompt + its seeded config), `root-loops` (OSC palette push), `tmux` (installs it; optional auto-attach on shell start, off here) | one marker block in `~/.zshrc` / `~/.bashrc`, sourcing a generated `init.<shell>`                          |
| **this repo (stow packages)**                            | standalone config *files* - `git`, `tmux` (`.tmux.conf` only), `bat`, `ghostty` (+ optional `nvim`)                                                                                                                    | [GNU Stow](https://www.gnu.org/software/stow/) symlinks into `$HOME`                                       |
| **this repo (rc libraries)**                             | the base `~/.zshrc` / `~/.bashrc` content - env, keybindings, zsh completion styling                                                                                                                                   | `zsh/zshrc.zsh` + `bash/bashrc.bash`, **`source`d** from a generated real rc file (not stowed - see below) |
| **this repo (`shell.d/`)**                               | personal rc lines not worth a public module - k8s/docker aliases, `linuxbrew`, helper functions, and tools still awaiting an omnishell module (`direnv`)                                                               | a second marker block, sourced *after* omnishell                                                           |
| **`~/.zshrc.local` / `~/.bashrc.local`**                 | machine-specific and secret - per-host `PATH`, tool completions, tokens. **Not version-controlled.**                                                                                                                   | sourced last by the same marker block                                                                      |

omnishell is consumed as a released binary (Homebrew tap / curl installer); this
repo never modifies it.

### Why the rc files aren't stowed

`~/.zshrc` and `~/.bashrc` are **generated real files**, each just:

```sh
# >>> dotfiles:base >>>
export DOTFILES="$HOME/.dotfiles"
[ -r "$DOTFILES/zsh/zshrc.zsh" ] && . "$DOTFILES/zsh/zshrc.zsh"
# <<< dotfiles:base <<<
```

omnishell and the `shell.d` block then *append* their marker blocks to those
files. If the rc file were a stow symlink into the repo, those appends would be
written straight back into version control - so bootstrap writes a real file that
`source`s the repo's rc library instead.

Install
-------

```sh
git clone https://github.com/JtheGunner/dotfiles ~/.dotfiles
~/.dotfiles/bootstrap.sh
exec $SHELL
```

`bootstrap.sh` installs dependencies + omnishell + ghostty, writes real
`~/.zshrc` / `~/.bashrc`, stows the packages, applies `omnishell/config.toml`
(which also installs `starship` / `mise` / `tmux` and activates the `root-loops`
palette push), appends the `shell.d` block to both rc files, and renders the
emulator color themes. It never runs
`chsh`. Re-running it is safe. An existing handwritten `~/.zshrc` is moved to
`~/.zshrc.pre-dotfiles` first.

### Manual / partial

```sh
cd ~/.dotfiles
stow git tmux bat # only the packages you want
```

Configuring
-----------

Every knob lives in **one** of five places. None of this needs `bootstrap.sh`
re-run (though re-running it is always safe) - the apply step is per row.

| I want to change...                                                               | Edit                                                                     | Apply with                                   |
|-----------------------------------------------------------------------------------|--------------------------------------------------------------------------|----------------------------------------------|
| base shell behaviour (env, keybindings, completion styling)                       | `zsh/zshrc.zsh`, `bash/bashrc.bash`, or the `*-mac` / `*-linux` siblings | `exec $SHELL`                                |
| a personal rc line (aliases, functions, tool hooks)                               | a file in `shell.d/`                                                     | `exec $SHELL`                                |
| a plugin / prompt / tool-activation line (fzf, zoxide, mise, starship, tmux, ...) | `omnishell/config.toml`                                                  | `omnishell apply`                            |
| a standalone program's config file (git, tmux, bat, ghostty, nvim)                | the matching stow package                                                | live immediately (symlinked); reload the app |
| terminal colours                                                                  | `rootloops/` - see [below](#colors-root-loops)                           | `make colors`                                |
| anything host-specific or secret                                                  | `~/.zshrc.local` / `~/.bashrc.local` (**not** in the repo)               | `exec $SHELL`                                |

### 1. Base rc libraries - `zsh/`, `bash/`

`zsh/zshrc.zsh` and `bash/bashrc.bash` are the pristine `~/.zshrc` / `~/.bashrc`
content, `source`d (not stowed) from the generated real rc file. Base config goes
here: `$EDITOR`, `$LANG`, `bindkey`, zsh `zstyle` completion rules, `shopt`.

OS-specific bits go in the siblings, sourced at the end of each library:
`zsh/zshrc-mac.zsh` + `zsh/zshrc-linux.zsh`, `bash/bashrc-mac.bash` +
`bash/bashrc-linux.bash` (today: Homebrew `shellenv` on macOS, `open` ->
`xdg-open` on Linux).

Load order per shell: base library -> OS sibling -> omnishell block -> `shell.d`
block -> `~/.<shell>rc.local`.

### 2. Personal rc fragments - `shell.d/*.sh`

POSIX-`sh` snippets, sourced in filename order **after** omnishell, by both
shells. Add one with a numeric prefix for ordering and keep it `sh`-compatible
(`make check` lints this).

| File                | Purpose                                                        |
|---------------------|----------------------------------------------------------------|
| `00-path.sh`        | prepend `~/.local/bin`, `~/bin` to `PATH`                      |
| `10-infra.sh`       | kubectl / flux / terraform aliases + completion, `$KUBECONFIG` |
| `20-docker.sh`      | docker `dk*` aliases (only if `docker` present)                |
| `30-linuxbrew.sh`   | linuxbrew `shellenv` (Linux only)                              |
| `40-aliases.sh`     | `ll`, `..` / `...`, `serve`                                    |
| `41-functions.sh`   | `whatsonport`, `jwtdecode`, `img2pdf`                          |
| `50-less-colors.sh` | coloured man pages (-> future omnishell `colorized-man`)       |
| `60-tools.sh`       | `direnv` + `yazi` hooks (-> future omnishell modules)          |
| `70-fzf-colors.sh`  | **generated** by `rootloops/apply.sh` - don't hand-edit        |

`50-`, `60-` and `70-` are placeholders: when the matching omnishell module is
adopted, delete the fragment and enable the module in `omnishell/config.toml`
(as was done for `mise`, `starship`, `root-loops`, `tmux`).

### 3. omnishell - `omnishell/config.toml`

Version-controlled here, copied to `~/.config/omnishell/config.toml` by
`bootstrap.sh`. It owns rc *lines* - plugin inits, history/completion options,
tool activation. After editing:

```sh
omnishell apply      # rewrites the generated init.<shell>; -y skips the prompt
omnishell doctor     # check for drift / degraded modules
```

| Module                                                            | What it does                                                                | Notable options                              |
|-------------------------------------------------------------------|-----------------------------------------------------------------------------|----------------------------------------------|
| `completion`, `history`, `autosuggestions`, `syntax-highlighting` | zsh/bash plugin baseline                                                    | `history.size = 50000`                       |
| `fzf`                                                             | key bindings + defaults                                                     | `ctrl_r`, `ctrl_t`, `default_opts`           |
| `zoxide`                                                          | smarter `cd`                                                                | `cmd = "z"`                                  |
| `modern-aliases`                                                  | `ls` / `cat` / `find` -> `eza` / `bat` / `fd`                               | `replace = [...]`                            |
| `mise`                                                            | runtime version manager, `mise activate` per prompt                         | -                                            |
| `starship`                                                        | prompt; seeds `~/.config/omnishell/starship.toml` once, never overwrites it | edit that file for prompt styling            |
| `root-loops`                                                      | OSC 4/10/11 palette push on shell start                                     | `appearance = "dark"`                        |
| `tmux`                                                            | installs tmux; optional auto-attach to a session on shell start             | `session = "default"`, `auto_attach = false` |

`starship`, `mise` and `tmux` are **installed** by `omnishell apply`, not by
`bootstrap.sh`. Prompt styling is `~/.config/omnishell/starship.toml` (seeded
once, then yours - not tracked here); the `~/.tmux.conf` *file* is the `tmux/`
stow package below. `tmux`'s `auto_attach` (added in omnishell 0.3.1) is
`false` here - tmux is installed and configured, but shells start outside it;
flip it to `true` to attach/create the `default` session on every shell start.

### 4. Stow packages - standalone config files

`stow` symlinks these into `$HOME`, so **editing the file in the repo changes the
live config immediately** (you may still need to reload the target app). After
adding or removing files in a package, run `make restow`.

| Package    | Symlinks to                            | Contains                                                                                                                                                                                                    |
|------------|----------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `git/`     | `~/.config/git/{config,ignore}`        | identity, aliases (`st`, `co`, `lg`, `coi` = fzf branch switch), `main` default branch, global ignore. `delta` paging is `~/.gitconfig.local`, written by `bootstrap.sh` **only when `delta` is installed** |
| `tmux/`    | `~/.tmux.conf`                         | prefix `C-a`, 1-based index, `\|` / `-` splits, mouse on, vi mode, Root-Loops-flavoured status bar (`prefix r` reloads)                                                                                     |
| `bat/`     | `~/.config/bat/config`                 | `--theme="ansi"` so `bat` / `delta` / fzf previews inherit the terminal palette                                                                                                                             |
| `ghostty/` | `~/.config/ghostty/config` + `themes/` | primary terminal; `theme = light:rootloops-light,dark:rootloops-dark` follows the OS                                                                                                                        |
| `nvim/`    | `~/.config/nvim/`                      | opt-in - only stowed if the directory exists                                                                                                                                                                |

Stow a subset with `cd ~/.dotfiles && stow git tmux`; add an extra terminal
package via `DOTFILES_TERMINALS="alacritty kitty" ./bootstrap.sh`.

### 5. Machine-specific & secrets - `~/.zshrc.local` / `~/.bashrc.local`

Sourced last by the `shell.d` marker block, **never version-controlled**.
Per-host `PATH`, private tokens, work-only completions, one-off overrides. Create
it by hand - nothing generates it.

Colors: Root Loops
------------------

Terminal colors are defined **once** and everything else inherits the 16 ANSI
colors. See [`rootloops/`](rootloops/):

- [`rootloops/RECIPE`](rootloops/RECIPE) - the canonical [rootloops.sh](https://rootloops.sh) recipe
- [`rootloops/palette.env`](rootloops/palette.env) - the 16 colors + fg/bg, **the dark source of truth**
- [`rootloops/palette-light.env`](rootloops/palette-light.env) - a light companion,
  derived from `palette.env` by `rootloops/derive-light.py` (rootloops.sh only
  makes dark schemes). Hand-tweak it freely; `apply.sh` won't overwrite it.

`rootloops/apply.sh` renders the **emulator** config that can't just inherit the
16 ANSI colors. The **OSC 4/10/11 palette push** to the running terminal is
omnishell's `root-loops` module now (`appearance = "dark"` in
`omnishell/config.toml`), not a generated `shell.d` fragment.

| Target                          | File                                                    | Notes                                                                                                                                                                                                                                                                                                    |
|---------------------------------|---------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Ghostty**                     | `ghostty/.config/ghostty/themes/rootloops-{dark,light}` | The config sets `theme = light:rootloops-light,dark:rootloops-dark`, so Ghostty follows the OS appearance. Ghostty is the primary terminal (installed by `bootstrap.sh`).                                                                                                                                |
| Any OSC-capable terminal        | omnishell `root-loops` module                           | Pushes the **dark** palette to the running terminal via OSC 4/10/11 (tmux-aware) on shell start. No emulator config needed. VTE/GNOME Terminal, kitty, alacritty, wezterm, foot, konsole, xterm, iTerm2, Linux console. The palette is baked into the module - keep it in sync with `palette.env` there. |
| GNOME Terminal (persistent)     | generated by `rootloops/gen-vte-terminal.sh`            | Writes the dark palette into the default GNOME Terminal profile via `gsettings`. Best-effort. Run automatically by `apply.sh` on Linux.                                                                                                                                                                  |
| macOS Terminal.app *(fallback)* | `rootloops/RootLoops.terminal`                          | Importable dark profile (`rootloops/gen-terminal-app.py`); `bootstrap.sh` imports it and sets it default.                                                                                                                                                                                                |
| `fzf` UI chrome                 | `shell.d/70-fzf-colors.sh`                              | dark; doesn't inherit ANSI cleanly                                                                                                                                                                                                                                                                       |
| neovim                          | (later)                                                 | once the `nvim` package exists                                                                                                                                                                                                                                                                           |

Only Ghostty gets the light/dark pair; everything else uses the dark palette
(they can't auto-switch anyway). `bat`, `tmux`, `git`/`delta` and `starship`
inherit ANSI, so they need no generated file.

**Change the theme:** edit `rootloops/RECIPE` + `rootloops/palette.env` (and
`palette-light.env` for light), run `rootloops/apply.sh` (or `make colors`),
commit. On macOS re-import `RootLoops.terminal`; on GNOME re-run `apply.sh`.

Layout
------

```
bootstrap.sh              one-shot installer
Makefile                  stow / colors / check wrappers
omnishell/config.toml     version-controlled omnishell config (incl. mise, starship, root-loops, tmux)
zsh/zshrc.zsh             rc library sourced by the generated ~/.zshrc (not stowed)
bash/bashrc.bash          rc library sourced by the generated ~/.bashrc (not stowed)
zsh/.zprofile             stowed
shell.d/*.sh              personal rc fragments (sourced after omnishell)
rootloops/                color single-source (palette.env) + emulator-theme generators
git/ tmux/ bat/ ghostty/  stow packages ->  ~/  and  ~/.config/
nvim/                     optional stow package (opt-in)
```

Notes
-----

- `git` config lives at `~/.config/git/config` (not `~/.gitconfig`). The `delta`
  paging config is split into `~/.gitconfig.local`, which `bootstrap.sh` writes
  only when `delta` is installed - on Debian stable `git-delta` (and `eza`, used
  by omnishell's `modern-aliases`) live in `bookworm-backports`, so without them
  those pieces degrade gracefully instead of breaking `git`.
- The `shell.d/` placeholder fragments (`50-less-colors.sh`, the `direnv` / `yazi`
  hooks in `60-tools.sh`) each map to an omnishell module not yet adopted here -
  see [Configuring §2](#2-personal-rc-fragments---shelldsh).
