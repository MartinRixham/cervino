# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working
with code in this repository.

## What this is

A Bash script, `build-alpine-gnome-iso.sh`, that builds a bootable x86_64
Alpine Linux live ISO that boots straight into GNOME, or with `TARGET=rpi`
an aarch64 Raspberry Pi SD card image (`.img.gz`) of the same system. It
reproduces what `setup-desktop gnome` would install and enable, on top of
Alpine's "standard" ISO (or its `rpiimg` image).

Besides the script, the repo holds:

- its mkimage profile, `mkimg.gnomelive.sh`
- its apkovl generator, `genapkovl-gnomelive.sh`, and the live system's
  scripts in `live/`
- the live initramfs's `initramfs-live.patch`
- the `cervino-desktop` package's `cervino-desktop/APKBUILD`
- the `cervino-vlc` and `cervino-gstreamer` packages'
  `cervino-vlc/APKBUILD` and `cervino-gstreamer/APKBUILD`
- the `cervino-terminal` package's `cervino-terminal/APKBUILD`
- the AppArmor profiles in `apparmor.d/`
- the Pi's patched `ffmpeg7`, `vlc`, `gst-plugins-base`, `gst-plugins-bad`,
  `wpa_supplicant` and `bluez` packages in `rpi/`

`README.md` documents the user-facing behaviour and the environment
variables (`TARGET`, `ALPINE_BRANCH`, `OUTDIR`, `LIVE_USER`,
`LIVE_PASSWORD`, `AUTOLOGIN`, `BROWSER`, `CONTAINER`, `MIRROR`,
`SIGNING_KEY`, `APK_REPO`, `CACHEDIR`). Keep the README table, the script's
header comment and the workflow in sync when you add or change a setting.

## Build and test

There are no unit tests. A change is checked by building the ISO and booting
it:

```sh
./build-alpine-gnome-iso.sh                       # needs podman or docker, curl, network
ALPINE_BRANCH=v3.24 AUTOLOGIN=0 ./build-alpine-gnome-iso.sh
qemu-system-x86_64 -enable-kvm -m 8G -cdrom out/*.iso
ci/vm-test.sh out/*.iso                             # the end-to-end test CI runs
INSTALL_MODE=sys ci/vm-test.sh out/*.iso            # the same with a sys install
```

### ci/vm-test.sh

`ci/vm-test.sh` drives QEMU/KVM boots over the serial console, keeping the
logs in `$WORKDIR` (default `./vm-test`). No setup happens between install
and test: the ISO itself must make every test pass. The guest gets the repo
files as a tar archive on `/dev/vdb`, and each command's exit status comes
back as an `@@RC=n@@` marker on the console.

The VMs:

- The atomic VM boots with OVMF (from the `ovmf` package, or
  `OVMF_CODE`/`OVMF_VARS`) on a q35 machine, its variable store kept in
  `$WORKDIR/efivars.fd` across the boots. On the default i440fx, the kernel
  never finds the CD drive on the PIIX IDE bus under OVMF.
- The sys VM keeps QEMU's default machine and BIOS.

**The install boot.** It boots the ISO's kernel directly, with the `APPEND`
line from the ISO's `syslinux.cfg` plus `console=ttyS0` (the ISO's boot
loaders have no serial console), and installs to `/dev/vda` with
`ci/guest/install.sh`, which:

1. checks that reinstalling `apparmor-profiles` from the disc fires the
   package's trigger (the kernel's AppArmor policy revision changes);
2. runs an answer file (`-m $INSTALL_MODE`: `atomic`, the default, or `sys`;
   `install.sh` and `test.sh` take it as their argument) through the ISO's
   `setup-alpine` wrapper;
3. fails if the live system's kernel log has any AppArmor denials
   (`ci/guest/apparmor-denials.sh`);
4. mounts the disk, clears tester's password, which the install leaves
   locked, and adds a `permit nopass tester` doas rule.

**The test boot.** It boots the disk, logs in as `tester` (root is locked
there) and runs `ci/guest/test.sh` through doas. `test.sh` prints its own
results in `test/features.sh`'s format, then the counts of all the tests
together. In order, it:

1. fails if anything of the live session (live user, its home, `live-user`
   script or runlevel link, autologin) reached the install;
2. turns on GDM autologin for `tester`, restarts gdm and runs
   `test/features.sh` as `tester` with the environment of the user's
   `gnome-shell`;
3. runs `test/apparmor.sh` as root (see below);
4. checks that the package's "Update Alpine Linux" launcher shows in the app
   grid (GLib's `Gio.DesktopAppInfo` in tester's session) and that what it
   runs is installed;
5. checks that the system is read-only (atomic) or writable (sys);
6. puts the memory under pressure: `ci/guest/memory-hog.js`, run with gjs in
   tester's session, takes memory 64 MiB at a time, every 200 ms, and the
   test fails unless earlyoom kills it, and only it, before the kernel's OOM
   killer acts, with GNOME Shell still running. The pages hold one repeated
   byte, which zram stores without compressing, so swap fills as fast as RAM
   and the VM doesn't thrash. Unpaced, swap filled so fast that earlyoom,
   which checks at most once a second, missed the window about half the
   time. This runs before the logout, which needs the session;
7. logs `tester` out through gnome-session and fails unless the session ends
   and GDM's login screen comes back: a new `gnome-shell` as `gdm` that
   stays up, answers on D-Bus, runs the `gnome-shell-compat` helper and is
   seat0's active elogind session. This has to live in `test.sh`, not
   `test/features.sh`, because it ends the session the tests run in;
8. fails on any AppArmor denial in the installed system's kernel log, so it
   covers everything the tests did.

`test/apparmor.sh` checks that every system daemon Fedora's SELinux targeted
policy gives a domain of its own (named in each test) runs under an AppArmor
profile in enforce mode, starting D-Bus-activated ones first. sshd is
installed but not enabled, so it starts it, logs in through it as a
throwaway user with a key (checking sshd-session and sshd-auth before
authentication, the session after, and sftp), then stops it, deleting the
host keys the start made, and deletes the user. The profiles are in
`apparmor.d/` (see below).

**The upgrade boots (atomic installs only).** Four more boots run
`ci/guest/upgrade.sh stage`, `check`, `rollback` and `fallback`. Notes
between the boots are kept in `/var/lib/cervino-ci`.

- `stage`: `apk add` (through the wrapper, so `update-alpine add`) of a
  small package not installed (`figlet`, ...) must stage a new version and
  leave the running one alone.
- `check`: the shutdown must have switched to it (on trial, as `BootNext`),
  with the `/etc` changes made after staging (a file written, one deleted).
  Once started it must become first in `BootOrder` and the fallback
  `BOOTX64.EFI` (waiting for the inittab `::once:` commit, which can race
  the console login), keeping the old version's entry.
- `rollback`: `update-alpine rollback` must make a new copy of the old
  version the default, which `update-alpine list` must show as running and
  next to start; `update-alpine delete` must remove the updated version from
  the volume, the boot partition and the boot entries but refuse the running
  one. Then another `apk add` is staged with a test-only shutdown service,
  `ci-break`, that overwrites the version on trial's `linux.efi` after
  `cervino-atomic`, so the firmware can't load it and falls back.
- `fallback`: must find the version from before running and still the
  default, with the broken one listed as "did not start when tried".

### ci/update-test.sh

`ci/update-test.sh out/repo` tests the package's `update-alpine` (taken out
of the built `.apk` with `tar`) in plain `alpine` containers, in seconds.
These run in containers rather than the VM because they change the system
and the VM's release is always the latest.

- On the package's release, it must upgrade the packages and check for a
  newer release.
- On the release before, it installs a stand-in `cervino-desktop`: only a
  `cervino.list` naming its own repo; made with `apk mkpkg`/`apk mkndx`,
  signed with a throwaway key, served by busybox-extras' `httpd` on
  `127.0.0.1:8080`. Then `update-alpine` must:
  - offer nothing and change nothing while that repo has no packages for the
    newer release;
  - once it has, offer it, and change nothing when that is turned down;
  - when accepted, leave `/etc/alpine-release`, `/etc/apk/repositories` and
    `cervino.list` on it, with the newer release's stand-in installed, no
    `cervino.list.apk-new` and nothing left to upgrade.

### shellcheck and formatting

`shellcheck build-alpine-gnome-iso.sh genapkovl-gnomelive.sh mkimg.gnomelive.sh live/*`,
plus the shell scripts in `cervino-desktop/`, `cervino-vlc/`,
`cervino-gstreamer/`, `cervino-terminal/`, `ci/` and `test/`, should print
nothing. `.shellcheckrc` turns off the checks
that go against the scripts' own idioms (`a= b=`, `cmd && ok || die`,
functions called by name, programs in single quotes, `ls` over names the
scripts make), and follows
the `# shellcheck source=` directives. Deliberate word splitting is marked
where it happens with `# shellcheck disable=`. The short files written
through heredocs are not checked.

The scripts are indented with tabs and kept to about 100 columns, counting a
tab as 4. Break a long command at a pipe, `&&` or `||`, or with a backslash,
indenting the continuation one more tab; split a long `die` message into
several arguments, and give a long `fail` message a variable. Lines that
can't be broken (udev rules, `.desktop` `Exec=` lines, AppArmor brace lists,
regexes) stay as they are. The packages in `rpi/` are Alpine's aports and
keep Alpine's formatting. Comments and Markdown are wrapped at about 76
columns.

A blank line separates a script's header comment from its code, functions
from each other, and the steps of a script (a group of commands with the
comment that explains them); a lone `#` separates paragraphs of one comment.
A file that started as a heredoc keeps none of this unless it is added, so
add it when moving one into a source file of its own.

### CI

CI (`.github/workflows/build-iso.yml`) runs the script with
`CONTAINER=docker` on pushes and PRs that touch the script, the generator,
`live/`, `mkimg.gnomelive.sh`, `cervino-desktop/`, `cervino-vlc/`,
`cervino-gstreamer/`, `cervino-terminal/`, `apparmor.d/`, `rpi/`, `ci/`,
`test/` or the workflow.

- **Build jobs**: one per `TARGET`, a matrix of `iso` on `ubuntu-latest` and
  `rpi` on `ubuntu-24.04-arm`. They free runner disk space first because
  mkimage needs several GB. Each job uploads its image plus `SHA256SUMS` as
  an artifact; the `iso` job then runs `ci/update-test.sh`. The `rpi` image
  is only built: QEMU can't run GNOME on an emulated Pi.
- **The Pi's package cache**: the `rpi` job passes
  `CACHEDIR=$RUNNER_TEMP/pkgcache` and keeps each Pi package in an Actions
  cache of its own. Before the build it restores the newest
  `rpi-<package>-*` (`actions/cache/restore` with a `restore-keys` prefix),
  and after it, even if it failed, saves each package whose `key` file is
  not the restored one's as `rpi-<package>-<key>`.
- **`vm-test`** (after both builds): downloads the ISO and runs
  `ci/vm-test.sh` once per `INSTALL_MODE` (a matrix of `atomic` and `sys`,
  on separate runners, since a runner's 16 GB can't hold two 8 GB VMs),
  failing unless every OS feature test passes. The console logs are uploaded
  as `vm-test-logs-<mode>` on failure.
- **`release`**: on `v*` tags, publishes both images as a GitHub release,
  only after both build jobs and both VM tests pass.
- **Signing**: on those tags the build jobs also sign with the
  `APK_SIGNING_KEY` secret, written to `$RUNNER_TEMP/cervino.rsa` (apk knows
  a key by its file name, so it stays `cervino.rsa` in every job). The
  secret belongs to the `release` environment, whose deployment rule admits
  only `v*` tags, so branch runs can't read it: the `repo` job always enters
  it, the build job only on tags (its `environment:` expression is empty
  otherwise).
- **The packages**: the build jobs set `APK_REPO` to the repository's GitHub
  Pages URL, and each uploads its `out/repo` (the packages as
  `<branch>/<arch>/*.apk`: `cervino-desktop`, `cervino-vlc`,
  `cervino-gstreamer`, `cervino-terminal`, and for `rpi` `wpa_supplicant`
  and `bluez` with their subpackages) as `cervino-repo-<target>`.
- **`repo`** (also after the VM tests): runs `ci/publish-repo.sh` in an
  `alpine:<branch>` container per branch (so the index is in a format that
  branch's apk reads) on a worktree of the `gh-pages` branch. That is an
  orphan branch holding only the published repo, created on the first
  release, written only by this job, one run at a time. It adds the packages
  (but a file already published stays as it was: the Pi's packages are
  rebuilt at the same version each release), keeps the newest five versions
  of each package, indexes each arch with `--rewrite-arch`, signs the index
  and pushes. GitHub Pages serves that branch; Pages must be set to it in
  the repository settings.

## How the script is structured

`TARGET` sets `ARCH` (`x86_64` or `aarch64`) at the top of the script. The
container runs `ARCH` (`--platform linux/amd64` or `linux/arm64`), as
building the root file system runs the packages' scripts; `host_main` stops
unless the host is that architecture or has QEMU user emulation for it in
`binfmt_misc`. CI builds `rpi` on an arm64 runner (`ubuntu-24.04-arm`).

The same file runs in four phases, selected by its first argument.

### 1. `host_main` (no argument)

- Picks the container runtime and resolves `ALPINE_BRANCH` from the mirror's
  `latest-releases.yaml`.
- Re-runs itself in `alpine:<release>`, mounting itself at `/build.sh`;
  `genapkovl-gnomelive.sh`, `live/`, `mkimg.gnomelive.sh`,
  `initramfs-live.patch`, `cervino-desktop/`, `cervino-vlc/`,
  `cervino-gstreamer/`, `cervino-terminal/`, `apparmor.d/` and `rpi/` (from
  the script's directory) at `/genapkovl-gnomelive.sh`, `/live`,
  `/mkimg.gnomelive.sh`, `/initramfs-live.patch`, `/cervino-desktop`,
  `/cervino-vlc`, `/cervino-gstreamer`, `/cervino-terminal`, `/apparmor.d`
  and `/rpi`; `$OUTDIR` at `/out`; and `CACHEDIR`, if set, at `/cache`.
- Passes `PKGVER`, the package's version: the last commit's time
  (`YYYYMMDD.HHMMSS`, UTC), or the build time outside git, so each commit's
  package upgrades the last.
- Settings reach the container only through the explicit `-e` flags, so a
  new setting must be added there too.
- `--security-opt label=disable` is deliberate (not `:Z`) so libvirt can
  still open the ISO on SELinux hosts.

### 2. `container_main` (`--in-container`, as root)

- Installs the build tools and creates the unprivileged `build` user and its
  abuild signing key: `SIGNING_KEY`, mounted at `/signing-key` with its file
  name in `SIGNING_KEY_NAME` (the public key is derived with openssl as
  `<name>.pub`), or else a new one from `abuild-keygen` (installed into
  `/etc/apk/keys` by hand, because `abuild-keygen -i` would call doas/sudo).
- Runs phase 3 as `build`, then copies the Pi's packages it built
  (`/work/pkgcache/<package>/`) to `/cache`, owned by `/cache`'s owner, even
  if phase 3 failed.
- Runs `build_rootfs` (as root), then phase 4 as `build`.
- Checks that the image's kernel (mkimage fetches it on its own) is the root
  file system's (`/lib/modules/<version>`); a kernel released mid-build
  stops it.
- Copies the image and the packages (`/work/pkgout`, as
  `/out/repo/<branch>/<arch>/`) to `/out`.

`build_rootfs` installs `/work/rootfs-packages` into `/work/rootfs` from
Alpine's repos and `/work/pkgrepo`, with apk's scripts and triggers run.
Phase 3 writes that list: the world, `linux-lts` or `linux-rpi`,
`wireless-regdb` and `linux-firmware`'s subpackages but those only servers,
network appliances and ARM SoCs use (`qcom`, `mellanox`, ...). Then it:

- deletes the initramfs mkinitfs's trigger made and the `machine-id` a
  package script made (the dbus service makes one at boot);
- packs it with `mksquashfs` (xz), leaving out the host's `security.selinux`
  xattrs and putting in `/dev`'s `null`, `zero`, `random`, `urandom` and
  `console` as `-p` definitions (rootless podman can't make device nodes, so
  scripts' `> /dev/null` makes a plain file).

mkimage puts it on the image as `cervino/rootfs.squashfs`, the live system's
root (see below). mkimage must not run as root: apk 3 rejects `--no-chown`
as root.

### 3. `builder_main` (`--as-builder`)

**The package list.** It sparse-clones `aports/scripts` at
`<release>-stable` and resolves the package list `setup-desktop gnome` would
install (`apk info --depends gnome gnome-apps-core`, in an apk root for
`$ARCH`, plus the wayland-base and udev packages). It adds `$features`, the
packages for what `test/features.sh` checks; some only exist on one
architecture (e.g. the Intel VA-API drivers), and `iproute2-minimal` is for
its IPv6 reverse path filter test, which needs `ip netns`.

`/etc/apk/world` is what `setup-desktop gnome` would put there plus
`cervino-desktop`, which depends on `$features`: a feature added later
reaches installed systems with the package, while GNOME's apps stay
removable from world. It also has `cervino-vlc` (VLC, on the Pi) and
`cervino-gstreamer` (below), either of which can be removed for Alpine's
packages, and `cervino-terminal` (below).

**The Pi's packages.** For `rpi` it first builds `rpi/ffmpeg7`, `rpi/vlc`,
`rpi/gst-plugins-base`, `rpi/gst-plugins-bad`, `rpi/wpa_supplicant` and
`rpi/bluez`, in that order, with `abuild -r`.

- abuild-apk installs their makedepends. `vlc` builds with the
  `ffmpeg7-dev`, and `gst-plugins-bad` with the `gst-plugins-base-dev`,
  built before them, which abuild's repo `/work/packages/cervino` offers.
- Before building, it checks that Alpine's version of each
  (`apk search --exact` in the apk root) is still the APKBUILD's `_alpine`,
  the one it was made from.
- With `/cache`, a package whose `key` there matches is taken from there
  instead (the files `abuild listpkg` names). The key is a hash of the
  branch, `ARCH`, Alpine's version, the files of `rpi/<package>/` and, for
  `vlc` and `gst-plugins-bad`, the key of `ffmpeg7` or `gst-plugins-base`.
  Each `.apk` is signed again with this build's key (`abuild-gzsplit`, then
  `abuild-sign` of its control part), and `abuild index` puts it in abuild's
  repo.
- A package built here is left with its key in `/work/pkgcache/<package>/`.

Each is Alpine's aport with Raspberry Pi OS's patches:

- `ffmpeg7` and `vlc`: the Pi's hardware video decoders (V4L2 request HEVC,
  V4L2 M2M H.264, DRM PRIME frames). ffmpeg7's libraries only add to
  Alpine's ABI.
- `gst-plugins-base` and `gst-plugins-bad`: the HEVC decoder in GStreamer
  (`v4l2slh265dec` with the Pi kernel's SAND formats `Nc12`/`Nc30`, which
  base gets as video formats `NV12_128C8`/`NV12_10LE32_128C8`, added after
  the enum's last, so its ABI only adds too). The two base patches that add
  them are vendored, ported to 1.28; the rest come from the
  `.debian.tar.xz`, and Pi OS's other v4l2codecs patches are in 1.28
  already. `test/features.sh` decodes `test/hevc-probe.mp4` with it to
  system-memory I420.
- `wpa_supplicant`: WPA3 with the Pi's Wi-Fi (SAE over D-Bus, WPA2 fallback
  without a passphrase). It goes with `cervino-desktop`'s `brcmfmac`
  options.
- `bluez`: A2DP priority on the Pi's shared Bluetooth/Wi-Fi radio.

The patches come from the `.debian.tar.xz` of Pi OS's package in
`archive.raspberrypi.com`, which keeps every version and is ahead of
`RPi-Distro` on GitHub (`ffmpeg7` names it `_rpi_debian` and applies the
patch from it in `prepare()`), or are vendored in `rpi/<package>/` when they
had to be ported (each says what changed). VLC's are the exception: from
`RPi-Distro` at a pinned commit, followed by our `rpi-musl-gcc15.patch` (Pi
OS builds with glibc and GCC 14) and `rpi-qt-wayland.patch` (the Qt
interface tries Wayland before X11, so in GNOME it shows video through
`wl_dmabuf` instead of EGL on Xwayland, which stutters). The version is
Alpine's plus `_p<n>`, Pi OS's patch set or `+rpt` release, which ranks
above Alpine's. To move to a newer one, take Alpine's APKBUILD again and
Raspberry Pi OS's patches for that version.

`wpa_supplicant` and `bluez` are published as they are, and so replace
Alpine's. The four media packages are published only inside
`cervino-vlc` (`vlc` and `ffmpeg7`) and `cervino-gstreamer`
(`gst-plugins-base` and `gst-plugins-bad`).

**`cervino-vlc` and `cervino-gstreamer`.** `build_bundle NAME VERSION
PACKAGE...` builds each with `abuild -d` in `/work/cervino/<name>`, from a
copy of `<name>/` with `<name>.conf` (`PKGVER`, `TARGET_ARCH`) next to the
APKBUILD. On `x86_64` they are empty. For `rpi` each also gets, from its
pair of packages:

- `apks/`: their runtime `.apk`s (not `-dev`, `-doc`, `-dbg`, `-lang` or
  `vlc-daemon`), whose files `package()` unpacks into it;
- in the `.conf`, from their `.PKGINFO`s: `PROVIDES`, each package's name
  and `cmd:` provides at Alpine's version (`_alpine`) rather than ours, and
  its `so:` provides; `DEPENDS`, their depends but those they provide each
  other; `LICENSE`, all their licenses. The packages have `!tracedeps`, as
  abuild can't trace the libraries with what they link not installed;
- for `cervino-vlc`, `vlc-libs`' `.trigger` and `.pre-deinstall` (VLC's
  plug-in cache), taken out of its `.apk` as the package's own. Any other
  install script stops the build.

Each pair has to stay together: VLC builds against ffmpeg7's patches, and
gst-plugins-bad's HEVC decoder uses the formats gst-plugins-base adds. The
pairs don't depend on each other: the GStreamer plug-ins don't use ffmpeg7,
and VLC, built against our gst-plugins-base, links it only by soname, whose
ABI only adds to Alpine's.

In world, each takes the place of Alpine's packages of those names (its
provides make them one name each, so they never install together), and
`apk del` of it brings Alpine's back. That only works with Alpine's version
in its provides: apk keeps a provider of a higher version for a name world
gives (`gst-plugins-base`) even once its package is deleted. Under their own
names, the patched packages would shadow Alpine's for good. VLC itself is
not in world (`cervino-vlc` brings it), so deleting `cervino-vlc` removes
it.

Their version is not `PKGVER` but `VLC_PKGVER` and `GSTREAMER_PKGVER`
(and `cervino-terminal`'s `TERMINAL_PKGVER`), which `host_main`'s
`bundle_version` takes from the last commit that changed the package's
directory, its two packages in `rpi/` or
`build_bundle` (`git log -L`), so that a release leaving them as they were
doesn't make installs download them again; `ci/publish-repo.sh` keeps a
file already published. That needs the history, so the build job checks
out with `fetch-depth: 0`. A change elsewhere that changes what they hold
has to touch one of those paths too.

**`cervino-terminal`.** Zellij in foot, the terminal, and AstroNvim:
`build_bundle` with no packages, so it has only its own files, the same on
both targets. It
depends on Alpine's `zellij`, `foot` and `font-droid-sans-mono-nerd`, and
holds a "Zellij" launcher (`foot -F --app-id=zellij` with the DroidSansM
Nerd Font, running `zellij`; GNOME Shell matches the window to it by the
app id), its icon (Zellij's logo, `zellij.svg`) and
`/etc/zellij/config.kdl`, which Alpine's zellij reads when the user has no
`~/.config/zellij`: only what differs from Zellij's defaults, so new
defaults reach users as Zellij is upgraded. That is move mode on Ctrl m
(the defaults bind Ctrl h only in `move` and `shared_except "locked"
"move"`, which it unbinds there) and no startup tips. It also takes over
foot's three launchers (`replaces="foot"`) with copies that have
`NoDisplay=true`, so the app grid shows Zellij alone; a change foot makes
to them has to be copied by hand.

It also brings AstroNvim. It depends on `neovim`, the programs AstroNvim
runs (`git`, `ripgrep`, `lazygit`, `bottom`, `gdu`),
`tree-sitter-grammars`, and the command line tools `bat`, `fd` and GNU
`less` (busybox's lacks most options), and holds:

- `/etc/xdg/nvim/init.lua` (`init.lua`), which Neovim reads when the user
  has no `~/.config/nvim`: AstroNvim's template in one file. On first start
  lazy.nvim downloads AstroNvim (`^6`) and its plugins into
  `~/.local/share/nvim`, where it also keeps its lock file (in
  `~/.config/nvim` it would hide this file from Neovim);
- Neovim's launcher (`replaces="neovim"`), running `nvim %F` in foot with
  the Nerd Font, for AstroNvim's icons, instead of in the terminal GNOME
  picks; a change neovim makes to it has to be copied by hand.

nvim-treesitter builds its parsers with a C compiler, which the system
lacks. So nothing is built (AstroCore's `auto_install` and
`ensure_installed` are off), and Neovim takes Alpine's parsers from
`$VIMRUNTIME/parser`. AstroCore only uses parsers nvim-treesitter built, so
`init.lua` wraps `astrocore.treesitter.installed()` to add Alpine's, and
puts nvim-treesitter's `runtime/` (its queries) on the runtime path. A
language whose queries don't load with Alpine's parser (a node type it
lacks; gomod, kotlin, regex and scala when this was written) is left out,
keeping Vim's syntax highlighting, as AstroCore would fail on it.
Mason installs nothing unless asked; most of what it downloads is built for
glibc.

`test/features.sh` checks the launchers' programs, the font, that
`zellij setup --check` accepts the configuration, that nvim finds
`/etc/xdg/nvim/init.lua` and it compiles, that it has a Python parser,
that `bat`, `rg`, `fd` and GNU `less` are installed, and that foot's
launchers are hidden. It can't start AstroNvim, which needs
the network.

**`cervino-desktop`.** It builds the package with `abuild -d` in
`/work/cervino/cervino-desktop`, from a copy of `cervino-desktop/` with,
next to the APKBUILD:

- `cervino-desktop.conf`, as `sh` assignments: `PKGVER`; `DEPENDS`, the
  features; `PUBKEY`, the file name of the signing key's public key, copied
  next to it; `REPO`, `$APK_REPO/$ALPINE_BRANCH` or empty; and
  `TARGET_ARCH`, `$ARCH`;
- Flathub's downloaded `flathub.flatpakrepo`;
- the `apparmor.d/` directory.

The package is signed with the build's key, which mkimage puts in the image,
so the live system and installs trust it. It is indexed, with
`cervino-vlc`, `cervino-gstreamer`, `cervino-terminal` and the Pi's other
packages, in a repo of its own,
`/work/pkgrepo/$ARCH`, as a package for
`$ARCH` (`apk index --rewrite-arch`: abuild files a noarch package under the
container's architecture, and apk 3 fetches a package from the directory of
the arch its index records), which mkimage gets as a third `--repository`.

**The image's sources.** It puts into `aports/scripts/`:

- the profile, with `mkimg.gnomelive.conf` (`gnomelive_target`,
  `gnomelive_kernel_opts` and `gnomelive_apks`, as `sh` assignments, which
  the profile function sources);
- the apkovl generator, with what it reads: `live/` and
  `genapkovl-gnomelive.conf` (the build settings `TARGET`, `LIVE_USER`,
  `LIVE_PASSWORD`, `AUTOLOGIN`, `KERNEL_OPTS` (kernel arguments) and
  `WORLD`, the root file system's package list, as `sh` assignments).

Last, it copies `/usr/share/mkinitfs` to `/work/mkinitfs` and applies
`initramfs-live.patch` to its `initramfs-init`; the build stops if it
doesn't apply.

### 4. `mkimage_main` (`--mkimage`)

It runs `mkimage.sh --profile gnomelive` with `DATADIR=/work/mkinitfs`,
which reaches `update-kernel`'s `mkinitfs`, so the image's initramfs has the
patched init.

**`mkimg.gnomelive.sh`** is a profile that extends `profile_standard` (for
`rpi`: `profile_rpiimg`, keeping `hostname="rpi"`, which mkimage's
`section_rpi_config` requires, plus a section that puts `usercfg.txt`,
turning on the vc4 KMS overlay, on the boot partition). It:

- sets the image's on-disc apk repo to `$disc_apks`: the disk tools and boot
  loaders Alpine's `setup-disk` adds, `kbd-bkeymaps` for `setup-keymap`, and
  `apparmor-profiles` for `ci/guest/install.sh`;
- leaves the modloop out: mkimage runs with `/work/bin` first in `PATH`,
  where an `update-kernel` wrapper deletes the modloop the real one made
  (the syslinux and grub sections only run with mkimage's own
  `output_format=iso`, so a custom ISO format is no way to do it);
- adds a section putting `/work/rootfs.squashfs` on the image as
  `cervino/rootfs.squashfs`;
- adds `KERNEL_OPTS` to the kernel command line:
  - AppArmor's `lsm=`;
  - `cryptdiscards=yes`, so an encrypted root passes the SSD fstrim's
    discards;
  -
    `sysctl.kernel.printk_ratelimit=0 audit_backlog_limit=8192 log_buf_len=4M`,
    so with no auditd the kernel log keeps every AppArmor message, which the
    denial checks rely on;
  - for `rpi` also `nvme.max_host_mem_size_mb=64`, raising the 32 MB NVMe
    host memory buffer cap the Pi firmware's device tree sets;
    `cgroup_enable=memory`, undoing the `cgroup_disable=memory` it also
    sets; and `console=tty1`, so `/dev/console`, where the initramfs asks
    for an encrypted root's passphrase, is the screen rather than the device
    tree's debug UART.

**`genapkovl-gnomelive.sh`** (a source file in the repo, copied in) builds
the apkovl (the `lbu` overlay format) holding what only the live system has:

- `/etc/apk/world`, the GDM `custom.conf` (autologin) and the OpenRC
  runlevel symlinks;
- a `live-user` init script;
- `setup-alpine`, `lbu`, `adduser`, `setup-disk` and `apk` wrappers in
  `/usr/local/sbin`, all from `live/`, copied in as they are;
- `/usr/local/share/gnomelive/gnomelive.conf`, mode 0600, holding the
  `LIVE_USER`, `LIVE_PASSWORD` and `KERNEL_OPTS` that `live-user`,
  `setup-alpine` and `lbu` source;
- an "Install Alpine Linux" launcher in `/usr/local/share/applications` that
  runs the `setup-alpine` wrapper in GNOME Console, plus a `Hidden=true`
  entry there that hides the package's "Update Alpine Linux" launcher.

## The `cervino-desktop` package

`cervino-desktop/APKBUILD` holds the desktop features' config files:

- profile.d, locale, NetworkManager, nftables, zram, earlyoom, the coredump
  handler, cron/anacron and the Flathub remote;
- the Wi-Fi region: `/usr/libexec/cervino/wifi-region` sets it with `iw` to
  the time zone's country from tzdata's `zone.tab`, or the world region
  `00`. A udev rule runs it when a radio appears (which `test/features.sh`
  simulates with `mac80211_hwsim`), and so does the `wifi-region` service,
  busybox `inotifyd` watching `/etc` for the time zone's files;
- on the Pi, the `dma_heap` devices for the video decoders (to the `video`
  group and the seat's user through `uaccess`, with Raspberry Pi OS's
  `vidbuf_cached` link, whose `grep` of `/proc/iomem` runs under udevd's
  profile), and its `brcmfmac` options
  (`roamoff=1 feature_disable=0x282000`: roaming and the WPA2/WPA3
  handshakes in wpa_supplicant, not the Wi-Fi firmware);
- sshd's sftp subsystem: the external `sftp-server`, so sshd's profile need
  not reach the user's files;
- Firefox's Widevine: `cervino.js` next to Alpine's `vendor.js`, which hides
  it, in `browser/defaults/preferences`. Firefox reads that directory in
  reverse alphabetical order, so the name must sort before `vendor`. On
  `aarch64`, where Mozilla offers no Widevine and Firefox can't download it,
  `/usr/libexec/cervino/widevine [ROOT]` gets Google's from Chrome's
  component update service into `/var/lib/widevine/gmp-widevinecdm/system`;
  the installer and an `/etc/periodic/weekly` job run it, and `profile.d`'s
  `50-widevine.sh` sets `MOZ_GMP_PATH` to it. That build has IFUNCs
  (`R_AARCH64_IRELATIVE`, MTE variants of a few functions), which musl's
  loader rejects, crashing Firefox's CDM process: the script rewrites each
  as a plain relocation to the function its resolver picks without
  hardware capabilities, reading that from the resolver's first
  instructions, and stops if a resolver doesn't look as expected;
- the "Update Alpine Linux" launcher and its `/usr/sbin/update-alpine`
  (package upgrade, then an offered release upgrade);
- the autostart helper that registers the session with GDM and answers
  gnome-session's end-of-session queries for GNOME Shell, also listed in
  GDM's greeter autostart directory so the login screen registers too;
- ...

It also holds the AppArmor profiles with their conf.d files, `/etc/inittab`
and the `/usr/libexec/cervino` helpers that start some daemons under them.

Things to know when changing it:

- abuild rejects files under `/usr/local`.
- The package has `options="!tracedeps"`: abuild would otherwise make it
  provide `cmd:apk` for the apk wrapper, which conflicts with `apk-tools`.
  Then the live system's boot-time install fails, quietly: the boot goes on
  with an almost empty root. So `builder_main` checks that the world
  installs with the built package (`apk add --simulate`) and stops the build
  if not.
- Files other packages own (alpine-baselayout's `inittab` and root crontab,
  shadow's `login.defs`, some daemons' conf.d files) are taken over with
  `replaces=`, which also keeps ours when those packages are upgraded. A new
  one needs its owner (`apk info --who-owns` in an Alpine container) added
  there, or installing fails with a file conflict.
- Like any package's, a file in `/etc` the user changed is kept on upgrade,
  with ours written next to it as `.apk-new`, so settings belong in drop-in
  files where the daemon reads them.
- `cervino-desktop.post-install` adds the features' services to their
  runlevels (the same as the apkovl's; their `-openrc` packages are
  dependencies so their init scripts are there first). It runs only on
  install, so a service the user disabled stays off on upgrades.
- `cervino-desktop.trigger` runs `rc-service apparmor reload` when any
  package changes `/etc/apparmor.d`, only where the apparmor service is
  started (not in the initramfs or `setup-disk`'s chroot), and
  `/usr/libexec/cervino/update-boot` when one changes `/boot`.

## Atomic installs

Atomic installs are run by `/usr/libexec/cervino/atomic.sh`, which
`update-boot`, `update-alpine` and `atomic-finalize` source.

`atomic_detect` is true only on an atomic install's running version:
`/etc/kernel/cmdline` exists, `/` is a `roots/<id>` subvolume, and
`btrfs inspect-internal rootid /` matches the mount's `subvolid`. So in
`update-alpine`'s chroot of a new version (where the kernel hook and the
package trigger also run) they all do nothing.

The volume's top level (mounted on `/run/cervino-volume.*`, as `/tmp` is
gone at shutdown) holds:

- `roots/<id>` (UTC `YYYYMMDDHHMMSS`): read-only, with a writable nested
  `etc` subvolume;
- while an update is staged, `staged` ("NEWID FROMID merge") and `etc-base`,
  a read-only snapshot of the running `/etc` taken when staging.

### Booting on a PC

Atomic installs on a PC are UEFI-only, with no boot loader.

- `update-boot` makes each complete (read-only, not staged) version's kernel
  (`lts` over other flavors), microcode and initramfs into a unified kernel
  image with `ukify` (from `systemd-efistub`),
  `/boot/efi/cervino/<id>/linux.efi`. Its command line is its
  `/etc/kernel/cmdline` plus `rootflags=subvol=/roots/<id>`, kept next to it
  as `cmdline`; the image is rebuilt when that changes.
- It gives each one a UEFI boot entry labelled
  `Alpine Linux YYYY-MM-DD HH:MM:SS`. It only touches entries on its ESP's
  PARTUUID, and deletes the plain `Alpine Linux` one that started Limine on
  earlier installs, with Limine's files.
- The version that starts is first in `BootOrder` (then the other versions,
  then everything else) and copied to `EFI/BOOT/BOOTX64.EFI`, the firmware's
  fallback for lost entries. The version on trial is `BootNext`.

### Which version starts

This is shared with the Pi (below). Where versions start on trial
(`atomic_trial`: a PC with `/sys/firmware/efi`, or a Pi with tryboot):

- the version `update-boot` runs on starts (it started);
- the newest one, if newer and not in the volume's `boot-failed`, is on
  trial, noted in the volume's `boot-trying` and in `/run/cervino-trial`.
  With `UPDATE_BOOT_COMMIT=1` that one starts instead.

`/usr/libexec/cervino/boot-trial boot` (an inittab `::once:` line, after the
default runlevel) adds `boot-trying` to `boot-failed` if another version is
running, then runs `update-boot`, which makes the running version the one
that starts.

Atomic installs turn mkinitfs's trigger off (`disable_trigger=yes`); the
package's `/etc/kernel-hooks.d/50-cervino-boot` (run by `kernel-hooks`)
builds the initramfs and then runs `update-boot`.

### Updating

`update-alpine` on an atomic install runs under
`flock /run/cervino-update.lock`:

- It snapshots the staged version if there is one, else the running one (its
  `etc` from `etc-base`), binds `/proc`, `/sys`, `/dev` and `/var` into it
  with tmpfs `/run` and `/tmp`, and runs the same apk steps as on other
  systems in a chroot of it (`$R` prefixes the files it edits, `run` the
  commands). Then, if the installed database, world or repositories changed,
  it makes it read-only and stages it.
- `add`/`del` run `apk add`/`del` instead.
- `rollback` stages a copy of the newest complete version older than the
  running one, with no merge.
- `list` prints each version (id, date, running, staged, incomplete, next to
  start).
- `delete ID...` (under the same lock) deletes versions, never the running
  one (the staged one with `atomic_unstage`), then runs `update-boot`.

Elsewhere (sys installs, and the containers of `ci/update-test.sh`, which
have no `atomic.sh`) `update-alpine` changes the running system as before.

The `cervino-atomic` service (shutdown runlevel, added by `post-install`)
runs `atomic-finalize`:

1. unless the staged version was made from another one (then it is deleted),
   it lists what changed in `/etc` since `etc-base` with
   `rsync -n -i -c --delete` and copies that into the new `etc` (an update's
   change to a file changed meanwhile is kept as `.apk-new`);
2. deletes `etc-base` and `staged`;
3. deletes all but the newest four complete versions (and the running one);
4. runs `update-boot`, which mounts `/boot/efi` itself since `localmount`
   has stopped (and points `TMPDIR`, for ukify, into `/run`, since `/tmp`
   and `/var` are unmounted and `/` is read-only).

### The apk wrapper

The package's `/usr/sbin/apk` is ahead of `/sbin/apk` in `/etc/profile`'s
and doas's `PATH` (Alpine has no `/usr` merge yet; with one they would be
the same file). It is a wrapper:

- on an atomic install's running system it hands `apk add`/`del` (plain
  package names, harmless options only) to `update-alpine add`/`del` and
  `apk upgrade` to `update-alpine`, and turns down `fix` and other options;
- everything else, `--simulate`, `--root`, and any other system (including
  `update-alpine`'s chroot) gets `/sbin/apk` unchanged.

## Installing

### sys installs

Alpine's `setup-disk` copies what `lbu package` includes (files under `/etc`
that differ from their package's) to the target, writes fstab,
`mkinitfs.conf` and the boot loader's settings, then installs
`/etc/apk/world` with
`apk add --root <target> --initdb ... --overlay-from-stdin`.

The apkovl's `apk` shim (in `/usr/local/sbin`, ahead of the package's
`/usr/sbin/apk`) takes over that one call when the `setup-disk` shim (which
exports `CERVINO_COPY_ROOT=1` before handing over to Alpine's) is in charge.
It:

1. copies `/.cervino/ro` to the target with `rsync -aHX --ignore-existing`,
   so what `setup-disk` wrote stays;
2. builds the initramfs with `mkinitfs -b`;
3. runs apk without `--initdb`, which adds only what the image lacks: the
   boot loader, from the disc, firmware for hardware the image has none for,
   and packages added in the live session;
4. runs the package's `widevine` into the target where it exists
   (`aarch64`);
5. runs `update-extlinux` or `grub-mkconfig` in the target, which the
   packages' triggers would have run when the kernel was installed
   (`setup-disk`'s chroot mounts are up then).

Every other apk call goes through unchanged. The apkovl's live-only files
under `/usr/local` don't reach installs.

### The setup-disk shim

The apkovl's `setup-disk` shim asks whether to install `atomic` (the
default) or `sys` (`-m atomic`/`-m sys` in answer files).

- `sys`, when chosen at its question (after it has asked for the disk and
  whether to encrypt, as `-m sys [-e] <disk>`, so Alpine's doesn't ask its
  own sys/data/crypt/lvm question), and the options it doesn't handle
  (`-m data`, `-L`, `-r`, several disks, a mount point, ...) go to Alpine's
  `setup-disk`.
- It can't install to the disk the live system started from (the Pi's SD
  card): the live root is a squashfs on it, so its disk list (disks with
  nothing mounted) leaves it out.
- On a PC, only one started with UEFI can install atomic: without
  `/sys/firmware/efi` the shim turns down `-m atomic` and makes the
  question's answer `sys`.

### Atomic installs on a PC

The shim does the partitioning itself: GPT with

- a 1 GiB FAT boot partition, mounted on `/boot/efi`;
- swap, sized as Alpine's `setup-disk` sizes it. It is needed: without it
  the earlyoom test fails, the kernel's OOM killer acting first. On an
  encrypted disk `dmcrypt` in boot opens it with a random key;
- btrfs, on LUKS2 (`cryptdm=root`) if asked to encrypt, holding `@var`,
  `@home` and `roots/<id>` (UTC `YYYYMMDDHHMMSS`) with a nested `etc`
  subvolume.

It mounts those on `/mnt` and copies the system there instead of installing
packages:

1. `rsync -aHX` of the live system's root file system image (`/.cervino/ro`,
   as built, not as the session changed it);
2. `lbu package -` (through the `lbu` shim) extracted over it, the disc's
   repositories commented out and `modloop` links removed, as Alpine's
   `setup-disk` does;
3. it writes fstab, `/etc/kernel/cmdline` and `mkinitfs.conf` (the features
   Alpine's `setup-disk` would pick, plus `disable_trigger=yes`);
4. builds the initramfs with `mkinitfs -b` (the image has none);
5. installs packages added in the live session (if `/etc/apk/world` differs
   from the image's) with `apk add --root` from the repositories;
6. removes `gnome-software-plugin-apk2` (in world from `gnome-apps-core`)
   and the `apk-polkit-server` runlevel link, as apk cannot write to the
   system;
7. runs the package's `widevine` into it where it exists (`aarch64`);
8. moves `/root` to `/var/roothome` (a symlink) and makes the root subvolume
   read-only;
9. deletes `Alpine Linux` boot entries whose partition is gone (an earlier
   install on this disk) and runs `update-boot`, which makes the boot entry.

### Atomic installs on a Raspberry Pi

On a Pi (`/proc/device-tree/model`) the table is MBR: the firmware's FAT
partition first (mounted on `/boot/firmware`), swap only with `-s` (Alpine's
default there), then btrfs. The shim copies `usercfg.txt` there.

`update-boot` tells a Pi by `start4.elf`/`bootcode.bin` in the root's
`/boot` (from `raspberrypi-bootloader`, in the Pi's features with the atomic
tools). It:

- copies each version's kernel (`vmlinuz-rpi*` as Alpine's `config.txt`
  picks it), initramfs, `*.dtb` and `overlays/` once into
  `cervino/<id>.new`, renamed to `cervino/<id>/`;
- adds `overlays/README`: the firmware ignores `os_prefix` for overlays
  without one, and Alpine's kernel ships none;
- writes its `cmdline.txt`;
- copies the firmware files from the version `config.txt` starts;
- writes `config.txt` with `os_prefix=cervino/<id>/` (the others as
  comments).

The firmware has no menu, so where it has tryboot
(`/proc/device-tree/chosen/bootloader/tryboot` exists), `config.txt` starts
the version that starts and `tryboot.txt` the one on trial (see "Which
version starts" above). The firmware only reads `tryboot.txt` at a restart
with the tryboot flag, so `boot-trial` has two more steps on the Pi:

- `shutdown` (from the `cervino-atomic` service, after `atomic-finalize`)
  commits the version on trial with `UPDATE_BOOT_COMMIT=1` unless the
  machine restarts;
- `reboot` (an inittab `::shutdown:` line after `openrc shutdown`, when the
  file systems are read-only) restarts with `reboot(2)`'s `RESTART2` and
  `"0 tryboot"` through `/usr/libexec/cervino/tryboot`, as busybox init
  passes no argument and the kernel's firmware driver clears the flag on any
  other restart. `tryboot` is `cervino-desktop/tryboot.c`, built only for
  `aarch64`: freestanding, no libc, by clang with lld; the package has
  `!archcheck` for it.

Busybox init doesn't tell a restart from a power off, so the package's
elogind `system-shutdown` hook (its `$1` is `reboot`) and its
`/usr/sbin/reboot` wrapper (ahead of busybox's in `PATH`; also inittab's
Ctrl-Alt-Del) write `/run/cervino-reboot`. Without it, a restart commits
like a power off.

The Pi path has been run on a Pi 500+, but the tryboot fallback has not.

## The live system's boot

At boot the initramfs (Alpine's init with `initramfs-live.patch`) finds
`cervino/rootfs.squashfs` on the boot media that `nlplug-findfs` mounted. It
loop-mounts it read-only on `/.cervino/ro` with a tmpfs on `/.cervino/rw`
(not under `/media`, where GNOME Files would list them), mounts an overlay
of the two as the root, unpacks the apkovl into it and skips installing the
world. If the image is missing or doesn't mount, it falls back to Alpine's
tmpfs root and installs the world from the disc.

The rest of Alpine's init (the disc's `/etc/apk/repositories`, moving the
mounts into the new root, `switch_root`) is unchanged. Then OpenRC starts
the services.

The apkovl's `/etc/apk/world` is the root file system's, kernel and firmware
included, so `setup-disk` fetches those from the mirror, as it fetched the
kernel before.

## Editing the generated files

Most changes happen in `cervino-desktop/` (the desktop features) or `live/`
and `genapkovl-gnomelive.sh` (the live system).

### Files and build settings

- **No file longer than 20 lines is written through a heredoc or
  templated.** It is a source file of its own, copied in as it is: the
  package's in `cervino-desktop/` (installed by the APKBUILD with
  `makefile ... < "$startdir"/<name>`), the live system's in `live/` (by the
  generator with `makefile ... < "$here"/live/<name>`), named as installed
  (but `cervino-desktop/apk-wrapper`, the package's `/usr/sbin/apk`).
- A script that needs a build setting reads it at run time instead: the live
  system's source `/usr/local/share/gnomelive/gnomelive.conf`, the mkimage
  profile `mkimg.gnomelive.conf`.
- Only files of 20 lines or fewer are written with heredocs, and only those
  may have settings filled in.
- In those short heredocs, use a quoted `<<'EOF'` for a file with no build
  settings in it, so it is written out as is. The APKBUILD's files have none
  (build settings are the live system's), except:
  - the signing key in `/etc/apk/keys`, so a later package can bring a new
    one;
  - with `APK_REPO`, `/etc/apk/repositories.d/cervino.list` (apk 3 reads
    those lists besides `/etc/apk/repositories`, which stays the user's),
    from `cervino-desktop.conf`.
- A short file that needs a build setting (`/etc/apk/world`, GDM's
  `custom.conf`) uses an unquoted `<<EOF`: `$LIVE_USER` etc. are filled in
  when the generator runs.
- A new build setting has to be added to the `genapkovl-gnomelive.conf` that
  `builder_main` writes, quoted with `shquote` (and, for the live system's
  scripts, to the `gnomelive.conf` the generator writes); the profile's to
  `mkimg.gnomelive.conf`.

### Runlevels

Runlevels mirror the standard ISO's, changed the way `setup-desktop gnome`
changes them: udev in place of mdev/hwdrivers, no `modloop` (the root file
system has the modules), plus `cgroups`, `dbus`, `live-user` and `gdm` in
default.

The apkovl also holds the desktop features' runlevels: `zram-init` in boot,
`apparmor` in sysinit (its conf.d orders it before udev, so udevd starts
confined), and their daemons (NetworkManager, chronyd, earlyoom, cupsd,
wifi-region, ...) in default.

### The setup-alpine wrapper

The `setup-alpine` wrapper exists so installing from inside the live desktop
works. It puts temporary shims first in `PATH`:

- `openrc` with `--no-stop`, so gdm and dbus are not killed;
- `rc-service`, which skips `networking stop`/`start` and turns
  `hostname restart` into a plain `hostname` call. Both would stop
  dependents such as chronyd and avahi and restart them in the background,
  where they deadlock on OpenRC's service locks with the next step's udev
  stop;
- `setup-devd`, which skips the `-C mdev` bootstrap (udev is already
  running);
- `rc-update`, which turns `add crond` into `add cronie` and skips
  `add acpid`:
  - busybox crond never runs a daily/weekly/monthly job the machine was off
    for. The apkovl's root crontab keeps only the 15min and hourly runs, and
    `/etc/cron.d/anacron` runs anacron at boot and hourly for
    `/etc/anacrontab`'s;
  - busybox acpid's only handler powers off on the power button at once,
    going around elogind and GNOME's power button setting. Its profile stays
    for anyone who enables it, but no test checks it, as it never runs in
    the VM;
- no-op `setup-interfaces`/`setup-dns`: NetworkManager manages the network;
  ifupdown only has `lo`.

The `openrc` and `rc-service` shims run OpenRC under `setsid -w`, so Ctrl-C
cannot kill a service transition halfway and leave its lock and state
behind.

It sets these defaults:

- `DEVDOPTS=udev`;
- `APKREPOSOPTS=-c` (community enabled);
- `MIRRORS` (which `setup-apkrepos` picks from): the `https://` URLs in
  `mirrors.alpinelinux.org/mirrors.json`, falling back to the CDN, since its
  default `mirrors.txt` only lists `http://` ones;
- `USEROPTS` with the `plugdev` and `lpadmin` groups;
- `KERNELOPTS` with `KERNEL_OPTS` (AppArmor's `lsm=`, `cryptdiscards=yes`,
  the kernel log limits, and on the Pi the NVMe cap, the memory cgroup
  controller and `console=tty1`);
- `SSHDOPTS=none` (no SSH server);
- `PROXYOPTS=none` and `USERSSHKEY=none`: no proxy or SSH key questions,
  which are server features (GNOME Settings has its own proxy settings);
- `NTPOPTS=none`: setup-ntp's default, busybox ntpd, would run next to
  chronyd, which the install already has from the live runlevels.

It passes `-e`, so no root password is asked for. An answer file passed with
`-f` still overrides those defaults (but not `-e`).

### Permanent shims

`setup-alpine` sources `/etc/profile` part way through, which resets `PATH`
and drops the temporary shims. So shims needed after that point live
permanently in `/usr/local/sbin`, which `/etc/profile` puts first:
`setup-disk` (see above), `lbu` and `adduser`.

`lbu`: `setup-disk` copies the live `/etc` to the target with
`lbu package -`, and the shim filters that archive:

- it drops the live user (passwd/shadow/group), its home directory
  (`setup-alpine` runs `lbu add` on every `/home/*`), the `live-user` init
  script and runlevel link, and GDM autologin;
- if the copy's `wheel` group has a member, it locks root's password (`!`);
- it starts the serial-console getty the initramfs added to `inittab`
  through `apparmor-exec`;
- on the Pi it adds `boot/usercfg.txt` (from `/usr/local/share/gnomelive`,
  which only the Pi's apkovl has): `setup-disk` unpacks the archive into the
  target with its boot partition mounted on `/boot`.

`adduser`: gives users created by `setup-user` bash as their login shell and
a mode 0700 home directory (`/etc/default/useradd` and `HOME_MODE` in
`/etc/login.defs` do the same for shadow's `useradd`, which GNOME Settings
uses). Under the `setup-alpine` wrapper (which sets `GNOMELIVE_SETUP=1`) it
lists the users it makes in `/run/gnomelive-setup-users` and accepts them
again on a later run, updating the full name, since `setup-user` asks for a
user again when `adduser` fails and the live `/etc` keeps a user from an
abandoned run.

## AppArmor profiles

`apparmor.d/` holds one profile per daemon that `test/apparmor.sh` checks
(plus `busybox-acpid`, for acpid, which installs leave off), all in enforce
mode. Avahi's and dnsmasq's come from Alpine's `apparmor-profiles`;
`apparmor.d/local/usr.sbin.dnsmasq` adds what NetworkManager's `dns=dnsmasq`
instance needs through that profile's `local/` include. The APKBUILD copies
them, `local/` included, into the package's `/etc/apparmor.d`.

How they attach:

- Each attaches by the daemon's path, except where a path can't single the
  daemon out: busybox applets (`busybox-syslogd`, `busybox-acpid`,
  `busybox-getty`, and `wifi-region`, the service's `inotifyd`) and the
  system bus (`dbus-system`; the same `dbus-daemon` runs every session bus).
- Those are started under their profile by name through
  `/usr/libexec/cervino/apparmor-exec`, which runs them unconfined if the
  profile isn't loaded. The services' conf.d files source
  `/usr/libexec/cervino/apparmor-start.sh`, which replaces OpenRC's default
  `start` (so it only works while the init script doesn't define its own),
  and the package's `/etc/inittab` wraps the gettys.
- The serial console getty the initramfs appends to inittab is wrapped by
  the `lbu` shim, so only on installed systems.

What they allow:

- Helpers a daemon runs either stay in its profile (`ix`), or run unconfined
  (`Ux`) when they are the user's session, a login or service control:
  sessions from `gdm-session-worker`, jobs from crond, poweroff from
  elogind, D-Bus activation through `dbus-daemon-launch-helper`, after which
  each service attaches to its own profile.
- Every profile accepts signals from `peer=busybox`: root's shells (and
  `rc-service`, `kill`, `killprocs` run from them) carry the label of
  Alpine's unconfined-mode `busybox` profile, not `unconfined`, which
  `abstractions/base` already lets in.
- Alpine's `dbus-daemon` has no AppArmor support and the kernel doesn't
  mediate Unix sockets, so the profiles have no `dbus` or `unix` rules.

To work out what a daemon needs, load its profile with `flags=(complain)`,
exercise it, and collect the `apparmor="ALLOWED"` lines from `dmesg` (the
image's kernel arguments keep them from being dropped); then check for
`apparmor="DENIED"` in enforce mode. `apparmor_parser -QT -K <file>` in an
Alpine container checks a profile's syntax.
