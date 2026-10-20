#!/usr/bin/env bash
#
# build-alpine-gnome-iso.sh
#
# Builds an x86_64 ISO that is Alpine's "standard" ISO plus everything that
# `setup-desktop gnome` would install and enable, so the live system boots
# straight to the GNOME desktop without running setup-alpine first.
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

	local world
	world=$(printf '%s\n' alpine-base doas \
		elogind polkit-elogind "$BROWSER" \
		eudev udev-init-scripts udev-init-scripts-openrc \
		$gnome_deps | sort -u)

	# --- mkimage profile -----------------------------------------------------
	cat > aports/scripts/mkimg.gnomelive.sh <<-EOF
	profile_gnomelive() {
		profile_standard
		profile_abbrev="gnome"
		title="GNOME Live"
		desc="Alpine standard plus GNOME, booting straight into GDM."
		arch="x86_64"
		apks="\$apks $(echo $world)"
		apkovl="aports/scripts/genapkovl-gnomelive.sh"
		hostname="alpine"
	}
	EOF

	# --- apkovl generator ----------------------------------------------------
	# The runlevels are those the initramfs sets up on the standard ISO,
	# changed as setup-desktop gnome would change them: mdev/hwdrivers swapped
	# for udev (setup-devd udev), plus cgroups, dbus and gdm in default.
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
		cat > "\$3"
		chown "\$1" "\$3"
		chmod "\$2" "\$3"
	}
	rc_add() {
		mkdir -p "\$tmp"/etc/runlevels/"\$2"
		ln -sf /etc/init.d/"\$1" "\$tmp"/etc/runlevels/"\$2"/"\$1"
	}

	mkdir -p "\$tmp"/etc/apk "\$tmp"/etc/init.d "\$tmp"/etc/gdm

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
			adduser -D -s /bin/ash -g "Live User" $LIVE_USER &&
			for g in audio video netdev input wheel; do
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
	# also swaps udev for mdev unless DEVDOPTS says otherwise, and leaves the
	# community repo (where GNOME lives) disabled. This wrapper, found first
	# in PATH, makes those runlevel switches start services without stopping
	# any, keeps udev, which GNOME needs, and defaults community to enabled.
	# An answer file passed with -f still overrides both defaults.
	# setup-disk copies the live /etc to the new system with "lbu package -",
	# and so would carry over the live user (with its known password), its
	# init script and GDM autologin. The lbu shim drops those from the copy;
	# the user created in setup-alpine's user step is the one to log in as.
	mkdir -p "\$tmp"/usr/local/sbin
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
	cat > "\$shim"/lbu <<'SHIM'
	#!/bin/sh
	[ "\$*" = "package -" ] || exec /usr/sbin/lbu "\$@"
	d=\$(mktemp -d) || exit
	trap 'rm -rf "\$d"' EXIT
	/usr/sbin/lbu package - > "\$d"/ovl.tar.gz || exit
	mkdir "\$d"/root
	tar -C "\$d"/root -xzf "\$d"/ovl.tar.gz || exit
	tar -tzf "\$d"/ovl.tar.gz | grep -v -e '^etc/init\.d/live-user\$' -e '^etc/runlevels/[^/]*/live-user\$' > "\$d"/list
	cd "\$d"/root || exit
	strip() { awk "\$@" "\$f" > "\$f".new && cat "\$f".new > "\$f" && rm "\$f".new; }
	for f in etc/passwd etc/passwd- etc/shadow etc/shadow-; do
	[ -f "\$f" ] && strip -F: -v u='$LIVE_USER' '\$1 != u'
	done
	for f in etc/group etc/group-; do
	[ -f "\$f" ] && strip -F: -v OFS=: -v u='$LIVE_USER' '\$1 == u { next } { n = split(\$4, m, ","); \$4 = ""; for (i = 1; i <= n; i++) if (m[i] != u) \$4 = \$4 (\$4 == "" ? "" : ",") m[i]; print }'
	done
	[ -f etc/gdm/custom.conf ] && sed -i '/^AutomaticLogin/d' etc/gdm/custom.conf
	tar -c --no-recursion -T "\$d"/list -z
	SHIM
	chmod +x "\$shim"/openrc "\$shim"/lbu
	DEVDOPTS=\${DEVDOPTS:-udev} APKREPOSOPTS=\${APKREPOSOPTS:--c} \\
		PATH="\$shim:\$PATH" /usr/sbin/setup-alpine "\$@"
	rc=\$?
	rm -rf "\$shim"
	exit \$rc
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

	rc_add firstboot default
	rc_add udev-postmount default
	rc_add cgroups default
	rc_add dbus default
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
