import AppKit
import ServiceManagement

/// App-wide preferences, saved in UserDefaults. Posts `Settings.didChange` on every change.
@MainActor
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("ClarishotSettingsDidChange")

    private let defaults = UserDefaults.standard

    enum ImageFormat: String, CaseIterable {
        case png, jpeg, webp, avif
        var title: String { rawValue.uppercased() == "WEBP" ? "WebP" : rawValue.uppercased() }
        var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
        /// Formats with a quality setting.
        var isLossy: Bool { self != .png }
    }

    enum WindowStyle: String, CaseIterable {
        case transparent, shadow, background
        var title: String {
            switch self {
            case .transparent: return "Transparent"
            case .shadow: return "With shadow"
            case .background: return "On wallpaper"
            }
        }
    }

    enum PreviewPosition: String, CaseIterable {
        case bottomLeft, bottomRight, topLeft, topRight
        var title: String {
            switch self {
            case .bottomLeft: return "Bottom Left"
            case .bottomRight: return "Bottom Right"
            case .topLeft: return "Top Left"
            case .topRight: return "Top Right"
            }
        }
    }

    // MARK: General

    var playSounds: Bool {
        get { bool("playSounds", default: true) }
        set { set(newValue, "playSounds") }
    }

    /// Where screenshots and recordings are saved. Defaults to the Desktop.
    var exportFolder: URL {
        get {
            if let path = defaults.string(forKey: "exportFolder") { return URL(fileURLWithPath: path, isDirectory: true) }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        set { set(newValue.path, "exportFolder") }
    }

    var exportFolderIsDefault: Bool { defaults.string(forKey: "exportFolder") == nil }

    /// File name templates. `{date}` and `{time}` are filled in.
    var screenshotNameTemplate: String {
        get { defaults.string(forKey: "screenshotName") ?? "Clarishot {date} at {time}" }
        set { set(newValue, "screenshotName") }
    }

    var recordingNameTemplate: String {
        get { defaults.string(forKey: "recordingName") ?? "Clarishot Recording {date} at {time}" }
        set { set(newValue, "recordingName") }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSAlert(error: error).runModal()
            }
            notify()
        }
    }

    // MARK: Screenshots

    var imageFormat: ImageFormat {
        get { ImageFormat(rawValue: defaults.string(forKey: "imageFormat") ?? "") ?? .png }
        set { set(newValue.rawValue, "imageFormat") }
    }

    /// JPEG quality, 0.1–1.
    var jpegQuality: Double {
        get { defaults.object(forKey: "jpegQuality") as? Double ?? 0.85 }
        set { set(newValue, "jpegQuality") }
    }

    var scaleScreenshotsTo1x: Bool {
        get { bool("scaleScreenshotsTo1x", default: false) }
        set { set(newValue, "scaleScreenshotsTo1x") }
    }

    /// How window captures look: just the window, with a soft shadow, or on the wallpaper.
    var windowStyle: WindowStyle {
        get { WindowStyle(rawValue: defaults.string(forKey: "windowStyle") ?? "") ?? .background }
        set { set(newValue.rawValue, "windowStyle") }
    }

    /// Name of a background preset to add to every new screenshot, or nil.
    var autoBackgroundPreset: String? {
        get { defaults.string(forKey: "autoBackgroundPreset") }
        set {
            if let newValue { defaults.set(newValue, forKey: "autoBackgroundPreset") } else { defaults.removeObject(forKey: "autoBackgroundPreset") }
            notify()
        }
    }

    /// Capture Text: keep each line on its own line (otherwise lines in a paragraph are joined).
    var keepLineBreaks: Bool {
        get { bool("keepLineBreaks", default: true) }
        set { set(newValue, "keepLineBreaks") }
    }

    /// Full-screen captures: place the screenshot on the wallpaper with padding and a shadow.
    var fullscreenOnWallpaper: Bool {
        get { bool("fullscreenOnWallpaper", default: true) }
        set { set(newValue, "fullscreenOnWallpaper") }
    }

    var showMagnifier: Bool {
        get { bool("showMagnifier", default: true) } // only shown in Crosshair Mode
        set { set(newValue, "showMagnifier") }
    }

    /// Seconds the self-timer waits before capturing.
    var selfTimerSeconds: Int {
        get { defaults.object(forKey: "selfTimerSeconds") as? Int ?? 5 }
        set { set(newValue, "selfTimerSeconds") }
    }

    var showCursorInScreenshots: Bool {
        get { bool("showCursorInScreenshots", default: false) }
        set { set(newValue, "showCursorInScreenshots") }
    }

    // After-capture actions (at least one should be on).
    var afterCaptureShowPreview: Bool {
        get { bool("afterShowPreview", default: true) }
        set { set(newValue, "afterShowPreview") }
    }

    var afterCaptureCopy: Bool {
        get { bool("afterCopy", default: false) }
        set { set(newValue, "afterCopy") }
    }

    var afterCaptureSave: Bool {
        get { bool("afterSave", default: false) }
        set { set(newValue, "afterSave") }
    }

    var afterCaptureAnnotate: Bool {
        get { bool("afterAnnotate", default: false) }
        set { set(newValue, "afterAnnotate") }
    }

    // MARK: Quick Access (preview card)

    var previewPosition: PreviewPosition {
        get { PreviewPosition(rawValue: defaults.string(forKey: "previewPosition") ?? "") ?? .bottomLeft }
        set { set(newValue.rawValue, "previewPosition") }
    }

    /// Seconds before the card closes by itself; 0 = never.
    var previewAutoClose: Int {
        get { defaults.object(forKey: "previewAutoClose") as? Int ?? 0 }
        set { set(newValue, "previewAutoClose") }
    }

    var previewOnActiveScreen: Bool {
        get { bool("previewOnActiveScreen", default: true) }
        set { set(newValue, "previewOnActiveScreen") }
    }

    var closePreviewAfterDragging: Bool {
        get { bool("closePreviewAfterDragging", default: true) }
        set { set(newValue, "closePreviewAfterDragging") }
    }

    // MARK: Recording

    var showRecordingTimeInMenuBar: Bool {
        get { bool("recordingTimeInMenuBar", default: true) }
        set { set(newValue, "recordingTimeInMenuBar") }
    }

    // MARK: History

    /// Days of capture history to keep; 0 = off.
    var historyDays: Int {
        get { defaults.object(forKey: "historyDays") as? Int ?? 30 }
        set { set(newValue, "historyDays"); HistoryStore.shared.prune() }
    }

    var showControlsWhileRecording: Bool {
        get { bool("controlsWhileRecording", default: true) }
        set { set(newValue, "controlsWhileRecording") }
    }

    // MARK: Wallpaper

    /// Custom picture used to hide desktop icons and for the "wallpaper" background. nil = desktop picture.
    var customWallpaper: URL? {
        get { defaults.string(forKey: "customWallpaper").map { URL(fileURLWithPath: $0) } }
        set {
            if let newValue { defaults.set(newValue.path, forKey: "customWallpaper") } else { defaults.removeObject(forKey: "customWallpaper") }
            notify()
        }
    }

    // MARK: Shortcuts

    /// The shortcut for an action: the user's choice, else the default. nil = turned off.
    func shortcut(for action: ShortcutAction) -> Shortcut? {
        guard let stored = defaults.dictionary(forKey: "shortcuts")?[action.rawValue] as? [String: Any] else {
            return action.defaultShortcut
        }
        if stored["none"] as? Bool == true { return nil }
        guard let code = stored["keyCode"] as? Int, let flags = stored["modifiers"] as? Int,
              let key = stored["key"] as? String else { return action.defaultShortcut }
        return Shortcut(key: key, keyCode: UInt32(code), modifiers: NSEvent.ModifierFlags(rawValue: UInt(flags)))
    }

    func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) {
        var all = defaults.dictionary(forKey: "shortcuts") ?? [:]
        if let shortcut {
            all[action.rawValue] = ["keyCode": Int(shortcut.keyCode), "modifiers": Int(shortcut.modifiers.rawValue),
                                    "key": shortcut.key]
        } else {
            all[action.rawValue] = ["none": true]
        }
        defaults.set(all, forKey: "shortcuts")
        notify()
    }

    func resetShortcuts() {
        defaults.removeObject(forKey: "shortcuts")
        notify()
    }

    // MARK: Added to match the full Settings window

    var theme: AppAppearance.Theme {
        get { AppAppearance.Theme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system }
        set { set(newValue.rawValue, "theme") }
    }

    /// Liquid Glass for floating bars and panels (macOS 26+).
    var liquidGlass: Bool {
        get { bool("liquidGlass", default: false) }
        set { set(newValue, "liquidGlass") }
    }

    /// "" = follow the system; otherwise a language code. Takes effect after relaunch.
    var appLanguage: String {
        get { defaults.string(forKey: "appLanguage") ?? "" }
        set {
            defaults.set(newValue, forKey: "appLanguage")
            // AppleLanguages is what macOS reads at launch to pick the app's language.
            if newValue.isEmpty { defaults.removeObject(forKey: "AppleLanguages") } else { defaults.set([newValue], forKey: "AppleLanguages") }
            notify()
        }
    }

    var showMenuBarIcon: Bool {
        get { bool("showMenuBarIcon", default: true) }
        set { set(newValue, "showMenuBarIcon") }
    }

    /// Leave Finder's desktop icons out of screenshots.
    var hideDesktopIconsWhileCapturing: Bool {
        get { bool("hideIconsWhileCapturing", default: false) }
        set { set(newValue, "hideIconsWhileCapturing") }
    }

    /// "" = the system screenshot sound, otherwise a name from /System/Library/Sounds.
    var shutterSound: String {
        get { defaults.string(forKey: "shutterSound") ?? "" }
        set { set(newValue, "shutterSound") }
    }

    var afterCapturePin: Bool {
        get { bool("afterPin", default: false) }
        set { set(newValue, "afterPin") }
    }

    var afterRecordingShowPreview: Bool {
        get { bool("afterRecShowPreview", default: true) }
        set { set(newValue, "afterRecShowPreview") }
    }

    var afterRecordingCopy: Bool {
        get { bool("afterRecCopy", default: false) }
        set { set(newValue, "afterRecCopy") }
    }

    var afterRecordingSave: Bool {
        get { bool("afterRecSave", default: false) }
        set { set(newValue, "afterRecSave") }
    }

    /// Quick Access card size, 0.7 … 1.3 of the normal size.
    var previewScale: Double {
        get { defaults.object(forKey: "previewScale") as? Double ?? 1 }
        set { set(newValue, "previewScale") }
    }

    /// When auto-close fires: also save the capture first.
    var autoCloseSaves: Bool {
        get { bool("autoCloseSaves", default: false) }
        set { set(newValue, "autoCloseSaves") }
    }

    /// The card's Save button asks where to save instead of using the export folder.
    var saveButtonAsks: Bool {
        get { bool("saveButtonAsks", default: false) }
        set { set(newValue, "saveButtonAsks") }
    }

    var wallpaperFollowsSpaces: Bool {
        get { bool("wallpaperFollowsSpaces", default: true) }
        set { set(newValue, "wallpaperFollowsSpaces") }
    }

    var convertToSRGB: Bool {
        get { bool("convertToSRGB", default: false) }
        set { set(newValue, "convertToSRGB") }
    }

    var addBorder: Bool {
        get { bool("addBorder", default: false) }
        set { set(newValue, "addBorder") }
    }

    /// Wallpaper padding around window captures, in points.
    var windowPadding: Double {
        get { defaults.object(forKey: "windowPadding") as? Double ?? 48 }
        set { set(newValue, "windowPadding") }
    }

    // Annotate
    var annotateAlwaysOnTop: Bool {
        get { bool("annotateOnTop", default: false) }
        set { set(newValue, "annotateOnTop") }
    }

    var annotateShowDockIcon: Bool {
        get { bool("annotateDockIcon", default: true) }
        set { set(newValue, "annotateDockIcon") }
    }

    var annotateRememberBackground: Bool {
        get { bool("annotateRememberBackground", default: false) }
        set { set(newValue, "annotateRememberBackground") }
    }

    /// Last state of the background tool, used when "remember" is on.
    var annotateBackgroundWasOpen: Bool {
        get { bool("annotateBackgroundWasOpen", default: false) }
        set { defaults.set(newValue, forKey: "annotateBackgroundWasOpen") }
    }

    var annotateShadows: Bool {
        get { bool("annotateShadows", default: true) }
        set { set(newValue, "annotateShadows") }
    }

    // Advanced
    var askForName: Bool {
        get { bool("askForName", default: false) }
        set { set(newValue, "askForName") }
    }

    var retinaSuffix: Bool {
        get { bool("retinaSuffix", default: true) }
        set { set(newValue, "retinaSuffix") }
    }

    enum ClipboardMode: Int, CaseIterable {
        case fileAndImage, image, file
        var title: String {
            switch self {
            case .fileAndImage: return "File & Image (default)"
            case .image: return "Image only"
            case .file: return "File only"
            }
        }
    }

    var clipboardMode: ClipboardMode {
        get { ClipboardMode(rawValue: defaults.integer(forKey: "clipboardMode")) ?? .fileAndImage }
        set { set(newValue.rawValue, "clipboardMode") }
    }

    /// Text recognition language code, "" = detect automatically.
    var ocrLanguage: String {
        get { defaults.string(forKey: "ocrLanguage") ?? "" }
        set { set(newValue, "ocrLanguage") }
    }

    /// Capture Text also reads QR codes as links.
    var ocrDetectLinks: Bool {
        get { bool("ocrDetectLinks", default: true) }
        set { set(newValue, "ocrDetectLinks") }
    }

    var allInOneRemember: Bool {
        get { bool("allInOneRemember", default: true) }
        set { set(newValue, "allInOneRemember") }
    }

    var pinRounded: Bool {
        get { bool("pinRounded", default: true) }
        set { set(newValue, "pinRounded") }
    }

    var pinShadow: Bool {
        get { bool("pinShadow", default: true) }
        set { set(newValue, "pinShadow") }
    }

    var pinBorder: Bool {
        get { bool("pinBorder", default: true) }
        set { set(newValue, "pinBorder") }
    }

    var annotateInverseArrows: Bool {
        get { bool("inverseArrows", default: false) }
        set { set(newValue, "inverseArrows") }
    }

    var annotateSmoothDrawing: Bool {
        get { bool("smoothDrawing", default: true) }
        set { set(newValue, "smoothDrawing") }
    }

    /// Grow the canvas so annotations drawn past the image edge are kept.
    var annotateAutoExpand: Bool {
        get { bool("autoExpandCanvas", default: false) }
        set { set(newValue, "autoExpandCanvas") }
    }

    /// Crop edges snap to borders in the picture (⌘ while dragging turns it off).
    var annotateSnapToEdges: Bool {
        get { bool("snapToEdges", default: true) }
        set { set(newValue, "snapToEdges") }
    }

    /// Highlighter strokes line up with the text under them (⌘ while dragging turns it off).
    var annotateSnapHighlight: Bool {
        get { bool("snapHighlight", default: true) }
        set { set(newValue, "snapHighlight") }
    }

    var annotateColorNames: Bool {
        get { bool("colorNames", default: false) }
        set { set(newValue, "colorNames") }
    }

    // MARK: Crosshair cursor (the pointer while picking an area)

    enum CrosshairShape: Int, CaseIterable {
        case gapCross, plus, circle, dot
        var title: String { ["Cross with gap", "Plus", "Circle and dot", "Dot"][rawValue] }
    }

    var crosshairShape: CrosshairShape {
        get { CrosshairShape(rawValue: defaults.integer(forKey: "crosshairShape")) ?? .gapCross }
        set { set(newValue.rawValue, "crosshairShape") }
    }

    /// 0 small, 1 medium, 2 large.
    var crosshairSize: Int {
        get { defaults.object(forKey: "crosshairSize") as? Int ?? 1 }
        set { set(min(max(newValue, 0), 2), "crosshairSize") }
    }

    var crosshairColor: NSColor {
        get { (defaults.string(forKey: "crosshairColor")).flatMap(NSColor.init(saved:)) ?? .white }
        set { set(newValue.p3String, "crosshairColor") }
    }

    /// Full-screen guide lines through the cursor while selecting an area.
    var crosshairLines: Bool {
        get { bool("crosshairLines", default: false) }
        set { set(newValue, "crosshairLines") }
    }

    /// Lets the `clarishot` command-line tool and its MCP server (for AI tools) drive Clarishot.
    var allowAgentAccess: Bool {
        get { bool("allowAgentAccess", default: false) }
        set { set(newValue, "allowAgentAccess") }
    }

    /// Lets other apps run captures through clarishot:// links.
    var allowURLScheme: Bool {
        get { bool("allowURLScheme", default: false) }
        set { set(newValue, "allowURLScheme") }
    }

    // MARK: Reset

    func resetAll() {
        for key in ["snapToEdges", "snapHighlight", "theme", "liquidGlass", "allowAgentAccess", "autoExpandCanvas", "inverseArrows", "smoothDrawing", "colorNames", "crosshairLines", "allowURLScheme", "showMenuBarIcon", "hideIconsWhileCapturing", "shutterSound", "afterPin", "afterRecShowPreview",
                    "afterRecCopy", "afterRecSave", "previewScale", "autoCloseSaves", "saveButtonAsks",
                    "wallpaperFollowsSpaces", "convertToSRGB", "addBorder", "windowPadding", "annotateOnTop",
                    "annotateDockIcon", "annotateRememberBackground", "annotateShadows", "askForName", "retinaSuffix",
                    "clipboardMode", "ocrLanguage", "ocrDetectLinks", "allInOneRemember", "pinRounded", "pinShadow",
                    "pinBorder", "playSounds", "exportFolder", "screenshotName", "recordingName", "imageFormat", "jpegQuality",
                    "scaleScreenshotsTo1x", "showCursorInScreenshots", "afterShowPreview", "afterCopy", "afterSave",
                    "afterAnnotate", "previewPosition", "previewAutoClose", "previewOnActiveScreen",
                    "closePreviewAfterDragging", "recordingTimeInMenuBar", "controlsWhileRecording",
                    "customWallpaper", "shortcuts", "historyDays", "showMagnifier", "selfTimerSeconds", "windowStyle", "autoBackgroundPreset", "keepLineBreaks", "fullscreenOnWallpaper"] {
            defaults.removeObject(forKey: key)
        }
        notify()
    }

    // MARK: Setup guide

    /// The first-run guide has been seen (finished or closed).
    var setupGuideDone: Bool {
        get { bool("setupGuideDone", default: false) }
        set { set(newValue, "setupGuideDone") }
    }

    /// Reopen the guide at the permissions page after "Restart".
    var setupGuideResume: Bool {
        get { bool("setupGuideResume", default: false) }
        set { set(newValue, "setupGuideResume") }
    }

    // MARK: Helpers

    private func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }

    private func set(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
