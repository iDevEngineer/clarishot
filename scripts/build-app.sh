#!/bin/bash
# Builds Clarishot and wraps it into build/Clarishot.app.
# Signing with a stable identity keeps the Screen Recording permission across
# rebuilds. Override with SIGN_IDENTITY; falls back to ad-hoc ("-") if the
# default certificate is missing. With a "Developer ID Application" identity the
# app is signed for notarisation (hardened runtime + entitlements, secure timestamp).
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

# Hardened runtime and a secure timestamp are what Apple's notary service requires.
SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" == Developer\ ID* ]]; then
    SIGN_FLAGS+=(--options runtime --timestamp)
fi
sign() { codesign "${SIGN_FLAGS[@]}" "$@"; }

APP=build/Clarishot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Clarishot "$APP/Contents/MacOS/Clarishot"
# Command-line tool + MCP server for AI tools.
mkdir -p "$APP/Contents/Helpers"
cp .build/release/ClarishotCLI "$APP/Contents/Helpers/clarishot"
sign "$APP/Contents/Helpers/clarishot"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Version from VERSION; build number = number of commits, so each build is higher than the last.
VERSION=$(tr -d '[:space:]' < VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

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
    for lib in "$APP/Contents/Frameworks/"*.dylib; do sign "$lib"; done
fi

# Sparkle (auto-updates). Its helpers are signed inside-out, as Sparkle's docs describe.
SPARKLE=$(find .build/artifacts -path "*macos-arm64_x86_64/Sparkle.framework" -maxdepth 6 | head -1)
if [ -z "$SPARKLE" ]; then echo "error: Sparkle.framework not found; run swift package resolve" >&2; exit 1; fi
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$FW/XPCServices/Installer.xpc" "$FW/XPCServices/Downloader.xpc" "$FW/Autoupdate" "$FW/Updater.app"; do
    [ -e "$item" ] && sign "$item"
done
sign "$APP/Contents/Frameworks/Sparkle.framework"

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
sign --entitlements Resources/Clarishot.entitlements "$APP"

echo "Built $APP ($VERSION, build $BUILD)"

# Keep /Applications/Clarishot.app in step with every build (skip with INSTALL=0).
if [ "${INSTALL:-1}" = "1" ]; then
    pkill -x Clarishot 2>/dev/null || true
    rm -rf /Applications/Clarishot.app
    ditto "$APP" /Applications/Clarishot.app
    echo "Installed /Applications/Clarishot.app"
fi
