#!/bin/sh
# Runs when a package (this one, apparmor-profiles, ...) changes the AppArmor
# profiles: loads them again, so that running daemons get the new rules
# without a reboot, and unloads those that are gone. Only where the apparmor
# service has loaded them: not in the initramfs, nor in setup-disk's chroot
# of a new system, which load them when they boot.
# Also runs when a package changes /boot (CPU microcode, a kernel) or Limine's
# files: update-boot copies them to the boot partition, on systems that boot
# that way (it does nothing on others). A new kernel's initramfs is built
# after this may run; the kernel hook runs update-boot again once it is.

apparmor= boot=
for dir; do
	case $dir in
	/etc/apparmor.d*) apparmor=1 ;;
	*) boot=1 ;;
	esac
done

if [ -n "$apparmor" ] && rc-service --quiet apparmor status >/dev/null 2>&1; then
	rc-service --quiet apparmor reload
fi
[ -z "$boot" ] || /usr/libexec/cervino/update-boot ||
	echo "cervino-desktop: could not update the boot partition" >&2

exit 0
