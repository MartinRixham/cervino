#!/bin/sh
# Fixes "Device firmware installed". Installs only the linux-firmware-*
# subpackages that the drivers for this machine's hardware ask for, rather
# than all of linux-firmware (several hundred MB).
# Hardware added later (e.g. a USB Wi-Fi adapter) may need this run again.
set -eu
[ "$(id -u)" -eq 0 ] || exec doas "$0" "$@"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Drivers for this hardware: loaded modules, plus any module matching a device.
{
    cut -d' ' -f1 /proc/modules
    find /sys/devices -name modalias -exec cat {} + 2>/dev/null | sort -u |
        xargs -r modprobe -aRq 2>/dev/null || true
} | sort -u > "$tmp/modules"

while read -r mod; do
    modinfo -F firmware "$mod" 2>/dev/null || true
done < "$tmp/modules" | sort -u > "$tmp/firmware"

if [ ! -s "$tmp/firmware" ]; then
    echo "No driver on this machine needs firmware; nothing to install."
    exit 0
fi

# Alpine packages each /lib/firmware/<dir> as linux-firmware-<dir>, and the
# loose top-level files as linux-firmware-other. Top-level names that are
# links into a directory (e.g. iwlwifi-*.ucode -> intel/) go with that
# directory, so look them up in upstream's WHENCE for the packaged version.
ver=$(apk search -x linux-firmware | sed -n 's/^linux-firmware-\([0-9]*\)-r[0-9]*$/\1/p')
if grep -qv / "$tmp/firmware" &&
    ! wget -qO "$tmp/WHENCE" "https://gitlab.com/kernel-firmware/linux-firmware/-/raw/$ver/WHENCE"; then
    echo "Could not fetch WHENCE for linux-firmware $ver; top-level files will come from linux-firmware-other" >&2
    : > "$tmp/WHENCE"
fi

while read -r fw; do
    case $fw in
        */*) ;;
        s5p-mfc*) fw=s5p-mfc/ ;;
        *) fw=$(awk -v f="$fw" '$1 == "Link:" && $2 == f { print $4; exit }' "$tmp/WHENCE") ;;
    esac
    case $fw in
        */*) echo "linux-firmware-${fw%%/*}" ;;
        *) echo linux-firmware-other ;;
    esac
done < "$tmp/firmware" | tr '[:upper:]' '[:lower:]' | sort -u > "$tmp/wanted"

apk search -q 'linux-firmware-*' | sort -u > "$tmp/available"
comm -23 "$tmp/wanted" "$tmp/available" | sed 's/^/No such package, skipping: /' >&2
pkgs=$(comm -12 "$tmp/wanted" "$tmp/available")

echo "Installing:" $pkgs
# shellcheck disable=SC2086
apk add $pkgs
