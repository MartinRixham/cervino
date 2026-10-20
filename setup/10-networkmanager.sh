#!/bin/sh

set -eu
[ "$(id -u)" -eq 0 ] || exec doas "$0" "$@"
user=${DOAS_USER:-${SUDO_USER:-}}
[ -n "$user" ] || { echo "Run this from your own account (it re-runs itself via doas)" >&2; exit 1; }

apk add networkmanager networkmanager-cli networkmanager-wifi

cat > /etc/NetworkManager/conf.d/10-alpine.conf <<'EOT'
[main]
dhcp=internal
plugins=keyfile
EOT

# NetworkManager's polkit rules on Alpine grant network control to plugdev
getent group plugdev >/dev/null && addgroup "$user" plugdev

if grep -q '^auto eth' /etc/network/interfaces; then
    cp /etc/network/interfaces /etc/network/interfaces.pre-nm
    ifdown -a -X lo 2>/dev/null || true
    cat > /etc/network/interfaces <<'EOT'
auto lo
iface lo inet loopback
iface lo inet6 loopback
EOT
    echo "Old config saved to /etc/network/interfaces.pre-nm"
fi

rc-update add networkmanager default
rc-service networkmanager restart
