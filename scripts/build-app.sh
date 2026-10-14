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

# App icon: the artwork in Resources/Brand if present, otherwise drawn by the app (AppIcon.swift).
ICONSET=.build/Snapzy.iconset
rm -rf "$ICONSET"
ART=Resources/Brand/snapzy-icon.png
if [ -f "$ART" ]; then
    mkdir -p "$ICONSET"
    # Shrink to ~86% on a transparent canvas to match the macOS icon grid margins.
    MASTER=.build/icon-master.png
    sips -Z 880 "$ART" --out "$MASTER" >/dev/null
    sips --padToHeightWidth 1024 1024 "$MASTER" --out "$MASTER" >/dev/null
    for base in 16 32 128 256 512; do
        sips -z $base $base "$MASTER" --out "$ICONSET/icon_${base}x${base}.png" >/dev/null
        sips -z $((base * 2)) $((base * 2)) "$MASTER" --out "$ICONSET/icon_${base}x${base}@2x.png" >/dev/null
    done
else
    .build/release/Snapzy --write-iconset "$ICONSET"
fi
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$SIGN_IDENTITY" "$APP"

echo "Built $APP"
