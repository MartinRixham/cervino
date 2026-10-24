#!/usr/bin/env bash
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
# packages. It and the GNOME packages (with all dependencies) are added to
# the ISO's on-disc apk repository, and an apkovl (the same overlay mechanism
# `lbu` uses) is placed on the ISO. At boot the initramfs unpacks the apkovl
# and installs everything in its /etc/apk/world from the disc into the RAM
# root, then OpenRC starts udev, dbus, gdm etc. exactly as setup-desktop
# would have configured them.
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
#                   named after the file plus .pub) to sign cervino-desktop
#                   and the image's repo with (default: a new key each build)
#   APK_REPO        URL of the repo cervino-desktop is published in, without
#                   the branch; installs get updates from APK_REPO/<branch>
#                   (default: none). Its packages must be signed with
#                   SIGNING_KEY.
#
# Note: the live system runs entirely from RAM (tmpfs), so booting the
# resulting image needs roughly 6 GB of RAM or more (an 8 GB Pi).

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

	echo ">>> Building Alpine ${ALPINE_BRANCH#v} GNOME live $TARGET image ($ARCH) with $runtime"
	# On SELinux hosts, disable confinement for this container rather than
	# relabelling the volumes with :Z: a container-private label on $OUTDIR
	# stops libvirt's qemu from opening the ISO in it.
	"$runtime" run --rm \
		--security-opt label=disable \
		-v "$(realpath "$0")":/build.sh:ro \
		-v "$here"/genapkovl-gnomelive.sh:/genapkovl-gnomelive.sh:ro \
		-v "$here"/cervino-desktop:/cervino-desktop:ro \
		-v "$here"/apparmor.d:/apparmor.d:ro \
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
	apk add --quiet alpine-sdk alpine-conf apk-tools busybox fakeroot \
		syslinux xorriso squashfs-tools mtools dosfstools sfdisk grub grub-efi git \
		mkinitfs

	# The image's initramfs installs /etc/apk/world at every boot, and apk
	# shows what the packages' install scripts print (as "  * " lines,
	# whatever --quiet says): the GNOME packages' advice, which this system
	# has already taken. mkimage builds the initramfs from this container's
	# mkinitfs, so its init gets the live system's apk shim's filter
	# (genapkovl-gnomelive.sh), which keeps apk's own messages and progress.
	local init=/usr/share/mkinitfs/initramfs-init
	[[ $(grep -c '^	if ! $MOCK apk add --root $sysroot ' "$init") == 2 &&
		$(grep -c '^apkflags="--initramfs-diskless-boot' "$init") == 1 ]] ||
		die "$init: the package install is not where expected"
	cat > /tmp/apk_add <<'EOF'
apk_add() (
	set -o pipefail
	{ cols=$(stty size <&3 2>/dev/null); } 3>&1
	{ $MOCK apk add "$@" 2>&1; } | awk -v cols="${cols#* }" 'BEGIN {
			RS = "\033"
			c = ENVIRON["APK_PROGRESS_CHAR"]
			if (c == "") c = ENVIRON["LANG"] ~ /UTF-8/ ? "\342\226\210" : "#"
		}
		NR > 1 && $0 == "8" { next }
		NR > 1 && cols > 25 && $0 ~ /^7 *[0-9]+% / {
			p = substr($0, 2, 3) + 0; w = cols - 6; $0 = sprintf("7%3d%% ", p)
			for (i = 0; i < w; i++) $0 = $0 (i < int(w * p / 100) ? c : " ")
		}
		NR > 1 && substr($0, 1, 1) == "7" {
			printf "\033[0K\033%s\0338", $0; bar = 1; fflush(); next
		}
		{ gsub(/  \* [^\n]*\n/, "") }
		NR > 1 { $0 = "\033" $0 }
		$0 == "" || $0 == "\033[0K" { next }
		{ printf "%s", $0; bar = 0; fflush() }
		END { if (bar) printf "\033[0K" }'
)
EOF
	sed -i -e 's/^	if ! $MOCK apk add --root $sysroot /	if ! apk_add --root $sysroot /' \
		-e '/^apkflags="--initramfs-diskless-boot/r /tmp/apk_add' "$init"

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

	su build -s /bin/bash -c 'bash /build.sh --as-builder'
	cp /work/out/*."$image_ext" /out/
	# The package, laid out as in the published repo.
	mkdir -p /out/repo
	cp -R /work/pkgout/. /out/repo/
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
	# mkimage cross-builds for $ARCH, which need not be the container's own
	# architecture, so resolve the packages in an apk root for $ARCH.
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
	# desktop) and
	# (x86_64 only) the CPU microcode.
	# Their configuration is in the cervino-desktop package, which depends on
	# them (built below), and their services are set up in the apkovl.
	# pipewire-pulse provides the pulseaudio that gnome-settings-daemon
	# depends on, so PulseAudio itself is not installed.
	local features="bash bash-completion file xz zstd pciutils dmidecode rsync
		mandoc mandoc-apropos mandoc-doc man-pages command-not-found nano
		musl-locales musl-locales-lang hunspell-en font-noto-emoji font-noto-cjk
		networkmanager networkmanager-cli networkmanager-wifi dnsmasq-dnssec-dbus chrony
		openrc-settingsd bluez cups cups-client cups-filters avahi avahi-tools
		nftables openssh power-profiles-daemon apparmor apparmor-utils apparmor-profiles
		zram-init zram-init-openrc pipewire wireplumber pipewire-pulse
		pipewire-alsa pipewire-spa-bluez pipewire-zeroconf xdg-utils flatpak
		gnome-software-plugin-flatpak apk-polkit-rs-openrc
		alpine-appstream-downloader libva libva-utils mesa-va-gallium gst-libav
		gst-plugins-rs-dav1d spice-vdagent spice-vdagent-openrc gcompat fstrim iproute2-minimal
		cronie cronie-openrc earlyoom earlyoom-openrc"
	case $TARGET in
	# CPU microcode updates: setup-disk's boot loader (GRUB or syslinux)
	# finds the images in /boot and loads them before the initramfs.
	iso) features="$features intel-media-driver libva-intel-driver amd-ucode intel-ucode" ;;
	# vcgencmd, pinctrl etc. raspberrypi-utils-raspinfo needs a sudo-virt
	# other than sudo itself, which mkimage's fetch would otherwise pick.
	rpi) features="$features raspberrypi-utils doas-sudo-shim" ;;
	esac

	# /etc/apk/world: what setup-desktop gnome puts there, plus
	# cervino-desktop, which brings in the features. So a feature added to
	# the package later reaches installed systems with it, while GNOME's
	# apps stay in world, where they can be removed one by one.
	local world packages
	world=$(printf '%s\n' alpine-base doas \
		elogind polkit-elogind "$BROWSER" \
		eudev udev-init-scripts udev-init-scripts-openrc \
		$gnome_deps cervino-desktop | sort -u)
	# What that installs, for the check below (cervino-desktop isn't built
	# yet).
	packages=$(printf '%s\n' $world $features | grep -vx cervino-desktop | sort -u)
	# mkimage puts the packages apk fetch --recursive picks in the image's
	# repo, and that picks the default provider of each dependency on its
	# own (sudo for raspinfo's sudo-virt, say). If installing the world as a
	# whole needs one the fetch did not pick, every apk add on the live
	# system fails, so check that the fetch covers the install.
	local fetched installed missing
	fetched=$(apk --root "$apkroot" fetch --simulate --recursive $packages |
		sed -n 's/^Downloading \(.*\)-[^-]*-r[0-9]*$/\1/p' | sort -u) ||
		die "could not fetch the packages for the image"
	installed=$(apk --root "$apkroot" add --simulate $packages |
		sed -n 's/^([0-9/]*) Installing \([^ ]*\) .*/\1/p' | sort -u) ||
		die "the packages for the image conflict (see above)"
	missing=$(comm -13 <(echo "$fetched") <(echo "$installed"))
	[[ -z $missing ]] ||
		die "the image's repo would lack $(echo $missing): add them to the features"

	# --- cervino-desktop package ---------------------------------------------
	# Built from cervino-desktop/APKBUILD, with the AppArmor profiles and
	# Flathub's remote (Flatpak adds the remotes in /etc/flatpak/remotes.d)
	# next to it, and signed with the build's key, which mkimage puts in the
	# image. It goes in a repo of its own for mkimage, indexed under $ARCH as
	# a package for $ARCH: abuild files the noarch package under the
	# container's architecture, and apk 3 looks for a package in the
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
		REPO "$(shquote "${APK_REPO:+$APK_REPO/$ALPINE_BRANCH}")" > "$pkgsrc"/cervino-desktop.conf
	(cd "$pkgsrc" && abuild -d -P /work/packages) || die "could not build cervino-desktop"
	cp /work/packages/cervino/*/cervino-desktop-*.apk "$pkgrepo/$ARCH"/
	mkdir -p /work/pkgout/"$ALPINE_BRANCH/$ARCH"
	cp "$pkgrepo/$ARCH"/cervino-desktop-*.apk /work/pkgout/"$ALPINE_BRANCH/$ARCH"/
	apk index --quiet --no-warnings --rewrite-arch "$ARCH" \
		-o "$pkgrepo/$ARCH"/APKINDEX.tar.gz "$pkgrepo/$ARCH"/*.apk ||
		die "could not index cervino-desktop"
	abuild-sign -q "$pkgrepo/$ARCH"/APKINDEX.tar.gz

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
	if [[ $TARGET == iso ]]; then
		cat > aports/scripts/mkimg.gnomelive.sh <<-EOF
		profile_gnomelive() {
			profile_standard
			profile_abbrev="gnome"
			title="GNOME Live"
			desc="Alpine standard plus GNOME, booting straight into GDM."
			arch="x86_64"
			kernel_cmdline="\$kernel_cmdline $kernel_opts"
			# CPU microcode, loaded by the ISO's boot loaders (as in
			# profile_extended)
			boot_addons="amd-ucode intel-ucode"
			initrd_ucode="/boot/amd-ucode.img /boot/intel-ucode.img"
			apks="\$apks $(echo $world)"
			apkovl="aports/scripts/genapkovl-gnomelive.sh"
			hostname="alpine"
		}
		EOF
	else
		# The Pi's config.txt includes usercfg.txt, for settings of our own:
		# GNOME needs the GPU's KMS driver, which the firmware leaves off.
		# The apkovl takes it along for the lbu shim to put on installs.
		printf '%s\n' "# Load the GPU's KMS driver, which GNOME needs." \
			dtoverlay=vc4-kms-v3d > aports/scripts/usercfg.txt
		# Alpine's Pi image: one FAT partition with the firmware, kernel,
		# apks and apkovl. section_rpi_config only builds the Pi's boot
		# files (config.txt, cmdline.txt, firmware) for hostname rpi.
		cat > aports/scripts/mkimg.gnomelive.sh <<-EOF
		profile_gnomelive() {
			profile_rpiimg
			image_name="alpine-gnomelive"
			title="GNOME Live"
			desc="Alpine for the Raspberry Pi plus GNOME, booting straight into GDM."
			arch="aarch64"
			kernel_cmdline="\$kernel_cmdline $kernel_opts"
			apks="\$apks $(echo $world)"
			output_format="gnomelive"
			apkovl="aports/scripts/genapkovl-gnomelive.sh"
			hostname="rpi"
		}

		section_gnomelive_usercfg() {
			[ "\$PROFILE" = gnomelive ] || return 0
			build_section gnomelive_usercfg \$(checksum < /work/aports/scripts/usercfg.txt)
		}

		build_gnomelive_usercfg() {
			cp /work/aports/scripts/usercfg.txt "\$DESTDIR"/
		}

		# rpiimg's create_image_imggz makes a FAT16 partition only 8 MB bigger
		# than the files, which the slack in its 32 KB clusters fills with this
		# many files. FAT32 with 4 KB clusters (which the Pi boots from too),
		# a tenth and 64 MB bigger, leaves room for the FAT and some free space.
		create_image_gnomelive() {
			sync "\$DESTDIR"
			local imgfile="\$OUTDIR/\${output_filename%.gz}"
			local size=\$(du -L -k -s "\$DESTDIR" | awk '{ print int(\$1 * 1.1 / 1024) + 64 }')
			rm -f "\$imgfile"
			truncate -s \$((size + 1))M "\$imgfile"
			echo 'start=2048, type=c, bootable' | sfdisk "\$imgfile"
			mkfs.vfat -n PIBOOT -F 32 -s 8 --offset 2048 "\$imgfile"
			mcopy -s -i "\$imgfile"@@2048s "\$DESTDIR"/* "\$DESTDIR"/.alpine-release ::
			echo "Compressing \$imgfile..."
			pigz -f -9 "\$imgfile" || gzip -f -9 "\$imgfile"
		}
		EOF
	fi

	# --- apkovl generator ----------------------------------------------------
	# genapkovl-gnomelive.sh reads the build settings from the .conf (and on
	# the Pi, usercfg.txt from the file next to it).
	printf '%s=%s\n' LIVE_USER "$(shquote "$LIVE_USER")" \
		LIVE_PASSWORD "$(shquote "$LIVE_PASSWORD")" \
		AUTOLOGIN "$(shquote "$AUTOLOGIN")" \
		KERNEL_OPTS "$(shquote "$kernel_opts")" \
		WORLD "$(shquote "$world")" > aports/scripts/genapkovl-gnomelive.conf
	install -m 0755 /genapkovl-gnomelive.sh aports/scripts/genapkovl-gnomelive.sh

	# --- build ---------------------------------------------------------------
	sh aports/scripts/mkimage.sh \
		--tag "$(cat /etc/alpine-release)" \
		--outdir /work/out \
		--workdir /work/mkimage \
		--arch "$ARCH" \
		--repository "$repo_main" \
		--repository "$repo_community" \
		--repository "$pkgrepo" \
		--profile gnomelive
}

if [[ ${1:-} == --in-container ]]; then
	container_main
elif [[ ${1:-} == --as-builder ]]; then
	builder_main
else
	host_main
fi
