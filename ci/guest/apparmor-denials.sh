#!/bin/sh
# Prints the AppArmor denials in the kernel log, each different one once
# (without the pids that tell repeats apart), and exits 1 if there are any.

denials=$(dmesg | sed -n 's/.*\(apparmor="DENIED".*\)/\1/p' |
	sed -e 's/ pid=[0-9]*//' -e 's/ fsuid=.*//' -e 's|/proc/[0-9]*/|/proc/<pid>/|g' |
	sort -u)
[ -z "$denials" ] && exit 0
printf '%s\n' "$denials"
exit 1
