<div style="text-align:center">

# 🐚 dotfiles

**A layered terminal setup for macOS and Debian / Ubuntu: zsh + bash, Ghostty, tmux, git, one colour palette.**

<code>git clone</code> &nbsp;→&nbsp; <code>./bootstrap.sh</code> &nbsp;→&nbsp; <code>exec $SHELL</code>

[![License: MIT](https://img.shields.io/badge/license-MIT-22c55e?style=flat-square)](LICENSE)
![Shell](https://img.shields.io/badge/shell-zsh%20·%20bash-3776ab?style=flat-square&logo=gnubash&logoColor=white)
![Platforms](https://img.shields.io/badge/platforms-macOS%20·%20Debian%20·%20Ubuntu-0ea5e9?style=flat-square&logo=apple&logoColor=white)
[![CI](https://img.shields.io/github/actions/workflow/status/JtheGunner/dotfiles/ci.yml?branch=main&style=flat-square&label=CI)](https://github.com/JtheGunner/dotfiles/actions/workflows/ci.yml)

</div>

---

## 🧭 Overview

The setup is split across five layers. Each layer owns one kind of thing, so
nothing is configured twice:

| Layer                                                    | Owns                                                                                                                                                                                                                                             | Mechanism                                                                                                 |
|----------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| **[omnishell](https://github.com/JtheGunner/omnishell)** | rc *lines*: plugin inits, history, completion, `fzf`, `zoxide`, `modern-aliases`, `colorized-man`, `direnv`, `broot`, `mise`, `starship` (prompt + its seeded config), `root-loops` (OSC palette push), `tmux` (installs it; auto-attach is off) | one marker block in `~/.zshrc` / `~/.bashrc`, sourcing a generated `init.<shell>`                         |
| **this repo: stow packages**                             | standalone config *files*: `git`, `tmux` (`.tmux.conf` only), `bat`, `ghostty` (+ optional `nvim`)                                                                                                                                               | [GNU Stow](https://www.gnu.org/software/stow/) symlinks into `$HOME`                                      |
| **this repo: rc libraries**                              | the base `~/.zshrc` / `~/.bashrc` content: env, keybindings, zsh completion styling                                                                                                                                                              | `zsh/zshrc.zsh` + `bash/bashrc.bash`, **`source`d** from a generated real rc file (not stowed, see below) |
| **this repo: `shell.d/`**                                | personal rc lines not worth a public module: k8s / docker aliases, `linuxbrew`, helper functions                                                                                                                                                 | a second marker block, sourced *after* omnishell                                                          |
| **`~/.zshrc.local` / `~/.bashrc.local`**                 | machine-specific and secret: per-host `PATH`, tool completions, tokens. **Not version-controlled.**                                                                                                                                              | sourced last by the same marker block                                                                     |

omnishell is consumed as a released binary (Homebrew tap / curl installer); this
repo never modifies it.

```text
 ~/.zshrc  (generated, real file)
   ├─ dotfiles:base  →  zsh/zshrc.zsh → zsh/zshrc-<os>.zsh
   ├─ omnishell      →  ~/.config/omnishell/init.zsh   (from omnishell/config.toml)
   └─ dotfiles       →  shell.d/*.sh  →  ~/.zshrc.local
```

### Why the rc files aren't stowed

`~/.zshrc` and `~/.bashrc` are **generated real files**, each starting with:

```sh
# >>> dotfiles:base >>>
export DOTFILES="$HOME/.dotfiles"
[ -r "$DOTFILES/zsh/zshrc.zsh" ] && . "$DOTFILES/zsh/zshrc.zsh"
# <<< dotfiles:base <<<
```

omnishell and the `shell.d` block then *append* their marker blocks to those
files. If the rc file were a stow symlink into the repo, this appends would be
written straight back into version control, so bootstrap writes a real file that
`source`s the repo's rc library instead.

---

## 🚀 Install

```sh
git clone https://github.com/JtheGunner/dotfiles ~/.dotfiles
~/.dotfiles/bootstrap.sh
exec $SHELL
```

`bootstrap.sh`:

1. checks that nothing points at another checkout (see [Multiple checkouts](#multiple-checkouts))
2. installs dependencies, omnishell and Ghostty
3. writes real `~/.zshrc` / `~/.bashrc`
4. stows the packages
5. writes the git `delta` config and asks for your git identity (see [Git identity](#-git-identity))
6. applies `omnishell/config.toml`, which also installs `starship`, `mise`, `tmux`, `direnv` and `broot`
7. appends the `shell.d` block to both rc files
8. renders the terminal colour themes

It never runs `chsh`, and re-running it is safe. An existing handwritten
`~/.zshrc` is moved to `~/.zshrc.pre-dotfiles` first. Pass `--yes` to answer every
prompt with "yes" (and skip the identity prompt).

> [!TIP]
> Run it from whichever checkout you want to be live: it installs from there. If
> the rc files or stow links point at a *different* checkout, it asks once before
> switching everything over.

### Multiple checkouts

Several clones on one machine are fine, e.g. a working copy to hack on and a
second one to test the install end to end. Only one of them is live. Two things
reference it:

| | Reference | Written by |
| :-: | --- | --- |
| 📄 | `export DOTFILES="…"` in the `dotfiles:base` block of `~/.zshrc` / `~/.bashrc` | step 3 |
| 🔗 | every stow symlink (`~/.tmux.conf`, `~/.config/ghostty`, …) | step 4 |

Every run checks **both** before it changes anything. Paths are compared after
resolving symlinks. If any reference points at another checkout, it lists each
one with its target (a deleted checkout is marked `(missing)`) and asks a single
question:

```text
 warn: references to another dotfiles checkout:
         ~/.zshrc (dotfiles:base)  ->  /Users/me/Projects/dotfiles
         ~/.bashrc (dotfiles:base)  ->  /Users/me/Projects/dotfiles
         ~/.tmux.conf  ->  /Users/me/old-dotfiles (missing)
 warn: this run installs from: /Users/me/Git/dotfiles
 switch everything to /Users/me/Git/dotfiles? [y/N]
```

- **yes:** only the `dotfiles:base` blocks are rewritten (a backup
  `~/.zshrc.pre-dotfiles.<timestamp>` comes first; the omnishell block, the
  `shell.d` block and your own lines stay untouched), the old stow links are
  removed and stow re-links them here.
- **no**, or no terminal to ask: it exits with status 1 and changes nothing.

To move to another checkout, run `./bootstrap.sh` from it and answer yes, or
pass `--yes` (`DOTFILES_ASSUME_YES=1`) to switch without asking.

### Manual / partial

```sh
cd ~/.dotfiles
stow git tmux bat # only the packages you want
```

---

## 🪪 Git identity

This repo ships **no** `user.name` / `user.email`. The git config sets
`user.useConfigOnly = true` instead, so git refuses to commit until you set an
identity yourself. Nobody who clones this repo commits under someone else's
name by accident.

Your identity lives in `~/.gitconfig.local`. That file is yours: it is included
last by the git config, never version-controlled and never overwritten.
`bootstrap.sh` offers to create it when no identity is set. To set it by hand:

```sh
git config --file ~/.gitconfig.local user.name  "Your Name"
git config --file ~/.gitconfig.local user.email "12345+you@users.noreply.github.com"
```

> [!IMPORTANT]
> `~/.config/git/config` is a stow symlink into this repo, so anything written
> there ends up in version control. `bootstrap.sh` creates an empty `~/.gitconfig`
> so that `git config --global …` writes there instead. Prefer
> `--file ~/.gitconfig.local` anyway.

Using your GitHub **noreply** address keeps your real email out of public
commits. Turn on *Block command line pushes that expose my email* under
GitHub → Settings → Emails to enforce that.

---

## ⚙️ Configuring

Every setting lives in **one** of five places. None of this needs `bootstrap.sh`
re-run (though re-running it is always safe); the "Apply with" column says how
to pick up a change.

|    | I want to change...                                                   | Edit                                                                     | Apply with                                   |
|:--:|-----------------------------------------------------------------------|--------------------------------------------------------------------------|----------------------------------------------|
| 🐚 | base shell behaviour (env, keybindings, completion styling)           | `zsh/zshrc.zsh`, `bash/bashrc.bash`, or the `*-mac` / `*-linux` siblings | `exec $SHELL`                                |
| 🧩 | a personal rc line (aliases, functions)                               | a file in `shell.d/`                                                     | `exec $SHELL`                                |
| 🔌 | a plugin / prompt / tool activation (fzf, direnv, broot, starship, …) | `omnishell/config.toml`                                                  | `omnishell apply`                            |
| 📄 | a standalone program's config file (git, tmux, bat, ghostty, nvim)    | the matching stow package                                                | live immediately (symlinked); reload the app |
| 🎨 | terminal colours                                                      | `rootloops/`, see [Colours](#-colours-root-loops)                        | `make colors`                                |
| 🔒 | anything host-specific or secret                                      | `~/.zshrc.local` / `~/.bashrc.local` (**not** in the repo)               | `exec $SHELL`                                |

### 1. Base rc libraries: `zsh/`, `bash/`

`zsh/zshrc.zsh` and `bash/bashrc.bash` are the pristine `~/.zshrc` / `~/.bashrc`
content, `source`d (not stowed) from the generated real rc file. Base config goes
here: `$EDITOR`, `$LANG`, `bindkey`, zsh `zstyle` completion rules, `shopt`.

OS-specific bits go in the siblings, sourced at the end of each library:
`zsh/zshrc-mac.zsh` + `zsh/zshrc-linux.zsh`, `bash/bashrc-mac.bash` +
`bash/bashrc-linux.bash` (today: Homebrew `shellenv` on macOS, `open` →
`xdg-open` on Linux).

Load order per shell: base library → OS sibling → omnishell block → `shell.d`
block → `~/.<shell>rc.local`.

### 2. Personal rc fragments: `shell.d/*.sh`

POSIX-`sh` snippets, sourced in filename order **after** omnishell, by both
shells. Add one with a numeric prefix for ordering and keep it `sh`-compatible (`make lint` checks this).

| File               | Purpose                                                                           |
|--------------------|-----------------------------------------------------------------------------------|
| `00-path.sh`       | prepend `~/.local/bin`, `~/bin` to `PATH`                                         |
| `10-infra.sh`      | `kubectl` / `flux` / `terraform` aliases + completion, `$KUBECONFIG`              |
| `20-docker.sh`     | docker `dk*` aliases, `dsd` / `dsr` Swarm stack helpers (only if `docker` exists) |
| `30-linuxbrew.sh`  | linuxbrew `shellenv` (Linux only)                                                 |
| `40-aliases.sh`    | `ll`, `..` / `...`, `week`, `serve`                                               |
| `41-functions.sh`  | `whatsonport`, `jwtdecode`, `img2pdf`                                             |
| `70-fzf-colors.sh` | **generated** by `rootloops/apply.sh`; don't hand-edit                            |

`dsd <stack> [compose-file]` deploys a Docker Swarm stack from
`$DOCKER_STACKS_DIR/<stack>/<stack>.yml` (default `/var/data/config`, the
[Geek Cookbook](https://geek-cookbook.funkypenguin.co.nz/) layout); set
`DOCKER_STACKS_DIR` in `~/.<shell>rc.local` to use another directory.
`dsr <stack>` removes one.

### 3. omnishell: `omnishell/config.toml`

Version-controlled here, copied to `~/.config/omnishell/config.toml` by
`bootstrap.sh`. It owns rc *lines*: plugin inits, history/completion options,
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
| `modern-aliases`                                                  | `ls` / `cat` / `find` → `eza` / `bat` / `fd`                                | `replace = [...]`                            |
| `colorized-man`                                                   | man pages through `bat`; plain `less` colours when `bat` is missing         | -                                            |
| `direnv`                                                          | per-directory environment from `.envrc`                                     | -                                            |
| `broot`                                                           | directory-tree TUI; `br` cd's into the directory you pick                   | `cmd = "br"`                                 |
| `mise`                                                            | runtime version manager, `mise activate` per prompt                         | -                                            |
| `starship`                                                        | prompt; seeds `~/.config/omnishell/starship.toml` once, never overwrites it | edit that file for prompt styling            |
| `root-loops`                                                      | OSC 4/10/11 palette push on shell start                                     | `appearance = "dark"`                        |
| `tmux`                                                            | installs tmux; optional auto-attach to a session on shell start             | `session = "default"`, `auto_attach = false` |

`starship`, `mise`, `tmux`, `direnv` and `broot` are **installed** by
`omnishell apply`, not by `bootstrap.sh`. Where a distro doesn't package one (e.g. `broot` / `starship` on Ubuntu 24.04), omnishell falls back to building it
and otherwise reports the module as *degraded*; the rest keeps working.

Prompt styling is `~/.config/omnishell/starship.toml` (seeded once, then yours,
not tracked here); the `~/.tmux.conf` *file* is the `tmux/` stow package below.
`tmux`'s `auto_attach` is `false` here: tmux is installed and configured, but
shells start outside it. Flip it to `true` to attach to (or create) the
`default` session on every shell start.

### 4. Stow packages: standalone config files

`stow` symlinks these into `$HOME`, so **editing the file in the repo changes the
live config immediately** (you may still need to reload the target app). After
adding or removing files in a package, run `make restow`.

|    | Package    | Symlinks to                            | Contains                                                                                                                                          |
|:--:|------------|----------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------|
| 🌿 | `git/`     | `~/.config/git/{config,ignore}`        | aliases (`st`, `co`, `lg`, `coi` = fzf branch switch), `main` default branch, global ignore; **no identity** (see [Git identity](#-git-identity)) |
| 🪟 | `tmux/`    | `~/.tmux.conf`                         | prefix `C-a`, 1-based index, `\|` / `-` splits, mouse on, vi mode, Root-Loops-flavoured status bar (`prefix r` reloads)                           |
| 🦇 | `bat/`     | `~/.config/bat/config`                 | `--theme="ansi"` so `bat` / `delta` / fzf previews inherit the terminal palette                                                                   |
| 👻 | `ghostty/` | `~/.config/ghostty/config` + `themes/` | primary terminal; `theme = light:rootloops-light,dark:rootloops-dark` follows the OS                                                              |
| 📝 | `nvim/`    | `~/.config/nvim/`                      | opt-in: only stowed if the directory exists                                                                                                       |

Stow a subset with `cd ~/.dotfiles && stow git tmux`; add an extra terminal
package via `DOTFILES_TERMINALS="alacritty kitty" ./bootstrap.sh`.

Per-machine Ghostty overrides go in `~/.config/ghostty.local` (optional, outside
the stowed directory).

### 5. Machine-specific & secrets: `~/.zshrc.local` / `~/.bashrc.local`

Sourced last by the `shell.d` marker block, **never version-controlled**:
per-host `PATH`, private tokens, work-only completions and aliases, one-off
overrides. Create it by hand; nothing generates it.

---

## 🎨 Colours: Root Loops

Terminal colours are defined **once**; everything else inherits the 16 ANSI
colours. See [`rootloops`](rootloops):

- [`rootloops/RECIPE`](rootloops/RECIPE): the canonical [rootloops.sh](https://rootloops.sh) recipe
- [`rootloops/palette.env`](rootloops/palette.env): the 16 colours + fg/bg, **the dark source of truth**
- [`rootloops/palette-light.env`](rootloops/palette-light.env): a light companion,
  derived from `palette.env` by `rootloops/derive-light.py` (rootloops.sh only
  makes dark schemes). Hand-tweak it freely; `apply.sh` won't overwrite it.

`rootloops/apply.sh` renders the **emulator** config that can't just inherit the
16 ANSI colours. The **OSC 4/10/11 palette push** to the running terminal is
omnishell's `root-loops` module (`appearance = "dark"` in `omnishell/config.toml`).

| Target                          | File                                                    | Notes                                                                                                                                                                                    |
|---------------------------------|---------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Ghostty**                     | `ghostty/.config/ghostty/themes/rootloops-{dark,light}` | The config sets `theme = light:rootloops-light,dark:rootloops-dark`, so Ghostty follows the OS appearance.                                                                               |
| Any OSC-capable terminal        | omnishell `root-loops` module                           | Pushes the **dark** palette on shell start (tmux-aware): VTE/GNOME Terminal, kitty, alacritty, wezterm, foot, konsole, xterm, iTerm2, Linux console. Keep it in sync with `palette.env`. |
| GNOME Terminal (persistent)     | generated by `rootloops/gen-vte-terminal.sh`            | Writes the dark palette into the default GNOME Terminal profile via `gsettings`. Best-effort; run automatically by `apply.sh` on Linux.                                                  |
| macOS Terminal.app *(fallback)* | `rootloops/RootLoops.terminal`                          | Importable dark profile (`rootloops/gen-terminal-app.py`); `bootstrap.sh` imports it and sets it as default.                                                                             |
| `fzf` UI chrome                 | `shell.d/70-fzf-colors.sh`                              | dark; doesn't inherit ANSI cleanly                                                                                                                                                       |

Only Ghostty gets the light/dark pair; everything else uses the dark palette (they can't switch automatically anyway). `bat`, `tmux`, `git`/`delta` and
`starship` inherit ANSI, so they need no generated file.

**Change the theme:** edit `rootloops/RECIPE` + `rootloops/palette.env` (and
`palette-light.env` for light), run `make colors`, commit. On macOS re-import
`RootLoops.terminal`; on GNOME re-run `rootloops/apply.sh`.

---

## 🧪 Development

|    | Command           | What it does                                                                                   |
|:--:|-------------------|------------------------------------------------------------------------------------------------|
| 🔍 | `make lint`       | `bash -n` / `sh -n` / `zsh -n`, shellcheck (if installed), Python syntax, Terminal.app profile |
| 🧪 | `make test`       | `tests/test-*.sh` in a throwaway `$HOME` / `PATH`; safe to run on your own machine             |
| 📦 | `make stow-check` | dry-run stow against your real `$HOME` (reports conflicts, changes nothing)                    |
| ✅ | `make check`      | all three                                                                                      |

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs `make lint test`
on Ubuntu and macOS, bootstraps a fresh Ubuntu runner twice and checks the
result with `tests/bootstrap-smoke.sh`, and scans the full history for secrets
with [gitleaks](https://github.com/gitleaks/gitleaks).

> [!WARNING]
> `tests/bootstrap-smoke.sh` inspects the real `$HOME` after a full bootstrap.
> Run it only on a disposable machine or container.

### Layout

```text
bootstrap.sh              one-shot installer
Makefile                  stow / colors / lint / test wrappers
omnishell/config.toml     version-controlled omnishell config
zsh/zshrc.zsh             rc library sourced by the generated ~/.zshrc (not stowed)
bash/bashrc.bash          rc library sourced by the generated ~/.bashrc (not stowed)
zsh/.zprofile             stowed
shell.d/*.sh              personal rc fragments (sourced after omnishell)
rootloops/                colour single source (palette.env) + emulator-theme generators
git/ tmux/ bat/ ghostty/  stow packages  →  ~/  and  ~/.config/
nvim/                     optional stow package (opt-in)
tests/                    test-*.sh (make test) + bootstrap-smoke.sh (CI)
```

### Notes

- The git config lives at `~/.config/git/config` (not `~/.gitconfig`). The
  `delta` paging config is `~/.gitconfig.delta`, which `bootstrap.sh` writes only
  when `delta` is installed. On Debian stable, `git-delta` and `eza` (used by
  omnishell's `modern-aliases`) live in `bookworm-backports`, so without them
  those pieces degrade gracefully instead of breaking `git`.
- `zsh/zshrc.zsh` and `shell.d/41-functions.sh` started from
  [hamvocke/dotfiles](https://github.com/hamvocke/dotfiles); the Ghostty cursor
  shader is [sahaj-b/ghostty-cursor-shaders](https://github.com/sahaj-b/ghostty-cursor-shaders)
  (MIT, notice kept in the file).

---

## 🤝 Contributing

Issues and pull requests are welcome. Run `make check` before opening a PR — CI
runs the same lint and tests (see [Development](#-development)).

---

## 📜 License

[MIT](LICENSE) for everything in this repo, except
`ghostty/.config/ghostty/shaders/cursor_warp.glsl`, which keeps its upstream
MIT notice.

<div style="text-align:center">
<sub>One palette, two shells, zero hand-edited rc files.</sub>
</div>
