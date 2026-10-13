import AppKit

/// Shows the screenshot with its annotations and turns mouse input into shapes.
@MainActor
final class CanvasView: NSView, NSTextFieldDelegate {
    let document: AnnotateDocument

    var tool: Tool = .arrow {
        didSet { commitText(); selectedIndex = nil; needsDisplay = true; window?.invalidateCursorRects(for: self) }
    }
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var arrowStyle: ArrowStyle = .straight
    var textStyle: TextStyle = .outline
    /// Width ÷ height for the crop tool, or nil for free cropping.
    var cropAspect: CGFloat?

    /// Called after any change, so the toolbar can refresh undo/redo.
    var onChange: (() -> Void)?
    /// Called when a tool's letter key is pressed.
    var onToolShortcut: ((Tool) -> Void)?

    private var draft: Annotation?
    private var cropStart: CGPoint?
    private var cropDraft: CGRect?
    private var selectedIndex: Int?
    private var lastDragPoint: CGPoint?
    private var movedSinceMouseDown = false
    private var textField: NSTextField?
    private var textAnchor: CGPoint?
    /// The text annotation being re-edited; hidden while its field is open.
    private var editingIndex: Int?

    private let margin: CGFloat = 32

    init(document: AnnotateDocument) {
        self.document = document
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(imageRectInView, cursor: tool == .select ? .arrow : (tool == .text ? .iBeam : .crosshair))
    }

    // MARK: Coordinate mapping (view points <-> image points)

    /// Padding around the image when the background is on, in image points.
    /// Space around the image for the background (x = sides, y = top and bottom), in image points.
    private var backgroundInset: CGSize {
        document.background.enabled ? document.background.insets(for: document.crop.size) : .zero
    }

    private var viewScale: CGFloat {
        let crop = document.crop
        let available = bounds.insetBy(dx: margin, dy: margin)
        let inset = backgroundInset
        let total = CGSize(width: crop.width + 2 * inset.width, height: crop.height + 2 * inset.height)
        return min(1, available.width / max(total.width, 1), available.height / max(total.height, 1))
    }

    /// Screenshot plus background, in view points.
    private var frameRectInView: CGRect {
        let s = viewScale
        let inset = backgroundInset
        let size = CGSize(width: (document.crop.width + 2 * inset.width) * s, height: (document.crop.height + 2 * inset.height) * s)
        return CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                      width: size.width, height: size.height)
    }

    private var imageRectInView: CGRect {
        frameRectInView.insetBy(dx: backgroundInset.width * viewScale, dy: backgroundInset.height * viewScale)
    }

    private func toImage(_ p: CGPoint) -> CGPoint {
        let r = imageRectInView, s = viewScale
        return CGPoint(x: (p.x - r.minX) / s + document.crop.minX, y: (p.y - r.minY) / s + document.crop.minY)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let r = imageRectInView, s = viewScale
        return CGPoint(x: (p.x - document.crop.minX) * s + r.minX, y: (p.y - document.crop.minY) * s + r.minY)
    }

    private func toView(_ rect: CGRect) -> CGRect {
        let origin = toView(rect.origin)
        return CGRect(x: origin.x, y: origin.y, width: rect.width * viewScale, height: rect.height * viewScale)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()

        let imageRect = imageRectInView
        let style = document.background
        if style.enabled {
            style.fill.fill(frameRectInView, in: ctx, flipped: true)
        } else {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 18, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(imageRect)
            ctx.restoreGState()
        }

        // Render the annotated screenshot at view size, then frame it.
        let annotations = visibleAnnotations()
        if style.enabled, let flat = renderedForView(annotations: annotations) {
            BackgroundRenderer.drawFramedImage(flat, in: imageRect, radius: style.cornerRadius * viewScale,
                                               shadow: style.shadow, shadowScale: viewScale, ctx: ctx, flipped: true)
        } else {
            ctx.saveGState()
            ctx.clip(to: imageRect)
            applyImageTransform(ctx, imageRect)
            AnnotationRenderer.drawImage(document.baseImage, in: CGRect(origin: .zero, size: document.imageSize), ctx: ctx)
            AnnotationRenderer.drawAll(annotations, in: ctx, effects: document.effects, imageSize: document.imageSize)
            ctx.restoreGState()
        }

        if let index = selectedIndex, document.annotations.indices.contains(index) {
            let outline = NSBezierPath(roundedRect: toView(document.annotations[index].bounds), xRadius: 4, yRadius: 4)
            outline.lineWidth = 1
            outline.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            outline.stroke()
        }

        if let crop = cropDraft { drawCropDraft(toView(crop), in: imageRect, ctx) }
    }

    private func applyImageTransform(_ ctx: CGContext, _ imageRect: CGRect) {
        ctx.translateBy(x: imageRect.minX, y: imageRect.minY)
        ctx.scaleBy(x: viewScale, y: viewScale)
        ctx.translateBy(x: -document.crop.minX, y: -document.crop.minY)
    }

    /// The annotated, cropped screenshot as an image at screen resolution (for rounded corners).
    private func renderedForView(annotations: [Annotation]) -> CGImage? {
        let pixelScale = viewScale * (window?.backingScaleFactor ?? 2)
        return AnnotationRenderer.render(base: document.baseImage, scale: pixelScale, imageSize: document.imageSize,
                                         crop: document.crop, annotations: annotations, effects: document.effects)
    }

    private func visibleAnnotations() -> [Annotation] {
        var list = document.annotations
        if let editingIndex, list.indices.contains(editingIndex) { list.remove(at: editingIndex) }
        if let draft { list.append(draft) }
        return list
    }

    private func drawCropDraft(_ rect: CGRect, in imageRect: CGRect, _ ctx: CGContext) {
        let path = CGMutablePath()
        path.addRect(imageRect)
        path.addRect(rect)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        commitText()
        window?.makeFirstResponder(self)
        let p = toImage(convert(event.locationInWindow, from: nil))
        movedSinceMouseDown = false

        // Double-click a text label (with any tool) to edit it.
        if event.clickCount == 2,
           let index = document.annotations.indices.last(where: {
               document.annotations[$0].tool == .text && document.annotations[$0].bounds.contains(p)
           }) {
            editText(at: index)
            return
        }

        switch tool {
        case .select:
            selectedIndex = document.annotations.indices.last { document.annotations[$0].bounds.contains(p) }
            lastDragPoint = p
        case .crop:
            cropStart = clampToImage(p)
        case .text:
            beginText(at: p, text: "", color: color, lineWidth: lineWidth)
        case .counter:
            document.checkpoint()
            document.annotations.append(Annotation(tool: .counter, start: p, end: p, color: color,
                                                   lineWidth: lineWidth, number: document.nextCounterNumber))
            changed()
        default:
            draft = Annotation(tool: tool, start: p, end: p, points: [p], color: color, lineWidth: lineWidth,
                               style: tool == .arrow ? arrowStyle.rawValue : 0)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        var p = toImage(convert(event.locationInWindow, from: nil))
        let shift = event.modifierFlags.contains(.shift)

        switch tool {
        case .select:
            guard let index = selectedIndex, let last = lastDragPoint else { return }
            if !movedSinceMouseDown { document.checkpoint(); movedSinceMouseDown = true }
            document.annotations[index].move(by: CGVector(dx: p.x - last.x, dy: p.y - last.y))
            lastDragPoint = p
        case .crop:
            guard let start = cropStart else { return }
            p = clampToImage(p)
            if let ratio = cropAspect {
                // Keep the chosen shape: follow the wider drag direction.
                var w = abs(p.x - start.x), h = abs(p.y - start.y)
                if w / max(h, 1) > ratio { h = w / ratio } else { w = h * ratio }
                p = CGPoint(x: start.x + (p.x < start.x ? -w : w), y: start.y + (p.y < start.y ? -h : h))
            }
            cropDraft = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                               width: abs(p.x - start.x), height: abs(p.y - start.y)).intersection(document.crop).integral
        default:
            guard var d = draft else { return }
            if shift { p = constrained(p, from: d.start, tool: d.tool) }
            d.end = p
            if d.tool.isFreehand {
                // Shift on the highlighter draws a straight stroke.
                if shift && d.tool == .highlighter { d.points = [d.start, p] } else { d.points.append(p) }
            }
            draft = d
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let d = draft {
            draft = nil
            if !d.isEmpty {
                document.checkpoint()
                document.annotations.append(d)
                changed()
            }
        }
        if let crop = cropDraft {
            cropDraft = nil
            cropStart = nil
            if crop.width >= 8, crop.height >= 8 {
                document.checkpoint()
                document.crop = crop
                changed()
                window?.invalidateCursorRects(for: self)
            }
        }
        if movedSinceMouseDown { changed() }
        lastDragPoint = nil
        needsDisplay = true
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            deleteSelection()
        case 53: // esc
            draft = nil
            cropDraft = nil
            selectedIndex = nil
            needsDisplay = true
        default:
            if plain, let key = event.charactersIgnoringModifiers?.lowercased(),
               let match = Tool.allCases.first(where: { $0.key == key }) {
                onToolShortcut?(match)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// Applies a colour or width change to the selected shape, if any.
    func applyStyleToSelection() {
        guard let index = selectedIndex else { return }
        document.checkpoint()
        document.annotations[index].color = color
        document.annotations[index].lineWidth = lineWidth
        switch document.annotations[index].tool {
        case .arrow: document.annotations[index].style = arrowStyle.rawValue
        case .text: document.annotations[index].style = textStyle.rawValue
        default: break
        }
        changed()
    }

    func deleteSelection() {
        guard let index = selectedIndex else { return }
        document.checkpoint()
        document.annotations.remove(at: index)
        selectedIndex = nil
        changed()
    }

    func refresh() {
        selectedIndex = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Text editing

    private func editText(at index: Int) {
        let existing = document.annotations[index]
        editingIndex = index
        selectedIndex = nil
        textStyle = existing.textStyle
        beginText(at: existing.start, text: existing.text, color: existing.color, lineWidth: existing.lineWidth)
        needsDisplay = true
    }

    private func beginText(at p: CGPoint, text: String, color: NSColor, lineWidth: CGFloat) {
        let sample = Annotation(tool: .text, start: p, end: p, color: color, lineWidth: lineWidth, style: textStyle.rawValue)
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = textStyle.font(size: sample.fontSize * viewScale)
        field.textColor = color
        field.placeholderString = "Text"
        field.delegate = self
        let origin = toView(p)
        field.frame = CGRect(x: origin.x - 2, y: origin.y, width: 60, height: sample.fontSize * viewScale * 1.3)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        textAnchor = p
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField else { return }
        let width = field.attributedStringValue.size().width + 20
        field.frame.size.width = max(60, width)
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    func commitText() {
        guard let field = textField, let anchor = textAnchor else { return }
        textField = nil
        textAnchor = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()

        if let index = editingIndex, document.annotations.indices.contains(index) {
            editingIndex = nil
            let old = document.annotations[index]
            if text.isEmpty {
                document.checkpoint()
                document.annotations.remove(at: index)
            } else if text != old.text || textStyle.rawValue != old.style {
                document.checkpoint()
                document.annotations[index].text = text
                document.annotations[index].style = textStyle.rawValue
            }
        } else if !text.isEmpty {
            document.checkpoint()
            document.annotations.append(Annotation(tool: .text, start: anchor, end: anchor, color: color,
                                                   lineWidth: lineWidth, text: text, style: textStyle.rawValue))
        }
        editingIndex = nil
        changed()
        window?.makeFirstResponder(self)
    }

    // MARK: Helpers

    private func changed() {
        needsDisplay = true
        onChange?()
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        let r = document.crop
        return CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    /// Shift: lines snap to 45° steps, boxes become squares/circles.
    private func constrained(_ p: CGPoint, from start: CGPoint, tool: Tool) -> CGPoint {
        let dx = p.x - start.x, dy = p.y - start.y
        switch tool {
        case .line, .arrow, .highlighter:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        case .rectangle, .filledRectangle, .ellipse, .pixelate, .blur, .spotlight:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        default:
            return p
        }
    }
}
