#!/bin/sh -e
#
# genapkovl-gnomelive.sh: the apkovl generator of the gnomelive mkimage
# profile. build-alpine-gnome-iso.sh copies it into aports/scripts/, with
# genapkovl-gnomelive.conf (the build settings: LIVE_USER, LIVE_PASSWORD,
# AUTOLOGIN, KERNEL_OPTS, WORLD), the live/ directory (the live system's
# scripts, which it puts in the apkovl as they are) and, for the Raspberry
# Pi, usercfg.txt next to it, and mkimage runs it with the hostname as its
# argument.
#
# The apkovl holds what only the live system has: the live user, autologin,
# the installer's wrappers and the runlevels. The live system boots from the
# root file system image on the boot media, with /etc/apk/world (WORLD, the
# image's packages) installed; the initramfs unpacks the apkovl over it. The
# desktop features' configuration is in the cervino-desktop package
# (cervino-desktop/APKBUILD), which the world installs, on the live system
# and on installs alike.
#
# The runlevels are those the initramfs sets up on the standard ISO, changed
# as setup-desktop gnome would change them: mdev/hwdrivers swapped for udev
# (setup-devd udev), plus cgroups, dbus and gdm in default. The desktop
# features add their services on top, and AppArmor to sysinit. modloop is
# left out: the image has the kernel's modules and firmware.

HOSTNAME="$1"
[ -n "$HOSTNAME" ] || { echo "usage: $0 hostname"; exit 1; }

here=$(dirname "$0")
# shellcheck source=/dev/null
. "$here"/genapkovl-gnomelive.conf

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

makefile() {
	mkdir -p "$(dirname "$3")"
	cat > "$3"
	chown "$1" "$3"
	chmod "$2" "$3"
}
rc_add() {
	mkdir -p "$tmp"/etc/runlevels/"$2"
	ln -sf /etc/init.d/"$1" "$tmp"/etc/runlevels/"$2"/"$1"
}
shquote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# The build settings the live system's scripts (from live/) read: the
# live-user init script, and the setup-alpine and lbu wrappers. Only root
# can read it, as it has LIVE_PASSWORD; /usr/local is not in lbu.list, so
# installs don't get it.
printf '%s=%s\n' LIVE_USER "$(shquote "$LIVE_USER")" \
	LIVE_PASSWORD "$(shquote "$LIVE_PASSWORD")" \
	KERNEL_OPTS "$(shquote "$KERNEL_OPTS")" |
	makefile root:root 0600 "$tmp"/usr/local/share/gnomelive/gnomelive.conf

makefile root:root 0644 "$tmp"/etc/hostname <<EOF
localhost
EOF

makefile root:root 0644 "$tmp"/etc/apk/world <<EOF
$WORLD
EOF

autologin_conf=""
if [ "$AUTOLOGIN" = 1 ]; then
	autologin_conf="AutomaticLoginEnable=True
AutomaticLogin=$LIVE_USER"
fi
makefile root:root 0644 "$tmp"/etc/gdm/custom.conf <<EOF
[daemon]
$autologin_conf

[security]

[xdmcp]

[chooser]

[debug]
EOF

# Stands in for setup-user: creates the desktop user before GDM starts.
# With no LIVE_PASSWORD the user has an empty password: GDM and the lock
# screen accept it (Alpine's base-auth has nullok), but polkit's PAM stack
# does not and doas would still ask, so the user gets a polkit rule and a
# doas nopass rule instead (doas uses the last matching rule, hence 90-).
# The rules are written here rather than shipped in the apkovl so that
# rules.d keeps the ownership the polkit package gives it.
makefile root:root 0755 "$tmp"/etc/init.d/live-user < "$here"/live/live-user

# setup-alpine switches OpenRC to the boot runlevel and back, which stops
# gdm and dbus and so kills the desktop (and the terminal running it). It
# also swaps udev for mdev unless DEVDOPTS says otherwise, leaves the
# community repo (where GNOME lives) disabled and configures interfaces
# for ifupdown, which would fight NetworkManager. This wrapper, found
# first in PATH, makes those runlevel switches start services without
# stopping any, skips the interface and DNS steps, keeps udev, which GNOME
# needs, and defaults community to enabled. It also defaults the user step
# to the plugdev (network settings) and lpadmin (printers) groups and the
# installed kernel command line to one with AppArmor enabled (and on the
# Pi, NVMe drives' host memory buffer cap raised and the memory cgroup
# controller back on), offers only mirrors
# reached over HTTPS (setup-apkrepos picks from $MIRRORS, else from
# mirrors.txt, which lists http:// URLs only; mirrors.json lists each
# mirror's https:// URL too, the CDN first), installs no
# SSH server, skips the NTP step (its default, busybox ntpd, would run
# next to the chronyd the install already has from the live runlevels),
# leaves acpid out of the runlevels (its only handler, for the power
# button, powers off at once; elogind handles the button and lets GNOME
# decide what it does), enables cronie, whose anacron runs the periodic
# jobs a laptop was off for, where it would enable busybox crond,
# and skips the root password (-e): the lbu shim below locks root on the installed
# system, whose admin user gets root through doas. An answer file passed
# with -f still overrides these defaults.
# Its hostname step restarts the hostname service and stops and starts
# networking, which stops what depends on them (avahi, chronyd, crond,
# syslog) and has OpenRC start them again in the background; there they
# race the next step, setup-devd -C mdev, which stops udev, until the
# OpenRC service locks deadlock ("Call to flock failed") and chronyd fails
# to start. So the rc-service shim skips the networking stop and start
# (NetworkManager owns the network) and sets the hostname directly, and
# the setup-devd shim skips the mdev bootstrap: udev is already running.
# Service changes run in a session of their own (setsid -w, from
# util-linux-misc, which zram-init pulls in), so Ctrl-C stops setup-alpine
# but cannot kill an openrc-run halfway, leaving its lock and state behind.
# The shims in the temporary directory only need to work until
# setup-alpine sources /etc/profile, which resets PATH; the lbu and
# adduser shims, used after that, live in /usr/local/sbin, which
# /etc/profile puts first.
makefile root:root 0755 "$tmp"/usr/local/sbin/setup-alpine < "$here"/live/setup-alpine

# An app grid entry that runs the wrapper above in a terminal. GLib's
# fallback terminal list has no GNOME Console, so Terminal=true would not
# work; kgx is run directly. The window stays open so the last messages can
# be read. /usr/local/share is not in lbu.list, so installs don't get it.
makefile root:root 0644 "$tmp"/usr/local/share/applications/alpine-install.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Install Alpine Linux
Comment=Install this system to disk with setup-alpine
Exec=kgx -T "Install Alpine Linux" -- sh -c "doas /usr/local/sbin/setup-alpine; echo; printf 'Press Enter to close. '; read -r _"
Icon=system-software-install
Categories=System;
EOF

# cervino-desktop's "Update Alpine Linux" launcher is of no use here: the
# live system runs from RAM, and an upgrade would be gone at the next boot.
# An entry in /usr/local/share/applications hides the one of the same name
# in /usr/share.
makefile root:root 0644 "$tmp"/usr/local/share/applications/update-alpine.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Update Alpine Linux
Hidden=true
EOF

# setup-disk copies the live /etc to the new system with "lbu package -",
# and so would carry over the live user (with its known or empty password,
# and its doas and polkit rules), its home directory (setup-alpine adds
# every /home/* to lbu), its init script and GDM autologin. This shim
# drops those from the copy; the user created in setup-alpine's user step
# is the one to log in as. If that user is an admin (in wheel, so doas lets
# them in), root's password is locked in the copy, as setup-alpine was told
# not to set one; without an admin, root is left as it is so the system can
# still be logged in to. The serial console's getty that the initramfs
# added to inittab is started under its AppArmor profile, as the others
# are. On the Pi it also adds boot/usercfg.txt (GNOME needs the GPU's KMS
# driver): setup-disk unpacks the archive into the new system with its boot
# partition mounted, and the bootloader package's config.txt includes that
# file.
makefile root:root 0755 "$tmp"/usr/local/sbin/lbu < "$here"/live/lbu

# The Pi image's usercfg.txt (see build-alpine-gnome-iso.sh), for the lbu
# shim above to put on installed systems' boot partitions.
if [ -f "$here"/usercfg.txt ]; then
	makefile root:root 0644 "$tmp"/usr/local/share/gnomelive/usercfg.txt \
		< "$here"/usercfg.txt
fi

# busybox adduser gives new users /bin/sh and a home directory everyone can
# read; give desktop users bash and a home only they can read instead
# (system users, created with -S, are left alone, and so are an explicit
# -s and -H). With two names, adduser adds an existing user to a group.
# setup-user asks for a user again if adduser fails, so a user that an
# earlier setup-alpine run made (one that was abandoned before or after
# writing the disk; the live /etc keeps the user) would only be refused as
# taken. Users made under the setup-alpine wrapper are listed in
# /run/gnomelive-setup-users, and the wrapper's next runs get them back,
# with the full name now given.
makefile root:root 0755 "$tmp"/usr/local/sbin/adduser < "$here"/live/adduser

# Alpine's setup-disk installs a sys install's system with "apk add --root
# MNT --initdb ... --overlay-from-stdin", once it has partitioned the disk
# and put the live /etc (lbu package), fstab, mkinitfs.conf and the boot
# loader's settings in MNT. Under the setup-disk shim (live/setup-disk)
# (CERVINO_COPY_ROOT), this apk copies the root file system image the live
# system runs from there first, but for the files already there, and builds
# its initramfs, so apk itself only adds what the image lacks: the boot
# loader (from the disc), firmware for hardware the image has none for, and
# packages added in the live session. Then it makes the boot loader's
# configuration, which the packages' triggers would have made when the
# kernel was installed. Everything else goes to apk as it is.
makefile root:root 0755 "$tmp"/usr/local/sbin/apk < "$here"/live/apk

# The setup-disk shim (live/setup-disk), which offers an
# atomic install besides Alpine's standard one.
makefile root:root 0755 "$tmp"/usr/local/sbin/setup-disk < "$here"/live/setup-disk

rc_add devfs sysinit
rc_add dmesg sysinit
rc_add apparmor sysinit
rc_add udev sysinit
rc_add udev-trigger sysinit
rc_add udev-settle sysinit

rc_add modules boot
rc_add sysctl boot
rc_add hostname boot
rc_add bootmisc boot
rc_add syslog boot
rc_add zram-init boot

rc_add firstboot default
rc_add udev-postmount default
rc_add cgroups default
rc_add dbus default
rc_add networkmanager default
rc_add chronyd default
rc_add earlyoom default
rc_add wifi-region default
rc_add openrc-settingsd default
rc_add bluetooth default
rc_add cupsd default
rc_add avahi-daemon default
rc_add nftables default
rc_add spice-vdagentd default
rc_add apk-polkit-server default
rc_add local default
rc_add live-user default
rc_add gdm default

rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown

tar -c -C "$tmp" etc usr | gzip -9n > "$HOSTNAME".apkovl.tar.gz
