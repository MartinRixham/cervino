#!/bin/sh
# Runs when a package (this one, apparmor-profiles, ...) changes the AppArmor
# profiles: loads them again, so that running daemons get the new rules
# without a reboot, and unloads those that are gone. Only where the apparmor
# service has loaded them: not in the initramfs, nor in setup-disk's chroot
# of a new system, which load them when they boot.
# Also runs when a package changes /boot (CPU microcode, a kernel):
# update-boot copies them to the boot partition, on systems that boot
# that way (it does nothing on others). A new kernel's initramfs is built
# after this may run; the kernel hook runs update-boot again once it is.
# And when a package (this one: disk-passphrase, passphrase-prompt) changes
# the initramfs's features: on an atomic install, whose mkinitfs.conf turns
# mkinitfs's own trigger off, the kernel hook builds the initramfs only for
# a new kernel, so this builds it again for each kernel installed (here, in
# update-alpine's chroot of a new version, which update-boot then copies to
# the boot partition).

apparmor= boot= initramfs=
for dir; do
	case $dir in
	/etc/apparmor.d*) apparmor=1 ;;
	/etc/mkinitfs/features.d*) initramfs=1 ;;
	*) boot=1 ;;
	esac
done

if [ -n "$initramfs" ] && [ -f /etc/kernel/cmdline ]; then
	for release in /usr/share/kernel/*/kernel.release; do
		[ -f "$release" ] || continue
		flavor=${release%/kernel.release}
		flavor=${flavor##*/}
		[ -e /boot/vmlinuz-"$flavor" ] || continue
		mkinitfs -o /boot/initramfs-"$flavor" "$(cat "$release")" ||
			echo "cervino-desktop: could not build the $flavor initramfs" >&2
	done
	boot=1
fi

if [ -n "$apparmor" ] && rc-service --quiet apparmor status >/dev/null 2>&1; then
	rc-service --quiet apparmor reload
fi
[ -z "$boot" ] || /usr/libexec/cervino/update-boot ||
	echo "cervino-desktop: could not update the boot partition" >&2

exit 0
