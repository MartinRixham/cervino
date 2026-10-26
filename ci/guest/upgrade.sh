#!/bin/sh
# ci/guest/upgrade.sh STEP: tests updating an atomic install, as root, over
# three starts of the installed system (ci/vm-test.sh restarts it between
# the steps):
#   stage     apk add, which cervino-desktop's apk wrapper hands to
#             update-alpine, adds a package (one of a few small ones that is
#             not installed) to a new version of the system,
#             which it stages, leaving the running one as it was; /etc is
#             changed before and after
#   check     the system started with the new version, which has the
#             package and the /etc changes, those made after staging too;
#             the old version is in the boot menu; then update-alpine
#             rollback stages a copy of the old version
#   rollback  the system started with that copy: no package; then
#             update-alpine list shows the versions, and update-alpine
#             delete removes the updated one, from the volume and the boot
#             partition, but not the running one
# Exits non-zero, saying why, on the first failure. Notes between the steps
# are kept in /var, which all versions share.

set -eu

notes=/var/lib/cervino-ci
. /usr/libexec/cervino/atomic.sh

die() {
	echo "upgrade test: $*" >&2
	exit 1
}
# boots_first ID: whether Limine's menu starts version ID by default.
boots_first() {
	awk '/^ *path:/ { print; exit }' /boot/efi/limine/limine.conf | grep -q "/cervino/$1/"
}

atomic_detect || die "not an atomic install"
echo "running version: $atomic_id"
case ${1:-} in
stage)
	mkdir -p "$notes"
	echo "$atomic_id" > "$notes"/first
	pkg=
	for p in figlet cmatrix sl cowsay; do
		apk info -e "$p" > /dev/null || { pkg=$p; break; }
	done
	[ -n "$pkg" ] || die "all the candidate packages are installed"
	echo "$pkg" > "$notes"/pkg
	echo before > /etc/ci-before
	echo gone > /etc/ci-gone
	apk info -e apk-tools > /dev/null || die "apk info does not get through the apk wrapper"
	! apk fix < /dev/null 2> /dev/null || die "apk fix was not turned down"
	apk add "$pkg" < /dev/null || die "apk add (update-alpine add) failed"
	! apk info -e "$pkg" > /dev/null || die "$pkg was installed into the running system"
	[ "$(btrfs property get -ts / ro)" = ro=true ] || die "/ is not read-only"
	boots_first "$atomic_id" || die "the boot menu does not start the running version before the restart"
	# Changes after staging, which the shutdown brings into the new version.
	echo after > /etc/ci-after
	rm /etc/ci-gone
	;;
check)
	first=$(cat "$notes"/first) pkg=$(cat "$notes"/pkg)
	[ "$atomic_id" != "$first" ] || die "the system started with the version before the update"
	apk info -e "$pkg" > /dev/null || die "the new version has no $pkg"
	[ "$(cat /etc/ci-before)" = before ] || die "/etc/ci-before, written before the update, is missing"
	[ "$(cat /etc/ci-after 2>/dev/null)" = after ] ||
		die "/etc/ci-after, written after the update was staged, did not reach the new version"
	[ ! -e /etc/ci-gone ] || die "/etc/ci-gone, deleted after the update was staged, is back"
	[ "$(btrfs property get -ts / ro)" = ro=true ] || die "/ is not read-only"
	boots_first "$atomic_id" || die "the boot menu does not start the new version first"
	grep -q "/cervino/$first/" /boot/efi/limine/limine.conf ||
		die "the version before the update is not in the boot menu"
	echo "$atomic_id" > "$notes"/second
	update-alpine rollback < /dev/null || die "update-alpine rollback failed"
	;;
rollback)
	first=$(cat "$notes"/first) second=$(cat "$notes"/second) pkg=$(cat "$notes"/pkg)
	[ "$atomic_id" != "$second" ] && [ "$atomic_id" != "$first" ] ||
		die "the system did not start with a new version after the rollback"
	! apk info -e "$pkg" > /dev/null || die "the rolled back version has $pkg"
	boots_first "$atomic_id" || die "the boot menu does not start the rolled back version first"
	list=$(update-alpine list) || die "update-alpine list failed"
	echo "$list"
	echo "$list" | grep -q "^$atomic_id .*running, starts next time$" ||
		die "update-alpine list does not show the running version as the one to start"
	echo "$list" | grep -q "^$first " && echo "$list" | grep -q "^$second " ||
		die "update-alpine list does not show the earlier versions"
	! update-alpine delete "$atomic_id" 2> /dev/null || die "update-alpine deleted the running version"
	update-alpine delete "$second" || die "update-alpine delete failed"
	! update-alpine list | grep -q "^$second " || die "$second is still listed after deleting it"
	! grep -q "/cervino/$second/" /boot/efi/limine/limine.conf || die "$second is still in the boot menu"
	[ ! -e /boot/efi/cervino/"$second" ] || die "$second's kernel is still on the boot partition"
	boots_first "$atomic_id" || die "the boot menu does not start the running version first after the delete"
	rm -rf "$notes"
	;;
*)
	die "usage: $0 stage|check|rollback"
	;;
esac
echo "upgrade test: $1 passed"
