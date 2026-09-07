# PATH additions. Sourced by both bash and zsh, after omnishell's block.

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac

case ":$PATH:" in
  *":$HOME/bin:"*) ;;
  *) [ -d "$HOME/bin" ] && PATH="$HOME/bin:$PATH" ;;
esac

export PATH
