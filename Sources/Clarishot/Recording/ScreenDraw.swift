import AppKit

/// Draw on screen while recording: a see-through layer over the recorded area that is part of
/// the video, plus a small toolbar that isn't. Off: clicks pass through to your apps.
/// On: drag to draw. Esc or ✓ stops drawing (strokes stay unless they fade); ⌘Z undoes.
@MainActor
final class ScreenDrawWindow: NSPanel {
    enum Tool: Int, CaseIterable {
        case pen, highlighter, arrow, rectangle
        var symbol: String { ["pencil.tip", "highlighter", "arrow.up.right", "rectangle"][rawValue] }
        var title: String { ["Pen", "Highlighter", "Arrow", "Rectangle"][rawValue] }
    }

    static let colors: [NSColor] = [NSColor(oklch: 0.63, 0.24, 27), NSColor(oklch: 0.80, 0.17, 85),
                                    NSColor(oklch: 0.70, 0.18, 145), NSColor(oklch: 0.62, 0.19, 258),
                                    NSColor(oklch: 1, 0, 0)]

    private let canvas = DrawView()
    fileprivate var drawToolbar: DrawToolbar?
    private(set) var isDrawing = false
    var onDrawingChange: ((Bool) -> Void)?

    init(rect: CGRect) {
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        canvas.frame = CGRect(origin: .zero, size: rect.size)
        canvas.autoresizingMask = [.width, .height]
        contentView = canvas
    }

    override var canBecomeKey: Bool { isDrawing }

    func toggle() { setDrawing(!isDrawing) }

    func setDrawing(_ on: Bool) {
        guard on != isDrawing else { return }
        isDrawing = on
        ignoresMouseEvents = !on
        canvas.isActive = on
        if on {
            let bar = drawToolbar ?? DrawToolbar(canvas: canvas) { [weak self] in self?.setDrawing(false) }
            drawToolbar = bar
            bar.place(above: frame, on: screen ?? NSScreen.main)
            bar.orderFrontRegardless()
            makeKey()
            invalidateCursorRects(for: canvas)
        } else {
            drawToolbar?.orderOut(nil)
            resignKey()
        }
        onDrawingChange?(on)
    }

    func close(clearing: Bool) {
        setDrawing(false)
        drawToolbar?.orderOut(nil)
        drawToolbar = nil
        orderOut(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { setDrawing(false); return } // Esc
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" { canvas.undo(); return }
        super.keyDown(with: event)
    }
}

// MARK: - Drawing

@MainActor
final class DrawView: NSView {
    struct Stroke {
        var tool: ScreenDrawWindow.Tool
        var color: NSColor
        var width: CGFloat
        var points: [CGPoint]
        var finished: Date?
    }

    var tool: ScreenDrawWindow.Tool = .pen
    var color: NSColor = ScreenDrawWindow.colors[0]
    var width: CGFloat = 5
    /// Strokes fade away a few seconds after you draw them.
    var fades = false { didSet { tickIfNeeded() } }
    var isActive = false

    private static let fadeAfter: TimeInterval = 2.5, fadeLength: TimeInterval = 0.6
    private var strokes: [Stroke] = []
    private var current: Stroke?
    private var timer: Timer?

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if isActive { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        let p = convert(event.locationInWindow, from: nil)
        current = Stroke(tool: tool, color: color, width: tool == .highlighter ? width * 4 : width, points: [p, p])
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var stroke = current else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch stroke.tool {
        case .pen, .highlighter: stroke.points.append(p)
        case .arrow, .rectangle: stroke.points[1] = p
        }
        current = stroke
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard var stroke = current else { return }
        current = nil
        stroke.finished = Date()
        strokes.append(stroke)
        tickIfNeeded()
        needsDisplay = true
    }

    func undo() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        needsDisplay = true
    }

    func clear() {
        strokes.removeAll()
        needsDisplay = true
    }

    /// While strokes are fading, redraw a few times a second and drop the gone ones.
    private func tickIfNeeded() {
        guard fades, timer == nil, !strokes.isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                self.strokes.removeAll { ($0.finished.map { now.timeIntervalSince($0) } ?? 0) > Self.fadeAfter + Self.fadeLength }
                self.needsDisplay = true
                if self.strokes.isEmpty || !self.fades { self.timer?.invalidate(); self.timer = nil }
            }
        }
    }

    private func alpha(of stroke: Stroke) -> CGFloat {
        guard fades, let finished = stroke.finished else { return 1 }
        let age = Date().timeIntervalSince(finished)
        return CGFloat(min(max(1 - (age - Self.fadeAfter) / Self.fadeLength, 0), 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        for stroke in strokes + (current.map { [$0] } ?? []) {
            let a = alpha(of: stroke)
            guard a > 0 else { continue }
            draw(stroke, alpha: a)
        }
    }

    private func draw(_ stroke: Stroke, alpha: CGFloat) {
        let base = stroke.tool == .highlighter ? 0.35 : 1
        stroke.color.withAlphaComponent(base * alpha).set()
        let path = NSBezierPath()
        path.lineWidth = stroke.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        guard let first = stroke.points.first, let last = stroke.points.last else { return }
        switch stroke.tool {
        case .pen, .highlighter:
            path.move(to: first)
            // Smooth the hand-drawn line through midpoints.
            for i in 1..<stroke.points.count {
                let a = stroke.points[i - 1], b = stroke.points[i]
                path.curve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), controlPoint1: a, controlPoint2: a)
            }
            path.line(to: last)
            path.stroke()
        case .rectangle:
            let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                              width: abs(last.x - first.x), height: abs(last.y - first.y))
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).then { $0.lineWidth = stroke.width; $0.stroke() }
        case .arrow:
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = max(14, stroke.width * 3.5)
            let tip = last
            let back = CGPoint(x: tip.x - cos(angle) * head * 0.8, y: tip.y - sin(angle) * head * 0.8)
            path.move(to: first)
            path.line(to: back)
            path.stroke()
            let triangle = NSBezierPath()
            triangle.move(to: tip)
            triangle.line(to: CGPoint(x: tip.x - cos(angle - 0.45) * head, y: tip.y - sin(angle - 0.45) * head))
            triangle.line(to: CGPoint(x: tip.x - cos(angle + 0.45) * head, y: tip.y - sin(angle + 0.45) * head))
            triangle.close()
            triangle.fill()
        }
    }
}

private extension NSBezierPath {
    func then(_ body: (NSBezierPath) -> Void) { body(self) }
}

// MARK: - Toolbar (not recorded)

@MainActor
private final class DrawToolbar: NSPanel {
    private let canvas: DrawView
    private var toolButtons: [PanelIconButton] = []
    private var colorButtons: [NSButton] = []
    private let onDone: () -> Void

    init(canvas: DrawView, onDone: @escaping () -> Void) {
        self.canvas = canvas
        self.onDone = onDone
        super.init(contentRect: CGRect(x: 0, y: 0, width: 400, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)

        let fallback = NSVisualEffectView()
        fallback.material = .hudWindow
        fallback.state = .active
        fallback.wantsLayer = true
        fallback.layer?.cornerRadius = 12
        fallback.layer?.masksToBounds = true
        let (outer, background) = AppAppearance.surface(cornerRadius: 12, fallback: fallback)

        var views: [NSView] = []
        for tool in ScreenDrawWindow.Tool.allCases {
            let button = PanelIconButton(symbol: tool.symbol, tip: tool.title)
            button.onClick = { [weak self] in self?.choose(tool) }
            toolButtons.append(button)
            views.append(button)
        }
        views.append(Self.divider())
        for (i, color) in ScreenDrawWindow.colors.enumerated() {
            let dot = NSButton(title: "", target: nil, action: nil)
            dot.isBordered = false
            dot.wantsLayer = true
            dot.layer?.backgroundColor = color.cgColor
            dot.layer?.cornerRadius = 9
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 18).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 18).isActive = true
            dot.tag = i
            dot.target = self
            dot.action = #selector(colorPicked(_:))
            colorButtons.append(dot)
            views.append(dot)
        }
        views.append(Self.divider())
        let fade = PanelIconButton(symbol: "wand.and.rays", onSymbol: "wand.and.rays", tip: "Fade strokes after a few seconds")
        fade.onClick = { [weak self, weak fade] in
            guard let self, let fade else { return }
            fade.isOn.toggle()
            self.canvas.fades = fade.isOn
        }
        let undo = PanelIconButton(symbol: "arrow.uturn.backward", tip: "Undo (⌘Z)")
        undo.onClick = { [weak self] in self?.canvas.undo() }
        let clear = PanelIconButton(symbol: "trash", tip: "Clear drawing")
        clear.onClick = { [weak self] in self?.canvas.clear() }
        let done = PanelIconButton(symbol: "checkmark", tip: "Stop drawing (Esc)")
        done.contentTintColor = .systemGreen
        done.onClick = { [weak self] in self?.onDone() }
        views += [fade, undo, clear, done]

        let stack = NSStackView(views: views)
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        contentView = outer
        setContentSize(outer.fittingSize)
        choose(.pen)
        colorPicked(colorButtons[0])
    }

    private static func divider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return line
    }

    private func choose(_ tool: ScreenDrawWindow.Tool) {
        canvas.tool = tool
        for (i, button) in toolButtons.enumerated() {
            button.layer?.backgroundColor = i == tool.rawValue ? NSColor.white.withAlphaComponent(0.22).cgColor : nil
        }
    }

    @objc private func colorPicked(_ sender: NSButton) {
        canvas.color = ScreenDrawWindow.colors[sender.tag]
        for dot in colorButtons {
            dot.layer?.borderWidth = dot === sender ? 2 : 0
            dot.layer?.borderColor = NSColor.white.cgColor
        }
    }

    /// Centred just above the drawing area, or inside its top edge when there's no room.
    func place(above area: CGRect, on screen: NSScreen?) {
        let visible = screen?.visibleFrame ?? area
        var origin = CGPoint(x: area.midX - frame.width / 2, y: area.maxY + 10)
        if origin.y + frame.height > visible.maxY { origin.y = area.maxY - frame.height - 10 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        setFrameOrigin(origin)
    }
}
