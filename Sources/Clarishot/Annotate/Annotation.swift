import AppKit
import CoreImage

/// Editor tools, in toolbar order. `key` is the single-letter shortcut.
enum Tool: CaseIterable {
    case select, crop, rectangle, filledRectangle, ellipse, line, arrow, text, highlighter, pixelate, blur, spotlight, counter, pencil
    case watermark
    /// A placed picture (Add screenshot). Not a toolbar tool.
    case picture

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .crop: return "crop"
        case .rectangle: return "square"
        case .filledRectangle: return "square.fill"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .highlighter: return "highlighter"
        case .pixelate: return "checkerboard.rectangle"
        case .blur: return "drop.halffull"
        case .spotlight: return "flashlight.on.fill"
        case .counter: return "1.circle"
        case .pencil: return "scribble"
        case .watermark: return "c.circle"
        case .picture: return "photo"
        }
    }

    var title: String {
        switch self {
        case .select: return "Select"
        case .crop: return "Crop"
        case .rectangle: return "Rectangle"
        case .filledRectangle: return "Filled Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .text: return "Text"
        case .highlighter: return "Highlighter"
        case .pixelate: return "Pixelate"
        case .blur: return "Blur"
        case .spotlight: return "Spotlight"
        case .counter: return "Counter"
        case .pencil: return "Pencil"
        case .watermark: return "Watermark"
        case .picture: return "Picture"
        }
    }

    var key: String {
        switch self {
        case .select: return "v"
        case .crop: return "c"
        case .rectangle: return "r"
        case .filledRectangle: return "f"
        case .ellipse: return "o"
        case .line: return "l"
        case .arrow: return "a"
        case .text: return "t"
        case .highlighter: return "h"
        case .pixelate: return "b"
        case .blur: return "u"
        case .spotlight: return "s"
        case .counter: return "n"
        case .pencil: return "p"
        case .watermark: return "w"
        case .picture: return ""
        }
    }

    /// Tools drawn by dragging a freehand path.
    var isFreehand: Bool { self == .pencil || self == .highlighter }
}

enum ArrowStyle: Int, CaseIterable {
    case straight, curved
    var title: String { self == .straight ? "Straight" : "Curved" }
}

/// How an arrow is drawn: a tapered shape, a line with separate heads, or a hollow outline.
enum ArrowType: Int, CaseIterable {
    case tapered, classic, outlined
    var title: String {
        switch self {
        case .tapered: return "Tapered"
        case .classic: return "Classic"
        case .outlined: return "Outlined"
        }
    }
}

/// What sits on each end of a classic arrow.
enum ArrowHead: Int, CaseIterable {
    case none, arrow, dot
    var title: String {
        switch self {
        case .none: return "None"
        case .arrow: return "Arrow"
        case .dot: return "Dot"
        }
    }
}

/// Watermark layout: one label where you click, one large label across the picture, or a repeating pattern.
enum WatermarkStyle: Int, CaseIterable {
    case single, diagonal, tiled
    var title: String {
        switch self {
        case .single: return "Single"
        case .diagonal: return "Diagonal"
        case .tiled: return "Tiled"
        }
    }
}

/// Solid, dashed or dotted outlines for shapes, lines and classic arrows.
enum LineDash: Int, CaseIterable {
    case solid, dashed, dotted
    var title: String {
        switch self {
        case .solid: return "Solid"
        case .dashed: return "Dashed"
        case .dotted: return "Dotted"
        }
    }

    /// Sets the context's dash pattern, scaled to the line width.
    func apply(to ctx: CGContext, width: CGFloat) {
        switch self {
        case .solid: break
        case .dashed: ctx.setLineDash(phase: 0, lengths: [width * 3, width * 2])
        case .dotted:
            ctx.setLineCap(.round)
            ctx.setLineDash(phase: 0, lengths: [0, width * 2])
        }
    }
}

/// Text looks, chosen from the editor's Style menu.
enum TextStyle: Int, CaseIterable {
    case outline, plain, shadow, filledBox, lightBox, mono, serif

    var title: String {
        switch self {
        case .outline: return "Outlined"
        case .plain: return "Plain"
        case .shadow: return "Shadow"
        case .filledBox: return "Filled Label"
        case .lightBox: return "Light Label"
        case .mono: return "Monospaced"
        case .serif: return "Serif"
        }
    }

    var hasBox: Bool { self == .filledBox || self == .lightBox }

    func font(size: CGFloat) -> NSFont {
        switch self {
        case .mono: return .monospacedSystemFont(ofSize: size, weight: .bold)
        case .serif: return NSFont(name: "Georgia-Bold", size: size) ?? .systemFont(ofSize: size, weight: .bold)
        default: return .systemFont(ofSize: size, weight: .bold)
        }
    }
}

/// One shape drawn on top of the screenshot. Points are in image points,
/// with a top-left origin.
struct Annotation {
    var tool: Tool
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: NSColor
    var lineWidth: CGFloat
    var text = ""
    var number = 0
    /// Arrow: `ArrowStyle` raw value. Text: `TextStyle` raw value.
    var style = 0
    /// The image of a `.picture` annotation, drawn to fill `rect`.
    var picture: CGImage?
    /// `LineDash` raw value.
    var dash = 0
    /// Arrow look (`ArrowType` raw value) and what's on each end (`ArrowHead` raw values).
    var arrowType = 0
    var startHead = 0
    var endHead = 1
    /// A curved arrow's bend point when the user has dragged it; nil = the default curve.
    var control: CGPoint?
    /// Watermark: opacity 0.05…1 and rotation in degrees. Size is `lineWidth` (font size); layout is `style`.
    var opacity: CGFloat = 0.35
    var rotation: CGFloat = -30

    var watermarkStyle: WatermarkStyle { WatermarkStyle(rawValue: style) ?? .single }

    /// The watermark text as drawn.
    func watermarkText() -> NSAttributedString {
        NSAttributedString(string: text.isEmpty ? " " : text, attributes: [
            .font: NSFont.systemFont(ofSize: lineWidth, weight: .semibold),
            .foregroundColor: color.withAlphaComponent(opacity)
        ])
    }

    var lineDash: LineDash { LineDash(rawValue: dash) ?? .solid }
    var arrowLook: ArrowType { ArrowType(rawValue: arrowType) ?? .tapered }
    var startEnd: ArrowHead { ArrowHead(rawValue: startHead) ?? .none }
    var endEnd: ArrowHead { ArrowHead(rawValue: endHead) ?? .arrow }

    /// Default bend point for a curved arrow (a gentle arc to one side).
    var defaultCurveControl: CGPoint {
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let dx = end.x - start.x, dy = end.y - start.y
        return CGPoint(x: mid.x - dy * 0.3, y: mid.y + dx * 0.3)
    }

    /// Moves one end, keeping a custom curve's shape relative to the arrow.
    mutating func setEnd(_ point: CGPoint, isStart: Bool) {
        let offset = control.map { CGVector(dx: $0.x - defaultCurveControl.x, dy: $0.y - defaultCurveControl.y) }
        if isStart { start = point } else { end = point }
        if let offset { control = CGPoint(x: defaultCurveControl.x + offset.dx, y: defaultCurveControl.y + offset.dy) }
    }

    var arrowStyle: ArrowStyle { ArrowStyle(rawValue: style) ?? .straight }
    var textStyle: TextStyle { TextStyle(rawValue: style) ?? .outline }

    /// The bend point of a curved arrow.
    var curveControl: CGPoint { control ?? defaultCurveControl }

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var fontSize: CGFloat { 12 + lineWidth * 3 }
    var counterDiameter: CGFloat { 18 + lineWidth * 3 }
    var highlighterWidth: CGFloat { lineWidth * 4 + 8 }

    /// Too small to keep (e.g. a click without a drag).
    var isEmpty: Bool {
        switch tool {
        case .pencil, .highlighter: return points.count < 2
        case .line, .arrow: return hypot(end.x - start.x, end.y - start.y) < 3
        case .text: return text.isEmpty
        case .counter, .watermark: return false
        default: return rect.width < 3 || rect.height < 3
        }
    }

    /// Area used for hit-testing and the selection outline.
    var bounds: CGRect {
        let base: CGRect
        var pad = lineWidth + 4
        switch tool {
        case .pencil, .highlighter:
            let xs = points.map(\.x), ys = points.map(\.y)
            base = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                          width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
            if tool == .highlighter { pad = highlighterWidth / 2 + 4 }
        case .text:
            base = CGRect(origin: start, size: NSAttributedString(string: text, attributes: textAttributes()).size())
            if textStyle.hasBox { pad += 8 }
        case .arrow where arrowStyle == .curved:
            let c = curveControl
            base = rect.union(CGRect(x: c.x, y: c.y, width: 0, height: 0))
        case .counter:
            let d = counterDiameter
            base = CGRect(x: start.x - d / 2, y: start.y - d / 2, width: d, height: d)
        case .watermark:
            // The label around its centre (tiled and diagonal ones are selected by this centre label too).
            let size = watermarkText().size()
            base = CGRect(x: start.x - size.width / 2, y: start.y - size.height / 2, width: size.width, height: size.height)
        default:
            base = rect
        }
        return base.insetBy(dx: -pad, dy: -pad)
    }

    func textAttributes(outline: Bool = false) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: textStyle.font(size: fontSize),
            .foregroundColor: textStyle == .filledBox ? NSColor.white : color
        ]
        if outline {
            attributes[.foregroundColor] = NSColor.white
            attributes[.strokeColor] = NSColor.white
            attributes[.strokeWidth] = 12 // positive = outline only, as % of font size
        }
        return attributes
    }

    mutating func move(by delta: CGVector) {
        start.x += delta.dx; start.y += delta.dy
        end.x += delta.dx; end.y += delta.dy
        if let c = control { control = CGPoint(x: c.x + delta.dx, y: c.y + delta.dy) }
        points = points.map { CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) }
    }
}

/// Pre-computed copies of the screenshot used by the pixelate and blur tools.
struct EffectImages {
    let pixelated: CGImage?
    let blurred: CGImage?

    init(image: CGImage, scale: CGFloat) {
        let input = CIImage(cgImage: image)
        let context = CIContext()
        func make(_ name: String, _ values: [String: Any]) -> CGImage? {
            guard let filter = CIFilter(name: name) else { return nil }
            filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
            for (key, value) in values { filter.setValue(value, forKey: key) }
            guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
            return context.createCGImage(output, from: input.extent)
        }
        pixelated = make("CIPixellate", [kCIInputScaleKey: 8 * scale, kCIInputCenterKey: CIVector(x: 0, y: 0)])
        blurred = make("CIGaussianBlur", [kCIInputRadiusKey: 10 * scale])
    }
}

/// Draws annotations into a context whose coordinates are image points with a
/// top-left origin (a flipped context). Used for both the canvas and export.
enum AnnotationRenderer {
    /// Draws all annotations: spotlight dimming first, then every other shape on top.
    static func drawAll(_ annotations: [Annotation], in ctx: CGContext, effects: EffectImages, imageSize: CGSize) {
        let spotlights = annotations.filter { $0.tool == .spotlight && !$0.isEmpty }
        if !spotlights.isEmpty {
            ctx.saveGState()
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.fill(CGRect(origin: .zero, size: imageSize))
            ctx.setBlendMode(.clear)
            for s in spotlights {
                ctx.addPath(CGPath(roundedRect: s.rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
                ctx.fillPath()
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        for a in annotations where a.tool != .spotlight {
            draw(a, in: ctx, effects: effects, imageSize: imageSize)
        }
    }

    static func draw(_ a: Annotation, in ctx: CGContext, effects: EffectImages, imageSize: CGSize) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let shadowed: Set<Tool> = [.arrow, .line, .rectangle, .ellipse, .pencil, .text, .filledRectangle, .picture]
        if shadowed.contains(a.tool), UserDefaults.standard.object(forKey: "annotateShadows") as? Bool ?? true {
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        }

        switch a.tool {
        case .watermark:
            drawWatermark(a, ctx, imageSize: imageSize)

        case .picture:
            if let picture = a.picture { drawImage(picture, in: a.rect, ctx: ctx) }

        case .rectangle:
            let r = a.rect
            let radius = min(a.lineWidth, r.width / 2, r.height / 2)
            a.lineDash.apply(to: ctx, width: a.lineWidth)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()

        case .filledRectangle:
            let r = a.rect
            let radius = min(a.lineWidth + 2, r.width / 2, r.height / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()

        case .ellipse:
            a.lineDash.apply(to: ctx, width: a.lineWidth)
            ctx.strokeEllipse(in: a.rect)

        case .line:
            a.lineDash.apply(to: ctx, width: a.lineWidth)
            ctx.move(to: a.start)
            ctx.addLine(to: a.end)
            ctx.strokePath()

        case .arrow:
            drawArrow(a, ctx)

        case .pencil, .highlighter:
            guard let first = a.points.first else { return }
            if a.tool == .highlighter {
                if a.style == 1 {
                    // Marker: a see-through pen stroke laid on top, with rounded ends.
                    ctx.setBlendMode(.normal)
                    ctx.setStrokeColor(a.color.withAlphaComponent(0.38).cgColor)
                    ctx.setLineCap(.round)
                } else {
                    // Text: tints only what's underneath, so text stays crisp and readable.
                    ctx.setBlendMode(.multiply)
                    ctx.setStrokeColor(a.color.withAlphaComponent(0.45).cgColor)
                    ctx.setLineCap(.butt)
                }
                ctx.setLineWidth(a.highlighterWidth)
            }
            ctx.move(to: first)
            for p in a.points.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()

        case .pixelate, .blur:
            ctx.clip(to: a.rect)
            if let image = a.tool == .pixelate ? effects.pixelated : effects.blurred {
                drawImage(image, in: CGRect(origin: .zero, size: imageSize), ctx: ctx)
            } else {
                ctx.setFillColor(NSColor.gray.cgColor)
                ctx.fill(a.rect)
            }

        case .counter:
            let d = a.counterDiameter
            let circle = CGRect(x: a.start.x - d / 2, y: a.start.y - d / 2, width: d, height: d)
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(0.3).cgColor)
            ctx.fillEllipse(in: circle)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            let label = NSAttributedString(string: "\(a.number)", attributes: [
                .font: NSFont.systemFont(ofSize: d * 0.55, weight: .bold),
                .foregroundColor: NSColor.white
            ])
            let size = label.size()
            withFlippedNSContext(ctx) {
                label.draw(at: CGPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2))
            }

        case .text:
            let string = NSAttributedString(string: a.text, attributes: a.textAttributes())
            let style = a.textStyle
            if style.hasBox {
                let box = CGRect(origin: a.start, size: string.size()).insetBy(dx: -8, dy: -4)
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.setFillColor(style == .filledBox ? a.color.cgColor : NSColor.white.withAlphaComponent(0.95).cgColor)
                ctx.fillPath()
            }
            if style == .shadow {
                ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: NSColor.black.withAlphaComponent(0.6).cgColor)
            }
            withFlippedNSContext(ctx) {
                if style == .outline {
                    NSAttributedString(string: a.text, attributes: a.textAttributes(outline: true)).draw(at: a.start)
                }
                string.draw(at: a.start)
            }

        case .select, .crop, .spotlight:
            break
        }
    }

    /// Bent arrow: a curved shaft ending in a solid head that follows the curve.
    /// Draws a watermark: one label at its point, one big label across the middle, or a rotated tiled pattern.
    private static func drawWatermark(_ a: Annotation, _ ctx: CGContext, imageSize: CGSize) {
        var mark = a
        let canvas = CGRect(origin: .zero, size: imageSize)
        if mark.watermarkStyle == .diagonal {
            // Big enough to run most of the way across the picture.
            let probe = Annotation(tool: .watermark, start: .zero, end: .zero, color: a.color, lineWidth: 100, text: a.text)
            let width = max(probe.watermarkText().size().width, 1)
            mark.lineWidth = max(a.lineWidth, hypot(imageSize.width, imageSize.height) * 0.7 / width * 100)
        }
        let label = mark.watermarkText()
        let size = label.size()
        let angle = mark.rotation * .pi / 180
        func draw(at centre: CGPoint) {
            ctx.saveGState()
            ctx.translateBy(x: centre.x, y: centre.y)
            ctx.rotate(by: angle)
            withFlippedNSContext(ctx) { label.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2)) }
            ctx.restoreGState()
        }
        switch mark.watermarkStyle {
        case .single: draw(at: a.start)
        case .diagonal: draw(at: CGPoint(x: canvas.midX, y: canvas.midY))
        case .tiled:
            ctx.saveGState()
            ctx.clip(to: canvas)
            let stepX = size.width + max(40, mark.lineWidth * 2), stepY = size.height + max(60, mark.lineWidth * 3)
            var row = 0
            var y = canvas.minY - stepY
            while y < canvas.maxY + stepY {
                var x = canvas.minX - stepX + (row % 2 == 0 ? 0 : stepX / 2)
                while x < canvas.maxX + stepX {
                    draw(at: CGPoint(x: x, y: y))
                    x += stepX
                }
                y += stepY
                row += 1
            }
            ctx.restoreGState()
        }
    }

    /// All arrow looks: tapered (filled shape), classic (line + chosen heads, may be dashed),
    /// outlined (hollow tapered shape); each straight or curved.
    private static func drawArrow(_ a: Annotation, _ ctx: CGContext) {
        let curved = a.arrowStyle == .curved
        switch a.arrowLook {
        case .tapered:
            ctx.addPath(curved ? curvedArrowPath(a) : arrowPath(from: a.start, to: a.end, width: a.lineWidth))
            ctx.fillPath()
        case .outlined:
            ctx.setLineWidth(max(1.5, a.lineWidth * 0.5))
            ctx.setLineJoin(.round)
            ctx.addPath(curved ? curvedArrowPath(a) : arrowPath(from: a.start, to: a.end, width: a.lineWidth))
            ctx.strokePath()
        case .classic:
            drawClassicArrow(a, ctx, curved: curved)
        }
    }

    /// A line (straight or curved, solid/dashed/dotted) with an arrowhead, dot or nothing on each end.
    private static func drawClassicArrow(_ a: Annotation, _ ctx: CGContext, curved: Bool) {
        let w = a.lineWidth
        let c = a.curveControl
        // Directions pointing out of each end, along the line.
        func unit(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
            let dx = to.x - from.x, dy = to.y - from.y, l = max(hypot(dx, dy), 0.001)
            return CGPoint(x: dx / l, y: dy / l)
        }
        let outEnd = unit(curved ? c : a.start, a.end)
        let outStart = unit(curved ? c : a.end, a.start)
        let headLength = w * 3.2 + 6, headWidth = w * 2.8 + 6, dotRadius = w * 1.4 + 2
        // Stop the line short of an arrowhead so its tip stays sharp.
        func trimmed(_ p: CGPoint, _ out: CGPoint, _ head: ArrowHead) -> CGPoint {
            head == .arrow ? CGPoint(x: p.x - out.x * headLength * 0.8, y: p.y - out.y * headLength * 0.8) : p
        }
        let s = trimmed(a.start, outStart, a.startEnd), e = trimmed(a.end, outEnd, a.endEnd)

        ctx.saveGState()
        ctx.setLineWidth(w)
        a.lineDash.apply(to: ctx, width: w)
        ctx.move(to: s)
        if curved { ctx.addQuadCurve(to: e, control: c) } else { ctx.addLine(to: e) }
        ctx.strokePath()
        ctx.restoreGState()

        func head(_ kind: ArrowHead, at tip: CGPoint, out: CGPoint) {
            switch kind {
            case .none: break
            case .dot:
                ctx.fillEllipse(in: CGRect(x: tip.x - dotRadius, y: tip.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
            case .arrow:
                let n = CGPoint(x: -out.y, y: out.x)
                let base = CGPoint(x: tip.x - out.x * headLength, y: tip.y - out.y * headLength)
                ctx.move(to: tip)
                ctx.addLine(to: CGPoint(x: base.x + n.x * headWidth / 2, y: base.y + n.y * headWidth / 2))
                ctx.addLine(to: CGPoint(x: base.x - n.x * headWidth / 2, y: base.y - n.y * headWidth / 2))
                ctx.closePath()
                ctx.fillPath()
            }
        }
        head(a.startEnd, at: a.start, out: outStart)
        head(a.endEnd, at: a.end, out: outEnd)
    }

    /// A curved arrow as one closed shape: the shaft follows the curve and widens from a thin tail
    /// to the head, matching the straight tapered arrow. Filled for tapered, stroked for outlined.
    static func curvedArrowPath(_ a: Annotation) -> CGPath {
        let w = a.lineWidth, s0 = a.start, c = a.curveControl, e = a.end
        func point(_ t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(x: u * u * s0.x + 2 * u * t * c.x + t * t * e.x, y: u * u * s0.y + 2 * u * t * c.y + t * t * e.y)
        }
        func tangent(_ t: CGFloat) -> CGPoint {
            let dx = 2 * (1 - t) * (c.x - s0.x) + 2 * t * (e.x - c.x)
            let dy = 2 * (1 - t) * (c.y - s0.y) + 2 * t * (e.y - c.y)
            let l = max(hypot(dx, dy), 0.001)
            return CGPoint(x: dx / l, y: dy / l)
        }
        let chord = hypot(e.x - s0.x, e.y - s0.y)
        let headLength = min(w * 4.5 + 6, chord * 0.6)
        let headWidth = w * 3.6 + 6, tailWidth = w * 0.4, shaftWidth = w * 1.3

        // Where the head starts: the last point along the curve at least headLength from the tip.
        let steps = 48
        var baseT: CGFloat = 0
        for i in stride(from: steps, through: 0, by: -1) {
            let t = CGFloat(i) / CGFloat(steps)
            let p = point(t)
            if hypot(e.x - p.x, e.y - p.y) >= headLength { baseT = t; break }
        }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0...steps {
            let t = baseT * CGFloat(i) / CGFloat(steps)
            let p = point(t), d = tangent(t), n = CGPoint(x: -d.y, y: d.x)
            let half = (tailWidth + (shaftWidth - tailWidth) * (t / max(baseT, 0.001))) / 2
            left.append(CGPoint(x: p.x + n.x * half, y: p.y + n.y * half))
            right.append(CGPoint(x: p.x - n.x * half, y: p.y - n.y * half))
        }
        let base = point(baseT)
        let dir = CGPoint(x: (e.x - base.x) / max(hypot(e.x - base.x, e.y - base.y), 0.001),
                          y: (e.y - base.y) / max(hypot(e.x - base.x, e.y - base.y), 0.001))
        let n = CGPoint(x: -dir.y, y: dir.x)

        let path = CGMutablePath()
        path.move(to: left[0])
        for p in left.dropFirst() { path.addLine(to: p) }
        path.addLine(to: CGPoint(x: base.x + n.x * headWidth / 2, y: base.y + n.y * headWidth / 2))
        path.addLine(to: e)
        path.addLine(to: CGPoint(x: base.x - n.x * headWidth / 2, y: base.y - n.y * headWidth / 2))
        for p in right.reversed() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }

    /// Tapered arrow: thin at the tail, widening into a solid head.
    static func arrowPath(from start: CGPoint, to end: CGPoint, width: CGFloat) -> CGPath {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.001)
        let u = CGPoint(x: dx / length, y: dy / length)
        let n = CGPoint(x: -u.y, y: u.x)
        let headLength = min(width * 4.5 + 6, length * 0.6)
        let headWidth = width * 3.6 + 6
        let tailWidth = width * 0.4
        let shaftWidth = width * 1.3
        let base = CGPoint(x: end.x - u.x * headLength, y: end.y - u.y * headLength)
        func offset(_ p: CGPoint, _ w: CGFloat) -> CGPoint { CGPoint(x: p.x + n.x * w / 2, y: p.y + n.y * w / 2) }

        let path = CGMutablePath()
        path.move(to: offset(start, tailWidth))
        path.addLine(to: offset(base, shaftWidth))
        path.addLine(to: offset(base, headWidth))
        path.addLine(to: end)
        path.addLine(to: offset(base, -headWidth))
        path.addLine(to: offset(base, -shaftWidth))
        path.addLine(to: offset(start, -tailWidth))
        path.closeSubpath()
        return path
    }

    /// Draws a CGImage the right way up inside a flipped context.
    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// Flattens the image and annotations into one full-resolution image.
    static func render(base: CGImage, scale: CGFloat, imageSize: CGSize, crop: CGRect,
                       annotations: [Annotation], effects: EffectImages) -> CGImage? {
        let width = Int((crop.width * scale).rounded())
        let height = Int((crop.height * scale).rounded())
        guard width > 0, height > 0, let ctx = makeContext(width: width, height: height, like: base) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        drawImage(base, in: CGRect(origin: .zero, size: imageSize), ctx: ctx)
        drawAll(annotations, in: ctx, effects: effects, imageSize: imageSize)
        return ctx.makeImage()
    }

    static func makeContext(width: Int, height: Int, like image: CGImage) -> CGContext? {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func withFlippedNSContext(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The editable state of one screenshot, with undo and redo.
@MainActor
final class AnnotateDocument {
    let capture: Capture
    /// The picture being annotated; replaced by rotate/flip.
    private(set) var baseImage: CGImage
    private(set) var imageSize: CGSize
    private(set) var effects: EffectImages
    var annotations: [Annotation] = []
    var crop: CGRect
    /// Background around the screenshot. Not part of undo history.
    var background = BackgroundStyle()

    private struct State {
        let baseImage: CGImage
        let imageSize: CGSize
        let annotations: [Annotation]
        let crop: CGRect
    }
    private var undoStack: [State] = []
    private var redoStack: [State] = []

    init(capture: Capture) {
        self.capture = capture
        baseImage = capture.image
        imageSize = capture.pointSize
        crop = CGRect(origin: .zero, size: capture.pointSize)
        effects = EffectImages(image: capture.image, scale: capture.scale)
    }

    enum Transform { case rotateLeft, rotateRight, flipHorizontal, flipVertical }

    /// Flattens the drawing into the picture, then rotates or flips it (undoable).
    func apply(_ transform: Transform) {
        guard let flat = AnnotationRenderer.render(base: baseImage, scale: capture.scale, imageSize: imageSize,
                                                   crop: crop, annotations: annotations, effects: effects)
        else { return }
        let rotates = transform == .rotateLeft || transform == .rotateRight
        let w = rotates ? flat.height : flat.width, h = rotates ? flat.width : flat.height
        guard let ctx = AnnotationRenderer.makeContext(width: w, height: h, like: flat) else { return }
        switch transform {
        case .rotateRight:
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.rotate(by: -.pi / 2)
        case .rotateLeft:
            ctx.translateBy(x: CGFloat(w), y: 0); ctx.rotate(by: .pi / 2)
        case .flipHorizontal:
            ctx.translateBy(x: CGFloat(w), y: 0); ctx.scaleBy(x: -1, y: 1)
        case .flipVertical:
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(flat, in: CGRect(x: 0, y: 0, width: flat.width, height: flat.height))
        guard let result = ctx.makeImage() else { return }
        checkpoint()
        setBase(result)
        annotations = []
        crop = CGRect(origin: .zero, size: imageSize)
    }

    /// Flattens the drawing, then lifts the subject off its background (undoable).
    /// Returns false if no clear subject was found.
    func removeBackground() async -> Bool {
        guard let flat = AnnotationRenderer.render(base: baseImage, scale: capture.scale, imageSize: imageSize,
                                                   crop: crop, annotations: annotations, effects: effects),
              let cut = await BackgroundRemover.removeBackgroundAsync(flat) else { return false }
        checkpoint()
        setBase(cut)
        annotations = []
        crop = CGRect(origin: .zero, size: imageSize)
        return true
    }

    /// Covers text that looks private (emails, keys, card numbers…) with solid boxes (undoable).
    /// Solid, not pixelate: pixelated text can sometimes be reconstructed.
    /// Returns how many were hidden.
    func hideSensitiveInfo() async -> Int {
        let matches = await SensitiveDataFinder.findAsync(in: baseImage, pointSize: imageSize)
        guard !matches.isEmpty else { return 0 }
        checkpoint()
        for match in matches {
            annotations.append(Annotation(tool: .filledRectangle, start: CGPoint(x: match.rect.minX, y: match.rect.minY),
                                          end: CGPoint(x: match.rect.maxX, y: match.rect.maxY),
                                          color: .black, lineWidth: 4))
        }
        return matches.count
    }

    private func setBase(_ image: CGImage) {
        baseImage = image
        imageSize = CGSize(width: CGFloat(image.width) / capture.scale, height: CGFloat(image.height) / capture.scale)
        effects = EffectImages(image: image, scale: capture.scale)
    }

    private var state: State { State(baseImage: baseImage, imageSize: imageSize, annotations: annotations, crop: crop) }

    private func restore(_ s: State) {
        if s.baseImage !== baseImage { setBase(s.baseImage) }
        annotations = s.annotations
        crop = s.crop
    }

    /// Locked: the canvas stays the picture's size. Unlocked: it grows to fit drawings.
    /// Starts from Preferences → Annotate → Automatically expand canvas; the lock button toggles it.
    var canvasLocked = !Settings.shared.annotateAutoExpand

    /// Add screenshot: places a picture to the right of the canvas and grows the canvas for it (undoable).
    func addPicture(_ image: CGImage, pointSize: CGSize) {
        checkpoint()
        // Keep it a sensible size next to the current picture.
        let maxHeight = max(crop.height, 200)
        let k = min(1, maxHeight / max(pointSize.height, 1))
        let size = CGSize(width: pointSize.width * k, height: pointSize.height * k)
        let origin = CGPoint(x: crop.maxX + 24, y: crop.minY)
        var shape = Annotation(tool: .picture, start: origin, end: CGPoint(x: origin.x + size.width, y: origin.y + size.height),
                               color: .clear, lineWidth: 0)
        shape.picture = image
        annotations.append(shape)
        crop = crop.union(shape.rect.insetBy(dx: -8, dy: -8)).integral
    }

    /// "Automatically expand canvas": grows the canvas (never shrinks it) to take in every
    /// annotation plus a small margin. Space outside the picture stays transparent.
    /// Runs as part of the change that caused it, so one Undo reverts both.
    func expandToFitAnnotations() {
        guard !canvasLocked else { return }
        var area = crop
        for a in annotations where !a.isEmpty { area = area.union(a.bounds.insetBy(dx: -8, dy: -8)) }
        if area != crop { crop = area.integral }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var nextCounterNumber: Int { (annotations.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1 }

    /// Call before every change so it can be undone.
    func checkpoint() {
        undoStack.append(state)
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        restore(next)
    }

    func rendered() -> Capture? {
        guard let flat = AnnotationRenderer.render(base: baseImage, scale: capture.scale, imageSize: imageSize,
                                                   crop: crop, annotations: annotations, effects: effects)
        else { return nil }
        guard background.enabled else { return Capture(image: flat, scale: capture.scale) }
        guard let composed = BackgroundRenderer.compose(flat, scale: capture.scale, style: background) else { return nil }
        return Capture(image: composed, scale: capture.scale)
    }
}
