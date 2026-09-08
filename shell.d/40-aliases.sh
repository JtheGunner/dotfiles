# Small personal aliases not covered by omnishell's modern-aliases module
# (which replaces ls/cat/find with eza/bat/fd).

alias ll='ls -alF'
alias la='ls -A'

alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

alias week='date +%V'                 # current ISO week number
alias serve='python3 -m http.server' # quick static file server

alias ssh='ghostty +ssh --'
