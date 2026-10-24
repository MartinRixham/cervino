#!/bin/sh
# Runs when a package (this one, apparmor-profiles, ...) changes the AppArmor
# profiles: loads them again, so that running daemons get the new rules
# without a reboot, and unloads those that are gone. Only where the apparmor
# service has loaded them: not in the initramfs, nor in setup-disk's chroot
# of a new system, which load them when they boot.

rc-service --quiet apparmor status >/dev/null 2>&1 || exit 0
rc-service --quiet apparmor reload

exit 0
