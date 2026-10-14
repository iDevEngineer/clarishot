import AppKit
import os

private let overlayLog = Logger(subsystem: "com.scottmackey.snapzy", category: "selection")

enum SelectionMode {
    case area
    case window
    /// Area you can move and resize, then pick what to do from an action bar.
    case allInOne
    /// Adjustable area for scrolling capture, confirmed with a Start Capture pill.
    case scrollArea
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

    private var keyTap: KeyTap?

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        // Keys may still go to the app behind (macOS doesn't always let us become active),
        // so catch Space, Esc and Return system-wide while the overlay is up.
        keyTap = KeyTap { [weak self] keyCode, isDown in self?.handleKey(keyCode, isDown: isDown) ?? false }
        for window in windows { window.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        let keyWindow = windows.first { $0.frame.contains(mouse) } ?? windows.first
        keyWindow?.makeKey()
        keyWindow?.makeFirstResponder(keyWindow?.contentView)
        if let view = keyWindow?.contentView as? OverlayView, view.isWindowMode {
            CameraCursor.shared.set()
        } else {
            CrosshairCursor.shared.set()
        }
    }

    /// Returns true if the key was used (and should not reach other apps).
    private func handleKey(_ keyCode: Int64, isDown: Bool) -> Bool {
        let views = windows.compactMap { $0.contentView as? OverlayView }
        switch keyCode {
        case 49: // space: move the box while dragging
            views.forEach { $0.setSpaceHeld(isDown) }
            return true
        case 53: // esc
            if isDown { finish(nil) }
            return true
        case 36, 76: // return, enter
            if isDown { return views.contains { $0.pressReturn() } }
            return false
        default:
            return false
        }
    }

    private func finish(_ result: SelectionResult?) {
        guard !finished else { return }
        finished = true
        keyTap = nil
        for window in windows {
            (window.contentView as? OverlayView)?.stopWatchingKeys()
            window.orderOut(nil)
        }
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
    /// Holding Space while dragging out an area moves the whole box instead of resizing it.
    private var spaceHeld = false {
        didSet { if spaceHeld != oldValue { overlayLog.notice("space held: \(self.spaceHeld, privacy: .public)") } }
    }
    private var lastDragPoint: CGPoint?
    private var keyMonitor: Any?

    /// Watches Space at the app level, so it's seen even mid-drag (before any window handles it).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard event.keyCode == 49 else { return event }
                let down = event.type == .keyDown
                MainActor.assumeIsolated { self?.spaceHeld = down }
                return nil
            }
        } else if window == nil {
            stopWatchingKeys()
        }
    }

    func stopWatchingKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
    /// Modes where the selection stays on screen to be moved and resized.
    private var editable: Bool { mode == .allInOne || mode == .scrollArea }
    private var startBar: ScrollStartBar?
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
        if editable, let initialSelection, bounds.contains(initialSelection) {
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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mode == .window ? CameraCursor.shared : CrosshairCursor.shared)
    }
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
        if editable, let rect = selection {
            if let handle = handle(at: p, in: rect) {
                interaction = .resizing(handle: handle, original: rect)
                actionBar?.isHidden = true
                startBar?.isHidden = true
                return
            }
            if rect.contains(p) {
                interaction = .moving(grab: p, original: rect)
                actionBar?.isHidden = true
                startBar?.isHidden = true
                return
            }
        }
        interaction = .drawing(start: p)
        lastDragPoint = p
        selection = nil
        actionBar?.isHidden = true
        startBar?.isHidden = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        mouse = point
        defer { lastDragPoint = point }
        switch interaction {
        case .none:
            return
        case .drawing(var start):
            if spaceHeld, let last = lastDragPoint, let current = selection {
                // Move the box (and its anchor corner) with the mouse, kept on screen.
                var dx = point.x - last.x, dy = point.y - last.y
                dx = min(max(dx, -current.minX), bounds.maxX - current.maxX)
                dy = min(max(dy, -current.minY), bounds.maxY - current.maxY)
                start = CGPoint(x: start.x + dx, y: start.y + dy)
                interaction = .drawing(start: start)
                // Move without rounding: rounding outward on every step made the box grow.
                selection = current.offsetBy(dx: dx, dy: dy)
            } else {
                var rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                  width: abs(point.x - start.x), height: abs(point.y - start.y))
                if aspectLocked { rect = lockAspect(rect, anchor: start) }
                selection = rect.integral
            }
        case .moving(let grab, let original):
            var rect = original.offsetBy(dx: point.x - grab.x, dy: point.y - grab.y)
            rect.origin.x = min(max(rect.minX, 0), bounds.maxX - rect.width).rounded()
            rect.origin.y = min(max(rect.minY, 0), bounds.maxY - rect.height).rounded()
            selection = rect
        case .resizing(let handle, let original):
            selection = resized(original, handle: handle, to: point).integral
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let rect = selection {
            selection = CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(),
                               width: rect.width.rounded(), height: rect.height.rounded())
        }
        defer {
            interaction = .none
            spaceHeld = false
            lastDragPoint = nil
        }
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
        case .allInOne, .scrollArea:
            if let rect = selection, rect.width >= 4, rect.height >= 4 {
                if !aspectLocked { aspectRatio = rect.width / max(rect.height, 1) }
                showActionBar()
            } else {
                selection = nil
                actionBar?.isHidden = true
                startBar?.isHidden = true
            }
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onFinish?(nil)
        case 36 where editable, 76 where editable: perform(mode == .scrollArea ? .scrolling : .screenshot)
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onFinish?(nil) }

    // MARK: All-In-One

    var isWindowMode: Bool { mode == .window }

    func setSpaceHeld(_ held: Bool) { spaceHeld = held }

    /// Return in All-In-One / scrolling selection; false if there's nothing to confirm.
    func pressReturn() -> Bool {
        guard editable, selection != nil else { return false }
        perform(mode == .scrollArea ? .scrolling : .screenshot)
        return true
    }

    private func perform(_ action: AllInOneAction) {
        guard let rect = selection, rect.width >= 4, rect.height >= 4 else { return }
        onFinish?(.allInOne(shot, rect, action))
    }

    private func showActionBar() {
        guard let rect = selection else { return }
        if mode == .scrollArea {
            let pill = startBar ?? makeStartBar()
            pill.isHidden = false
            // Sits on the bottom edge, like a tab hanging off the selection.
            let size = pill.fittingSize
            var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 8)
            if origin.y < 8 { origin.y = rect.minY + 8 }
            origin.x = min(max(origin.x, 8), bounds.maxX - size.width - 8)
            pill.frame = CGRect(origin: origin, size: size)
            return
        }
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

    private func makeStartBar() -> ScrollStartBar {
        let bar = ScrollStartBar()
        bar.onStart = { [weak self] in self?.perform(.scrolling) }
        addSubview(bar)
        startBar = bar
        return bar
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
        if mode == .window {
            CameraCursor.shared.set()
            return
        }
        guard editable, let rect = selection, let mouse, case .none = interaction else {
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
        case .area, .allInOne, .scrollArea: drawArea(ctx)
        case .window: drawWindowHighlight(ctx)
        }
        if let hint, selection == nil { drawHint(hint) }
        if Settings.shared.showMagnifier, mode != .window, mode != .scrollArea, let mouse, isDrawingOrIdle {
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

    /// Large light instruction pill in the middle of the screen.
    private func drawHint(_ text: String) {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .medium),
            .foregroundColor: NSColor.black.withAlphaComponent(0.82)
        ])
        let size = string.size()
        let box = CGRect(x: (bounds.midX - size.width / 2 - 30).rounded(), y: (bounds.midY - size.height / 2 - 16).rounded(),
                         width: (size.width + 60).rounded(), height: (size.height + 32).rounded())
        let pill = NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = CGSize(width: 0, height: -4)
        shadow.set()
        NSColor(white: 0.9, alpha: 0.92).setFill()
        pill.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.6).setStroke()
        pill.lineWidth = 1
        pill.stroke()
        string.draw(at: CGPoint(x: box.minX + 30, y: box.minY + 16))
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

            if editable, case .drawing = interaction {} else if editable { drawHandles(for: rect, ctx) }
            if case .none = interaction, editable { return } // the bar shows the size
            drawLabel("\(Int(rect.width)) × \(Int(rect.height))", near: mouse ?? CGPoint(x: rect.maxX, y: rect.minY))
        } else {
            if mode == .scrollArea {
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
                ctx.fill(bounds)
            }
            if let mouse { drawLabel("\(Int(mouse.x)), \(Int(bounds.height - mouse.y))", near: mouse) }
        }
    }

    /// Corner brackets plus short bars on each edge, for resizing.
    private func drawHandles(for rect: CGRect, _ ctx: CGContext) {
        let arm: CGFloat = 12, bar: CGFloat = 10
        let path = CGMutablePath()
        for (x, y, dx, dy) in [(rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0),
                               (rect.maxX, rect.minY, -1.0, 1.0), (rect.minX, rect.minY, 1.0, 1.0)] {
            path.move(to: CGPoint(x: x + dx * arm, y: y))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + dy * arm))
        }
        path.move(to: CGPoint(x: rect.midX - bar, y: rect.maxY)); path.addLine(to: CGPoint(x: rect.midX + bar, y: rect.maxY))
        path.move(to: CGPoint(x: rect.midX - bar, y: rect.minY)); path.addLine(to: CGPoint(x: rect.midX + bar, y: rect.minY))
        path.move(to: CGPoint(x: rect.minX, y: rect.midY - bar)); path.addLine(to: CGPoint(x: rect.minX, y: rect.midY + bar))
        path.move(to: CGPoint(x: rect.maxX, y: rect.midY - bar)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY + bar))
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(5)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.restoreGState()
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

/// "↓ Start Capture" pill under a scrolling-capture selection.
@MainActor
final class ScrollStartBar: NSView {
    var onStart: (() -> Void)?

    init() {
        super.init(frame: .zero)
        let start = PillLabelButton(title: "Start Capture", symbol: "arrow.down", light: true) { [weak self] in self?.onStart?() }
        start.toolTip = "Select only the part that scrolls, then scroll slowly or use Auto-Scroll. Return also starts."
        start.translatesAutoresizingMaskIntoConstraints = false
        addSubview(start)
        NSLayoutConstraint.activate([
            start.leadingAnchor.constraint(equalTo: leadingAnchor),
            start.trailingAnchor.constraint(equalTo: trailingAnchor),
            start.topAnchor.constraint(equalTo: topAnchor),
            start.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Rounded pill with an icon and a title, centred together with even padding.
/// Light = white with dark text; dark = translucent black with white text.
@MainActor
final class PillLabelButton: NSView {
    private let handler: () -> Void
    private let light: Bool
    private var pressed = false { didSet { updateLook() } }

    init(title: String, symbol: String, light: Bool, handler: @escaping () -> Void) {
        self.handler = handler
        self.light = light
        super.init(frame: .zero)
        wantsLayer = true
        let height: CGFloat = 30
        layer?.cornerRadius = height / 2
        layer?.shadowOpacity = 0.2
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        let tint = light ? NSColor.black.withAlphaComponent(0.85) : NSColor.white
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 11, weight: .bold)
        icon.contentTintColor = tint
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = tint
        let stack = NSStackView(views: title.isEmpty ? [icon] : [icon, label])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: title.isEmpty ? 8 : 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: title.isEmpty ? -8 : -16)
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The whole pill is one click target (the icon and label never take the click).
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) && !isHidden ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { if isEnabled { pressed = true } }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        if isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) { handler() }
    }

    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.5 } }

    private func updateLook() {
        let base = light ? NSColor.white : NSColor.black.withAlphaComponent(0.72)
        let down = light ? NSColor(white: 0.88, alpha: 1) : NSColor.black.withAlphaComponent(0.85)
        layer?.backgroundColor = (pressed ? down : base).cgColor
    }
}

/// Intercepts key presses for the whole system while it exists (needs Accessibility).
/// The handler returns true to swallow a key so it doesn't reach the app behind.
/// Without permission it does nothing; the overlay's own key handling still applies.
@MainActor
final class KeyTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let handler: (Int64, Bool) -> Bool

    init(handler: @escaping (Int64, Bool) -> Bool) {
        self.handler = handler
        guard AXIsProcessTrusted() else {
            overlayLog.notice("key tap: no Accessibility permission")
            return
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let swallow = MainActor.assumeIsolated { me.handler(code, type == .keyDown) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }, userInfo: refcon) else { return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = source
        CGEvent.tapEnable(tap: tap, enable: true)
        overlayLog.notice("key tap: active")
    }

    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}

/// Camera pointer for picking a window, like macOS's own window screenshot.
@MainActor
enum CameraCursor {
    static let shared: NSCursor = {
        let size: CGFloat = 32
        let image = NSImage(size: CGSize(width: size, height: size), flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
            guard let symbol = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return false }
            let s = symbol.size
            let at = CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height)
            // Dark outline under a white camera so it shows on any background.
            for (dx, dy) in [(-1.5, 0.0), (1.5, 0.0), (0.0, -1.5), (0.0, 1.5)] {
                tinted(symbol, .black.withAlphaComponent(0.6)).draw(in: at.offsetBy(dx: dx, dy: dy))
            }
            tinted(symbol, .white).draw(in: at)
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: size / 2, y: size / 2))
    }()

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
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
