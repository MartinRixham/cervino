#!/bin/sh
# Runs as root on the installed system: checks that the live session was
# left behind, logs the user created during the install in to GNOME, then
# runs os-feature-tests.sh as that user with the session's environment
# (taken from gnome-shell), as if from a terminal in the desktop. Exits with
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
user_proc() {
	for d in /proc/[0-9]*; do
		[ "$(cat "$d"/comm 2>/dev/null)" = "$1" ] && [ "$(stat -c %u "$d")" = "$uid" ] &&
			{ echo "${d#/proc/}"; return 0; }
	done
	return 1
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

su "$user" -s /bin/bash -c '
	while IFS= read -r -d "" kv; do export "$kv"; done < /proc/$1/environ
	cd
	exec bash "$2"' bash "$pid" "$(realpath "$dir")/os-feature-tests.sh" < /dev/null
