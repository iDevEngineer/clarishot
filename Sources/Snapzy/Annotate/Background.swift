import AppKit

/// What fills the space around the screenshot.
enum BackgroundFill {
    case gradient(NSColor, NSColor)
    case solid(NSColor)
    case wallpaper

    static let presets: [BackgroundFill] = [
        .gradient(NSColor(srgbRed: 0.98, green: 0.45, blue: 0.53, alpha: 1), NSColor(srgbRed: 0.99, green: 0.74, blue: 0.40, alpha: 1)),
        .gradient(NSColor(srgbRed: 0.40, green: 0.49, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.74, green: 0.40, blue: 0.95, alpha: 1)),
        .gradient(NSColor(srgbRed: 0.20, green: 0.80, blue: 0.75, alpha: 1), NSColor(srgbRed: 0.25, green: 0.47, blue: 0.95, alpha: 1)),
        .gradient(NSColor(srgbRed: 0.55, green: 0.88, blue: 0.45, alpha: 1), NSColor(srgbRed: 0.13, green: 0.65, blue: 0.55, alpha: 1)),
        .gradient(NSColor(srgbRed: 0.99, green: 0.86, blue: 0.40, alpha: 1), NSColor(srgbRed: 0.98, green: 0.55, blue: 0.25, alpha: 1)),
        .gradient(NSColor(srgbRed: 0.18, green: 0.20, blue: 0.27, alpha: 1), NSColor(srgbRed: 0.40, green: 0.43, blue: 0.53, alpha: 1)),
        .solid(NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1)),
        .solid(NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)),
        .wallpaper
    ]

    /// Fills `rect` in the given context (any orientation).
    @MainActor
    func fill(_ rect: CGRect, in ctx: CGContext, flipped: Bool) {
        switch self {
        case .solid(let color):
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
        case .gradient(let a, let b):
            let colors = [a.cgColor, b.cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])
            else { return }
            let top = flipped ? rect.minY : rect.maxY
            let bottom = flipped ? rect.maxY : rect.minY
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: top), end: CGPoint(x: rect.maxX, y: bottom), options: [])
            ctx.restoreGState()
        case .wallpaper:
            guard let image = Wallpaper.image else {
                BackgroundFill.presets[1].fill(rect, in: ctx, flipped: flipped)
                return
            }
            // Aspect-fill the wallpaper into the rect.
            let size = CGSize(width: image.width, height: image.height)
            let scale = max(rect.width / size.width, rect.height / size.height)
            let drawn = CGSize(width: size.width * scale, height: size.height * scale)
            let target = CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                                width: drawn.width, height: drawn.height)
            ctx.saveGState()
            ctx.clip(to: rect)
            if flipped {
                AnnotationRenderer.drawImage(image, in: target, ctx: ctx)
            } else {
                ctx.draw(image, in: target)
            }
            ctx.restoreGState()
        }
    }
}

/// The current desktop picture, loaded once.
@MainActor
enum Wallpaper {
    static let image: CGImage? = {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: 2400] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }()
}

struct BackgroundStyle {
    var enabled = false
    var fillIndex = 0
    var padding: CGFloat = 64      // points
    var cornerRadius: CGFloat = 12 // points
    var shadow = true

    var fill: BackgroundFill { BackgroundFill.presets[fillIndex] }
}

enum BackgroundRenderer {
    /// Places the flattened screenshot on the background at full resolution.
    @MainActor
    static func compose(_ image: CGImage, scale: CGFloat, style: BackgroundStyle) -> CGImage? {
        let pad = Int((style.padding * scale).rounded())
        let width = image.width + 2 * pad
        let height = image.height + 2 * pad
        guard let ctx = AnnotationRenderer.makeContext(width: width, height: height, like: image) else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        let imageRect = CGRect(x: pad, y: pad, width: image.width, height: image.height)
        style.fill.fill(full, in: ctx, flipped: false)
        drawFramedImage(image, in: imageRect, radius: style.cornerRadius * scale,
                        shadow: style.shadow, shadowScale: scale, ctx: ctx, flipped: false)
        return ctx.makeImage()
    }

    /// Draws the image with rounded corners and an optional soft shadow.
    static func drawFramedImage(_ image: CGImage, in rect: CGRect, radius: CGFloat, shadow: Bool,
                                shadowScale: CGFloat, ctx: CGContext, flipped: Bool) {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        if shadow {
            ctx.saveGState()
            let dy = -8 * shadowScale // shadow offsets ignore the flip: negative is always down
            ctx.setShadow(offset: CGSize(width: 0, height: dy), blur: 30 * shadowScale,
                          color: NSColor.black.withAlphaComponent(0.4).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if flipped {
            AnnotationRenderer.drawImage(image, in: rect, ctx: ctx)
        } else {
            ctx.draw(image, in: rect)
        }
        ctx.restoreGState()
    }
}

/// Popover with the background options.
@MainActor
final class BackgroundViewController: NSViewController {
    private var style: BackgroundStyle
    private let onChange: (BackgroundStyle) -> Void
    private var swatches: [FillSwatch] = []
    private let toggle = NSSwitch()

    init(style: BackgroundStyle, onChange: @escaping (BackgroundStyle) -> Void) {
        self.style = style
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        toggle.state = style.enabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggled(_:))
        let header = NSStackView(views: [label("Background", bold: true), NSView(), toggle])

        swatches = BackgroundFill.presets.indices.map { index in
            let swatch = FillSwatch(fill: BackgroundFill.presets[index])
            swatch.isSelected = index == style.fillIndex
            swatch.onClick = { [weak self] in self?.pickFill(index) }
            return swatch
        }
        let row1 = NSStackView(views: Array(swatches.prefix(5)))
        let row2 = NSStackView(views: Array(swatches.dropFirst(5)))
        for row in [row1, row2] { row.spacing = 6 }
        let grid = NSStackView(views: [row1, row2])
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 6

        let padding = slider(value: style.padding, max: 200, action: #selector(paddingChanged(_:)))
        let radius = slider(value: style.cornerRadius, max: 40, action: #selector(radiusChanged(_:)))
        let shadow = NSButton(checkboxWithTitle: "Shadow", target: self, action: #selector(shadowToggled(_:)))
        shadow.state = style.shadow ? .on : .off

        let stack = NSStackView(views: [header, grid,
                                        row(label("Padding"), padding),
                                        row(label("Corners"), radius),
                                        shadow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalToConstant: 232).isActive = true
        view = stack
    }

    private func label(_ text: String, bold: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = bold ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 12)
        if !bold { field.textColor = .secondaryLabelColor }
        return field
    }

    private func slider(value: CGFloat, max: Double, action: Selector) -> NSSlider {
        let slider = NSSlider(value: Double(value), minValue: 0, maxValue: max, target: self, action: action)
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        return slider
    }

    private func row(_ title: NSView, _ control: NSView) -> NSStackView {
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: 60).isActive = true
        return NSStackView(views: [title, control])
    }

    private func update(_ change: (inout BackgroundStyle) -> Void) {
        change(&style)
        onChange(style)
    }

    private func pickFill(_ index: Int) {
        for (i, s) in swatches.enumerated() { s.isSelected = i == index }
        update { $0.fillIndex = index; $0.enabled = true }
        toggle.state = .on
    }

    @objc private func toggled(_ sender: NSSwitch) { update { $0.enabled = sender.state == .on } }
    @objc private func paddingChanged(_ sender: NSSlider) { update { $0.padding = CGFloat(sender.doubleValue).rounded() } }
    @objc private func radiusChanged(_ sender: NSSlider) { update { $0.cornerRadius = CGFloat(sender.doubleValue).rounded() } }
    @objc private func shadowToggled(_ sender: NSButton) { update { $0.shadow = sender.state == .on } }
}

/// A small rounded square previewing one background fill.
final class FillSwatch: NSButton {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }
    private let fill: BackgroundFill

    init(fill: BackgroundFill) {
        self.fill = fill
        super.init(frame: .zero)
        isBordered = false
        title = ""
        target = self
        action = #selector(clicked)
        if case .wallpaper = fill { toolTip = "Desktop wallpaper" }
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 40).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        fill.fill(rect, in: ctx, flipped: isFlipped)
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(isSelected ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.cgColor)
        ctx.setLineWidth(isSelected ? 2 : 1)
        ctx.strokePath()
    }

    @objc private func clicked() { onClick?() }
}
