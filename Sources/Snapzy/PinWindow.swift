import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

private let log = Logger(subsystem: "com.scottmackey.snapzy", category: "paste")

/// Keeps a screenshot floating above all other windows.
/// Hover shows: close (top-left), lock (top-right) and Paste (bottom centre).
/// While locked the pin can only be closed: no pasting and no moving.
/// Only the close button closes it, so it can't be closed by accident.
@MainActor
final class PinWindow: NSPanel {
    private static var open: [PinWindow] = []
    /// The last app that wasn't Snapzy, so Paste goes back to where you were working.
    private static var lastOtherApp: NSRunningApplication?
    private static var observer: NSObjectProtocol?

    private let capture: Capture
    private let pinView: PinView

    static func pin(_ capture: Capture) {
        trackFrontmostApp()
        let window = PinWindow(capture: capture)
        open.append(window)
        window.center()
        window.orderFrontRegardless()
    }

    private init(capture: Capture) {
        self.capture = capture
        let size = Self.fittedSize(capture.pointSize)
        pinView = PinView(frame: CGRect(origin: .zero, size: size), image: capture.image)
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        pinView.onClose = { [weak self] in self?.closePin() }
        pinView.onPaste = { [weak self] in self?.paste() }
        pinView.onLockChange = { [weak self] locked in self?.isMovableByWindowBackground = !locked }
        contentView = pinView
    }

    /// Never take keyboard focus: clicking the pin must leave your text box focused,
    /// otherwise Paste's ⌘V would land on the pin instead of in your app.
    override var canBecomeKey: Bool { false }

    private func closePin() {
        orderOut(nil)
        Self.open.removeAll { $0 === self }
    }

    // MARK: Paste

    /// Copies the image and presses ⌘V in the app you were last using.
    private func paste() {
        capture.copyToClipboard()
        let front = NSWorkspace.shared.frontmostApplication
        log.notice("Paste clicked. trusted=\(AXIsProcessTrusted(), privacy: .public) front=\(front?.bundleIdentifier ?? "nil", privacy: .public) lastOther=\(Self.lastOtherApp?.bundleIdentifier ?? "nil", privacy: .public) clipboard=\(NSPasteboard.general.types?.map(\.rawValue).joined(separator: ",") ?? "", privacy: .public)")
        guard AXIsProcessTrusted() else {
            // Show the system prompt so the user can allow it, and leave the image on the clipboard.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            Toast.show("Copied — press ⌘V. To paste directly, allow Snapzy in Accessibility, then restart it.")
            return
        }
        // Paste into the app you were working in (clicking the pin doesn't switch apps, but a
        // Snapzy window like Annotate might be in front).
        var delay = 0.05
        if front?.processIdentifier == getpid(), let target = Self.lastOtherApp {
            target.activate()
            delay = 0.25
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            log.notice("Sending Cmd-V to \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil", privacy: .public)")
            Self.pressCommandV()
        }
    }

    /// Sends ⌘V as real key presses: Command down, V down, V up, Command up.
    private static func pressCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let command = CGKeyCode(kVK_Command), v = CGKeyCode(kVK_ANSI_V)
        let steps: [(CGKeyCode, Bool)] = [(command, true), (v, true), (v, false), (command, false)]
        for (key, down) in steps {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else {
                log.error("Could not create key event")
                continue
            }
            event.flags = (key == v || down) ? .maskCommand : []
            event.post(tap: .cghidEventTap)
        }
    }

    private static func trackFrontmostApp() {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            lastOtherApp = front
        }
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app.processIdentifier != getpid() { lastOtherApp = app }
            }
        }
    }

    /// 90% of the original size, shrunk further only if it would fill more than 85% of the screen.
    private static func fittedSize(_ size: CGSize) -> CGSize {
        let limit = (NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800))
        let scale = min(0.9, limit.width * 0.85 / size.width, limit.height * 0.85 / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

/// The pinned image plus its hover controls.
@MainActor
private final class PinView: NSView {
    var onClose: (() -> Void)?
    var onPaste: (() -> Void)?
    var onLockChange: ((Bool) -> Void)?

    private let controls = NSView()
    private var lockButton: CircleButton!
    private var pasteButton: PillButton!
    private var locked = false

    init(frame: CGRect, image: CGImage) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resizeAspect

        controls.frame = bounds
        controls.autoresizingMask = [.width, .height]
        controls.alphaValue = 0
        addSubview(controls)

        let inset: CGFloat = 8
        let size = CircleButton.size
        let close = CircleButton(symbol: "xmark") { [weak self] in self?.onClose?() }
        close.toolTip = "Close"
        close.setFrameOrigin(CGPoint(x: inset, y: bounds.maxY - inset - size))
        close.autoresizingMask = [.maxXMargin, .minYMargin]

        lockButton = CircleButton(symbol: "lock.open.fill") { [weak self] in self?.toggleLock() }
        lockButton.toolTip = "Lock: only allow closing"
        lockButton.setFrameOrigin(CGPoint(x: bounds.maxX - inset - size, y: bounds.maxY - inset - size))
        lockButton.autoresizingMask = [.minXMargin, .minYMargin]

        pasteButton = PillButton(title: "Paste") { [weak self] in
            guard let self, !self.locked else { return }
            self.onPaste?()
        }
        pasteButton.setFrameOrigin(CGPoint(x: bounds.midX - pasteButton.frame.width / 2, y: inset))
        pasteButton.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]

        [close, lockButton, pasteButton].forEach { controls.addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func toggleLock() {
        locked.toggle()
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        lockButton.image = NSImage(systemSymbolName: locked ? "lock.fill" : "lock.open.fill",
                                   accessibilityDescription: locked ? "Locked" : "Unlocked")?.withSymbolConfiguration(config)
        lockButton.contentTintColor = locked ? .white : NSColor.black.withAlphaComponent(0.8)
        lockButton.layer?.backgroundColor = (locked ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.95)).cgColor
        lockButton.toolTip = locked ? "Unlock" : "Lock: only allow closing"
        pasteButton.isEnabled = !locked
        pasteButton.alphaValue = locked ? 0.4 : 1
        onLockChange?(locked)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { fadeControls(in: true) }
    override func mouseExited(with event: NSEvent) { fadeControls(in: false) }

    private func fadeControls(in visible: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            controls.animator().alphaValue = visible ? 1 : 0
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

}
