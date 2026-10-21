#!/bin/sh
# Runs as root on the live ISO: installs to /dev/vda with setup-alpine, using
# the ISO's wrapper in /usr/local/sbin as a user in the live desktop would.
# The answer file leaves out what the wrapper sets defaults for (DEVDOPTS,
# KERNELOPTS) or skips (interfaces and DNS: NetworkManager handles the
# network), so those defaults are what gets tested.

set -eu

[ "$(command -v setup-alpine)" = /usr/local/sbin/setup-alpine ] ||
	{ echo "setup-alpine is not the ISO's wrapper" >&2; exit 1; }

# The install fetches packages from the network.
nm-online -q -t 120

cat > /tmp/answers <<'EOF'
KEYMAPOPTS=none
HOSTNAMEOPTS=cervino
TIMEZONEOPTS=UTC
PROXYOPTS=none
APKREPOSOPTS="-1 -c"
USEROPTS="-a -u -g audio,input,video,netdev,plugdev,lpadmin tester"
SSHDOPTS=none
NTPOPTS=none
DISKOPTS="-m sys /dev/vda"
LBUOPTS=none
APKCACHEOPTS=none
EOF

ERASE_DISKS=/dev/vda setup-alpine -e -f /tmp/answers
