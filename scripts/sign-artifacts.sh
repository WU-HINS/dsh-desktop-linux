#!/usr/bin/env bash
# GPG-sign every release artifact plus the checksum file.
#   GPG_PRIVATE_KEY=... GPG_PASSPHRASE=... ./scripts/sign-artifacts.sh <directory>
set -euo pipefail

directory="${1:-dist}"
: "${GPG_PRIVATE_KEY:?GPG_PRIVATE_KEY is required}"

export GNUPGHOME="$(mktemp -d)"
trap 'rm -rf "$GNUPGHOME"' EXIT

printf '%s' "$GPG_PRIVATE_KEY" | gpg --batch --import >/dev/null 2>&1
key="$(gpg --list-secret-keys --with-colons | awk -F: '/^sec:/{print $5; exit}')"
[[ -n "$key" ]] || { echo "sign-artifacts: imported key has no secret material" >&2; exit 1; }

shopt -s nullglob
files=("$directory"/*.AppImage "$directory"/*.deb "$directory"/*.rpm "$directory"/*.pkg.tar.zst "$directory"/SHA256SUMS.txt)
[[ ${#files[@]} -gt 0 ]] || { echo "sign-artifacts: nothing to sign in $directory" >&2; exit 1; }

for file in "${files[@]}"; do
  [[ -f "$file" ]] || continue
  printf '%s' "${GPG_PASSPHRASE:-}" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
    --local-user "$key" --armor --detach-sign --output "$file.asc" "$file"
  echo "signed $(basename "$file")"
done

gpg --armor --export "$key" > "$directory/PUBKEY.asc"
echo "exported $directory/PUBKEY.asc"
