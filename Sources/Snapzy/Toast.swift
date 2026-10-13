import AppKit

/// A short message in a dark rounded box near the bottom of the screen.
@MainActor
enum Toast {
    private static var current: NSPanel?

    static func show(_ message: String) {
        current?.orderOut(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 32, height: label.frame.height + 18)

        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let box = NSView(frame: CGRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        box.layer?.cornerRadius = size.height / 2
        label.setFrameOrigin(CGPoint(x: 16, y: 9))
        box.addSubview(label)
        panel.contentView = box

        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(CGPoint(x: v.midX - size.width / 2, y: v.minY + 60))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        current = panel
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard current === panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        }
    }
}
