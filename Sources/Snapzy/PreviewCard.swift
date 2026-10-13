import AppKit
import CoreImage

/// Stacks the floating preview cards in a corner of the screen (see Settings → Quick Access).
@MainActor
final class PreviewManager {
    static let shared = PreviewManager()

    private var panels: [PreviewPanel] = []
    private let edgeInset: CGFloat = 20
    private let spacing: CGFloat = 12

    func show(_ capture: Capture) {
        let panel = PreviewPanel(capture: capture)
        panel.onDismiss = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.remove(panel)
        }
        panels.insert(panel, at: 0)
        layout(animatedNew: panel)
        let seconds = Settings.shared.previewAutoClose
        if seconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self, weak panel] in
                guard let self, let panel, self.panels.contains(where: { $0 === panel }) else { return }
                self.remove(panel)
            }
        }
    }

    private func remove(_ panel: PreviewPanel) {
        panels.removeAll { $0 === panel }
        panel.slideOut { [weak self] in self?.layout(animatedNew: nil) }
    }

    private func layout(animatedNew newPanel: PreviewPanel?) {
        let settings = Settings.shared
        let mouse = NSEvent.mouseLocation
        let active = settings.previewOnActiveScreen ? NSScreen.screens.first { $0.frame.contains(mouse) } : nil
        guard let screen = active ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let position = settings.previewPosition
        let fromTop = position == .topLeft || position == .topRight
        let onRight = position == .bottomRight || position == .topRight
        var offset = edgeInset
        for panel in panels {
            let margin = PreviewPanel.shadowMargin
            let cardSize = CGSize(width: panel.frame.width - 2 * margin, height: panel.frame.height - 2 * margin)
            let x = onRight ? visible.maxX - edgeInset - cardSize.width : visible.minX + edgeInset
            let y = fromTop ? visible.maxY - offset - cardSize.height : visible.minY + offset
            let origin = CGPoint(x: x - margin, y: y - margin)
            let frame = CGRect(origin: origin, size: panel.frame.size)
            if panel === newPanel {
                panel.slideIn(to: frame, fromRight: onRight)
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    panel.animator().setFrame(frame, display: true)
                }
            }
            offset += cardSize.height + spacing
        }
    }
}

/// A borderless, non-activating window holding one preview card.
@MainActor
final class PreviewPanel: NSPanel {
    static let shadowMargin: CGFloat = 24
    var onDismiss: (() -> Void)?

    init(capture: Capture) {
        let card = PreviewCardView(capture: capture)
        let m = Self.shadowMargin
        let size = CGSize(width: card.frame.width + 2 * m, height: card.frame.height + 2 * m)
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        becomesKeyOnlyIfNeeded = true

        let container = NSView(frame: CGRect(origin: .zero, size: size))
        card.setFrameOrigin(CGPoint(x: m, y: m))
        container.addSubview(card)
        contentView = container
        card.onDismiss = { [weak self] in self?.onDismiss?() }
    }

    private var slidesRight = false

    func slideIn(to frame: CGRect, fromRight: Bool = false) {
        slidesRight = fromRight
        setFrame(frame.offsetBy(dx: fromRight ? frame.width : -frame.width, dy: 0), display: false)
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(frame, display: true)
            animator().alphaValue = 1
        }
    }

    func slideOut(completion: @escaping () -> Void) {
        let target = frame.offsetBy(dx: slidesRight ? frame.width : -frame.width, dy: 0)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().setFrame(target, display: true)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            completion()
        })
    }
}

/// The white card with a thumbnail. On hover it shows Copy / Save and corner buttons.
@MainActor
final class PreviewCardView: NSView, NSDraggingSource {
    var onDismiss: (() -> Void)?

    private static let maxSize = CGSize(width: 220, height: 240)
    private static let minSide: CGFloat = 110
    private static let radius: CGFloat = 12
    private let capture: Capture
    private let thumbRect: CGRect
    private let hoverView = NSView()
    private var dragging = false

    init(capture: Capture) {
        self.capture = capture
        // The card is the image itself, no border: fit it in the max size, but keep
        // very thin images (e.g. long scrolling captures) from becoming slivers.
        let size = capture.pointSize
        let fit = min(Self.maxSize.width / max(size.width, 1), Self.maxSize.height / max(size.height, 1))
        let width = min(max((size.width * fit).rounded(), Self.minSide), Self.maxSize.width)
        let height = min(max((size.height * fit).rounded(), Self.minSide), Self.maxSize.height)
        thumbRect = CGRect(x: 0, y: 0, width: width, height: height)
        super.init(frame: thumbRect)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func setUp() {
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        layer?.shadowPath = CGPath(roundedRect: thumbRect, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
        // Thin white outline; a layer's border draws above its sublayers, so it stays crisp over the hover dimming.
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        layer?.borderWidth = 1.5

        let thumb = CALayer()
        thumb.frame = thumbRect
        thumb.contents = capture.image
        thumb.contentsGravity = .resizeAspectFill
        thumb.cornerRadius = Self.radius
        thumb.masksToBounds = true
        layer?.addSublayer(thumb)

        hoverView.frame = thumbRect
        hoverView.wantsLayer = true
        hoverView.layer?.cornerRadius = Self.radius
        hoverView.layer?.masksToBounds = true
        hoverView.alphaValue = 0
        // On hover: a blurred copy of the thumbnail, lightly darkened, under the buttons.
        let blurred = CALayer()
        blurred.frame = hoverView.bounds
        blurred.contents = Self.blurredThumbnail(capture.image, size: thumbRect.size)
        blurred.contentsGravity = .resizeAspectFill
        blurred.opacity = 0.75 // let the sharp image show through a little (frosted look)
        let dim = CALayer()
        dim.frame = hoverView.bounds
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        hoverView.layer?.addSublayer(blurred)
        hoverView.layer?.addSublayer(dim)
        addSubview(hoverView)
        buildHoverControls()
        if capture.isVideo { addDurationBadge() }
    }

    /// A small, blurred copy of the image for the hover state.
    private static func blurredThumbnail(_ image: CGImage, size: CGSize) -> CGImage? {
        let input = CIImage(cgImage: image)
        // Shrink first (to about 2× the card size) so the blur is cheap.
        let shrink = min(1, (max(size.width, size.height) * 2) / CGFloat(max(image.width, image.height)))
        let small = input.transformed(by: CGAffineTransform(scaleX: shrink, y: shrink))
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(small.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(10, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: small.extent) else { return nil }
        return CIContext().createCGImage(output, from: small.extent)
    }

    /// "▶ 0:12" label in the thumbnail's bottom-right corner.
    private func addDurationBadge() {
        let seconds = Int(capture.duration.rounded())
        let label = NSTextField(labelWithString: (capture.isGIF ? "GIF · " : "") + String(format: "%d:%02d", seconds / 60, seconds % 60))
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        let icon = NSImageView(image: NSImage(systemSymbolName: "video.fill", accessibilityDescription: "Recording")!)
        icon.contentTintColor = .white
        icon.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        let badge = NSStackView(views: [icon, label])
        badge.spacing = 4
        badge.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        badge.layer?.cornerRadius = 6
        let size = badge.fittingSize
        badge.frame = CGRect(x: thumbRect.maxX - size.width - 6, y: thumbRect.minY + 6, width: size.width, height: size.height)
        addSubview(badge, positioned: .below, relativeTo: hoverView)
    }

    private func buildHoverControls() {
        let b = hoverView.bounds
        let copy = PillButton(title: "Copy") { [weak self] in self?.copy() }
        let save = PillButton(title: "Save") { [weak self] in self?.save() }
        let gap: CGFloat = 6
        let total = copy.frame.height * 2 + gap
        copy.setFrameOrigin(CGPoint(x: b.midX - copy.frame.width / 2, y: b.midY + total / 2 - copy.frame.height))
        save.setFrameOrigin(CGPoint(x: b.midX - save.frame.width / 2, y: b.midY - total / 2))
        hoverView.addSubview(copy)
        hoverView.addSubview(save)

        let inset: CGFloat = 6
        let size = CircleButton.size
        var corners: [(String, String, CGPoint, () -> Void)] = [
            ("xmark", "Close", CGPoint(x: inset, y: b.maxY - inset - size), { [weak self] in self?.onDismiss?() })
        ]
        if capture.isVideo {
            corners.append(("scissors", "Trim", CGPoint(x: inset, y: inset), { [weak self] in self?.trim() }))
        } else {
            corners.append(("pin.fill", "Pin to the screen", CGPoint(x: b.maxX - inset - size, y: b.maxY - inset - size),
                            { [weak self] in self?.pin() }))
            corners.append(("pencil", "Annotate", CGPoint(x: inset, y: inset), { [weak self] in self?.annotate() }))
        }
        for (symbol, tip, origin, action) in corners {
            let button = CircleButton(symbol: symbol, action: action)
            button.toolTip = tip
            button.setFrameOrigin(origin)
            hoverView.addSubview(button)
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            hoverView.animator().alphaValue = on ? 1 : 0
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Actions

    private func copy() {
        capture.copyToClipboard()
        Toast.show("Copied to clipboard")
        onDismiss?()
    }

    private func save() {
        do {
            try capture.save()
            Toast.show(Capture.savedMessage)
            onDismiss?()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func pin() {
        PinWindow.pin(capture)
        onDismiss?()
    }

    private func annotate() {
        AnnotateWindowController.open(capture)
        onDismiss?()
    }

    private func trim() {
        guard #available(macOS 15.0, *) else { return }
        if capture.isGIF {
            guard let source = capture.sourceVideoURL else { return }
            TrimWindowController.open(source, makeGIF: true)
        } else if let url = capture.videoURL {
            TrimWindowController.open(url, makeGIF: false)
        }
        onDismiss?()
    }

    // MARK: Drag the image out into another app

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let url = try? capture.temporaryFile() else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(thumbRect, contents: capture.nsImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        if !operation.isEmpty, Settings.shared.closePreviewAfterDragging { onDismiss?() }
    }
}

/// White rounded button used for Copy / Save.
final class PillButton: NSButton {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: CGRect(x: 0, y: 0, width: 88, height: 30))
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.95).cgColor
        layer?.cornerRadius = 15 // fully rounded ends (pill)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.85)
        ])
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    @objc private func clicked() { handler() }
}

/// Small round icon button used in the card corners.
final class CircleButton: NSButton {
    static let size: CGFloat = 24
    private let handler: () -> Void

    init(symbol: String, action: @escaping () -> Void) {
        self.handler = action
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.95).cgColor
        layer?.cornerRadius = Self.size / 2
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        contentTintColor = NSColor.black.withAlphaComponent(0.8)
        imagePosition = .imageOnly
        target = self
        self.action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    @objc private func clicked() { handler() }
}
