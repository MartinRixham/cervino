#!/bin/sh

set -eu
[ "$(id -u)" -eq 0 ] || exec doas "$0" "$@"

apk add command-not-found
ln -sf /etc/profile.d/command-not-found.sh /etc/bash/command-not-found.sh
