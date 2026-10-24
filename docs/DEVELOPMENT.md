# Developer guide

Clarishot is a Swift Package with two executables: the menu-bar app and the `clarishot` command-line
tool. There's no Xcode project; a script wraps the build into a signed `.app`.

- [Building](#building)
- [Project layout](#project-layout)
- [How the main pieces work](#how-the-main-pieces-work)
- [Conventions](#conventions)
- [Versions and releases](#versions-and-releases)

## Building

Requirements: macOS 14 or later to run; **Xcode 26** (or its command-line tools) to build, because the
code uses the macOS 26 SDK (Liquid Glass) behind availability checks.

```bash
./scripts/build-app.sh
```

This runs `swift build -c release`, assembles `build/Clarishot.app`, signs it, and copies it to
`/Applications/Clarishot.app` (quitting any running copy first).

| Variable | Effect |
|---|---|
| `INSTALL=0` | Build `build/Clarishot.app` only; don't touch `/Applications` |
| `SIGN_IDENTITY="Name"` | Sign with this certificate (default: a local development certificate if present, else ad-hoc) |

For quick compile checks, `swift build` is enough.

### Signing and permissions

macOS ties Screen Recording and Accessibility permission to the app's signature. With **ad-hoc**
signing (`-`), every build counts as a new app and macOS asks for permission again. Create a
self-signed code-signing certificate in Keychain Access (Certificate Assistant → Create a Certificate,
type *Code Signing*) and pass its name as `SIGN_IDENTITY`, or edit `DEFAULT_IDENTITY` in the script.

If permission prompts keep returning:

```bash
tccutil reset ScreenCapture com.scottmackey.clarishot
```

### WebP

macOS can read WebP but not write it. The first build downloads Google's `libwebp` (BSD licence)
source, checks its SHA-256, builds it for Apple silicon and Intel, and caches it in
`.build/libwebp-<version>`. It goes into `Contents/Frameworks` and Clarishot loads it from there only.
To build offline without it, run with `WEBP=0`; WebP is then left out of the format list.

### Handy launch options

```bash
open /Applications/Clarishot.app --args --settings screenshots   # open a Preferences tab
open /Applications/Clarishot.app --args --settings general --width 1200
```

## Project layout

```
Package.swift                 Two targets: Clarishot (app) and ClarishotCLI (clarishot command)
Resources/Info.plist          Bundle ID, version, permission texts, clarishot:// scheme
Resources/Brand/              App icon artwork (turned into AppIcon.icns at build time)
scripts/build-app.sh          Build, bundle, sign, install
scripts/release.sh            Bump the version, update the changelog, tag
scripts/perf.sh               Measure capture speed, idle cost, memory and leaks (build/perf/)
VERSION                       The current version number

Sources/Clarishot/
  main.swift, AppDelegate.swift      Launch, migration from the old name, menu bar setup
  StatusMenuController.swift         Menu-bar icon and menu
  Shortcuts.swift                    Global shortcuts (Carbon hotkeys) and their actions
  CaptureCoordinator.swift           Every screenshot mode, start to finish; after-capture actions
  SelectionOverlay.swift             Frozen-screen overlay: area, window, All-In-One bar, scrolling area
  SmartCapture.swift                 Live element picker using the Accessibility API
  ScreenCapturer.swift               ScreenCaptureKit captures and cropping
  Capture.swift                      A captured image or recording: naming, saving, clipboard
  ImageEncoder.swift                 PNG / JPEG / WebP / AVIF
  ImageTools.swift                   Background removal and sensitive-info detection (Vision)
  TextRecognizer.swift               OCR and QR codes (Vision)
  PreviewCard.swift                  The corner preview cards
  PinWindow.swift                    Floating pinned screenshots
  Appearance.swift, RoundedWindow.swift   Theme, Liquid Glass surfaces, window shape
  Annotate/                          Editor window, canvas, shapes, backgrounds, snapping
  Recording/                         Recording panel, recorder, overlays (camera, clicks, keys), trim
  Scrolling/                         Scrolling capture and the image stitcher
  History/                           Capture History store and strip
  Settings/                          Preferences store and window
  Agent/                             Local socket server and the actions behind the CLI / MCP

Sources/ClarishotCLI/main.swift      `clarishot` command and the MCP server
```

## How the main pieces work

**Capturing.** `ScreenCapturer.captureAllScreens()` grabs every display with ScreenCaptureKit, leaving
out Clarishot's own windows. Area modes show these frozen images in `SelectionOverlay`, so what you
select is exactly what you get, then crop them. Everything ends in `CaptureCoordinator.deliver(_:)`,
which applies the After Capture settings (preview card, copy, save, annotate, pin).

**Smart Capture** asks the app under the pointer for the accessibility element at that point
(`AXUIElementCopyElementAtPosition`), walks up its parents to build a chain of frames, and draws the
selected one on a clear overlay. Clicking captures that frame from a fresh screenshot.

**Scrolling capture** grabs the area repeatedly while you scroll and `ScrollStitcher` finds how far
each frame moved by comparing rows, appending only the new strip. Scrolling back up trims the result.

**Recording** uses `SCRecordingOutput` (macOS 15+). Pause and restart are implemented by recording
segments and joining them when you stop. GIFs are made from the finished movie.

**Annotate.** `AnnotateDocument` holds the picture, the list of shapes, the crop and undo history.
`CanvasView` handles input and draws; `AnnotationRenderer` draws the same shapes when exporting, so
the saved file matches the screen.

**Preferences** are plain `UserDefaults` values in `Settings`, which posts `Settings.didChange` on every
change. Recording options live in `RecordingOptions` (saved as one dictionary).

**AI and CLI access.** See [AI tools & command line](AI_AND_CLI.md#how-it-works).

## Conventions

- AppKit throughout, `@MainActor` for UI types. Heavy work (Vision, encoding) runs off the main thread.
- Match the surrounding code: short doc comments that say *why*, no large frameworks.
- User-facing text is plain English; Preferences rows get an icon via `PreferenceIcons`.
- Keep user data on the Mac. No network calls, analytics or accounts.

## Versions and releases

Clarishot uses [semantic versioning](https://semver.org): `MAJOR.MINOR.PATCH`.

- The version lives in `VERSION`. The build script writes it into the app's `Info.plist`, and uses the
  number of commits as the build number, so you never edit `Info.plist` by hand.
- Changes are listed in [`CHANGELOG.md`](../CHANGELOG.md) under **Unreleased** as you go.

To release:

```bash
./scripts/release.sh patch     # or: minor, major, or an exact version such as 1.2.0
git push && git push --tags
```

Before it changes anything, `release.sh` builds the app and runs `scripts/perf.sh --check`, which fails if
the overlay or preview card got slower, a hang or new leak appeared, or idle CPU rose (the screen
flashes for a few minutes; skip with `SKIP_PERF=1`). Then it bumps `VERSION`, moves the **Unreleased**
notes into a dated section, commits, and creates
a `vX.Y.Z` tag. It also builds `build/Clarishot-X.Y.Z.zip` and the update feed `build/appcast.xml`,
ready to attach to a GitHub release:

```bash
gh release create vX.Y.Z build/Clarishot-X.Y.Z.zip build/appcast.xml --notes-file build/release-notes.md
./scripts/update-tap.sh X.Y.Z   # points the Homebrew cask at the new release
```

### Notarisation and auto-updates

- **Auto-updates** use [Sparkle](https://sparkle-project.org). The app checks
  `releases/latest/download/appcast.xml` once a day, so the repo must be public for updates to reach
  anyone. Each zip is signed with an update key kept in the login keychain (account `clarishot`); its
  public half is `SUPublicEDKey` in `Info.plist`. Back the private key up with
  `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account clarishot -x <file>` and store that
  file somewhere safe: without it, existing installs can't accept new updates.
- **Notarisation** happens automatically when a "Developer ID Application" certificate is in the
  keychain. One-time setup:
  1. Join the Apple Developer Program and create a **Developer ID Application** certificate in Xcode
     (Settings → Accounts → Manage Certificates).
  2. Save notary credentials: `xcrun notarytool store-credentials clarishot` (Apple ID, team ID and an
     app-specific password from appleid.apple.com).

  `release.sh` then signs with the hardened runtime, submits to Apple, staples the ticket and
  checks the result with `spctl`. Without the certificate it stops before tagging, because macOS
  would block the download; run with `ALLOW_UNNOTARISED=1` to ship an un-notarised build anyway.
