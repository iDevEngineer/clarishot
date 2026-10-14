#!/bin/bash
# Makes a release: bumps VERSION, dates the changelog's Unreleased notes, commits, tags vX.Y.Z,
# and builds build/Clarishot-X.Y.Z.zip plus build/release-notes.md for a GitHub release.
#
#   ./scripts/release.sh patch | minor | major | X.Y.Z
#
# It does not push. Afterwards: git push && git push --tags
set -euo pipefail
cd "$(dirname "$0")/.."

[ $# -eq 1 ] || { echo "usage: $0 patch|minor|major|X.Y.Z" >&2; exit 1; }
if [ -n "$(git status --porcelain)" ]; then
    echo "error: commit or stash your changes first" >&2; exit 1
fi

CURRENT=$(tr -d '[:space:]' < VERSION)
IFS=. read -r MAJOR MINOR PATCH <<< "$CURRENT"
case "$1" in
    patch) NEW="$MAJOR.$MINOR.$((PATCH + 1))" ;;
    minor) NEW="$MAJOR.$((MINOR + 1)).0" ;;
    major) NEW="$((MAJOR + 1)).0.0" ;;
    [0-9]*.[0-9]*.[0-9]*) NEW="$1" ;;
    *) echo "error: expected patch, minor, major or X.Y.Z" >&2; exit 1 ;;
esac
if git rev-parse "v$NEW" >/dev/null 2>&1; then
    echo "error: tag v$NEW already exists" >&2; exit 1
fi

# Warn if nothing was noted under Unreleased.
if ! awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f && /[^[:space:]]/{found=1} END{exit !found}' CHANGELOG.md; then
    echo "warning: CHANGELOG.md has no notes under [Unreleased]; this release will have empty notes." >&2
fi

TODAY=$(date +%Y-%m-%d)
echo "$NEW" > VERSION

# Changelog: keep an empty Unreleased section, put its notes under the new version, add compare links.
python3 - "$CURRENT" "$NEW" "$TODAY" <<'PY'
import re, sys
current, new, today = sys.argv[1:]
path = "CHANGELOG.md"
text = open(path).read()
text = text.replace("## [Unreleased]\n", f"## [Unreleased]\n\n## [{new}] - {today}\n", 1)
repo = "https://github.com/Synced-Co/clarishot"
text = re.sub(r"\[Unreleased\]: .*", f"[Unreleased]: {repo}/compare/v{new}...HEAD\n[{new}]: {repo}/compare/v{current}...v{new}", text, count=1)
open(path, "w").write(text)
# Notes for this release only, for the GitHub release page.
section = text.split(f"## [{new}] - {today}\n", 1)[1].split("\n## [", 1)[0].strip()
open("build/release-notes.md" if __import__("os").path.isdir("build") else "release-notes.tmp", "w").write(section + "\n")
PY
mkdir -p build
[ -f release-notes.tmp ] && mv release-notes.tmp build/release-notes.md

git add VERSION CHANGELOG.md
git commit -q -m "Release v$NEW"
git tag -a "v$NEW" -m "Clarishot $NEW"

INSTALL=0 ./scripts/build-app.sh
rm -f "build/Clarishot-$NEW.zip"
ditto -c -k --keepParent build/Clarishot.app "build/Clarishot-$NEW.zip"

echo
echo "Released v$NEW (not pushed yet)."
echo "  git push && git push --tags"
echo "  gh release create v$NEW build/Clarishot-$NEW.zip --title \"Clarishot $NEW\" --notes-file build/release-notes.md"
