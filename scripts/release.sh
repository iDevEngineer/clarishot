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
repo = "https://github.com/iDevEngineer/clarishot"
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

# Notarised releases need a "Developer ID Application" certificate in the keychain and notary
# credentials saved once with:  xcrun notarytool store-credentials clarishot
DEV_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
if [ -n "$DEV_ID" ]; then
    SIGN_IDENTITY="$DEV_ID" INSTALL=0 ./scripts/build-app.sh
else
    echo "warning: no Developer ID Application certificate; this build is NOT notarised and macOS will warn users." >&2
    INSTALL=0 ./scripts/build-app.sh
fi
ZIP="build/Clarishot-$NEW.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Clarishot.app "$ZIP"

if [ -n "$DEV_ID" ]; then
    echo "Notarising (usually a few minutes)…"
    xcrun notarytool submit "$ZIP" --keychain-profile clarishot --wait
    xcrun stapler staple build/Clarishot.app
    spctl --assess --type execute --verbose build/Clarishot.app
    # Re-zip so the download carries the stapled ticket.
    rm -f "$ZIP"
    ditto -c -k --keepParent build/Clarishot.app "$ZIP"
fi

# Sparkle feed: sign the zip with the update key (kept in the keychain, account "clarishot")
# and write build/appcast.xml, which the app reads from the latest GitHub release.
SIGNATURE=$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account clarishot "$ZIP")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" build/Clarishot.app/Contents/Info.plist)
python3 - "$NEW" "$BUILD_NUMBER" "$SIGNATURE" <<'PY'
import html, sys
from email.utils import formatdate
new, build, signature = sys.argv[1:]
notes = html.escape(open("build/release-notes.md").read())
url = f"https://github.com/iDevEngineer/clarishot/releases/download/v{new}/Clarishot-{new}.zip"
open("build/appcast.xml", "w").write(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Clarishot</title>
    <item>
      <title>Clarishot {new}</title>
      <pubDate>{formatdate(localtime=False, usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{new}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description sparkle:format="plain-text">{notes}</description>
      <enclosure url="{url}" type="application/octet-stream" {signature}/>
    </item>
  </channel>
</rss>
""")
PY

echo
echo "Released v$NEW (not pushed yet)."
echo "  git push && git push --tags"
echo "  gh release create v$NEW build/Clarishot-$NEW.zip build/appcast.xml --title \"Clarishot $NEW\" --notes-file build/release-notes.md"
