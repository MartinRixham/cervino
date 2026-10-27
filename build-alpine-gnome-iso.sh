#!/usr/bin/env bash
# Package lists are words in a string, split where they are used.
# PKGVER comes from the host, through the container's environment.
# shellcheck disable=SC2086,SC2046,SC2116,SC2153
#
# build-alpine-gnome-iso.sh
#
# Builds an x86_64 ISO that is Alpine's "standard" ISO plus everything that
# `setup-desktop gnome` would install and enable, so the live system boots
# straight to the GNOME desktop without running setup-alpine first, or
# (TARGET=rpi) the same as an aarch64 Raspberry Pi SD card image, built on
# Alpine's "rpiimg" image instead of the standard ISO. On top
# of that it adds and configures what test/features.sh expects of a
# desktop (bash, NetworkManager, PipeWire, CUPS, AppArmor, Flatpak, ...),
# both on the live system and on systems installed from it, and confines
# the system daemons with the AppArmor profiles in apparmor.d/.
#
# Uses Alpine's own image tooling (aports/scripts/mkimage.sh) with a custom
# profile that extends profile_standard, run inside an Alpine container, so
# the host only needs podman or docker.
#
# How it works: the desktop features' configuration is built into a package,
# cervino-desktop (cervino-desktop/APKBUILD), which depends on the features'
# packages. It and the GNOME packages, with the kernel and firmware, are
# installed once into a root file system, which goes on the image as a
# squashfs (cervino/rootfs.squashfs), with an apkovl (the same overlay
# mechanism `lbu` uses) for what only the live system has. At boot the
# initramfs (with initramfs-live.patch) mounts the squashfs read-only with a
# tmpfs over it as the root, unpacks the apkovl into it, and OpenRC starts
# udev, dbus, gdm etc. exactly as setup-desktop would have configured them.
# Installs copy the system from the squashfs too; the image's on-disc apk
# repository only has the disk tools and boot loaders Alpine's setup-disk
# adds. The Pi's image also has VLC and the ffmpeg7 libraries it plays
# through, GStreamer's base and bad plug-ins, wpa_supplicant and bluez,
# built from rpi/: Alpine's packages with Raspberry Pi OS's patches for the
# Pi's hardware video decoders, Wi-Fi and Bluetooth, published with
# cervino-desktop.
#
# The container runs the target's architecture, so the packages' scripts
# run when the root file system is installed: building for another
# architecture needs QEMU user emulation (binfmt_misc, e.g. qemu-user-static).
#
# Usage:
#   ./build-alpine-gnome-iso.sh
#
# Environment overrides:
#   TARGET          iso: an x86_64 ISO; rpi: an aarch64 Raspberry Pi
#                   (4, 400, 5, 500) SD card image (default: iso)
#   ALPINE_BRANCH   Alpine release branch, e.g. v3.24 (default: latest-stable)
#   OUTDIR          where the image is written (default: ./out)
#   LIVE_USER       desktop user created on boot (default: alpine)
#   LIVE_PASSWORD   that user's password (default: none; the user logs in,
#                   unlocks the screen and uses doas and polkit without one)
#   AUTOLOGIN       0 to stop at the GDM login screen instead of logging
#                   LIVE_USER straight in to GNOME (default: 1)
#   BROWSER         browser package, as setup-desktop (default: firefox)
#   CONTAINER       container runtime to use (default: podman, else docker)
#   MIRROR          Alpine package mirror
#                   (default: https://dl-cdn.alpinelinux.org/alpine)
#   SIGNING_KEY     abuild private key (its public key is derived from it,
#                   named after the file plus .pub) to sign the packages
#                   built here (cervino-desktop, and the Pi's ffmpeg7, vlc,
#                   gst-plugins-base, gst-plugins-bad, wpa_supplicant and
#                   bluez) and the image's repo with
#                   (default: a new key each build)
#   APK_REPO        URL of the repo those packages are published in, without
#                   the branch; installs get updates from APK_REPO/<branch>
#                   (default: none). Its packages must be signed with
#                   SIGNING_KEY.
#   CACHEDIR        where the Pi's packages built from rpi/ are kept, to be
#                   taken from there by later builds while their sources,
#                   Alpine's version and the release are the same
#                   (default: none, each build builds them)
#
# Note: the live system runs from the root file system image on the boot
# media, with only its changes in RAM: it boots to the desktop in 2 GB.

set -euo pipefail

TARGET=${TARGET:-iso}
case $TARGET in
iso) ARCH=x86_64 image_ext=iso ;;
rpi) ARCH=aarch64 image_ext=img.gz ;;
*) echo "error: bad TARGET: $TARGET (iso or rpi)" >&2; exit 1 ;;
esac
MIRROR=${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
LIVE_USER=${LIVE_USER:-alpine}
LIVE_PASSWORD=${LIVE_PASSWORD-}
AUTOLOGIN=${AUTOLOGIN:-1}
BROWSER=${BROWSER:-firefox}
SIGNING_KEY=${SIGNING_KEY-}
APK_REPO=${APK_REPO-}
CACHEDIR=${CACHEDIR-}

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
		ALPINE_BRANCH=$(curl -fsSL \
			"$MIRROR/latest-stable/releases/$ARCH/latest-releases.yaml" |
			awk '/branch:/ { print $2; exit }') ||
			die "could not determine latest Alpine release; set ALPINE_BRANCH"
	fi
	[[ $ALPINE_BRANCH =~ ^v[0-9]+\.[0-9]+$ ]] || die "bad ALPINE_BRANCH: $ALPINE_BRANCH"

	OUTDIR=$(realpath -m "${OUTDIR:-./out}")
	mkdir -p "$OUTDIR"

	# cervino-desktop's version: the time of the last commit, so that each
	# commit's package upgrades the one before (the build time outside git).
	local here pkgver
	here=$(dirname "$(realpath "$0")")
	pkgver=$(TZ=UTC0 git -C "$here" log -1 --date=format-local:%Y%m%d.%H%M%S \
		--format=%cd 2>/dev/null) || pkgver=
	pkgver=${pkgver:-$(date -u +%Y%m%d.%H%M%S)}

	# The signing key goes in as a file, under a fixed path; apk knows a key by
	# its file name, which is passed alongside.
	local keyopts=()
	if [[ -n $SIGNING_KEY ]]; then
		[[ -r $SIGNING_KEY ]] || die "cannot read SIGNING_KEY: $SIGNING_KEY"
		keyopts=(-v "$(realpath "$SIGNING_KEY")":/signing-key:ro
			-e SIGNING_KEY_NAME="$(basename "$SIGNING_KEY")")
	fi
	[[ -z $APK_REPO || $APK_REPO == https://* ]] || die "APK_REPO must be an https:// URL"
	local cacheopts=()
	if [[ -n $CACHEDIR ]]; then
		mkdir -p "$CACHEDIR"
		cacheopts=(-v "$(realpath "$CACHEDIR")":/cache)
	fi

	# The container runs the target's architecture, as installing the root
	# file system runs its packages' scripts: on another host, under QEMU.
	local platform=amd64
	[[ $ARCH == aarch64 ]] && platform=arm64
	[[ $(uname -m) == "$ARCH" || -e /proc/sys/fs/binfmt_misc/qemu-$ARCH ]] ||
		die "building for $ARCH on $(uname -m) needs QEMU user emulation (qemu-user-static)"

	echo ">>> Building Alpine ${ALPINE_BRANCH#v} GNOME live $TARGET image ($ARCH) with $runtime"
	# On SELinux hosts, disable confinement for this container rather than
	# relabelling the volumes with :Z: a container-private label on $OUTDIR
	# stops libvirt's qemu from opening the ISO in it.
	"$runtime" run --rm \
		--platform "linux/$platform" \
		--security-opt label=disable \
		-v "$(realpath "$0")":/build.sh:ro \
		-v "$here"/genapkovl-gnomelive.sh:/genapkovl-gnomelive.sh:ro \
		-v "$here"/live:/live:ro \
		-v "$here"/mkimg.gnomelive.sh:/mkimg.gnomelive.sh:ro \
		-v "$here"/initramfs-live.patch:/initramfs-live.patch:ro \
		-v "$here"/cervino-desktop:/cervino-desktop:ro \
		-v "$here"/apparmor.d:/apparmor.d:ro \
		-v "$here"/rpi:/rpi:ro \
		-v "$OUTDIR":/out \
		-e TARGET="$TARGET" \
		-e ALPINE_BRANCH="$ALPINE_BRANCH" \
		-e MIRROR="$MIRROR" \
		-e LIVE_USER="$LIVE_USER" \
		-e LIVE_PASSWORD="$LIVE_PASSWORD" \
		-e AUTOLOGIN="$AUTOLOGIN" \
		-e BROWSER="$BROWSER" \
		-e PKGVER="$pkgver" \
		-e APK_REPO="${APK_REPO%/}" \
		"${keyopts[@]}" \
		"${cacheopts[@]}" \
		"docker.io/library/alpine:${ALPINE_BRANCH#v}" \
		sh -c 'apk add --quiet bash && exec bash /build.sh --in-container'

	echo ">>> Done:"
	ls -lh "$OUTDIR"/*-"$ARCH.$image_ext" "$OUTDIR"/repo/*/"$ARCH"/*.apk
}

# ---------------------------------------------------------------------------
# Container side: set up the profile + apkovl generator and run mkimage.sh.
# ---------------------------------------------------------------------------
container_main() {
	printf '%s\n' "$MIRROR/$ALPINE_BRANCH/main" "$MIRROR/$ALPINE_BRANCH/community" \
		> /etc/apk/repositories
	apk update --quiet
	# clang and lld build cervino-desktop's freestanding tryboot for the Pi.
	# The container runs $ARCH, and syslinux (for the ISO's boot loader)
	# only exists for x86.
	local syslinux=
	[[ $TARGET == iso ]] && syslinux=syslinux
	apk add --quiet alpine-sdk alpine-conf apk-tools busybox fakeroot \
		$syslinux xorriso squashfs-tools mtools dosfstools sfdisk grub grub-efi git \
		clang lld mkinitfs patch

	# mkimage must run unprivileged: apk 3 rejects its --no-chown as root.
	adduser -D build
	addgroup build abuild
	mkdir -p /work
	chown build:build /work

	# abuild signs cervino-desktop and mkimage the ISO's apk index with the
	# key abuild.conf names; the public key ends up in the image. Without
	# SIGNING_KEY, a new one. (abuild-keygen -i would shell out to doas/sudo,
	# so install the key by hand.)
	local privkey
	if [[ -n ${SIGNING_KEY_NAME:-} ]]; then
		privkey=/home/build/.abuild/$SIGNING_KEY_NAME
		mkdir -p /home/build/.abuild
		install -m 0600 /signing-key "$privkey"
		openssl rsa -in "$privkey" -pubout -out "$privkey".pub 2>/dev/null ||
			die "SIGNING_KEY is not an RSA private key"
		echo "PACKAGER_PRIVKEY=\"$privkey\"" > /home/build/.abuild/abuild.conf
		chown -R build:build /home/build/.abuild
	else
		su build -s /bin/bash -c 'abuild-keygen -a -n'
		privkey=$(. /home/build/.abuild/abuild.conf && echo "$PACKAGER_PRIVKEY")
	fi
	cp "$privkey".pub /etc/apk/keys/

	# The Pi's packages it built go in the cache (owned by its owner on the
	# host) even if the build stops later, so the next one need not build
	# them again.
	local rc=0
	su build -s /bin/bash -c 'bash /build.sh --as-builder' || rc=$?
	if [[ -d /cache ]]; then
		local dir
		for dir in /work/pkgcache/*/; do
			[[ -d $dir ]] || continue
			dir=${dir%/}
			rm -rf /cache/"${dir##*/}"
			cp -R "$dir" /cache/
			chown -R "$(stat -c %u:%g /cache)" /cache/"${dir##*/}"
		done
	fi
	(( rc == 0 )) || exit "$rc"
	build_rootfs
	su build -s /bin/bash -c 'bash /build.sh --mkimage'
	# The live system loads the root file system's modules for the image's
	# kernel, which mkimage fetched separately: a kernel released in between
	# would have none.
	local kver
	kver=$(ls /work/rootfs/lib/modules)
	[[ -n $(find /work/mkimage -path "*/boot/config-$kver" -print -quit) ]] ||
		die "the image's kernel is not the root file system's ($kver): build again"
	cp /work/out/*."$image_ext" /out/
	# The package, laid out as in the published repo.
	mkdir -p /out/repo
	cp -R /work/pkgout/. /out/repo/
}

# The installed system, built once: the packages builder_main lists, from
# Alpine's repos and cervino-desktop's, installed into an empty root with
# their scripts and triggers run (as root, which apk needs to chroot into it;
# the container runs $ARCH, so it can run them), then packed into a squashfs,
# which mkimage puts on the image as cervino/rootfs.squashfs: the live
# system's root.
build_rootfs() {
	local rootfs=/work/rootfs
	echo ">>> Installing the root file system"
	# Alpine's keys and the build's, which the root's own packages
	# (alpine-keys, cervino-desktop) then take over.
	mkdir -p "$rootfs"/etc/apk/keys
	cp /etc/apk/keys/* "$rootfs"/etc/apk/keys/
	apk add --root "$rootfs" --initdb --no-cache --quiet \
		--repository "$MIRROR/$ALPINE_BRANCH/main" \
		--repository "$MIRROR/$ALPINE_BRANCH/community" \
		--repository /work/pkgrepo \
		$(cat /work/rootfs-packages) || die "could not install the root file system"
	# mkinitfs's trigger built an initramfs for this container; installs
	# build their own. Each system needs a machine-id of its own, which the
	# dbus service makes when there is none.
	rm -f "$rootfs"/boot/initramfs-* "$rootfs"/etc/machine-id
	# A container may not make device nodes (rootless podman cannot), so apk
	# may have made none, and scripts writing to /dev/null a plain file. Put
	# the nodes apk makes in the squashfs instead (mksquashfs keeps a file
	# that is there over a -p definition).
	rm -f "$rootfs"/dev/{null,zero,random,urandom,console}
	echo ">>> Packing the root file system"
	# The host's SELinux labels stay out (the container's files get them on
	# an SELinux host); other xattrs, such as file capabilities, go in.
	mksquashfs "$rootfs" /work/rootfs.squashfs -comp xz -b 1M -noappend -quiet \
		-xattrs-exclude '^security\.selinux$' \
		-p 'dev/null c 666 0 0 1 3' -p 'dev/zero c 666 0 0 1 5' \
		-p 'dev/random c 666 0 0 1 8' -p 'dev/urandom c 666 0 0 1 9' \
		-p 'dev/console c 600 0 0 5 1' ||
		die "could not pack the root file system"
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
	# Resolve the packages in an apk root of their own for $ARCH, with
	# Alpine's repos only.
	local apkroot=/work/apkroot
	# (The keys there are symlinks: cp without -r copies the files.)
	mkdir -p "$apkroot"/etc/apk/keys
	cp /usr/share/apk/keys/"$ARCH"/* "$apkroot"/etc/apk/keys/
	printf '%s\n' "$repo_main" "$repo_community" > "$apkroot"/etc/apk/repositories
	apk --root "$apkroot" --arch "$ARCH" add --quiet --initdb --no-chown
	apk --root "$apkroot" update --quiet
	local gnome_deps
	gnome_deps=$(apk --root "$apkroot" info --quiet --depends gnome gnome-apps-core |
		sed -e 's/[<>=~].*//' | grep -v '^$' | sort -u)
	[[ -n $gnome_deps ]] || die "could not resolve gnome dependencies"

	# --- Desktop features on top of that ------------------------------------
	# What test/features.sh checks for: a full shell and the usual CLI
	# tools, man pages, a UTF-8 locale, spell checking, emoji and CJK fonts,
	# NetworkManager (with dnsmasq as the local DNS server, built with the
	# D-Bus support NetworkManager configures it through), NTP, the
	# hostname1/timedate1/locale1 D-Bus services,
	# Bluetooth, printing, mDNS, a firewall, an SSH client and server (not
	# enabled), power profiles, AppArmor, zram swap, PipeWire (with AirPlay
	# speakers found over mDNS: pipewire-zeroconf), xdg-utils,
	# Flatpak, Alpine's packages in GNOME Software
	# (apk-polkit-server and the AppStream catalog), VA-API (libva with the
	# Mesa, Intel (x86_64 only) and vainfo packages), gst-libav (FFmpeg's
	# decoders: multithreaded H.264, and the E-AC-3 and DTS sound tracks
	# GStreamer has no other decoder for), dav1d's AV1 decoder (much faster
	# than libaom's, the only other one), the SPICE guest agent,
	# gcompat (the glibc loader, for programs built for glibc), fstrim,
	# cronie (cron with anacron, for periodic jobs missed while off),
	# earlyoom (kills a process before running out of memory freezes the
	# desktop), iw and wireless-regdb (the Wi-Fi region, set from the time
	# zone) and
	# (x86_64 only) the CPU microcode.
	# Their configuration is in the cervino-desktop package, which depends on
	# them (built below), and their services are set up in the apkovl.
	# pipewire-pulse provides the pulseaudio that gnome-settings-daemon
	# depends on, so PulseAudio itself is not installed. rtkit gives
	# PipeWire's audio threads real-time scheduling.
	local features="bash bash-completion file xz zstd pciutils dmidecode rsync
		mandoc mandoc-apropos mandoc-doc man-pages command-not-found nano
		musl-locales musl-locales-lang hunspell-en font-noto-emoji font-noto-cjk
		networkmanager networkmanager-cli networkmanager-wifi dnsmasq-dnssec-dbus chrony
		openrc-settingsd bluez cups cups-client cups-filters avahi avahi-tools
		nftables openssh power-profiles-daemon apparmor apparmor-utils apparmor-profiles
		zram-init zram-init-openrc pipewire wireplumber pipewire-pulse rtkit
		pipewire-alsa pipewire-spa-bluez pipewire-zeroconf xdg-utils flatpak
		gnome-software-plugin-flatpak apk-polkit-rs-openrc
		alpine-appstream-downloader libva libva-utils mesa-va-gallium gst-libav
		gst-plugins-rs-dav1d spice-vdagent spice-vdagent-openrc gcompat fstrim
		iproute2-minimal cronie cronie-openrc earlyoom earlyoom-openrc iw wireless-regdb"
	# The installer's setup-disk shim (see live/setup-disk) offers an
	# atomic install: the system on a btrfs volume, optionally encrypted,
	# booted from a FAT boot partition. Installed systems need the same tools
	# to keep that partition up to date, and kernel-hooks to run
	# cervino-desktop's hook after a kernel upgrade.
	local atomic="btrfs-progs cryptsetup cryptsetup-openrc blkid dosfstools sfdisk kernel-hooks"
	case $TARGET in
	# CPU microcode updates: the images in /boot go before the initramfs (in
	# a sys install's boot loader, an atomic install's UKI). UEFI starts
	# atomic installs, each version a unified kernel image (made by ukify)
	# with a boot entry of its own.
	iso) features="$features intel-media-driver libva-intel-driver amd-ucode intel-ucode
		$atomic efibootmgr ukify" ;;
	# vcgencmd, pinctrl etc. raspberrypi-utils-raspinfo needs a sudo-virt
	# other than sudo itself, which mkimage's fetch would otherwise pick.
	# The firmware's package, so that each version of an atomic install
	# brings the firmware it is to start with.
	rpi) features="$features raspberrypi-utils doas-sudo-shim $atomic raspberrypi-bootloader" ;;
	esac

	# The Pi's video player: VLC, with Raspberry Pi OS's patches for the
	# Pi's hardware decoders (built below from rpi/), an app like GNOME's.
	local apps=
	[[ $TARGET == rpi ]] && apps=vlc-qt

	# /etc/apk/world: what setup-desktop gnome puts there, plus
	# cervino-desktop, which brings in the features. So a feature added to
	# the package later reaches installed systems with it, while GNOME's
	# apps stay in world, where they can be removed one by one.
	local world
	world=$(printf '%s\n' alpine-base doas \
		elogind polkit-elogind "$BROWSER" \
		eudev udev-init-scripts udev-init-scripts-openrc \
		$gnome_deps $apps cervino-desktop | sort -u)

	# The image's on-disc apk repo, for Alpine's setup-disk (sys installs,
	# see genapkovl-gnomelive.sh): the disk tools it installs on the live
	# system and the boot loaders it installs on the new one, which the root
	# file system (copied to the new system first) lacks, and the keymaps
	# setup-alpine's keyboard step installs. Also apparmor-profiles, which
	# ci/guest/install.sh reinstalls.
	local disc_apks="e2fsprogs xfsprogs lvm2 mdadm dosfstools sfdisk cryptsetup btrfs-progs
		kbd-bkeymaps apparmor-profiles"
	case $TARGET in
	iso) disc_apks="$disc_apks syslinux grub-bios grub-efi efibootmgr" ;;
	rpi) disc_apks="$disc_apks raspberrypi-bootloader" ;;
	esac

	# --- The Pi's packages ----------------------------------------------------
	# Alpine's, with Raspberry Pi OS's patches (rpi/): ffmpeg7 and vlc for
	# the Pi's hardware video decoders, gst-plugins-base and gst-plugins-bad
	# for its HEVC decoder in GStreamer (Showtime, WebKit, the file
	# previews), wpa_supplicant for WPA3 with its Wi-Fi, bluez for audio
	# over its Bluetooth, which shares the radio.
	# They rank above Alpine's and so replace them. Each is
	# Alpine's APKBUILD of one version (its _alpine) with the patches: stop
	# if Alpine's has moved on, as its changes (security fixes, rebuilds for
	# libraries' new sonames) would be missing. abuild -r installs what they
	# build with (abuild-apk, which the abuild group may run) and adds the
	# packages it built before to the repos, so vlc builds with ffmpeg7-dev
	# and gst-plugins-bad with gst-plugins-base-dev from here.
	# With CACHEDIR (mounted on /cache), a package built before is taken
	# from there when its key matches: a hash of the release, the
	# architecture, Alpine's version, rpi/<package>/ and the key of the
	# package it builds with. Its files keep the signature of the build that
	# made them, so they are signed again with this build's key. Packages
	# built here are left in /work/pkgcache for container_main to keep.
	if [[ $TARGET == rpi ]]; then
		local name base alpine dep key file tmp files
		local -A keys after=([vlc]=ffmpeg7 [gst-plugins-bad]=gst-plugins-base)
		local repodir=/work/packages/cervino/$ARCH
		mkdir -p /work/cervino /work/pkgcache
		for name in ffmpeg7 vlc gst-plugins-base gst-plugins-bad wpa_supplicant bluez; do
			base=$(sed -n 's/^_alpine=//p' /rpi/"$name"/APKBUILD)
			alpine=$(apk --root "$apkroot" search --exact "$name") ||
				die "Alpine $ALPINE_BRANCH has no $name"
			[[ $alpine == "$name-$base" ]] ||
				die "Alpine's $name is $alpine, rpi/$name/APKBUILD is based on" \
					"$name-$base: update it"
			cp -R /rpi/"$name" /work/cervino/
			cd /work/cervino/"$name"
			dep=${after[$name]:-}
			key=$({
				echo "$ALPINE_BRANCH $ARCH $alpine ${dep:+${keys[$dep]}}"
				find . -type f -exec sha256sum {} + | LC_ALL=C sort -k 2
			} | sha256sum | cut -d ' ' -f 1)
			keys[$name]=$key
			mapfile -t files < <(abuild listpkg)
			if [[ $(cat /cache/"$name"/key 2>/dev/null) == "$key" ]] &&
				(cd /cache/"$name" && ls "${files[@]}" > /dev/null 2>&1); then
				echo ">>> $name: taking ${files[*]} from the cache"
				mkdir -p "$repodir"
				for file in "${files[@]}"; do
					tmp=$(mktemp -d)
					(cd "$tmp" && abuild-gzsplit < /cache/"$name"/"$file" &&
						abuild-sign -q control.tar.gz &&
						cat control.tar.gz data.tar.gz \
							> "$repodir"/"$file") ||
						die "could not sign $file again"
					rm -rf "$tmp"
				done
				# The repo abuild -r installs vlc's and gst-plugins-bad's
				# makedepends from.
				abuild -P /work/packages index || die "could not index $name"
			else
				abuild -r -P /work/packages || die "could not build $name"
				mkdir -p /work/pkgcache/"$name"
				(cd "$repodir" && cp "${files[@]}" /work/pkgcache/"$name"/) ||
					die "abuild built other packages than abuild listpkg" \
						"names for $name"
				echo "$key" > /work/pkgcache/"$name"/key
			fi
			cd /work
		done
	fi

	# --- cervino-desktop package ---------------------------------------------
	# Built from cervino-desktop/APKBUILD, with the AppArmor profiles and
	# Flathub's remote (Flatpak adds the remotes in /etc/flatpak/remotes.d)
	# next to it, and signed with the build's key, which mkimage puts in the
	# image. It goes in a repo of its own for mkimage, with the Pi's
	# packages, indexed under $ARCH: abuild files the noarch package under
	# the container's architecture, and apk 3 looks for a package in the
	# directory of the architecture its index gives. Its dependencies are in
	# Alpine's repos, which the index doesn't cover.
	local pkgsrc=/work/cervino/cervino-desktop pkgrepo=/work/pkgrepo
	mkdir -p "$pkgsrc" "$pkgrepo/$ARCH"
	cp -R /cervino-desktop/. /apparmor.d "$pkgsrc"/
	wget -qO "$pkgsrc"/flathub.flatpakrepo https://dl.flathub.org/repo/flathub.flatpakrepo ||
		die "could not download the Flathub remote"
	# The package brings the public key, and with APK_REPO, the repo.
	local pubkey
	pubkey=$(. /home/build/.abuild/abuild.conf && echo "$PACKAGER_PRIVKEY".pub)
	cp "$pubkey" "$pkgsrc"/
	printf '%s=%s\n' PKGVER "$(shquote "$PKGVER")" \
		DEPENDS "$(shquote "$(echo $features)")" \
		PUBKEY "$(shquote "$(basename "$pubkey")")" \
		REPO "$(shquote "${APK_REPO:+$APK_REPO/$ALPINE_BRANCH}")" \
		TARGET_ARCH "$(shquote "$ARCH")" > "$pkgsrc"/cervino-desktop.conf
	(cd "$pkgsrc" && abuild -d -P /work/packages) || die "could not build cervino-desktop"
	cp /work/packages/cervino/*/*.apk "$pkgrepo/$ARCH"/
	mkdir -p /work/pkgout/"$ALPINE_BRANCH/$ARCH"
	cp "$pkgrepo/$ARCH"/*.apk /work/pkgout/"$ALPINE_BRANCH/$ARCH"/
	apk index --quiet --no-warnings --rewrite-arch "$ARCH" \
		-o "$pkgrepo/$ARCH"/APKINDEX.tar.gz "$pkgrepo/$ARCH"/*.apk ||
		die "could not index the packages"
	abuild-sign -q "$pkgrepo/$ARCH"/APKINDEX.tar.gz

	# --- Root file system -----------------------------------------------------
	# container_main installs these into the root file system: the world plus
	# the kernel and firmware an installed system needs (setup-disk would
	# otherwise fetch them from the mirror). The firmware is all of
	# linux-firmware but what only servers, network appliances and ARM SoCs
	# use, as an installed system may get hardware the machine it was
	# installed from did not have. The modloop's firmware is no substitute:
	# it has only the files modules declare, and drivers load many by names
	# they make up (Intel Bluetooth, laptop speaker amps, ath11k/ath12k).
	local kernel=lts firmware
	local unused='qcom|mellanox|qed|netronome|dpaa2|liquidio|cxgb4|bnx2x|vxge|amlogic|s5p-mfc|amphion'
	[[ $TARGET == rpi ]] && kernel=rpi
	firmware=$(apk --root "$apkroot" info --quiet --depends linux-firmware |
		sed -e 's/[<>=~].*//' | grep -v '^$' | grep -vxE "linux-firmware-($unused)") ||
		die "could not resolve linux-firmware's packages"
	# The root file system's world, and the live system's (in the apkovl).
	local image_world
	image_world=$(printf '%s\n' $world "linux-$kernel" $firmware wireless-regdb | sort -u)
	echo "$image_world" > /work/rootfs-packages

	# The live system installs the world at boot, and goes on without it if
	# that fails, so check that the package installs with it (a cmd: or file
	# it provides could conflict with another package's), and with the rest
	# of the root file system.
	apk --root "$apkroot" add --simulate --allow-untrusted --repository "$pkgrepo" \
		$(cat /work/rootfs-packages) > /dev/null ||
		die "cervino-desktop does not install with the rest of the image (see above)"

	# Kernel arguments, both on the image and (through setup-disk's
	# KERNELOPTS) on installs. AppArmor is built into the kernel but needs
	# enabling on the command line.
	local kernel_opts="lsm=landlock,lockdown,yama,loadpin,safesetid,integrity,apparmor"
	# The initramfs opens an encrypted root without discards, so the
	# weekly fstrim never reaches the SSD; cryptdiscards=yes lets them
	# through (at the cost of showing which blocks are free). Without an
	# encrypted root the initramfs ignores it.
	kernel_opts+=" cryptdiscards=yes"
	# With no auditd, the kernel prints audit records (AppArmor's among
	# them) through printk, which drops all but 10 every 5 s, and queues at
	# most 64 before kauditd runs: the profile loads alone are ~190, so
	# denials went missing from dmesg. Lift both limits, from boot on (a
	# sysctl.d file would only apply after the apparmor and udev sysinit
	# services), and make the 128 KiB log buffer big enough to keep them.
	kernel_opts+=" sysctl.kernel.printk_ratelimit=0 audit_backlog_limit=8192 log_buf_len=4M"
	# The Pi firmware's device tree caps an NVMe drive's host memory buffer
	# at 32 MB (nvme.max_host_mem_size_mb=32 in its bootargs, which
	# cmdline.txt comes after and so overrides). A DRAM-less drive that
	# needs more, as many ask for 64 MB, then gets none and runs slower.
	# The same bootargs turn off the memory cgroup controller
	# (cgroup_disable=memory); the Pi kernel's cgroup_enable= turns it back
	# on, so cgroups (containers' memory limits, for one) can limit memory.
	# Without a console= argument the kernel takes /dev/console from the
	# device tree's stdout-path, the debug UART, so the initramfs would ask
	# for an encrypted root's passphrase there, leaving the screen blank;
	# console=tty1 puts it on the screen.
	if [[ $TARGET == rpi ]]; then
		kernel_opts+=" nvme.max_host_mem_size_mb=64 cgroup_enable=memory console=tty1"
	fi

	# --- mkimage profile -----------------------------------------------------
	# mkimg.gnomelive.sh reads the build settings from the .conf next to it.
	printf '%s=%s\n' gnomelive_target "$(shquote "$TARGET")" \
		gnomelive_kernel_opts "$(shquote "$kernel_opts")" \
		gnomelive_apks "$(shquote "$(echo $disc_apks)")" \
		> aports/scripts/mkimg.gnomelive.conf
	install -m 0644 /mkimg.gnomelive.sh aports/scripts/mkimg.gnomelive.sh
	if [[ $TARGET == rpi ]]; then
		# The Pi's config.txt includes usercfg.txt, for settings of our own:
		# GNOME needs the GPU's KMS driver, which the firmware leaves off.
		# The apkovl takes it along for the lbu shim to put on installs.
		printf '%s\n' "# Load the GPU's KMS driver, which GNOME needs." \
			dtoverlay=vc4-kms-v3d > aports/scripts/usercfg.txt
	fi

	# --- apkovl generator ----------------------------------------------------
	# genapkovl-gnomelive.sh reads the build settings from the .conf, the
	# live system's scripts from live/ (and on the Pi, usercfg.txt), all next
	# to it.
	printf '%s=%s\n' TARGET "$(shquote "$TARGET")" \
		LIVE_USER "$(shquote "$LIVE_USER")" \
		LIVE_PASSWORD "$(shquote "$LIVE_PASSWORD")" \
		AUTOLOGIN "$(shquote "$AUTOLOGIN")" \
		KERNEL_OPTS "$(shquote "$kernel_opts")" \
		WORLD "$(shquote "$image_world")" > aports/scripts/genapkovl-gnomelive.conf
	install -m 0755 /genapkovl-gnomelive.sh aports/scripts/genapkovl-gnomelive.sh
	cp -R /live aports/scripts/live

	# --- initramfs -----------------------------------------------------------
	# The live system's root is the root file system image on the boot media
	# (see initramfs-live.patch), so the image's initramfs gets an init of
	# its own: update-kernel runs mkinitfs, which takes it from $DATADIR.
	cp -R /usr/share/mkinitfs /work/mkinitfs
	patch -s -d /work/mkinitfs -p1 < /initramfs-live.patch ||
		die "initramfs-live.patch does not apply to this release's mkinitfs"
	# The live system has the kernel's modules and firmware in the root file
	# system, so the image goes without the modloop that mkimage's kernel
	# section has update-kernel make: an update-kernel ahead of it in PATH
	# deletes it from the section's boot/ (its last argument, with --media).
	mkdir -p /work/bin
	cat > /work/bin/update-kernel <<'EOF'
#!/bin/sh
/usr/sbin/update-kernel "$@" || exit
for dest; do :; done
rm -f "$dest"/boot/modloop-*
EOF
	chmod 0755 /work/bin/update-kernel
}

# Builds the image, once container_main has built the root file system it
# puts on it.
mkimage_main() {
	cd /work
	DATADIR=/work/mkinitfs PATH=/work/bin:$PATH sh aports/scripts/mkimage.sh \
		--tag "$(cat /etc/alpine-release)" \
		--outdir /work/out \
		--workdir /work/mkimage \
		--arch "$ARCH" \
		--repository "$MIRROR/$ALPINE_BRANCH/main" \
		--repository "$MIRROR/$ALPINE_BRANCH/community" \
		--repository /work/pkgrepo \
		--profile gnomelive
}

if [[ ${1:-} == --in-container ]]; then
	container_main
elif [[ ${1:-} == --as-builder ]]; then
	builder_main
elif [[ ${1:-} == --mkimage ]]; then
	mkimage_main
else
	host_main
fi
