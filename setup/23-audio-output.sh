#!/bin/sh

set -eu
[ "$(id -u)" -eq 0 ] || exec doas "$0" "$@"
user=${DOAS_USER:-${SUDO_USER:-}}
[ -n "$user" ] || { echo "Run this from your own account (it re-runs itself via doas)" >&2; exit 1; }

"$(dirname "$0")/22-pipewire.sh"
id -nG "$user" | tr ' ' '\n' | grep -qx audio || addgroup "$user" audio
echo "Log out and back in, then check with: wpctl status"
