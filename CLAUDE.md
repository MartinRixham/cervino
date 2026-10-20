# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Bash script, `build-alpine-gnome-iso.sh`, that builds a bootable x86_64 Alpine Linux live ISO that boots straight into GNOME. It reproduces what `setup-desktop gnome` would install and enable, on top of Alpine's "standard" ISO. `README.md` documents the user-facing behaviour and the environment variables (`ALPINE_BRANCH`, `OUTDIR`, `LIVE_USER`, `LIVE_PASSWORD`, `AUTOLOGIN`, `BROWSER`, `CONTAINER`, `MIRROR`). Keep the README table, the script's header comment and the workflow in sync when you add or change a setting.

## Build and test

There are no unit tests or linters. A change is checked by building the ISO and booting it:

```sh
./build-alpine-gnome-iso.sh                       # needs podman or docker, curl, network
ALPINE_BRANCH=v3.24 AUTOLOGIN=0 ./build-alpine-gnome-iso.sh
qemu-system-x86_64 -enable-kvm -m 8G -cdrom out/*.iso   # live system runs from RAM: ~6 GB+
```

`shellcheck build-alpine-gnome-iso.sh` is useful, but the generated scripts inside heredocs are not checked by it.

CI (`.github/workflows/build-iso.yml`) runs the script with `CONTAINER=docker` on pushes/PRs that touch the script or workflow, uploads the ISO plus `SHA256SUMS` as an artifact, and publishes a GitHub release on `v*` tags. It frees runner disk space first because mkimage needs several GB.

## How the script is structured

The same file runs in three phases, selected by its first argument:

1. **`host_main`** (no argument): picks the container runtime, resolves `ALPINE_BRANCH` from the mirror's `latest-releases.yaml`, and re-runs itself in `alpine:<release>`, mounting itself at `/build.sh` and `$OUTDIR` at `/out`. Settings reach the container only through the explicit `-e` flags, so a new setting must be added there too. `--security-opt label=disable` is deliberate (not `:Z`) so libvirt can still open the ISO on SELinux hosts.
2. **`container_main`** (`--in-container`, as root): installs the build tools, creates the unprivileged `build` user and an abuild signing key (installed into `/etc/apk/keys` by hand, because `abuild-keygen -i` would call doas/sudo), then runs phase 3 as `build`. mkimage must not run as root: apk 3 rejects `--no-chown` as root.
3. **`builder_main`** (`--as-builder`): sparse-clones `aports/scripts` at `<release>-stable`, resolves the package list `setup-desktop gnome` would install (`apk info --depends gnome gnome-apps-core` plus the wayland-base and udev packages), writes two files into `aports/scripts/`, and runs `mkimage.sh --profile gnomelive`:
   - `mkimg.gnomelive.sh`: a profile that extends `profile_standard` and adds the package list to the ISO's on-disc apk repo.
   - `genapkovl-gnomelive.sh`: builds the apkovl (the `lbu` overlay format) holding `/etc/apk/world`, the GDM `custom.conf` (autologin), OpenRC runlevel symlinks, a `live-user` init script and a `/usr/local/sbin/setup-alpine` wrapper.

At boot the initramfs unpacks the apkovl, installs `/etc/apk/world` from the disc into the tmpfs root, and OpenRC starts the services.

### Editing the generated scripts

Most changes happen inside the nested heredocs in `builder_main`, so watch the quoting levels:

- Both outer heredocs use `<<-`, which strips leading **tabs**. Indent with tabs, never spaces, or the generated files break.
- `<<-GENEOF` is unquoted, so `$VAR` expands at **build time** (for example `$world`, `$LIVE_USER`, `$autologin_conf`) and `\$VAR` expands when the **generator runs** inside mkimage. Inner `<<'EOF'` heredocs (the `live-user` script, the `setup-alpine` wrapper) are written out literally by the generator, so values baked in at build time use `$`, and runtime variables of those scripts need `\$`.
- Runlevels mirror the standard ISO's, changed the way `setup-desktop gnome` changes them: udev in place of mdev/hwdrivers, plus `cgroups`, `dbus`, `live-user` and `gdm` in default.
- The `setup-alpine` wrapper exists so installing from inside the live desktop works: it shims `openrc` with `--no-stop` (so gdm and dbus are not killed), defaults `DEVDOPTS=udev` and `APKREPOSOPTS=-c` (community enabled). An answer file passed with `-f` still overrides those defaults. It also shims `lbu`: `setup-disk` copies the live `/etc` to the target with `lbu package -`, and the shim filters that archive to drop the live user (passwd/shadow/group), the `live-user` init script and runlevel link, and GDM autologin.
