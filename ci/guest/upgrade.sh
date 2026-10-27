#!/bin/sh
# ci/guest/upgrade.sh STEP: tests updating an atomic install, as root, over
# three starts of the installed system (ci/vm-test.sh restarts it between
# the steps):
#   stage     apk add, which cervino-desktop's apk wrapper hands to
#             update-alpine, adds a package (one of a few small ones that is
#             not installed) to a new version of the system,
#             which it stages, leaving the running one as it was; /etc is
#             changed before and after
#   check     the system started with the new version (on trial: UEFI's
#             BootNext), which has the package and the /etc changes, those
#             made after staging too, and which is then made the one that
#             starts (first in BootOrder), with the old version kept; then
#             update-alpine rollback stages a copy of the old version
#   rollback  the system started with that copy: no package; then
#             update-alpine list shows the versions, and update-alpine
#             delete removes the updated one, from the volume, the boot
#             partition and the boot entries, but not the running one;
#             then it stages another update, with apk add again, and a
#             service that breaks its kernel image at the shutdown, once
#             it is on trial
#   fallback  the firmware could not start that update, so the system
#             started with the version before, which is still the one that
#             starts; update-alpine list shows that the update did not
#             start, and it is deleted
# Exits non-zero, saying why, on the first failure. Notes between the steps
# are kept in /var, which all versions share.

set -eu

notes=/var/lib/cervino-ci
# shellcheck source=../../cervino-desktop/atomic.sh
. /usr/libexec/cervino/atomic.sh

die() {
	echo "upgrade test: $*" >&2
	exit 1
}

# boot_num ID: the number of version ID's UEFI boot entry, if it has one.
boot_num() {
	local label
	label=$(echo "$1" | sed 's/^\(....\)\(..\)\(..\)\(..\)\(..\)\(..\)$/\1-\2-\3 \4:\5:\6/')
	efibootmgr | sed -n "s/^Boot\([0-9A-Fa-f]\{4\}\)\*\{0,1\} Alpine Linux $label\(	.*\)\{0,1\}\$/\1/p"
}

# boots_first ID: whether version ID starts by default: its boot entry is
# first in BootOrder, with no BootNext, and the firmware's fallback is it.
boots_first() {
	local n
	n=$(boot_num "$1")
	[ -n "$n" ] && [ "$(efibootmgr | sed -n 's/^BootOrder: \([^,]*\).*/\1/p')" = "$n" ] &&
		! efibootmgr | grep -q '^BootNext:' &&
		cmp -s /boot/efi/cervino/"$1"/linux.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
}

# started ID: waits for version ID, on trial, to be made the one that starts,
# which init does once the default runlevel has started (boot-trial boot).
started() {
	local _
	for _ in $(seq 60); do
		boots_first "$1" && return 0
		sleep 2
	done
	return 1
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
	boots_first "$atomic_id" ||
		die "the running version does not start by default before the restart"
	# Changes after staging, which the shutdown brings into the new version.
	echo after > /etc/ci-after
	rm /etc/ci-gone
	;;

check)
	first=$(cat "$notes"/first) pkg=$(cat "$notes"/pkg)
	[ "$atomic_id" != "$first" ] || die "the system started with the version before the update"
	apk info -e "$pkg" > /dev/null || die "the new version has no $pkg"
	[ "$(cat /etc/ci-before)" = before ] ||
		die "/etc/ci-before, written before the update, is missing"
	[ "$(cat /etc/ci-after 2>/dev/null)" = after ] ||
		die "/etc/ci-after, written after the update was staged, did not reach the new version"
	[ ! -e /etc/ci-gone ] || die "/etc/ci-gone, deleted after the update was staged, is back"
	[ "$(btrfs property get -ts / ro)" = ro=true ] || die "/ is not read-only"
	started "$atomic_id" || die "the new version was not made the one that starts"
	[ -n "$(boot_num "$first")" ] && [ -f /boot/efi/cervino/"$first"/linux.efi ] ||
		die "the version before the update has no boot entry"
	! update-alpine list | grep -q "did not start" ||
		die "update-alpine list shows a version that did not start"
	echo "$atomic_id" > "$notes"/second
	update-alpine rollback < /dev/null || die "update-alpine rollback failed"
	;;

rollback)
	first=$(cat "$notes"/first) second=$(cat "$notes"/second) pkg=$(cat "$notes"/pkg)
	[ "$atomic_id" != "$second" ] && [ "$atomic_id" != "$first" ] ||
		die "the system did not start with a new version after the rollback"
	! apk info -e "$pkg" > /dev/null || die "the rolled back version has $pkg"
	started "$atomic_id" || die "the rolled back version was not made the one that starts"
	list=$(update-alpine list) || die "update-alpine list failed"
	echo "$list"
	echo "$list" | grep -q "^$atomic_id .*running, starts next time$" ||
		die "update-alpine list does not show the running version as the one to start"
	echo "$list" | grep -q "^$first " && echo "$list" | grep -q "^$second " ||
		die "update-alpine list does not show the earlier versions"
	! update-alpine delete "$atomic_id" 2> /dev/null ||
		die "update-alpine deleted the running version"
	update-alpine delete "$second" || die "update-alpine delete failed"
	! update-alpine list | grep -q "^$second " || die "$second is still listed after deleting it"
	[ -z "$(boot_num "$second")" ] || die "$second still has a boot entry"
	[ ! -e /boot/efi/cervino/"$second" ] || die "$second's kernel is still on the boot partition"
	boots_first "$atomic_id" ||
		die "the running version does not start by default after the delete"
	echo "$atomic_id" > "$notes"/third
	apk add "$pkg" < /dev/null || die "apk add (update-alpine add) failed"
	cat > /etc/init.d/ci-break <<'EOF'
#!/sbin/openrc-run
depend() {
	after cervino-atomic
	before killprocs mount-ro savecache
}
start() {
	read -r id < /run/cervino-trial || return 0
	mountpoint -q /boot/efi || mount /boot/efi
	echo "ci-break: breaking $id's kernel image"
	echo broken > /boot/efi/cervino/"$id"/linux.efi
	sync
}
EOF
	chmod 755 /etc/init.d/ci-break
	rc-update add ci-break shutdown
	;;

fallback)
	third=$(cat "$notes"/third)
	rc-update del ci-break shutdown
	rm -f /etc/init.d/ci-break
	[ "$atomic_id" = "$third" ] ||
		die "the system did not start with the version before the broken update"
	failed=$(ls /boot/efi/cervino | sort | tail -n1)
	[ "$failed" != "$third" ] || die "the broken update is not on the boot partition"
	boots_first "$atomic_id" || die "the running version does not start by default"
	list=$(update-alpine list) || die "update-alpine list failed"
	echo "$list"
	echo "$list" | grep -q "^$failed .*did not start when tried$" ||
		die "update-alpine list does not show that the broken update did not start"
	echo "$list" | grep -q "^$atomic_id .*running, starts next time$" ||
		die "update-alpine list does not show the running version as the one to start"
	update-alpine delete "$failed" || die "update-alpine delete failed"
	rm -rf "$notes"
	;;

*)
	die "usage: $0 stage|check|rollback|fallback"
	;;
esac
echo "upgrade test: $1 passed"
