#!/bin/sh
# ci/update-test.sh REPO_DIR
#
# Tests update-alpine, from the cervino-desktop package the build wrote to
# REPO_DIR (laid out as <branch>/<arch>/, as in out/repo), in containers of
# plain Alpine (CONTAINER: podman, else docker), where it runs in seconds:
# - on the package's release: it upgrades the packages and checks for a
#   newer release;
# - on the release before: it offers the newer one, and turning that down
#   changes nothing; then, accepted, it upgrades the system to it.
# A container has no cervino.list, so the check of cervino-desktop's repo
# for the new release is not covered. Prints results as test/features.sh
# does and exits with the number of failed tests.

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

# On the release before the package's: a newer release is offered, and
# turning it down leaves the repositories alone.
t_offer() {
	desc="update-alpine offers a newer release; turning it down changes nothing"
	release=$(cut -d. -f1,2 /etc/alpine-release)
	cp "$repos" /repositories.orig
	run ''
	[ "$rc" = 0 ] || { run_fail "$desc" "it failed"; return 1; }
	printf '%s\n' "$out" | grep -q "is available (this system runs $release)" ||
		{ run_fail "$desc" "it offered no newer release"; return 1; }
	cmp -s "$repos" /repositories.orig ||
		{ fail "$desc" "turning the upgrade down changed $repos:
$(diff /repositories.orig "$repos")"; return 1; }
	pass "$desc"
}

# Then, accepted (and the restart turned down), the system is upgraded to it.
t_upgrade() {
	desc="update-alpine upgrades to the newer release"
	run 'y\nn\n'
	[ "$rc" = 0 ] || { run_fail "$desc" "it failed"; return 1; }
	new=$(printf '%s\n' "$out" | sed -n 's/^The system now runs Alpine Linux \([0-9]*\.[0-9]*\)\..*/\1/p')
	[ -n "$new" ] || { run_fail "$desc" "it did not say it upgraded"; return 1; }
	case $(cat /etc/alpine-release) in "$new".*) ;; *)
		fail "$desc" "it said it upgraded to $new, but /etc/alpine-release is $(cat /etc/alpine-release)"
		return 1
	esac
	grep -q "/v$new/main" "$repos" && ! grep -q "/v$release/" "$repos" ||
		{ fail "$desc" "$repos not moved to v$new:
$(cat "$repos")"; return 1; }
	left=$(left_to_upgrade)
	[ -z "$left" ] || { fail "$desc" "packages left to upgrade:
$left"; return 1; }
	pass "$desc"
}

# in_container current|older PACKAGE
in_container() {
	tar -xzf "$2" -C / usr/sbin/update-alpine && [ -x /usr/sbin/update-alpine ] ||
		{ fail "update-alpine in the package" "$2 has no executable usr/sbin/update-alpine"; exit 1; }
	case $1 in
	current)
		t_current || true ;;
	older)
		if t_offer; then
			t_upgrade || true
		fi ;;
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
			"docker.io/library/alpine:$1" sh /update-test.sh --in-container "$2" /cervino-desktop.apk ||
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
