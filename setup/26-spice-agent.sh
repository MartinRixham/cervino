#!/bin/sh

set -eu
[ "$(id -u)" -eq 0 ] || exec doas "$0" "$@"

apk add spice-vdagent spice-vdagent-openrc
modprobe uinput
grep -qx uinput /etc/modules || echo uinput >> /etc/modules
rc-update add spice-vdagentd default
rc-service spice-vdagentd start
echo "Log out and back in to start the session agent."
