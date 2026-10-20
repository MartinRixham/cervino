#!/bin/sh

set -eu
[ "$(id -u)" -eq 0 ] || exec doas "$0" "$@"
user=${DOAS_USER:-${SUDO_USER:-}}
[ -n "$user" ] || { echo "Run this from your own account (it re-runs itself via doas)" >&2; exit 1; }

apk add cups cups-client cups-filters
getent group lpadmin >/dev/null && addgroup "$user" lpadmin
rc-update add cupsd default
rc-service cupsd start
