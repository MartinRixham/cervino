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

# run_test DESCRIPTION FUNCTION [ARGS...]
run_test() {
	local desc=$1 reason rc
	shift
	reason=$("$@" 2>/dev/null)
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

# Runs a command as root without asking for a password: directly when root,
# else through doas or sudo if they let the user in without one.
as_root() {
	((EUID == 0)) && { "$@"; return; }
	local tool
	tool=$(first_have doas sudo) || return 1
	"$tool" -n "$@"
}

# pids_of COMM [USER]: prints the pids of the processes called COMM owned by
# USER, or by any system user (UID below 1000) when no USER is given.
pids_of() {
	local comm=$1 uid=${2:+$(id -u "$2" 2>/dev/null)} f c u
	for f in /proc/[0-9]*/comm; do
		read -r c <"$f" 2>/dev/null || continue
		[[ $c == "${comm:0:15}" ]] || continue
		u=$(stat -c %u "${f%/comm}" 2>/dev/null) || continue
		if [[ -n $uid ]]; then
			((u == uid)) || continue
		else
			((u < 1000)) || continue
		fi
		f=${f%/comm}
		echo "${f#/proc/}"
	done
}

# The AppArmor label of a process: "unconfined", or "PROFILE (MODE)"
label_of() {
	cat "/proc/$1/attr/apparmor/current" 2>/dev/null || cat "/proc/$1/attr/current" 2>/dev/null
}

# confined PID...: fails, saying why, unless every process runs under a
# profile in enforce (or kill) mode.
confined() {
	# Processes with the same name and label are reported together:
	# "getty (3131, 3132) runs unconfined"
	local pid label why key keys=() reason=
	local -A pids_for=()
	for pid; do
		label=$(label_of "$pid") || continue
		case $label in
			*' (enforce)' | *' (kill)') continue ;;
			unconfined) why="runs unconfined" ;;
			*' (unconfined)') why="runs under ${label% (*}, a profile in unconfined mode" ;;
			*' ('*')') why="runs under ${label% (*} in ${label##* (} mode" ;;
			*) why="has AppArmor label '$label'" ;;
		esac
		key="$(cat "/proc/$pid/comm" 2>/dev/null)|$why"
		[[ -n ${pids_for[$key]:-} ]] || keys+=("$key")
		pids_for[$key]+="${pids_for[$key]:+, }$pid"
	done
	((${#keys[@]} == 0)) && return 0
	for key in "${keys[@]}"; do
		reason+="${reason:+; }${key%%|*} (${pids_for[$key]}) ${key#*|}"
	done
	echo "$reason"
	return 1
}

# t_daemon COMM [--user USER] [--dbus NAME] [--optional]: COMM's processes
# are confined. --dbus starts it through D-Bus when it is not running (it is
# skipped when that service is not installed); --optional skips it when it
# is not running instead of failing.
t_daemon() {
	local comm=$1 user= bus= optional=0 pids i
	shift
	while (($#)); do
		case $1 in
			--user) user=$2; shift ;;
			--dbus) bus=$2; shift ;;
			--optional) optional=1 ;;
		esac
		shift
	done
	[[ $(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) == Y ]] ||
		{ echo "AppArmor is not enabled"; return 1; }
	pids=$(pids_of "$comm" ${user:+"$user"})
	if [[ -z $pids && -n $bus ]]; then
		[[ -e /usr/share/dbus-1/system-services/$bus.service ]] ||
			{ echo "no D-Bus service $bus (not installed)"; return 2; }
		have gdbus || { echo "gdbus missing, cannot start $bus"; return 1; }
		timeout 30 gdbus call --system --dest org.freedesktop.DBus \
			--object-path /org/freedesktop/DBus \
			--method org.freedesktop.DBus.StartServiceByName "$bus" 0 >/dev/null 2>&1 ||
			{ echo "D-Bus cannot start $bus"; return 1; }
		for ((i = 0; i < 10; i++)); do
			pids=$(pids_of "$comm" ${user:+"$user"})
			[[ -n $pids ]] && break
			sleep 1
		done
		[[ -n $pids ]] || {
			echo "D-Bus started $bus but no $comm process is running"
			return 1
		}
	fi
	if [[ -z $pids ]]; then
		((optional)) && { echo "$comm is not running"; return 2; }
		echo "$comm is not running"
		return 1
	fi
	# shellcheck disable=SC2086
	confined $pids
}

# Seeing which process owns a socket needs root,
# so the test is skipped when the user
# cannot get it without a password.
t_network_listeners() {
	local out pids=() pid u
	if have ss; then
		out=$(as_root ss -Htuln -p 2>/dev/null) || {
			echo "cannot see the sockets' processes without root"
			return 2
		}
		out=$(grep -o 'pid=[0-9]*' <<<"$out" | cut -d= -f2)
	elif have netstat; then
		# The last column is PID/Program name
		out=$(as_root netstat -tulnp 2>/dev/null) || {
			echo "cannot see the sockets' processes without root"
			return 2
		}
		out=$(grep -Eo '[0-9]+/[^ ]*$' <<<"$out" | cut -d/ -f1)
	else
		echo "no ss or netstat"
		return 2
	fi
	while read -r pid; do
		u=$(stat -c %u "/proc/$pid" 2>/dev/null) || continue
		((u < 1000)) && pids+=("$pid")
	done < <(sort -un <<<"$out")
	((${#pids[@]} > 0)) || { echo "no system process listens on the network"; return 2; }
	confined "${pids[@]}"
}

# sshd is installed but not enabled. ssh_setup starts it (ssh_cleanup stops
# it again and deletes the host keys its start made) and adds a user to log
# in as with a key, so that the tests below go through a whole login: the
# listener, sshd-session and sshd-auth for each connection, and the user's
# session outside the profile. That needs root, so the tests are skipped
# without it.
SSH_USER=apparmor-sshtest
ssh_skip= ssh_error= ssh_dir= ssh_started=0 ssh_host_keys= ssh_opts=()

ssh_setup() {
	[[ -x /usr/sbin/sshd ]] && have ssh || { ssh_skip="OpenSSH is not installed"; return; }
	((EUID == 0)) || {
		ssh_skip="starting sshd and adding a user to log in as needs root"
		return
	}
	have useradd || { ssh_skip="no useradd to add a user to log in as"; return; }
	ssh_dir=$(mktemp -d) || { ssh_error="mktemp failed"; return; }
	ssh_opts=(-i "$ssh_dir/key" -o IdentitiesOnly=yes -o BatchMode=yes
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
	ssh_host_keys=$(ls /etc/ssh/ssh_host_* 2>/dev/null)
	# In a session of their own (setsid) and with no terminal on stdin: the
	# init script runs sshd (sshd -G, sshd -t, the daemon), and AppArmor
	# denies sshd's profile the inherited terminal, the controlling one too
	if ! setsid -w rc-service sshd status >/dev/null 2>&1 </dev/null; then
		ssh_started=1
		setsid -w rc-service sshd start >/dev/null 2>&1 </dev/null || {
			ssh_error="rc-service sshd start failed"
			return
		}
	fi
	id "$SSH_USER" >/dev/null 2>&1 && userdel -r "$SSH_USER" >/dev/null 2>&1
	# '*': no password, but not locked ('!'), which sshd refuses keys for too
	useradd -m -p '*' -s /bin/sh "$SSH_USER" >/dev/null 2>&1 ||
		{ ssh_error="useradd $SSH_USER failed"; return; }
	ssh-keygen -q -t ed25519 -N '' -C '' -f "$ssh_dir/key" >/dev/null 2>&1 ||
		{ ssh_error="ssh-keygen failed"; return; }
	local home
	home=$(getent passwd "$SSH_USER" | cut -d: -f6)
	install -d -m 0700 -o "$SSH_USER" -g "$SSH_USER" "$home/.ssh" &&
		install -m 0600 -o "$SSH_USER" -g "$SSH_USER" "$ssh_dir/key.pub" \
			"$home/.ssh/authorized_keys" ||
		{ ssh_error="cannot add the key to $home/.ssh/authorized_keys"; return; }
}

ssh_cleanup() {
	local f
	((EUID == 0)) || return 0
	if id "$SSH_USER" >/dev/null 2>&1; then
		pkill -u "$SSH_USER" 2>/dev/null
		sleep 1
		userdel -r "$SSH_USER" >/dev/null 2>&1
	fi
	if ((ssh_started)); then
		setsid -w rc-service sshd stop >/dev/null 2>&1 </dev/null
		for f in /etc/ssh/ssh_host_*; do
			[[ -e $f ]] && ! grep -qxF "$f" <<<"$ssh_host_keys" && rm -f "$f"
		done
	fi
	[[ -n $ssh_dir ]] && rm -rf "$ssh_dir"
}

ssh_ready() {
	[[ -n $ssh_skip ]] && { echo "$ssh_skip"; return 2; }
	[[ -n $ssh_error ]] && { echo "$ssh_error"; return 1; }
	return 0
}

# The listener
t_sshd() {
	ssh_ready || return
	t_daemon sshd
}

# The sshd-session and sshd-auth that handle a connection before it has
# authenticated: a client that sends its version and then waits.
t_sshd_preauth() {
	ssh_ready || return
	local banner pids i
	exec 3<>/dev/tcp/127.0.0.1/22 || { echo "cannot connect to port 22"; return 1; }
	read -r -t 10 banner <&3
	[[ $banner == SSH-* ]] || { exec 3<&-; echo "no SSH version from port 22"; return 1; }
	printf 'SSH-2.0-apparmor-test\r\n' >&3
	for ((i = 0; i < 10; i++)); do
		pids=$(pids_of sshd-auth)
		[[ -n $pids ]] && break
		sleep 1
	done
	[[ -n $pids ]] || { exec 3<&-; echo "no sshd-auth process for the connection"; return 1; }
	pids+=" $(pids_of sshd-session)"
	# shellcheck disable=SC2086
	confined $pids
	i=$?
	exec 3<&-
	return "$i"
}

# A login with a key and a terminal: the sshd-session processes (root's,
# and the user's, which the shell is a child of) are confined; the shell
# is not.
t_sshd_login() {
	ssh_ready || return
	local out=$ssh_dir/login pid pids parent shell i rc
	# shellcheck disable=SC2016
	timeout 30 ssh "${ssh_opts[@]}" -tt "$SSH_USER@127.0.0.1" \
		'cat /proc/$PPID/attr/apparmor/current 2>/dev/null || cat /proc/$PPID/attr/current
			cat /proc/$$/attr/apparmor/current 2>/dev/null || cat /proc/$$/attr/current
			sleep 5' >"$out" 2>&1 </dev/null &
	pid=$!
	for ((i = 0; i < 10; i++)); do
		pids=$(pids_of sshd-session "$SSH_USER")
		[[ -n $pids ]] && break
		sleep 1
	done
	pids+=" $(pids_of sshd-session)"
	if [[ -n ${pids// /} ]]; then
		# shellcheck disable=SC2086
		confined $pids
		rc=$?
	else
		echo "no sshd-session process for the login"
		rc=1
	fi
	wait "$pid" || { echo "ssh login failed: $(tr -d '\r' <"$out" | head -n 3)"; return 1; }
	((rc == 0)) || return "$rc"
	{ read -r parent; read -r shell; } < <(tr -d '\r' <"$out")
	[[ $parent == 'sshd (enforce)' ]] || {
		echo "the shell's parent runs as '$parent', not under sshd"
		return 1
	}
	[[ $shell == unconfined ]] || {
		echo "the login shell runs as '$shell', not unconfined"
		return 1
	}
}

# sftp goes through the external sftp-server, outside sshd's profile.
t_sftp() {
	ssh_ready || return
	have sftp || { echo "no sftp client"; return 2; }
	local out
	out=$(timeout 30 sftp "${ssh_opts[@]}" -b - "$SSH_USER@127.0.0.1" <<<'ls /' 2>&1) ||
		{ echo "sftp failed: $(head -n 3 <<<"$out")"; return 1; }
}

# --------------------------------------------------------------------------

echo "== Core system  =="
run_test "udev device manager (udev_t)"                       t_daemon udevd
run_test "D-Bus system bus (system_dbusd_t)"                  t_daemon dbus-daemon --user messagebus
run_test "System logger (syslogd_t)"                          t_daemon syslogd
run_test "cron (crond_t)"                                     t_daemon crond
run_test "Console login prompts (getty_t)"                    t_daemon getty
run_test "elogind (systemd_logind_t)"                         t_daemon elogind-daemon
run_test "earlyoom OOM killer (systemd_oomd_t)"               t_daemon earlyoom --user nobody
run_test "polkit (policykit_t)"                               t_daemon polkitd --dbus org.freedesktop.PolicyKit1
run_test "Hostname/time/locale services (systemd_hostnamed_t)" t_daemon openrc-settingsd --dbus org.freedesktop.hostname1

echo
echo "== Network =="
run_test "NetworkManager (NetworkManager_t)"                  t_daemon NetworkManager
run_test "wpa_supplicant (NetworkManager_t)"                  t_daemon wpa_supplicant --dbus fi.w1.wpa_supplicant1
run_test "dnsmasq DNS server (dnsmasq_t)"                     t_daemon dnsmasq
run_test "chrony time sync (chronyd_t)"                       t_daemon chronyd
run_test "Avahi mDNS (avahi_t)"                               t_daemon avahi-daemon
run_test "Wi-Fi region service (ifconfig_t, as iw runs)"      t_daemon inotifyd
run_test "Every system process on a network socket confined"  t_network_listeners

echo
echo "== Desktop services =="
run_test "GDM display manager (xdm_t)"                        t_daemon gdm
run_test "GDM session worker (xdm_t)"                         t_daemon gdm-session-worker
run_test "AccountsService (accountsd_t)"                      t_daemon accounts-daemon --dbus org.freedesktop.Accounts
run_test "UPower (devicekit_power_t)"                         t_daemon upowerd --dbus org.freedesktop.UPower
run_test "UDisks (devicekit_disk_t)"                          t_daemon udisksd --dbus org.freedesktop.UDisks2
run_test "power-profiles-daemon (powerprofiles_t)"            t_daemon power-profiles-daemon --dbus net.hadess.PowerProfiles
run_test "RealtimeKit (rtkit_daemon_t)"                       t_daemon rtkit-daemon --dbus org.freedesktop.RealtimeKit1
run_test "colord (colord_t)"                                  t_daemon colord --dbus org.freedesktop.ColorManager
run_test "GeoClue location service (geoclue_t)"               t_daemon geoclue --dbus org.freedesktop.GeoClue2
run_test "Bluetooth (bluetooth_t)"                            t_daemon bluetoothd --dbus org.bluez
run_test "Thunderbolt device manager (boltd_t)"               t_daemon boltd --dbus org.freedesktop.bolt
run_test "Firmware updates (fwupd_t)"                         t_daemon fwupd --dbus org.freedesktop.fwupd
run_test "CUPS print scheduler (cupsd_t)"                     t_daemon cupsd
run_test "SPICE guest agent daemon (vdagent_t)"               t_daemon spice-vdagentd --optional

echo
echo "== Remote login (sshd, started for the tests) =="
ssh_setup
run_test "OpenSSH server (sshd_t)"                            t_sshd
run_test "SSH connection before login (sshd_net_t)"           t_sshd_preauth
run_test "SSH login session (sshd_t)"                         t_sshd_login
run_test "sftp"                                               t_sftp
ssh_cleanup

echo
printf 'Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
exit "$FAIL"
