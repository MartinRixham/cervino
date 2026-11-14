#!/usr/bin/env bash
#
# ci/publish-repo.sh KEY [PREFIX=]NEW...: adds the packages builds left in
# each NEW directory (laid out as <branch>/<arch>/, as in OUTDIR/repo) to
# the apk repos README.md (Updates) describes, under PREFIX/ on GitHub Pages
# (none for the ISOs', rpi for the Pi's), and keeps the newest few versions
# of each package. KEY is the abuild private key the packages are signed
# with, which signs the indexes too.
#
# The packages are assets of a GitHub release per repo and arch, tagged
# packages-[PREFIX-]<branch>-<arch>, and only the indexes are on the
# gh-pages branch, which Pages serves: an index names its release's
# download URL as its packages' (mkndx's --pkgname-spec), and apk checks
# each package it downloads against the hash the signed index holds. Pages
# times out deploying a site of hundreds of MB, and the branch's history
# would keep every package ever published. So gh-pages is force-pushed as
# a single commit, and assets no longer kept are deleted only once it no
# longer names them.
#
# Runs on the CI runner, in a checkout of the repository, with gh (GH_REPO,
# GH_TOKEN allowed to write releases and push gh-pages) and docker: each
# index is made in an alpine:<branch> container, in the format that
# branch's apk reads.

set -euo pipefail

key=$(realpath "${1:?usage: $0 KEY [PREFIX=]NEW...}")
shift
: "${GH_REPO:?GH_REPO must name the repository}"
# Older packages stay for a while, so that a release can be rolled back.
keep=5
download=https://github.com/$GH_REPO/releases/download

die() { echo "::error::$*" >&2; exit 1; }

site=$(mktemp -d)
work=$(mktemp -d)
keys=$(mktemp -d)
trap 'rm -rf "$site" "$work" "$keys" "$site.index"' EXIT
# A separate index, so that the checkout of main is left alone.
export GIT_INDEX_FILE=$site.index

# Only a missing branch means starting afresh: any other failure must stop
# the publish rather than force-push an empty site over the old one.
if git ls-remote --exit-code --heads origin gh-pages > /dev/null; then
	git fetch --depth 1 origin gh-pages
	git --work-tree "$site" checkout FETCH_HEAD -- .
else
	status=$?
	[[ $status == 2 ]] || exit "$status"
fi

# apk knows a key by its file name: the one the build signed with.
pubkey=$(basename "$key").pub
openssl rsa -in "$key" -pubout -out "$keys/$pubkey" 2> /dev/null ||
	die "$key is not an RSA private key"

# Releases up to v3.24.4 published the Pi's packages as the ISOs' repo's
# aarch64 ones, on gh-pages: they move to the Pi's repo, rpi/, once.
if [[ ! -e $site/rpi ]]; then
	for dir in "$site"/v*/aarch64; do
		[[ -d $dir ]] || continue
		mkdir -p "$site/rpi/${dir#"$site"/}"
		mv "$dir"/* "$site/rpi/${dir#"$site"/}"/
		rmdir "$dir"
	done
fi

# release_id TAG: the id of TAG's release, or nothing if there is none. Any
# failure but a missing release stops the publish.
release_id() {
	local out
	if out=$(gh api "repos/$GH_REPO/releases/tags/$1" --jq .id 2>&1); then
		echo "$out"
	elif ! grep -q 'HTTP 404' <<< "$out"; then
		echo "$out" >&2
		return 1
	fi
}

# release_assets ID: the names of release ID's assets.
release_assets() {
	gh api --paginate "repos/$GH_REPO/releases/$1/assets" --jq '.[].name'
}

# The repos to publish, as PREFIX/BRANCH/ARCH (PREFIX empty for the
# ISOs'): those with new packages, and those on gh-pages still holding
# packages of their own (published before the packages became release
# assets), which move to their release.
declare -A repos newdir
for arg; do
	prefix= new=$arg
	[[ $arg != *=* ]] || prefix=${arg%%=*} new=${arg#*=}
	for dir in "$new"/v*/*/; do
		dir=${dir%/}
		repo=$prefix/${dir#"$new"/}
		repos[$repo]=1
		newdir[$repo]=$dir
	done
done
for dir in "$site"/v*/*/ "$site"/*/v*/*/; do
	ls "$dir"*.apk > /dev/null 2>&1 || continue
	dir=${dir%/}
	repo=${dir#"$site"/}
	[[ $repo == */*/* ]] || repo=/$repo
	repos[$repo]=1
done
[[ ${#repos[@]} -gt 0 ]] || { echo "No packages to publish"; exit 0; }

declare -A stale prefixes
for repo in "${!repos[@]}"; do
	IFS=/ read -r prefix branch arch <<< "$repo"
	prefixes[$prefix]=1
	tag=packages-${prefix:+$prefix-}$branch-$arch
	pages=$site/${prefix:+$prefix/}$branch/$arch
	dir=$work/$tag
	mkdir -p "$dir" "$pages"
	echo ">>> $tag"

	id=$(release_id "$tag")
	if [[ -z $id ]]; then
		gh release create "$tag" --title "$tag" --latest=false --notes \
			"Packages of Cervino's ${prefix:+$prefix }repo for Alpine $branch, $arch. apk installs them from there; see README.md, Updates."
		id=$(release_id "$tag")
	fi
	mapfile -t before < <(release_assets "$id")
	if [[ ${#before[@]} -gt 0 ]]; then
		gh release download "$tag" --pattern '*.apk' --dir "$dir"
	fi

	# Those published on gh-pages before, and the new ones. Every release
	# builds most packages again at a version already published: that one
	# stays as it was (installs have it already).
	for apk in "$pages"/*.apk ${newdir[$repo]:+"${newdir[$repo]}"/*.apk}; do
		[[ -e $apk ]] || continue
		[[ -e $dir/${apk##*/} ]] || cp "$apk" "$dir"/
	done
	rm -f "$pages"/*.apk

	# The newest few versions of each package (NAME-VERSION-rN.apk).
	for name in $(ls "$dir" | sed -n 's/^\(.*\)-[^-]*-r[0-9]*\.apk$/\1/p' | sort -u); do
		ls "$dir" | grep -E "^$name-[^-]+-r[0-9]+\.apk\$" | sort -V -r |
			tail -n +$((keep + 1)) | sed "s|^|$dir/|" | xargs -r rm -f
	done

	# GitHub renames assets with other characters than these, and the
	# index names each package NAME-VERSION.apk, as abuild does.
	upload=()
	for apk in "$dir"/*.apk; do
		name=${apk##*/}
		[[ $name =~ ^[A-Za-z0-9._-]+$ ]] ||
			die "$name has characters a GitHub release asset can't have"
		printf '%s\n' "${before[@]}" | grep -qxF -- "$name" || upload+=("$apk")
	done
	if [[ ${#upload[@]} -gt 0 ]]; then
		gh release upload "$tag" "${upload[@]}"
	fi
	mapfile -t after < <(release_assets "$id")
	for apk in "$dir"/*.apk; do
		printf '%s\n' "${after[@]}" | grep -qxF -- "${apk##*/}" ||
			die "${apk##*/} is missing from the $tag release"
	done
	for name in "${before[@]}"; do
		[[ -e $dir/$name ]] || stale[$tag/$name]=1
	done

	# The index, signed, naming the release's assets. It is the arch's
	# index whatever the packages' own arch (cervino-desktop's is noarch):
	# with each package's URL in the index, apk doesn't look for it in the
	# directory of the arch its index records.
	pkgs=()
	for apk in "$dir"/*.apk; do pkgs+=("/pkgs/${apk##*/}"); done
	# shellcheck disable=SC2016 # mkndx fills in ${name} and ${version}
	docker run --rm --user "$(id -u):$(id -g)" \
		-v "$dir:/pkgs:ro" -v "$pages:/out" -v "$key:/key/${key##*/}:ro" \
		-v "$keys/$pubkey:/etc/apk/keys/$pubkey:ro" \
		"docker.io/library/alpine:${branch#v}" \
		apk mkndx --quiet --sign-key "/key/${key##*/}" \
		--description "cervino ${prefix:+$prefix }$branch" \
		--pkgname-spec "$download/$tag/"'${name}-${version}.apk' \
		-o /out/APKINDEX.tar.gz "${pkgs[@]}" ||
		die "could not index $tag"
done

# The public key next to each repo, for setting it up by hand. GitHub
# Pages serves the files as they are, without Jekyll.
for prefix in "${!prefixes[@]}"; do
	cp "$keys/$pubkey" "$site/${prefix:+$prefix/}"
done
touch "$site"/.nojekyll

rm -f "$GIT_INDEX_FILE"
git --work-tree "$site" add -A
tree=$(git write-tree)
export GIT_AUTHOR_NAME="github-actions[bot]"
export GIT_AUTHOR_EMAIL="41898333+github-actions[bot]@users.noreply.github.com"
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
commit=$(git commit-tree "$tree" -m "Packages from ${GITHUB_REF_NAME:-$(git rev-parse --short HEAD)}")
git push -f origin "$commit:refs/heads/gh-pages"

# Only now that gh-pages no longer names them. apk keeps an index for a
# while, so an install with an older one can still fail to download a
# deleted package until it fetches the new index.
for name in "${!stale[@]}"; do
	gh release delete-asset "${name%%/*}" "${name#*/}" --yes
done
