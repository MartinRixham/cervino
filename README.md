# Cervino

Build a bootable x86_64 Alpine Linux live ISO that starts straight into the
GNOME desktop.

The image is Alpine's "standard" ISO plus everything `setup-desktop gnome`
would install and enable, so you don't need to run `setup-alpine` first.
Boot it and you land in GNOME, logged in as a live user.

On top of plain `setup-desktop gnome`, the ISO comes with what you'd expect
from a desktop distribution, and keeps it when installed to disk:

- bash as the login shell, with completion and a command-not-found handler,
  `nano` as `EDITOR`, `~/.local/bin` first in `PATH`, man pages and the usual
  CLI tools (`file`, `xz`, `zstd`, `lspci`, `dmidecode`, `rsync`)
- a UTF-8 locale (`C.UTF-8`), English spell checking, emoji and CJK fonts
- NetworkManager, chrony for time sync, and `openrc-settingsd` for GNOME
  Settings' hostname, date/time and language panels
- Bluetooth, CUPS printing, Avahi mDNS, an nftables firewall (allowing SSH
  and mDNS in), and power profiles
- AppArmor, zram swap (half the RAM, at most 8 GB) and a crash dump
  collector writing to `/var/lib/coredump`
- PipeWire as the sound server (in place of PulseAudio), `xdg-utils`, Flatpak
  with Flathub, and the SPICE guest agent for VMs
- logging out without the logout dialog waiting on GNOME Shell (Alpine's
  gnome-shell registers with gnome-session but never answers its
  end-of-session queries; a session helper answers for it)

[`os-feature-tests.sh`](os-feature-tests.sh) checks all of this on a running
system.

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

The ISO is written to `./out/`.

Settings are passed as environment variables, for example:

```sh
ALPINE_BRANCH=v3.24 LIVE_USER=me LIVE_PASSWORD=secret AUTOLOGIN=0 \
    ./build-alpine-gnome-iso.sh
```

| Variable        | Default                                    | Description                                                         |
| --------------- | ------------------------------------------ | ------------------------------------------------------------------- |
| `ALPINE_BRANCH` | latest stable                              | Alpine release branch, e.g. `v3.24`                                 |
| `OUTDIR`        | `./out`                                    | Where the ISO is written                                            |
| `LIVE_USER`     | `alpine`                                   | Desktop user created at boot                                        |
| `LIVE_PASSWORD` | `alpine`                                   | That user's password                                                |
| `AUTOLOGIN`     | `1`                                        | Set to `0` to stop at the GDM login screen instead of logging in    |
| `BROWSER`       | `firefox`                                  | Browser package to install, as in `setup-desktop`                   |
| `CONTAINER`     | `podman`, else `docker`                    | Container runtime to use                                            |
| `MIRROR`        | `https://dl-cdn.alpinelinux.org/alpine`    | Alpine package mirror                                               |

### Prebuilt ISOs

The [Build ISO](.github/workflows/build-iso.yml) GitHub Actions workflow runs
the script on every push and pull request that touches it, and uploads the ISO
and its `SHA256SUMS` as a workflow artifact. You can also start it by hand from
the Actions tab and choose an Alpine branch there. Pushing a `v*` tag also
publishes the ISO as a GitHub release.

After building, the workflow tests the ISO in a QEMU/KVM VM with
[`ci/vm-test.sh`](ci/vm-test.sh). The test boots the ISO, installs it to a
virtual disk with `setup-alpine`, checks that nothing of the live session
was copied to the installed system, and then runs `os-feature-tests.sh` in
the installed user's GNOME session. The build fails, and no release is
published, unless every test passes. To run the same test locally (it needs
`qemu-system-x86_64`, `xorriso` and access to `/dev/kvm`):

```sh
ci/vm-test.sh out/*.iso
```

## Booting the ISO

The live system runs entirely from RAM (tmpfs), so you need **about 6 GB of
RAM or more** to boot it. Write it to a USB stick or attach it to a VM, for
example:

```sh
qemu-system-x86_64 -enable-kvm -m 8G -cdrom out/*.iso
```

The live user is in the `wheel` group and can use `doas` to get root.

### Installing to disk

`setup-alpine` works from inside the running desktop. The ISO puts a wrapper
in front of it that:

- stops runlevel changes from shutting down `gdm` and `dbus` (which would kill
  the session you're running it from),
- keeps `udev` as the device manager, which GNOME needs, instead of switching
  to `mdev`,
- skips the network interface and DNS questions, because NetworkManager
  manages the network,
- enables the community repository, where GNOME lives, by default,
- adds the new user to the `plugdev` and `lpadmin` groups as well, so they can
  change network settings and manage printers, and gives them bash as the
  login shell,
- enables AppArmor on the installed system's kernel command line,
- leaves the live session out of the installed system.

An answer file passed with `-f` still overrides these defaults.

Like any Alpine `sys` install, the disk gets a copy of the running system: the
same packages (so GNOME) and your changes under `/etc`. The live user, its
home directory, its init script and GDM autologin are dropped from that copy, so create a user in
`setup-alpine`'s user step and log in as that user. Without one there is no
account GDM can log in to.

## How it works

The script uses Alpine's own image tooling, `aports/scripts/mkimage.sh`, with
a custom profile (`gnomelive`) that extends `profile_standard`:

1. **Host:** works out the Alpine release and re-runs itself in an
   `alpine:<release>` container, mounting the output directory.
2. **Container:** installs the build tools, creates an unprivileged `build`
   user and an abuild signing key (`mkimage.sh` must run unprivileged).
3. **Builder:** sparse-clones `aports/scripts`, resolves the package list
   that `setup-desktop gnome` would install plus the desktop features listed
   above, and generates:
   - the mkimage profile, which adds those packages (with all dependencies) to
     the ISO's on-disc apk repository;
   - an apkovl generator. The apkovl is the same overlay mechanism `lbu` uses;
     it contains `/etc/apk/world`, the GDM config, the desktop features'
     configuration, OpenRC runlevels (udev in place of mdev, plus `cgroups`,
     `dbus`, `gdm` and the desktop features' services), a `live-user` init
     script, and the `setup-alpine` wrapper with its `lbu` and `adduser`
     shims.
4. At boot the initramfs unpacks the apkovl, installs everything in its
   `/etc/apk/world` from the disc into the RAM root, and OpenRC starts udev,
   dbus, gdm and so on just as `setup-desktop` would have configured them.

## License

[Apache License 2.0](LICENSE)
