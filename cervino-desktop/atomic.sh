# shellcheck shell=sh
# Sourced by update-boot, update-alpine and the cervino-atomic service.
# The volume's top level holds roots/<id> and, while an update is staged,
# "staged" (the new version's id, then the id of the version it was made
# from, and "merge" if the /etc changes made since are to be brought into it)
# and etc-base, a read-only snapshot of /etc when it was staged.

# atomic_detect [ROOT]: whether ROOT (default /) is a version of an atomic
# install, mounted there (not a chroot into one being made); sets atomic_dev
# (the volume's device) and atomic_id (the version's id).
atomic_detect() {
	local root="${1:-/}" d m t o _ subvolid=
	root=${root%/}
	atomic_dev= atomic_id=
	[ -f "$root"/etc/kernel/cmdline ] || return 1
	while read -r d m t o _; do
		[ "$m" = "${root:-/}" ] && [ "$t" = btrfs ] || continue
		atomic_dev=$d
		atomic_id=$(echo ",$o," | sed -n 's|.*,subvol=/roots/\([^,/]*\),.*|\1|p')
		subvolid=$(echo ",$o," | sed -n 's/.*,subvolid=\([0-9]*\),.*/\1/p')
	done < /proc/mounts
	[ -n "$atomic_id" ] &&
		[ "$(btrfs inspect-internal rootid "${root:-/}" 2>/dev/null)" = "$subvolid" ]
}

# atomic_mount: mounts the volume's top level on $top (in /run, which is
# still there at shutdown); atomic_umount undoes it.
atomic_mount() {
	top=$(mktemp -d /run/cervino-volume.XXXXXX) &&
		mount -t btrfs -o subvolid=5 "$atomic_dev" "$top"
}
atomic_umount() {
	umount "$top" 2>/dev/null
	rmdir "$top" 2>/dev/null
}

# atomic_staged: sets staged_id, staged_from and staged_merge from $top/staged
# (all empty when nothing is staged).
atomic_staged() {
	staged_id= staged_from= staged_merge=
	[ ! -f "$top"/staged ] || read -r staged_id staged_from staged_merge < "$top"/staged
}

# atomic_ready ID: whether version ID is complete: read-only, and not staged.
atomic_ready() {
	[ "$1" != "$staged_id" ] && [ -d "$top/roots/$1" ] &&
		[ "$(btrfs property get -ts "$top/roots/$1" ro 2>/dev/null)" = ro=true ]
}

# atomic_pi [ROOT]: whether ROOT (default /) is a Raspberry Pi's system (the
# firmware's files are in its /boot).
atomic_pi() {
	local r="${1:-}"
	r=${r%/}
	[ -f "$r"/boot/start4.elf ] || [ -f "$r"/boot/bootcode.bin ]
}

# atomic_trial [ROOT]: whether a new version of ROOT's system starts once
# on trial, with the running one to fall back on (see
# /usr/libexec/cervino/boot-trial): on a PC, which UEFI starts, and on a Pi
# whose firmware has tryboot.
atomic_trial() {
	if atomic_pi "${1:-}"; then
		[ -e /proc/device-tree/chosen/bootloader/tryboot ]
	else
		[ -d /sys/firmware/efi ]
	fi
}

# atomic_failed ID: whether version ID did not start when it was tried.
atomic_failed() {
	grep -qx "$1" "$top"/boot-failed 2>/dev/null
}

# atomic_delete ID: deletes version ID.
atomic_delete() {
	local r="$top/roots/$1"
	[ -n "$1" ] && [ -d "$r" ] || return 0
	btrfs property set -ts "$r" ro false 2>/dev/null
	[ ! -d "$r"/etc ] || btrfs -q subvolume delete "$r"/etc 2>/dev/null || rm -rf "${r:?}"/etc
	btrfs -q subvolume delete "$r"
}

# atomic_unstage: deletes the staged version, if any, and what goes with it.
atomic_unstage() {
	atomic_staged
	[ -z "$staged_id" ] || atomic_delete "$staged_id"
	[ ! -d "$top"/etc-base ] || btrfs -q subvolume delete "$top"/etc-base
	rm -f "$top"/staged
	# shellcheck disable=SC2034 # read by the scripts that source this
	staged_id= staged_from= staged_merge=
}

# atomic_gc: deletes all but the running version, the staged one and the
# newest four complete ones, and versions left incomplete.
atomic_gc() {
	local id n=0
	atomic_staged
	for id in $(ls -r "$top"/roots); do
		[ "$id" = "$atomic_id" ] || [ "$id" = "$staged_id" ] && continue
		if atomic_ready "$id" && [ "$n" -lt 4 ]; then
			n=$((n + 1))
			continue
		fi
		atomic_delete "$id"
	done
}
