#!/usr/bin/env bash
#
# build-alpine-gnome-iso.sh
#
# Builds an x86_64 ISO that is Alpine's "standard" ISO plus everything that
# `setup-desktop gnome` would install and enable, so the live system boots
# straight to the GNOME desktop without running setup-alpine first. On top
# of that it adds and configures what os-feature-tests.sh expects of a
# desktop (bash, NetworkManager, PipeWire, CUPS, AppArmor, Flatpak, ...),
# both on the live system and on systems installed from it.
#
# Uses Alpine's own image tooling (aports/scripts/mkimage.sh) with a custom
# profile that extends profile_standard, run inside an Alpine container, so
# the host only needs podman or docker.
#
# How it works: the GNOME packages (with all dependencies) are added to the
# ISO's on-disc apk repository, and an apkovl (the same overlay mechanism
# `lbu` uses) is placed on the ISO. At boot the initramfs unpacks the apkovl
# and installs everything in its /etc/apk/world from the disc into the RAM
# root, then OpenRC starts udev, dbus, gdm etc. exactly as setup-desktop
# would have configured them.
#
# Usage:
#   ./build-alpine-gnome-iso.sh
#
# Environment overrides:
#   ALPINE_BRANCH   Alpine release branch, e.g. v3.24 (default: latest-stable)
#   OUTDIR          where the ISO is written (default: ./out)
#   LIVE_USER       desktop user created on boot (default: alpine)
#   LIVE_PASSWORD   that user's password (default: alpine)
#   AUTOLOGIN       0 to stop at the GDM login screen instead of logging
#                   LIVE_USER straight in to GNOME (default: 1)
#   BROWSER         browser package, as setup-desktop (default: firefox)
#   CONTAINER       container runtime to use (default: podman, else docker)
#
# Note: the live system runs entirely from RAM (tmpfs), so booting the
# resulting ISO needs roughly 6 GB of RAM or more.

set -euo pipefail

ARCH=x86_64
MIRROR=${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
LIVE_USER=${LIVE_USER:-alpine}
LIVE_PASSWORD=${LIVE_PASSWORD:-alpine}
AUTOLOGIN=${AUTOLOGIN:-1}
BROWSER=${BROWSER:-firefox}

die() { echo "error: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Host side: work out the release, then re-run this script in a container.
# ---------------------------------------------------------------------------
host_main() {
	local runtime=${CONTAINER:-}
	if [[ -z $runtime ]]; then
		if command -v podman >/dev/null; then runtime=podman
		elif command -v docker >/dev/null; then runtime=docker
		else die "need podman or docker"
		fi
	fi

	if [[ -z ${ALPINE_BRANCH:-} ]]; then
		ALPINE_BRANCH=$(curl -fsSL "$MIRROR/latest-stable/releases/$ARCH/latest-releases.yaml" |
			awk '/branch:/ { print $2; exit }') ||
			die "could not determine latest Alpine release; set ALPINE_BRANCH"
	fi
	[[ $ALPINE_BRANCH =~ ^v[0-9]+\.[0-9]+$ ]] || die "bad ALPINE_BRANCH: $ALPINE_BRANCH"

	OUTDIR=$(realpath -m "${OUTDIR:-./out}")
	mkdir -p "$OUTDIR"

	echo ">>> Building Alpine ${ALPINE_BRANCH#v} GNOME live ISO with $runtime"
	# On SELinux hosts, disable confinement for this container rather than
	# relabelling the volumes with :Z: a container-private label on $OUTDIR
	# stops libvirt's qemu from opening the ISO in it.
	"$runtime" run --rm \
		--security-opt label=disable \
		-v "$(realpath "$0")":/build.sh:ro \
		-v "$OUTDIR":/out \
		-e ALPINE_BRANCH="$ALPINE_BRANCH" \
		-e MIRROR="$MIRROR" \
		-e LIVE_USER="$LIVE_USER" \
		-e LIVE_PASSWORD="$LIVE_PASSWORD" \
		-e AUTOLOGIN="$AUTOLOGIN" \
		-e BROWSER="$BROWSER" \
		"docker.io/library/alpine:${ALPINE_BRANCH#v}" \
		sh -c 'apk add --quiet bash && exec bash /build.sh --in-container'

	echo ">>> Done:"
	ls -lh "$OUTDIR"/*.iso
}

# ---------------------------------------------------------------------------
# Container side: generate the profile + apkovl and run mkimage.sh.
# ---------------------------------------------------------------------------
container_main() {
	printf '%s\n' "$MIRROR/$ALPINE_BRANCH/main" "$MIRROR/$ALPINE_BRANCH/community" \
		> /etc/apk/repositories
	apk update --quiet
	apk add --quiet alpine-sdk alpine-conf apk-tools busybox fakeroot \
		syslinux xorriso squashfs-tools mtools dosfstools grub grub-efi git

	# mkimage must run unprivileged: apk 3 rejects its --no-chown as root.
	adduser -D build
	addgroup build abuild
	mkdir -p /work
	chown build:build /work

	# mkimage signs the ISO's apk index; the public key ends up in the image.
	# (-i would shell out to doas/sudo, so install the key by hand.)
	su build -s /bin/bash -c 'abuild-keygen -a -n'
	cp /home/build/.abuild/*.rsa.pub /etc/apk/keys/

	su build -s /bin/bash -c 'bash /build.sh --as-builder'
	cp /work/iso/*.iso /out/
}

builder_main() {
	local repo_main="$MIRROR/$ALPINE_BRANCH/main"
	local repo_community="$MIRROR/$ALPINE_BRANCH/community"
	local aports_branch="${ALPINE_BRANCH#v}-stable"

	cd /work
	# gitlab.alpinelinux.org rejects many datacenter IPs (HTTP 418, e.g. on
	# GitHub Actions runners), so fall back to the official GitHub mirror.
	local url
	for url in https://gitlab.alpinelinux.org/alpine/aports.git \
		https://github.com/alpinelinux/aports.git; do
		rm -rf aports
		git clone --quiet --depth 1 --filter=blob:none --sparse \
			--branch "$aports_branch" "$url" aports && break
		echo ">>> clone from $url failed" >&2
	done
	[[ -d aports/.git ]] || die "could not clone aports"
	git -C aports sparse-checkout set scripts

	# --- What setup-desktop gnome installs -----------------------------------
	#   setup-wayland-base: elogind polkit-elogind $BROWSER
	#   setup-devd udev:    eudev udev-init-scripts udev-init-scripts-openrc
	#   gnome:              apk add $(apk info --quiet --depends gnome gnome-apps-core)
	local gnome_deps
	gnome_deps=$(apk info --quiet --depends gnome gnome-apps-core |
		sed -e 's/[<>=~].*//' | grep -v '^$' | sort -u)
	[[ -n $gnome_deps ]] || die "could not resolve gnome dependencies"

	# --- Desktop features on top of that ------------------------------------
	# What os-feature-tests.sh checks for: a full shell and the usual CLI
	# tools, man pages, a UTF-8 locale, spell checking, emoji and CJK fonts,
	# NetworkManager, NTP, the hostname1/timedate1/locale1 D-Bus services,
	# Bluetooth, printing, mDNS, a firewall, power profiles, AppArmor, zram
	# swap, PipeWire, xdg-utils, Flatpak and the SPICE guest agent. Their
	# configuration and services are set up in the apkovl below.
	# pipewire-pulse provides the pulseaudio that gnome-settings-daemon
	# depends on, so PulseAudio itself is not installed.
	local features="bash bash-completion file xz zstd pciutils dmidecode rsync
		mandoc mandoc-apropos mandoc-doc man-pages command-not-found nano
		musl-locales musl-locales-lang hunspell-en font-noto-emoji font-noto-cjk
		networkmanager networkmanager-cli networkmanager-wifi chrony
		openrc-settingsd bluez cups cups-client cups-filters avahi avahi-tools
		nftables power-profiles-daemon apparmor apparmor-utils apparmor-profiles
		zram-init zram-init-openrc pipewire wireplumber pipewire-pulse
		pipewire-alsa pipewire-spa-bluez xdg-utils flatpak
		gnome-software-plugin-flatpak spice-vdagent spice-vdagent-openrc"

	local world
	world=$(printf '%s\n' alpine-base doas \
		elogind polkit-elogind "$BROWSER" \
		eudev udev-init-scripts udev-init-scripts-openrc \
		$gnome_deps $features | sort -u)

	# Flatpak adds the remotes in /etc/flatpak/remotes.d (see local.d below).
	wget -qO /work/flathub.flatpakrepo https://dl.flathub.org/repo/flathub.flatpakrepo ||
		die "could not download the Flathub remote"

	# AppArmor is built into the kernel but needs enabling on the command line,
	# both on the ISO and (through setup-disk's KERNELOPTS) on installs.
	local lsm="lsm=landlock,lockdown,yama,loadpin,safesetid,integrity,apparmor"

	# --- mkimage profile -----------------------------------------------------
	cat > aports/scripts/mkimg.gnomelive.sh <<-EOF
	profile_gnomelive() {
		profile_standard
		profile_abbrev="gnome"
		title="GNOME Live"
		desc="Alpine standard plus GNOME, booting straight into GDM."
		arch="x86_64"
		kernel_cmdline="\$kernel_cmdline $lsm"
		apks="\$apks $(echo $world)"
		apkovl="aports/scripts/genapkovl-gnomelive.sh"
		hostname="alpine"
	}
	EOF

	# --- apkovl generator ----------------------------------------------------
	# The runlevels are those the initramfs sets up on the standard ISO,
	# changed as setup-desktop gnome would change them: mdev/hwdrivers swapped
	# for udev (setup-devd udev), plus cgroups, dbus and gdm in default. The
	# desktop features add their services on top.
	local autologin_conf=""
	if [[ $AUTOLOGIN == 1 ]]; then
		autologin_conf="AutomaticLoginEnable=True
AutomaticLogin=$LIVE_USER"
	fi

	cat > aports/scripts/genapkovl-gnomelive.sh <<-GENEOF
	#!/bin/sh -e
	HOSTNAME="\$1"
	[ -n "\$HOSTNAME" ] || { echo "usage: \$0 hostname"; exit 1; }

	tmp="\$(mktemp -d)"
	trap 'rm -rf "\$tmp"' EXIT

	makefile() {
		mkdir -p "\$(dirname "\$3")"
		cat > "\$3"
		chown "\$1" "\$3"
		chmod "\$2" "\$3"
	}
	rc_add() {
		mkdir -p "\$tmp"/etc/runlevels/"\$2"
		ln -sf /etc/init.d/"\$1" "\$tmp"/etc/runlevels/"\$2"/"\$1"
	}

	makefile root:root 0644 "\$tmp"/etc/hostname <<EOF
	localhost
	EOF

	makefile root:root 0644 "\$tmp"/etc/apk/world <<EOF
	$world
	EOF

	makefile root:root 0644 "\$tmp"/etc/gdm/custom.conf <<EOF
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
	makefile root:root 0644 "\$tmp"/etc/profile.d/50-editor.sh <<'EOF'
	export EDITOR="\${EDITOR:-nano}"
	EOF
	makefile root:root 0644 "\$tmp"/etc/profile.d/99-local-bin.sh <<'EOF'
	_p=":\$PATH:"
	while case \$_p in *":\$HOME/.local/bin:"*) true ;; *) false ;; esac; do
	_p="\${_p%%:"\$HOME"/.local/bin:*}:\${_p#*:"\$HOME"/.local/bin:}"
	done
	_p="\${_p#:}"
	_p="\${_p%:}"
	PATH="\$HOME/.local/bin\${_p:+:\$_p}"
	export PATH
	unset _p
	EOF
	# command-not-found only installs a hook for login sh; bash sources /etc/bash/*.sh.
	mkdir -p "\$tmp"/etc/bash
	ln -s /etc/profile.d/command-not-found.sh "\$tmp"/etc/bash/command-not-found.sh

	# Session language when the user has not picked one.
	makefile root:root 0644 "\$tmp"/etc/locale.conf <<EOF
	LANG=C.UTF-8
	EOF

	# New users get bash as their login shell: shadow's useradd (used by
	# GNOME Settings) reads this; setup-user's busybox adduser goes through
	# the shim in /usr/local/sbin below.
	makefile root:root 0644 "\$tmp"/etc/default/useradd <<EOF
	SHELL=/bin/bash
	EOF

	# NetworkManager manages all interfaces; ifupdown only brings up lo.
	makefile root:root 0644 "\$tmp"/etc/NetworkManager/conf.d/10-alpine.conf <<EOF
	[main]
	dhcp=internal
	plugins=keyfile
	EOF
	makefile root:root 0644 "\$tmp"/etc/network/interfaces <<EOF
	auto lo
	iface lo inet loopback
	iface lo inet6 loopback
	EOF

	# The default nftables ruleset drops incoming connections; allow SSH and mDNS.
	makefile root:root 0644 "\$tmp"/etc/nftables.d/50-desktop.nft <<EOF
	table inet filter {
	chain input {
	tcp dport 22 accept comment "SSH"
	udp dport 5353 accept comment "mDNS"
	}
	}
	EOF

	# zram swap of half the RAM, at most 8 GiB (the init script sources this).
	makefile root:root 0644 "\$tmp"/etc/conf.d/zram-init <<'EOF'
	load_on_start=yes
	unload_on_stop=yes
	num_devices=1
	type0=swap
	size0=\$(awk '/^MemTotal:/ { s = int(\$2 / 2048); print (s > 8192 ? 8192 : s) }' /proc/meminfo)
	algo0=zstd
	labl0=zram_swap
	EOF

	# Core dumps go to /var/lib/coredump. lbu.list makes "lbu package" (and
	# so setup-disk) take /usr/local/libexec along to installed systems.
	makefile root:root 0644 "\$tmp"/etc/sysctl.d/50-coredump.conf <<EOF
	kernel.core_pattern = |/usr/local/libexec/coredump-handler %P %u %s %t
	EOF
	makefile root:root 0644 "\$tmp"/etc/apk/protected_paths.d/lbu.list <<EOF
	+usr/local/libexec
	EOF
	makefile root:root 0755 "\$tmp"/usr/local/libexec/coredump-handler <<'EOF'
	#!/bin/sh
	# Invoked by the kernel via core_pattern with: %P %u %s %t
	pid=\$1 uid=\$2 sig=\$3 time=\$4
	dir=/var/lib/coredump
	max_files=20
	max_bytes=2147483648

	umask 077
	mkdir -p "\$dir"
	comm=\$(tr -cd 'A-Za-z0-9_.-' < "/proc/\$pid/comm" 2>/dev/null)
	out="\$dir/core.\${comm:-unknown}.\$uid.\$pid.\$time"

	if command -v zstd >/dev/null 2>&1; then
	out=\$out.zst
	head -c "\$max_bytes" | zstd -q -o "\$out"
	else
	head -c "\$max_bytes" > "\$out"
	fi
	logger -t coredump "Process \$pid (\${comm:-unknown}) of user \$uid dumped core on signal \$sig: \$out"

	ls -1t "\$dir"/core.* 2>/dev/null | tail -n +\$((max_files + 1)) | xargs -r rm -f
	EOF

	# The SPICE agent needs uinput.
	makefile root:root 0644 "\$tmp"/etc/modules-load.d/uinput.conf <<EOF
	uinput
	EOF

	makefile root:root 0644 "\$tmp"/etc/flatpak/remotes.d/flathub.flatpakrepo \\
		< /work/flathub.flatpakrepo
	# Only flatpak run as root adds those to the system installation; until
	# then users see no remotes.
	makefile root:root 0755 "\$tmp"/etc/local.d/flatpak-remotes.start <<EOF
	#!/bin/sh
	flatpak remotes >/dev/null 2>&1 || true
	EOF

	# Stands in for setup-user: creates the desktop user before GDM starts.
	makefile root:root 0755 "\$tmp"/etc/init.d/live-user <<'EOF'
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
			echo '$LIVE_USER:$LIVE_PASSWORD' | chpasswd
			mkdir -p /etc/doas.d
			echo 'permit persist :wheel' > /etc/doas.d/20-wheel.conf
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
	makefile root:root 0755 "\$tmp"/usr/local/sbin/setup-alpine <<'EOF'
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
		KERNELOPTS=\${KERNELOPTS:-quiet $lsm} \\
		PATH="\$shim:\$PATH" /usr/sbin/setup-alpine "\$@"
	rc=\$?
	rm -rf "\$shim"
	exit \$rc
	EOF

	# setup-disk copies the live /etc to the new system with "lbu package -",
	# and so would carry over the live user (with its known password), its
	# home directory (setup-alpine adds every /home/* to lbu), its init script
	# and GDM autologin. This shim drops those from the copy; the user created
	# in setup-alpine's user step is the one to log in as.
	makefile root:root 0755 "\$tmp"/usr/local/sbin/lbu <<'EOF'
	#!/bin/sh
	[ "\$*" = "package -" ] || exec /usr/sbin/lbu "\$@"
	d=\$(mktemp -d) || exit
	trap 'rm -rf "\$d"' EXIT
	/usr/sbin/lbu package - > "\$d"/ovl.tar.gz || exit
	mkdir "\$d"/root
	tar -C "\$d"/root -xzf "\$d"/ovl.tar.gz || exit
	tar -tzf "\$d"/ovl.tar.gz | grep -v -e '^etc/init\.d/live-user\$' -e '^etc/runlevels/[^/]*/live-user\$' \\
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
	makefile root:root 0755 "\$tmp"/usr/local/sbin/adduser <<'EOF'
	#!/bin/sh
	for a; do
	case \$a in -s|-[!-]*S*) exec /usr/sbin/adduser "\$@" ;; esac
	done
	exec /usr/sbin/adduser -s /bin/bash "\$@"
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

	tar -c -C "\$tmp" etc usr | gzip -9n > "\$HOSTNAME".apkovl.tar.gz
	GENEOF
	chmod +x aports/scripts/genapkovl-gnomelive.sh

	# --- build ---------------------------------------------------------------
	sh aports/scripts/mkimage.sh \
		--tag "$(cat /etc/alpine-release)" \
		--outdir /work/iso \
		--workdir /work/mkimage \
		--arch "$ARCH" \
		--repository "$repo_main" \
		--repository "$repo_community" \
		--profile gnomelive
}

if [[ ${1:-} == --in-container ]]; then
	container_main
elif [[ ${1:-} == --as-builder ]]; then
	builder_main
else
	host_main
fi
