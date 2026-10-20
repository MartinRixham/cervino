#!/bin/sh
# Fixes "mDNS hostname published". Usage: 15-mdns.sh [hostname]
# Installs Avahi and gives the machine a real hostname to publish.
# NOTE: musl has no NSS, so nss-mdns does not exist for Alpine. GNOME apps
# that use Avahi over D-Bus will see .local hosts, but getent/ssh/ping will
# not.
set -eu
[ "$(id -u)" -eq 0 ] || exec doas "$0" "$@"

name=${1:-}
if [ -z "$name" ]; then
    name=$(hostname -s)
    [ "$name" = localhost ] && name=alpine
fi

apk add avahi avahi-tools
echo "$name" > /etc/hostname
hostname -F /etc/hostname
grep -q "[[:space:]]$name\$" /etc/hosts || printf '127.0.1.1\t%s\n' "$name" >> /etc/hosts

rc-update add avahi-daemon default
rc-service avahi-daemon restart
sleep 2
avahi-resolve -n "$name.local" || true
echo "Hostname is now $name (reboot so the desktop session picks it up)."
