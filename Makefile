# Convenience wrappers. `./bootstrap.sh` is still the one-shot entry point.
# Note: ~/.zshrc and ~/.bashrc are written by bootstrap.sh, not stow.

DOTFILES := $(CURDIR)
PACKAGES := zsh git tmux bat ghostty

.PHONY: help
help:
	@echo "make stow      - symlink $(PACKAGES) into \$$HOME (not the rc files)"
	@echo "make restow    - re-stow (after adding/removing files)"
	@echo "make unstow    - remove the symlinks"
	@echo "make colors    - regenerate Root Loops files from rootloops/palette.env"
	@echo "make check     - dry-run stow + lint shell scripts + lint the Terminal.app profile"

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

.PHONY: check
check:
	@echo ">> stow dry-run"
	stow -nv --target=$(HOME) $(PACKAGES) 2>&1 | sed 's/^/   /'
	@echo ">> shell syntax (bash scripts)"
	@for f in bootstrap.sh rootloops/apply.sh rootloops/gen-vte-terminal.sh zsh/zshrc.zsh zsh/zshrc-*.zsh bash/bashrc.bash bash/bashrc-*.bash; do bash -n "$$f" && echo "   ok $$f"; done
	@echo ">> shell syntax (POSIX: sourced fragments)"
	@for f in shell.d/*.sh zsh/.zprofile; do sh -n "$$f" && echo "   ok $$f"; done
	@command -v shellcheck >/dev/null && shellcheck -s sh shell.d/*.sh || echo "   (shellcheck not installed)"
	@echo ">> Terminal.app profile"
	@command -v plutil >/dev/null && plutil -lint rootloops/RootLoops.terminal || echo "   (plutil not available - skipped)"
