#!/bin/sh
# Runs as root on the installed system: checks that the live session was
# left behind, logs the user created during the install in to GNOME, then
# runs os-feature-tests.sh as that user with the session's environment
# (taken from gnome-shell), as if from a terminal in the desktop, and checks
# that the session uses the keyboard layout chosen in setup-alpine. Last, it
# logs the user out and checks that GDM's login screen comes back. Exits with
# the number of failed tests.

set -eu

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
	echo "live session left on the installed system:" $leftover >&2
	exit 1
fi

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

failed=0
session_run "$user" "$pid" bash "$(realpath "$dir")/os-feature-tests.sh" < /dev/null || failed=$?

# The keyboard layout chosen in setup-alpine (KEYMAPOPTS in install.sh) has
# to be the user's only input source in GNOME.
keymap=gb
t_keyboard_layout() {
	sources=$(session_run "$user" "$pid" gsettings get org.gnome.desktop.input-sources sources < /dev/null) ||
		sources=
	if [ "$sources" != "[('xkb', '$keymap')]" ]; then
		echo "GNOME's input sources are ${sources:-unreadable}, not the layout chosen in setup-alpine ($keymap) alone" >&2
		echo "[FAIL] GNOME uses the keyboard layout chosen in setup-alpine"
		return 1
	fi
	echo "[PASS] GNOME uses the keyboard layout chosen in setup-alpine"
}

t_keyboard_layout || failed=$((failed + 1))

# Logging out has to end the user's session and bring back GDM's login
# screen: its own gnome-shell, running as gdm, in seat0's active session and
# answering on its D-Bus. This runs last, as it ends the session.
logout_fail() {
	echo "logout: $*" >&2
	echo "--- processes of $user and gdm:"
	ps -o pid,user,args 2>/dev/null | awk -v u="$user" '$2 == u || $2 == "gdm"'
	echo "--- /var/log/messages since the logout:"
	tail -n +"$((log_lines + 1))" /var/log/messages 2>/dev/null | tail -n 100
	echo "[FAIL] Logging out returns to the GDM login screen"
	return 1
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
		[ "$i" -le 90 ] || { logout_fail "the session of $user did not end within 90 s"; return 1; }
		sleep 1
	done

	i=0
	until greeter=$(proc_of gnome-shell "$gdm_uid") && [ "$greeter" != "$old_greeter" ]; do
		# GDM only logs in automatically again when it takes the session's
		# end for a failure ("Session never registered, failing").
		user_proc gnome-shell > /dev/null &&
			{ logout_fail "GDM logged $user straight back in instead of showing the login screen"; return 1; }
		i=$((i + 1))
		[ "$i" -le 90 ] || { logout_fail "no login screen within 90 s of the session ending"; return 1; }
		sleep 1
	done
	sleep 15
	[ "$(proc_of gnome-shell "$gdm_uid")" = "$greeter" ] ||
		{ logout_fail "the login screen's gnome-shell ($greeter) did not stay up"; return 1; }

	session_run gdm "$greeter" timeout 30 gdbus call --session --timeout 10 \
		--dest org.gnome.Shell --object-path /org/gnome/Shell \
		--method org.freedesktop.DBus.Peer.Ping > /dev/null < /dev/null ||
		{ logout_fail "the login screen's gnome-shell does not answer on D-Bus"; return 1; }

	# The login screen's session has to register with GDM too (through the
	# gnome-shell-compat helper), or logging in through it fails: GDM takes
	# the end of the login screen for a failure and keeps restarting it,
	# taking the seat from the new session, whose screen then freezes.
	proc_of gnome-shell-com "$gdm_uid" > /dev/null ||
		{ logout_fail "the login screen runs no gnome-shell-compat helper to register it with GDM"; return 1; }

	# The login screen has to be seat0's active session, which elogind gives
	# the display to, or the screen stays frozen on the old session.
	active=$(loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null) || active=
	[ -n "$active" ] && [ "$(loginctl show-session "$active" -p Name --value 2>/dev/null)" = gdm ] ||
		{ loginctl list-sessions --no-legend 2>&1; logout_fail "the login screen is not the active session on seat0 (active: ${active:-none})"; return 1; }
	echo "[PASS] Logging out returns to the GDM login screen"
}

t_logout_to_greeter || failed=$((failed + 1))
exit "$failed"
