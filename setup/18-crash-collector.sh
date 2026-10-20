#!/bin/sh

set -eu
[ "$(id -u)" -eq 0 ] || exec doas "$0" "$@"

mkdir -p /usr/local/libexec
cat > /usr/local/libexec/coredump-handler <<'EOT'
#!/bin/sh
# Invoked by the kernel via core_pattern with: %P %u %s %t
pid=$1 uid=$2 sig=$3 time=$4
dir=/var/lib/coredump
max_files=20
max_bytes=2147483648

umask 077
mkdir -p "$dir"
comm=$(tr -cd 'A-Za-z0-9_.-' < "/proc/$pid/comm" 2>/dev/null)
out="$dir/core.${comm:-unknown}.$uid.$pid.$time"

if command -v zstd >/dev/null 2>&1; then
    out=$out.zst
    head -c "$max_bytes" | zstd -q -o "$out"
else
    head -c "$max_bytes" > "$out"
fi
logger -t coredump "Process $pid (${comm:-unknown}) of user $uid dumped core on signal $sig: $out"

ls -1t "$dir"/core.* 2>/dev/null | tail -n +$((max_files + 1)) | xargs -r rm -f
EOT
chmod 755 /usr/local/libexec/coredump-handler

pattern='|/usr/local/libexec/coredump-handler %P %u %s %t'
printf 'kernel.core_pattern = %s\n' "$pattern" > /etc/sysctl.d/50-coredump.conf
printf '%s\n' "$pattern" > /proc/sys/kernel/core_pattern
echo "Core dumps now go to /var/lib/coredump."
