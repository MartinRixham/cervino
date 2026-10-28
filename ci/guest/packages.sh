#!/bin/sh
# ci/guest/packages.sh MODE: runs as root on the installed system, an atomic
# or a sys install (MODE, setup-disk's -m): adds the packages of this build
# that the image leaves out (cervino-gstreamer, cervino-terminal), whose
# .apk files are in pkgs/ of the shared archive, as a user would add them
# from the repo. They are signed with the build's key, which the system
# trusts. On an atomic install update-alpine adds them to a new version of
# the system, which it starts with next time; ci/vm-test.sh restarts it
# before the tests.

set -eu

mode=${1:?usage: $0 atomic|sys}
dir=$(dirname "$0")/../..

# Their dependencies come from the network: see install.sh.
nm-online -q -t 120
i=0
until nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1; do
	i=$((i + 1))
	[ "$i" -le 60 ] || { echo "cannot resolve dl-cdn.alpinelinux.org" >&2; exit 1; }
	sleep 2
done

set -- "$dir"/pkgs/*.apk
[ -e "$1" ] || { echo "no packages to add" >&2; exit 1; }
if [ "$mode" = atomic ]; then
	# update-alpine runs apk in a chroot of the new version, which has /var
	# but not this /tmp, and the apk wrapper only passes on package names.
	pkgs=/var/lib/cervino-ci/pkgs
	rm -rf "$pkgs"
	mkdir -p "$pkgs"
	cp "$@" "$pkgs"/
	update-alpine add "$pkgs"/*.apk < /dev/null
else
	apk add "$@"
fi
