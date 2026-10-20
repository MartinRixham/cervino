#!/bin/sh

set -eu
[ "$(id -u)" -eq 0 ] || exec doas "$0" "$@"

# Named 99- so it runs after the other profile.d scripts. Any existing
# entry is removed first, so nested login shells don't add duplicates.
cat > /etc/profile.d/99-local-bin.sh <<'EOT'
_p=":$PATH:"
while case $_p in *":$HOME/.local/bin:"*) true ;; *) false ;; esac; do
	_p="${_p%%:"$HOME"/.local/bin:*}:${_p#*:"$HOME"/.local/bin:}"
done
_p="${_p#:}"
_p="${_p%:}"
PATH="$HOME/.local/bin${_p:+:$_p}"
export PATH
unset _p
EOT
echo "~/.local/bin is first in PATH in new login shells. Log out and back in for it to take effect."
