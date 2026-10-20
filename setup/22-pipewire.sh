#!/bin/sh

set -eu
[ "$(id -u)" -eq 0 ] || exec doas "$0" "$@"

apk add pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-spa-bluez
if apk info -e pulseaudio >/dev/null 2>&1 && [ -e /usr/bin/pulseaudio ]; then
    apk del pulseaudio pulseaudio-alsa pulseaudio-bluez
fi
echo "Log out and back in to switch the session to PipeWire."
