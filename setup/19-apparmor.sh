#!/bin/sh

set -eu
[ "$(id -u)" -eq 0 ] || exec doas "$0" "$@"

apk add apparmor apparmor-utils apparmor-profiles
rc-update add apparmor boot

conf=/etc/update-extlinux.conf
if ! grep -q '^default_kernel_opts=.*apparmor' "$conf"; then
    cp "$conf" "$conf.pre-apparmor"
    sed -i 's/^default_kernel_opts="\(.*\)"/default_kernel_opts="\1 lsm=landlock,lockdown,yama,loadpin,safesetid,integrity,apparmor"/' "$conf"
fi
grep '^default_kernel_opts=' "$conf"
update-extlinux
echo "Reboot to activate AppArmor."
