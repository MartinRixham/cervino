#!/bin/sh
# ci/update-test.sh REPO_DIR
#
# Tests update-alpine, from the cervino-desktop package the build wrote to
# REPO_DIR (laid out as <branch>/<arch>/, as in out/repo), in containers of
# plain Alpine (CONTAINER: podman, else docker), where it runs in seconds:
# - on the package's release: it upgrades the packages and checks for a
#   newer release;
# - on the release before, with a stand-in cervino-desktop installed from a
#   signed repo served over HTTP in the container, whose cervino.list names
#   that repo: while the repo has no packages for the newer release, it
#   offers nothing and changes nothing; once it has, it offers the newer
#   release, and turning that down changes nothing; then, accepted, it
#   upgrades the system to it, cervino-desktop and cervino.list included.
# The stand-in holds only cervino.list, so this doesn't install GNOME.
# Prints results as test/features.sh does and exits with the number of
# failed tests.

set -eu

passed=0 failed=0
pass() {
	passed=$((passed + 1))
	printf '[PASS] %s\n' "$1"
}
# fail DESCRIPTION REASON
fail() {
	failed=$((failed + 1))
	printf '[FAIL] %s\n' "$1"
	printf '%s\n' "$2" | sed 's/^/       /'
}

# Inside the container, as root.

repos=/etc/apk/repositories
list=/etc/apk/repositories.d/cervino.list
cervino=http://127.0.0.1:8080

# run ANSWERS: runs update-alpine with ANSWERS (printf %b) as its input, into
# $out and $rc.
run() {
	rc=0
	out=$(printf '%b' "$1" | timeout 600 update-alpine 2>&1) || rc=$?
}
# run_fail DESCRIPTION REASON: fails a test with update-alpine's last output.
run_fail() {
	fail "$1" "$2; update-alpine exited with $rc:
$(printf '%s\n' "$out" | tail -n 8)"
}
# left_to_upgrade: prints what apk would still upgrade.
left_to_upgrade() {
	apk upgrade --simulate 2>&1 | grep -E '^\([0-9]+/[0-9]+\) (Upgrading|Replacing)' || true
}

# On the package's release: the packages are upgraded and a newer release
# looked for (and offered, when the image was built on an older branch).
t_current() {
	desc="update-alpine upgrades the packages"
	run ''
	[ "$rc" = 0 ] || { run_fail "$desc" "it failed"; return 1; }
	printf '%s\n' "$out" | grep -Eq 'is the latest release|is available' ||
		{ run_fail "$desc" "it did not check for a newer release"; return 1; }
	left=$(left_to_upgrade)
	[ -z "$left" ] || { fail "$desc" "packages left to upgrade:
$left"; return 1; }
	pass "$desc"
}

# cervino_repo BRANCH VERSION: publishes a stand-in cervino-desktop VERSION,
# which holds only a cervino.list naming its own repo, as BRANCH's repo
# under $cervino, signed with a key apk trusts.
cervino_repo() {
	dir=/srv/$1/$(apk --print-arch)
	mkdir -p /stand-in/"$1"/etc/apk/repositories.d "$dir"
	echo "$cervino/$1" > /stand-in/"$1"/etc/apk/repositories.d/cervino.list
	apk mkpkg -F /stand-in/"$1" -I name:cervino-desktop -I version:"$2" \
		-I arch:"$(apk --print-arch)" -I description:stand-in -I license:none \
		--sign-key /cervino-test.rsa -o "$dir"/cervino-desktop-"$2".apk &&
		apk mkndx --sign-key /cervino-test.rsa -o "$dir"/APKINDEX.tar.gz "$dir"/*.apk > /dev/null
}

# Installs the stand-in cervino-desktop from its repo for this release, served
# on $cervino.
setup_cervino() {
	release=$(cut -d. -f1,2 /etc/alpine-release)
	apk add -q openssl busybox-extras &&
		openssl genrsa -out /cervino-test.rsa 2048 2> /dev/null &&
		openssl rsa -in /cervino-test.rsa -pubout \
			-out /etc/apk/keys/cervino-test.rsa.pub 2> /dev/null &&
		cervino_repo "v$release" 1-r0 &&
		busybox-extras httpd -p "${cervino#http://}" -h /srv &&
		apk add -q -X "$cervino/v$release" cervino-desktop &&
		[ "$(cat "$list")" = "$cervino/v$release" ]
}

# save: keeps copies of the repository lists; unchanged DESCRIPTION: fails
# DESCRIPTION if they changed since.
save() {
	cp "$repos" /repositories.orig
	cp "$list" /cervino.list.orig
}
unchanged() {
	cmp -s "$repos" /repositories.orig && cmp -s "$list" /cervino.list.orig && return 0
	fail "$1" "the repository lists changed:
$(diff /repositories.orig "$repos"; diff /cervino.list.orig "$list")"
	return 1
}

# On the release before the package's: while cervino-desktop's repo has no
# packages for the newer release, it is not offered.
t_unpublished() {
	desc="update-alpine waits for cervino-desktop's repo to have the newer release"
	save
	run ''
	[ "$rc" = 0 ] || { run_fail "$desc" "it failed"; return 1; }
	new=$(printf '%s\n' "$out" |
		sed -n 's/^Alpine Linux \([0-9]*\.[0-9]*\) is out, but Cervino.*/\1/p')
	[ -n "$new" ] || {
		run_fail "$desc" "it did not say the repo has no packages for a newer release"
		return 1
	}
	unchanged "$desc" || return 1
	pass "$desc"
}

# Then, with the repo published, it is offered, and turning it down leaves
# the repository lists alone.
t_offer() {
	desc="update-alpine offers a newer release; turning it down changes nothing"
	cervino_repo "v$new" 2-r0 || {
		fail "$desc" "could not publish the stand-in for v$new"
		return 1
	}
	save
	run ''
	[ "$rc" = 0 ] || { run_fail "$desc" "it failed"; return 1; }
	printf '%s\n' "$out" | grep -q "Alpine Linux $new is available (this system runs $release)" ||
		{ run_fail "$desc" "it offered no newer release"; return 1; }
	unchanged "$desc" || return 1
	pass "$desc"
}

# Then, accepted (and the restart turned down), the system is upgraded to it.
t_upgrade() {
	desc="update-alpine upgrades to the newer release"
	run 'y\nn\n'
	[ "$rc" = 0 ] || { run_fail "$desc" "it failed"; return 1; }
	printf '%s\n' "$out" | grep -q "^The system now runs Alpine Linux $new\\." ||
		{ run_fail "$desc" "it did not say it upgraded to $new"; return 1; }
	case $(cat /etc/alpine-release) in "$new".*) ;; *)
		fail "$desc" \
			"it said it upgraded to $new, but /etc/alpine-release is $(cat /etc/alpine-release)"
		return 1
	esac
	grep -q "/v$new/main" "$repos" && ! grep -q "/v$release/" "$repos" ||
		{ fail "$desc" "$repos not moved to v$new:
$(cat "$repos")"; return 1; }
	[ "$(cat "$list")" = "$cervino/v$new" ] ||
		{ fail "$desc" "$list not moved to v$new: $(cat "$list")"; return 1; }
	[ ! -e "$list.apk-new" ] ||
		{ fail "$desc" "$list.apk-new left behind"; return 1; }
	apk list --installed cervino-desktop 2> /dev/null | grep -q '^cervino-desktop-2-r0 ' || {
		fail "$desc" \
			"cervino-desktop not upgraded to v$new's: $(apk list --installed cervino-desktop 2>&1)"
		return 1
	}
	left=$(left_to_upgrade)
	[ -z "$left" ] || { fail "$desc" "packages left to upgrade:
$left"; return 1; }
	pass "$desc"
}

# in_container current|older PACKAGE
in_container() {
	tar -xzf "$2" -C / usr/sbin/update-alpine && [ -x /usr/sbin/update-alpine ] || {
		fail "update-alpine in the package" "$2 has no executable usr/sbin/update-alpine"
		exit 1
	}
	case $1 in
	current)
		t_current || true ;;
	older)
		setup_cervino || {
			fail "Stand-in cervino-desktop installed from a local repo" "setting it up failed"
			exit 1
		}
		t_unpublished && t_offer && t_upgrade || true ;;
	esac
	exit "$failed"
}

# On the host.

die() {
	echo "update-test.sh: $*" >&2
	exit 1
}

host_main() {
	repo=${1:?usage: ci/update-test.sh REPO_DIR}
	set -- "$repo"/v*/*/cervino-desktop-*.apk
	[ -f "$1" ] || die "no cervino-desktop package in $repo"
	pkg=$(realpath "$1")
	branch=${1#"$repo"/}
	branch=${branch%%/*}
	minor=${branch#*.}
	runtime=${CONTAINER:-}
	if [ -z "$runtime" ]; then
		if command -v podman > /dev/null; then runtime=podman; else runtime=docker; fi
	fi

	total=0
	# in_alpine RELEASE MODE: runs this script in an alpine:RELEASE container.
	in_alpine() {
		echo "== Alpine $1 =="
		rc=0
		"$runtime" run --rm --security-opt label=disable \
			-v "$(realpath "$0")":/update-test.sh:ro -v "$pkg":/cervino-desktop.apk:ro \
			"docker.io/library/alpine:$1" \
			sh /update-test.sh --in-container "$2" /cervino-desktop.apk ||
			rc=$?
		total=$((total + rc))
		echo
	}
	release=${branch#v}
	in_alpine "$release" current
	if [ "$minor" -gt 0 ]; then
		in_alpine "${release%.*}.$((minor - 1))" older
	else
		echo "No release before $release to upgrade from"
	fi
	echo "update-alpine tests failed: $total"
	exit "$total"
}

if [ "${1:-}" = --in-container ]; then
	shift
	in_container "$@"
fi
host_main "$@"
