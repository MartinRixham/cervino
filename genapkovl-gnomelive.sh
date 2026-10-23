#!/bin/sh -e
#
# genapkovl-gnomelive.sh: the apkovl generator of the gnomelive mkimage
# profile. build-alpine-gnome-iso.sh copies it into aports/scripts/, with
# genapkovl-gnomelive.conf (the build settings: LIVE_USER, LIVE_PASSWORD,
# AUTOLOGIN, KERNEL_OPTS, WORLD), flathub.flatpakrepo, the repo's AppArmor
# profiles (apparmor.d/) and, for the Raspberry Pi, usercfg.txt next to it,
# and mkimage runs it with the hostname as its argument.
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

# --- Desktop features ---
# Login shells: nano as the default editor, ~/.local/bin first in PATH
# (any existing entry removed, so nested login shells don't add it twice).
makefile root:root 0644 "$tmp"/etc/profile.d/50-editor.sh <<'EOF'
export EDITOR="${EDITOR:-nano}"
EOF
makefile root:root 0644 "$tmp"/etc/profile.d/99-local-bin.sh <<'EOF'
_p=":$PATH:"
while case $_p in *":$HOME/.local/bin:"*) true ;; *) false ;; esac; do
	_p="${_p%%:"$HOME"/.local/bin:*}:${_p#*:"$HOME"/.local/bin:}"
done
_p="${_p#:}"
_p="${_p%:}"
PATH="$HOME/.local/bin${_p:+:$_p}"
export PATH
unset _p
EOF
# command-not-found only installs a hook for login sh; bash sources /etc/bash/*.sh.
mkdir -p "$tmp"/etc/bash
ln -s /etc/profile.d/command-not-found.sh "$tmp"/etc/bash/command-not-found.sh

# Session language when the user has not picked one.
makefile root:root 0644 "$tmp"/etc/locale.conf <<'EOF'
LANG=C.UTF-8
EOF

# New users get bash as their login shell: shadow's useradd (used by
# GNOME Settings) reads this; setup-user's busybox adduser goes through
# the shim in /usr/local/sbin below.
makefile root:root 0644 "$tmp"/etc/default/useradd <<'EOF'
SHELL=/bin/bash
EOF
# Only the owner (and root) can read a new user's home directory: useradd
# creates it with HOME_MODE (the rest is Alpine's login.defs); the adduser
# shim below does the same for busybox adduser, which has no such setting.
makefile root:root 0644 "$tmp"/etc/login.defs <<'EOF'
USERGROUPS_ENAB yes
UID_MIN 1000
HOME_MODE 0700
EOF

# NetworkManager manages all interfaces; ifupdown only brings up lo.
makefile root:root 0644 "$tmp"/etc/NetworkManager/conf.d/10-alpine.conf <<'EOF'
[main]
dhcp=internal
plugins=keyfile
EOF
makefile root:root 0644 "$tmp"/etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback
iface lo inet6 loopback
EOF

# The default nftables ruleset drops incoming connections; allow SSH and
# mDNS. It also drops all forwarded traffic, which would cut containers
# (Docker, Podman, LXC/Incus) and VMs (libvirt) on their NAT bridges off
# the network whatever rules they add in their own tables: let traffic from
# their bridges out and the replies back in. Drop IPv6 packets from source
# addresses the host has no route back to, as spoofed, before any input or
# forward rule sees them; Neighbor Discovery is exempt (DAD's solicits come
# from ::). IPv4 has the kernel's rp_filter.
makefile root:root 0644 "$tmp"/etc/nftables.d/50-desktop.nft <<'EOF'
table inet filter {
	chain rpfilter {
		type filter hook prerouting priority filter + 10; policy accept;
		icmpv6 type { nd-router-advert, nd-neighbor-solicit } accept
		meta nfproto ipv6 fib saddr . mark oif missing drop comment "IPv6 reverse path filter"
	}
	chain input {
		tcp dport 22 accept comment "SSH"
		udp dport 5353 accept comment "mDNS"
	}
	chain forward {
		ct state { established, related } accept comment "Replies"
		ct state invalid drop comment "Drop invalid connections"
		iifname "virbr*" accept comment "libvirt"
		iifname "docker*" accept comment "Docker"
		iifname "br-*" accept comment "Docker networks"
		iifname "podman*" accept comment "Podman"
		iifname "cni-*" accept comment "CNI"
		iifname "lxcbr*" accept comment "LXC"
		iifname "lxdbr*" accept comment "LXD"
		iifname "incusbr*" accept comment "Incus"
	}
}
EOF

# sshd (installed, not enabled) serves sftp with the external sftp-server,
# which runs as the user outside sshd's AppArmor profile: Alpine's default,
# internal-sftp, runs in sshd itself, whose profile would then have to let it
# at every file. The first Subsystem line wins, and sshd_config includes
# sshd_config.d before its own.
makefile root:root 0644 "$tmp"/etc/ssh/sshd_config.d/50-sftp.conf <<'EOF'
Subsystem sftp /usr/lib/ssh/sftp-server
EOF

# busybox syslogd rotates /var/log/messages itself, by default at 200 KiB
# with one old file, which a busy desktop fills in minutes: keep 5 x 8 MiB.
# It runs under its AppArmor profile (see AppArmor below).
makefile root:root 0644 "$tmp"/etc/conf.d/syslog <<'EOF'
SYSLOGD_OPTS="-t -s 8192 -b 4"
apparmor_profile=busybox-syslogd
. /usr/local/libexec/apparmor-start.sh
EOF

# The kernel sets the system clock from the hardware clock as it finds it,
# and chrony keeps it right from then on, so hwclock need not set it again
# (hwclock --systz, which the init script always runs, still corrects for a
# hardware clock that keeps local time). Setting it waits for the clock's
# update interrupt, which some VMs never raise: 10 s, then an error. The
# file stays plain assignments: openrc-settingsd rewrites clock= in it.
makefile root:root 0644 "$tmp"/etc/conf.d/hwclock <<'EOF'
clock="UTC"
clock_hctosys="NO"
EOF

# SSDs need to be told which blocks are free; trim mounted file systems
# weekly (crond, which setup-alpine enables, runs /etc/periodic).
makefile root:root 0755 "$tmp"/etc/periodic/weekly/fstrim <<'EOF'
#!/bin/sh
exec fstrim -a -q
EOF

# zram swap of half the RAM, at most 8 GiB (the init script sources this).
makefile root:root 0644 "$tmp"/etc/conf.d/zram-init <<'EOF'
load_on_start=yes
unload_on_stop=yes
num_devices=1
type0=swap
size0=$(awk '/^MemTotal:/ { s = int($2 / 2048); print (s > 8192 ? 8192 : s) }' /proc/meminfo)
algo0=zstd
labl0=zram_swap
EOF

# Core dumps go to /var/lib/coredump and are deleted after a week. lbu.list
# makes "lbu package" (and so setup-disk) take /usr/local/libexec along to
# installed systems.
makefile root:root 0644 "$tmp"/etc/sysctl.d/50-coredump.conf <<'EOF'
kernel.core_pattern = |/usr/local/libexec/coredump-handler %P %u %s %t
EOF
makefile root:root 0644 "$tmp"/etc/apk/protected_paths.d/lbu.list <<'EOF'
+usr/local/libexec
+usr/share/gdm/greeter/autostart/gnome-shell-compat.desktop
EOF
makefile root:root 0755 "$tmp"/usr/local/libexec/coredump-handler <<'EOF'
#!/bin/sh
# Invoked by the kernel via core_pattern with: %P %u %s %t
pid=$1 uid=$2 sig=$3 time=$4
dir=/var/lib/coredump
max_files=20
max_bytes=2147483648

umask 077
mkdir -p "$dir"
comm=$(tr -cd 'A-Za-z0-9_.-' < "/proc/$pid/comm" 2>/dev/null)
out="$dir/core.${comm:-unknown}.$uid.$pid.$time"

if command -v zstd >/dev/null 2>&1; then
	out=$out.zst
	head -c "$max_bytes" | zstd -q -o "$out"
else
	head -c "$max_bytes" > "$out"
fi
logger -t coredump "Process $pid (${comm:-unknown}) of user $uid dumped core on signal $sig: $out"

ls -1t "$dir"/core.* 2>/dev/null | tail -n +$((max_files + 1)) | xargs -r rm -f
find "$dir" -name 'core.*' -mtime +7 -delete
EOF
# Dumps also expire when no new crash comes along to prune them.
makefile root:root 0755 "$tmp"/etc/periodic/daily/coredump-cleanup <<'EOF'
#!/bin/sh
[ -d /var/lib/coredump ] || exit 0
exec find /var/lib/coredump -name 'core.*' -mtime +7 -delete
EOF

# AppArmor: profiles (from the repo's apparmor.d) for system daemons;
# Alpine's apparmor-profiles has Avahi's.
# AppArmor loads them in sysinit, before udev starts, so that
# udevd runs under its profile too.
for f in "$here"/apparmor.d/*; do
	makefile root:root 0644 "$tmp"/etc/apparmor.d/"${f##*/}" < "$f"
done
makefile root:root 0644 "$tmp"/etc/conf.d/apparmor <<'EOF'
rc_need="sysfs"
rc_before="udev"
EOF
# A profile attaches to a program by its path, which does not tell busybox
# applets (syslogd, crond, acpid, getty) from one another, or the system
# bus's dbus-daemon from the session buses'. Those are started under their
# profile by name, through this wrapper: from their conf.d files, which
# replace OpenRC's start with apparmor-start.sh's, and from /etc/inittab.
makefile root:root 0755 "$tmp"/usr/local/libexec/apparmor-exec <<'EOF'
#!/bin/sh
# apparmor-exec PROFILE COMMAND [ARG...]: runs COMMAND under the AppArmor
# profile PROFILE, or unconfined when that profile is not loaded (AppArmor
# turned off, or the profile removed).
profile=$1
shift
if grep -qs "^$profile (" /sys/kernel/security/apparmor/profiles; then
	exec aa-exec -p "$profile" -- "$@"
fi
exec "$@"
EOF
makefile root:root 0644 "$tmp"/usr/local/libexec/apparmor-start.sh <<'EOF'
# Sourced by a service's conf.d file, which sets apparmor_profile: OpenRC's
# start, which the init script does not override, runs the daemon through
# apparmor-exec.
start() {
	local daemon="$command"
	command_args="$apparmor_profile $command $command_args"
	command=/usr/local/libexec/apparmor-exec
	default_start || return
	# stop looks for the daemon, not for the wrapper.
	service_set_value command "$daemon"
}
EOF
makefile root:root 0644 "$tmp"/etc/conf.d/crond <<'EOF'
CRON_OPTS="-c /etc/crontabs"
apparmor_profile=busybox-crond
. /usr/local/libexec/apparmor-start.sh
EOF
makefile root:root 0644 "$tmp"/etc/conf.d/acpid <<'EOF'
apparmor_profile=busybox-acpid
. /usr/local/libexec/apparmor-start.sh
EOF
makefile root:root 0644 "$tmp"/etc/conf.d/dbus <<'EOF'
apparmor_profile=dbus-system
. /usr/local/libexec/apparmor-start.sh
EOF
# alpine-baselayout's inittab, with the gettys started through the wrapper.
# The initramfs adds a plain getty for a serial console it finds; the lbu
# shim below wraps that one on installed systems.
makefile root:root 0644 "$tmp"/etc/inittab <<'EOF'
# /etc/inittab

::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

# Set up a couple of getty's
tty1::respawn:/usr/local/libexec/apparmor-exec busybox-getty /sbin/getty 38400 tty1
tty2::respawn:/usr/local/libexec/apparmor-exec busybox-getty /sbin/getty 38400 tty2
tty3::respawn:/usr/local/libexec/apparmor-exec busybox-getty /sbin/getty 38400 tty3
tty4::respawn:/usr/local/libexec/apparmor-exec busybox-getty /sbin/getty 38400 tty4
tty5::respawn:/usr/local/libexec/apparmor-exec busybox-getty /sbin/getty 38400 tty5
tty6::respawn:/usr/local/libexec/apparmor-exec busybox-getty /sbin/getty 38400 tty6

# Put a getty on the serial port
#ttyS0::respawn:/usr/local/libexec/apparmor-exec busybox-getty /sbin/getty -L 115200 ttyS0 vt100

# Stuff to do for the 3-finger salute
::ctrlaltdel:/sbin/reboot

# Stuff to do before rebooting
::shutdown:/sbin/openrc shutdown
EOF

# Alpine's gnome-shell (50) is newer than its gnome-session and GDM (48), and
# misses two of their protocols, so this session helper stands in for it:
# - it registers with gnome-session as a client (so that gnome-session, run
#   without systemd, knows the shell is up) but never answers its
#   QueryEndSession and EndSession signals, so every logout waits for the
#   shell, listed as "Not responding".
# - it calls GDM's RegisterSession without the a{sv} argument GDM 48 expects,
#   so the call fails. GDM then takes the end of every session for a failure
#   ("Session never registered, failing"): it logs the autologin user straight
#   back in, and after a few such failures shows no login screen at all. The
#   login screen's own session is no different: when a user logs in through
#   it, GDM restarts the "failed" login screen, which takes the seat from the
#   new session and dies, until GDM gives up and the screen stays frozen.
# The login screen's gnome-session only autostarts what is in GDM's greeter
# directory, so the helper is listed there too; lbu.list takes that along to
# installed systems.
makefile root:root 0755 "$tmp"/usr/local/libexec/gnome-shell-compat <<'EOF'
#!/usr/bin/gjs
// Registers the session with GDM and answers gnome-session's end-of-session
// queries on behalf of GNOME Shell
const {Gio, GLib} = imports.gi;
const bus = Gio.DBus.session;
const SM = 'org.gnome.SessionManager';
const SHELL_APP_ID = 'org.gnome.Shell.desktop';

function call(path, iface, method, args = null, ret = null) {
    return bus.call_sync(SM, path, iface, method, args,
        ret ? new GLib.VariantType(ret) : null, Gio.DBusCallFlags.NONE, 5000, null).deepUnpack();
}

// GDM finds the display from the caller's login session, which is this one.
Gio.DBus.system.call('org.gnome.DisplayManager', '/org/gnome/DisplayManager/Manager',
    'org.gnome.DisplayManager.Manager', 'RegisterSession', new GLib.Variant('(a{sv})', [{}]),
    null, Gio.DBusCallFlags.NONE, -1, null, (conn, res) => {
        try {
            conn.call_finish(res);
        } catch (e) {
            logError(e, 'registering the session with GDM');
        }
    });

bus.signal_subscribe(SM, `${SM}.ClientPrivate`, null, null, null, Gio.DBusSignalFlags.NONE,
    (_c, _sender, path, _iface, signal) => {
        if (signal !== 'QueryEndSession' && signal !== 'EndSession')
            return;
        try {
            const [appId] = call(path, `${SM}.Client`, 'GetAppId', null, '(s)');
            if (appId === SHELL_APP_ID) {
                call(path, `${SM}.ClientPrivate`, 'EndSessionResponse',
                    new GLib.Variant('(bs)', [true, '']));
            }
        } catch (e) {
            logError(e, `answering ${signal} for ${path}`);
        }
    });

new GLib.MainLoop(null, false).run();
EOF
for dir in etc/xdg/autostart usr/share/gdm/greeter/autostart; do
	makefile root:root 0644 "$tmp"/$dir/gnome-shell-compat.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=GNOME Shell compatibility helper
Exec=/usr/local/libexec/gnome-shell-compat
OnlyShowIn=GNOME;
NoDisplay=true
EOF
done

# The SPICE agent needs uinput.
makefile root:root 0644 "$tmp"/etc/modules-load.d/uinput.conf <<'EOF'
uinput
EOF
# spice-vdagentd blocks writing to its virtio port while nothing on the host
# reads it (no SPICE client), and then ignores SIGTERM: kill it after 5 s,
# and remove the socket it then leaves behind, or it cannot start again.
# Only a VM with a SPICE channel has the agent's virtio port (udev-settle
# has created it by the default runlevel): anywhere else the daemon has
# nothing to do, so the service is left inactive instead of started.
makefile root:root 0644 "$tmp"/etc/conf.d/spice-vdagentd <<'EOF'
spice_port=/dev/virtio-ports/com.redhat.spice.0
retry="TERM/5/KILL/5"
start() {
	if [ ! -e "$spice_port" ]; then
		einfo "No SPICE channel, not starting ${name:-$RC_SVCNAME}"
		mark_service_inactive
		return 0
	fi
	default_start
}
stop() {
	[ -e "$spice_port" ] || return 0
	default_stop
}
stop_post() {
	rm -f /run/spice-vdagentd/spice-vdagent-sock
}
EOF

makefile root:root 0644 "$tmp"/etc/flatpak/remotes.d/flathub.flatpakrepo \
	< "$here"/flathub.flatpakrepo
# Only flatpak run as root adds those to the system installation; until
# then users see no remotes.
makefile root:root 0755 "$tmp"/etc/local.d/flatpak-remotes.start <<'EOF'
#!/bin/sh
flatpak remotes >/dev/null 2>&1 || true
EOF

# GNOME Software lists Alpine's packages from the AppStream catalog of the
# repositories in /etc/apk/repositories, which nothing fetches by default.
# Fetch it daily (setup-alpine enables crond) and whenever a connection
# comes up; only what changed is downloaded.
makefile root:root 0755 "$tmp"/etc/periodic/daily/alpine-appstream <<'EOF'
#!/bin/sh
# NetworkManager's dispatcher runs this without /usr/sbin in PATH.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
exec flock -n /run/alpine-appstream.lock alpine-appstream-downloader >/dev/null 2>&1
EOF
makefile root:root 0755 "$tmp"/etc/NetworkManager/dispatcher.d/50-alpine-appstream <<'EOF'
#!/bin/sh
[ "$2" = up ] || exit 0
setsid /etc/periodic/daily/alpine-appstream </dev/null >/dev/null 2>&1 &
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
[ -f etc/inittab ] && sed -i 's|:/sbin/getty |:/usr/local/libexec/apparmor-exec busybox-getty /sbin/getty |' etc/inittab
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
