#!/bin/sh

set -eu
[ "$(id -u)" -eq 0 ] || exec doas "$0" "$@"

apk add openrc-settingsd
rc-update add openrc-settingsd default
rc-service openrc-settingsd start
