#!/usr/bin/env bash
# Apply the Root Loops palette to the DEFAULT GNOME Terminal / VTE profile via
# gsettings (persistent, profile-level). Best-effort: silently does nothing if
# gsettings or the GNOME Terminal schema is absent (KDE Konsole, xfce4-terminal,
# etc. are still covered at runtime by omnishell's root-loops module).
#
# Run by rootloops/apply.sh on Linux.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$here/palette.env"

command -v gsettings >/dev/null 2>&1 || { echo "gsettings not found - skipping VTE profile"; exit 0; }
gsettings list-schemas 2>/dev/null | grep -q '^org.gnome.Terminal.ProfilesList$' || {
  echo "GNOME Terminal schema not present - skipping VTE profile"; exit 0
}

profile="$(gsettings get org.gnome.Terminal.ProfilesList default | tr -d \")"
base="org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:${profile}/"

pal="['#${RL_COLOR0}', '#${RL_COLOR1}', '#${RL_COLOR2}', '#${RL_COLOR3}', '#${RL_COLOR4}', '#${RL_COLOR5}', '#${RL_COLOR6}', '#${RL_COLOR7}', '#${RL_COLOR8}', '#${RL_COLOR9}', '#${RL_COLOR10}', '#${RL_COLOR11}', '#${RL_COLOR12}', '#${RL_COLOR13}', '#${RL_COLOR14}', '#${RL_COLOR15}']"

gsettings set "$base" use-theme-colors false
gsettings set "$base" bold-color-same-as-fg true
gsettings set "$base" foreground-color "'#${RL_FG}'"
gsettings set "$base" background-color "'#${RL_BG}'"
gsettings set "$base" palette "$pal"

echo "applied Root Loops to GNOME Terminal profile ${profile}"
