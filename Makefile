# Convenience wrappers. `./bootstrap.sh` is still the one-shot entry point.
# Note: ~/.zshrc and ~/.bashrc are written by bootstrap.sh, not stow.

DOTFILES := $(CURDIR)
PACKAGES := zsh git tmux bat ghostty

.PHONY: help
help:
	@echo "make stow        - symlink $(PACKAGES) into \$$HOME (not the rc files)"
	@echo "make restow      - re-stow (after adding/removing files)"
	@echo "make unstow      - remove the symlinks"
	@echo "make colors      - regenerate Root Loops files from rootloops/palette.env"
	@echo "make check       - make lint + make test + make stow-check"
	@echo "make lint        - syntax + shellcheck + python + Terminal.app profile (what CI runs)"
	@echo "make test        - run tests/test-*.sh (isolated \$$HOME, safe anywhere)"
	@echo "make stow-check  - dry-run stow against \$$HOME"

.PHONY: stow restow unstow
stow:
	stow --target=$(HOME) $(PACKAGES)
restow:
	stow --restow --target=$(HOME) $(PACKAGES)
unstow:
	stow --delete --target=$(HOME) $(PACKAGES)

.PHONY: colors
colors:
	bash rootloops/apply.sh

# Scripts executed with bash, and POSIX fragments sourced by both shells.
# (zsh files can only be syntax-checked - shellcheck does not support zsh.)
BASH_SCRIPTS := bootstrap.sh rootloops/apply.sh rootloops/gen-vte-terminal.sh bash/bashrc.bash $(wildcard bash/bashrc-*.bash) $(wildcard tests/*.sh)
SH_FRAGMENTS := $(wildcard shell.d/*.sh) zsh/.zprofile
ZSH_FILES    := zsh/zshrc.zsh $(wildcard zsh/zshrc-*.zsh)

.PHONY: check lint test stow-check
check: lint test stow-check

# Everything that doesn't touch $HOME - this is what CI runs.
lint:
	@echo ">> syntax (bash)"
	@for f in $(BASH_SCRIPTS); do bash -n "$$f" || exit 1; echo "   ok $$f"; done
	@echo ">> syntax (POSIX sh)"
	@for f in $(SH_FRAGMENTS); do sh -n "$$f" || exit 1; echo "   ok $$f"; done
	@echo ">> syntax (zsh)"
	@if command -v zsh >/dev/null; then \
	  for f in $(ZSH_FILES); do zsh -n "$$f" || exit 1; echo "   ok $$f"; done; \
	else echo "   (zsh not installed - skipped)"; fi
	@echo ">> shellcheck"
	@if command -v shellcheck >/dev/null; then \
	  shellcheck -S warning $(BASH_SCRIPTS) && \
	  shellcheck -S warning -s sh $(SH_FRAGMENTS) && echo "   ok"; \
	else echo "   (shellcheck not installed - skipped)"; fi
	@echo ">> python"
	@python3 -c 'import ast,sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]' rootloops/*.py && echo "   ok"
	@echo ">> Terminal.app profile"
	@if command -v plutil >/dev/null; then plutil -lint rootloops/RootLoops.terminal; \
	else python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' rootloops/RootLoops.terminal && echo "   ok (plistlib)"; fi

# Unit-style tests in a throwaway $HOME / PATH - never touch the real ones.
# (tests/bootstrap-smoke.sh is NOT run here: it checks a finished bootstrap and
#  belongs on a disposable machine - CI or a container.)
test:
	@for t in tests/test-*.sh; do echo "== $$t"; bash "$$t" || exit 1; done

# Dry-run stow against the real $HOME (reports conflicts, changes nothing).
stow-check:
	@echo ">> stow dry-run"
	@stow -nv --target=$(HOME) $(PACKAGES) 2>&1 | sed 's/^/   /'
