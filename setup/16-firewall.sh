#!/bin/sh

set -eu
[ "$(id -u)" -eq 0 ] || exec doas "$0" "$@"

apk add nftables
cat > /etc/nftables.d/50-desktop.nft <<'EOT'
table inet filter {
	chain input {
		tcp dport 22 accept comment "SSH"
		udp dport 5353 accept comment "mDNS"
	}
}
EOT
nft -c -f /etc/nftables.nft
rc-update add nftables default
rc-service nftables restart
