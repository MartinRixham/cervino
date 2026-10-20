#!/bin/sh

set -eu
[ "$(id -u)" -eq 0 ] || exec doas "$0" "$@"

apk add bluez
rc-update add bluetooth default
rc-service bluetooth start || echo "bluetoothd did not start (no adapter?); it is enabled for boot."
