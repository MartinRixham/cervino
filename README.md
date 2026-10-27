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
- the Wi-Fi region set to the time zone's country (as chosen in the
  installer or GNOME Settings, and following it when it changes), so the
  country's channels and power limits apply, including for a hotspot; a
  time zone with no country (UTC) keeps the kernel's world region, and
  drivers that set the region themselves (Intel's) ignore it
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
  recovers, and a speaker whose output went away on an error is found
  again), `xdg-utils`, Flatpak
  with Flathub, and the SPICE guest agent for VMs
- `gst-libav` (FFmpeg's decoders for GStreamer): multithreaded H.264 and
  HEVC, and the AC-3, E-AC-3 and DTS sound tracks of most video files, and
  dav1d's AV1 decoder (`gst-plugins-rs-dav1d`)
- DRM video (Netflix, Spotify, ...) in Firefox: Alpine hides Firefox's
  Widevine, which needs `gcompat`; the ISO shows it again, and Firefox
  downloads it from Google when a page first asks and you turn DRM on. On
  the Pi, where Mozilla offers no Widevine, the installer downloads Google's
  arm64 build to `/var/lib/widevine` (it is not in the image, so the live
  system has none) and a weekly job keeps it up to date;
  `doas /usr/libexec/cervino/widevine` fetches it by hand. Firefox finds
  it through `MOZ_GMP_PATH`, set by login shells, so after the first
  download it needs a new login
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
- a **Zellij** launcher in the app grid: the Zellij terminal multiplexer
  in the foot terminal, in the Droid Sans Mono Nerd Font, with move mode
  on Ctrl m (Ctrl h in Zellij's defaults) and no tips at startup
  (`/etc/zellij/config.kdl`, which a `~/.config/zellij/config.kdl` of your
  own replaces). foot's own launchers are hidden, so the app grid shows
  Zellij alone. With it comes **Neovim** set up as AstroNvim, for users
  without a `~/.config/nvim` of their own, its launcher running it in
  foot too. AstroNvim and its plugins download on its first start, so that
  needs the network. Its Tree-sitter parsers are Alpine's, as the system
  has no C compiler to build them, so they don't install on demand. All
  this is the `cervino-terminal` package, which
  `doas apk del cervino-terminal` removes

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
| `SIGNING_KEY`   | a new key each build                       | abuild private key to sign the packages built here and the image's repo |
| `APK_REPO`      | none                                       | URL (without the branch) of the repo installs get updates of the packages built here from; its packages must be signed with `SIGNING_KEY` |
| `CACHEDIR`      | none                                       | Where the Raspberry Pi's packages built from `rpi/` are kept; later builds take them from there (signed again with their own key) while their sources, Alpine's version of them and the release are the same |

### Prebuilt ISOs

The [Build ISO](.github/workflows/build-iso.yml) GitHub Actions workflow runs
the script on every push and pull request that touches it, for both targets,
and uploads the ISO and the Raspberry Pi image, each with its `SHA256SUMS`, as
workflow artifacts. You can also start it by hand from the Actions tab and
choose an Alpine branch there. Pushing a `v*` tag also publishes both images
as a GitHub release, and the packages built for them (`cervino-desktop`,
`cervino-vlc`, `cervino-gstreamer`, `cervino-terminal`, and the Pi's
`wpa_supplicant` and `bluez`) to the update repo (see [Updates](#updates)).

After building, the workflow tests the ISO in a QEMU/KVM VM with
[`ci/vm-test.sh`](ci/vm-test.sh). The test boots the ISO, installs it to a
virtual disk with `setup-alpine`, checks that nothing of the live session
was copied to the installed system, runs `test/features.sh` in the
installed user's GNOME session and `test/apparmor.sh` as root, runs an app
in the session that takes memory until something kills it and checks that
earlyoom does, before the kernel's OOM killer and without touching GNOME
Shell, then logs out and checks that GDM's login screen comes back. It runs twice,
in parallel on two runners: once as a sys install, and once as an atomic
install, which it then restarts three more times: `update-alpine add` stages a new version with a package
added and leaves the running one alone, the restart switches to it with
the changes made to `/etc` meanwhile, `update-alpine rollback` goes
back, and `update-alpine delete` removes the updated version. Both the live system and the installed one must
get through all this without a single AppArmor denial. The build fails, and no release is
published, unless every test passes. The Raspberry Pi image is built but not
tested this way: QEMU can't emulate a Pi that runs GNOME. To run the same
test locally (it needs
`qemu-system-x86_64`, `xorriso` and access to `/dev/kvm`):

```sh
ci/vm-test.sh out/*.iso                     # an atomic install
INSTALL_MODE=sys ci/vm-test.sh out/*.iso    # a sys install
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
it as `.apk-new`). Further updates before the restart add up in the same
new version. There is no boot menu: the new version starts once on trial,
with the version before to fall back on. Once it has started, it is the one
that starts from then on. If it doesn't start, switch the computer off and
on: the version before starts again, and the new one is not tried again
(`update-alpine list` shows it as "did not start when tried"). On a PC the
firmware does that (UEFI's `BootNext`), on a Raspberry Pi its tryboot (see
[Raspberry Pi](#raspberry-pi)). The four newest versions before are kept,
and `doas update-alpine rollback` makes the version before the running one
the one that starts again (as a new copy of it, with its `/etc` as it was).
`doas update-alpine list` lists the versions, newest first, with which one
is running and which the system starts with next time, and `doas
update-alpine delete ID...` deletes versions you no longer want (a staged
update too, which cancels it); the running version can't be deleted.
`/var` and `/home` are shared, so data is never rolled back.

Each `v*` tag publishes the release's packages to the `gh-pages` branch,
which holds nothing but that repository (written by CI alone, never merged):
`<branch>/<arch>/APKINDEX.tar.gz` with the newest five versions of each
package (a version already there stays as it was), and the
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

The live system runs from a read-only image of the installed system on the
disc, with only what changes kept in RAM, so **2 GB of RAM** is enough to
boot it to the desktop (4 GB or more to do much in it). Write it to a USB
stick or attach it to a VM, for example:

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
- skips the HTTP proxy and user SSH key questions, which are for servers
  (GNOME Settings has its own proxy settings),
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
  update is a new version of the system, which it starts with next time
  (once on trial first), and the four versions before stay. It asks for one
  disk and whether to encrypt it. The system is copied from the image the
  live system runs from, so installing downloads nothing (but packages
  added in the live session). On a PC it needs UEFI: a PC started without it
  (legacy BIOS) gets a sys install.
- **sys** (`-m sys`): Alpine's standard install, updated in place, with
  Alpine's own disk questions. So does every other `setup-disk` option
  (`data` or LVM mode, RAID, several disks). The system is copied from the
  same image, with the boot loader from the disc, so this downloads nothing
  either (but firmware the image lacks for the machine's hardware, if the
  mirror can be reached).

On a PC, an atomic install erases the disk and makes three partitions: a
1 GiB FAT boot partition (the EFI system partition, mounted on
`/boot/efi`), swap (twice the RAM, at most 4 GiB or a quarter of
the disk, as Alpine sizes it; encrypted with a new random key at each boot
if the disk is) and a btrfs volume, inside LUKS2 if you chose encryption
(its passphrase is asked for at every boot). The volume holds each version
of the system as a read-only subvolume, `roots/<date and time>`, with a
writable `/etc` of its own nested in it, beside `@var` and `@home`, which
all versions share and which are mounted on `/var` and `/home` (root's
home is `/var/roothome`). UEFI starts the system with no boot loader: each
version is a unified kernel image (its kernel, CPU microcode, initramfs and
kernel arguments in one file, made by `ukify`) on the boot partition,
`cervino/<date and time>/linux.efi`, with a UEFI boot entry of its own,
"Alpine Linux" and its date and time, so the firmware's boot menu can start
any of them too. The `cervino-desktop` package's `update-boot` makes them
and the entries, puts the version that starts first in `BootOrder` and sets
`BootNext` to a version on trial. It also copies the version that starts to
`EFI/BOOT/BOOTX64.EFI`, which the firmware starts if it loses the boot
entries. Each version's kernel arguments are in its `/etc/kernel/cmdline`.
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
the Raspberry Pi 4, 400, 5 and 500. Like the ISO's, the live system runs
from a read-only image on the card, so a Pi with **2 GB of RAM** should do
(4 GB or more to do much in it; not yet measured on a Pi). The image is built from
Alpine's own Pi image, with the same packages, settings and features as the
ISO (except the Intel VA-API drivers and the CPU microcode). It also turns on the GPU's KMS driver
(`dtoverlay=vc4-kms-v3d` in `usercfg.txt`), which GNOME needs.

The Pi image also has VLC, built with Raspberry Pi OS's patches for the
Pi's video decoders, as Raspberry Pi OS ships it: HEVC (H.265) on the Pi 4
and 5, and H.264 on the Pi 4 (the Pi 5 has no H.264 decoder), decoded by
the hardware and shown without copying the frames. It plays through
`ffmpeg7`'s libraries, built with Raspberry Pi OS's FFmpeg patch, which
replace Alpine's for every program that uses them. GStreamer's base and bad
plug-ins are built with Raspberry Pi OS's patches too, so what plays
through GStreamer (GNOME's Showtime, GNOME Web, the file previews) decodes
HEVC on the Pi 4's and 5's decoder. Firefox uses Alpine's FFmpeg 8, and so
decodes in software on the Pi.

All four are Alpine's packages with the patches applied
([`rpi/`](rpi)), and come in two packages, `cervino-vlc` (VLC with its
FFmpeg) and `cervino-gstreamer` (GStreamer's plug-ins), which take the
place of Alpine's packages of the same names and come from the update repo
with `cervino-desktop`. Either can be removed:

```sh
doas apk del cervino-vlc          # no VLC; Alpine's FFmpeg 7 for the rest
doas apk add vlc-qt               # then, for Alpine's VLC
doas apk del cervino-gstreamer    # Alpine's GStreamer plug-ins
```

Alpine's packages then take their place, without the hardware decoding
(`doas apk add` switches back). On a PC both packages are empty: the
system uses Alpine's packages, and the PC image has no VLC.

The Pi's Wi-Fi and Bluetooth are set up as on Raspberry Pi OS too: the
Wi-Fi driver leaves roaming and the WPA2/WPA3 handshakes to wpa_supplicant
rather than the chip's firmware, which does them unreliably, with
Raspberry Pi OS's wpa_supplicant patches that go with that (so
NetworkManager uses WPA3, and falls back to WPA2 where it must), and
BlueZ gives Bluetooth audio priority on the radio the Pi shares between
Wi-Fi and Bluetooth, so headphones don't stutter while Wi-Fi is busy.
These packages come from the update repo too. The build compiles all six,
which takes tens of minutes on an arm64 host, and hours under QEMU
emulation on an x86_64 one.

Write it to an SD card or USB drive with Raspberry Pi Imager ("Use custom"),
or with:

```sh
gunzip -c out/alpine-gnomelive-*-aarch64.img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync
```

Installing works as from the ISO (see [Installing to disk](#installing-to-disk)),
to a USB or NVMe drive, but for now not to the SD card the Pi booted from:
the live system runs from an image on it, so it can't be unmounted. The
installed system's boot partition gets the same `usercfg.txt`.

An atomic install on the Pi erases the disk and makes an MBR partition
table, as the Pi's firmware starts from its first partition: a 1 GiB FAT
boot partition (mounted on `/boot/firmware`, as on Raspberry Pi OS), swap
only if asked for (`-s`, as Alpine does on the Pi) and the btrfs volume,
encrypted or not, as on a PC. The firmware starts the system itself, with
no boot menu: each version's kernel, initramfs, device trees, overlays and
`cmdline.txt` are copied to `cervino/<date and time>/` on the boot
partition, and `config.txt` (written by `update-boot`; your settings go in
`usercfg.txt`) starts one with `os_prefix=`, listing the others in
comments. A Pi whose firmware has tryboot (the Pi 4 and 5 families with a
current bootloader) tries a new version once:
`config.txt` stays on the version that last started, `tryboot.txt` names
the new one, and restarting (from GNOME, `doas reboot` or
`update-alpine`'s offer) restarts with the firmware's tryboot flag, so
the new version starts that one time. Once it has started, `config.txt`
names it. If it doesn't start, switching the Pi off and on starts the
version before again, and the new one is not tried again (`update-alpine
list` shows it as "did not start when tried"). Switching off instead of
restarting can't use tryboot, so the next start goes straight to the new
version, with nothing to fall back on, as on older firmware. Going back
from a version that starts is `doas update-alpine rollback`, or, from one
that doesn't, putting an earlier version's directory in `os_prefix` on
another computer.

## How it works

The script uses Alpine's own image tooling, `aports/scripts/mkimage.sh`, with
a custom profile (`gnomelive`) that extends `profile_standard`:

1. **Host:** works out the Alpine release and re-runs itself in an
   `alpine:<release>` container of the target's architecture, mounting the
   output directory. Building the Pi image on an x86_64 host (or the ISO on
   an arm64 one) needs QEMU user emulation, e.g. `qemu-user-static`.
2. **Container:** installs the build tools, creates an unprivileged `build`
   user and an abuild signing key (`mkimage.sh` must run unprivileged).
3. **Builder:** sparse-clones `aports/scripts`, resolves the package list
   that `setup-desktop gnome` would install plus the desktop features listed
   above, and generates:
   - for the Pi, the `ffmpeg7`, `vlc`, `gst-plugins-base`,
     `gst-plugins-bad`, `wpa_supplicant` and `bluez` packages, built with
     abuild from [`rpi/`](rpi): Alpine's, with Raspberry Pi OS's patches
     for the Pi's hardware video decoders, Wi-Fi and Bluetooth (the build
     stops when Alpine's packages are no longer the versions those are
     based on);
   - the `cervino-vlc` and `cervino-gstreamer` packages, built with
     abuild from [`cervino-vlc/APKBUILD`](cervino-vlc/APKBUILD) and
     [`cervino-gstreamer/APKBUILD`](cervino-gstreamer/APKBUILD): for the
     Pi, the runtime packages of `ffmpeg7` and `vlc`, and of
     `gst-plugins-base` and `gst-plugins-bad`, each pair in one, providing
     their names at Alpine's versions; empty on a PC;
   - the `cervino-terminal` package, built with abuild from
     [`cervino-terminal/APKBUILD`](cervino-terminal/APKBUILD): the Zellij
     launcher and configuration, depending on Alpine's `zellij`, `foot`
     and `font-droid-sans-mono-nerd`, and Neovim's launcher and AstroNvim
     configuration ([`cervino-terminal/init.lua`](cervino-terminal/init.lua)),
     depending on `neovim` and `tree-sitter-grammars`;
   - the `cervino-desktop` package, built with abuild from
     [`cervino-desktop/APKBUILD`](cervino-desktop/APKBUILD): the desktop
     features' configuration and the AppArmor profiles from
     [`apparmor.d/`](apparmor.d), depending on the features' packages;
   - the mkimage profile, [`mkimg.gnomelive.sh`](mkimg.gnomelive.sh), which puts the root file system on the image,
     with an on-disc apk repository of only the disk tools and boot loaders
     Alpine's `setup-disk` adds, and no modloop (for the Pi it extends
     Alpine's `rpiimg` profile instead, and adds `usercfg.txt`);
   - the initramfs's init: Alpine's, with
     [`initramfs-live.patch`](initramfs-live.patch);
   - an apkovl generator, [`genapkovl-gnomelive.sh`](genapkovl-gnomelive.sh). The apkovl is the same overlay mechanism `lbu` uses;
     it contains what only the live system needs: `/etc/apk/world`, the GDM
     config, OpenRC runlevels (udev in place of mdev, plus `cgroups`,
     `dbus`, `gdm` and the desktop features' services, and AppArmor in
     `sysinit`, before udev), a `live-user` init script, and the
     `setup-alpine` wrapper with its `lbu`, `adduser`, `setup-disk` and `apk`
     shims (the scripts are in [`live/`](live)).
4. **Root file system:** the same packages, plus the kernel and firmware,
   installed once, with their scripts run, and packed into a squashfs,
   `cervino/rootfs.squashfs` on the image. Then `mkimage.sh` builds the
   image.
5. At boot the initramfs mounts the squashfs read-only with a tmpfs over it
   (an overlay) as the root, unpacks the apkovl into it, and OpenRC starts
   udev, dbus, gdm and so on just as `setup-desktop` would have configured
   them. Nothing is installed at boot, and only what changes takes RAM.

## License

[Apache License 2.0](LICENSE)
