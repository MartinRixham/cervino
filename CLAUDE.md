# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Bash script, `build-alpine-gnome-iso.sh` (with its apkovl generator `genapkovl-gnomelive.sh`), that builds a bootable x86_64 Alpine Linux live ISO that boots straight into GNOME. It reproduces what `setup-desktop gnome` would install and enable, on top of Alpine's "standard" ISO. `README.md` documents the user-facing behaviour and the environment variables (`ALPINE_BRANCH`, `OUTDIR`, `LIVE_USER`, `LIVE_PASSWORD`, `AUTOLOGIN`, `BROWSER`, `CONTAINER`, `MIRROR`). Keep the README table, the script's header comment and the workflow in sync when you add or change a setting.

## Build and test

There are no unit tests or linters. A change is checked by building the ISO and booting it:

```sh
./build-alpine-gnome-iso.sh                       # needs podman or docker, curl, network
ALPINE_BRANCH=v3.24 AUTOLOGIN=0 ./build-alpine-gnome-iso.sh
qemu-system-x86_64 -enable-kvm -m 8G -cdrom out/*.iso   # live system runs from RAM: ~6 GB+
ci/vm-test.sh out/*.iso                             # the end-to-end test CI runs
```

`ci/vm-test.sh` drives two QEMU/KVM boots over the serial console, keeping the logs in `$WORKDIR` (default `./vm-test`). First it boots the ISO's kernel directly, with the `APPEND` line from the ISO's `syslinux.cfg` plus `console=ttyS0` (the ISO's boot loaders have no serial console), and installs to `/dev/vda` with `ci/guest/install.sh`, which runs an answer file through the ISO's `setup-alpine` wrapper. Then it boots the disk, logs in as `tester` (root is locked there; `install.sh` puts a `permit nopass tester` doas rule in the live `/etc` before installing, so the disk gets it) and runs `ci/guest/test.sh` through doas: it fails if anything of the live session (live user, its home, `live-user` script or runlevel link, autologin) reached the install, then turns on GDM autologin for `tester`, restarts gdm and runs `test/features.sh` as `tester` with the environment of the user's `gnome-shell`. `test.sh` prints its own results in `test/features.sh`'s format, then the counts of all the tests together. Last, it logs `tester` out through gnome-session and fails unless the session ends and GDM's login screen comes back (a new `gnome-shell` as `gdm` that stays up, answers on D-Bus, runs the `gnome-shell-compat` helper and is seat0's active elogind session); this has to live in `test.sh`, not `test/features.sh`, because it ends the session the tests run in. No setup happens between install and test: the ISO itself must make every test pass. The guest gets the repo files as a tar archive on `/dev/vdb`, and each command's exit status comes back as an `@@RC=n@@` marker on the console.

`shellcheck build-alpine-gnome-iso.sh genapkovl-gnomelive.sh` is useful, but the scripts the generator writes out through heredocs are not checked by it.

CI (`.github/workflows/build-iso.yml`) runs the script with `CONTAINER=docker` on pushes/PRs that touch the script, the generator, `ci/`, `test/` or the workflow. It uploads the ISO plus `SHA256SUMS` as an artifact, then runs `ci/vm-test.sh`; the job fails unless every OS feature test passes (the console logs are uploaded on failure). It publishes a GitHub release on `v*` tags only after the test passes. It frees runner disk space first because mkimage needs several GB.

## How the script is structured

The same file runs in three phases, selected by its first argument:

1. **`host_main`** (no argument): picks the container runtime, resolves `ALPINE_BRANCH` from the mirror's `latest-releases.yaml`, and re-runs itself in `alpine:<release>`, mounting itself at `/build.sh`, `genapkovl-gnomelive.sh` (from the script's directory) at `/genapkovl-gnomelive.sh` and `$OUTDIR` at `/out`. Settings reach the container only through the explicit `-e` flags, so a new setting must be added there too. `--security-opt label=disable` is deliberate (not `:Z`) so libvirt can still open the ISO on SELinux hosts.
2. **`container_main`** (`--in-container`, as root): installs the build tools, creates the unprivileged `build` user and an abuild signing key (installed into `/etc/apk/keys` by hand, because `abuild-keygen -i` would call doas/sudo), then runs phase 3 as `build`. mkimage must not run as root: apk 3 rejects `--no-chown` as root.
3. **`builder_main`** (`--as-builder`): sparse-clones `aports/scripts` at `<release>-stable`, resolves the package list `setup-desktop gnome` would install (`apk info --depends gnome gnome-apps-core` plus the wayland-base and udev packages) and adds `$features`, the packages for what `test/features.sh` checks. It writes the profile into `aports/scripts/` and puts the apkovl generator there with what it reads: `genapkovl-gnomelive.conf` (the build settings `LIVE_USER`, `LIVE_PASSWORD`, `AUTOLOGIN`, `LSM` and `WORLD`, the package list, as `sh` assignments) and Flathub's downloaded `flathub.flatpakrepo`. Then it runs `mkimage.sh --profile gnomelive`:
   - `mkimg.gnomelive.sh`: a profile that extends `profile_standard`, adds the package list to the ISO's on-disc apk repo and AppArmor's `lsm=` to the kernel command line.
   - `genapkovl-gnomelive.sh` (a source file in the repo, copied in): builds the apkovl (the `lbu` overlay format) holding `/etc/apk/world`, the GDM `custom.conf` (autologin), the desktop features' config files (profile.d, locale, NetworkManager, nftables, zram, coredump handler, Flathub remote, the autostart helper that registers the session with GDM and answers gnome-session's end-of-session queries for GNOME Shell, also listed in GDM's greeter autostart directory so the login screen registers too, ...), OpenRC runlevel symlinks, a `live-user` init script, `setup-alpine`, `lbu` and `adduser` wrappers in `/usr/local/sbin`, and an "Install Alpine Linux" launcher in `/usr/local/share/applications` that runs the `setup-alpine` wrapper in GNOME Console.

Everything the desktop features need on an installed system must be under `/etc` (or listed in `/etc/apk/protected_paths.d/lbu.list`, as `/usr/local/libexec` and the greeter's autostart file are), because `setup-disk` only copies what `lbu package` includes.

At boot the initramfs unpacks the apkovl, installs `/etc/apk/world` from the disc into the tmpfs root, and OpenRC starts the services.

### Editing the generated files

Most changes happen in `genapkovl-gnomelive.sh`, which writes each file of the apkovl with a heredoc:

- Use a quoted `<<'EOF'` heredoc for a file with no build settings in it, so it is written out as is.
- A file that needs a build setting (the `live-user` init script, the `setup-alpine` and `lbu` wrappers, `/etc/apk/world`, GDM's `custom.conf`) uses an unquoted `<<EOF`: `$LIVE_USER`, `$LSM` etc. are filled in when the generator runs, and the generated script's own variables need `\$` (and a literal backslash `\\`).
- A new build setting has to be added to the `genapkovl-gnomelive.conf` that `builder_main` writes, quoted with `shquote`.
- The mkimage profile is still a `<<-EOF` heredoc in `builder_main`; it strips leading **tabs**, so indent it with tabs only.
- Runlevels mirror the standard ISO's, changed the way `setup-desktop gnome` changes them: udev in place of mdev/hwdrivers, plus `cgroups`, `dbus`, `live-user` and `gdm` in default. The desktop features add `apparmor` and `zram-init` to boot, and their daemons (NetworkManager, chronyd, cupsd, ...) to default.
- The `setup-alpine` wrapper exists so installing from inside the live desktop works. It puts temporary shims first in `PATH`: `openrc` with `--no-stop` (so gdm and dbus are not killed), and no-op `setup-interfaces`/`setup-dns` (NetworkManager manages the network; ifupdown only has `lo`). It defaults `DEVDOPTS=udev`, `APKREPOSOPTS=-c` (community enabled), `USEROPTS` with the `plugdev` and `lpadmin` groups, and `KERNELOPTS` with AppArmor's `lsm=`, and passes `-e` so no root password is asked for. An answer file passed with `-f` still overrides those defaults (but not `-e`).
- `setup-alpine` sources `/etc/profile` part way through, which resets `PATH` and drops the temporary shims. So shims needed after that point live permanently in `/usr/local/sbin`, which `/etc/profile` puts first. `lbu`: `setup-disk` copies the live `/etc` to the target with `lbu package -`, and the shim filters that archive to drop the live user (passwd/shadow/group), its home directory (`setup-alpine` runs `lbu add` on every `/home/*`), the `live-user` init script and runlevel link, and GDM autologin; if the copy's `wheel` group has a member, it also locks root's password (`!`). `adduser`: gives users created by `setup-user` bash as their login shell (`/etc/default/useradd` does the same for shadow's `useradd`, which GNOME Settings uses).
