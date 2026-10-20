#!/bin/sh
# Runs as root on the installed system: checks that the live session was
# left behind, logs the user created during the install in to GNOME, then
# runs os-feature-tests.sh as that user with the session's environment
# (taken from gnome-shell), as if from a terminal in the desktop. Last, it
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

# Logging out has to end the user's session and bring back GDM's login
# screen: its own gnome-shell, running as gdm, holding the display (DRM
# master) and answering on its D-Bus. This runs last, as it ends the session.
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

	# The greeter has to own the display, or the screen stays frozen on the
	# old session. debugfs lists each DRM client and whether it is master.
	mountpoint -q /sys/kernel/debug 2>/dev/null || mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || :
	clients=$(cat /sys/kernel/debug/dri/*/clients 2>/dev/null) || clients=
	if [ -n "$clients" ]; then
		echo "$clients" | awk -v p="$greeter" '$2 == p && $4 == "y" { found = 1 } END { exit !found }' ||
			{ echo "--- DRM clients:"; echo "$clients"; logout_fail "the login screen is not DRM master"; return 1; }
	else
		echo "logout: no DRM client list in debugfs; not checking DRM master"
	fi
	echo "[PASS] Logging out returns to the GDM login screen"
}

t_logout_to_greeter || failed=$((failed + 1))
exit "$failed"
