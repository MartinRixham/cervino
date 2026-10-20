#!/bin/sh

set -eu
[ "$(id -u)" -eq 0 ] || exec doas "$0" "$@"

apk add zram-init zram-init-openrc

ram_mb=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
size=$((ram_mb / 2))
[ "$size" -gt 8192 ] && size=8192

conf=/etc/conf.d/zram-init
sed -i -e 's/^num_devices=.*/num_devices=1/' -e "s/^size0=.*/size0=$size/" "$conf"

rc-update add zram-init boot
rc-service zram-init restart
cat /proc/swaps
