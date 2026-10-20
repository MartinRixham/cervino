#!/bin/sh

set -eu
[ "$(id -u)" -eq 0 ] || exec doas "$0" "$@"
user=${DOAS_USER:-${SUDO_USER:-}}
[ -n "$user" ] || { echo "Run this from your own account (it re-runs itself via doas)" >&2; exit 1; }
locale=${1:-en_GB.UTF-8}

apk add musl-locales musl-locales-lang
printf 'LANG=%s\n' "$locale" > /etc/locale.conf

path=$(gdbus call --system --dest org.freedesktop.Accounts \
    --object-path /org/freedesktop/Accounts \
    --method org.freedesktop.Accounts.FindUserByName "$user" |
    sed "s/^(objectpath '\(.*\)',)$/\1/")
gdbus call --system --dest org.freedesktop.Accounts --object-path "$path" \
    --method org.freedesktop.Accounts.User.SetLanguage "$locale" >/dev/null
echo "Session language for $user set to $locale (log out and back in)."
