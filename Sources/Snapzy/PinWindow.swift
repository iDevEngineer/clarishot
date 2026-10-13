import AppKit

/// Keeps a screenshot floating above all other windows. Drag to move,
/// double-click or press Esc to close.
@MainActor
final class PinWindow: NSPanel {
    private static var open: [PinWindow] = []

    static func pin(_ capture: Capture) {
        let window = PinWindow(capture: capture)
        open.append(window)
        window.center()
        window.orderFrontRegardless()
        window.makeKey()
    }

    private init(capture: Capture) {
        let size = Self.fittedSize(capture.pointSize)
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = PinView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.contents = capture.image
        view.layer?.contentsGravity = .resizeAspect
        view.onClose = { [weak self] in self?.closePin() }
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { closePin() }

    private func closePin() {
        orderOut(nil)
        Self.open.removeAll { $0 === self }
    }

    /// Shrinks very large captures so the pin fits comfortably on screen.
    private static func fittedSize(_ size: CGSize) -> CGSize {
        let limit = (NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800))
        let scale = min(1, limit.width * 0.6 / size.width, limit.height * 0.6 / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

private final class PinView: NSView {
    var onClose: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onClose?() } else { super.mouseDown(with: event) }
    }
}
