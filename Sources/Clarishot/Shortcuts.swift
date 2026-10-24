import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut, shown in the menu and registered system-wide.
struct Shortcut: Equatable {
    let key: String            // menu key equivalent, e.g. "4"
    let keyCode: UInt32        // Carbon virtual key code
    let modifiers: NSEvent.ModifierFlags

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    /// e.g. "⌥⇧⌘4"
    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Self.keyName(code: keyCode, fallback: key)
    }

    static func keyName(code: UInt32, fallback: String) -> String {
        let names: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
        ]
        return names[Int(code)] ?? fallback.uppercased()
    }
}

/// Everything that can have a global shortcut. ⌥⇧⌘ defaults avoid the system's ⇧⌘3/4/5.
enum ShortcutAction: String, CaseIterable {
    case allInOne, captureArea, capturePreviousArea, captureFullscreen, captureWindow, scrollingCapture, selfTimer,
         captureText, recordScreen, pauseRecording,
         toggleDesktopIcons, openHistory, restoreLastCapture,
         captureAreaCopy, captureAreaSave, captureAreaAnnotate, captureAreaPin,
         smartCapture, objectCutout, captureMenu, drawOnScreen

    var title: String {
        switch self {
        case .allInOne: return "All-In-One"
        case .selfTimer: return "Self-Timer"
        case .captureArea: return "Capture Area"
        case .capturePreviousArea: return "Capture Previous Area"
        case .captureFullscreen: return "Capture Fullscreen"
        case .captureWindow: return "Capture Window"
        case .scrollingCapture: return "Scrolling Capture"
        case .captureText: return "Capture Text (OCR)"
        case .recordScreen: return "Record Screen / Stop Recording"
        case .pauseRecording: return "Pause / Resume Recording"
        case .toggleDesktopIcons: return "Toggle Desktop Icons"
        case .openHistory: return "Open Capture History"
        case .restoreLastCapture: return "Restore Last Capture"
        case .captureAreaCopy: return "Capture Area & Copy to Clipboard"
        case .captureAreaSave: return "Capture Area & Save"
        case .captureAreaAnnotate: return "Capture Area & Annotate"
        case .captureAreaPin: return "Capture Area & Pin to the Screen"
        case .smartCapture: return "Smart Capture"
        case .objectCutout: return "Capture Object (Cutout)"
        case .captureMenu: return "Capture Menu or Popover"
        case .drawOnScreen: return "Draw on Screen (while recording)"
        }
    }

    /// nil = no shortcut until the user records one.
    var defaultShortcut: Shortcut? {
        let m: NSEvent.ModifierFlags = [.option, .shift, .command]
        switch self {
        case .allInOne: return Shortcut(key: "a", keyCode: UInt32(kVK_ANSI_A), modifiers: m)
        case .selfTimer: return Shortcut(key: "t", keyCode: UInt32(kVK_ANSI_T), modifiers: m)
        case .captureArea: return Shortcut(key: "4", keyCode: UInt32(kVK_ANSI_4), modifiers: m)
        case .capturePreviousArea: return Shortcut(key: "6", keyCode: UInt32(kVK_ANSI_6), modifiers: m)
        case .captureFullscreen: return Shortcut(key: "3", keyCode: UInt32(kVK_ANSI_3), modifiers: m)
        case .captureWindow: return Shortcut(key: "5", keyCode: UInt32(kVK_ANSI_5), modifiers: m)
        case .scrollingCapture: return Shortcut(key: "s", keyCode: UInt32(kVK_ANSI_S), modifiers: m)
        case .captureText: return Shortcut(key: "2", keyCode: UInt32(kVK_ANSI_2), modifiers: m)
        case .recordScreen: return Shortcut(key: "r", keyCode: UInt32(kVK_ANSI_R), modifiers: m)
        case .pauseRecording: return Shortcut(key: "p", keyCode: UInt32(kVK_ANSI_P), modifiers: m)
        case .smartCapture: return Shortcut(key: "e", keyCode: UInt32(kVK_ANSI_E), modifiers: m)
        case .objectCutout: return Shortcut(key: "1", keyCode: UInt32(kVK_ANSI_1), modifiers: m)
        case .captureMenu: return Shortcut(key: "m", keyCode: UInt32(kVK_ANSI_M), modifiers: m)
        case .drawOnScreen: return Shortcut(key: "d", keyCode: UInt32(kVK_ANSI_D), modifiers: m)
        case .captureAreaAnnotate: return Shortcut(key: "7", keyCode: UInt32(kVK_ANSI_7), modifiers: m)
        case .toggleDesktopIcons, .openHistory, .restoreLastCapture,
             .captureAreaCopy, .captureAreaSave, .captureAreaPin: return nil
        }
    }

    @MainActor
    func perform() {
        Perf.trigger(rawValue)
        let c = CaptureCoordinator.shared
        switch self {
        case .allInOne: c.allInOne()
        case .selfTimer: c.selfTimer()
        case .captureArea: c.captureArea()
        case .capturePreviousArea: c.capturePreviousArea()
        case .captureFullscreen: c.captureFullscreen()
        case .captureWindow: c.captureWindow()
        case .scrollingCapture: ScrollCaptureCoordinator.shared.start()
        case .captureText: c.captureText()
        case .recordScreen: RecordingCoordinator.shared.toggle()
        case .pauseRecording: RecordingCoordinator.shared.togglePause()
        case .toggleDesktopIcons: DesktopIconHider.shared.toggle()
        case .openHistory: HistoryWindowController.show()
        case .restoreLastCapture: PreviewManager.shared.restoreRecentlyClosed()
        case .captureAreaCopy: c.captureArea(then: .copy)
        case .captureAreaSave: c.captureArea(then: .save)
        case .captureAreaAnnotate: c.captureAndAnnotate()
        case .smartCapture: c.captureSmart()
        case .objectCutout: c.captureCutout()
        case .captureMenu: c.captureMenu()
        case .drawOnScreen: RecordingCoordinator.shared.toggleDrawing()
        case .captureAreaPin: c.captureArea(then: .pin)
        }
    }
}

enum Shortcuts {
    /// (Re)registers every action's current shortcut.
    @MainActor
    static func registerAll() {
        let hotkeys = HotkeyCenter.shared
        hotkeys.unregisterAll()
        for action in ShortcutAction.allCases {
            if let shortcut = Settings.shared.shortcut(for: action) {
                hotkeys.register(shortcut) { action.perform() }
            }
        }
    }
}

/// Registers global hotkeys through Carbon (works without Accessibility permission).
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var installed = false
    /// While true (e.g. when recording a new shortcut), presses are ignored.
    var isSuspended = false

    func register(_ shortcut: Shortcut, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E_505A), id: id) // "SNPZ"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        guard !isSuspended else { return }
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotkeyCenter.shared.fire(id) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
