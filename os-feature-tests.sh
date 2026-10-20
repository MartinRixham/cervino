#!/usr/bin/env bash

set -u

PASS=0
FAIL=0
SKIP=0

if [[ -t 1 ]]; then
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
    if have flatpak && [[ -n $(flatpak remotes --columns=name 2>/dev/null) ]]; then
        return 0
    fi
    have snap && proc_running snapd && return 0
    echo "no Flatpak remote configured and no snapd"
    return 1
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
    local code
    code=$(cat <<'EOF'
const {Gio, GLib} = imports.gi;
const System = imports.system;
const bus = Gio.DBus.session;
const SM = 'org.gnome.SessionManager';
const RD = 'org.gnome.Mutter.RemoteDesktop';
const KEY_Escape = 0xff1b;

function call(dest, path, iface, method, args = null, ret = null) {
    const reply = bus.call_sync(dest, path, iface, method, args,
        ret ? new GLib.VariantType(ret) : null, Gio.DBusCallFlags.NONE, 10000, null);
    return reply.deepUnpack();
}

function spin(ms, until = () => false) {
    const ctx = GLib.MainContext.default();
    const end = GLib.get_monotonic_time() + ms * 1000;
    while (!until() && GLib.get_monotonic_time() < end) {
        if (!ctx.iteration(false))
            GLib.usleep(10000);
    }
    return until();
}

let rdSession;
try {
    [rdSession] = call(RD, '/org/gnome/Mutter/RemoteDesktop', RD, 'CreateSession', null, '(o)');
    call(RD, rdSession, `${RD}.Session`, 'Start');
} catch (e) {
    print(`cannot start a RemoteDesktop session to cancel the logout: ${e.message}`);
    System.exit(2);
}

const [client] = call(SM, '/org/gnome/SessionManager', SM, 'RegisterClient',
    new GLib.Variant('(ss)', ['os-feature-tests', '']), '(o)');
let queried = false, canceled = false, ended = false;
bus.signal_subscribe(null, `${SM}.ClientPrivate`, null, client, null, Gio.DBusSignalFlags.NONE,
    (_c, _sender, _path, _iface, signal) => {
        if (signal === 'QueryEndSession') {
            queried = true;
            call(SM, client, `${SM}.ClientPrivate`, 'EndSessionResponse',
                new GLib.Variant('(bs)', [false, 'os-feature-tests: logout probe']));
        } else if (signal === 'CancelEndSession') {
            canceled = true;
        } else if (signal === 'EndSession') {
            ended = true;
        }
    });

function cleanup() {
    try {
        call(SM, '/org/gnome/SessionManager', SM, 'UnregisterClient', new GLib.Variant('(o)', [client]));
    } catch {}
    try {
        call(RD, rdSession, `${RD}.Session`, 'Stop');
    } catch {}
}

try {
    call(SM, '/org/gnome/SessionManager', SM, 'Logout', new GLib.Variant('(u)', [0]));
} catch (e) {
    print(`cannot start a logout: ${e.message}`);
    cleanup();
    System.exit(1);
}
if (!spin(5000, () => queried)) {
    print('gnome-session did not query clients on logout');
    cleanup();
    System.exit(1);
}
// Unanswered queries turn into inhibitors after 1 s; then the dialog opens
spin(3000);

const blockers = [];
const [inhibitors] = call(SM, '/org/gnome/SessionManager', SM, 'GetInhibitors', null, '(ao)');
for (const path of inhibitors) {
    const iface = `${SM}.Inhibitor`;
    try {
        const [appId] = call(SM, path, iface, 'GetAppId', null, '(s)');
        const [reason] = call(SM, path, iface, 'GetReason', null, '(s)');
        const [flags] = call(SM, path, iface, 'GetFlags', null, '(u)');
        if (flags & 1 && /gnome-shell|org\.gnome\.Shell/i.test(appId))
            blockers.push(`${appId} (${reason})`);
    } catch {}
}

for (let i = 0; i < 5 && !canceled && !ended; i++) {
    for (const state of [true, false])
        call(RD, rdSession, `${RD}.Session`, 'NotifyKeyboardKeysym', new GLib.Variant('(ub)', [KEY_Escape, state]));
    spin(2000, () => canceled || ended);
}
cleanup();

if (!canceled) {
    print('could not cancel the logout dialog: the session may log out');
    System.exit(1);
}
if (blockers.length > 0) {
    print(`logout blocked by GNOME Shell: ${blockers.join(', ')}`);
    System.exit(1);
}
EOF
)
    timeout 60 gjs -c "$code"
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
run_test "Standard CLI tools installed"                t_cli_tools
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
run_test "Power management service"                    t_power_profiles
run_test "Crash dump collector configured"             t_coredump_handler
run_test "Mandatory access control active"             t_mandatory_access_control
run_test "Compressed swap (zram or zswap)"             t_memory_compression
run_test "Device firmware installed"                   t_firmware

echo
echo "== Desktop integration =="
run_test "PipeWire is the sound server"                t_pipewire_audio
run_test "Audio output device available"               t_audio_sink
run_test "xdg-open available"                          t_xdg_open
run_test "Sandboxed app store (Flatpak or Snap)"       t_app_store_sandbox
run_test "SPICE guest agent (VM clipboard/resize)"     t_spice_agent
run_test "Logout not blocked by GNOME Shell"           t_logout_not_blocked_by_shell

echo
printf 'Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
exit "$FAIL"
