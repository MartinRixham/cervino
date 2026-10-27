#!/bin/sh
# ci/guest/test.sh MODE: runs as root on the installed system, an atomic or
# a sys install (MODE, setup-disk's -m): checks that the live session was
# left behind and that packages.sh added cervino-gstreamer, logs the user
# created during the install in to GNOME, then
# runs test/features.sh as that user with the session's environment
# (taken from gnome-shell), as if from a terminal in the desktop, and
# test/apparmor.sh as root. Then it runs a runaway app in the session and
# checks that earlyoom kills it (and nothing else) before the kernel's OOM
# killer would, logs the user out and checks that GDM's login screen comes
# back, and last that the kernel log has no AppArmor denials. Exits with
# the number of failed tests.

set -eu

mode=${1:?usage: $0 atomic|sys}
dir=$(dirname "$0")/../..
user=tester
uid=$(id -u "$user")

leftover=$(awk -F: '$5 == "Live User" { print "user " $1 }' /etc/passwd)
for f in /etc/init.d/live-user /etc/runlevels/*/live-user /etc/doas.d/90-live-user.conf \
	/etc/polkit-1/rules.d/49-live-user.rules /home/*; do
	[ -e "$f" ] || [ -L "$f" ] || continue
	[ "$f" = /home/$user ] || leftover="$leftover $f"
done
grep -q '^AutomaticLogin' /etc/gdm/custom.conf && leftover="$leftover GDM autologin"
if [ -n "$leftover" ]; then
	# shellcheck disable=SC2086
	echo "live session left on the installed system:" $leftover >&2
	exit 1
fi

# The packages the image leaves out, which packages.sh added in the boot
# before (on an atomic install, to the version this one started with).
apk info -e cervino-gstreamer > /dev/null ||
	{ echo "cervino-gstreamer is not installed" >&2; exit 1; }

cat > /etc/gdm/custom.conf <<EOF
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=$user
EOF
rc-service gdm restart

# pgrep differs between busybox and procps (which setup/ installs), so look
# through /proc directly.
# proc_of NAME UID: prints the pid of a process called NAME owned by UID.
proc_of() {
	for d in /proc/[0-9]*; do
		[ "$(cat "$d"/comm 2>/dev/null)" = "$1" ] && [ "$(stat -c %u "$d" 2>/dev/null)" = "$2" ] &&
			{ echo "${d#/proc/}"; return 0; }
	done
	return 1
}
user_proc() { proc_of "$1" "$uid"; }

# session_run USER PID COMMAND [ARGS...]: runs a command as USER with the
# environment of process PID, as if from a terminal in that session.
session_run() {
	run_as=$1 env_pid=$2
	shift 2
	# busybox su permutes its arguments like GNU getopt, so "--" keeps it
	# from taking the command's options as its own.
	su -s /bin/bash -c '
		while IFS= read -r -d "" kv; do export "$kv"; done < /proc/$1/environ
		cd 2>/dev/null
		shift
		exec "$@"' -- "$run_as" bash "$env_pid" "$@"
}

i=0
until pid=$(user_proc gnome-shell); do
	i=$((i + 1))
	[ "$i" -le 300 ] || { echo "no GNOME session for $user" >&2; exit 1; }
	sleep 1
done
# Let the session's autostarted services (PipeWire and so on) come up.
i=0
until user_proc pipewire-pulse >/dev/null || [ "$i" -ge 60 ]; do
	i=$((i + 1))
	sleep 1
done
sleep 15

# Results are printed as test/features.sh prints its own: [PASS] or
# [FAIL] and the reason for a failure indented below it, in colour on a
# terminal, then the counts of all the tests together.
if [ -t 1 ]; then
	C_PASS=$(printf '\033[32m') C_FAIL=$(printf '\033[31m') C_OFF=$(printf '\033[0m')
	color=FORCE_COLOR=1
else
	C_PASS= C_FAIL= C_OFF= color=
fi
passed=0 failed=0 skipped=0
pass() {
	passed=$((passed + 1))
	printf '%s[PASS]%s %s\n' "$C_PASS" "$C_OFF" "$1"
}
# fail DESCRIPTION REASON
fail() {
	failed=$((failed + 1))
	printf '%s[FAIL]%s %s\n' "$C_FAIL" "$C_OFF" "$1"
	printf '       %s\n' "$2"
}

# run_suite COMMAND [ARGS...]: runs a test script that prints its results as
# test/features.sh does and adds its counts to the totals. Such a script
# ends with "Passed: n  Failed: n  Skipped: n" and exits with the number of
# failures. Its output goes through tee, so callers tell it to colour it.
run_suite() {
	out=$(mktemp)
	{
		rc=0
		"$@" < /dev/null || rc=$?
		echo "$rc" > "$out".rc
	} | tee "$out"
	counts=$(sed -n 's/^Passed: \([0-9]*\)  Failed: \([0-9]*\)  Skipped: \([0-9]*\)$/\1 \2 \3/p' \
		"$out" | tail -n 1)
	rc=$(cat "$out".rc)
	rm -f "$out" "$out".rc
	# shellcheck disable=SC2086
	set -- ${counts:-0 0 0}
	[ "$rc" -le "$2" ] || set -- "$1" "$rc" "$3"
	passed=$((passed + $1)) failed=$((failed + $2)) skipped=$((skipped + $3))
}

run_suite session_run "$user" "$pid" env $color bash "$(realpath "$dir")/test/features.sh"
echo
run_suite env $color bash "$(realpath "$dir")/test/apparmor.sh"

echo
echo "== Installed system =="

# cervino-desktop's "Update Alpine Linux" launcher has to show in the app
# grid of an installed system (the live image hides it), as GLib, which
# GNOME Shell lists apps through, sees it in the user's session, and what it
# runs has to be there.
t_update_launcher() {
	desc="Update Alpine Linux in the app grid"
	exe=$(session_run "$user" "$pid" gjs -c "
		const a = imports.gi.Gio.DesktopAppInfo.new('update-alpine.desktop');
		if (!a || !a.should_show())
			imports.system.exit(1);
		print(a.get_executable());" < /dev/null 2>/dev/null) ||
		{ fail "$desc" "update-alpine.desktop is missing or hidden"; return 1; }
	for c in "$exe" doas /usr/sbin/update-alpine; do
		command -v "$c" > /dev/null || {
			fail "$desc" "the launcher needs $c, which is not installed"
			return 1
		}
	done
	pass "$desc"
}

t_update_launcher || true

# An atomic install's system files are read-only, while /etc, /var, /home
# and root's home can be written to. A sys install is an ordinary system.
t_read_only_system() {
	if [ "$mode" = sys ]; then
		desc="System writable (a sys install)"
		[ ! -e /etc/kernel/cmdline ] &&
			[ "$(btrfs property get -ts / ro 2>/dev/null)" != ro=true ] ||
			{ fail "$desc" "the sys install is an atomic one"; return 1; }
		touch /usr/.ci-write 2>/dev/null && rm -f /usr/.ci-write ||
			{ fail "$desc" "root cannot write to /usr"; return 1; }
		pass "$desc"
		return 0
	fi
	desc="System read-only, /etc, /var, /home and /root writable"
	[ "$(btrfs property get -ts / ro 2>/dev/null)" = ro=true ] ||
		{ fail "$desc" "/ is not a read-only btrfs subvolume"; return 1; }
	if touch /usr/.ci-write 2>/dev/null; then
		rm -f /usr/.ci-write
		fail "$desc" "root can write to /usr"
		return 1
	fi
	for d in /etc /var /home /root; do
		touch "$d"/.ci-write 2>/dev/null && rm -f "$d"/.ci-write ||
			{ fail "$desc" "root cannot write to $d"; return 1; }
	done
	pass "$desc"
}

t_read_only_system || true

# A runaway app in the session has to be killed by earlyoom, before the
# kernel's OOM killer acts and without taking GNOME Shell with it. It runs
# before the logout check, which needs the session, and its kill is covered
# by the AppArmor denial check at the end.
t_memory_pressure() {
	desc="Runaway app killed by earlyoom, session kept"
	hog=$(realpath "$dir")/ci/guest/memory-hog.js
	kernel_kills=$(dmesg | grep -c 'Killed process') || true
	log_lines=$(wc -l < /var/log/messages 2>/dev/null) || log_lines=0

	session_run "$user" "$pid" gjs "$hog" < /dev/null > /dev/null 2>&1 &
	job=$!
	hog_pid=
	i=0
	while kill -0 "$job" 2>/dev/null; do
		if [ -z "$hog_pid" ]; then
			for d in /proc/[0-9]*; do
				[ "$(stat -c %u "$d" 2>/dev/null)" = "$uid" ] &&
					tr '\0' ' ' 2>/dev/null < "$d"/cmdline | grep -qF "$hog" &&
					{ hog_pid=${d#/proc/}; break; }
			done
		fi
		i=$((i + 1))
		if [ "$i" -gt 300 ]; then
			kill "$job" ${hog_pid:+"$hog_pid"} 2>/dev/null
			fail "$desc" "the app still runs after 300 s: nothing killed it"
			return 1
		fi
		sleep 1
	done
	wait "$job" 2>/dev/null || true
	# Let the session swap back in before the next checks.
	sleep 10

	log=$(tail -n +"$((log_lines + 1))" /var/log/messages 2>/dev/null)
	if [ "$(dmesg | grep -c 'Killed process')" -gt "${kernel_kills:-0}" ]; then
		fail "$desc" \
			"the kernel's OOM killer acted first: $(dmesg | grep 'Killed process' | tail -n 3)"
		return 1
	fi
	if [ -z "$hog_pid" ] ||
		! printf '%s\n' "$log" | grep -q "earlyoom.*sending SIG[A-Z]* to process $hog_pid "; then
		why=$(printf '%s\n' "$log" | grep earlyoom | tail -n 5)
		fail "$desc" "earlyoom did not kill the app (pid ${hog_pid:-not found}); its log: $why"
		return 1
	fi
	victims=$(printf '%s\n' "$log" |
		sed -n 's/.*earlyoom.*sending SIG[A-Z]* to process \([0-9]*\) .*/\1/p' |
		grep -vx "$hog_pid" | sort -u | tr '\n' ' ')
	[ -z "$victims" ] || {
		why=$(printf '%s\n' "$log" | grep 'earlyoom.*sending SIG' |
			grep -v "process $hog_pid ") || :
		fail "$desc" "earlyoom killed other processes too: $why"
		return 1
	}
	[ -e /proc/"$pid" ] || { fail "$desc" "GNOME Shell ($pid) did not survive"; return 1; }
	pass "$desc"
}

t_memory_pressure || true

# Logging out has to end the user's session and bring back GDM's login
# screen: its own gnome-shell, running as gdm, in seat0's active session and
# answering on its D-Bus. This runs last, as it ends the session.
logout_fail() {
	fail "Logging out returns to the GDM login screen" "$*"
	echo "--- processes of $user and gdm:"
	ps -o pid,user,args 2>/dev/null | awk -v u="$user" '$2 == u || $2 == "gdm"'
	echo "--- /var/log/messages since the logout:"
	tail -n +"$((log_lines + 1))" /var/log/messages 2>/dev/null | tail -n 100
}

t_logout_to_greeter() {
	gdm_uid=$(id -u gdm)
	old_greeter=$(proc_of gnome-shell "$gdm_uid") || old_greeter=
	session=$(user_proc gnome-session-binary) || session=
	log_lines=$(wc -l < /var/log/messages 2>/dev/null) || log_lines=0

	# Mode 1: no confirmation dialog (gnome-session still queries its clients)
	session_run "$user" "$pid" timeout 30 gdbus call --session \
		--dest org.gnome.SessionManager --object-path /org/gnome/SessionManager \
		--method org.gnome.SessionManager.Logout 1 > /dev/null < /dev/null ||
		{ logout_fail "cannot ask gnome-session to log out"; return 1; }

	i=0
	while [ -e /proc/"$pid" ] || { [ -n "$session" ] && [ -e /proc/"$session" ]; }; do
		i=$((i + 1))
		[ "$i" -le 90 ] || {
			logout_fail "the session of $user did not end within 90 s"
			return 1
		}
		sleep 1
	done

	i=0
	until greeter=$(proc_of gnome-shell "$gdm_uid") && [ "$greeter" != "$old_greeter" ]; do
		# GDM only logs in automatically again when it takes the session's
		# end for a failure ("Session never registered, failing").
		user_proc gnome-shell > /dev/null && {
			logout_fail "GDM logged $user straight back in instead of showing the login screen"
			return 1
		}
		i=$((i + 1))
		[ "$i" -le 90 ] || {
			logout_fail "no login screen within 90 s of the session ending"
			return 1
		}
		sleep 1
	done
	sleep 15
	[ "$(proc_of gnome-shell "$gdm_uid")" = "$greeter" ] || {
		logout_fail "the login screen's gnome-shell ($greeter) did not stay up"
		return 1
	}

	session_run gdm "$greeter" timeout 30 gdbus call --session --timeout 10 \
		--dest org.gnome.Shell --object-path /org/gnome/Shell \
		--method org.freedesktop.DBus.Peer.Ping > /dev/null < /dev/null ||
		{ logout_fail "the login screen's gnome-shell does not answer on D-Bus"; return 1; }

	# The login screen's session has to register with GDM too (through the
	# gnome-shell-compat helper), or logging in through it fails: GDM takes
	# the end of the login screen for a failure and keeps restarting it,
	# taking the seat from the new session, whose screen then freezes.
	proc_of gnome-shell-com "$gdm_uid" > /dev/null || {
		logout_fail "the login screen runs no gnome-shell-compat helper to register it with GDM"
		return 1
	}

	# The login screen has to be seat0's active session, which elogind gives
	# the display to, or the screen stays frozen on the old session.
	active=$(loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null) || active=
	[ -n "$active" ] &&
		[ "$(loginctl show-session "$active" -p Name --value 2>/dev/null)" = gdm ] || {
		logout_fail "the login screen is not the active session on seat0 (active: ${active:-none})"
		loginctl list-sessions --no-legend 2>&1
		return 1
	}
	pass "Logging out returns to the GDM login screen"
}

t_logout_to_greeter || true

# Checked last, so that it covers everything the tests did.
if denials=$("$dir"/ci/guest/apparmor-denials.sh); then
	pass "No AppArmor denials"
else
	fail "No AppArmor denials" "$(printf '%s\n' "$denials" | sed '2,$s/^/       /')"
fi

echo
printf 'All tests: Passed: %d  Failed: %d  Skipped: %d\n' "$passed" "$failed" "$skipped"
exit "$failed"
