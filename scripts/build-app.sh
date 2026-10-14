#!/bin/bash
# Builds Clarishot and wraps it into build/Clarishot.app.
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

APP=build/Clarishot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Clarishot "$APP/Contents/MacOS/Clarishot"
# Command-line tool + MCP server for AI tools.
mkdir -p "$APP/Contents/Helpers"
cp .build/release/ClarishotCLI "$APP/Contents/Helpers/clarishot"
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/clarishot"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# WebP encoder: Google's libwebp (BSD licence), copied from Homebrew if installed.
WEBP_LIB=/opt/homebrew/opt/webp/lib
if [ -f "$WEBP_LIB/libwebp.7.dylib" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp "$WEBP_LIB/libwebp.7.dylib" "$WEBP_LIB/libsharpyuv.0.dylib" "$APP/Contents/Frameworks/"
    chmod u+w "$APP/Contents/Frameworks/"*.dylib
    install_name_tool -id @rpath/libsharpyuv.0.dylib "$APP/Contents/Frameworks/libsharpyuv.0.dylib"
    install_name_tool -id @rpath/libwebp.7.dylib "$APP/Contents/Frameworks/libwebp.7.dylib"
    install_name_tool -change @rpath/libsharpyuv.0.dylib @loader_path/libsharpyuv.0.dylib \
        "$APP/Contents/Frameworks/libwebp.7.dylib"
    # Refuse to ship a library that still points outside the app (e.g. into /opt/homebrew).
    if otool -L "$APP/Contents/Frameworks/"*.dylib | grep -q "/opt/homebrew"; then
        echo "error: bundled WebP library still links to /opt/homebrew" >&2
        exit 1
    fi
    for lib in "$APP/Contents/Frameworks/"*.dylib; do codesign --force --sign "$SIGN_IDENTITY" "$lib"; done
fi

# App icon: the artwork in Resources/Brand if present, otherwise drawn by the app (AppIcon.swift).
ICONSET=.build/Clarishot.iconset
rm -rf "$ICONSET"
ART=Resources/Brand/clarishot-icon.png
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
    .build/release/Clarishot --write-iconset "$ICONSET"
fi
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$SIGN_IDENTITY" "$APP"

echo "Built $APP"
