#!/bin/sh

set -eu
[ "$(id -u)" -eq 0 ] || exec doas "$0" "$@"

apk add nano
cat > /etc/profile.d/50-editor.sh <<'EOT'
export EDITOR="${EDITOR:-nano}"
EOT
echo "EDITOR defaults to nano in new login shells."
