import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut, shown in the menu and registered system-wide.
struct Shortcut {
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
}

/// Default shortcuts. ⌥⇧⌘ avoids clashing with the system's ⇧⌘3/4/5.
enum Shortcuts {
    static let captureArea = Shortcut(key: "4", keyCode: UInt32(kVK_ANSI_4), modifiers: [.option, .shift, .command])
    static let captureFullscreen = Shortcut(key: "3", keyCode: UInt32(kVK_ANSI_3), modifiers: [.option, .shift, .command])
    static let captureWindow = Shortcut(key: "5", keyCode: UInt32(kVK_ANSI_5), modifiers: [.option, .shift, .command])
    static let capturePreviousArea = Shortcut(key: "6", keyCode: UInt32(kVK_ANSI_6), modifiers: [.option, .shift, .command])
    static let recordScreen = Shortcut(key: "r", keyCode: UInt32(kVK_ANSI_R), modifiers: [.option, .shift, .command])
    static let pauseRecording = Shortcut(key: "p", keyCode: UInt32(kVK_ANSI_P), modifiers: [.option, .shift, .command])
    static let scrollingCapture = Shortcut(key: "s", keyCode: UInt32(kVK_ANSI_S), modifiers: [.option, .shift, .command])
    static let captureText = Shortcut(key: "2", keyCode: UInt32(kVK_ANSI_2), modifiers: [.option, .shift, .command])

    @MainActor
    static func registerAll() {
        let c = CaptureCoordinator.shared
        let hotkeys = HotkeyCenter.shared
        hotkeys.register(captureArea) { c.captureArea() }
        hotkeys.register(captureFullscreen) { c.captureFullscreen() }
        hotkeys.register(captureWindow) { c.captureWindow() }
        hotkeys.register(capturePreviousArea) { c.capturePreviousArea() }
        hotkeys.register(captureText) { c.captureText() }
        hotkeys.register(scrollingCapture) { ScrollCaptureCoordinator.shared.start() }
        hotkeys.register(recordScreen) { RecordingCoordinator.shared.toggle() }
        hotkeys.register(pauseRecording) { RecordingCoordinator.shared.togglePause() }
    }
}

/// Registers global hotkeys through Carbon (works without Accessibility permission).
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    func register(_ shortcut: Shortcut, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = UInt32(handlers.count + 1)
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E_505A), id: id) // "SNPZ"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) }
    }

    fileprivate func fire(_ id: UInt32) {
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
