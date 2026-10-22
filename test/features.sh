#!/usr/bin/env bash

set -u

PASS=0
FAIL=0
SKIP=0

# FORCE_COLOR: colour even when not writing to a terminal
if [[ -t 1 || -n ${FORCE_COLOR:-} ]]; then
    C_PASS=$'\e[32m' C_FAIL=$'\e[31m' C_SKIP=$'\e[33m' C_OFF=$'\e[0m'
else
    C_PASS='' C_FAIL='' C_SKIP='' C_OFF=''
fi

run_test() {
    local desc=$1 fn=$2 reason rc
    reason=$("$fn" 2>/dev/null)
    rc=$?
    case $rc in
        0) PASS=$((PASS + 1)); printf '%s[PASS]%s %s\n' "$C_PASS" "$C_OFF" "$desc" ;;
        2) SKIP=$((SKIP + 1)); printf '%s[SKIP]%s %s\n' "$C_SKIP" "$C_OFF" "$desc" ;;
        *) FAIL=$((FAIL + 1)); printf '%s[FAIL]%s %s\n' "$C_FAIL" "$C_OFF" "$desc" ;;
    esac
    [[ -n $reason ]] && printf '       %s\n' "$reason"
    return 0
}

have() { command -v "$1" >/dev/null 2>&1; }

first_have() {
    local c
    for c; do have "$c" && { echo "$c"; return 0; }; done
    return 1
}

proc_running() {
    local f comm p
    for f in /proc/[0-9]*/comm; do
        read -r comm <"$f" 2>/dev/null || continue
        for p; do
            [[ $comm == "${p:0:15}" ]] && return 0
        done
    done
    return 1
}

service_enabled() {
    local s=$1 d
    if have systemctl && [[ -d /run/systemd/system ]]; then
        systemctl is-enabled "$s" >/dev/null 2>&1 && return 0
    fi
    if have rc-update; then
        rc-update show 2>/dev/null | grep -Eq "^[[:space:]]*$s[[:space:]]*\|" && return 0
    fi
    for d in /var/service /etc/service /etc/runit/runsvdir/default /etc/s6/adminsv/default/contents.d /etc/dinit.d/boot.d; do
        [[ -e $d/$s ]] && return 0
    done
    return 1
}

dbus_name_available() {
    local bus=$1 name=$2 m
    have gdbus || return 1
    for m in ListNames ListActivatableNames; do
        gdbus call "$bus" --dest org.freedesktop.DBus \
            --object-path /org/freedesktop/DBus \
            --method "org.freedesktop.DBus.$m" 2>/dev/null |
            grep -q "'$name'" && return 0
    done
    return 1
}

login_shell() { getent passwd "$(id -un)" | cut -d: -f7; }

# Runs a command as root without asking for a password: directly when root,
# else through doas or sudo if they let the user in without one.
as_root() {
    ((EUID == 0)) && { "$@"; return; }
    local tool
    tool=$(first_have doas sudo) || return 1
    "$tool" -n "$@"
}

# The periodic jobs cron runs (root's own crontab is only readable by root)
scheduled_job_files() {
    local f
    for f in /etc/periodic/*/* /etc/cron.hourly/* /etc/cron.daily/* /etc/cron.weekly/* \
             /etc/cron.monthly/* /etc/cron.d/* /etc/crontab; do
        [[ -f $f && -r $f ]] && printf '%s\n' "$f"
    done
}

# --------------------------------------------------------------------------
# Shell and command-line environment
# --------------------------------------------------------------------------

t_interactive_shell() {
    local shell
    shell=$(login_shell)
    case ${shell##*/} in
        bash | zsh | fish | ksh | mksh | oksh | tcsh | nu | elvish | xonsh) return 0 ;;
    esac
    echo "login shell is $shell (a minimal POSIX shell)"
    return 1
}

t_privilege_escalation() {
    local tool
    tool=$(first_have sudo doas run0 sudo-rs) || { echo "no sudo, doas or run0"; return 1; }
    id -nG | tr ' ' '\n' | grep -Eqx 'wheel|sudo|admin' ||
        { echo "$tool present but user is not in an admin group"; return 1; }
}

# Admin users get root through sudo/doas, so root itself should not be able
# to log in with a password. /etc/shadow is only readable by root, so a user
# asks AccountsService (which reads it as root) instead; it only counts a
# hash starting with "!" as locked, not "*".
t_root_locked() {
    local hash obj
    if [[ -r /etc/shadow ]]; then
        hash=$(awk -F: '$1 == "root" { print $2 }' /etc/shadow)
        case $hash in
            '!'* | '*'*) return 0 ;;
            '') echo "root has an empty password" ;;
            *) echo "root has a password" ;;
        esac
        return 1
    fi
    have gdbus || { echo "cannot read /etc/shadow and no gdbus to ask AccountsService"; return 1; }
    obj=$(gdbus call --system --dest org.freedesktop.Accounts \
        --object-path /org/freedesktop/Accounts \
        --method org.freedesktop.Accounts.FindUserByName root 2>/dev/null) ||
        { echo "cannot read /etc/shadow and AccountsService does not answer"; return 1; }
    obj=${obj#*\'} obj=${obj%%\'*}
    gdbus call --system --dest org.freedesktop.Accounts --object-path "$obj" \
        --method org.freedesktop.DBus.Properties.Get org.freedesktop.Accounts.User Locked 2>/dev/null |
        grep -q true && return 0
    case $(gdbus call --system --dest org.freedesktop.Accounts --object-path "$obj" \
        --method org.freedesktop.DBus.Properties.Get org.freedesktop.Accounts.User PasswordMode 2>/dev/null) in
        *' 2>'*) echo "root has an empty password" ;;
        *) echo "root's password is not locked" ;;
    esac
    return 1
}

t_cli_tools() {
    local missing=()
    have file                          || missing+=("file")
    have xz                            || missing+=("xz")
    have zstd                          || missing+=("zstd")
    have lspci                         || missing+=("lspci")
    first_have dmidecode lshw inxi hwinfo >/dev/null || missing+=("hardware info (dmidecode/lshw/inxi)")
    first_have ss netstat >/dev/null   || missing+=("socket stats (ss/netstat)")
    have rsync                         || missing+=("rsync")
    first_have less most >/dev/null    || missing+=("pager (less/most)")
    ((${#missing[@]} == 0)) || { echo "missing: ${missing[*]}"; return 1; }
}

# Most programs distributed outside the distribution are built for glibc
# and need its dynamic loader; on musl systems gcompat provides one.
t_glibc_programs() {
    local loader d
    case $(uname -m) in
        x86_64) loader=ld-linux-x86-64.so.2 ;;
        aarch64) loader=ld-linux-aarch64.so.1 ;;
        *) echo "unknown glibc loader name for $(uname -m)"; return 2 ;;
    esac
    for d in /lib64 /lib /usr/lib64 /usr/lib; do
        [[ -e $d/$loader ]] && return 0
    done
    echo "no $loader (glibc, or gcompat on musl)"
    return 1
}

t_man_pages() {
    have man || { echo "no man command (man-db or mandoc)"; return 1; }
    man -w man >/dev/null 2>&1 || { echo "no man page for man"; return 1; }
}

t_command_not_found() {
    local shell
    shell=$(login_shell)
    case ${shell##*/} in
        zsh)  zsh -ic 'whence -w command_not_found_handler' >/dev/null 2>&1 ;;
        fish) fish -ic 'functions -q fish_command_not_found' >/dev/null 2>&1 ;;
        *)    bash -ic 'declare -F command_not_found_handle' >/dev/null 2>&1 ;;
    esac || { echo "no command-not-found handler in interactive ${shell##*/}"; return 1; }
}

t_default_editor() {
    local shell ed
    shell=$(login_shell)
    ed=$("$shell" -l -c 'echo "${VISUAL:-$EDITOR}"' 2>/dev/null </dev/null)
    [[ -n $ed ]] || { echo "neither EDITOR nor VISUAL set in a login shell"; return 1; }
}

t_local_bin_first_in_path() {
    local shell path first
    shell=$(login_shell)
    path=$("$shell" -l -c 'printenv PATH' 2>/dev/null </dev/null)
    first=${path%%:*}
    [[ ${first%/} == "$HOME/.local/bin" ]] || { echo "first PATH entry in a login shell is '${first:-unset}'"; return 1; }
}

# --------------------------------------------------------------------------
# Localisation
# --------------------------------------------------------------------------

t_utf8_locale() {
    local ctype=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
    [[ $ctype =~ [Uu][Tt][Ff]-?8 ]] || { echo "session locale is '${ctype:-unset}'"; return 1; }
}

t_spell_dictionary() {
    local p
    for p in /usr/share/hunspell/en_*.dic /usr/share/myspell/en_*.dic \
             /usr/share/myspell/dicts/en_*.dic /usr/lib*/aspell*/en*.multi \
             /usr/share/nuspell/en_*.dic; do
        [[ -e $p ]] && return 0
    done
    echo "no English hunspell/aspell dictionary"
    return 1
}

t_fonts_emoji() {
    have fc-list || { echo "fontconfig missing"; return 1; }
    [[ -n $(fc-list ':charset=1f600' family) ]] || { echo "no font covers U+1F600"; return 1; }
}

t_fonts_cjk() {
    have fc-list || { echo "fontconfig missing"; return 1; }
    [[ -n $(fc-list ':lang=ja' family) ]] || { echo "no Japanese-capable font"; return 1; }
    [[ -n $(fc-list ':lang=zh-cn' family) ]] || { echo "no Simplified Chinese font"; return 1; }
}

# --------------------------------------------------------------------------
# System services
# --------------------------------------------------------------------------

t_network_manager() {
    if proc_running NetworkManager; then
        have nmcli && nmcli -t -f RUNNING general 2>/dev/null | grep -qx running && return 0
        echo "NetworkManager running but nmcli cannot talk to it"
        return 1
    fi
    proc_running connmand systemd-networkd && return 0
    echo "no network management daemon (NetworkManager/ConnMan/systemd-networkd)"
    return 1
}

t_time_sync() {
    proc_running chronyd systemd-timesyncd ntpd openntpd ntpsec && return 0
    echo "no NTP client running"
    return 1
}

t_settings_dbus_services() {
    # Desktop settings panels use these for device name, time/timezone and
    # system language (systemd, openrc-settingsd and others provide them)
    local n missing=()
    for n in org.freedesktop.hostname1 org.freedesktop.timedate1 org.freedesktop.locale1; do
        dbus_name_available --system "$n" || missing+=("$n")
    done
    ((${#missing[@]} == 0)) || { echo "missing D-Bus services: ${missing[*]}"; return 1; }
}

t_bluetooth() {
    proc_running bluetoothd && return 0
    service_enabled bluetooth || service_enabled bluetoothd ||
        { echo "bluetooth service neither running nor enabled at boot"; return 1; }
}

t_printing() {
    have lpstat || { echo "no print system client (lpstat)"; return 1; }
    lpstat -r 2>/dev/null | grep -q 'scheduler is running' ||
        { echo "print scheduler not running"; return 1; }
}

t_mdns() {
    local name
    name=$(hostname -s 2>/dev/null || hostname)
    [[ $name == localhost ]] && { echo "hostname is still localhost"; return 1; }
    getent hosts "$name.local" >/dev/null 2>&1 && return 0
    if have avahi-resolve; then
        timeout 5 avahi-resolve -n "$name.local" >/dev/null 2>&1 && return 0
    fi
    if have resolvectl; then
        timeout 5 resolvectl query -p mdns "$name.local" >/dev/null 2>&1 && return 0
    fi
    echo "$name.local not published by an mDNS responder (Avahi/resolved)"
    return 1
}

t_firewall() {
    proc_running firewalld && return 0
    grep -qs '^ENABLED=yes' /etc/ufw/ufw.conf && return 0
    local s
    for s in nftables iptables ip6tables awall shorewall ferm; do
        service_enabled "$s" && return 0
    done
    [[ -s /proc/net/ip_tables_names ]] && return 0
    echo "no firewall service active (firewalld/ufw/nftables/iptables)"
    return 1
}

# Containers (Docker, Podman) and VMs (libvirt) on a NAT bridge reach the
# network through the host's forward hook, and a packet has to get past
# every base chain on it: a chain that drops forwarded traffic cuts them off,
# whatever rules the runtimes add in their own tables. Such a chain has to
# accept traffic coming in from their bridges and the replies going back.
# A chain that jumps to others (Docker's own FORWARD chain does) is taken to
# accept them there. Reading the ruleset needs root, so the test is skipped
# when the user cannot get it without a password.
t_firewall_forwarding() {
    local ruleset blocked
    proc_running firewalld && return 0
    ruleset=$(as_root nft list ruleset 2>/dev/null) ||
        { echo "cannot read the nftables ruleset without root"; return 2; }
    blocked=$(awk -v bridges='(virbr|docker|podman|cni-|br-|lxcbr|lxdbr|incusbr)' '
        /^[ \t]*table / { table = $2 " " $3 }
        /^[ \t]*chain / { inchain = 1; name = $2; drop = out = back = 0; next }
        !inchain { next }
        /hook forward/ && /policy drop/ { drop = 1; next }
        /^[ \t]*}/ {
            if (drop && !(out && back)) print table " " name
            inchain = 0
            next
        }
        /(^|[ \t])(jump|goto)[ \t]/ { out = back = 1 }
        /(^|[ \t])accept([ \t]|$)/ {
            if ($0 ~ /^[ \t]*accept[ \t]*$/) out = back = 1
            if ($0 ~ /iifname/ && $0 ~ bridges) out = 1
            if ($0 ~ /established/ || ($0 ~ /oifname/ && $0 ~ bridges)) back = 1
        }' <<<"$ruleset")
    [[ -z $blocked ]] && return 0
    echo "forwarded traffic of container/VM bridges dropped by: $(echo $blocked)"
    return 1
}

# Run as root by t_ipv6_rpfilter: sets up a network namespace joined to the
# host by a veth pair, sends a TCP SYN to port 22 (open in the firewall) at
# the host from an address it has a route back to and at another of its
# addresses from one it has none back to (2001:db8:dead::/64 is
# unreachable), and prints for each "in" or "out": whether it got past
# every input chain, which a counter in a chain of its own that runs after
# every other shows. Needs iproute2's ip (busybox ip has no netns).
rpfilter_probe() {
    local ns=rpftest c v=
    cleanup() {
        ip netns del "$ns" 2>/dev/null
        ip -6 route del unreachable 2001:db8:dead::/64 2>/dev/null
        nft delete table inet rpftest 2>/dev/null
    }
    cleanup
    trap cleanup EXIT
    (
        set -e
        ip netns add "$ns"
        ip link add rpf-host type veth peer name eth0 netns "$ns"
        nmcli device set rpf-host managed no 2>/dev/null || true
        ip addr add fd18::1/64 dev rpf-host nodad
        ip addr add fd18::3/128 dev rpf-host nodad
        ip link set rpf-host up
        ip -n "$ns" addr add fd18::2/64 dev eth0 nodad
        ip -n "$ns" addr add 2001:db8:dead::2/128 dev eth0 nodad
        ip -n "$ns" link set eth0 up
        ip -n "$ns" -6 route add fd18::3/128 dev eth0 src 2001:db8:dead::2
        ip -6 route add unreachable 2001:db8:dead::/64
        nft -f - <<'EOF'
table inet rpftest {
    counter arrived {}
    chain input {
        type filter hook input priority 2147483647; policy accept;
        iifname "rpf-host" tcp dport 22 counter name "arrived"
    }
}
EOF
    ) >/dev/null || return 1
    for c in fd18::1 fd18::3; do
        nft reset counter inet rpftest arrived >/dev/null
        ip netns exec "$ns" timeout 2 bash -c 'exec 3<>"/dev/tcp/$1/22"' _ "$c" 2>/dev/null
        nft list counter inet rpftest arrived | grep -Eq 'packets [1-9]' && v+=" in" || v+=" out"
    done
    echo $v
}

# Like Fedora (IPv6_rpfilter=loose in Workstation's firewalld.conf), drop
# IPv6 packets from source addresses the host has no route back to, which
# are spoofed. IPv4 has the kernel's rp_filter. Needs root, so the test is
# skipped when the user cannot get it without a password.
t_ipv6_rpfilter() {
    local out
    as_root true 2>/dev/null || { echo "cannot set up a test network without root"; return 2; }
    out=$(as_root bash -c "$(declare -f rpfilter_probe); rpfilter_probe" 2>/dev/null) ||
        { echo "cannot set up a test network (needs iproute2's ip and nft)"; return 1; }
    case $out in
        "in out") return 0 ;;
        "in in") echo "a packet from 2001:db8:dead::2, which has no route back, got in" ;;
        *) echo "cannot tell: a packet to SSH (port 22) from fd18::2 did not get in either" ;;
    esac
    return 1
}

# A network service nobody asked for is something more to attack: sshd, if
# installed, should only run once the user turns it on.
t_sshd_disabled() {
    service_enabled sshd && { echo "sshd is enabled"; return 1; }
    proc_running sshd && { echo "sshd is running"; return 1; }
    return 0
}

# The system log should go back days, not minutes, so that it still covers
# a problem when you look into it, and the file system it is on needs the
# room. journald (by default up to 10% of the file system) and syslog
# daemons, whose files logrotate rotates, keep that much; busybox syslogd
# rotates by itself, by default at 200 KiB (-s) with one old file (-b).
t_log_retention() {
    local min_kib=32768 f comm pid= args size=200 old=1 avail
    for f in /proc/[0-9]*/comm; do
        read -r comm <"$f" 2>/dev/null || continue
        [[ $comm == syslogd ]] && pid=${f%/comm}
    done
    if [[ -n $pid && $(readlink -f "$(tr '\0' '\n' <"$pid/cmdline" | head -n1)") == */busybox ]]; then
        mapfile -d '' args <"$pid/cmdline"
        set -- "${args[@]:1}"
        while (($#)); do
            case $1 in
                -s) size=$2; shift ;;
                -s*) size=${1#-s} ;;
                -b) old=$2; shift ;;
                -b*) old=${1#-b} ;;
                -C*) echo "busybox syslogd keeps the log in memory only (-C)"; return 1 ;;
            esac
            shift
        done
        ((size == 0 || size * (old + 1) >= min_kib)) ||
            { echo "busybox syslogd keeps at most $((size * (old + 1))) KiB of log (-s $size -b $old)"; return 1; }
    elif ! proc_running systemd-journald rsyslogd syslog-ng metalog socklog syslogd; then
        echo "no system logger running"
        return 1
    fi
    avail=$(df -Pk /var/log 2>/dev/null | awk 'NR == 2 { print $4 }')
    ((${avail:-0} >= min_kib)) || { echo "only ${avail:-0} KiB free for /var/log"; return 1; }
}

# Core dumps are as big as the crashed process's memory, and hold what it
# had in it, so they should not be kept forever. systemd-coredump, apport
# and ABRT remove old ones themselves; another collector needs the handler
# or a periodic job to delete dumps by age (find ... -mtime/-mmin).
t_coredump_cleanup() {
    local pat handler f
    pat=$(cat /proc/sys/kernel/core_pattern)
    [[ $pat == '|'* ]] || { echo "no crash collector"; return 2; }
    handler=${pat#|}
    handler=${handler%% *}
    case ${handler##*/} in
        systemd-coredump | apport | abrt-hook-ccpp) return 0 ;;
    esac
    while read -r f; do
        grep -Eq 'find .*core.*-m(time|min)|find .*-m(time|min).*core' "$f" 2>/dev/null && return 0
    done < <(printf '%s\n' "$handler"; scheduled_job_files)
    echo "nothing deletes old core dumps of $handler by age"
    return 1
}

# SSDs slow down unless the file system tells them which blocks are free,
# either as it frees them (the discard mount option) or now and then
# (fstrim run by a timer or cron job).
t_ssd_trim() {
    local src mnt fs opts sys need=() trims=0
    while read -r src mnt fs opts _; do
        [[ $src == /dev/* ]] || continue
        case $fs in ext2 | ext3 | ext4 | xfs | btrfs | f2fs | jfs | vfat | exfat) ;; *) continue ;; esac
        sys=$(readlink -f "/sys/class/block/$(basename "$(readlink -f "$src")")") || continue
        [[ -e $sys/partition ]] && sys=${sys%/*}
        (($(cat "$sys/queue/discard_max_bytes" 2>/dev/null || echo 0) > 0)) || continue
        trims=1
        [[ ,$opts, == *,discard[,=]* ]] || need+=("$mnt")
    done </proc/mounts
    ((trims)) || { echo "no file system on a device that supports TRIM"; return 2; }
    ((${#need[@]} == 0)) && return 0
    if have systemctl && [[ -d /run/systemd/system ]]; then
        systemctl is-enabled fstrim.timer >/dev/null 2>&1 && return 0
    fi
    service_enabled fstrim && return 0
    scheduled_job_files | xargs -r grep -lw fstrim >/dev/null 2>&1 && return 0
    echo "no discard mount option or periodic fstrim for: ${need[*]}"
    return 1
}

t_power_profiles() {
    dbus_name_available --system net.hadess.PowerProfiles && return 0
    dbus_name_available --system org.freedesktop.UPower.PowerProfiles && return 0
    proc_running tuned auto-cpufreq && return 0
    service_enabled tlp && return 0
    echo "no power management service (power-profiles-daemon/tuned/TLP)"
    return 1
}

t_coredump_handler() {
    local pat
    pat=$(cat /proc/sys/kernel/core_pattern)
    [[ $pat == '|'* ]] || { echo "core_pattern is '$pat' (no crash collector)"; return 1; }
}

t_mandatory_access_control() {
    if [[ -r /sys/fs/selinux/enforce ]]; then
        [[ $(cat /sys/fs/selinux/enforce) == 1 ]] && return 0
        echo "SELinux present but not enforcing"
        return 1
    fi
    [[ $(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) == Y ]] && return 0
    grep -Eqs '(^|,)(smack|tomoyo)(,|$)' /sys/kernel/security/lsm && return 0
    echo "no MAC security module active (SELinux/AppArmor/Smack/TOMOYO)"
    return 1
}

t_memory_compression() {
    grep -q '^/dev/zram' /proc/swaps && return 0
    [[ $(cat /sys/module/zswap/parameters/enabled 2>/dev/null) == Y ]] && return 0
    echo "neither zram swap nor zswap enabled"
    return 1
}

t_firmware() {
    local mod fw f d ok missing=()
    have modinfo || { echo "no modinfo (kmod)"; return 2; }
    while read -r mod _; do
        fw=$(modinfo -F firmware "$mod" 2>/dev/null)
        [[ -n $fw ]] || continue
        ok=0
        while read -r f; do
            for d in /lib/firmware /usr/lib/firmware; do
                compgen -G "$d/$f" >/dev/null || compgen -G "$d/$f.zst" >/dev/null ||
                    compgen -G "$d/$f.xz" >/dev/null || continue
                ok=1; break 2
            done
        done <<<"$fw"
        ((ok)) || missing+=("$mod")
    done </proc/modules
    ((${#missing[@]} == 0)) || { echo "no firmware for loaded drivers: ${missing[*]}"; return 1; }
}

# --------------------------------------------------------------------------
# Desktop integration
# --------------------------------------------------------------------------

t_pipewire_audio() {
    proc_running pipewire || { echo "PipeWire is not running"; return 1; }
    proc_running wireplumber pipewire-media-session ||
        { echo "no PipeWire session manager (WirePlumber) running"; return 1; }
    proc_running pulseaudio && { echo "PulseAudio is running instead of PipeWire's replacement"; return 1; }
    proc_running pipewire-pulse || { echo "pipewire-pulse is not running"; return 1; }
    [[ -S ${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native ]] ||
        { echo "no PulseAudio-compatible socket in the runtime directory"; return 1; }
}

t_audio_sink() {
    grep -q '^ *[0-9]' /proc/asound/cards 2>/dev/null || { echo "no sound card present"; return 2; }
    have wpctl || { echo "wpctl missing"; return 1; }
    wpctl inspect @DEFAULT_AUDIO_SINK@ >/dev/null 2>&1 ||
        { echo "sound card present but PipeWire has no audio sink"; return 1; }
}

t_xdg_open() {
    have xdg-open || { echo "xdg-utils not installed"; return 1; }
}

t_app_store_sandbox() {
    have flatpak || { echo "Flatpak not installed"; return 1; }
    [[ -n $(flatpak remotes --columns=name 2>/dev/null) ]] || { echo "no Flatpak remote configured"; return 1; }
}

t_app_store_distro_packages() {
    # GNOME Software lists the distribution's packages through a packaging
    # plugin (PackageKit, apk, ...) and the distribution's AppStream catalog.
    # gnome-software-cmd runs the same plugins as the app, so a search there
    # finds what a search in the app would. Before searching it refreshes
    # every plugin's metadata, which the app does in the background; fwupd's
    # (firmware from LVFS, not packages) can take minutes to fail when LVFS
    # is slow, so that plugin is left out.
    have gnome-software || { echo "GNOME Software not installed"; return 2; }
    dbus_name_available --session org.gnome.SessionManager || { echo "not in a GNOME session"; return 2; }
    local cmd out why
    cmd=$(first_have /usr/libexec/gnome-software-cmd /usr/lib/gnome-software/gnome-software-cmd) ||
        { echo "no gnome-software-cmd"; return 2; }
    # --verbose logs to stdout too, which shows why a plugin failed
    out=$(timeout 120 "$cmd" --verbose --plugin-blocklist=fwupd --show-results --refine-flags=origin search gimp 2>&1)
    # apk-polkit reports an up-to-date index as an error: not the cause
    why=$(grep -Eo "Failed to (refresh|setup) plugin .*" <<<"$out" | grep -v "file is unchanged" | head -n1)
    grep -Eq '^bundle-kind: +package$' <<<"$out" && return 0
    echo "GNOME Software finds no distribution package for 'gimp'${why:+ ($why)}"
    return 1
}

t_app_store_firmware_updates() {
    # GNOME Software offers OEM firmware updates (UEFI, SSDs, docks, ...)
    # through its fwupd plugin, which asks the fwupd daemon over D-Bus; fwupd
    # downloads them from the LVFS. A VM has no device fwupd can update, so
    # this checks the pieces are in place, not that an update is offered.
    have gnome-software || { echo "GNOME Software not installed"; return 2; }
    compgen -G "/usr/lib*/gnome-software/plugins-*/libgs_plugin_fwupd.so" >/dev/null ||
        compgen -G "/usr/lib/*-linux-gnu/gnome-software/plugins-*/libgs_plugin_fwupd.so" >/dev/null ||
        { echo "GNOME Software has no fwupd plugin"; return 1; }
    # Reading a property starts the daemon if D-Bus activates it on demand
    have gdbus || { echo "gdbus missing"; return 1; }
    timeout 30 gdbus call --system --dest org.freedesktop.fwupd --object-path / \
        --method org.freedesktop.DBus.Properties.Get org.freedesktop.fwupd DaemonVersion >/dev/null 2>&1 ||
        { echo "fwupd daemon does not answer on the system bus"; return 1; }
    have fwupdmgr || { echo "fwupdmgr missing"; return 1; }
    timeout 30 fwupdmgr get-remotes --json 2>/dev/null |
        awk -F'"' '$2 == "Id" { id = $4 } $2 == "Enabled" && id == "lvfs" && /true/ { found = 1 } END { exit !found }' ||
        { echo "LVFS remote not enabled in fwupd"; return 1; }
}

t_logout_not_blocked_by_shell() {
    # Starts a real logout and cancels it again. gnome-session asks every
    # registered client whether the session may end, and lists a client that
    # does not answer within a second as a "Not responding" inhibitor, so the
    # logout dialog waits out its 60 s countdown. This registers its own client
    # that refuses the logout (so the session never actually ends), reads the
    # inhibitors while the dialog is up, then presses Escape on the dialog
    # through Mutter's RemoteDesktop API, which cancels the logout.
    have gjs || { echo "gjs missing"; return 2; }
    dbus_name_available --session org.gnome.SessionManager || { echo "not in a GNOME session"; return 2; }
    dbus_name_available --session org.gnome.Mutter.RemoteDesktop || { echo "no Mutter RemoteDesktop API to cancel the logout"; return 2; }
    timeout 60 gjs "$(dirname "${BASH_SOURCE[0]}")/logout-probe.js"
}

t_video_acceleration() {
    # VA-API is available when libva and at least one VA driver are
    # installed. Only a GPU whose kernel driver has VA support (Intel, AMD,
    # NVIDIA via nouveau) must also answer vainfo: a VM without GPU access has
    # no render node, or one (virtio-gpu, ...) that VA-API cannot use.
    local lib drv node kdrv drivers=() bad=()
    for lib in /usr/lib/libva.so.2 /usr/lib64/libva.so.2 /usr/lib/*-linux-gnu/libva.so.2; do
        [[ -e $lib ]] && break
        lib=
    done
    [[ -n $lib ]] || { echo "libva not installed"; return 1; }
    for drv in /usr/lib/dri/*_drv_video.so /usr/lib64/dri/*_drv_video.so \
               /usr/lib/*-linux-gnu/dri/*_drv_video.so; do
        [[ -e $drv ]] && drivers+=("$(basename "$drv" _drv_video.so)")
    done
    ((${#drivers[@]} > 0)) || { echo "no VA-API drivers installed"; return 1; }
    for node in /dev/dri/renderD*; do
        [[ -e $node ]] || continue
        kdrv=$(basename "$(readlink -f "/sys/class/drm/${node##*/}/device/driver")")
        case $kdrv in
            i915 | xe | amdgpu | radeon | nouveau) ;;
            *) continue ;;
        esac
        have vainfo || { echo "vainfo missing"; return 1; }
        timeout 20 vainfo --display drm --device "$node" >/dev/null 2>&1 || bad+=("$node ($kdrv)")
    done
    ((${#bad[@]} == 0)) || { echo "VA-API does not work on ${bad[*]}"; return 1; }
}

t_spice_agent() {
    [[ -e /dev/virtio-ports/com.redhat.spice.0 ]] || { echo "not a SPICE VM"; return 2; }
    proc_running spice-vdagent spice-vdagentd ||
        { echo "SPICE channel present but spice-vdagent not running"; return 1; }
}

# --------------------------------------------------------------------------

echo "== Shell and command line =="
run_test "Full-featured interactive login shell"       t_interactive_shell
run_test "Privilege escalation for admin users"        t_privilege_escalation
run_test "Root password login locked"                  t_root_locked
run_test "Standard CLI tools installed"                t_cli_tools
run_test "glibc programs can run (gcompat on musl)"    t_glibc_programs
run_test "Manual pages installed"                      t_man_pages
run_test "Command-not-found handler in shell"          t_command_not_found
run_test "Default editor set"                          t_default_editor
run_test "~/.local/bin first in PATH"                  t_local_bin_first_in_path

echo
echo "== Localisation and fonts =="
run_test "UTF-8 locale active"                         t_utf8_locale
run_test "English spell-check dictionary"              t_spell_dictionary
run_test "Emoji font installed"                        t_fonts_emoji
run_test "CJK fonts installed"                         t_fonts_cjk

echo
echo "== System services =="
run_test "Network management daemon running"           t_network_manager
run_test "Network time synchronisation"                t_time_sync
run_test "hostname1/timedate1/locale1 D-Bus services"  t_settings_dbus_services
run_test "Bluetooth service enabled"                   t_bluetooth
run_test "Printing available"                          t_printing
run_test "mDNS hostname published"                      t_mdns
run_test "Firewall active"                             t_firewall
run_test "Firewall forwards container and VM traffic"  t_firewall_forwarding
run_test "IPv6 reverse path filter"                     t_ipv6_rpfilter
run_test "SSH server disabled by default"              t_sshd_disabled
run_test "Power management service"                    t_power_profiles
run_test "System log keeps enough history"             t_log_retention
run_test "Crash dump collector configured"             t_coredump_handler
run_test "Old core dumps removed"                      t_coredump_cleanup
run_test "Mandatory access control active"             t_mandatory_access_control
run_test "Compressed swap (zram or zswap)"             t_memory_compression
run_test "SSD TRIM enabled or scheduled"               t_ssd_trim
run_test "Device firmware installed"                   t_firmware

echo
echo "== Desktop integration =="
run_test "PipeWire is the sound server"                t_pipewire_audio
run_test "Audio output device available"               t_audio_sink
run_test "xdg-open available"                          t_xdg_open
run_test "Sandboxed app store (Flatpak)"               t_app_store_sandbox
run_test "Distribution packages in GNOME Software"     t_app_store_distro_packages
run_test "Firmware updates in GNOME Software"          t_app_store_firmware_updates
run_test "VA-API video acceleration available"         t_video_acceleration
run_test "SPICE guest agent (VM clipboard/resize)"     t_spice_agent
run_test "Logout not blocked by GNOME Shell"           t_logout_not_blocked_by_shell

echo
printf 'Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
exit "$FAIL"
