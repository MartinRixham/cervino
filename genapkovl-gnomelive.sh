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

# apk shows what packages' install scripts print (as "  * " lines, whatever
# --quiet says), and setup-disk's install of the new system prints all the
# GNOME packages' advice (add your user to plugdev, enable openrc-settingsd,
# ...), which this system has already taken. This shim drops those lines
# from that install (apk add --initdb), keeping apk's own messages, errors
# and progress bar: it splits the output at the ESCs the bar is drawn
# with, so the bar is passed on as it is drawn. Other apk runs are left
# alone.
makefile root:root 0755 "$tmp"/usr/local/sbin/apk <<'EOF'
#!/bin/sh
case " $* " in
*" add "*" --initdb "*) ;;
*) exec /sbin/apk "$@" ;;
esac
set -o pipefail
{ /sbin/apk "$@" 2>&1; } | awk 'BEGIN { RS = "\033"; ORS = "" }
	NR > 1 { printf "\033" }
	{ gsub(/  \* [^\n]*\n/, ""); printf "%s", $0; fflush() }'
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
