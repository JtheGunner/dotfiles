# Colored man pages / less. Temporary home: this is planned as the omnishell
# `colorized-man` module (OMNIS-7). Move it there once that module ships and
# delete this file.

export LESS_TERMCAP_mb="$(printf '\033[1;31m')"     # begin blinking
export LESS_TERMCAP_md="$(printf '\033[1;36m')"     # begin bold
export LESS_TERMCAP_me="$(printf '\033[0m')"        # end mode
export LESS_TERMCAP_so="$(printf '\033[01;44;33m')" # begin standout (info box)
export LESS_TERMCAP_se="$(printf '\033[0m')"        # end standout
export LESS_TERMCAP_us="$(printf '\033[1;32m')"     # begin underline
export LESS_TERMCAP_ue="$(printf '\033[0m')"        # end underline
