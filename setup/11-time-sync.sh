#!/bin/sh

set -eu
[ "$(id -u)" -eq 0 ] || exec doas "$0" "$@"

apk add chrony
rc-update add chronyd default
rc-service chronyd start
