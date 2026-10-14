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
