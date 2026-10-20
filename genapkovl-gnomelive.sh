#!/bin/sh -e
#
# genapkovl-gnomelive.sh: the apkovl generator of the gnomelive mkimage
# profile. build-alpine-gnome-iso.sh copies it into aports/scripts/, with
# genapkovl-gnomelive.conf (the build settings: LIVE_USER, LIVE_PASSWORD,
# AUTOLOGIN, LSM, WORLD) and flathub.flatpakrepo next to it, and mkimage runs
# it with the hostname as its argument.
#
# The runlevels are those the initramfs sets up on the standard ISO, changed
# as setup-desktop gnome would change them: mdev/hwdrivers swapped for udev
# (setup-devd udev), plus cgroups, dbus and gdm in default. The desktop
# features add their services on top.

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

# The default nftables ruleset drops incoming connections; allow SSH and mDNS.
makefile root:root 0644 "$tmp"/etc/nftables.d/50-desktop.nft <<'EOF'
table inet filter {
	chain input {
		tcp dport 22 accept comment "SSH"
		udp dport 5353 accept comment "mDNS"
	}
}
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

# Core dumps go to /var/lib/coredump. lbu.list makes "lbu package" (and
# so setup-disk) take /usr/local/libexec along to installed systems.
makefile root:root 0644 "$tmp"/etc/sysctl.d/50-coredump.conf <<'EOF'
kernel.core_pattern = |/usr/local/libexec/coredump-handler %P %u %s %t
EOF
makefile root:root 0644 "$tmp"/etc/apk/protected_paths.d/lbu.list <<'EOF'
+usr/local/libexec
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
#   back in, and after a few such failures shows no login screen at all.
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
makefile root:root 0644 "$tmp"/etc/xdg/autostart/gnome-shell-compat.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=GNOME Shell compatibility helper
Exec=/usr/local/libexec/gnome-shell-compat
OnlyShowIn=GNOME;
NoDisplay=true
EOF

# The SPICE agent needs uinput.
makefile root:root 0644 "$tmp"/etc/modules-load.d/uinput.conf <<'EOF'
uinput
EOF

makefile root:root 0644 "$tmp"/etc/flatpak/remotes.d/flathub.flatpakrepo \
	< "$here"/flathub.flatpakrepo
# Only flatpak run as root adds those to the system installation; until
# then users see no remotes.
makefile root:root 0755 "$tmp"/etc/local.d/flatpak-remotes.start <<'EOF'
#!/bin/sh
flatpak remotes >/dev/null 2>&1 || true
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
# installed kernel command line to one with AppArmor enabled. An answer
# file passed with -f still overrides these defaults.
# The shims in the temporary directory only need to work until
# setup-alpine sources /etc/profile, which resets PATH; the lbu and
# adduser shims, used after that, live in /usr/local/sbin, which
# /etc/profile puts first.
# Unquoted heredoc: $LSM is filled in here.
makefile root:root 0755 "$tmp"/usr/local/sbin/setup-alpine <<EOF
#!/bin/sh
shim=\$(mktemp -d) || exit
cat > "\$shim"/openrc <<'SHIM'
#!/bin/sh
case "\$1" in
-*) exec /sbin/openrc "\$@" ;;
*) exec /sbin/openrc --no-stop "\$@" ;;
esac
SHIM
for cmd in setup-interfaces setup-dns; do
	printf '#!/bin/sh\necho "%s: skipped, NetworkManager manages the network"\n' \$cmd > "\$shim"/\$cmd
done
chmod +x "\$shim"/*
DEVDOPTS=\${DEVDOPTS:-udev} APKREPOSOPTS=\${APKREPOSOPTS:--c} \\
	USEROPTS=\${USEROPTS:--a -g audio,input,video,netdev,plugdev,lpadmin} \\
	KERNELOPTS=\${KERNELOPTS:-quiet $LSM} \\
	PATH="\$shim:\$PATH" /usr/sbin/setup-alpine "\$@"
rc=\$?
rm -rf "\$shim"
exit \$rc
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
# is the one to log in as.
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
[ -f etc/gdm/custom.conf ] && sed -i '/^AutomaticLogin/d' etc/gdm/custom.conf
[ -f etc/apk/protected_paths.d/lbu.list ] && sed -i '\\:^+home/$LIVE_USER\$:d' etc/apk/protected_paths.d/lbu.list
tar -c --no-recursion -T "\$d"/list -z
EOF

# busybox adduser gives new users /bin/sh; give desktop users bash instead
# (system users, created with -S, and an explicit -s are left alone).
makefile root:root 0755 "$tmp"/usr/local/sbin/adduser <<'EOF'
#!/bin/sh
for a; do
	case $a in -s|-[!-]*S*) exec /usr/sbin/adduser "$@" ;; esac
done
exec /usr/sbin/adduser -s /bin/bash "$@"
EOF

rc_add devfs sysinit
rc_add dmesg sysinit
rc_add modloop sysinit
rc_add udev sysinit
rc_add udev-trigger sysinit
rc_add udev-settle sysinit

rc_add modules boot
rc_add sysctl boot
rc_add hostname boot
rc_add bootmisc boot
rc_add syslog boot
rc_add apparmor boot
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
rc_add local default
rc_add live-user default
rc_add gdm default

rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown

tar -c -C "$tmp" etc usr | gzip -9n > "$HOSTNAME".apkovl.tar.gz
