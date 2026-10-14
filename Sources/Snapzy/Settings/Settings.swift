import AppKit
import ServiceManagement

/// App-wide preferences, saved in UserDefaults. Posts `Settings.didChange` on every change.
@MainActor
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("SnapzySettingsDidChange")

    private let defaults = UserDefaults.standard

    enum ImageFormat: String, CaseIterable { case png, jpeg }

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
        get { defaults.string(forKey: "screenshotName") ?? "Snapzy {date} at {time}" }
        set { set(newValue, "screenshotName") }
    }

    var recordingNameTemplate: String {
        get { defaults.string(forKey: "recordingName") ?? "Snapzy Recording {date} at {time}" }
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

    var showMagnifier: Bool {
        get { bool("showMagnifier", default: false) }
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

    // MARK: Reset

    func resetAll() {
        for key in ["playSounds", "exportFolder", "screenshotName", "recordingName", "imageFormat", "jpegQuality",
                    "scaleScreenshotsTo1x", "showCursorInScreenshots", "afterShowPreview", "afterCopy", "afterSave",
                    "afterAnnotate", "previewPosition", "previewAutoClose", "previewOnActiveScreen",
                    "closePreviewAfterDragging", "recordingTimeInMenuBar", "controlsWhileRecording",
                    "customWallpaper", "shortcuts", "historyDays", "showMagnifier", "selfTimerSeconds", "windowStyle", "autoBackgroundPreset", "keepLineBreaks"] {
            defaults.removeObject(forKey: key)
        }
        notify()
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
