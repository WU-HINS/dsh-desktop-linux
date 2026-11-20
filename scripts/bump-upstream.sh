#!/usr/bin/env bash
# Point PKGBUILD at one upstream tag and commit.
#   ./scripts/bump-upstream.sh <upstream-tag> <commit-sha> <version>
# Rewrites _tag, _commit, pkgver and resets pkgrel, which is what every other file keys off.
set -euo pipefail

tag="${1:?upstream tag is required}"
commit="${2:?upstream commit is required}"
version="${3:?upstream version is required}"

[[ "$tag" =~ ^dsh-v[0-9A-Za-z.+-]+$ ]] || { echo "bump-upstream: bad tag '$tag'" >&2; exit 2; }
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "bump-upstream: bad commit '$commit'" >&2; exit 2; }
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "bump-upstream: bad version '$version'" >&2; exit 2; }

pkgver="${version//-/}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
file="$root/PKGBUILD"

sed -i "s/^_tag=.*/_tag='$tag'/" "$file"
sed -i "s/^_commit=.*/_commit='$commit'/" "$file"
sed -i "s/^pkgver=.*/pkgver=$pkgver/" "$file"
sed -i "s/^pkgrel=.*/pkgrel=1/" "$file"

echo "==> PKGBUILD -> _tag=$tag _commit=$commit pkgver=$pkgver pkgrel=1"
grep -E '^(pkgver|pkgrel|_tag|_commit)=' "$file"
