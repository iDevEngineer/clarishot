# Changelog

All notable changes to Clarishot are listed here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[semantic versioning](https://semver.org).

## [Unreleased]

### Fixed
- Wallpaper backgrounds came out black on recent macOS: an invisible Dock window was captured instead of the picture.

### Changed
- Uses about 60% less memory at rest: the live wallpaper is kept compressed, and large decoded images are freed after a minute idle.

### Added
- Menu-bar menu: icons for Quit and Preferences.

## [0.2.1] - 2026-10-15

### Added
- Menu-bar menu: icons for About, Check for Updates and Setup Guide.

## [0.2.0] - 2026-10-15

### Added
- Crosshair cursor options in Preferences → General → Appearance: shape, size and colour, with a preview.

### Changed
- Licence changed from MIT to GPL-3.0 (earlier releases stay MIT).
- About: the website link now goes to scottmackey.uk.

## [0.1.1] - 2026-10-15

### Added
- Automatic updates (Check for Updates… in the menu and About; daily checks, optional auto-install), and notarised release builds.
- First-run setup guide: welcome, permissions with live status and Allow buttons, shortcuts, launch at login.
- Draw on screen while recording (⌥⇧⌘D): pen, highlighter, arrow, rectangle, colours, fade, undo and clear.
- Zoom editor: zooms can follow the cursor, panning smoothly along the recorded pointer path.
- Zoom editor for recordings: automatic zooms at your clicks, a timeline to move, resize, add and aim them, and export.
- Annotate asks to save before closing with unsaved edits.
- Annotate: copy (⌘C), paste (⌘V) and duplicate (⌘D) shapes.
- Annotate: re-editable `.clarishot` project files (⌥⌘S), opened from Open… or Finder.
- Capture Menu or Popover (⌥⇧⌘M): captures an open menu, submenus or menu-bar popover.
- Preview card: swipe toward the edge to dismiss; file info (pixels, format, file size) on hover.
- Annotate: properties bar for the current tool or selected shape.
- Arrows: classic, tapered and outlined looks; arrowheads or dots on either end; dashed and dotted lines;
  a draggable bend handle for curved arrows; draggable end points.
- Watermark tool (W): single, diagonal or tiled text with size, opacity, rotation and colour.
- Editor layout: Add screenshot, canvas lock, zoom, Drag Me, share, pin, undo and redo buttons.
- Background tool is now a left sidebar: presets, gradients, wallpapers (add your own), blurred
  wallpapers, plain colours, padding, inset, shadow, corners, alignment and ratio.
- 20 soft multi-colour "mesh" gradient backgrounds.
- Auto-balance: centres a screenshot's content on the background, ignoring empty space at its edges.

### Fixed
- Curved tapered arrows now taper from a thin tail to a thick head.
- Annotate opens with the Select tool instead of Arrow.
- A new background starts with no padding, corners or shadow (choosing a fill adds some padding).
- The background custom-colour picker no longer closes while you adjust it.
- Background sidebar: sliders no longer jump when picking a colour; alignment now places the
  screenshot flush against the chosen edge or corner, with icons showing each position.

## [0.1.0] - 2026-10-14

First public release.

### Added
- Screenshots: area, window, fullscreen, previous area, All-In-One, Smart Capture, scrolling capture,
  object cutout, Capture & Annotate, self-timer, text recognition (OCR) and QR codes.
- Output as PNG, JPEG, WebP or AVIF; window and fullscreen captures on the wallpaper.
- Preview card, pinned screenshots (paste, lock, resize) and Capture History with source-app icons.
- Annotate editor: shapes, arrows, text styles, highlighter, counters, blur, pixelate, spotlight,
  Hide Sensitive Info, Remove Background, crop with snapping, rotate and flip, backgrounds and presets.
- Screen recording to video or GIF with system audio, microphone, camera bubble, click highlights,
  keystrokes, pause, restart, countdown and trimming.
- Preferences with themes, optional Liquid Glass, and every shortcut configurable.
- MCP server and `clarishot` command-line tool for AI tools and scripts; `clarishot://` links.

[Unreleased]: https://github.com/iDevEngineer/clarishot/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/iDevEngineer/clarishot/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/iDevEngineer/clarishot/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/iDevEngineer/clarishot/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/iDevEngineer/clarishot/releases/tag/v0.1.0
