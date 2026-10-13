import AppKit
import Carbon.HIToolbox

/// A button showing a shortcut. Click it, then press keys to record a new one.
/// Delete clears it; Esc cancels. Global hotkeys are paused while recording.
@MainActor
final class ShortcutRecorder: NSButton {
    var shortcut: Shortcut? { didSet { updateTitle() } }
    private let onChange: (Shortcut?) -> Void
    private var monitor: Any?

    init(shortcut: Shortcut?, onChange: @escaping (Shortcut?) -> Void) {
        self.shortcut = shortcut
        self.onChange = onChange
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 160).isActive = true
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func updateTitle() {
        title = shortcut?.displayString ?? "None"
    }

    @objc private func startRecording() {
        guard monitor == nil else { return }
        title = "Type shortcut…"
        HotkeyCenter.shared.isSuspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    /// Returns true if the event was used and should not reach the window.
    private func handle(_ event: NSEvent) -> Bool {
        if event.type == .leftMouseDown {
            stopRecording()
            return false
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_Escape:
            stopRecording()
        case kVK_Delete, kVK_ForwardDelete:
            shortcut = nil
            stopRecording()
            onChange(nil)
        default:
            // Require a "real" modifier so plain typing isn't hijacked.
            guard !flags.intersection([.command, .option, .control]).isEmpty else {
                NSSound.beep()
                return true
            }
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let new = Shortcut(key: key, keyCode: UInt32(event.keyCode), modifiers: flags)
            shortcut = new
            stopRecording()
            onChange(new)
        }
        return true
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotkeyCenter.shared.isSuspended = false
        updateTitle()
        Shortcuts.registerAll()
    }
}
