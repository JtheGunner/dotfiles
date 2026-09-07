# Homebrew on Linux (linuxbrew). No-op on macOS (handled by /opt/homebrew) or
# when brew is not installed.

if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
