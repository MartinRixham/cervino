#!/bin/sh

set -eu
[ "$(id -u)" -eq 0 ] || exec doas "$0" "$@"
user=${DOAS_USER:-${SUDO_USER:-}}
[ -n "$user" ] || { echo "Run this from your own account (it re-runs itself via doas)" >&2; exit 1; }

apk add bash bash-completion
usermod -s /bin/bash "$user"
echo "Login shell for $user is now /bin/bash (takes effect at next login)."
