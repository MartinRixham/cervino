#!/bin/sh
# ci/publish-repo.sh NEW PAGES KEY BRANCH: adds the cervino-desktop packages
# of Alpine branch BRANCH that builds left under NEW/BRANCH/<arch>/ (the
# images' OUTDIR/repo) to the apk repo in PAGES (a checkout of the gh-pages
# branch), keeps the newest few of each arch, and indexes and signs each arch
# again with KEY, the abuild private key the packages are signed with. Runs as
# root in an alpine:<BRANCH> container, so the index is in the format that
# branch's apk reads.

set -eu

new=$1 pages=$2 key=$3 branch=$4
# Older packages stay for a while, so that a release can be rolled back.
keep=5

apk add --quiet abuild
# apk knows a key by its file name: the one the build signed with.
pubkey=$(basename "$key").pub
openssl rsa -in "$key" -pubout -out /etc/apk/keys/"$pubkey" 2>/dev/null
# For setting the repo up by hand.
cp /etc/apk/keys/"$pubkey" "$pages"/

for dir in "$new/$branch"/*/; do
	arch=$(basename "$dir")
	out=$pages/$branch/$arch
	mkdir -p "$out"
	cp "$dir"/cervino-desktop-*.apk "$out"/
	# The version is a time stamp of fixed width, so names sort by it.
	ls "$out"/cervino-desktop-*.apk | sort -r | tail -n +$((keep + 1)) | xargs -r rm -f
	# The package is noarch, but apk 3 fetches it from the directory of the
	# arch its index gives.
	rm -f "$out"/APKINDEX.tar.gz
	apk index --quiet --no-warnings --rewrite-arch "$arch" \
		--description "cervino $branch" \
		-o "$out"/APKINDEX.tar.gz "$out"/cervino-desktop-*.apk
	abuild-sign -q -k "$key" -p "$pubkey" "$out"/APKINDEX.tar.gz
done

# GitHub Pages serves the files as they are, without Jekyll.
touch "$pages"/.nojekyll
chown -R "$(stat -c %u:%g "$pages")" "$pages"
