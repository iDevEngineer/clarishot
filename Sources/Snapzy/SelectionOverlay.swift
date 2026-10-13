import AppKit

enum SelectionMode {
    case area
    case window
}

enum SelectionResult {
    case area(ScreenShot, CGRect) // rect in screen-local points
    case window(CGWindowID)
}

/// Full-screen overlay windows (one per display) showing a frozen copy of the
/// screen, for dragging out an area or clicking a window. Esc cancels.
@MainActor
final class SelectionOverlayController {
    private var windows: [OverlayWindow] = []
    private let completion: (SelectionResult?) -> Void
    private let previousApp = NSWorkspace.shared.frontmostApplication
    private var finished = false

    init(shots: [ScreenShot], mode: SelectionMode, targets: [WindowTarget], hint: String? = nil,
         completion: @escaping (SelectionResult?) -> Void) {
        self.completion = completion
        for shot in shots {
            let window = OverlayWindow(contentRect: shot.screen.frame, styleMask: .borderless,
                                       backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.isOpaque = true
            window.hasShadow = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = OverlayView(frame: CGRect(origin: .zero, size: shot.screen.frame.size),
                                   shot: shot, mode: mode, targets: targets, hint: hint)
            view.onFinish = { [weak self] result in self?.finish(result) }
            window.contentView = view
            window.setFrame(shot.screen.frame, display: false)
            windows.append(window)
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        for window in windows { window.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        let keyWindow = windows.first { $0.frame.contains(mouse) } ?? windows.first
        keyWindow?.makeKey()
        keyWindow?.makeFirstResponder(keyWindow?.contentView)
        CrosshairCursor.shared.set()
    }

    private func finish(_ result: SelectionResult?) {
        guard !finished else { return }
        finished = true
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        previousApp?.activate()
        completion(result)
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView {
    var onFinish: ((SelectionResult?) -> Void)?

    private let shot: ScreenShot
    private let mode: SelectionMode
    private let targets: [WindowTarget]
    private var mouse: CGPoint?
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hovered: WindowTarget?
    private let hint: String?

    init(frame: CGRect, shot: ScreenShot, mode: SelectionMode, targets: [WindowTarget], hint: String? = nil) {
        self.hint = hint
        self.shot = shot
        self.mode = mode
        self.targets = targets
        super.init(frame: frame)
        let global = NSEvent.mouseLocation
        if shot.screen.frame.contains(global) { mouse = toLocal(global) }
        updateHover()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways,
                                                 .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: CrosshairCursor.shared) }
    override func cursorUpdate(with event: NSEvent) { CrosshairCursor.shared.set() }

    // MARK: Mouse and keys

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        updateHover()
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    override func mouseExited(with event: NSEvent) {
        guard dragStart == nil else { return }
        mouse = nil
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard mode == .area else { return }
        dragStart = convert(event.locationInWindow, from: nil)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area, let start = dragStart else { return }
        let point = clamped(convert(event.locationInWindow, from: nil))
        mouse = point
        selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                           width: abs(point.x - start.x), height: abs(point.y - start.y)).integral
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .area:
            if let rect = selection, rect.width >= 4, rect.height >= 4 {
                onFinish?(.area(shot, rect))
            } else {
                dragStart = nil
                selection = nil
                needsDisplay = true
            }
        case .window:
            if let hovered { onFinish?(.window(hovered.id)) }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onFinish?(nil) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(shot.image, in: bounds)

        switch mode {
        case .area: drawArea(ctx)
        case .window: drawWindowHighlight(ctx)
        }
        if let hint, selection == nil { drawHint(hint) }
    }

    /// Instruction pill near the top of the screen.
    private func drawHint(_ text: String) {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white
        ])
        let size = string.size()
        let box = CGRect(x: bounds.midX - size.width / 2 - 16, y: bounds.maxY - 90,
                         width: size.width + 32, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        string.draw(at: CGPoint(x: box.minX + 16, y: box.minY + 8))
    }

    private func drawArea(_ ctx: CGContext) {
        if let rect = selection {
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(rect)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.fillPath(using: .evenOdd)

            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))

            drawLabel("\(Int(rect.width)) × \(Int(rect.height))", near: mouse ?? CGPoint(x: rect.maxX, y: rect.minY))
        } else if let mouse {
            drawLabel("\(Int(mouse.x)), \(Int(bounds.height - mouse.y))", near: mouse)
        }
    }

    private func drawWindowHighlight(_ ctx: CGContext) {
        guard let hovered else { return }
        let rect = hovered.frame.offsetBy(dx: -shot.screen.frame.minX, dy: -shot.screen.frame.minY)
        ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.22).cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(rect.insetBy(dx: 1, dy: 1))
    }

    /// Small dark pill next to the cursor, e.g. "640 × 480".
    private func drawLabel(_ text: String, near point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        // Below and to the right of the cursor, clear of the crosshair.
        var box = CGRect(x: point.x + 20, y: point.y - size.height - 26,
                         width: size.width + 12, height: size.height + 6)
        if box.maxX > bounds.maxX - 4 { box.origin.x = point.x - box.width - 14 }
        if box.minY < 4 { box.origin.y = point.y + 14 }
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        string.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3))
    }

    // MARK: Helpers

    private func updateHover() {
        guard mode == .window, let mouse else { hovered = nil; return }
        let global = CGPoint(x: mouse.x + shot.screen.frame.minX, y: mouse.y + shot.screen.frame.minY)
        hovered = targets.first { $0.frame.contains(global) }
    }

    private func toLocal(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - shot.screen.frame.minX, y: global.y - shot.screen.frame.minY)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.maxX), y: min(max(point.y, 0), bounds.maxY))
    }
}

/// A large crosshair cursor: four arms with a gap in the middle, white with a
/// dark outline so it shows on any background. The hot spot is the centre.
@MainActor
enum CrosshairCursor {
    static let shared: NSCursor = {
        let size: CGFloat = 40
        let image = NSImage(size: CGSize(width: size, height: size), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let gap: CGFloat = 5, arm: CGFloat = 17
            let path = NSBezierPath()
            path.move(to: CGPoint(x: c.x - arm, y: c.y)); path.line(to: CGPoint(x: c.x - gap, y: c.y))
            path.move(to: CGPoint(x: c.x + gap, y: c.y)); path.line(to: CGPoint(x: c.x + arm, y: c.y))
            path.move(to: CGPoint(x: c.x, y: c.y - arm)); path.line(to: CGPoint(x: c.x, y: c.y - gap))
            path.move(to: CGPoint(x: c.x, y: c.y + gap)); path.line(to: CGPoint(x: c.x, y: c.y + arm))
            path.lineCapStyle = .round
            path.lineWidth = 4.5
            NSColor.black.withAlphaComponent(0.55).setStroke()
            path.stroke()
            path.lineWidth = 2
            NSColor.white.setStroke()
            path.stroke()
            let dot = NSBezierPath(ovalIn: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3))
            NSColor.black.withAlphaComponent(0.55).setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
            NSColor.white.setFill()
            dot.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: size / 2, y: size / 2))
    }()
}
