#!/bin/sh
# ci/local-repo.sh [RUN_ID]
#
# Serves the packages of a CI build on 127.0.0.1 as an apk repository, to
# upgrade this machine to them before a release publishes them: downloads
# the build's repo (cervino-repo-<target>.tar, which CI puts on the
# prerelease ci-<run id>) of workflow run RUN_ID or else the last
# successful run of the checked out branch, and serves it until it is
# stopped (Ctrl-C). It needs no GitHub login, nor root:
# it prints the commands that add the repository and its keys, upgrade,
# and remove them again, which README.md (Upgrading to a CI build)
# describes.
#
# Its packages are signed with the build's own key and have no
# index. The key is taken from the cervino-desktop package, which brings it,
# and the index is made here, signed with a key made for this run, whose
# private half is deleted before the repo is served. Both public keys are
# written next to the repo, for apk to be made to trust them.
#
# TARGET (rpi, arm64 or x86_64) is the build to take, by default this
# machine's; PORT (8080) is the port to serve on; REPO (owner/name) the
# GitHub repository, by default that of the remote origin.

set -eu

die() {
	echo "local-repo: $*" >&2
	exit 1
}

workflow=build-iso.yml
port=${PORT:-8080}
indexkey=cervino-local.rsa.pub

[ $# -le 1 ] || die "usage: $0 [RUN_ID]"
run=${1:-}
for cmd in python3 openssl; do
	command -v "$cmd" > /dev/null || die "$cmd is not installed"
done

target=${TARGET:-}
if [ -z "$target" ]; then
	# As atomic.sh's atomic_pi: the firmware's files are in a Pi's /boot.
	if [ -f /boot/start4.elf ] || [ -f /boot/bootcode.bin ]; then
		target=rpi
	else
		case $(uname -m) in
		aarch64) target=arm64 ;;
		x86_64) target=x86_64 ;;
		*) die "no build for $(uname -m)" ;;
		esac
	fi
fi
arch=$(apk --print-arch)

cd "$(dirname "$0")"/..
repo=${REPO:-$(git remote get-url origin |
	sed -n 's,^.*github\.com[:/]\([^/]*/[^/]*\)$,\1,p' | sed 's/\.git$//')}
[ -n "$repo" ] || die "the remote origin is not on GitHub: set REPO"
if [ -z "$run" ]; then
	branch=$(git rev-parse --abbrev-ref HEAD)
	# The API, which needs no login for a public repository.
	run=$(wget -q -O - "https://api.github.com/repos/$repo/actions/workflows/$workflow/runs?branch=$branch&status=success&per_page=1" |
		python3 -c 'import json, sys; print(*(r["id"] for r in json.load(sys.stdin)["workflow_runs"]))') ||
		die "could not list the runs of $repo"
	[ -n "$run" ] || die "no successful $workflow run of $branch"
fi

work=$(mktemp -d)
server=
cleanup() {
	trap - EXIT
	[ -z "$server" ] || kill "$server" 2> /dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM

echo ">>> Downloading cervino-repo-$target from run $run"
wget -q -O "$work"/repo.tar \
	"https://github.com/$repo/releases/download/ci-$run/cervino-repo-$target.tar" ||
	die "could not download cervino-repo-$target of run $run (CI keeps them for 14 days)"
mkdir "$work"/repo
tar -xf "$work"/repo.tar -C "$work"/repo
rm "$work"/repo.tar
# Laid out as <branch>/<arch>/.
release=$(ls "$work"/repo)
dir=$work/repo/$release/$arch
[ -d "$dir" ] || die "the download does not hold $arch packages of one release"
[ "$(sed -n 's/^VERSION_ID=\([0-9]*\.[0-9]*\).*/v\1/p' /etc/os-release)" = "$release" ] ||
	die "the packages are for Alpine $release, not this system's release"

# The build's key: the one cervino-desktop is signed with, which it holds.
desktop=$(ls "$dir"/cervino-desktop-[0-9]*.apk)
buildkey=$(tar -tzf "$desktop" 2> /dev/null | sed -n 's/^\.SIGN\.RSA\.//p;q')
[ -n "$buildkey" ] || die "$desktop is not signed"
mkdir "$work"/keys
tar -xzOf "$desktop" etc/apk/keys/"$buildkey" > "$work/keys/$buildkey" 2> /dev/null &&
	[ -s "$work/keys/$buildkey" ] || die "$desktop does not hold its key, $buildkey"

# The index, naming each package by its URL: apk would look for a noarch
# package (cervino-desktop) under noarch/ otherwise.
url=http://127.0.0.1:$port
(
	umask 077
	openssl genrsa -out "$work"/index.rsa 2048 2> /dev/null
)
openssl rsa -in "$work"/index.rsa -pubout -out "$work/keys/$indexkey" 2> /dev/null
apk mkndx --quiet --keys-dir "$work"/keys --sign-key "$work"/index.rsa \
	--pkgname-spec "$url/$release/$arch/"'${name}-${version}.apk' \
	-o "$dir"/APKINDEX.tar.gz "$dir"/*.apk || die "could not index the packages"
rm "$work"/index.rsa

python3 -m http.server "$port" --bind 127.0.0.1 --directory "$work"/repo \
	> "$work"/server.log 2>&1 &
server=$!
n=0
until wget -q -O /dev/null "$url/$release/$arch/APKINDEX.tar.gz" 2> /dev/null; do
	n=$((n + 1))
	kill -0 "$server" 2> /dev/null && [ "$n" -lt 50 ] ||
		die "could not serve on port $port: $(tail -n 1 "$work"/server.log)"
	sleep 0.2
done

cat <<EOF
>>> Serving $url/$release until stopped (Ctrl-C). To upgrade, in another
    terminal:

doas cp $work/keys/*.pub /etc/apk/keys/
echo $url/$release | doas tee /etc/apk/repositories.d/local.list
doas update-alpine

    and afterwards, before restarting:

doas rm /etc/apk/repositories.d/local.list /etc/apk/keys/$indexkey
EOF
wait "$server"
