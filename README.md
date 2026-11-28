# Cervino

Build a bootable x86_64 or aarch64 Alpine Linux live ISO, or a Raspberry
Pi SD card image, that starts straight into the GNOME desktop.

The image is Alpine's "standard" ISO plus everything `setup-desktop gnome`
would install and enable, so you don't need to run `setup-alpine` first.
Boot it and you land in GNOME, logged in as a live user.

On top of plain `setup-desktop gnome`, the ISO comes with what you'd expect
from a desktop distribution:

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
- subordinate user and group IDs (`/etc/subuid`, `/etc/subgid`) for every
  user, so rootless containers (podman, toolbox, distrobox) work once
  installed; Alpine gives them only to users made after podman is
  installed, and not to the one the installer makes. The `tun` module is
  loaded at boot, as their network (and userspace VPNs) needs
  `/dev/net/tun`
- suspend turned off in a virtual machine (`cervino-desktop-vm`, installed
  only in a VM): GNOME would otherwise suspend an idle guest, and at once
  when the host wakes from its own sleep, leaving a blank display that the
  hypervisor's keyboard and pointer do not wake
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
  with Flathub, and the SPICE guest agent for VMs (installed only in a VM)
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
  on Ctrl m (Ctrl h in Zellij's defaults), no tips at startup and
  selections copied to the primary selection, pasted with the middle
  button, rather than the clipboard (`/etc/zellij/config.kdl`, which a
  `~/.config/zellij/config.kdl` of your own replaces). foot's own
  launchers are hidden, so the app grid shows Zellij alone. GDM's login
  screen also offers a **Cervino Terminal** session (the cog under the
  password field): the same Zellij in foot, full screen in the cage kiosk
  compositor rather than in GNOME, which logs out when Zellij exits. With it
  comes **Neovim** set up as AstroNvim, for users without a
  `~/.config/nvim` of their own, its launcher running it in foot too.
  AstroNvim and its plugins download on its first start, so that
  needs the network. Its Tree-sitter parsers are Alpine's, as the system
  has no C compiler to build them, so they don't install on demand. The
  command line tools bat, ripgrep (`rg`), fd and GNU less come with it, and
  Fedora's bash: its green prompt, history kept from every shell rather
  than the last one closed overwriting it, `ls` and `grep` in colour, and
  `user@host:dir` as the pane's and window's title. All this is the `cervino-terminal` package,
  which the image leaves out: `doas apk add cervino-terminal` adds it from
  the update repo, and `doas apk del cervino-terminal` removes it
- **Media Sharing** in GNOME Settings (Sharing): Rygel shares the folders
  listed there with UPnP/DLNA players (TVs, Kodi, VLC) on the networks
  it is turned on for. GNOME starts Rygel only through systemd, which
  Alpine lacks, so a session helper starts and stops it as the switch and
  the network change. Rygel serves only on the interface of the network
  the switch is on for, on port 8200, which the firewall opens, with UPnP
  discovery (SSDP, UDP 1900). As Rygel ships, it also plays media other
  devices send it (a UPnP renderer). This is the `cervino-upnp` package,
  which the image leaves out: `doas apk add cervino-upnp` adds it, and it
  works from the next login (on an atomic install, once the restart has
  started the new version)

[`test/features.sh`](test/features.sh) checks all of this on a running
system. [`test/apparmor.sh`](test/apparmor.sh) checks that AppArmor confines
the system daemons.

The update repo also has packages that Alpine lacks, built from
[`extra/`](extra), which the image leaves out and nothing depends on:

- `tui-torrent`, a terminal interface that searches YTS and The Pirate Bay
  and downloads with aria2, which it starts itself when it isn't running.
  Its downloads go to `~/Downloads`. aria2's RPC interface, which it drives,
  listens only on the machine itself and takes a secret that changes each
  run (tui-torrent opened it to the network, with no secret).
  `doas apk add tui-torrent` adds it.
- `bapk` ([Bold APK](https://github.com/martinrixham/bold-apk)), a
  terminal interface for apk: search, install, upgrade and remove
  packages, and look up their known vulnerabilities in Alpine's security
  database. On an atomic install what it installs, removes or upgrades
  goes into a new version of the system, as with `apk` (see
  [Updates](#updates)). `doas apk add bapk` adds it.
- `qstop` ([gnome-qstop](https://github.com/MartinRixham/gnome-qstop)),
  GNOME's quick settings menu in the terminal: volume, microphone and
  brightness, Wi-Fi, Bluetooth, VPN and the other toggles, and lock, log
  out, suspend, restart and power off. `doas apk add qstop` adds it.
- `bijiben`, GNOME Notes 41.1 from
  [a fork](https://gitlab.gnome.org/MartinRixham/bijiben), ported to
  GTK 4 and libadwaita, so unlike the Flathub app (GNOME's 40.2 release,
  GTK 3) it follows GNOME's dark style. Back up your notes before
  pointing it at the same Nextcloud account as another version.
  `doas apk add bijiben` adds it.
- `rpi-keyboard-config`
  ([Raspberry Pi's](https://github.com/raspberrypi/rpi-keyboard-config)),
  which sets the keymaps and RGB lighting of the Raspberry Pi 500 and
  500+ keyboards, for users in the `plugdev` group or at the seat (run
  `rpi-keyboard-config --help`). `doas apk add rpi-keyboard-config` adds
  it, and the keyboard is usable by it from the next restart. It needs
  the keyboard's Vial firmware (1.20 or later), which the first ones
  shipped without: if it says the firmware isn't compatible, update it
  with `rpi-keyboard-fw-update`.
- `rpi-keyboard-fw-update`
  ([Raspberry Pi's](https://github.com/raspberrypi/keyboard-firmware)),
  only for the Pi, which updates the firmware of the Raspberry Pi 500
  and 500+ keyboards to the one it brings, for the Pi's model and
  keyboard layout. `rpi-keyboard-fw-update -v` shows the keyboard and its
  firmware version, `doas rpi-keyboard-fw-update` updates it. Keep a USB
  keyboard at hand in case the update fails. `doas apk add
  rpi-keyboard-fw-update` adds it.
- `tomesole` ([tomesole](https://github.com/ChrisThoma/tomesole)), a
  terminal interface and command line client for searching and
  downloading from Library Genesis (run `tomesole`, or `tomesole doctor`
  to check its setup). `doas apk add tomesole` adds it.
- `spotatui` ([spotatui](https://github.com/LargeModGames/spotatui)), a
  terminal Spotify client (Premium accounts only), built with its Soloist
  engine. Spotify refuses the keys of some accounts' tracks to librespot,
  the open source player inside spotatui and Alpine's `ncspot`: they log
  in and nothing plays. Soloist, Spotify's own headless player, plays for
  those accounts. To use it, make an API key at
  <https://developer.spotify.com/dashboard/soloist>, then in spotatui's
  Settings have Soloist Path download Soloist from Spotify (it may not be
  passed on, so the package has none), set Playback Engine to Soloist,
  and choose spotatui in the device menu of a Spotify app on the same
  network, once (the package opens the firewall to local networks for
  that, on the ports Soloist may listen on). Soloist is built for glibc: the package brings the few
  glibc functions that `gcompat` lacks, and spotatui loads them into it.
  Spotify's builds of Soloist stop working after 90 days: download it
  again then. `doas apk add spotatui` adds it.
- `mullvad-containers`, which lets Firefox Multi-Account Containers send
  each container through a different [Mullvad](https://mullvad.net)
  server, picked by country and city in the container's settings. The
  extension offers this for Mozilla VPN, which runs on Mullvad's servers:
  the package answers it in the Mozilla VPN client's place, with Mullvad's
  SOCKS5 proxies, which are reachable while connected to Mullvad by any
  means, such as WireGuard in NetworkManager. After `doas apk add
  mullvad-containers`, allow the native messaging and proxy permissions
  in the extension's preferences, then restart Firefox. The extension
  still calls the servers Mozilla VPN's.

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

The ISO is written to `./out/`. For the [aarch64 ISO](#aarch64-iso), set
`TARGET=arm64`; for the [Raspberry Pi](#raspberry-pi) image, `TARGET=rpi`.

Settings are passed as environment variables, for example:

```sh
ALPINE_BRANCH=v3.24 LIVE_USER=me LIVE_PASSWORD=secret AUTOLOGIN=0 \
    ./build-alpine-gnome-iso.sh
```

| Variable        | Default                                    | Description                                                         |
| --------------- | ------------------------------------------ | ------------------------------------------------------------------- |
| `TARGET`        | `x86_64`                                   | `x86_64` for the x86_64 ISO, `arm64` for the aarch64 ISO, `rpi` for the aarch64 Raspberry Pi image |
| `ALPINE_BRANCH` | latest stable                              | Alpine release branch, e.g. `v3.24`                                 |
| `OUTDIR`        | `./out`                                    | Where the image is written                                          |
| `LIVE_USER`     | `alpine`                                   | Desktop user created at boot                                        |
| `LIVE_PASSWORD` | none                                       | That user's password; with none, doas and admin prompts don't ask   |
| `AUTOLOGIN`     | `1`                                        | Set to `0` to stop at the GDM login screen instead of logging in    |
| `BROWSER`       | `firefox`                                  | Browser package to install, as in `setup-desktop`                   |
| `CONTAINER`     | `podman`, else `docker`                    | Container runtime to use                                            |
| `MIRROR`        | `https://dl-cdn.alpinelinux.org/alpine`    | Alpine package mirror                                               |
| `SIGNING_KEY`   | a new key each build                       | abuild private key to sign the packages built here and the image's repo; its public key, derived from it, is named after its file plus `.pub` |
| `APK_REPO`      | none                                       | URL (without the branch) of the repo installs get updates of the packages built here from; its packages must be signed with `SIGNING_KEY`, or with `APK_REPO_KEY`'s key |
| `APK_REPO_KEY`  | none                                       | Public key `APK_REPO`'s packages are signed with, when that is not `SIGNING_KEY`'s; installs trust it, under its file name, as well as the build's own |
| `CACHEDIR`      | none                                       | Where the packages built from `rpi/`, `patched/` and `extra/` are kept; later builds take them from there (signed again with their own key) while their sources, Alpine's version of them and the release are the same |
| `ONLY`          | none                                       | Build only these packages from `rpi/`, `patched/` and `extra/` (say `firefox`), into `CACHEDIR`, and no image |
| `CACHE_ONLY`    | none                                       | Take these packages (`all`: every one) from `CACHEDIR`, and stop if they aren't there, rather than building them |

### Prebuilt ISOs

The [Build ISO](.github/workflows/build-iso.yml) GitHub Actions workflow runs
the script on every push and pull request that touches it, for each target,
and uploads the two ISOs and the Raspberry Pi image, each with its
`SHA256SUMS`, as workflow artifacts. It also runs once a day on `main`, so a change in Alpine
that breaks the build (a patched package that Alpine updated, a patch that no
longer applies) shows up without a push. You can also start it by hand from
the Actions tab and choose an Alpine branch there. Pushing a `v*` tag also publishes the images
as a GitHub release, and the packages built for them (`cervino-desktop`,
`cervino-vlc`, `cervino-gstreamer`, `cervino-terminal`, `cervino-upnp`,
`mutter`, `dnsmasq`, `libsoup3`, `tui-torrent`, `bapk`, `qstop`,
`bijiben`, `rpi-keyboard-config`, `tomesole`, `spotatui`,
`mullvad-containers`, `pam-cryptsetup-keyring`, and the Pi's
`wpa_supplicant`, `bluez`, `mesa`, `firefox`, `rpi-keyboard-fw-update` and
`cervino-kernel`) to the update repos (see [Updates](#updates)).

After building, the workflow tests the ISO in a QEMU/KVM VM with
[`ci/vm-test.sh`](ci/vm-test.sh). The test boots the ISO, installs it to a
virtual disk with `setup-alpine`, restarts it to add `cervino-gstreamer`,
`cervino-terminal` and `cervino-upnp` from the packages just built (the image leaves them
out; see [the Pi](#raspberry-pi)), checks that nothing of the live session
was copied to the installed system, runs `test/features.sh` in the
installed user's GNOME session and `test/apparmor.sh` as root, runs an app
in the session that takes memory until something kills it and checks that
earlyoom does, before the kernel's OOM killer and without touching GNOME
Shell, then logs out and checks that GDM's login screen comes back. It runs twice,
in parallel on two runners: once as a sys install, and once as an atomic
install, which it then restarts three more times: `update-alpine add` stages a new version with a package
added and leaves the running one alone, the restart switches to it with
the changes made to `/etc` meanwhile, `update-alpine rollback` goes
back, `update-alpine delete` removes the updated version, and an update
that doesn't start falls back to the version before. Both the live system and the installed one must
get through all this without a single AppArmor denial. The build fails, and no release is
published, unless every test passes. The Raspberry Pi image is built but not
tested this way: QEMU can't emulate a Pi that runs GNOME. Nor is the aarch64
ISO, as GitHub's arm64 runners have no KVM. To run the same
test locally (it needs
`qemu-system-x86_64`, `xorriso` and access to `/dev/kvm`):

```sh
ci/vm-test.sh out/*-x86_64.iso                     # an atomic install
INSTALL_MODE=sys ci/vm-test.sh out/*-x86_64.iso    # a sys install
```

On an aarch64 host with KVM, `ci/vm-test.sh out/*-aarch64.iso` tests the
aarch64 ISO the same way (it needs `qemu-system-aarch64` and AAVMF,
UEFI for QEMU's `virt` machine, which both install modes boot with there).

It takes `cervino-gstreamer`, `cervino-terminal` and `cervino-upnp` from
`out/repo`, next to the ISO, or from the directory given as a second argument.

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
Pages, `https://martinrixham.github.io/cervino/<branch>` for the ISOs and
`https://martinrixham.github.io/cervino/rpi/<branch>` for the Pi (both
hold aarch64 packages, so they need a repository each), through
`/etc/apk/repositories.d/cervino.list`, and trust its signing key. A new
`cervino-desktop` arrives with the next `apk upgrade`, or in GNOME
Software's updates, like any other package. If it depends on a new
package, that comes from Alpine's own repositories along with it. The
patched packages' debug symbols are there too, as their `-dbg` packages
(`doas apk add mutter-dbg`, say).

**Update Alpine Linux** in the app grid (or `doas update-alpine` in a
terminal) asks for your password, upgrades every package in a terminal
window, and then, when a newer stable Alpine release is out, offers to
upgrade the system to it: it moves `/etc/apk/repositories` (and
`cervino.list`) to the new branch, upgrades `apk-tools` and then everything
with `apk upgrade --available`, and offers to restart. The release is only
offered once this project's repository has a package for it. The live
system hides the launcher, since it runs from RAM. `doas update-alpine add
PACKAGE...` and `doas update-alpine del PACKAGE...` add and remove packages;
`add --upgrade` also upgrades those already installed.
bash completes its commands, and the packages to add or remove.

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
the one that starts again (as a new copy of it, with its `/etc` as it was),
or `doas update-alpine rollback ID` any other complete version, newer ones
too.
`doas update-alpine list` lists the versions, newest first, with which one
is running and which the system starts with next time, and `doas
update-alpine delete ID...` deletes versions you no longer want (a staged
update too, which cancels it); the running version can't be deleted.
bash completes the IDs where doas doesn't ask for a password (right after
you entered it), or in a root shell.
`/var` and `/home` are shared, so data is never rolled back.

Each `v*` tag publishes the release's packages, keeping the newest five
versions of each (a version already there stays as it was). The packages
themselves are the assets of a GitHub release per repository and
architecture, `packages-<branch>-<arch>` (and `packages-rpi-<branch>-aarch64`),
which CI creates and keeps up to date; they are not meant to be downloaded
from there by hand. The `gh-pages` branch, which Pages serves, holds only
the indexes, `<branch>/<arch>/APKINDEX.tar.gz` (and
`rpi/<branch>/aarch64/`), each naming its release as where its packages
are, and the public key, `cervino.rsa.pub`. apk checks every package it
downloads against the signed index. The branch is written by CI alone, as
a single commit each time. Release builds and the repo are signed with
the `APK_SIGNING_KEY` secret of the `release` environment, which only `v*`
tags can use. To set this up for a fork:

1. Make a key: `openssl genrsa -out cervino.rsa 2048` (or `abuild-keygen
   -n`). Keep it safe: whoever holds it can change every installed system.
2. Save its public key as the repository variable `APK_PUBLIC_KEY`
   (Settings → Secrets and variables → Actions → Variables, or
   `openssl rsa -in cervino.rsa -pubout | gh variable set APK_PUBLIC_KEY`);
   a release stops if that is not the secret's.
3. In Settings → Environments, create a `release` environment, limit its
   deployment branches and tags to the tag pattern `v*`, and save the key's
   contents as its `APK_SIGNING_KEY` secret. If others can push to the
   repository, also restrict who can create `v*` tags with a tag ruleset.
4. Push a `v*` tag. The first release creates the `gh-pages` branch and
   the `packages-*` releases.
5. In Settings → Pages, serve the `gh-pages` branch (root).

To replace the key (if it leaked, say), make a new one as in step 1 and
save it over the old `APK_SIGNING_KEY` secret, from the environment's
settings page or as below, with its public key:

```sh
openssl genrsa -out cervino.rsa 2048
gh secret set APK_SIGNING_KEY -e release < cervino.rsa
openssl rsa -in cervino.rsa -pubout | gh variable set APK_PUBLIC_KEY
```

Before the first release has been published, that is all. After it, delete
the `gh-pages` branch and the `packages-*` releases (with their tags) too,
so the next release publishes every package signed with the new key (a
package already published would stay signed with the old one). Installed systems trust only the old public key, so they
won't take packages signed with the new one: each has to be given the new
`cervino.rsa.pub` from the `gh-pages` branch in `/etc/apk/keys` by hand.

CI builds of pushes and pull requests can't use the secret, so they are
signed with a key of their own, but their installs get updates from the
same repository when its public key is in the repository variable
`APK_PUBLIC_KEY`: they trust that key too (`APK_REPO_KEY`). They keep the
packages they were built with until a release publishes newer ones.
Without the variable, as without `APK_REPO`, an image gets no update
repository.

### Upgrading to a CI build

To put a CI build's packages on an installed machine before a release
publishes them, run [`ci/local-repo.sh`](ci/local-repo.sh) on that machine,
from a clone of this repository, as your user:

```sh
ci/local-repo.sh            # the last successful run of the checked out branch
ci/local-repo.sh 43640904096   # or a workflow run, by its ID
```

It needs no GitHub login. Each CI run but a tag's (or a pull request's
from a fork) puts its packages on a prerelease of its own, `ci-<run id>`,
as anyone may download release assets but only logged in users artifacts,
and deletes those of runs more than 14 days old. The script downloads the
run's `cervino-repo-<target>.tar` for the machine (`TARGET=rpi`, `arm64` or
`x86_64` to choose another) and serves it on `http://127.0.0.1:8080`
(`PORT`) until you stop it with Ctrl-C. Its packages are signed with that
build's own key, and it has no index, so the script makes one, signed with a key made for the
run, whose private half it deletes before serving. It needs no root, and
changes nothing on the system: it prints the commands that do, with the
paths filled in. In another terminal, have apk trust the two public keys
(the build's, which the `cervino-desktop` package brings, and the index's,
`cervino-local.rsa.pub`), add the repository, and upgrade:

```sh
doas cp /tmp/tmp.XXXXXX/keys/*.pub /etc/apk/keys/   # the directory the script prints
echo http://127.0.0.1:8080/v3.24 | doas tee /etc/apk/repositories.d/local.list
doas update-alpine
```

Then, before restarting, remove the repository and the index's key again,
and stop the script:

```sh
doas rm /etc/apk/repositories.d/local.list /etc/apk/keys/cervino-local.rsa.pub
```

On an atomic install the shutdown takes them out of the new version too.
The build's key (`build-<id>.rsa.pub`) stays in `/etc/apk/keys`, as the
upgraded `cervino-desktop` owns it; if the upgrade did not go through,
remove it as well.

Packages whose version is the one installed are left as they are, though
the build made them anew. The upgraded `cervino-desktop` names the update
repository the build was made for, so the machine goes on to take releases
from there.

## Booting the ISO

The live system runs from a read-only image of the installed system on the
disc, with only what changes kept in RAM, so **2 GB of RAM** is enough to
boot it to the desktop (4 GB or more to do much in it). Write it to a USB
stick or attach it to a VM, for example:

```sh
qemu-system-x86_64 -enable-kvm -m 8G -cdrom out/*-x86_64.iso
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
- leaves the SPICE guest agent (`spice-vdagent`) and `cervino-desktop-vm`
  (no suspend in a VM) out of the installed system unless it is installed
  in a VM (`apk add spice-vdagent spice-vdagent-openrc cervino-desktop-vm`
  adds them back),
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
(its passphrase is asked for at every boot; see
[Encryption and automatic login](#encryption-and-automatic-login)). The volume holds each version
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
`EFI/BOOT/BOOTX64.EFI` (`BOOTAA64.EFI` on aarch64), which the firmware
starts if it loses the boot entries. Each version's kernel arguments are in its `/etc/kernel/cmdline`.
GNOME Software installs apps from Flatpak only, as apk cannot write to the
system: `update-alpine` installs packages (see [Updates](#updates)), and
`doas apk add`, `del` and `upgrade` hand over to it.

Like any Alpine `sys` install, the disk gets a copy of the running system: the
same packages (so GNOME, and the `cervino-desktop` package, which holds the
desktop features' configuration) and your changes under `/etc`. The live user, its
home directory, its doas and polkit rules, its init script and GDM autologin
are dropped from that copy, so create a user in `setup-alpine`'s user step and
log in as that user. Without one there is no account GDM can log in to.

#### Encryption and automatic login

On an encrypted atomic install with **Automatic Login** turned on (GNOME
Settings, Users), the disk's passphrase also unlocks the login keyring, so
apps' saved passwords are there without a second prompt, as on Fedora. The
initramfs asks for it with `cervino-desktop`'s
[`disk-passphrase`](cervino-desktop/disk-passphrase) (the kernel argument
`cryptkey=EXEC=/usr/libexec/cervino/disk-passphrase`, and the
`cervino-passphrase` feature in `/etc/mkinitfs/mkinitfs.conf`), which
leaves it in root's kernel keyring as `cryptsetup`, readable by root only
and gone after five minutes. At the automatic login a PAM module,
`pam_cryptsetup_keyring` ([`extra/pam-cryptsetup-keyring`](extra/pam-cryptsetup-keyring),
added to `/etc/pam.d/gdm-autologin` by `cervino-desktop`), reads it and
hands it to `pam_gnome_keyring`. GDM's own `pam_gdm` does this on other
distributions, but Alpine builds it without keyutils, which it needs.

That only unlocks a login keyring whose password is the disk's passphrase.
The keyring is made at the first login, with the password it was given:
your account's, if you logged in with it before turning on the automatic
login, as you do on a new install. Change the keyring's password to the
disk's passphrase in Passwords and Keys (Seahorse): right-click Login,
Change Password. Do it again after changing the disk's passphrase
(`cryptsetup luksChangeKey`). When they differ, nothing is unlocked, as
before. Only atomic installs made since get it: those encrypted before
keep the initramfs asking for the passphrase itself. To have it do so on a
new install, take `cryptkey=...` out of `/etc/kernel/cmdline`
and run `doas /usr/libexec/cervino/update-boot`. A `sys` install, with
Alpine's own disk setup, doesn't have it.

## aarch64 ISO

```sh
TARGET=arm64 ./build-alpine-gnome-iso.sh
```

builds `out/alpine-gnomelive-<release>-aarch64.iso`, from Alpine's aarch64
standard ISO, for arm64 machines that start with UEFI, and for VMs on an
arm64 host. It boots with GRUB alone (UEFI's only), and runs Alpine's
`linux-lts`. It has the same system as the x86_64 ISO (but the Intel
VA-API drivers and the CPU microcode), with Alpine's VLC, GStreamer, Mesa,
wpa_supplicant and BlueZ: the Pi's patched ones are for the Pi's hardware,
and stay in the Pi's repo. Installing works as from the x86_64 ISO (see
[Installing to disk](#installing-to-disk)), atomic or sys, both with UEFI.

To start it in virt-manager, make a VM from the ISO ("Local install
media"), with the architecture `aarch64` and the machine type `virt` (UEFI
is the firmware there), 4 GB of RAM or more and a virtio disk, and before
starting it pick "Virtio" video (the machine has no display of its own).
With `qemu-system-aarch64` alone (the firmware's path is Fedora's
`edk2-aarch64`'s; Debian's `qemu-efi-aarch64` has
`/usr/share/qemu-efi-aarch64/QEMU_EFI.fd`):

```sh
qemu-system-aarch64 -machine virt -accel kvm -cpu host -m 8G \
    -bios /usr/share/AAVMF/AAVMF_CODE.fd -device virtio-gpu-pci \
    -device qemu-xhci -device usb-kbd -device usb-tablet \
    -drive file=out/alpine-gnomelive-*-aarch64.iso,media=cdrom,if=none,id=cd \
    -device virtio-scsi-pci -device scsi-cd,drive=cd
```

## Raspberry Pi

```sh
TARGET=rpi ./build-alpine-gnome-iso.sh
```

builds `out/alpine-gnomelive-<release>-aarch64.img.gz`, an SD card image for
the Raspberry Pi 5, 500 and CM5, whose kernel has 16 KB memory pages, which
the earlier Pis can't use (see
[The 16 KB page kernel](#the-16-kb-page-kernel)). Like the ISO's, the live system runs
from a read-only image on the card. The image is built from Alpine's own Pi
image, with the same packages, settings and features as the ISO (except
the Intel VA-API drivers and the CPU microcode). It also turns on the GPU's
KMS driver (`dtoverlay=vc4-kms-v3d` in `usercfg.txt`), which GNOME needs.
On an encrypted install the initramfs loads that driver before it asks for
the disk's passphrase (the `cervino-pi-display` feature in
`/etc/mkinitfs/mkinitfs.conf`, and `i2c-brcmstb,snd-soc-hdmi-codec,vc4` in
the kernel's `modules=`), as the Pi's firmware doesn't always leave the
kernel a framebuffer, and without one the prompt isn't on screen.
The Pi can't suspend, so GNOME doesn't try to when it is idle; the screen
still blanks.

The Pi image also has VLC, built with Raspberry Pi OS's patches for the
Pi's video decoder, as Raspberry Pi OS ships it: HEVC (H.265; the Pi 5
has no H.264 decoder), decoded by the hardware and shown without copying
the frames. It plays through
`ffmpeg7`'s libraries, built with Raspberry Pi OS's FFmpeg patch, which
replace Alpine's for every program that uses them. GStreamer's base and bad
plug-ins are built with Raspberry Pi OS's patches too, but left out of the
image: with them added (below), what plays through GStreamer (GNOME's
Showtime, GNOME Web, the file previews) decodes HEVC on the Pi's
decoder. Firefox uses Alpine's FFmpeg 8, and so
decodes in software on the Pi.

All four are Alpine's packages with the patches applied
([`rpi/`](rpi)), and come in two packages, `cervino-vlc` (VLC with its
FFmpeg) and `cervino-gstreamer` (GStreamer's plug-ins), which take the
place of Alpine's packages of the same names and come from the update repo
with `cervino-desktop`. `cervino-vlc` is installed, and can be removed;
`cervino-gstreamer` is not, and can be added:

```sh
doas apk del cervino-vlc          # no VLC; Alpine's FFmpeg 7 for the rest
doas apk add vlc-qt               # then, for Alpine's VLC
doas apk add cervino-gstreamer    # GStreamer's plug-ins with the patches
```

Without them, Alpine's packages take their place, without the hardware
decoding (`doas apk add` and `doas apk del` switch between them). On the
ISOs `cervino-vlc` brings in Alpine's VLC (`vlc-qt`), and can be removed
the same way, and the system uses Alpine's GStreamer plug-ins.

`cervino-gstreamer` also holds Showtime, on every target, with a patch of
ours that keeps its sound from skipping on an AirPlay speaker: it holds a
second of decoded video (about 75 MB at 1080p), so that the audio can be
decoded far enough ahead of it. Without `cervino-gstreamer`, Showtime is
Alpine's.

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

An atomic install on the Pi needs firmware with tryboot (a current
bootloader has it); with an older one the installer makes Alpine's
standard install (sys). It erases the disk and makes a GPT
partition table: a small FAT partition (mounted on `/boot/firmware`)
holding only `autoboot.txt` and `usercfg.txt` (your settings), two 256 MiB
FAT boot partitions, A and B, swap only if asked for (`-s`, as Alpine does
on the Pi) and the btrfs volume, encrypted or not, as on a PC. The firmware
starts the system itself, with no boot menu: each of A and B holds one
version (the firmware, its kernel, initramfs, device trees and overlays in
`cervino/<date and time>/`, `cmdline.txt` and a `config.txt` that starts
it), and `autoboot.txt` (written by `update-boot`) names the one that
starts. A new version is copied to the other partition, never to the one
that starts, and tried once: restarting (from GNOME, `doas reboot` or
`update-alpine`'s offer) restarts with the firmware's tryboot flag, which
starts the other partition that one time. Once it has started,
`autoboot.txt` names its partition, so a power cut while it is written
leaves the version before to start. If it doesn't start, switching the Pi
off and on starts the version before again, and the new one is not tried
again (`update-alpine list` shows it as "did not start when tried").
Switching off instead of restarting can't use tryboot, so the next start
begins with the version before, which restarts at once, before the
desktop, to try the new one. Going back
from a version that starts is `doas update-alpine rollback`, or, from one
that doesn't, swapping the two partition numbers in `autoboot.txt` on
another computer, which starts the version in the other partition.

### The 16 KB page kernel

The Pi's kernel has 16 KB memory pages instead of 4 KB, as Raspberry Pi
OS's has on the Pi 5, 500 and CM5, which makes some work faster (fewer
misses in the CPU's address translation cache, cheaper page faults).
`cervino-kernel` is Alpine's Pi kernel, `linux-rpi`, built that way (its
configuration is Raspberry Pi OS's for that kernel), and the only kernel
the Pi image and its installs have: the Pi's `cervino-desktop` depends on
it, so it can't be removed, and it takes the place of `linux-rpi` in an
install made before it, at its next update. The earlier Pis' cores can't
use 16 KB pages, so the image and installs start only on a Pi 5, 500 or
CM5 (on an earlier Pi, the package refuses to install).

Programs that assume 4 KB pages fail under it: some builds of jemalloc,
x86 emulators (box64, FEX) and Wine, and some programs built for other
systems. Swap is made for one page size: an unencrypted swap partition
(installs with `-s`) made under an older install's 4 KB kernel isn't used until `swapon --fixpgsz` formats it again; encrypted
swap is made anew at each boot.

The build compiles it too, which adds about an hour on an arm64 host.
[`test/kernel.sh`](test/kernel.sh) builds and tests it on a Pi 5 or 500
without starting it there: it checks the package, then boots a copy of the
Pi's system in a VM with it and with a 4 KB page kernel, and runs the CI's
OS feature tests in both (see the script for what it can't test). CI,
whose runners can't run that VM, checks the package the `rpi` build made
and boots a small system with it in a VM, running only the kernel's own
checks (`test/kernel.sh out/repo`).

## How it works

The script uses Alpine's own image tooling, `aports/scripts/mkimage.sh`, with
a custom profile (`gnomelive`) that extends `profile_standard`:

1. **Host:** works out the Alpine release and re-runs itself in an
   `alpine:<release>` container of the target's architecture, mounting the
   output directory. Building an aarch64 image on an x86_64 host (or the
   x86_64 ISO on an arm64 one) needs QEMU user emulation, e.g.
   `qemu-user-static`.
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
     based on), `mesa`, with a patch of ours that stops programs
     inheriting the GPU's render node, and the GPU memory with it,
     `firefox`, with a patch of ours that stops it probing the camera's
     16 video devices for video decoding at every start, which held up
     its start by about 0.3 s, and
     `linux-rpi` with 16 KB pages, as `cervino-kernel` (see
     [The 16 KB page kernel](#the-16-kb-page-kernel)). Alpine builds
     Firefox twice, the first time to record a PGO profile; this build
     takes Mozilla's profile for the same release instead (which
     Mozilla's own aarch64 build uses too) and builds it once. That
     still takes hours; CI builds it, like each of these packages, in a
     job of its own, only when its sources or Alpine's version change,
     and the image's build takes them all from there (`ONLY` and
     `CACHE_ONLY`);
   - for every target, `mutter`, `showtime`, `dnsmasq` and `libsoup3`,
     built from [`patched/`](patched): Alpine's, with patches of ours that keep GNOME
     Shell from crashing when a window's buffer can't be loaded onto the
     GPU (as can happen going fullscreen on the Pi), Showtime's sound from
     skipping on an AirPlay speaker, and names from failing to resolve
     through a VPN after switching between VPN connections, and with
     libsoup's upstream fix that keeps media shared with Media Sharing
     from stopping after a second;
   - for every target, the packages in [`extra/`](extra), which Alpine
     lacks (`tui-torrent`, `bapk`, `qstop`, `bijiben`,
     `rpi-keyboard-config`, `tomesole`, `spotatui`,
     `mullvad-containers`, `pam-cryptsetup-keyring`, and for the Pi only
     `rpi-keyboard-fw-update`),
     built the same way;
   - the `cervino-vlc` and `cervino-gstreamer` packages, built with
     abuild from [`cervino-vlc/APKBUILD`](cervino-vlc/APKBUILD) and
     [`cervino-gstreamer/APKBUILD`](cervino-gstreamer/APKBUILD): for the
     Pi, the runtime packages of `ffmpeg7` and `vlc`, and of
     `gst-plugins-base` and `gst-plugins-bad`, each pair in one, and for
     both `showtime` in `cervino-gstreamer`, providing their names at
     Alpine's versions (on the ISOs `cervino-vlc` only depends on Alpine's
     `vlc-qt`);
   - the `cervino-terminal` package, built with abuild from
     [`cervino-terminal/APKBUILD`](cervino-terminal/APKBUILD): the Zellij
     launcher and configuration, depending on Alpine's `zellij`, `foot`
     and `font-droid-sans-mono-nerd`, and Neovim's launcher and AstroNvim
     configuration ([`cervino-terminal/init.lua`](cervino-terminal/init.lua)),
     depending on `neovim` and `tree-sitter-grammars`, and on `bat`,
     `ripgrep`, `fd` and `less`, and Fedora's bash prompt and settings;
   - the `cervino-upnp` package, built with abuild from
     [`cervino-upnp/APKBUILD`](cervino-upnp/APKBUILD): the session helper
     that starts Rygel for GNOME Settings' Media Sharing
     ([`cervino-upnp/media-sharing`](cervino-upnp/media-sharing)) and the
     firewall rules for it, depending on Alpine's `rygel`;
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
