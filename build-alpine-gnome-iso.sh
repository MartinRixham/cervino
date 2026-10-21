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
#   LIVE_PASSWORD   that user's password (default: none; the user logs in,
#                   unlocks the screen and uses doas and polkit without one)
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
LIVE_PASSWORD=${LIVE_PASSWORD-}
AUTOLOGIN=${AUTOLOGIN:-1}
BROWSER=${BROWSER:-firefox}

die() { echo "error: $*" >&2; exit 1; }
# Quote $1 for sh: single quotes, with any ' inside written as '\''.
shquote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

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
		-v "$(dirname "$(realpath "$0")")"/genapkovl-gnomelive.sh:/genapkovl-gnomelive.sh:ro \
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
# Container side: set up the profile + apkovl generator and run mkimage.sh.
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
	# swap, PipeWire, xdg-utils, Flatpak, Alpine's packages in GNOME Software
	# (apk-polkit-server and the AppStream catalog), VA-API (libva with the
	# Mesa, Intel and vainfo packages) and the SPICE guest agent. Their
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
		gnome-software-plugin-flatpak apk-polkit-rs-openrc
		alpine-appstream-downloader libva libva-utils mesa-va-gallium
		intel-media-driver libva-intel-driver spice-vdagent spice-vdagent-openrc"

	local world
	world=$(printf '%s\n' alpine-base doas \
		elogind polkit-elogind "$BROWSER" \
		eudev udev-init-scripts udev-init-scripts-openrc \
		$gnome_deps $features | sort -u)

	# Flatpak adds the remotes in /etc/flatpak/remotes.d (see the generator).
	wget -qO aports/scripts/flathub.flatpakrepo https://dl.flathub.org/repo/flathub.flatpakrepo ||
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
	# genapkovl-gnomelive.sh reads the build settings from the .conf and the
	# Flathub remote from the file next to it.
	printf '%s=%s\n' LIVE_USER "$(shquote "$LIVE_USER")" \
		LIVE_PASSWORD "$(shquote "$LIVE_PASSWORD")" \
		AUTOLOGIN "$(shquote "$AUTOLOGIN")" \
		LSM "$(shquote "$lsm")" \
		WORLD "$(shquote "$world")" > aports/scripts/genapkovl-gnomelive.conf
	install -m 0755 /genapkovl-gnomelive.sh aports/scripts/genapkovl-gnomelive.sh

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
