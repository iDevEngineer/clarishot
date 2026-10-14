import AppKit

/// OKLCH: a colour described by lightness (0–1), chroma (colourfulness, 0–~0.37) and hue (0–360°).
/// Equal steps look equally different to the eye, which makes it good for picking palettes.
/// Converted here to Display P3, the wide colour range Mac screens show.
struct Oklch: Equatable {
    var lightness: Double
    var chroma: Double
    var hue: Double

    enum Gamut {
        /// Fits ordinary sRGB: looks the same everywhere.
        case sRGB
        /// Only fits the wider Display P3 range: vivid on Mac screens, duller on older ones.
        case p3
        /// Outside both; shown as the nearest P3 colour.
        case outside
    }

    /// Linear sRGB (may be outside 0…1 for wide-gamut colours), via OKLab.
    private var linearSRGB: (Double, Double, Double) {
        let h = hue * .pi / 180
        let a = chroma * cos(h), b = chroma * sin(h)
        let l_ = lightness + 0.3963377774 * a + 0.2158037573 * b
        let m_ = lightness - 0.1055613458 * a - 0.0638541728 * b
        let s_ = lightness - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    /// Linear Display P3, from linear sRGB.
    private var linearP3: (Double, Double, Double) {
        let (r, g, b) = linearSRGB
        return (0.8224621 * r + 0.1775380 * g + 0.0000000 * b,
                0.0331941 * r + 0.9668058 * g + 0.0000000 * b,
                0.0170827 * r + 0.0723974 * g + 0.9105199 * b)
    }

    var gamut: Gamut {
        let tolerance = 0.0005
        func fits(_ c: (Double, Double, Double)) -> Bool {
            [c.0, c.1, c.2].allSatisfy { $0 >= -tolerance && $0 <= 1 + tolerance }
        }
        if fits(linearSRGB) { return .sRGB }
        return fits(linearP3) ? .p3 : .outside
    }

    /// The colour in Display P3 (out-of-range values are clipped to the nearest P3 colour).
    var color: NSColor {
        func encode(_ v: Double) -> CGFloat {
            let x = min(max(v, 0), 1)
            return CGFloat(x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055)
        }
        let (r, g, b) = linearP3
        return NSColor(displayP3Red: encode(r), green: encode(g), blue: encode(b), alpha: 1)
    }

    /// e.g. "oklch(62% 0.25 29)" — the same notation CSS uses.
    var css: String {
        String(format: "oklch(%.0f%% %.3f %.0f)", lightness * 100, chroma, hue)
    }
}

/// Lightness, chroma and hue sliders with a live swatch, the CSS value and a gamut note.
final class OklchPickerView: NSView {
    var onChange: ((NSColor) -> Void)?
    var onUse: ((NSColor) -> Void)?

    private var value = Oklch(lightness: 0.65, chroma: 0.22, hue: 30)
    private let swatch = NSView()
    private let cssLabel = NSTextField(labelWithString: "")
    private let gamutLabel = NSTextField(labelWithString: "")
    private var sliders: [NSSlider] = []
    private var targets: [Callback] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 8
        swatch.layer?.borderWidth = 0.5
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.widthAnchor.constraint(equalToConstant: 44).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 44).isActive = true
        cssLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cssLabel.isSelectable = true
        gamutLabel.font = .systemFont(ofSize: 11)
        gamutLabel.textColor = .secondaryLabelColor
        let info = NSStackView(views: [cssLabel, gamutLabel])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 2
        let top = NSStackView(views: [swatch, info])
        top.spacing = 10

        let rows = [
            sliderRow("Lightness", 0...1, value.lightness) { $0.lightness = $1 },
            sliderRow("Chroma", 0...0.37, value.chroma) { $0.chroma = $1 },
            sliderRow("Hue", 0...360, value.hue) { $0.hue = $1 }
        ]
        let use = NSButton(title: "Use Colour", target: nil, action: nil)
        use.bezelStyle = .rounded
        use.controlSize = .small
        let useTarget = Callback { [weak self] _ in
            guard let self else { return }
            self.onUse?(self.value.color)
        }
        targets.append(useTarget)
        use.target = useTarget
        use.action = #selector(Callback.fire(_:))

        let stack = NSStackView(views: [top] + rows + [use])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Start from an existing colour (e.g. the current one).
    func setColor(_ color: NSColor) {
        guard let c = color.usingColorSpace(.extendedSRGB) else { return }
        func linear(_ v: CGFloat) -> Double {
            let x = Double(v)
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let r = linear(c.redComponent), g = linear(c.greenComponent), b = linear(c.blueComponent)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        var h = atan2(B, A) * 180 / .pi
        if h < 0 { h += 360 }
        value = Oklch(lightness: L, chroma: hypot(A, B), hue: h)
        sliders[0].doubleValue = value.lightness
        sliders[1].doubleValue = value.chroma
        sliders[2].doubleValue = value.hue
        update()
    }

    private func sliderRow(_ title: String, _ range: ClosedRange<Double>, _ start: Double,
                           set: @escaping (inout Oklch, Double) -> Void) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 62).isActive = true
        let slider = NSSlider(value: start, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let target = Callback { [weak self] sender in
            guard let self, let v = (sender as? NSSlider)?.doubleValue else { return }
            set(&self.value, v)
            self.update()
            self.onChange?(self.value.color)
        }
        targets.append(target)
        slider.target = target
        slider.action = #selector(Callback.fire(_:))
        sliders.append(slider)
        return NSStackView(views: [label, slider])
    }

    private func update() {
        swatch.layer?.backgroundColor = value.color.cgColor
        cssLabel.stringValue = value.css
        switch value.gamut {
        case .sRGB: gamutLabel.stringValue = "Fits sRGB: looks the same everywhere"
        case .p3: gamutLabel.stringValue = "Wide-gamut P3: extra vivid on Mac screens"
        case .outside: gamutLabel.stringValue = "Beyond P3: shown as the nearest colour"
        }
    }
}

/// A colour swatch button that opens the OKLCH picker in a popover. Used wherever Clarishot
/// lets you choose a colour outside the editor's own palette.
final class OklchColorButton: NSButton {
    var color: NSColor { didSet { needsDisplay = true } }
    /// Called live while the sliders move.
    var onChange: ((NSColor) -> Void)?
    /// Draw a colour-wheel ring around the swatch, so it reads as "pick any colour".
    var showsWheel = false { didSet { needsDisplay = true } }
    private var popover: NSPopover?

    init(color: NSColor, size: CGSize = CGSize(width: 44, height: 22)) {
        self.color = color
        super.init(frame: .zero)
        isBordered = false
        title = ""
        toolTip = "Choose a colour (OKLCH)"
        target = self
        action = #selector(open)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        if showsWheel, let ctx = NSGraphicsContext.current?.cgContext {
            // A hue ring (drawn as thin wedges) with the current colour in the middle.
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let radius = min(bounds.width, bounds.height) / 2 - 0.5
            let steps = 72
            for i in 0..<steps {
                let a0 = CGFloat(i) / CGFloat(steps) * 2 * .pi, a1 = CGFloat(i + 1) / CGFloat(steps) * 2 * .pi + 0.02
                ctx.move(to: center)
                ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: false)
                ctx.closePath()
                ctx.setFillColor(NSColor(oklch: 0.72, 0.16, Double(i) / Double(steps) * 360).cgColor)
                ctx.fillPath()
            }
            let inner = bounds.insetBy(dx: bounds.width * 0.25, dy: bounds.height * 0.25)
            ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
            ctx.fillEllipse(in: inner.insetBy(dx: -1, dy: -1))
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: inner)
            return
        }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        color.setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }

    @objc private func open() {
        let picker = OklchPickerView()
        picker.setColor(color)
        picker.onChange = { [weak self] new in
            self?.color = new
            self?.onChange?(new)
        }
        picker.onUse = { [weak self] new in
            self?.color = new
            self?.onChange?(new)
            self?.popover?.close()
        }
        let controller = NSViewController()
        let container = NSView()
        picker.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            picker.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            picker.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            picker.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        controller.view = container
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        self.popover = popover
    }
}

extension NSColor {
    /// Saved form that keeps wide-gamut colours: "P3 r g b".
    var p3String: String {
        let c = usingColorSpace(.displayP3) ?? self
        return String(format: "P3 %.4f %.4f %.4f", c.redComponent, c.greenComponent, c.blueComponent)
    }

    /// Reads "P3 r g b" (or an older "#RRGGBB").
    convenience init?(saved: String) {
        if saved.hasPrefix("P3 ") {
            let parts = saved.dropFirst(3).split(separator: " ").compactMap { Double($0) }
            guard parts.count == 3 else { return nil }
            self.init(displayP3Red: parts[0], green: parts[1], blue: parts[2], alpha: 1)
        } else {
            self.init(hex: saved)
        }
    }
}

extension NSColor {
    /// A colour from OKLCH values (lightness 0–1, chroma, hue in degrees), in Display P3.
    convenience init(oklch lightness: Double, _ chroma: Double, _ hue: Double) {
        let c = Oklch(lightness: lightness, chroma: chroma, hue: hue).color
        self.init(displayP3Red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: 1)
    }
}

/// Clarishot's built-in colours, defined in OKLCH so they share even lightness and vividness,
/// and come out in Display P3 (richer than the standard system colours on Mac screens).
enum OklchPalette {
    static let red = NSColor(oklch: 0.63, 0.25, 27)
    static let orange = NSColor(oklch: 0.73, 0.19, 50)
    static let yellow = NSColor(oklch: 0.88, 0.18, 95)
    static let green = NSColor(oklch: 0.72, 0.21, 145)
    static let blue = NSColor(oklch: 0.60, 0.21, 258)
    static let purple = NSColor(oklch: 0.58, 0.24, 300)
    static let pink = NSColor(oklch: 0.67, 0.23, 352)
    static let gray = NSColor(oklch: 0.60, 0, 0)
    static let black = NSColor(oklch: 0.16, 0, 0)
    static let white = NSColor(oklch: 1, 0, 0)

    /// The editor's swatches, in order, with their names.
    static let annotate: [(color: NSColor, name: String)] = [
        (red, "Red"), (orange, "Orange"), (yellow, "Yellow"), (green, "Green"),
        (blue, "Blue"), (purple, "Purple"), (black, "Black"), (white, "White")
    ]
}
