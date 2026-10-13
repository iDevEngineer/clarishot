#!/bin/bash
# Builds Snapzy and wraps it into build/Snapzy.app.
# Signing with a stable identity keeps the Screen Recording permission across
# rebuilds. Override with SIGN_IDENTITY; falls back to ad-hoc ("-") if the
# default certificate is missing.
set -euo pipefail
cd "$(dirname "$0")/.."

DEFAULT_IDENTITY="WhisperDictation Dev"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    if security find-identity -v -p codesigning | grep -q "$DEFAULT_IDENTITY"; then
        SIGN_IDENTITY="$DEFAULT_IDENTITY"
    else
        SIGN_IDENTITY="-"
    fi
fi

swift build -c release

APP=build/Snapzy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Snapzy "$APP/Contents/MacOS/Snapzy"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "$SIGN_IDENTITY" "$APP"

echo "Built $APP"
