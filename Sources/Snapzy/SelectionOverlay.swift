import AppKit

enum SelectionMode {
    case area
    case window
    /// Area you can move and resize, then pick what to do from an action bar.
    case allInOne
}

/// What to do with an All-In-One selection.
enum AllInOneAction {
    case screenshot, text, scrolling, record, timer
}

enum SelectionResult {
    case area(ScreenShot, CGRect) // rect in screen-local points
    case window(CGWindowID)
    case allInOne(ScreenShot, CGRect, AllInOneAction)
}

/// Full-screen overlay windows (one per display) showing a frozen copy of the
/// screen, for dragging out an area or clicking a window. Esc cancels.
@MainActor
final class SelectionOverlayController {
    private var windows: [OverlayWindow] = []
    private let completion: (SelectionResult?) -> Void
    private let previousApp = NSWorkspace.shared.frontmostApplication
    private var finished = false

    /// `initial` pre-selects an area (All-In-One remembers the last one).
    init(shots: [ScreenShot], mode: SelectionMode, targets: [WindowTarget], hint: String? = nil,
         initial: (displayID: CGDirectDisplayID, rect: CGRect)? = nil,
         completion: @escaping (SelectionResult?) -> Void) {
        self.completion = completion
        for shot in shots {
            let window = OverlayWindow(contentRect: shot.screen.frame, styleMask: .borderless,
                                       backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            // No zoom-in when it appears: the overlay shows a frozen copy of the screen,
            // so macOS's appear animation made the whole screen seem to shrink.
            window.animationBehavior = .none
            window.level = .screenSaver
            window.isOpaque = true
            window.hasShadow = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let start = initial.flatMap { ScreenCapturer.displayID(for: shot.screen) == $0.displayID ? $0.rect : nil }
            let view = OverlayView(frame: CGRect(origin: .zero, size: shot.screen.frame.size),
                                   shot: shot, mode: mode, targets: targets, hint: hint, initialSelection: start)
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

@MainActor
final class OverlayView: NSView {
    var onFinish: ((SelectionResult?) -> Void)?

    private let shot: ScreenShot
    private let mode: SelectionMode
    private let targets: [WindowTarget]
    private let hint: String?
    private var mouse: CGPoint?
    private var selection: CGRect?
    private var hovered: WindowTarget?

    /// What the current drag is doing.
    private enum Interaction {
        case none
        case drawing(start: CGPoint)
        case moving(grab: CGPoint, original: CGRect)
        case resizing(handle: Handle, original: CGRect)
    }

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private var interaction: Interaction = .none
    private var actionBar: AllInOneBar?
    private var aspectLocked = false
    private var aspectRatio: CGFloat = 1

    init(frame: CGRect, shot: ScreenShot, mode: SelectionMode, targets: [WindowTarget], hint: String? = nil,
         initialSelection: CGRect? = nil) {
        self.hint = hint
        self.shot = shot
        self.mode = mode
        self.targets = targets
        super.init(frame: frame)
        let global = NSEvent.mouseLocation
        if shot.screen.frame.contains(global) { mouse = toLocal(global) }
        updateHover()
        if mode == .allInOne, let initialSelection, bounds.contains(initialSelection) {
            selection = initialSelection
            showActionBar()
        }
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
    override func cursorUpdate(with event: NSEvent) { updateCursor() }

    // MARK: Mouse and keys

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        updateHover()
        updateCursor()
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    override func mouseExited(with event: NSEvent) {
        if case .none = interaction {
            mouse = nil
            hovered = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard mode != .window else { return }
        let p = convert(event.locationInWindow, from: nil)
        if mode == .allInOne, let rect = selection {
            if let handle = handle(at: p, in: rect) {
                interaction = .resizing(handle: handle, original: rect)
                actionBar?.isHidden = true
                return
            }
            if rect.contains(p) {
                interaction = .moving(grab: p, original: rect)
                actionBar?.isHidden = true
                return
            }
        }
        interaction = .drawing(start: p)
        selection = nil
        actionBar?.isHidden = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        mouse = point
        switch interaction {
        case .none:
            return
        case .drawing(let start):
            var rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(point.x - start.x), height: abs(point.y - start.y))
            if aspectLocked { rect = lockAspect(rect, anchor: start) }
            selection = rect.integral
        case .moving(let grab, let original):
            var rect = original.offsetBy(dx: point.x - grab.x, dy: point.y - grab.y)
            rect.origin.x = min(max(rect.minX, 0), bounds.maxX - rect.width)
            rect.origin.y = min(max(rect.minY, 0), bounds.maxY - rect.height)
            selection = rect.integral
        case .resizing(let handle, let original):
            selection = resized(original, handle: handle, to: point).integral
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { interaction = .none }
        switch mode {
        case .area:
            if let rect = selection, rect.width >= 4, rect.height >= 4 {
                onFinish?(.area(shot, rect))
            } else {
                selection = nil
                needsDisplay = true
            }
        case .window:
            if let hovered { onFinish?(.window(hovered.id)) }
        case .allInOne:
            if let rect = selection, rect.width >= 4, rect.height >= 4 {
                if !aspectLocked { aspectRatio = rect.width / max(rect.height, 1) }
                showActionBar()
            } else {
                selection = nil
                actionBar?.isHidden = true
            }
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onFinish?(nil)
        case 36 where mode == .allInOne, 76 where mode == .allInOne: perform(.screenshot)
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onFinish?(nil) }

    // MARK: All-In-One

    private func perform(_ action: AllInOneAction) {
        guard let rect = selection, rect.width >= 4, rect.height >= 4 else { return }
        onFinish?(.allInOne(shot, rect, action))
    }

    private func showActionBar() {
        guard let rect = selection else { return }
        let bar = actionBar ?? makeActionBar()
        bar.update(size: rect.size, locked: aspectLocked)
        bar.isHidden = false
        // Below the area, else above it, else inside its bottom edge.
        let size = bar.fittingSize
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if origin.y < 8 { origin.y = rect.maxY + 12 }
        if origin.y + size.height > bounds.maxY - 8 { origin.y = rect.minY + 12 }
        origin.x = min(max(origin.x, 8), bounds.maxX - size.width - 8)
        bar.frame = CGRect(origin: origin, size: size)
    }

    private func makeActionBar() -> AllInOneBar {
        let bar = AllInOneBar()
        bar.onAction = { [weak self] action in self?.perform(action) }
        bar.onCancel = { [weak self] in self?.onFinish?(nil) }
        bar.onToggleLock = { [weak self] in
            guard let self, let rect = self.selection else { return }
            self.aspectLocked.toggle()
            self.aspectRatio = rect.width / max(rect.height, 1)
            self.showActionBar()
        }
        bar.onSize = { [weak self] size in
            guard let self, var rect = self.selection else { return }
            // Keep the top-left corner fixed.
            rect = CGRect(x: rect.minX, y: rect.maxY - size.height, width: size.width, height: size.height)
            rect.origin.x = min(max(rect.minX, 0), max(self.bounds.maxX - rect.width, 0))
            rect.origin.y = min(max(rect.minY, 0), max(self.bounds.maxY - rect.height, 0))
            self.selection = rect.intersection(self.bounds).integral
            self.aspectRatio = rect.width / max(rect.height, 1)
            self.showActionBar()
            self.needsDisplay = true
            self.window?.makeFirstResponder(self)
        }
        addSubview(bar)
        actionBar = bar
        return bar
    }

    private func handleRects(for rect: CGRect) -> [(Handle, CGRect)] {
        let s: CGFloat = 10
        func box(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s) }
        return [
            (.topLeft, box(rect.minX, rect.maxY)), (.top, box(rect.midX, rect.maxY)),
            (.topRight, box(rect.maxX, rect.maxY)), (.right, box(rect.maxX, rect.midY)),
            (.bottomRight, box(rect.maxX, rect.minY)), (.bottom, box(rect.midX, rect.minY)),
            (.bottomLeft, box(rect.minX, rect.minY)), (.left, box(rect.minX, rect.midY))
        ]
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> Handle? {
        handleRects(for: rect).first { $0.1.insetBy(dx: -4, dy: -4).contains(point) }?.0
    }

    private func resized(_ r: CGRect, handle: Handle, to p: CGPoint) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch handle {
        case .topLeft: minX = p.x; maxY = p.y
        case .top: maxY = p.y
        case .topRight: maxX = p.x; maxY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; minY = p.y
        case .bottom: minY = p.y
        case .bottomLeft: minX = p.x; minY = p.y
        case .left: minX = p.x
        }
        var rect = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        if aspectLocked {
            if handle == .top || handle == .bottom {
                rect.size.width = rect.height * aspectRatio
            } else {
                let h = rect.width / aspectRatio
                if handle == .topLeft || handle == .topRight { rect.origin.y = rect.minY } else { rect.origin.y = rect.maxY - h }
                rect.size.height = h
            }
        }
        return rect
    }

    private func lockAspect(_ rect: CGRect, anchor: CGPoint) -> CGRect {
        let h = rect.width / aspectRatio
        let y = rect.minY < anchor.y ? anchor.y - h : anchor.y
        return CGRect(x: rect.minX, y: y, width: rect.width, height: h)
    }

    private func updateCursor() {
        guard mode == .allInOne, let rect = selection, let mouse, case .none = interaction else {
            CrosshairCursor.shared.set()
            return
        }
        if let handle = handle(at: mouse, in: rect) {
            switch handle {
            case .left, .right: NSCursor.resizeLeftRight.set()
            case .top, .bottom: NSCursor.resizeUpDown.set()
            default: NSCursor.crosshair.set()
            }
        } else if rect.contains(mouse) {
            NSCursor.openHand.set()
        } else {
            CrosshairCursor.shared.set()
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(shot.image, in: bounds)

        switch mode {
        case .area, .allInOne: drawArea(ctx)
        case .window: drawWindowHighlight(ctx)
        }
        if let hint, selection == nil { drawHint(hint) }
        if Settings.shared.showMagnifier, mode != .window, let mouse, isDrawingOrIdle {
            drawMagnifier(at: mouse, ctx)
        }
    }

    private var isDrawingOrIdle: Bool {
        switch interaction {
        case .none: return selection == nil || mode == .area
        case .drawing: return true
        default: return false
        }
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

            if mode == .allInOne, case .drawing = interaction {} else if mode == .allInOne {
                for (_, box) in handleRects(for: rect) {
                    let dot = NSBezierPath(ovalIn: box.insetBy(dx: 1, dy: 1))
                    NSColor.white.setFill()
                    dot.fill()
                    NSColor.black.withAlphaComponent(0.4).setStroke()
                    dot.lineWidth = 1
                    dot.stroke()
                }
            }
            if case .none = interaction, mode == .allInOne { return } // the bar shows the size
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

    /// Round loupe above-right of the cursor showing the pixels under it, plus their colour.
    private func drawMagnifier(at point: CGPoint, _ ctx: CGContext) {
        let pixelsAcross = 15
        let diameter: CGFloat = 120
        let sx = CGFloat(shot.image.width) / bounds.width
        let sy = CGFloat(shot.image.height) / bounds.height
        let cx = Int(point.x * sx), cy = Int((bounds.height - point.y) * sy)
        let half = pixelsAcross / 2
        let source = CGRect(x: cx - half, y: cy - half, width: pixelsAcross, height: pixelsAcross)
        guard let patch = shot.image.cropping(to: source.intersection(CGRect(x: 0, y: 0, width: shot.image.width,
                                                                             height: shot.image.height))) else { return }

        var center = CGPoint(x: point.x + 30 + diameter / 2, y: point.y + 30 + diameter / 2)
        if center.x + diameter / 2 > bounds.maxX { center.x = point.x - 30 - diameter / 2 }
        if center.y + diameter / 2 > bounds.maxY { center.y = point.y - 30 - diameter / 2 }
        let circle = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 10, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillEllipse(in: circle)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addEllipse(in: circle)
        ctx.clip()
        ctx.interpolationQuality = .none
        ctx.draw(patch, in: circle)
        // Outline the centre pixel.
        let cell = diameter / CGFloat(pixelsAcross)
        let centerCell = CGRect(x: circle.midX - cell / 2, y: circle.midY - cell / 2, width: cell, height: cell)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(centerCell)
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: circle.insetBy(dx: 1, dy: 1))

        if let hex = Self.hexColor(of: patch, x: half, y: half) {
            let string = NSAttributedString(string: hex, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white
            ])
            let size = string.size()
            let box = CGRect(x: circle.midX - size.width / 2 - 6, y: circle.minY - size.height - 10,
                             width: size.width + 12, height: size.height + 4)
            NSColor.black.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            string.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 2))
        }
    }

    private static func hexColor(of image: CGImage, x: Int, y: Int) -> String? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Draw so the wanted pixel (top-left origin) lands on the single output pixel.
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2])
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

/// Dark bar under an All-In-One selection: capture actions, size and aspect lock.
@MainActor
final class AllInOneBar: NSVisualEffectView, NSTextFieldDelegate {
    var onAction: ((AllInOneAction) -> Void)?
    var onCancel: (() -> Void)?
    var onToggleLock: (() -> Void)?
    var onSize: ((CGSize) -> Void)?

    private let widthField = SizeField()
    private let heightField = SizeField()
    private let lockButton = PanelIconButton(symbol: "lock.open", onSymbol: "lock.fill", tip: "Lock aspect ratio")

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        state = .active
        blendingMode = .withinWindow
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        let actions: [(String, String, AllInOneAction)] = [
            ("camera.viewfinder", "Capture screenshot (↩)", .screenshot),
            ("text.viewfinder", "Capture text (OCR)", .text),
            ("arrow.down.doc", "Scrolling capture", .scrolling),
            ("record.circle", "Record screen", .record),
            ("timer", "Self-timer", .timer)
        ]
        let buttons: [NSView] = actions.map { symbol, tip, action in
            let button = PanelIconButton(symbol: symbol, tip: tip)
            button.onClick = { [weak self] in self?.onAction?(action) }
            return button
        }
        for f in [widthField, heightField] { f.delegate = self }
        let times = NSTextField(labelWithString: "×")
        times.textColor = .secondaryLabelColor
        lockButton.onClick = { [weak self] in self?.onToggleLock?() }
        let cancel = PanelIconButton(symbol: "xmark", tip: "Cancel (Esc)")
        cancel.onClick = { [weak self] in self?.onCancel?() }

        let stack = NSStackView(views: buttons + [divider(), widthField, times, heightField, lockButton, divider(), cancel])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(size: CGSize, locked: Bool) {
        widthField.integerValue = Int(size.width)
        heightField.integerValue = Int(size.height)
        lockButton.isOn = locked
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        onSize?(CGSize(width: max(CGFloat(widthField.integerValue), 4), height: max(CGFloat(heightField.integerValue), 4)))
    }

    private func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return box
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
