#!/usr/bin/env bash
#
# ci/vm-test.sh ISO
#
# Tests the ISO end to end in QEMU/KVM, driven over the serial console:
#
#   1. install: boots the ISO and installs it to a blank virtual disk with
#      setup-alpine (through the ISO's wrapper, as a user would), as an
#      atomic or a sys install ($INSTALL_MODE)
#   2. test:    boots the installed system into GNOME, logged in as the
#               user created during the install, and runs
#               test/features.sh in that desktop session and
#               test/apparmor.sh as root, then logs out and checks
#               that GDM's login screen comes back
#   3. upgrade: (atomic installs only) four more boots, in which
#               ci/guest/upgrade.sh has
#               update-alpine stage an update of the atomic install,
#               checks that the system switched to it at the restart,
#               that a rollback goes back, that update-alpine
#               list and delete work, and that an update that does
#               not start falls back to the version before
#
# Exits non-zero if either stage fails or any test fails. The serial console
# output of each boot is streamed to stdout and kept in $WORKDIR/<stage>.log.
#
# The guest gets test/ and ci/guest/ as a tar archive on a
# second virtual disk, /dev/vdb.
#
# An atomic install needs UEFI, so its VM has OVMF, with variables kept
# across its boots in $WORKDIR/efivars.fd (the boot entries the install
# makes, the one-time BootNext of an update); a sys install's has the
# default BIOS.
#
# Environment overrides:
#   INSTALL_MODE  atomic or sys, setup-disk's -m (default: atomic)
#   WORKDIR     disk image, logs etc. (default: ./vm-test)
#   VM_MEMORY   guest RAM; the live system runs from RAM (default: 8G)
#   VM_CPUS     guest CPUs (default: all host CPUs)
#   OVMF_CODE, OVMF_VARS  OVMF's firmware and variable store templates
#               (default: found in /usr/share)

set -euo pipefail
export LC_ALL=C

ISO=${1:?usage: $0 ISO}
REPO=$(dirname "$(dirname "$(realpath "$0")")")
WORKDIR=$(realpath -m "${WORKDIR:-./vm-test}")
VM_MEMORY=${VM_MEMORY:-8G}
VM_CPUS=${VM_CPUS:-$(nproc)}
INSTALL_MODE=${INSTALL_MODE:-atomic}

die() { echo "error: $*" >&2; exit 1; }

case $INSTALL_MODE in atomic | sys) ;; *) die "INSTALL_MODE must be atomic or sys" ;; esac

qemu_pid=
vm_user=root
tee_pid=
cleanup() {
	[[ -n $qemu_pid ]] && kill "$qemu_pid" 2>/dev/null
	[[ -n $tee_pid ]] && kill "$tee_pid" 2>/dev/null
	return 0
}
trap cleanup EXIT

# vm_start NAME [QEMU ARGS...]: boots the VM with its serial console on a
# pair of FIFOs; output goes to $WORKDIR/NAME.log, input through fd 3.
vm_start() {
	vm=$1
	shift
	log=$WORKDIR/$vm.log
	mark=0
	rm -f "$WORKDIR"/serial.in "$WORKDIR"/serial.out
	mkfifo "$WORKDIR"/serial.in "$WORKDIR"/serial.out
	: > "$log"

	echo ">>> [$vm] starting VM"
	qemu-system-x86_64 \
		-enable-kvm -cpu host -m "$VM_MEMORY" -smp "$VM_CPUS" \
		-display none -monitor none \
		-serial pipe:"$WORKDIR"/serial \
		-nic user,model=virtio-net-pci \
		-drive file="$WORKDIR"/disk.qcow2,if=virtio,format=qcow2 \
		-drive file="$WORKDIR"/share.tar,if=virtio,format=raw,readonly=on \
		-audiodev none,id=snd0 -device intel-hda -device hda-output,audiodev=snd0 \
		-device virtio-serial -chardev null,id=vdagent \
		-device virtserialport,chardev=vdagent,name=com.redhat.spice.0 \
		"${firmware[@]}" "$@" &
	qemu_pid=$!
	tee "$log" < "$WORKDIR"/serial.out &
	tee_pid=$!
	exec 3<>"$WORKDIR"/serial.in
}

# vm_stop: powers the VM off and waits for QEMU to exit.
vm_stop() {
	echo ">>> [$vm] powering off"
	# The test boot is logged in as tester, who needs doas.
	if [[ $vm_user == root ]]; then send poweroff; else send "doas poweroff"; fi
	local end=$((SECONDS + 300))
	while kill -0 "$qemu_pid" 2>/dev/null; do
		((SECONDS < end)) || { echo ">>> [$vm] did not power off; killing QEMU"; kill "$qemu_pid"; }
		sleep 2
	done
	wait "$qemu_pid" || true
	wait "$tee_pid" || true
	qemu_pid= tee_pid=
	exec 3>&-
}

send() { printf '%s\r' "$*" >&3; }

# wait_for REGEX SECONDS: waits for console output after the previous match
# to match the extended regex, and leaves the matched text in $match.
wait_for() {
	local re=$1 end=$((SECONDS + $2)) hit
	while ((SECONDS < end)); do
		hit=$(tail -c +$((mark + 1)) "$log" | grep -aEob -m1 -- "$re" | head -n1) || true
		if [[ -n $hit ]]; then
			match=${hit#*:}
			mark=$((mark + ${hit%%:*} + ${#match}))
			return 0
		fi
		kill -0 "$qemu_pid" 2>/dev/null || die "[$vm] VM exited while waiting for /$re/"
		sleep 2
	done
	die "[$vm] timed out after $2s waiting for /$re/"
}

# vm_run USER COMMAND SECONDS: logs in as USER (with an empty password) on
# the serial console, runs the command there and sets $rc to its exit status.
vm_run() {
	wait_for 'login: ' 1200
	vm_user=$1
	send "$1"
	wait_for '~[#$] ' 120
	# The marker is printed with printf so that the echoed command line
	# cannot match it.
	send "$2; printf '@@RC=%s@@\\n' \$?"
	wait_for '@@RC=[0-9]+@@' "$3"
	rc=${match//[!0-9]/}
	echo
	echo ">>> [$vm] exit status $rc"
}

unpack_share='rm -rf /tmp/ci && mkdir /tmp/ci && tar -xf /dev/vdb -C /tmp/ci'

command -v qemu-system-x86_64 >/dev/null || die "need qemu-system-x86_64"
command -v xorriso >/dev/null || die "need xorriso"
[[ -r /dev/kvm && -w /dev/kvm ]] || die "need access to /dev/kvm"

firmware=()
if [[ $INSTALL_MODE == atomic ]]; then
	for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
		/usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/qemu/ovmf-x86_64-code.bin; do
		[[ -n ${OVMF_CODE:-} ]] || [[ ! -f $f ]] || OVMF_CODE=$f
	done
	[[ -f ${OVMF_CODE:-} ]] || die "need OVMF (the ovmf package), or OVMF_CODE and OVMF_VARS"
	OVMF_VARS=${OVMF_VARS:-${OVMF_CODE/CODE/VARS}}
	OVMF_VARS=${OVMF_VARS/-code./-vars.}
	[[ -f $OVMF_VARS ]] || die "no OVMF variable store next to $OVMF_CODE; set OVMF_VARS"
fi

mkdir -p "$WORKDIR"
rm -f "$WORKDIR"/*.log "$WORKDIR"/disk.qcow2 "$WORKDIR"/efivars.fd
if [[ $INSTALL_MODE == atomic ]]; then
	cp "$OVMF_VARS" "$WORKDIR"/efivars.fd
	chmod u+w "$WORKDIR"/efivars.fd
	firmware=(-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
		-drive if=pflash,format=raw,file="$WORKDIR"/efivars.fd)
fi
qemu-img create -q -f qcow2 "$WORKDIR"/disk.qcow2 32G
tar -C "$REPO" -cf "$WORKDIR"/share.tar --owner=0 --group=0 \
	test ci/guest

# The ISO's boot loaders have no serial console, so boot its kernel and
# initramfs directly (through OVMF, as UEFI would, for an atomic install),
# with its own command line plus a serial console; the initramfs still finds
# and boots from the ISO in the CD drive as usual.
xorriso -osirrox on -indev "$ISO" \
	-extract /boot/vmlinuz-lts "$WORKDIR"/vmlinuz-lts \
	-extract /boot/initramfs-lts "$WORKDIR"/initramfs-lts \
	-extract /boot/syslinux/syslinux.cfg "$WORKDIR"/syslinux.cfg 2>/dev/null
chmod u+w "$WORKDIR"/vmlinuz-lts "$WORKDIR"/initramfs-lts "$WORKDIR"/syslinux.cfg
cmdline=$(awk '$1 == "APPEND" { $1 = ""; print; exit }' "$WORKDIR"/syslinux.cfg)
[[ -n $cmdline ]] || die "no kernel command line in the ISO's syslinux.cfg"

vm_start install -cdrom "$ISO" \
	-kernel "$WORKDIR"/vmlinuz-lts -initrd "$WORKDIR"/initramfs-lts \
	-append "$cmdline console=ttyS0,115200"
vm_run root "$unpack_share && /tmp/ci/ci/guest/install.sh $INSTALL_MODE" 3600
vm_stop
((rc == 0)) || die "installing with setup-alpine failed"

vm_start test
# The installed system's root is locked, so log in as the user created
# during the install, whom install.sh lets log in and use doas without a
# password.
vm_run tester "doas sh -c '$unpack_share && /tmp/ci/ci/guest/test.sh $INSTALL_MODE'" 1500
vm_stop
((rc == 0)) || die "$rc test(s) failed"
echo ">>> All OS feature tests passed"

[[ $INSTALL_MODE == atomic ]] || exit 0

# Updating the atomic install: an update is staged, the shutdown switches to
# it, a rollback goes back, and an update that does not start is dropped.
for step in stage check rollback fallback; do
	vm_start "upgrade-$step"
	vm_run tester "doas sh -c '$unpack_share && /tmp/ci/ci/guest/upgrade.sh $step'" 1200
	vm_stop
	((rc == 0)) || die "updating the atomic install failed at: $step"
done
echo ">>> Atomic update and rollback passed"
