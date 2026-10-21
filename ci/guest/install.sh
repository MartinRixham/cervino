#!/bin/sh
# Runs as root on the live ISO: installs to /dev/vda with setup-alpine, using
# the ISO's wrapper in /usr/local/sbin as a user in the live desktop would.
# The answer file leaves out what the wrapper sets defaults for (DEVDOPTS,
# KERNELOPTS, no root password) or skips (interfaces and DNS:
# NetworkManager handles the network), so those defaults are what gets
# tested. It installs openssh, so that the ISO's sshd settings are tested.

set -eu

[ "$(command -v setup-alpine)" = /usr/local/sbin/setup-alpine ] ||
	{ echo "setup-alpine is not the ISO's wrapper" >&2; exit 1; }

# The install fetches packages from the network. NetworkManager can report
# it up before names resolve, and setup-alpine's mirror step gives up on the
# first failed lookup, so also wait for DNS.
nm-online -q -t 120
i=0
until nslookup mirrors.alpinelinux.org >/dev/null 2>&1; do
	i=$((i + 1))
	[ "$i" -le 60 ] || { echo "cannot resolve mirrors.alpinelinux.org" >&2; exit 1; }
	sleep 2
done

cat > /tmp/answers <<'EOF'
KEYMAPOPTS=none
HOSTNAMEOPTS=cervino
TIMEZONEOPTS=UTC
PROXYOPTS=none
APKREPOSOPTS="-1 -c"
USEROPTS="-a -u -g audio,input,video,netdev,plugdev,lpadmin tester"
SSHDOPTS=openssh
NTPOPTS=none
DISKOPTS="-m sys /dev/vda"
LBUOPTS=none
APKCACHEOPTS=none
EOF

ERASE_DISKS=/dev/vda setup-alpine -f /tmp/answers

# The installed system's root is locked, so the test boot logs in on the
# serial console as tester and needs root without a password prompt. tester
# is left locked by the install (setup-user -u runs shadow's passwd -u, which
# refuses to leave an empty password), so give it an empty one, and a doas
# rule that does not ask.
mnt=$(mktemp -d)
for part in /dev/vda[0-9]*; do
	mount "$part" "$mnt" 2>/dev/null || continue
	[ -e "$mnt"/etc/alpine-release ] && break
	umount "$mnt"
done
[ -e "$mnt"/etc/alpine-release ] || { echo "no installed root on /dev/vda" >&2; exit 1; }
chroot "$mnt" passwd -d tester
echo 'permit nopass tester' > "$mnt"/etc/doas.d/90-ci.conf
umount "$mnt"
