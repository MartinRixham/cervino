#!/bin/sh -e
#
# genapkovl-gnomelive.sh: the apkovl generator of the gnomelive mkimage
# profile. build-alpine-gnome-iso.sh copies it into aports/scripts/, with
# genapkovl-gnomelive.conf (the build settings: LIVE_USER, LIVE_PASSWORD,
# AUTOLOGIN, KERNEL_OPTS, WORLD) and, for the Raspberry Pi, usercfg.txt next
# to it, and mkimage runs it with the hostname as its argument.
#
# The apkovl holds what only the live system has: the live user, autologin,
# the installer's wrappers and the runlevels. The desktop features'
# configuration is in the cervino-desktop package (cervino-desktop/APKBUILD),
# which /etc/apk/world installs, on the live system and on installs alike.
#
# The runlevels are those the initramfs sets up on the standard ISO, changed
# as setup-desktop gnome would change them: mdev/hwdrivers swapped for udev
# (setup-devd udev), plus cgroups, dbus and gdm in default. The desktop
# features add their services on top, and AppArmor to sysinit.

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
if [ -n "$LIVE_PASSWORD" ]; then
	password="echo '$LIVE_PASSWORD' | chpasswd"
else
	password=$(cat <<EOF
passwd -d $LIVE_USER >/dev/null
		echo 'permit nopass $LIVE_USER' > /etc/doas.d/90-live-user.conf
		cat > /etc/polkit-1/rules.d/49-live-user.rules <<'RULE'
polkit.addRule(function (action, subject) {
	if (subject.user == "$LIVE_USER")
		return polkit.Result.YES;
});
RULE
EOF
)
fi
# Unquoted heredoc: $LIVE_USER and the password commands are filled in
# here, \$ is left for the init script.
makefile root:root 0755 "$tmp"/etc/init.d/live-user <<EOF
#!/sbin/openrc-run
description="Create the live desktop user"

depend() {
	need localmount
	before gdm
}

start() {
	ebegin "Creating live user $LIVE_USER"
	if ! getent passwd $LIVE_USER >/dev/null; then
		adduser -D -s /bin/bash -g "Live User" $LIVE_USER &&
		chmod 700 /home/$LIVE_USER &&
		for g in audio video netdev input plugdev lpadmin wheel; do
			addgroup $LIVE_USER \$g 2>/dev/null
		done
		mkdir -p /etc/doas.d
		echo 'permit persist :wheel' > /etc/doas.d/20-wheel.conf
		$password
		# GNOME Shell offers the tour until this is set; leave that to
		# installed systems. Writing it needs dconf-service on a bus.
		su -s /bin/sh -c "dbus-run-session -- gsettings set org.gnome.shell welcome-dialog-last-shown-version \"'999'\"" $LIVE_USER \
			>/dev/null 2>&1
	fi
	eend 0
}
EOF

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
# Unquoted heredoc: $KERNEL_OPTS is filled in here.
makefile root:root 0755 "$tmp"/usr/local/sbin/setup-alpine <<EOF
#!/bin/sh
shim=\$(mktemp -d) || exit
trap 'rm -rf "\$shim"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
cat > "\$shim"/openrc <<'SHIM'
#!/bin/sh
case "\$1" in
-*) exec setsid -w /sbin/openrc "\$@" ;;
*) exec setsid -w /sbin/openrc --no-stop "\$@" ;;
esac
SHIM
cat > "\$shim"/rc-service <<'SHIM'
#!/bin/sh
case " \$* " in
*" networking stop "*|*" networking start "*) exit 0 ;;
*" hostname restart "*) read -r h _ < /etc/hostname && exec hostname "\$h"; exit ;;
esac
exec setsid -w /sbin/rc-service "\$@"
SHIM
cat > "\$shim"/setup-devd <<'SHIM'
#!/bin/sh
case " \$* " in
*" mdev "*) exit 0 ;;
esac
exec /usr/sbin/setup-devd "\$@"
SHIM
cat > "\$shim"/rc-update <<'SHIM'
#!/bin/sh
case " \$* " in
*" add acpid "*) exit 0 ;;
*" add crond "*) exec /sbin/rc-update -q add cronie ;;
esac
exec /sbin/rc-update "\$@"
SHIM
for cmd in setup-interfaces setup-dns; do
	printf '#!/bin/sh\necho "%s: skipped, NetworkManager manages the network"\n' \$cmd > "\$shim"/\$cmd
done
chmod +x "\$shim"/*
if [ -z "\${MIRRORS:-}" ]; then
	MIRRORS=\$(wget -qO- -T 10 https://mirrors.alpinelinux.org/mirrors.json |
		grep -o 'https:\\\\/\\\\/[^"]*' | sed 's#\\\\/#/#g')
	export MIRRORS=\${MIRRORS:-https://dl-cdn.alpinelinux.org/alpine/}
fi
DEVDOPTS=\${DEVDOPTS:-udev} APKREPOSOPTS=\${APKREPOSOPTS:--c} \\
	USEROPTS=\${USEROPTS:--a -g audio,input,video,netdev,plugdev,lpadmin} \\
	KERNELOPTS=\${KERNELOPTS:-quiet $KERNEL_OPTS} SSHDOPTS=\${SSHDOPTS:-none} \\
	NTPOPTS=\${NTPOPTS:-none} \\
	PATH="\$shim:\$PATH" /usr/sbin/setup-alpine -e "\$@"
EOF

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
# Unquoted heredoc: $LIVE_USER is filled in here.
makefile root:root 0755 "$tmp"/usr/local/sbin/lbu <<EOF
#!/bin/sh
[ "\$*" = "package -" ] || exec /usr/sbin/lbu "\$@"
d=\$(mktemp -d) || exit
trap 'rm -rf "\$d"' EXIT
/usr/sbin/lbu package - > "\$d"/ovl.tar.gz || exit
mkdir "\$d"/root
tar -C "\$d"/root -xzf "\$d"/ovl.tar.gz || exit
tar -tzf "\$d"/ovl.tar.gz | grep -v -e '^etc/init\.d/live-user\$' -e '^etc/runlevels/[^/]*/live-user\$' \\
	-e '^etc/doas\.d/90-live-user\.conf\$' -e '^etc/polkit-1/rules\.d/49-live-user\.rules\$' \\
	-e '^home/$LIVE_USER/' -e '^home/$LIVE_USER\$' > "\$d"/list
cd "\$d"/root || exit
strip() { awk "\$@" "\$f" > "\$f".new && cat "\$f".new > "\$f" && rm "\$f".new; }
for f in etc/passwd etc/passwd- etc/shadow etc/shadow-; do
	[ -f "\$f" ] && strip -F: -v u='$LIVE_USER' '\$1 != u'
done
for f in etc/group etc/group-; do
	[ -f "\$f" ] && strip -F: -v OFS=: -v u='$LIVE_USER' '\$1 == u { next } { n = split(\$4, m, ","); \$4 = ""; for (i = 1; i <= n; i++) if (m[i] != u) \$4 = \$4 (\$4 == "" ? "" : ",") m[i]; print }'
done
if [ -f etc/group ] && awk -F: '\$1 == "wheel" && \$4 != "" { found = 1 } END { exit !found }' etc/group; then
	for f in etc/shadow etc/shadow-; do
		[ -f "\$f" ] && strip -F: -v OFS=: '\$1 == "root" { \$2 = "!" } { print }'
	done
fi
[ -f etc/gdm/custom.conf ] && sed -i '/^AutomaticLogin/d' etc/gdm/custom.conf
[ -f etc/inittab ] && sed -i 's|:/sbin/getty |:/usr/libexec/cervino/apparmor-exec busybox-getty /sbin/getty |' etc/inittab
[ -f etc/apk/protected_paths.d/lbu.list ] && sed -i '\\:^+home/$LIVE_USER\$:d' etc/apk/protected_paths.d/lbu.list
if [ -f /usr/local/share/gnomelive/usercfg.txt ]; then
	mkdir -p boot
	cp /usr/local/share/gnomelive/usercfg.txt boot/
	echo boot/usercfg.txt >> "\$d"/list
fi
tar -c --no-recursion -T "\$d"/list -z
EOF

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
makefile root:root 0755 "$tmp"/usr/local/sbin/adduser <<'EOF'
#!/bin/sh
shell=/bin/bash home=yes user= names=0 value=
for a; do
	if [ -n "$value" ]; then value=; continue; fi
	case $a in
	-S|-[!-]*S*) exec /usr/sbin/adduser "$@" ;;
	-s) shell= value=1 ;;
	-[hgGuk]) value=1 ;;
	-H|-[!-]*H*) home= ;;
	-*) ;;
	*) user=$a names=$((names + 1)) ;;
	esac
done
[ -z "$shell" ] || set -- -s "$shell" "$@"
/usr/sbin/adduser "$@" || exit
[ "$names" = 1 ] && [ -n "$home" ] || exit 0
dir=$(getent passwd "$user" | cut -d: -f6)
[ ! -d "$dir" ] || chmod 700 "$dir"
EOF

# setup-disk offers an atomic install (-m atomic, and the default answer)
# besides Alpine's standard one (-m sys, and the other modes, RAID, several
# disks or a mounted root, which go to Alpine's setup-disk; sys chosen at its
# question goes there too once the disk and encryption are asked). As in Fedora
# Silverblue, an atomic install's system is read-only, and update-alpine
# updates it as a whole (see cervino-desktop's atomic.sh). On a PC it goes
# to one disk: GPT with a BIOS boot
# partition, a FAT boot partition (the EFI system partition, and Limine's for
# BIOS too, so the disk boots either way), swap sized as Alpine's setup-disk
# sizes it (or by -s; on an encrypted disk, dmcrypt opens it with a random
# key at each boot) and a btrfs volume, on LUKS if the disk is to be
# encrypted. The volume holds the system in roots/<id> (the install's date
# and time) with a nested subvolume for its /etc, and @var and @home, which
# later versions share. Alpine's setup-disk installs the packages and the
# live /etc into it (with BOOTLOADER=none, as a mounted root), then this shim
# writes fstab and /etc/kernel/cmdline (the kernel arguments, but for the
# subvolume), turns mkinitfs's trigger off (the kernel hook builds the
# initramfs instead, before copying it), removes GNOME Software's apk
# plugin, moves /root to /var/roothome, makes the system read-only and runs
# cervino-desktop's update-boot, which puts the kernel on the boot partition
# with Limine and its menu. On UEFI it also adds a boot entry for Limine.
# On a Raspberry Pi the disk is MBR (the firmware starts from its first
# partition), with the firmware's FAT partition first, mounted on
# /boot/firmware, swap only with -s, as Alpine's setup-disk does on the Pi,
# and then the btrfs volume; update-boot puts each version's boot files in
# its own directory there, and config.txt starts the newest (os_prefix). The
# disk the live system started from can be installed to once its modloop is
# copied to RAM, as Alpine's setup-disk offers.
makefile root:root 0755 "$tmp"/usr/local/sbin/setup-disk <<'EOF'
#!/bin/sh
. /usr/lib/libalpine.sh

pi=
grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null && pi=1
stock= crypt= mode= modefile= disks= swap= kflavor= verbose=
parse() {
	while getopts "b:B:hek:Lm:o:qrR:s:vw:" opt; do
		case $opt in
		e) crypt=1 ;;
		m) mode=$OPTARG ;;
		q) QUIET=1 ;;
		s) swap=$OPTARG ;;
		w) modefile=$OPTARG ;;
		k) kflavor=$OPTARG ;;
		v) verbose=1 ;;
		*) stock=1 ;;
		esac
	done
	shift $((OPTIND - 1))
	disks=$*
}
parse "$@"
case $mode in ''|atomic|none) ;; *) stock=1 ;; esac
case $disks in *" "*) stock=1 ;; esac
[ -d "${disks:-/nonexistent}" ] && stock=1
[ -z "$stock" ] || exec /usr/sbin/setup-disk "$@"
[ "$mode" != none ] && [ "$disks" != none ] || exit 0
asked=
if [ -z "$mode" ]; then
	echo
	echo "How would you like to install the system?"
	echo "  atomic  read-only and updated as a whole: an update is a new version of"
	echo "          the system, started with next time, and the earlier versions"
	echo "          stay (one disk, which can be encrypted)"
	echo "  sys     Alpine's standard install, updated in place"
	resp=
	until isin "$resp" atomic sys none; do
		ask "Install as? ('atomic', 'sys' or 'none')" atomic
	done
	[ "$resp" != none ] || exit 0
	mode=$resp asked=1
fi

# Disks with nothing mounted or stacked on them, but optical drives.
find_disks() {
	local p d m
	for p in /sys/block/*/device; do
		d=${p%/device}
		d=${d##*/}
		for m in $(awk '$1 ~ /^\/dev\// { sub("/dev/", "", $1); gsub("/", "!", $1); print $1 }' /proc/mounts); do
			[ "$m" = "$d" ] || [ -e /sys/block/"$d/$m" ] && continue 2
		done
		for m in /sys/block/"$d"/holders/* /sys/block/"$d"/*/holders/*; do
			[ -e "$m" ] && continue 2
		done
		grep -qx 5 /sys/block/"$d"/device/type 2>/dev/null && continue
		printf ' %s' "$d"
	done
}
show_disk_info() {
	local d
	for d; do
		echo "  $d	($(awk '{ printf "%.1f GB", $1 * 512 / 1000000000 }' /sys/block/"$d"/size) $(cat /sys/block/"$d"/device/vendor /sys/block/"$d"/device/model 2>/dev/null | xargs))"
	done
}

# The disk the live system started from (the Pi's SD card, say) can be
# installed to once its modloop is copied to RAM and it is unmounted, as
# Alpine's setup-disk does.
boot_media=$(find_modloop_media 2>/dev/null) || boot_media=
boot_disk=
if [ -n "$boot_media" ]; then
	boot_disk=$(sed -n 's/^DEVNAME=//p' /sys/dev/block/"$(mountpoint -d "$boot_media" | cut -d: -f1)":0/uevent 2>/dev/null)
fi
free_boot_disk() {
	DO_UMOUNT=1 modloop_media=$boot_media copy-modloop || die "could not unmount $boot_media"
	boot_media=
}

if [ -z "$disks" ]; then
	avail=$(find_disks)
	if [ -z "$avail" ] && [ -n "$boot_disk" ] &&
		ask_yesno "No disks available. Try boot media $boot_media? (y/n)" n; then
		free_boot_disk
		avail=$(find_disks)
	fi
	[ -n "$avail" ] || { qecho "No disks found." >&2; exit 0; }
	set -- $avail
	resp=
	until [ "$resp" = none ] || isin "$resp" $avail; do
		echo "Available disks are:"
		show_disk_info $avail
		echo
		ask "Which disk would you like to install to? (or 'none')" "${DEFAULT_DISK:-$1}"
	done
	[ "$resp" != none ] || exit 0
	disks=$resp
fi
disk=$(readlink -f "$disks")
case $disk in /dev/*) ;; *) disk=/dev/$disks ;; esac
d=${disk#/dev/}
[ -e /sys/block/"$d"/device ] || die "$disks is not a disk"
[ -z "$boot_media" ] || [ "$d" != "$boot_disk" ] || free_boot_disk
if [ -n "$asked" ] && [ -z "$crypt" ]; then
	echo
	ask_yesno "Encrypt the disk? Its passphrase will be asked for at every boot. (y/n)" n && crypt=1
fi
# A sys install chosen here goes to Alpine's setup-disk with the disk and
# mode already answered, so it doesn't ask its own question of how to use
# the disk (sys, data, crypt, lvm, ...).
if [ "$mode" = sys ]; then
	exec /usr/sbin/setup-disk -m sys ${crypt:+-e} ${QUIET:+-q} ${verbose:+-v} \
		${kflavor:+-k "$kflavor"} ${swap:+-s "$swap"} ${modefile:+-w "$modefile"} "$disk"
fi
if [ "$ERASE_DISKS" != "$disks" ] && [ "$ERASE_DISKS" != "$disk" ]; then
	echo
	echo "WARNING: The following disk will be erased:"
	show_disk_info "$d"
	echo
	ask_yesno "WARNING: Erase the above disk and continue? (y/n)" n || exit 1
fi
if [ -n "$crypt" ]; then
	echo
	echo "If you forget the passphrase, everything on the disk is lost."
	_ifs=$IFS
	IFS=
	while :; do
		askpass "Passphrase for the disk? (will not echo)"
		pass=$resp
		askpass "Passphrase for the disk? (again)"
		[ -n "$pass" ] && [ "$resp" = "$pass" ] && break
		echo "The passphrases are empty or do not match, try again."
	done
	IFS=$_ifs
fi
[ -z "$modefile" ] || echo sys > "$modefile"

# The boot partition: the EFI system partition, which Limine boots from on
# UEFI and BIOS alike, or on the Pi the firmware's, mounted on /boot/firmware
# as on Raspberry Pi OS.
bootdir=/boot/efi
[ -z "$pi" ] || bootdir=/boot/firmware
mnt=/mnt
cleanup() {
	umount "$mnt$bootdir" "$mnt"/home "$mnt"/var "$mnt" 2>/dev/null
	[ -z "$crypt" ] || cryptsetup close root 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Swap as Alpine's setup-disk sizes it: twice the RAM, but at most a quarter
# of the disk and 4 GiB, and none below 64 MiB; on the Pi none.
[ -z "$pi" ] || swap=${swap:-0}
if [ -z "$swap" ]; then
	swap=$(awk '$1 == "MemTotal:" { print int($2 / 512) }' /proc/meminfo)
	max=$(($(cat /sys/block/"$d"/size) / 8192))
	[ "$swap" -le "$max" ] || swap=$max
	[ "$swap" -le 4096 ] || swap=4096
fi
[ "$swap" -ge 64 ] || swap=0

# The Pi's firmware starts from the first partition of an MBR disk.
dmesg -n1
if [ -n "$pi" ]; then
	{
		echo 'label: dos'
		echo 'size=1GiB, type=c, bootable'
		[ "$swap" = 0 ] || echo "size=${swap}MiB, type=82"
		echo 'type=83'
	}
else
	{
		echo 'label: gpt'
		echo 'size=1MiB, type=21686148-6449-6E6F-744E-656564454649, name="BIOS boot"'
		echo 'size=1GiB, type=U, name="EFI system"'
		[ "$swap" = 0 ] || echo "size=${swap}MiB, type=S, name=\"Swap\""
		echo 'type=L, name="Alpine Linux"'
	}
fi | sfdisk --quiet --wipe always --wipe-partitions always "$disk" || die "could not partition $disk"
# part N: partition N's device, once udev has made it.
part() {
	local _ p
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		for p in /sys/block/"$d"/*/partition; do
			[ "$(cat "$p" 2>/dev/null)" = "$1" ] || continue
			p=/dev/$(basename "${p%/partition}")
			[ -b "$p" ] && { echo "$p"; return 0; }
		done
		udevadm settle 2>/dev/null || sleep 1
	done
	return 1
}
n=2
[ -n "$pi" ] || n=3
espn=$((n - 1))
if [ "$swap" != 0 ]; then
	swappart=$(part $n) || die "the partitions of $disk did not show up"
	n=$((n + 1))
fi
esp=$(part $espn) && rootpart=$(part $n) || die "the partitions of $disk did not show up"

mkfs.vfat -F 32 -n BOOT "$esp" >/dev/null || die "could not format $esp"
dev=$rootpart
if [ -n "$crypt" ]; then
	printf %s "$pass" | cryptsetup luksFormat --batch-mode --type luks2 --key-file=- "$rootpart" &&
		printf %s "$pass" | cryptsetup open --key-file=- "$rootpart" root ||
		die "could not encrypt $rootpart"
	pass=
	dev=/dev/mapper/root
fi
modprobe -q btrfs
mkfs.btrfs -q -f -L alpine "$dev" || die "could not format $dev"
id=$(date -u +%Y%m%d%H%M%S)
mount -t btrfs "$dev" "$mnt" &&
	btrfs -q subvolume create "$mnt"/@var &&
	btrfs -q subvolume create "$mnt"/@home &&
	mkdir "$mnt"/roots &&
	btrfs -q subvolume create "$mnt"/roots/"$id" &&
	btrfs -q subvolume create "$mnt"/roots/"$id"/etc &&
	umount "$mnt" || die "could not create the subvolumes on $dev"
mount -t btrfs -o noatime,subvol=/roots/"$id" "$dev" "$mnt" &&
	mkdir -p "$mnt"/var "$mnt"/home "$mnt$bootdir" &&
	mount -t btrfs -o noatime,subvol=/@var "$dev" "$mnt"/var &&
	mount -t btrfs -o noatime,subvol=/@home "$dev" "$mnt"/home &&
	mount -t vfat "$esp" "$mnt$bootdir" || die "could not mount $dev"

BOOTLOADER=none /usr/sbin/setup-disk ${QUIET:+-q} "$mnt" || exit

uuid=$(blkid -s UUID -o value "$dev")
f=$mnt/etc/fstab
{
	printf 'UUID=%s\t%s\tbtrfs\t%s\t0 0\n' "$uuid" / noatime \
		"$uuid" /var noatime,subvol=/@var "$uuid" /home noatime,subvol=/@home
	printf 'UUID=%s\t%s\tvfat\tnoatime,fmask=0133,dmask=0022\t0 2\n' "$(blkid -s UUID -o value "$esp")" "$bootdir"
	# Swap on an encrypted disk gets a new random key at each boot (from
	# dmcrypt, which runs before swap), so what was swapped out is gone.
	if [ "$swap" = 0 ]; then
		:
	elif [ -n "$crypt" ]; then
		printf '/dev/mapper/swap\tnone\tswap\tdefaults\t0 0\n'
	else
		mkswap -L swap "$swappart" >/dev/null || die "could not format $swappart"
		printf 'UUID=%s\tnone\tswap\tdefaults\t0 0\n' "$(blkid -s UUID -o value "$swappart")"
	fi
	awk -v b="$bootdir" '$2 != "/" && $2 != "/var" && $2 != "/home" && $2 != b && $3 != "swap"' "$f"
} > "$f".new && mv "$f".new "$f" || die "could not write $f"
if [ "$swap" != 0 ] && [ -n "$crypt" ]; then
	printf '\nswap=swap\nsource=/dev/disk/by-partuuid/%s\noptions="-c aes-xts-plain64 -s 512 -d /dev/urandom"\n' \
		"$(blkid -s PARTUUID -o value "$swappart")" >> "$mnt"/etc/conf.d/dmcrypt &&
		ln -sf /etc/init.d/dmcrypt "$mnt"/etc/runlevels/boot/dmcrypt || die "could not set up encrypted swap"
fi

if [ -n "$crypt" ]; then
	cmdline="root=/dev/mapper/root cryptroot=UUID=$(cryptsetup luksUUID "$rootpart") cryptdm=root"
else
	cmdline="root=UUID=$uuid"
fi
modules=sd-mod,usb-storage,btrfs
case $d in nvme*) modules=$modules,nvme ;; esac
[ ! -e /sys/module/vmd ] || modules=$modules,vmd
cmdline="$cmdline rootfstype=btrfs modules=$modules${KERNELOPTS:+ $KERNELOPTS}"
case " $(cat /proc/cmdline) " in *" nomodeset "*) cmdline="nomodeset $cmdline" ;; esac
# A serial console the install runs on is the installed system's too.
tty=$(tty 2>/dev/null)
case $tty in /dev/ttyS[0-9]*)
	case " $cmdline " in *" console=${tty#/dev/} "*|*" console=${tty#/dev/},"*) ;; *)
		cmdline="$cmdline console=${tty#/dev/},$(stty speed < "$tty" 2>/dev/null || echo 115200)" ;;
	esac ;;
esac
mkdir -p "$mnt"/etc/kernel
echo "$cmdline" > "$mnt"/etc/kernel/cmdline
echo disable_trigger=yes >> "$mnt"/etc/mkinitfs/mkinitfs.conf
# GNOME Software cannot install packages into the read-only system: it keeps
# Flatpak, and update-alpine add installs packages.
if mount --bind /proc "$mnt"/proc && mount --bind /dev "$mnt"/dev; then
	apk del --root "$mnt" --quiet gnome-software-plugin-apk2 ||
		echo "GNOME Software's apk plugin could not be removed." >&2
	umount "$mnt"/dev "$mnt"/proc
fi
rm -f "$mnt"/etc/runlevels/default/apk-polkit-server
# Root's home, where root's shell keeps its history, is writable.
mkdir -p "$mnt"/var/roothome &&
	cp -a "$mnt"/root/. "$mnt"/var/roothome/ && chmod 700 "$mnt"/var/roothome &&
	rm -rf "$mnt"/root && ln -s var/roothome "$mnt"/root || die "could not move /root"
btrfs property set -ts "$mnt" ro true || die "could not make the system read-only"
# The Pi's own settings (the lbu shim put them in the system's /boot).
[ -z "$pi" ] || [ ! -f "$mnt"/boot/usercfg.txt ] || cp "$mnt"/boot/usercfg.txt "$mnt$bootdir"/ ||
	die "could not write usercfg.txt"
/usr/libexec/cervino/update-boot "$mnt" || die "could not install the boot loader"

if [ -z "$pi" ] && [ -d /sys/firmware/efi ]; then
	efibootmgr | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\)\*\{0,1\} Alpine Linux\(	.*\)\{0,1\}$/\1/p' |
		while read -r n; do efibootmgr -q -b "$n" -B; done
	efibootmgr -q --create --disk "$disk" --part 2 --loader '\EFI\BOOT\BOOTX64.EFI' --label 'Alpine Linux' ||
		echo "No UEFI boot entry was added; the firmware should still find Limine on $disk." >&2
fi
EOF

rc_add devfs sysinit
rc_add dmesg sysinit
rc_add modloop sysinit
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
