# mkimg.gnomelive.sh: the gnomelive mkimage profile. build-alpine-gnome-iso.sh
# copies it into aports/scripts/, with mkimg.gnomelive.conf (the build
# settings: gnomelive_target, iso or rpi; gnomelive_kernel_opts, the kernel
# arguments; gnomelive_apks, the on-disc repo's packages) and, for the
# Raspberry Pi, usercfg.txt next to it.
# mkimage reads the variables set here and sets the ones used, and its
# build_section takes the checksum as separate words.
# shellcheck shell=sh disable=SC2034,SC2154,SC2046

# The ISO: Alpine's standard ISO plus GNOME. The Pi's image: Alpine's Pi
# image, one FAT partition with the firmware, kernel, apks and apkovl;
# section_rpi_config only builds the Pi's boot files (config.txt,
# cmdline.txt, firmware) for hostname rpi.
profile_gnomelive() {
	. /work/aports/scripts/mkimg.gnomelive.conf
	if [ "$gnomelive_target" = rpi ]; then
		profile_rpiimg
		image_name="alpine-gnomelive"
		title="GNOME Live"
		desc="Alpine for the Raspberry Pi plus GNOME, booting straight into GDM."
		arch="aarch64"
		output_format="gnomelive"
		hostname="rpi"
	else
		profile_standard
		profile_abbrev="gnome"
		title="GNOME Live"
		desc="Alpine standard plus GNOME, booting straight into GDM."
		arch="x86_64"
		# CPU microcode, loaded by the ISO's boot loaders (as in
		# profile_extended)
		boot_addons="amd-ucode intel-ucode"
		initrd_ucode="/boot/amd-ucode.img /boot/intel-ucode.img"
		hostname="alpine"
	fi
	kernel_cmdline="$kernel_cmdline $gnomelive_kernel_opts"
	apks="$gnomelive_apks"
	apkovl="aports/scripts/genapkovl-gnomelive.sh"
}

# The Pi's config.txt includes usercfg.txt, for settings of our own (see
# build-alpine-gnome-iso.sh).
section_gnomelive_usercfg() {
	[ "$PROFILE" = gnomelive ] && [ -f /work/aports/scripts/usercfg.txt ] || return 0
	build_section gnomelive_usercfg $(checksum < /work/aports/scripts/usercfg.txt)
}

build_gnomelive_usercfg() {
	cp /work/aports/scripts/usercfg.txt "$DESTDIR"/
}

# rpiimg's create_image_imggz makes a FAT16 partition only 8 MB bigger
# than the files, which the slack in its 32 KB clusters fills with this
# many files. FAT32 with 4 KB clusters (which the Pi boots from too),
# a tenth and 64 MB bigger, leaves room for the FAT and some free space.
create_image_gnomelive() {
	sync "$DESTDIR"
	local imgfile="$OUTDIR/${output_filename%.gz}" size
	size=$(du -L -k -s "$DESTDIR" | awk '{ print int($1 * 1.1 / 1024) + 64 }')
	rm -f "$imgfile"
	truncate -s $((size + 1))M "$imgfile"
	echo 'start=2048, type=c, bootable' | sfdisk "$imgfile"
	mkfs.vfat -n PIBOOT -F 32 -s 8 --offset 2048 "$imgfile"
	mcopy -s -i "$imgfile"@@2048s "$DESTDIR"/* "$DESTDIR"/.alpine-release ::
	echo "Compressing $imgfile..."
	pigz -f -9 "$imgfile" || gzip -f -9 "$imgfile"
}

# The root file system image (built by then), the live system's root.
section_gnomelive_rootfs() {
	[ "$PROFILE" = gnomelive ] || return 0
	build_section gnomelive_rootfs $(checksum < /work/rootfs.squashfs)
}

build_gnomelive_rootfs() {
	mkdir -p "$DESTDIR"/cervino
	cp /work/rootfs.squashfs "$DESTDIR"/cervino/
}
