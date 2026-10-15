#!/bin/bash
# Points the Homebrew cask (iDevEngineer/homebrew-tap) at a published release.
#
#   ./scripts/update-tap.sh X.Y.Z
#
# Run after `gh release create vX.Y.Z …`, so the zip is downloadable.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 X.Y.Z" >&2; exit 1; }
VERSION=$1
URL="https://github.com/iDevEngineer/clarishot/releases/download/v$VERSION/Clarishot-$VERSION.zip"
SHA=$(curl -fsSL "$URL" | shasum -a 256 | cut -d' ' -f1)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
git clone -q https://github.com/iDevEngineer/homebrew-tap.git "$WORK"
CASK="$WORK/Casks/clarishot.rb"
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
git -C "$WORK" commit -qam "Clarishot $VERSION"
git -C "$WORK" push -q
echo "Homebrew cask now at $VERSION ($SHA)"
