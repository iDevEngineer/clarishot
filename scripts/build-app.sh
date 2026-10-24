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

# Universal binary, so the app runs on both Apple silicon and Intel Macs.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN=$(swift build -c release "${ARCHS[@]}" --show-bin-path)

# Hardened runtime and a secure timestamp are what Apple's notary service requires.
SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" == Developer\ ID* ]]; then
    SIGN_FLAGS+=(--options runtime --timestamp)
fi
sign() { codesign "${SIGN_FLAGS[@]}" "$@"; }

APP=build/Clarishot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Clarishot" "$APP/Contents/MacOS/Clarishot"
# Command-line tool + MCP server for AI tools.
mkdir -p "$APP/Contents/Helpers"
cp "$BIN/ClarishotCLI" "$APP/Contents/Helpers/clarishot"
sign "$APP/Contents/Helpers/clarishot"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Version from VERSION; build number = number of commits, so each build is higher than the last.
VERSION=$(tr -d '[:space:]' < VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

# WebP encoder: Google's libwebp (BSD licence), built from source once for both Mac chips and the
# app's minimum macOS, then cached in .build. Skip with WEBP=0 (the app then hides the WebP option).
WEBP_VERSION=1.6.0
WEBP_SHA256=e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
WEBP_DIR="$PWD/.build/libwebp-$WEBP_VERSION"
WEBP_LIB="$WEBP_DIR/universal"
build_webp() {
    local work="$WEBP_DIR/work" tarball="$WEBP_DIR/libwebp-$WEBP_VERSION.tar.gz"
    local sdk minos
    sdk=$(xcrun --sdk macosx --show-sdk-path)
    minos=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Resources/Info.plist)
    rm -rf "$work" && mkdir -p "$work/src"
    [ -f "$tarball" ] || curl -fsSL -o "$tarball" \
        "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$WEBP_VERSION.tar.gz"
    if ! echo "$WEBP_SHA256  $tarball" | shasum -a 256 -c - >/dev/null; then
        rm -f "$tarball"; echo "error: libwebp download does not match its checksum" >&2; exit 1
    fi
    tar -xzf "$tarball" -C "$work/src" --strip-components 1
    for arch in arm64 x86_64; do
        local host=$([ "$arch" = arm64 ] && echo aarch64-apple-darwin || echo x86_64-apple-darwin)
        local flags="-arch $arch -isysroot $sdk -mmacosx-version-min=$minos"
        local prefix="$work/out-$arch"
        mkdir -p "$work/build-$arch"
        # Unset INSTALL: autoconf reads it as the install program, but here it means "copy to /Applications".
        (unset INSTALL; cd "$work/build-$arch" && ../src/configure --host="$host" --prefix="$prefix" \
            --disable-static --disable-libwebpmux --disable-libwebpdemux --disable-libwebpdecoder \
            --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic --disable-sdl --disable-gl \
            CC="$(xcrun --find clang)" CFLAGS="$flags -O2" LDFLAGS="$flags" && make -j8 install) \
            > "$work/build-$arch.log" 2>&1 || { echo "error: libwebp build failed, see $work/build-$arch.log" >&2; exit 1; }
        # Load from inside the app, never from the folder it was built in.
        install_name_tool -id @rpath/libsharpyuv.0.dylib "$prefix/lib/libsharpyuv.0.dylib"
        install_name_tool -id @rpath/libwebp.7.dylib \
            -change "$prefix/lib/libsharpyuv.0.dylib" @loader_path/libsharpyuv.0.dylib "$prefix/lib/libwebp.7.dylib"
    done
    mkdir -p "$work/universal"
    for lib in libwebp.7.dylib libsharpyuv.0.dylib; do
        lipo -create "$work/out-arm64/lib/$lib" "$work/out-x86_64/lib/$lib" -output "$work/universal/$lib"
    done
    rm -rf "$WEBP_LIB" && mv "$work/universal" "$WEBP_LIB" && rm -rf "$work"
}
if [ "${WEBP:-1}" = "1" ]; then
    [ -f "$WEBP_LIB/libwebp.7.dylib" ] || build_webp
    mkdir -p "$APP/Contents/Frameworks"
    cp "$WEBP_LIB/libwebp.7.dylib" "$WEBP_LIB/libsharpyuv.0.dylib" "$APP/Contents/Frameworks/"
    # Refuse to ship a library that links to anything outside the app and macOS.
    if otool -L "$APP/Contents/Frameworks/"lib*.dylib | grep -v ':$' | grep -vqE '^\s+(@rpath|@loader_path|/usr/lib|/System)/'; then
        echo "error: bundled WebP library links to a path outside the app" >&2
        exit 1
    fi
    for lib in "$APP/Contents/Frameworks/"lib*.dylib; do sign "$lib"; done
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
    "$BIN/Clarishot" --write-iconset "$ICONSET"
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
