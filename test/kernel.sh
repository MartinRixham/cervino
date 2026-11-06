#!/usr/bin/env bash
#
# test/kernel.sh [REPO_DIR]: builds cervino-kernel (rpi/linux-rpi) and
# tests it as far as a Raspberry Pi 5 or 500 can without starting it, before
# it is pushed. Run it on the Pi, from the repo. It needs podman (rootless,
# with subordinate IDs: /etc/subuid, /etc/subgid) and KVM.
#
# With REPO_DIR, a build's packages laid out as <branch>/<arch>/ (out/repo),
# it tests the cervino-kernel there instead, on any arm64 machine with
# podman or docker (CONTAINER), KVM or not: CI runs it after the rpi build.
# That is step 1 without the build, and step 2 with a small system instead
# of this machine's (only what --guest checks) and --guest alone.
#
# 1. --build, in an alpine:<branch> container: builds the package (again
#    only when rpi/linux-rpi or Alpine's linux-rpi changed), signed with a
#    throwaway key, and checks it (check_package): what it provides, its
#    config against Alpine's linux-rpi's, the page size in its kernel
#    image's header, that it takes linux-rpi's place and gives it back as
#    the apk wrapper deletes it, and that its pre-install script turns down
#    a system that is not an atomic install (and, on a Pi 5 or 500 that is
#    one, accepts it). --check does the same for REPO_DIR's package.
# 2. --vm, in another: installs this machine's world, cervino-kernel in
#    place of linux-rpi, with linux-virt and the packages the VM test adds,
#    into a btrfs disk image set up as an install would be (a user, tester,
#    who may use doas; this machine's runlevels and time zone; Widevine).
#    It boots that twice in QEMU/KVM (the virt machine, devices on
#    virtio-mmio), with cervino-kernel (16 KB pages) and with linux-virt
#    (4 KB), running in each the checks of --guest and ci/guest/test.sh (as
#    on a sys install), the CI's OS feature tests. A test that fails with
#    16 KB pages but not with 4 KB fails here; one that fails with both
#    (the VM has no Pi hardware) is reported as skipped.
#
# The Pi's own hardware under the kernel (its GPU, video decoders, Wi-Fi,
# NVMe) is left for a trial boot: README.md, The 16 KB page kernel.
#
# Prints the results as test/features.sh does; exits with the number of
# failures. The VM's console logs are kept in $WORKDIR/<kernel>.log.
#
# Environment overrides:
#   ALPINE_BRANCH  the release to build for (default: this machine's;
#                  with REPO_DIR, its <branch>)
#   CONTAINER      podman or docker, with REPO_DIR (default: podman)
#   ACCEL=tcg      with REPO_DIR, emulate the CPU even with KVM
#   MIRROR         Alpine mirror (default: the CDN)
#   WORKDIR        sources, packages, disk images, logs (default: ./kernel-test)
#   VM_MEMORY      guest RAM (default: 6G; with REPO_DIR, 4G)
#   VM_CPUS        guest CPUs (default: all host CPUs)
#   SKIP_VM=1      only build (or with REPO_DIR, find) and check the package

set -euo pipefail
export LC_ALL=C

MIRROR=${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}

die() { echo "error: $*" >&2; exit 1; }

# Results, as test/features.sh prints them.
if [[ -t 1 ]]; then
	C_PASS=$'\e[32m' C_FAIL=$'\e[31m' C_SKIP=$'\e[33m' C_OFF=$'\e[0m'
else
	C_PASS='' C_FAIL='' C_SKIP='' C_OFF=''
fi
PASS=0 FAIL=0 SKIP=0
pass() { PASS=$((PASS + 1)); printf '%s[PASS]%s %s\n' "$C_PASS" "$C_OFF" "$1"; }
# fail DESCRIPTION REASON, skip DESCRIPTION REASON
fail() {
	FAIL=$((FAIL + 1))
	printf '%s[FAIL]%s %s\n' "$C_FAIL" "$C_OFF" "$1"
	printf '       %s\n' "$2"
}
skip() {
	SKIP=$((SKIP + 1))
	printf '%s[SKIP]%s %s\n' "$C_SKIP" "$C_OFF" "$1"
	printf '       %s\n' "$2"
}
totals() {
	echo
	echo "Passed: $PASS  Failed: $FAIL  Skipped: $SKIP"
	exit "$FAIL"
}

# ---------------------------------------------------------------------------
# Host side: runs the phases in containers and adds up their failures.
# ---------------------------------------------------------------------------
host_main() {
	local repo=${1:-}
	here= image= failed=0 runtime=podman
	here=$(dirname "$(dirname "$(realpath "$0")")")
	if [[ -n $repo ]]; then
		local apks
		apks=("$repo"/v*/aarch64/cervino-kernel-[0-9]*.apk)
		[[ ${#apks[@]} == 1 && -f ${apks[0]} ]] ||
			die "$repo has no cervino-kernel (or more than one)"
		repo=$(realpath "$(dirname "${apks[0]}")")
		ALPINE_BRANCH=$(basename "$(dirname "$repo")")
		runtime=${CONTAINER:-podman}
	else
		ALPINE_BRANCH=${ALPINE_BRANCH:-v$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null)}
	fi
	[[ $ALPINE_BRANCH =~ ^v[0-9]+\.[0-9]+$ ]] || die "set ALPINE_BRANCH (v3.24, ...)"
	[[ $(uname -m) == aarch64 ]] || die "run it on an arm64 machine (with no REPO_DIR, a Pi 5)"
	command -v "$runtime" >/dev/null || die "need $runtime"
	image=docker.io/library/alpine:${ALPINE_BRANCH#v}

	# The pre-install script, which only reads, on this machine: it must
	# accept a Pi 5 or 500 that is an atomic install.
	local desc="pre-install accepts this machine (a BCM2712, an atomic install)"
	if tr '\0' '\n' < /proc/device-tree/compatible 2>/dev/null | grep -qx 'brcm,bcm2712' &&
		[[ -f /etc/kernel/cmdline ]]; then
		if sh "$here"/rpi/linux-rpi/cervino-kernel.pre-install; then
			pass "$desc"
		else
			fail "$desc" "it exited with $?"
		fi
	else
		skip "$desc" "this machine is not one"
	fi
	failed=$FAIL

	# Without subordinate IDs, rootless podman maps only root: it can't
	# unpack Alpine's image (/etc/shadow is group shadow's), and apk can't
	# give files to the VM system's other users (gdm, polkitd, ...).
	[[ $runtime != podman ]] || (($(id -u) == 0)) ||
		(($(podman unshare cat /proc/self/uid_map | wc -l) > 1)) ||
		die "rootless podman has no subordinate IDs for $(id -un): as root," \
			"add a range to /etc/subuid and /etc/subgid (e.g. $(id -un):100000:65536)" \
			"and run podman system migrate"

	WORKDIR=${WORKDIR:-./kernel-test}
	mkdir -p "$WORKDIR"
	WORKDIR=$(realpath "$WORKDIR")

	if [[ -n $repo ]]; then
		echo ">>> Checking $repo/$(basename "${apks[0]}")"
		phase --check -v "$repo":/repo:ro
		[[ -z ${SKIP_VM:-} ]] || done_main
		# The small system's kernel arguments: AppArmor's, as the image's.
		rm -rf "$WORKDIR"/host
		mkdir -p "$WORKDIR"/host
		echo 'lsm=landlock,lockdown,yama,integrity,apparmor' > "$WORKDIR"/host/cmdline
		echo ">>> Testing cervino-kernel in a VM (a small system)"
		phase --vm --privileged -v "$repo":/repo:ro -v "$WORKDIR":/work -e SMALL=1 \
			-e ACCEL="${ACCEL:-}" -e VM_MEMORY="${VM_MEMORY:-4G}" \
			-e VM_CPUS="${VM_CPUS:-$(nproc)}"
		done_main
	fi

	echo ">>> Building cervino-kernel for Alpine ${ALPINE_BRANCH#v}"
	phase --build -v "$WORKDIR":/work
	[[ -z ${SKIP_VM:-} && -f $WORKDIR/packages/current ]] || done_main

	[[ -r /dev/kvm && -w /dev/kvm ]] || die "need access to /dev/kvm"

	# What the VM's system copies from this machine.
	local host=$WORKDIR/host l
	rm -rf "$host"
	mkdir -p "$host"
	cp -R /etc/apk/world /etc/apk/repositories /etc/apk/keys "$host"/
	[[ ! -d /etc/apk/repositories.d ]] || cp -R /etc/apk/repositories.d "$host"/
	for l in /etc/runlevels/*/*; do
		echo "$(basename "$(dirname "$l")") ${l##*/}"
	done > "$host"/runlevels
	readlink /etc/localtime | sed 's|.*/zoneinfo/||' > "$host"/timezone
	# Its kernel arguments, but those that name its disks or the Pi's
	# hardware.
	tr ' ' '\n' < /proc/cmdline |
		grep -E '^(lsm|cryptdiscards|sysctl\.[a-z_.]*|audit_backlog_limit|log_buf_len)=' |
		xargs > "$host"/cmdline

	echo ">>> Testing cervino-kernel in a VM"
	phase --vm --privileged -v "$WORKDIR":/work \
		-e VM_MEMORY="${VM_MEMORY:-6G}" -e VM_CPUS="${VM_CPUS:-$(nproc)}"
	done_main
}

# phase PHASE [RUNTIME OPTIONS...]: runs this script's PHASE in a container of
# $image, adding its failures to $failed.
phase() {
	local name=$1 rc=0
	shift
	"$runtime" run --rm --pull=always --security-opt label=disable -v "$here":/src:ro \
		-e ALPINE_BRANCH="$ALPINE_BRANCH" -e MIRROR="$MIRROR" "$@" \
		"$image" sh -c "apk add --quiet bash && exec bash /src/test/kernel.sh $name" ||
		rc=$?
	((rc != 125)) || die "$runtime could not run the container"
	failed=$((failed + rc))
}

done_main() {
	echo
	echo ">>> $failed test(s) failed"
	exit "$failed"
}

# ---------------------------------------------------------------------------
# --build: builds the package and checks it.
# ---------------------------------------------------------------------------
# apk_scratch ARGS...: apk on the scratch root $scratch, with Alpine's repos
# and the package's ($pkgrepo), running no scripts (no kernel hooks).
apk_scratch() {
	apk --root "$scratch" --no-scripts --quiet \
		--repository "$MIRROR/$ALPINE_BRANCH/main" \
		--repository "$MIRROR/$ALPINE_BRANCH/community" \
		--repository "$pkgrepo" "$@"
}

# installed: the names of the packages installed in $scratch.
installed() { apk --root "$scratch" info 2>/dev/null | sort | xargs; }

build_main() {
	printf '%s\n' "$MIRROR/$ALPINE_BRANCH/main" "$MIRROR/$ALPINE_BRANCH/community" \
		> /etc/apk/repositories
	apk upgrade --update --quiet
	apk add --quiet alpine-sdk tar

	# Alpine's linux-rpi must still be the one the package was made from.
	local aport=/src/rpi/linux-rpi base alpine key
	base=$(sed -n 's/^_alpine=//p' "$aport"/APKBUILD)
	alpine=$(apk search --exact linux-rpi | grep '^linux-rpi-[0-9]') ||
		die "Alpine $ALPINE_BRANCH has no linux-rpi"
	[[ $alpine == "linux-rpi-$base" ]] ||
		die "Alpine's linux-rpi is $alpine, rpi/linux-rpi/APKBUILD is based on" \
			"linux-rpi-$base: update it"

	# A throwaway signing key, kept so that a package built before still
	# installs.
	mkdir -p /root/.abuild /work/keys
	if [[ ! -f /work/keys/abuild.conf ]]; then
		abuild-keygen -a -n -q 2>/dev/null
		cp /root/.abuild/* /work/keys/
	fi
	cp /work/keys/* /root/.abuild/
	cp /work/keys/*.pub /etc/apk/keys/

	# Built again only when the package's files or Alpine's linux-rpi changed.
	key=$({
		echo "$ALPINE_BRANCH $alpine"
		cd "$aport" && find . -type f -exec sha256sum {} + | sort -k 2
	} | sha256sum | cut -d ' ' -f 1)
	local src=/work/src/cervino/linux-rpi
	rm -rf /work/src
	mkdir -p "$src" /work/distfiles
	cp -R "$aport"/. "$src"/
	local apk
	apk=/work/packages/cervino/aarch64/$(cd "$src" && abuild -F listpkg)
	rm -f /work/packages/current
	if [[ $(cat /work/packages/key 2>/dev/null) == "$key" && -f $apk ]]; then
		echo ">>> cervino-kernel: built already"
	else
		rm -rf /work/packages
		(cd "$src" && SRCDEST=/work/distfiles REPODEST=/work/packages abuild -F -r) ||
			die "could not build cervino-kernel"
		echo "$key" > /work/packages/key
	fi
	# What the VM tests (the host goes on only with it).
	echo "$key" > /work/packages/current
	echo
	pkgrepo=/work/packages/cervino
	check_package "$apk"
}

# --check: checks the package in /repo, a build's (CI's), as --build does
# its own.
check_main() {
	printf '%s\n' "$MIRROR/$ALPINE_BRANCH/main" "$MIRROR/$ALPINE_BRANCH/community" \
		> /etc/apk/repositories
	apk upgrade --update --quiet
	apk add --quiet tar
	local_repo /tmp/repo
	check_package "$(echo "$pkgrepo"/aarch64/cervino-kernel-[0-9]*.apk)"
}

# local_repo DIR: makes DIR a repo of /repo's cervino-kernel alone, indexed
# again and signed with a throwaway key (the build's is gone), which apk
# then trusts, and which is enough for it to trust the package. Sets
# pkgrepo, and pubkey to the key.
local_repo() {
	pkgrepo=$1
	apk add --quiet abuild
	rm -rf "$pkgrepo"
	mkdir -p "$pkgrepo"/aarch64
	cp /repo/cervino-kernel-[0-9]*.apk "$pkgrepo"/aarch64/
	abuild-keygen -a -n -q 2>/dev/null
	pubkey=$(echo ~/.abuild/*.pub)
	cp "$pubkey" /etc/apk/keys/
	apk index --quiet --no-warnings --allow-untrusted -o "$pkgrepo"/aarch64/APKINDEX.tar.gz \
		"$pkgrepo"/aarch64/*.apk
	abuild-sign -q "$pkgrepo"/aarch64/APKINDEX.tar.gz
}

# check_package APK: the package's checks, with it in $pkgrepo and its key
# in /etc/apk/keys.
check_package() {
	local apk=$1 base
	base=$(sed -n 's/^_alpine=//p' /src/rpi/linux-rpi/APKBUILD)

	# What the package provides and runs.
	local info
	info=$(tar -xzOf "$apk" .PKGINFO 2>/dev/null)
	local desc="cervino-kernel provides linux-rpi at Alpine's version"
	if grep -qx "provides = linux-rpi=$base" <<< "$info"; then
		pass "$desc"
	else
		fail "$desc" "provides: $(sed -n 's/^provides = //p' <<< "$info" | xargs)"
	fi
	desc="cervino-kernel has its pre-install script, and no other"
	local scripts
	scripts=$(tar -tzf "$apk" 2>/dev/null | grep -E '^\.(pre-|post-|trigger)' | xargs)
	if [[ $scripts == .pre-install ]]; then
		pass "$desc"
	else
		fail "$desc" "scripts: ${scripts:-none}"
	fi

	# The config: Alpine's linux-rpi's, but for what 16 KB pages change
	# (bcm2712_defconfig's options and those that follow from them) and
	# ours (cervino-changes.config and those its options bring in).
	local ours=/tmp/config-ours theirs=/tmp/config-alpine
	tar -xzOf "$apk" --wildcards 'boot/config-*' > "$ours" 2>/dev/null
	apk fetch --quiet --stdout linux-rpi | tar -xzO --wildcards 'boot/config-*' \
		> "$theirs" 2>/dev/null
	desc="Kernel config has 16 KB pages"
	if grep -qx CONFIG_ARM64_16K_PAGES=y "$ours"; then
		pass "$desc"
	else
		fail "$desc" "$(grep -E '^CONFIG_ARM64_[0-9]+K_PAGES=' "$ours")"
	fi
	local expected
	expected='ARM64_(4K|16K)_PAGES|ARM64_VA_BITS(_[0-9]+)?|ARM64_PAGE_SHIFT|'
	expected+='ARM64_CONT_[PM]E_SHIFT|PGTABLE_LEVELS|ARCH_MMAP_RND(_COMPAT)?_BITS(_MIN|_MAX)?|'
	expected+='ARCH_FORCE_MAX_ORDER|ARM64_PA_BITS(_[0-9]+)?|SERIAL_RPI_FW|LOCALVERSION|'
	expected+='HAVE_ARCH_TRANSPARENT_HUGEPAGE_PUD|VIRTIO(_[A-Z_]+)?|DRM_VIRTIO_GPU(_[A-Z_]+)?|'
	expected+='SND_VIRTIO|BLK_MQ_VIRTIO|NET_FAILOVER|FAILOVER'
	local changed
	changed=$(diff <(grep -E '^CONFIG_' "$theirs" | sort) <(grep -E '^CONFIG_' "$ours" | sort) |
		sed -n 's/^[<>] CONFIG_\([A-Z0-9_]*\)=.*/\1/p' | sort -u |
		grep -vxE "$expected" | xargs) || true
	desc="Kernel config is Alpine's linux-rpi's, but for the page size and virtio"
	if [[ -s $theirs && -n $(cat "$ours") && -z $changed ]]; then
		pass "$desc"
	else
		fail "$desc" "also changed: ${changed:-(could not read the configs)}"
	fi

	# The kernel image's header: flags (a 64-bit word at byte 24), whose
	# bits 1-2 are the page size, 1 for 4 KB, 2 for 16 KB.
	local image=/tmp/vmlinuz flags
	tar -xzOf "$apk" boot/vmlinuz-rpi16k > "$image" 2>/dev/null
	flags=$(od -An -t u8 -j 24 -N 8 "$image" | tr -d ' ')
	desc="Kernel image's header says 16 KB pages"
	if [[ $(od -An -c -j 56 -N 4 "$image" | tr -d ' ') == ARMd && -n $flags ]] &&
		((((flags >> 1) & 3) == 2)); then
		pass "$desc"
	else
		fail "$desc" "header flags: ${flags:-none}"
	fi

	# Taking linux-rpi's place, and giving it back as the apk wrapper deletes
	# cervino-kernel: a conflict in world first (!cervino-kernel), then del.
	scratch=$(mktemp -d)
	mkdir -p "$scratch"/etc/apk
	cp -R /etc/apk/keys "$scratch"/etc/apk/
	desc="cervino-kernel takes linux-rpi's place"
	if ! apk_scratch add --initdb linux-rpi || [[ ! -f $scratch/boot/vmlinuz-rpi ]]; then
		fail "$desc" "could not install Alpine's linux-rpi"
	elif ! apk_scratch add cervino-kernel; then
		fail "$desc" "apk add cervino-kernel failed"
	elif [[ " $(installed) " == *" linux-rpi "* || -e $scratch/boot/vmlinuz-rpi ||
		! -f $scratch/boot/vmlinuz-rpi16k ]]; then
		fail "$desc" "installed: $(installed)"
	else
		pass "$desc"
	fi
	desc="Deleting cervino-kernel (as the apk wrapper does) brings linux-rpi back"
	if ! apk_scratch add '!cervino-kernel' || ! apk_scratch del cervino-kernel; then
		fail "$desc" "apk failed"
	elif [[ " $(installed) " == *" cervino-kernel "* || -e $scratch/boot/vmlinuz-rpi16k ||
		! -f $scratch/boot/vmlinuz-rpi ||
		$(xargs < "$scratch"/etc/apk/world) != linux-rpi ]]; then
		fail "$desc" "installed: $(installed); world: $(xargs < "$scratch"/etc/apk/world)"
	else
		pass "$desc"
	fi
	rm -rf "$scratch"

	# This container is no atomic install (no /etc/kernel/cmdline).
	desc="pre-install turns down a system that is not an atomic install"
	tar -xzOf "$apk" .pre-install > /tmp/pre-install 2>/dev/null
	if [[ ! -s /tmp/pre-install ]]; then
		fail "$desc" "the package has no pre-install script"
	elif sh /tmp/pre-install 2>/dev/null; then
		fail "$desc" "it accepted this container"
	else
		pass "$desc"
	fi
	totals
}

# ---------------------------------------------------------------------------
# --vm: installs the VM's system and boots it with each kernel.
# ---------------------------------------------------------------------------
# chroot_run COMMAND...: runs a command in the VM's system.
chroot_run() { chroot "$root" "$@"; }

# make_system: installs the VM's system into $root and makes the disk image,
# $guest/disk.pristine, from it.
make_system() {
	local host=/work/host pkgs world
	rm -rf "$root"
	mkdir -p "$root"/etc/apk "$root"/etc/kernel "$root"/etc/mkinitfs
	if [[ -n $small ]]; then
		cp -R /etc/apk/keys /etc/apk/repositories "$root"/etc/apk/
	else
		cp -R "$host"/keys "$host"/repositories "$root"/etc/apk/
		[[ ! -d $host/repositories.d ]] || cp -R "$host"/repositories.d "$root"/etc/apk/
		cp "$pubkey" "$root"/etc/apk/keys/
	fi
	# As on an atomic install, where the kernel hook builds the initramfs
	# (and update-boot then does nothing, as this is none), here with the
	# VM's drivers, and cervino-kernel's pre-install accepts it. The small
	# system has no hook: mkinitfs's trigger builds it.
	echo "root=LABEL=cervino-root" > "$root"/etc/kernel/cmdline
	echo 'features="base btrfs keymap kms virtio"' > "$root"/etc/mkinitfs/mkinitfs.conf
	[[ -n $small ]] || echo disable_trigger=yes >> "$root"/etc/mkinitfs/mkinitfs.conf
	# This machine's world, cervino-kernel for linux-rpi, plus linux-virt and
	# the packages ci/guest/packages.sh adds; or the small system, what
	# guest_main needs.
	if [[ -n $small ]]; then
		world="alpine-base mkinitfs kmod bash doas btrfs-progs apparmor apparmor-openrc"
		world+=" apparmor-profiles zram-init zram-init-openrc"
		pkgs="cervino-kernel linux-virt"
	else
		world=$(grep -vx linux-rpi "$host"/world | xargs)
		pkgs="cervino-kernel linux-virt cervino-gstreamer cervino-terminal cervino-upnp"
	fi
	echo ">>> Installing the VM's system"
	# shellcheck disable=SC2086
	apk add --root "$root" --initdb --quiet --repository "$pkgrepo" \
		$world $pkgs || die "could not install the VM's system"
	[[ -f $root/boot/initramfs-rpi16k && -f $root/boot/initramfs-virt ]] ||
		die "no initramfs was made"

	mount --rbind /dev "$root"/dev
	mount -t proc proc "$root"/proc
	mount --rbind /sys "$root"/sys
	echo cervino-kernel-test > "$root"/etc/hostname
	printf '127.0.0.1\tcervino-kernel-test localhost\n::1\tlocalhost\n' > "$root"/etc/hosts
	printf '%s\n' 'LABEL=cervino-root / btrfs defaults 0 0' \
		'LABEL=cervino-swap none swap sw 0 0' >> "$root"/etc/fstab
	# A getty on the serial console, as the lbu shim wraps it.
	local getty=/sbin/getty
	[[ -n $small ]] || getty="/usr/libexec/cervino/apparmor-exec busybox-getty $getty"
	echo "ttyAMA0::respawn:$getty -L 115200 ttyAMA0 vt100" >> "$root"/etc/inittab
	local level service runlevels=$host/runlevels
	if [[ -n $small ]]; then
		runlevels=/tmp/runlevels
		printf '%s\n' 'sysinit devfs' 'sysinit dmesg' 'sysinit mdev' 'sysinit hwdrivers' \
			'boot apparmor' 'boot modules' 'boot sysctl' 'boot hostname' 'boot bootmisc' \
			'boot syslog' 'boot swap' 'boot zram-init' > "$runlevels"
		# Swap on zram, as cervino-desktop's (Alpine's adds file systems).
		printf '%s\n' load_on_start=yes unload_on_stop=yes num_devices=1 type0=swap \
			size0=512 algo0=zstd labl0=zram_swap > "$root"/etc/conf.d/zram-init
	else
		ln -sfn /etc/zoneinfo/"$(cat "$host"/timezone)" "$root"/etc/localtime
	fi
	while read -r level service; do
		[[ -e $root/etc/init.d/$service ]] || continue
		mkdir -p "$root"/etc/runlevels/"$level"
		ln -sfn /etc/init.d/"$service" "$root"/etc/runlevels/"$level"/"$service"
	done < "$runlevels"
	# tester, as setup-user makes the user (live/adduser and setup-alpine's
	# groups), with no password and doas without one, as ci/guest/install.sh
	# leaves it; root locked, as the lbu shim leaves it.
	chroot_run adduser -D -s /bin/bash -g Tester tester
	local groups=(wheel audio input video netdev plugdev lpadmin)
	[[ -z $small ]] || groups=(wheel)
	# shellcheck disable=SC2016 # expanded by the chroot's shell
	chroot_run sh -c 'for g; do addgroup tester "$g"; done' sh "${groups[@]}"
	chroot_run passwd -d tester > /dev/null
	chroot_run passwd -l root > /dev/null
	chmod 0700 "$root"/home/tester
	mkdir -p "$root"/etc/doas.d
	echo 'permit nopass tester' > "$root"/etc/doas.d/kernel-test.conf
	rm -f "$root"/etc/machine-id
	# As setup-disk does on an install.
	[[ -n $small ]] || "$root"/usr/libexec/cervino/widevine "$root" ||
		echo ">>> could not install Widevine: its test will fail with both kernels" >&2
	umount -R "$root"/dev "$root"/proc "$root"/sys

	echo ">>> Making the disk image"
	cp "$root"/boot/vmlinuz-rpi16k "$root"/boot/initramfs-rpi16k \
		"$root"/boot/vmlinuz-virt "$root"/boot/initramfs-virt "$guest"/
	rm -f "$guest"/disk.pristine
	truncate -s 32G "$guest"/disk.pristine
	mkfs.btrfs -q -L cervino-root --rootdir "$root" "$guest"/disk.pristine ||
		die "could not make the disk image"
	rm -rf "$root"
}

# vm_start NAME [QEMU ARGS...]: boots the VM with its serial console on a
# pair of FIFOs; output goes to /work/NAME.log, input through fd 3.
vm_start() {
	vm=$1
	shift
	log=/work/$vm.log
	mark=0
	rm -f "$guest"/serial.in "$guest"/serial.out
	mkfifo "$guest"/serial.in "$guest"/serial.out
	: > "$log"
	echo ">>> [$vm] starting the VM"
	# QEMU's virtio-mmio devices are legacy (virtio 0.9) unless told
	# otherwise, which virtio-gpu and virtio-sound refuse.
	qemu-system-aarch64 "${accel[@]}" \
		-m "$VM_MEMORY" -smp "$VM_CPUS" -global virtio-mmio.force-legacy=false \
		-display none -monitor none -serial pipe:"$guest"/serial \
		-drive file="$guest"/disk.img,if=none,format=raw,id=root \
		-device virtio-blk-device,drive=root,serial=root \
		-drive file="$guest"/share.tar,if=none,format=raw,readonly=on,id=share \
		-device virtio-blk-device,drive=share,serial=share \
		-drive file="$guest"/swap.img,if=none,format=raw,id=swap \
		-device virtio-blk-device,drive=swap,serial=swap \
		-netdev user,id=net -device virtio-net-device,netdev=net \
		-device virtio-gpu-device \
		-audiodev none,id=snd -device virtio-sound-device,audiodev=snd \
		"$@" > /dev/null 2>"$guest"/qemu.err &
	qemu_pid=$!
	cat < "$guest"/serial.out > "$log" &
	cat_pid=$!
	exec 3<>"$guest"/serial.in
}

# vm_stop: powers the VM off and waits for QEMU to exit.
vm_stop() {
	echo ">>> [$vm] powering off"
	send "doas poweroff"
	local end=$((SECONDS + 300))
	while kill -0 "$qemu_pid" 2>/dev/null; do
		((SECONDS < end)) || { echo ">>> [$vm] did not power off"; kill "$qemu_pid"; }
		sleep 2
	done
	wait "$qemu_pid" || true
	wait "$cat_pid" || true
	exec 3>&-
}

send() { printf '%s\r' "$*" >&3; }

# wait_for REGEX SECONDS: waits for console output after the previous match
# to match the extended regex; false if it doesn't in time or QEMU exits.
wait_for() {
	local re=$1 end=$((SECONDS + $2)) hit
	while ((SECONDS < end)); do
		hit=$(tail -c +$((mark + 1)) "$log" | grep -aEob -m1 -- "$re" | head -n1) || true
		if [[ -n $hit ]]; then
			match=${hit#*:}
			mark=$((mark + ${hit%%:*} + ${#match}))
			return 0
		fi
		kill -0 "$qemu_pid" 2>/dev/null || return 1
		sleep 2
	done
	return 1
}

# vm_run COMMAND SECONDS: runs a command as root (doas) in tester's login
# shell on the serial console, leaving its exit status in rc; false if it
# does not finish in time.
vm_run() {
	send "doas sh -c '$1'; printf '@@RC=%s@@\\n' \$?"
	wait_for '@@RC=[0-9]+@@' "$2" || return
	rc=${match//[!0-9]/}
}

# vm_test COMMAND SECONDS: runs a test command (vm_run); false if it does not
# finish in time, or fails without printing any results (it stopped early).
vm_test() {
	local start=$mark
	vm_run "$@" || { echo ">>> [$vm] timed out: $1"; return 1; }
	((rc == 0)) || [[ -n $(tail -c +$((start + 1)) "$log" | results) ]] || {
		echo ">>> [$vm] exited $rc without results: $1"
		return 1
	}
}

# results [LOG]: the results the guest printed (in LOG, or read from the
# standard input): [PASS], [FAIL] or [SKIP] and the test's description, one
# per line.
results() {
	tr -d '\r' < "${1:-/dev/stdin}" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' |
		sed -n 's/^\[\(PASS\|FAIL\|SKIP\)\] \(.*\)$/\1 \2/p'
}

# boot KERNEL: boots the VM's system with KERNEL (rpi16k or virt) and runs
# the tests; false if the VM did not get as far as running them.
boot() {
	local kernel=$1 cmdline
	cmdline="root=LABEL=cervino-root rootfstype=btrfs modules=virtio_mmio,virtio_blk,btrfs"
	cmdline+=" console=ttyAMA0 $(cat /work/host/cmdline)"
	cp --reflink=auto "$guest"/disk.pristine "$guest"/disk.img
	# Swap made at the kernel's page size: the kernel refuses swap made at
	# another (README.md, The 16 KB page kernel).
	local pagesize=4096
	[[ $kernel != rpi16k ]] || pagesize=16384
	truncate -s 4G "$guest"/swap.img
	mkswap -q -p "$pagesize" -L cervino-swap "$guest"/swap.img
	vm_start "$kernel" -kernel "$guest"/vmlinuz-"$kernel" \
		-initrd "$guest"/initramfs-"$kernel" -append "$cmdline"
	local share='rm -rf /tmp/ci && mkdir /tmp/ci && tar -xf /dev/disk/by-id/virtio-share -C /tmp/ci'
	local ok=
	if wait_for 'login: ' 900; then
		send tester
		# The small system has only what guest_main checks.
		if wait_for '~('$'\e''\[[0-9;]*m)*[#$] ' 120 &&
			vm_test "$share && bash /tmp/ci/test/kernel.sh --guest" 1200 &&
			{ [[ -n $small ]] || vm_test "$share && /tmp/ci/ci/guest/test.sh sys" 3600; }; then
			ok=1
		else
			# What the log needs to tell why (the console's own messages
			# stop at the login prompt).
			local diag='ls -l /dev/dri; lsmod | grep -iE "gpu|drm"; rc-status -a'
			vm_run "$diag; tail -n 100 /var/log/messages" 120 || true
		fi
		vm_stop
	else
		kill "$qemu_pid" 2>/dev/null
		wait "$qemu_pid" "$cat_pid" || true
		exec 3>&-
		cat "$guest"/qemu.err >> "$log"
	fi
	[[ -n $ok ]]
}

vm_main() {
	printf '%s\n' "$MIRROR/$ALPINE_BRANCH/main" "$MIRROR/$ALPINE_BRANCH/community" \
		> /etc/apk/repositories
	apk upgrade --update --quiet
	apk add --quiet qemu-system-aarch64 qemu-hw-display-virtio-gpu grep btrfs-progs \
		util-linux coreutils tar
	small=${SMALL:-}
	local inputs=(/src/test/kernel.sh)
	if [[ -n $small ]]; then
		local_repo /tmp/repo
	else
		pkgrepo=/work/packages/cervino pubkey=$(echo /work/keys/*.pub)
		cp "$pubkey" /etc/apk/keys/
		inputs+=(/work/host/world /work/host/repositories /work/host/runlevels)
	fi
	# Without KVM (a CI runner), QEMU emulates the CPU: a few times slower.
	accel=(-machine 'virt,gic-version=host' -accel kvm -cpu host)
	if [[ ${ACCEL:-} == tcg || ! -w /dev/kvm ]]; then
		accel=(-machine 'virt,gic-version=3' -accel 'tcg,thread=multi'
			-cpu 'max,pauth-impdef=on')
		echo ">>> No KVM: QEMU emulates the CPU"
	fi

	guest=/work/guest root=/vm-root
	mkdir -p "$guest"
	# The system is installed again when the package, this machine's world
	# or repositories, or this script changed (and once a day, to pick up
	# updates).
	local key
	key=$(cat "$pkgrepo"/aarch64/*.apk "${inputs[@]}" | sha256sum | cut -d ' ' -f 1)
	key="$key $(date -u +%F)"
	if [[ $(cat "$guest"/key 2>/dev/null) != "$key" || ! -f $guest/disk.pristine ]]; then
		rm -f "$guest"/key
		make_system
		echo "$key" > "$guest"/key
	fi
	tar -C /src -cf "$guest"/share.tar --owner=0 --group=0 test ci/guest

	local kernel
	declare -A booted
	for kernel in rpi16k virt; do
		if boot "$kernel"; then
			booted[$kernel]=1
		else
			echo ">>> [$kernel] the VM did not run the tests (see $kernel.log)"
		fi
	done
	echo

	# The 16 KB page kernel's results; a failure the 4 KB one has too is the
	# VM's, not the page size's.
	local desc="VM boots with cervino-kernel and runs the tests"
	if [[ -n ${booted[rpi16k]:-} ]]; then pass "$desc"; else fail "$desc" "see rpi16k.log"; fi
	desc="VM boots with linux-virt (4 KB pages) and runs the tests"
	if [[ -n ${booted[virt]:-} ]]; then pass "$desc"; else fail "$desc" "see virt.log"; fi
	local result baseline
	baseline=$(results /work/virt.log | sed -n 's/^FAIL //p')
	while read -r result desc; do
		case $result in
		PASS) pass "$desc" ;;
		SKIP) skip "$desc" "skipped in the VM" ;;
		FAIL)
			if [[ -n ${booted[virt]:-} ]] && grep -qxF -- "$desc" <<< "$baseline"; then
				skip "$desc" "fails with 4 KB pages too: see virt.log"
			else
				fail "$desc" "with 16 KB pages only: see rpi16k.log"
			fi ;;
		esac
	done < <(results /work/rpi16k.log)
	totals
}

# ---------------------------------------------------------------------------
# --guest: in the VM, as root: the kernel's own checks.
# ---------------------------------------------------------------------------
guest_main() {
	local expected=4096 desc out
	[[ $(uname -r) == *-rpi16k ]] && expected=16384

	desc="Page size is $expected bytes ($(uname -r))"
	out=$(getconf PAGESIZE)
	if [[ $out == "$expected" ]]; then pass "$desc"; else fail "$desc" "it is $out"; fi

	desc="AppArmor is on, with profiles in enforce mode"
	out=$(grep -c '(enforce)$' /sys/kernel/security/apparmor/profiles 2>/dev/null) || out=0
	if [[ $(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) == Y ]] && ((out > 0)); then
		pass "$desc"
	else
		fail "$desc" "$out profiles in enforce mode"
	fi

	# btrfs's sectors (4 KB) are smaller than 16 KB pages, which it handles
	# apart ("subpage"): data must come back as written, and scrub find no
	# errors.
	desc="btrfs root reads back what was written, and scrubs clean"
	local file=/var/tmp/kernel-test.bin sum
	dd if=/dev/urandom of="$file" bs=1M count=256 2>/dev/null
	sum=$(sha256sum < "$file")
	sync
	echo 3 > /proc/sys/vm/drop_caches
	if [[ $(sha256sum < "$file") != "$sum" ]]; then
		fail "$desc" "the file read back differs"
	elif ! out=$(btrfs scrub start -B / 2>&1) || ! grep -q 'no errors found' <<< "$out"; then
		fail "$desc" "$(tr '\n' ' ' <<< "$out")"
	else
		pass "$desc"
	fi
	rm -f "$file"

	desc="Swap: zram and the swap disk"
	out=$(awk 'NR > 1 { print $1 }' /proc/swaps | xargs)
	if [[ $out == *zram* && $(readlink -f /dev/disk/by-id/virtio-swap) == /dev/vd? &&
		" $out " == *" $(readlink -f /dev/disk/by-id/virtio-swap) "* ]]; then
		pass "$desc"
	else
		fail "$desc" "swaps: ${out:-none}"
	fi

	desc="Modules load: nf_tables, wireguard, tun, fuse, overlay, veth, bridge"
	if out=$(modprobe -a nf_tables wireguard tun fuse overlay veth bridge 2>&1); then
		pass "$desc"
	else
		fail "$desc" "$out"
	fi

	desc="Kernel log has no oops, BUG or warning"
	out=$(dmesg | grep -E 'BUG:|Oops|WARNING:|Call trace:|Unable to handle' | head -n 3) || :
	if [[ -z $out ]]; then pass "$desc"; else fail "$desc" "$out"; fi
	totals
}

case ${1:-} in
--build) build_main ;;
--check) check_main ;;
--vm) vm_main ;;
--guest) guest_main ;;
-*) die "usage: $0 [REPO_DIR]" ;;
*) (($# <= 1)) || die "usage: $0 [REPO_DIR]"; host_main "$@" ;;
esac
