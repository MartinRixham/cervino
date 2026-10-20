#!/bin/sh

set -eu
[ "$(id -u)" -eq 0 ] || exec doas "$0" "$@"

apk add xdg-utils
