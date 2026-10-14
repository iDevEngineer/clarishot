import AppKit

/// Shows the screenshot with its annotations and turns mouse input into shapes.
@MainActor
final class CanvasView: NSView, NSTextFieldDelegate {
    let document: AnnotateDocument

    var tool: Tool = .select {
        didSet { commitText(); selectedIndex = nil; needsDisplay = true; window?.invalidateCursorRects(for: self) }
    }
    var color: NSColor = OklchPalette.red
    var lineWidth: CGFloat = 4
    var arrowStyle: ArrowStyle = .straight
    var textStyle: TextStyle = .outline
    // Defaults for new shapes, set from the properties bar.
    var lineDash: LineDash = .solid
    var arrowType: ArrowType = .tapered
    var startHead: ArrowHead = .none
    var endHead: ArrowHead = .arrow
    // Watermark defaults (text is remembered between sessions).
    var watermarkText = UserDefaults.standard.string(forKey: "watermarkText") ?? "© Clarishot" {
        didSet { UserDefaults.standard.set(watermarkText, forKey: "watermarkText") }
    }
    var watermarkStyle: WatermarkStyle = .single
    /// Highlighter mode: 0 = Text (tints what's under it), 1 = Marker (see-through pen on top).
    var highlighterMode = 0
    var watermarkSize: CGFloat = 36
    var watermarkOpacity: CGFloat = 0.35
    var watermarkRotation: CGFloat = -30
    /// Told whenever the selected shape changes, so the properties bar can follow it.
    var onSelectionChange: (() -> Void)?

    /// The selected shape, if any.
    var selectedAnnotation: Annotation? {
        selectedIndex.flatMap { document.annotations.indices.contains($0) ? document.annotations[$0] : nil }
    }
    /// Width ÷ height for the crop tool, or nil for free cropping.
    var cropAspect: CGFloat?

    /// Called after any change, so the toolbar can refresh undo/redo.
    var onChange: (() -> Void)?
    /// Called when a tool's letter key is pressed.
    var onToolShortcut: ((Tool) -> Void)?

    private var draft: Annotation?
    private var cropStart: CGPoint?
    private var cropDraft: CGRect?
    private var selectedIndex: Int? { didSet { if oldValue != selectedIndex { onSelectionChange?() } } }
    /// Dragging a curved arrow's bend handle.
    private var draggingControl: Int?
    /// Dragging one end of a selected arrow or line (`isStart` picks which end).
    private var draggingEnd: (index: Int, isStart: Bool)?

    /// The selected arrow or line, if any — these show draggable end handles.
    private var selectedLineIndex: Int? {
        guard let index = selectedIndex, document.annotations.indices.contains(index),
              [.arrow, .line, .highlighter].contains(document.annotations[index].tool) else { return nil }
        return index
    }

    /// The selected arrow, if it's curved (it then shows a bend handle).
    private var curveHandleIndex: Int? {
        guard let index = selectedLineIndex, document.annotations[index].tool == .arrow,
              document.annotations[index].arrowStyle == .curved else { return nil }
        return index
    }

    /// Which end handle (if any) is under a point in view coordinates.
    private func endHandle(at viewPoint: CGPoint) -> (index: Int, isStart: Bool)? {
        guard let index = selectedLineIndex else { return nil }
        let a = document.annotations[index]
        func near(_ p: CGPoint) -> Bool { hypot(toView(p).x - viewPoint.x, toView(p).y - viewPoint.y) <= 11 }
        if near(a.handleEnd) { return (index, false) }
        if near(a.handleStart) { return (index, true) }
        return nil
    }
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

    /// Edges and text lines of the current picture, redone when it changes (rotate, cut out…).
    private var guides: (image: CGImage, value: SnapGuides)?
    private var snapGuides: SnapGuides {
        if let guides, guides.image === document.baseImage { return guides.value }
        let value = SnapGuides(image: document.baseImage, pointSize: document.imageSize)
        guides = (document.baseImage, value)
        return value
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(imageRectInView, cursor: tool == .select ? .arrow : (tool == .text ? .iBeam : .crosshair))
    }

    // MARK: Coordinate mapping (view points <-> image points)

    /// Canvas size and screenshot position (image points) when the background is on.
    private var backgroundLayout: (canvas: CGSize, origin: CGPoint)? {
        guard document.background.enabled else { return nil }
        let balance = document.background.autoBalance == true
            ? ContentBalance.offset(for: document.baseImage, crop: document.crop, pointSize: document.imageSize) : .zero
        return document.background.layout(for: document.crop.size, balance: balance)
    }

    private var totalSize: CGSize { backgroundLayout?.canvas ?? document.crop.size }

    /// nil = fit the window; otherwise a fixed zoom (1 = 100%).
    var zoom: CGFloat? { didSet { pan = .zero; needsDisplay = true; window?.invalidateCursorRects(for: self); onZoomChange?() } }
    var onZoomChange: (() -> Void)?
    /// Scroll offset when zoomed in past the window.
    private var pan: CGPoint = .zero

    private var fitScale: CGFloat {
        let crop = document.crop
        let available = bounds.insetBy(dx: margin, dy: margin)
        _ = crop
        let total = totalSize
        return min(1, available.width / max(total.width, 1), available.height / max(total.height, 1))
    }

    /// The zoom actually shown (for the zoom menu's label).
    var currentScale: CGFloat { viewScale }

    private var viewScale: CGFloat { zoom ?? fitScale }

    /// Two-finger scroll moves around a zoomed-in picture.
    override func scrollWheel(with event: NSEvent) {
        guard zoom != nil else { return super.scrollWheel(with: event) }
        let size = frameRectInView.size
        let limitX = max(0, (size.width - bounds.width) / 2 + margin)
        let limitY = max(0, (size.height - bounds.height) / 2 + margin)
        pan.x = min(max(pan.x + event.scrollingDeltaX, -limitX), limitX)
        pan.y = min(max(pan.y + event.scrollingDeltaY, -limitY), limitY)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// Screenshot plus background, in view points.
    private var frameRectInView: CGRect {
        let s = viewScale
        let size = CGSize(width: totalSize.width * s, height: totalSize.height * s)
        return CGRect(x: ((bounds.width - size.width) / 2 + pan.x).rounded(),
                      y: ((bounds.height - size.height) / 2 + pan.y).rounded(),
                      width: size.width, height: size.height)
    }

    private var imageRectInView: CGRect {
        let frame = frameRectInView, s = viewScale
        guard let layout = backgroundLayout else { return frame }
        return CGRect(x: frame.minX + layout.origin.x * s, y: frame.minY + layout.origin.y * s,
                      width: document.crop.width * s, height: document.crop.height * s)
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
                                               shadow: style.effectiveShadow, inset: style.effectiveInset * viewScale,
                                               shadowScale: viewScale, ctx: ctx, flipped: true)
        } else {
            ctx.saveGState()
            ctx.clip(to: imageRect)
            applyImageTransform(ctx, imageRect)
            AnnotationRenderer.drawImage(document.baseImage, in: CGRect(origin: .zero, size: document.imageSize), ctx: ctx)
            AnnotationRenderer.drawAll(annotations, in: ctx, effects: document.effects, imageSize: document.imageSize)
            ctx.restoreGState()
        }

        if let index = selectedLineIndex {
            // Arrows and lines: a round handle on each end instead of a box.
            let a = document.annotations[index]
            if curveHandleIndex == index {
                // Curved arrow: dashed guides from each end to a diamond bend handle.
                let c = toView(a.curveControl)
                let guides = NSBezierPath()
                guides.move(to: toView(a.start)); guides.line(to: c); guides.line(to: toView(a.end))
                guides.lineWidth = 1
                guides.setLineDash([4, 3], count: 2, phase: 0)
                NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
                guides.stroke()
                let diamond = NSBezierPath()
                diamond.move(to: CGPoint(x: c.x, y: c.y - 7)); diamond.line(to: CGPoint(x: c.x + 7, y: c.y))
                diamond.line(to: CGPoint(x: c.x, y: c.y + 7)); diamond.line(to: CGPoint(x: c.x - 7, y: c.y)); diamond.close()
                NSColor.white.setFill(); diamond.fill()
                NSColor.controlAccentColor.setStroke(); diamond.lineWidth = 2; diamond.stroke()
            }
            if a.tool == .highlighter {
                // Light outline so you can see what's selected, plus the two end handles.
                let outline = NSBezierPath(roundedRect: toView(a.bounds), xRadius: 4, yRadius: 4)
                outline.lineWidth = 1
                outline.setLineDash([4, 3], count: 2, phase: 0)
                NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
                outline.stroke()
            }
            for point in [a.handleStart, a.handleEnd] {
                let c = toView(point)
                let dot = NSBezierPath(ovalIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12))
                NSColor.controlAccentColor.setFill()
                dot.fill()
                NSColor.white.setStroke()
                dot.lineWidth = 2
                dot.stroke()
            }
        } else if let index = selectedIndex, document.annotations.indices.contains(index) {
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
        let viewPoint = convert(event.locationInWindow, from: nil)
        let p = toImage(viewPoint)
        movedSinceMouseDown = false

        // Grab an end (or a curved arrow's bend handle) of the selected arrow or line, whichever tool is active.
        if let handle = endHandle(at: viewPoint) {
            draggingEnd = handle
            return
        }
        if let index = curveHandleIndex, hypot(toView(document.annotations[index].curveControl).x - viewPoint.x,
                                               toView(document.annotations[index].curveControl).y - viewPoint.y) <= 11 {
            draggingControl = index
            return
        }

        // Double-click a text label (with any tool) to edit it.
        if event.clickCount == 2,
           let index = document.annotations.indices.last(where: {
               document.annotations[$0].tool == .text && document.annotations[$0].bounds.contains(p)
           }) {
            editText(at: index)
            return
        }

        // Starting something new deselects the previous arrow (its handles disappear).
        if tool != .select { selectedIndex = nil }
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
        case .watermark:
            // Diagonal and tiled cover the whole picture, so they sit at its centre.
            let centre = watermarkStyle == .single ? p : CGPoint(x: document.crop.midX, y: document.crop.midY)
            var mark = Annotation(tool: .watermark, start: centre, end: centre, color: color, lineWidth: watermarkSize,
                                  text: watermarkText, style: watermarkStyle.rawValue)
            mark.opacity = watermarkOpacity
            mark.rotation = watermarkRotation
            document.checkpoint()
            document.annotations.append(mark)
            selectedIndex = document.annotations.count - 1
            changed()
        default:
            draft = Annotation(tool: tool, start: p, end: p, points: [p], color: color, lineWidth: lineWidth,
                               style: tool == .arrow ? arrowStyle.rawValue : (tool == .highlighter ? highlighterMode : 0),
                               dash: lineDash.rawValue, arrowType: arrowType.rawValue,
                               startHead: startHead.rawValue, endHead: endHead.rawValue)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        var p = toImage(convert(event.locationInWindow, from: nil))
        let shift = event.modifierFlags.contains(.shift)

        if let handle = draggingEnd, document.annotations.indices.contains(handle.index) {
            if !movedSinceMouseDown { document.checkpoint(); movedSinceMouseDown = true }
            var a = document.annotations[handle.index]
            let anchor = handle.isStart ? a.handleEnd : a.handleStart
            if shift { p = constrained(p, from: anchor, tool: a.tool == .highlighter ? .line : a.tool) }
            a.moveHandle(isStart: handle.isStart, to: p)
            document.annotations[handle.index] = a
            needsDisplay = true
            return
        }
        if let index = draggingControl, document.annotations.indices.contains(index) {
            if !movedSinceMouseDown { document.checkpoint(); movedSinceMouseDown = true }
            document.annotations[index].control = p
            needsDisplay = true
            return
        }

        switch tool {
        case .select:
            guard let index = selectedIndex, let last = lastDragPoint else { return }
            if !movedSinceMouseDown { document.checkpoint(); movedSinceMouseDown = true }
            document.annotations[index].move(by: CGVector(dx: p.x - last.x, dy: p.y - last.y))
            lastDragPoint = p
        case .crop:
            guard let start = cropStart else { return }
            p = clampToImage(p)
            if Settings.shared.annotateSnapToEdges, !event.modifierFlags.contains(.command) {
                // Snap within ~8 screen points, whatever the zoom.
                let tolerance = 8 / max(viewScale, 0.01)
                p.x = SnapGuides.snap(p.x, to: snapGuides.verticalEdges, tolerance: tolerance)
                p.y = SnapGuides.snap(p.y, to: snapGuides.horizontalEdges, tolerance: tolerance)
            }
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
                if d.tool == .highlighter, Settings.shared.annotateSnapHighlight, !event.modifierFlags.contains(.command),
                   let line = snapGuides.textLine(at: d.start) {
                    // Started on a line of text: run straight along its middle, across the words covered.
                    let y = line.midY
                    d.points = [CGPoint(x: d.start.x, y: y), CGPoint(x: p.x, y: y)]
                    d.end = CGPoint(x: p.x, y: y)
                } else if shift && d.tool == .highlighter {
                    // Shift on the highlighter draws a straight stroke.
                    d.points = [d.start, p]
                } else {
                    d.points.append(p)
                }
            }
            draft = d
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if draggingEnd != nil || draggingControl != nil {
            draggingEnd = nil
            draggingControl = nil
            if movedSinceMouseDown { changed() }
            needsDisplay = true
            return
        }
        if var d = draft {
            draft = nil
            let settings = Settings.shared
            // Arrow head at the start instead of the end; ⌥ flips the setting for one arrow.
            if d.tool == .arrow, settings.annotateInverseArrows != event.modifierFlags.contains(.option) {
                swap(&d.start, &d.end)
            }
            if d.tool == .pencil, settings.annotateSmoothDrawing { d.points = Self.smoothed(d.points) }
            if !d.isEmpty {
                document.checkpoint()
                document.annotations.append(d)
                // A new arrow, line or highlight stays selected, so it can be adjusted straight away
                // (ends, colour, thickness, mode) without switching to the Select tool.
                if [.arrow, .line, .highlighter].contains(d.tool) { selectedIndex = document.annotations.count - 1 }
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
    /// Copies a shape's own settings into the current defaults (used when it's selected).
    func loadDefaults(from a: Annotation) {
        color = a.color
        switch a.tool {
        case .arrow:
            lineWidth = a.lineWidth
            arrowStyle = a.arrowStyle
            arrowType = a.arrowLook
            startHead = a.startEnd
            endHead = a.endEnd
            lineDash = a.lineDash
        case .rectangle, .ellipse, .line:
            lineWidth = a.lineWidth
            lineDash = a.lineDash
        case .text:
            lineWidth = a.lineWidth
            textStyle = a.textStyle
        case .highlighter:
            lineWidth = a.lineWidth
            highlighterMode = a.style
        case .watermark:
            watermarkText = a.text
            watermarkStyle = a.watermarkStyle
            watermarkSize = a.lineWidth
            watermarkOpacity = a.opacity
            watermarkRotation = a.rotation
        default:
            lineWidth = a.lineWidth
        }
    }

    func applyStyleToSelection() {
        guard let index = selectedIndex else { return }
        document.checkpoint()
        document.annotations[index].color = color
        document.annotations[index].lineWidth = lineWidth
        switch document.annotations[index].tool {
        case .arrow:
            if document.annotations[index].style != arrowStyle.rawValue { document.annotations[index].control = nil }
            document.annotations[index].style = arrowStyle.rawValue
            document.annotations[index].arrowType = arrowType.rawValue
            document.annotations[index].startHead = startHead.rawValue
            document.annotations[index].endHead = endHead.rawValue
            document.annotations[index].dash = lineDash.rawValue
        case .rectangle, .ellipse, .line:
            document.annotations[index].dash = lineDash.rawValue
        case .text: document.annotations[index].style = textStyle.rawValue
        case .highlighter: document.annotations[index].style = highlighterMode
        case .watermark:
            var mark = document.annotations[index]
            mark.text = watermarkText
            mark.style = watermarkStyle.rawValue
            mark.lineWidth = watermarkSize
            mark.opacity = watermarkOpacity
            mark.rotation = watermarkRotation
            if mark.watermarkStyle != .single { mark.start = CGPoint(x: document.crop.midX, y: document.crop.midY); mark.end = mark.start }
            document.annotations[index] = mark
        default: break
        }
        changed()
    }

    var hasSelection: Bool { selectedIndex != nil }

    // MARK: Copy, paste, duplicate

    /// How far each pasted or duplicated copy is shifted, so it doesn't sit exactly on top.
    private static let copyOffset = CGVector(dx: 16, dy: 16)
    private var pasteCount = 0

    /// Copies the selected shape. Returns false when nothing is selected.
    func copySelection() -> Bool {
        guard let index = selectedIndex, document.annotations.indices.contains(index) else { return false }
        commitText()
        ShapeClipboard.write([document.annotations[index]])
        pasteCount = 0
        return true
    }

    /// Pastes copied shapes. Returns false when the clipboard holds no shapes.
    func pasteShapes() -> Bool {
        guard var shapes = ShapeClipboard.read() else { return false }
        pasteCount += 1
        let shift = CGVector(dx: Self.copyOffset.dx * CGFloat(pasteCount), dy: Self.copyOffset.dy * CGFloat(pasteCount))
        for i in shapes.indices { shapes[i].move(by: shift) }
        insert(shapes)
        return true
    }

    func duplicateSelection() {
        guard let index = selectedIndex, document.annotations.indices.contains(index) else { return }
        var copy = document.annotations[index]
        copy.move(by: Self.copyOffset)
        insert([copy])
    }

    private func insert(_ shapes: [Annotation]) {
        commitText()
        document.checkpoint()
        for var shape in shapes {
            if shape.tool == .counter { shape.number = document.nextCounterNumber }
            document.annotations.append(shape)
        }
        changed()
        selectedIndex = document.annotations.count - 1
        needsDisplay = true
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
        document.expandToFitAnnotations()
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

extension CanvasView {
    /// Chaikin corner cutting: rounds off the jitter in a hand-drawn stroke.
    static func smoothed(_ points: [CGPoint], passes: Int = 2) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var result = points
        for _ in 0..<passes {
            var next = [result[0]]
            for (a, b) in zip(result, result.dropFirst()) {
                next.append(CGPoint(x: 0.75 * a.x + 0.25 * b.x, y: 0.75 * a.y + 0.25 * b.y))
                next.append(CGPoint(x: 0.25 * a.x + 0.75 * b.x, y: 0.25 * a.y + 0.75 * b.y))
            }
            next.append(result[result.count - 1])
            result = next
        }
        return result
    }
}
