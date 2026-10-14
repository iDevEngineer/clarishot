# Clarishot user guide

Clarishot runs from the menu bar (the shutter icon). Everything below is also in that menu.
Shortcuts are the defaults; change them in **Preferences → Shortcuts**.

- [Getting started](#getting-started)
- [Taking screenshots](#taking-screenshots)
- [After a capture](#after-a-capture)
- [Annotating](#annotating)
- [Recording the screen](#recording-the-screen)
- [Capture History](#capture-history)
- [Preferences](#preferences)
- [Troubleshooting](#troubleshooting)

## Getting started

1. Open Clarishot from `/Applications`. The **setup guide** opens.
2. On **A few permissions**, click **Allow…** next to Screen Recording and turn Clarishot on in System
   Settings, then click **Restart**. The guide reopens where you left off with a green tick.
   Accessibility, Microphone and Camera are optional; each row says what it switches on.
3. Check your shortcuts, choose whether Clarishot opens at login, and click **Start Using Clarishot**.
4. Press **⌥⇧⌘4** and drag across part of the screen. A preview card appears in the bottom-left corner.

Reopen the guide any time from **Setup Guide…** in the menu-bar menu.

## Taking screenshots

### Capture Area (⌥⇧⌘4)
Drag across the screen. While dragging:
- Hold **Space** to move the selection without resizing it.
- Hold **Shift** when drawing shapes later in Annotate to keep them straight.
- Press **Esc** to cancel.

### Capture Window (⌥⇧⌘5)
The pointer becomes a camera. Hover a window to highlight it, then click. Window captures are placed on
your wallpaper with padding and a shadow by default. Change this in **Preferences → Screenshots →
Window Screenshots**.

### Capture Fullscreen (⌥⇧⌘3)
Captures the screen the pointer is on, placed on your wallpaper (turn this off in **Preferences →
Screenshots**).

### Capture Previous Area (⌥⇧⌘6)
Captures the same area as last time, with no selecting. Remembered across restarts.

### All-In-One (⌥⇧⌘A)
Drag an area (or adjust the last one), then choose from the bar underneath: **Area, Fullscreen, Window,
Smart, Scrolling, Timer, OCR, Recording**. The right-hand panel lets you type an exact size or pick an
aspect ratio.

### Smart Capture (⌥⇧⌘E)
Point at any part of an app (a button, toolbar, sidebar or dialog) and it gets a blue outline with a
label like *Button · 120 × 32*. Click to capture exactly that element.
- **↑** or scroll up: select the larger element around it.
- **↓** or scroll down: go back to the smaller one.
- **Esc** or clicking outside the outline cancels.

Needs **Accessibility** permission.

### Capture Menu or Popover (⌥⇧⌘M)
Open any menu, submenu or menu-bar popover, then press **⌥⇧⌘M**. Clarishot captures just that
menu (with any open submenus), without an overlay that would close it. From Clarishot's own menu
you get 3 seconds to reopen the menu you want.

### Scrolling Capture (⌥⇧⌘S)
1. Drag around only the part of the window that scrolls (leave out fixed headers and sidebars).
2. Click **Start Capture**.
3. Scroll slowly, or click **Auto-Scroll**. A preview grows beside the area. Scrolling back up trims the end.
4. Click **Done** (or press Return).

### Capture Object (⌥⇧⌘1)
Drag around something (a person, product or icon). Clarishot keeps only the main subject, on a
transparent background, cropped to fit.

### Capture & Annotate (⌥⇧⌘7)
Select an area and it opens straight in the editor. Click **Done** to run your usual after-capture actions.

### Capture Text (⌥⇧⌘2)
Drag over text. The text, and any QR code or barcode contents, are copied to the clipboard.
Choose the language and line-break behaviour in **Preferences → Advanced → Text Recognition**.

### Self-Timer (⌥⇧⌘T)
Drag an area and a countdown starts (red, then orange, then green at the last second). Set 3, 5, 10 or 15
seconds in **Preferences → Screenshots**.

## After a capture

### The preview card
A card appears in the corner (choose which in **Preferences → Quick Access**). Hover it to see:
- **Copy** and **Save** (pill buttons)
- **Annotate** (pencil), **Pin**, and **Close** in the corners
- File info at the top: size in pixels, format and file size
- Drag the card into any app to drop the image there.
- Swipe it toward the screen edge with two fingers to dismiss it.

The card can close by itself after a set time, optionally saving first.
**Restore Recently Closed** in the menu brings back the last card.

### Pinned screenshots
Pin a capture to float it above every window. Hover it for:
- **✕** (top-left) to close
- **Lock** (top-right): a locked pin can only be closed, not moved or pasted
- **Paste** (bottom): pastes the image into the app you were using
- Edges and bottom corners to resize

### Saving
Files go to the **Save location** in **Preferences → General → Storage** (Desktop by default), named like
`Clarishot 2026-10-14 at 09.41.07@2x.png`. Change the name pattern and format in **Preferences → Advanced**
and **Preferences → Screenshots**.

## Annotating

Open the editor from the preview card's pencil, from **Capture & Annotate**, or with **Open…** in the menu.

| Key | Tool |
|---|---|
| V | Select / move |
| C | Crop |
| R / F | Rectangle / filled rectangle |
| O | Ellipse |
| L | Line |
| A | Arrow (straight or curved: paintbrush menu) |
| T | Text (seven styles) |
| H | Highlighter |
| B | Pixelate |
| U | Blur |
| S | Spotlight |
| N | Counter (1, 2, 3…) |
| P | Pencil |
| W | Watermark (single, diagonal or tiled text) |

- **Undo / Redo**: ⌘Z / ⇧⌘Z. **Save**: ⌘S.
- **Copy**: ⌘C copies the selected shape, or the whole picture when nothing is selected.
  **Paste**: ⌘V pastes copied shapes (into this or another editor window). **Duplicate**: ⌘D.
- **Editable projects**: **Save as… → Save Editable Project…** (⌥⌘S) saves a `.clarishot` file.
  Open it later with **Open…** or by double-clicking it in Finder, and every shape, the crop and the
  background are still editable. Saving again writes to the same file.
- Closing the editor with edits you haven't saved, copied or pinned asks **Save**, **Don't Save** or
  **Cancel**. Save puts the image in your save location.
- **Double-click** text to edit it.
- **Colour**: the colour dot; includes an eyedropper and your recent colours.
- **Wand menu**: rotate, flip, **Remove Background**, **Hide Sensitive Info**.
- **Background** (frame icon): put the screenshot on a gradient, colour or your wallpaper, with padding,
  corners and shadow. Save a look as a preset and apply it to every screenshot automatically.

**Hide Sensitive Info** finds emails, phone numbers, IP addresses, card numbers, API keys, tokens, and
anything next to labels such as *Password*, *Username* or *PIN*, and covers each with a solid box.
The boxes are normal shapes you can move or delete. Always check the result before sharing.

**Snapping** (Preferences → Annotate): crop edges snap to borders in the picture, and highlighter strokes
started on text run straight along the line. Hold **⌘** while dragging to turn snapping off.

## Recording the screen

1. Press **⌥⇧⌘R** and drag an area (or press **Space** to pick a window).
2. A panel appears. Set the size, then turn on what you need:
   - **Microphone** (click to choose which one)
   - **Computer audio**
   - **Camera** (click for camera, size, shape, full screen and mirroring)
   - **Click highlights** and **keystrokes**
3. Click **Record Video** (Return) or **Record GIF** (⌥Return).
4. During recording, use the control bar under the area: **stop**, **pause** (⌥⇧⌘P), **restart** or
   **delete**. The menu-bar icon becomes a red stop button with a timer.
5. When you stop, a preview card appears. The scissors button trims the recording.

### Draw on screen
While recording, click the **pencil** on the control bar (or press **⌥⇧⌘D**) to draw over the
recorded area; the drawing is part of the video. A small toolbar (not recorded) has **pen**,
**highlighter**, **arrow** and **rectangle**, five colours, **fade** (strokes disappear after a few
seconds), **undo** (⌘Z), **clear** and **✓**. Press **Esc** or ✓ to go back to using your apps;
strokes stay on screen until you clear them (unless fade is on).

### Zooms
Click the **magnifying glass** on a recording's preview card (or **Edit Zooms…** in Capture
History's right-click menu). Clarishot noted every click you made while recording, and places a
2× zoom on each one, easing in and out.
- **Timeline:** zooms are blue bars; orange dots are your clicks. Drag a bar to move it, drag its
  ends to change its length, double-click empty space to add one.
- **Select a zoom** to set how far it zooms (1.25× to 3.5×) and to aim it: the preview shows the
  whole frame with the zoomed area outlined; click or drag to move it.
- **Follow cursor** (on for automatic zooms) pans the zoom smoothly after the pointer; the preview
  draws the path it will follow. Clicking to aim switches it off and holds the zoom still.
- **Play** (Space) shows the finished result. **Auto Zoom** puts back the zooms from your clicks.
- **Export** makes a new movie with the zooms and shows it on a preview card. The original stays
  as it was.

Recording options (frame rate, resolution, GIF size and quality, click-highlight look, keystroke style)
are in **Preferences → Screen Recording** or the sliders button on the recording panel.

## Capture History

**Capture History…** in the menu opens a strip of your recent captures across the top of the screen.
- Filter by **Screenshots**, **Recordings** or **GIFs**.
- Hover a capture and click **Restore** to bring back its preview card; right-click for more.
- The small icon on each shows the app it was taken from.
- Choose how long to keep history with the **…** menu or **Preferences → Advanced**.

## Preferences

Open with **Preferences…** in the menu (⌘,).

| Tab | Highlights |
|---|---|
| General | Launch at login, menu-bar icon, language, theme, Liquid Glass, sounds, save location, after-capture actions |
| Shortcuts | Change or turn off any shortcut; search the list |
| Quick Access | Card position, size, auto-close, save behaviour |
| Wallpaper | Use a custom picture instead of your desktop wallpaper |
| Screenshots | Format and quality, 1x scaling, sRGB, border, window background, crosshair and magnifier |
| Screen Recording | Everything about recordings, GIFs and click highlights |
| Annotate | Snapping, arrow direction, smoothing, shadows, window behaviour |
| Advanced | File names, clipboard format, history, text recognition, pins, AI access, `clarishot://` links |

If you hide the menu-bar icon, open Clarishot again from Finder to get back to Preferences.

## Troubleshooting

**macOS keeps asking for Screen Recording permission.**
Quit Clarishot, turn it off and on again in System Settings → Privacy & Security → Screen & System Audio
Recording, then reopen it. If you build it yourself, sign it with the same certificate every time (see the
[developer guide](DEVELOPMENT.md)).

**Smart Capture, Paste or keystrokes don't work.**
Turn Clarishot on in System Settings → Privacy & Security → **Accessibility**.

**A shortcut does nothing.**
Another app may use it. Change it in Preferences → Shortcuts.

**WebP isn't in the format list.**
The build couldn't find Google's WebP library. Run `brew install webp` and build again.
