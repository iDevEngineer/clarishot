import AppKit

extension NSWindow {
    /// Clarishot's softer window shape: corners rounder than the system default.
    /// Makes the window itself clear, draws the background inside a rounded, clipped content
    /// view, and lets the shadow follow that shape.
    func useRoundedCorners(_ radius: CGFloat = 26) {
        styleMask.insert(.fullSizeContentView)
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        guard let content = contentView else { return }
        content.wantsLayer = true
        content.layer?.cornerRadius = radius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        if !content.subviews.contains(where: { $0 is RoundedWindowBackground }) {
            let background = RoundedWindowBackground(frame: content.bounds)
            background.autoresizingMask = [.width, .height]
            content.addSubview(background, positioned: .below, relativeTo: nil)
        }
        invalidateShadow()
    }
}

/// The normal window background colour, following light and dark mode.
final class RoundedWindowBackground: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
