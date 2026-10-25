# Cervino

Build a bootable x86_64 Alpine Linux live ISO, or a Raspberry Pi SD card
image, that starts straight into the GNOME desktop.

The image is Alpine's "standard" ISO plus everything `setup-desktop gnome`
would install and enable, so you don't need to run `setup-alpine` first.
Boot it and you land in GNOME, logged in as a live user.

On top of plain `setup-desktop gnome`, the ISO comes with what you'd expect
from a desktop distribution, and keeps it when installed to disk:

- bash as the login shell, with completion and a command-not-found handler,
  `nano` as `EDITOR`, `~/.local/bin` first in `PATH`, man pages and the usual
  CLI tools (`file`, `xz`, `zstd`, `lspci`, `dmidecode`, `rsync`), and
  `gcompat` so programs built for glibc run
- a UTF-8 locale (`C.UTF-8`), English spell checking, emoji and CJK fonts
- NetworkManager, with dnsmasq as the local DNS server, so a VPN's internal
  names go to the VPN's DNS server and everything else to the network's (with
  several servers in `resolv.conf`, musl takes whichever answers first),
  Wi-Fi power saving turned off on Broadcom SDIO chips (`brcmfmac`, as on
  the Raspberry Pi), where it adds latency and drops connections,
  chrony for time sync (the installer skips its NTP step, so
  busybox ntpd isn't added next to it), and `openrc-settingsd` for GNOME
  Settings' hostname, date/time and language panels
- Bluetooth, CUPS printing, Avahi mDNS, an nftables firewall (allowing SSH,
  mDNS and AirPlay in, forwarding for container and VM bridges, and an IPv6
  reverse path filter dropping spoofed source addresses), and power
  profiles
- OpenSSH installed, but sshd not enabled until you turn it on
  (`rc-update add sshd`): the installer's SSH step defaults to none. sftp
  runs the external `sftp-server`, so sshd's AppArmor profile need not
  allow access to the user's files
- AppArmor, with profiles in enforce mode for udev, D-Bus, syslog, cron, elogind,
  polkit, NetworkManager, chrony, earlyoom, GDM, UDisks, CUPS, fwupd, sshd,
  ...; (see [`apparmor.d/`](apparmor.d)), zram swap (half the RAM, at most
  8 GB), `earlyoom`, which kills the process using the most memory (browser
  tabs first, never the GNOME session or login) before running out freezes
  the desktop, a crash dump collector writing to `/var/lib/coredump` (dumps
  are deleted after a week), a system log kept to 40 MB instead of busybox syslogd's
  400 KB, a weekly `fstrim` for SSDs (with discards let through an
  encrypted root), cronie in place of busybox crond, with anacron running
  the daily, weekly and monthly jobs after boot or resume when the machine
  was off at their time, and Intel and AMD CPU microcode
  updates, loaded by the boot loader (x86_64 only)
- PipeWire as the sound server (in place of PulseAudio), its audio threads
  given real-time priority through RealtimeKit, with AirPlay
  speakers on the network as outputs (playing after 30 s of silence starts
  a new AirPlay session, so a speaker that has dropped the old one
  recovers), `xdg-utils`, Flatpak
  with Flathub, and the SPICE guest agent for VMs
- `gst-libav` (FFmpeg's decoders for GStreamer): multithreaded H.264 and
  HEVC, and the AC-3, E-AC-3 and DTS sound tracks of most video files, and
  dav1d's AV1 decoder (`gst-plugins-rs-dav1d`)
- Alpine's packages in GNOME Software: `apk-polkit-server` runs at boot, and
  the AppStream catalog of the repositories in `/etc/apk/repositories` is
  fetched when a network connection comes up and daily (the live system's
  only repository is the disc, so this takes effect on installed systems;
  not on atomic installs, whose system is read-only)
- logging out without the logout dialog waiting on GNOME Shell, and back to
  GDM's login screen, and logging in through that screen without the new
  session freezing (Alpine's gnome-shell is newer than its gnome-session
  and GDM: it never answers gnome-session's end-of-session queries, and its
  call registering the session with GDM fails, so GDM takes the end of every
  session, the login screen's included, for a crash; a session helper, run
  in user sessions and in the login screen, does both for it)

[`test/features.sh`](test/features.sh) checks all of this on a running
system. [`test/apparmor.sh`](test/apparmor.sh) checks that AppArmor confines
the system daemons.

## Requirements

- Linux host with `podman` or `docker`
- `curl` (used to look up the latest Alpine release)
- Network access to the Alpine mirror and `gitlab.alpinelinux.org`

The build itself runs inside an `alpine` container, so nothing else needs to
be installed on the host.

## Usage

```sh
./build-alpine-gnome-iso.sh
```

The ISO is written to `./out/`. For the [Raspberry Pi](#raspberry-pi) image,
set `TARGET=rpi`.

Settings are passed as environment variables, for example:

```sh
ALPINE_BRANCH=v3.24 LIVE_USER=me LIVE_PASSWORD=secret AUTOLOGIN=0 \
    ./build-alpine-gnome-iso.sh
```

| Variable        | Default                                    | Description                                                         |
| --------------- | ------------------------------------------ | ------------------------------------------------------------------- |
| `TARGET`        | `iso`                                      | `iso` for the x86_64 ISO, `rpi` for the aarch64 Raspberry Pi image  |
| `ALPINE_BRANCH` | latest stable                              | Alpine release branch, e.g. `v3.24`                                 |
| `OUTDIR`        | `./out`                                    | Where the image is written                                          |
| `LIVE_USER`     | `alpine`                                   | Desktop user created at boot                                        |
| `LIVE_PASSWORD` | none                                       | That user's password; with none, doas and admin prompts don't ask   |
| `AUTOLOGIN`     | `1`                                        | Set to `0` to stop at the GDM login screen instead of logging in    |
| `BROWSER`       | `firefox`                                  | Browser package to install, as in `setup-desktop`                   |
| `CONTAINER`     | `podman`, else `docker`                    | Container runtime to use                                            |
| `MIRROR`        | `https://dl-cdn.alpinelinux.org/alpine`    | Alpine package mirror                                               |
| `SIGNING_KEY`   | a new key each build                       | abuild private key to sign `cervino-desktop` and the image's repo   |
| `APK_REPO`      | none                                       | URL (without the branch) of the repo installs get `cervino-desktop` updates from; its packages must be signed with `SIGNING_KEY` |

### Prebuilt ISOs

The [Build ISO](.github/workflows/build-iso.yml) GitHub Actions workflow runs
the script on every push and pull request that touches it, for both targets,
and uploads the ISO and the Raspberry Pi image, each with its `SHA256SUMS`, as
workflow artifacts. You can also start it by hand from the Actions tab and
choose an Alpine branch there. Pushing a `v*` tag also publishes both images
as a GitHub release, and the `cervino-desktop` package to the update repo
(see [Updates](#updates)).

After building, the workflow tests the ISO in a QEMU/KVM VM with
[`ci/vm-test.sh`](ci/vm-test.sh). The test boots the ISO, installs it to a
virtual disk with `setup-alpine`, checks that nothing of the live session
was copied to the installed system, runs `test/features.sh` in the
installed user's GNOME session and `test/apparmor.sh` as root, runs an app
in the session that takes memory until something kills it and checks that
earlyoom does, before the kernel's OOM killer and without touching GNOME
Shell, then logs out and checks that GDM's login screen comes back. It
installs as an atomic install, so it then restarts the installed system
three more times: `update-alpine add` stages a new version with a package
added and leaves the running one alone, the restart switches to it with
the changes made to `/etc` meanwhile, and `update-alpine rollback` goes
back. Both the live system and the installed one must
get through all this without a single AppArmor denial. The build fails, and no release is
published, unless every test passes. The Raspberry Pi image is built but not
tested this way: QEMU can't emulate a Pi that runs GNOME. To run the same
test locally (it needs
`qemu-system-x86_64`, `xorriso` and access to `/dev/kvm`):

```sh
ci/vm-test.sh out/*.iso
```

Before that, [`ci/update-test.sh`](ci/update-test.sh) tests `update-alpine`
from the package just built, in Alpine containers: it has to upgrade the
packages, and, starting from the release before with a stand-in
`cervino-desktop` installed from a local repo, wait until that repo has
packages for the newer release, then offer it, change nothing when that is
turned down, and upgrade to it, `cervino.list` included, when accepted
(`ci/update-test.sh out/repo` runs it locally).

## Updates

The desktop features' configuration (and the packages they need) is the
`cervino-desktop` package, so it can change on systems already installed.
Release images point apk at an extra repository on this project's GitHub
Pages, `https://martinrixham.github.io/cervino/<branch>`, through
`/etc/apk/repositories.d/cervino.list`, and trust its signing key. A new
`cervino-desktop` arrives with the next `apk upgrade`, or in GNOME
Software's updates, like any other package. If it depends on a new
package, that comes from Alpine's own repositories along with it.

**Update Alpine Linux** in the app grid (or `doas update-alpine` in a
terminal) asks for your password, upgrades every package in a terminal
window, and then, when a newer stable Alpine release is out, offers to
upgrade the system to it: it moves `/etc/apk/repositories` (and
`cervino.list`) to the new branch, upgrades `apk-tools` and then everything
with `apk upgrade --available`, and offers to restart. The release is only
offered once this project's repository has a package for it. The live
system hides the launcher, since it runs from RAM. `doas update-alpine add
PACKAGE...` and `doas update-alpine del PACKAGE...` add and remove packages.

On an atomic install, all of that happens to a new version of the system,
a copy of the running one, upgraded in a chroot, while the running system
stays as it was (apk itself cannot change it). The new version is staged:
the system starts with it next time. At that shutdown, the changes made to
`/etc` since the update are copied into it (where the update changed a file
you changed meanwhile too, yours is kept and the update's is saved next to
it as `.apk-new`), and it becomes the default in the boot menu. Further
updates before the restart add up in the same new version. The versions
before stay in the boot menu under **Earlier versions**, the four newest of
them kept, so a version that doesn't work can be started from there, and
`doas update-alpine rollback` then makes the version before the running one
the default again (as a new copy of it, with its `/etc` as it was).
`/var` and `/home` are shared, so data is never rolled back.

Each `v*` tag publishes the release's package to the `gh-pages` branch,
which holds nothing but that repository (written by CI alone, never merged):
`<branch>/<arch>/APKINDEX.tar.gz` with the newest five packages, and the
public key, `cervino.rsa.pub`. Release builds and the repo are signed with
the `APK_SIGNING_KEY` secret of the `release` environment, which only `v*`
tags can use. To set this up for a fork:

1. Make a key: `openssl genrsa -out cervino.rsa 2048` (or `abuild-keygen
   -n`). Keep it safe: whoever holds it can change every installed system.
2. In Settings → Environments, create a `release` environment, limit its
   deployment branches and tags to the tag pattern `v*`, and save the key's
   contents as its `APK_SIGNING_KEY` secret. If others can push to the
   repository, also restrict who can create `v*` tags with a tag ruleset.
3. Push a `v*` tag. The first release creates the `gh-pages` branch.
4. In Settings → Pages, serve the `gh-pages` branch (root).

Images built without `SIGNING_KEY` and `APK_REPO`, such as CI builds of pushes and pull
requests, get no update repository: only tag builds are signed for it.

## Booting the ISO

The live system runs entirely from RAM (tmpfs), so you need **about 6 GB of
RAM or more** to boot it. Write it to a USB stick or attach it to a VM, for
example:

```sh
qemu-system-x86_64 -enable-kvm -m 8G -cdrom out/*.iso
```

The live user is in the `wheel` group and can use `doas` to get root. By
default it has no password: the login and lock screens take an empty one, and
`doas` and GNOME's administrator prompts let it through without asking. Set
`LIVE_PASSWORD` to give it one, in which case they ask for that.

### Installing to disk

`setup-alpine` works from inside the running desktop: open **Install Alpine
Linux** from the app grid, or run `doas setup-alpine` in a terminal. The ISO
puts a wrapper in front of it that:

- stops runlevel changes from shutting down `gdm` and `dbus` (which would kill
  the session you're running it from),
- keeps `udev` as the device manager, which GNOME needs, instead of switching
  to `mdev`,
- skips the network interface and DNS questions, because NetworkManager
  manages the network,
- enables the community repository, where GNOME lives, by default,
- offers only mirrors that serve packages over HTTPS (set `MIRRORS` to
  choose your own list),
- adds the new user to the `plugdev` and `lpadmin` groups as well, so they can
  change network settings and manage printers, gives them bash as the
  login shell, and makes their home directory readable only by them (users
  added later in GNOME Settings get the same),
- enables AppArmor on the installed system's kernel command line, keeps
  every AppArmor message in the kernel log (without auditd the kernel would
  otherwise drop all but a few), and lets discards through an encrypted root so `fstrim` reaches the SSD (on the
  Pi it also raises the firmware's 32 MB cap on an NVMe drive's host memory
  buffer to 64 MB, so DRAM-less drives that need 64 MB get one, and turns
  the memory cgroup controller, which the firmware turns off, back on, and
  sets `console=tty1`, so an encrypted root's passphrase is asked for on
  the screen rather than on the debug UART),
- enables `cronie` (with anacron) where it would enable busybox `crond`,
- leaves `acpid` disabled, which would power off as soon as the power button
  is pressed; elogind handles the button instead, so GNOME's setting for it
  applies,
- skips the root password question and locks root's password on the
  installed system when you create an admin user (the default), who gets
  root with `doas` instead,
- leaves the live session out of the installed system,
- offers an atomic install, a system kept as versions (see below).

An answer file passed with `-f` still overrides these defaults.

The disk step first asks how to install the system:

- **atomic** (the default; `-m atomic` in an answer file's `DISKOPTS`): the
  system is read-only and updated as a whole, as in Fedora Silverblue. Each
  update is a new version of the system, which it starts with next time, and
  the four versions before stay (in the boot menu, on a PC). It asks for one
  disk and whether to encrypt it.
- **sys** (`-m sys`): Alpine's standard install, updated in place, with
  Alpine's own disk questions. So does every other `setup-disk` option
  (`data` or LVM mode, RAID, several disks).

On a PC, an atomic install erases the disk and makes four partitions: a 1 MiB BIOS
boot partition, a 1 GiB FAT boot partition (the EFI system partition,
mounted on `/boot/efi`), swap (twice the RAM, at most 4 GiB or a quarter of
the disk, as Alpine sizes it; encrypted with a new random key at each boot
if the disk is) and a btrfs volume, inside LUKS2 if you chose encryption
(its passphrase is asked for at every boot). The volume holds each version
of the system as a read-only subvolume, `roots/<date and time>`, with a
writable `/etc` of its own nested in it, beside `@var` and `@home`, which
all versions share and which are mounted on `/var` and `/home` (root's
home is `/var/roothome`). [Limine](https://limine-bootloader.org) boots the
disk from the boot partition, on UEFI or BIOS alike, so each version's
kernel, initramfs and CPU microcode are copied there; the
`cervino-desktop` package's `update-boot` does that, and writes Limine's
menu. Each version's kernel arguments are in its `/etc/kernel/cmdline`.
GNOME Software installs apps from Flatpak only, as apk cannot write to the
system: `update-alpine` installs packages (see [Updates](#updates)), and
`doas apk add`, `del` and `upgrade` hand over to it.

Like any Alpine `sys` install, the disk gets a copy of the running system: the
same packages (so GNOME, and the `cervino-desktop` package, which holds the
desktop features' configuration) and your changes under `/etc`. The live user, its
home directory, its doas and polkit rules, its init script and GDM autologin
are dropped from that copy, so create a user in `setup-alpine`'s user step and
log in as that user. Without one there is no account GDM can log in to.

## Raspberry Pi

```sh
TARGET=rpi ./build-alpine-gnome-iso.sh
```

builds `out/alpine-gnomelive-<release>-aarch64.img.gz`, an SD card image for
the Raspberry Pi 4, 400, 5 and 500. Like the ISO, the live system runs from
RAM, so it needs a Pi with **8 GB of RAM or more**. The image is built from
Alpine's own Pi image, with the same packages, settings and features as the
ISO (except the Intel VA-API drivers and the CPU microcode), so it doesn't
need an ARM host or emulation. It also turns on the GPU's KMS driver
(`dtoverlay=vc4-kms-v3d` in `usercfg.txt`), which GNOME needs.

Write it to an SD card or USB drive with Raspberry Pi Imager ("Use custom"),
or with:

```sh
gunzip -c out/alpine-gnomelive-*-aarch64.img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync
```

Installing works as from the ISO (see [Installing to disk](#installing-to-disk)),
to a USB or NVMe drive or to the SD card the Pi booted from: everything runs
from RAM, so `setup-alpine` offers to unmount it. The installed system's boot
partition gets the same `usercfg.txt`.

An atomic install on the Pi erases the disk and makes an MBR partition
table, as the Pi's firmware starts from its first partition: a 1 GiB FAT
boot partition (mounted on `/boot/firmware`, as on Raspberry Pi OS), swap
only if asked for (`-s`, as Alpine does on the Pi) and the btrfs volume,
encrypted or not, as on a PC. The firmware starts the system itself, with
no boot menu: each version's kernel, initramfs, device trees, overlays and
`cmdline.txt` are copied to `cervino/<date and time>/` on the boot
partition, and `config.txt` (written by `update-boot`; your settings go in
`usercfg.txt`) starts the newest with `os_prefix=`, listing the earlier
versions in comments. So going back is `doas update-alpine rollback`, or,
if the new version does not start, putting an earlier version's directory
in `os_prefix` on another computer. This has not been tested on a Pi yet:
QEMU can't run the Pi's firmware.

## How it works

The script uses Alpine's own image tooling, `aports/scripts/mkimage.sh`, with
a custom profile (`gnomelive`) that extends `profile_standard`:

1. **Host:** works out the Alpine release and re-runs itself in an
   `alpine:<release>` container, mounting the output directory. For the Pi,
   `mkimage.sh` builds for aarch64 in the host's own container: it fetches
   the aarch64 packages and assembles the image without running them.
2. **Container:** installs the build tools, creates an unprivileged `build`
   user and an abuild signing key (`mkimage.sh` must run unprivileged).
3. **Builder:** sparse-clones `aports/scripts`, resolves the package list
   that `setup-desktop gnome` would install plus the desktop features listed
   above, and generates:
   - the `cervino-desktop` package, built with abuild from
     [`cervino-desktop/APKBUILD`](cervino-desktop/APKBUILD): the desktop
     features' configuration and the AppArmor profiles from
     [`apparmor.d/`](apparmor.d), depending on the features' packages;
   - the mkimage profile, which adds those packages and `cervino-desktop`
     (with all dependencies) to the ISO's on-disc apk repository (for the
     Pi it extends Alpine's `rpiimg` profile instead, and adds
     `usercfg.txt`);
   - an apkovl generator. The apkovl is the same overlay mechanism `lbu` uses;
     it contains what only the live system needs: `/etc/apk/world`, the GDM
     config, OpenRC runlevels (udev in place of mdev, plus `cgroups`,
     `dbus`, `gdm` and the desktop features' services, and AppArmor in
     `sysinit`, before udev), a `live-user` init script, and the
     `setup-alpine` wrapper with its `lbu` and `adduser` shims.
4. At boot the initramfs unpacks the apkovl, installs everything in its
   `/etc/apk/world` from the disc into the RAM root, and OpenRC starts udev,
   dbus, gdm and so on just as `setup-desktop` would have configured them.

## License

[Apache License 2.0](LICENSE)
