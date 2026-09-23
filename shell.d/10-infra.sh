# Kubernetes / infra tooling. Personal layer - deliberately NOT an omnishell
# module (omnishell stays a public, generic tool).

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export KUBE_EDITOR="${KUBE_EDITOR:-nano}"

if command -v kubectl >/dev/null 2>&1; then
  alias k='kubectl'
  # shell-specific completion wiring
  if [ -n "${ZSH_VERSION:-}" ]; then
    eval "$(kubectl completion zsh 2>/dev/null)" || true
    compdef k=kubectl 2>/dev/null || true
  elif [ -n "${BASH_VERSION:-}" ]; then
    eval "$(kubectl completion bash 2>/dev/null)" || true
    # shellcheck disable=SC3044 # bash-only builtin, guarded by $BASH_VERSION
    complete -o default -F __start_kubectl k 2>/dev/null || true
  fi
fi

command -v flux >/dev/null 2>&1 && alias f='flux'
command -v terraform >/dev/null 2>&1 && alias tf='terraform'
