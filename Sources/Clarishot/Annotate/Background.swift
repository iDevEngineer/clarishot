import AppKit
import ScreenCaptureKit

/// What fills the space around the screenshot.
enum BackgroundFill {
    case gradient(NSColor, NSColor)
    case solid(NSColor)
    case wallpaper

    /// Defined in OKLCH (lightness, chroma, hue) and drawn in Display P3.
    static let presets: [BackgroundFill] = [
        .gradient(NSColor(oklch: 0.70, 0.17, 10), NSColor(oklch: 0.84, 0.13, 65)),    // pink → peach
        .gradient(NSColor(oklch: 0.60, 0.20, 270), NSColor(oklch: 0.62, 0.22, 310)),  // blue → violet
        .gradient(NSColor(oklch: 0.77, 0.13, 185), NSColor(oklch: 0.58, 0.19, 262)),  // teal → blue
        .gradient(NSColor(oklch: 0.84, 0.18, 135), NSColor(oklch: 0.62, 0.12, 175)),  // green → teal
        .gradient(NSColor(oklch: 0.90, 0.15, 95), NSColor(oklch: 0.73, 0.17, 50)),    // yellow → orange
        .gradient(NSColor(oklch: 0.27, 0.02, 265), NSColor(oklch: 0.48, 0.03, 265)),  // slate
        .solid(NSColor(oklch: 0.96, 0.003, 265)),                                     // light
        .solid(NSColor(oklch: 0.19, 0.004, 265)),                                     // dark
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
            // Display P3 so wide-gamut custom colours keep their vividness.
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.displayP3), colors: colors, locations: [0, 1])
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

/// The wallpaper picture: the custom one from Settings, else what's actually on the desktop.
///
/// macOS's "desktop picture URL" is often stale or a default for dynamic and moving
/// wallpapers, so Clarishot captures the live wallpaper from the screen instead and keeps it
/// up to date when you switch Spaces or displays change. The file URL is only a fallback.
@MainActor
enum Wallpaper {
    private static var fileCache: (url: URL, image: CGImage)?
    private static var live: [CGDirectDisplayID: CGImage] = [:]
    private static var observers: [NSObjectProtocol] = []

    /// Starts keeping the live wallpaper up to date. Call once at launch.
    static func startWatching() {
        guard observers.isEmpty else { return }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if Settings.shared.wallpaperFollowsSpaces { refreshSoon() } }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { refreshSoon() }
        })
        Task { await refresh() }
    }

    /// Waits for the Space switch animation to finish, then captures the wallpaper again.
    private static func refreshSoon() {
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await refresh()
        }
    }

    /// Captures the wallpaper (only the desktop picture, no windows or icons) on every display.
    static func refresh() async {
        guard Settings.shared.customWallpaper == nil,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return }
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let pictures = content.windows.filter { $0.windowLayer < iconLevel }
        for screen in NSScreen.screens {
            let id = ScreenCapturer.displayID(for: screen)
            guard let display = content.displays.first(where: { $0.displayID == id }), !pictures.isEmpty else { continue }
            let filter = SCContentFilter(display: display, including: pictures)
            let config = SCStreamConfiguration()
            config.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
            config.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
            config.showsCursor = false
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                live[id] = image
            }
        }
    }

    static func url(for screen: NSScreen? = NSScreen.main) -> URL? {
        if let custom = Settings.shared.customWallpaper { return custom }
        guard let screen else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    static func image(for screen: NSScreen? = NSScreen.main) -> CGImage? {
        if Settings.shared.customWallpaper == nil, let screen, let image = live[ScreenCapturer.displayID(for: screen)] {
            return image
        }
        guard let url = url(for: screen) else { return nil }
        if let fileCache, fileCache.url == url { return fileCache.image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: 2400] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        fileCache = (url, image)
        return image
    }

    static var image: CGImage? { image() }
}

struct BackgroundStyle: Codable, Equatable {
    var enabled = false
    var fillIndex = 0
    var padding: CGFloat = 64      // points
    var cornerRadius: CGFloat = 12 // points
    var shadow = true
    /// Index into `aspects`: 0 = fit the screenshot, otherwise a fixed shape.
    var aspect = 0

    static let aspects: [(title: String, ratio: CGFloat?)] = [
        ("Auto", nil), ("1:1 Square", 1), ("4:3", 4.0 / 3), ("16:9", 16.0 / 9), ("9:16 Portrait", 9.0 / 16)
    ]

    /// Custom colours chosen with the OKLCH picker (saved as P3); used when `fillIndex` is -1.
    var customFrom: String?
    var customTo: String?

    var fill: BackgroundFill {
        if fillIndex < 0 {
            let from = customFrom.flatMap(NSColor.init(saved:)) ?? .systemIndigo
            let to = customTo.flatMap(NSColor.init(saved:)) ?? from
            return from == to ? .solid(from) : .gradient(from, to)
        }
        return BackgroundFill.presets[min(max(fillIndex, 0), BackgroundFill.presets.count - 1)]
    }

    /// Space left and right (width) and above and below (height) the content,
    /// widened on one side if needed to reach the chosen aspect ratio.
    func insets(for content: CGSize) -> CGSize {
        var w = content.width + 2 * padding, h = content.height + 2 * padding
        if let ratio = Self.aspects[min(max(aspect, 0), Self.aspects.count - 1)].ratio {
            if w / h < ratio { w = h * ratio } else { h = w / ratio }
        }
        return CGSize(width: (w - content.width) / 2, height: (h - content.height) / 2)
    }
}

/// Saved background styles, by name.
@MainActor
enum BackgroundPresets {
    private static let key = "backgroundPresets"

    static var all: [(name: String, style: BackgroundStyle)] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: BackgroundStyle].self, from: data) else { return [] }
        return dict.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }.map { ($0.key, $0.value) }
    }

    static func style(named name: String) -> BackgroundStyle? { all.first { $0.name == name }?.style }

    static func save(_ style: BackgroundStyle, as name: String) {
        var dict = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.style) })
        var s = style
        s.enabled = true
        dict[name] = s
        if let data = try? JSONEncoder().encode(dict) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func delete(_ name: String) {
        var dict = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.style) })
        dict[name] = nil
        if let data = try? JSONEncoder().encode(dict) { UserDefaults.standard.set(data, forKey: key) }
        if Settings.shared.autoBackgroundPreset == name { Settings.shared.autoBackgroundPreset = nil }
    }
}

enum BackgroundRenderer {
    /// Window captures: adds a soft shadow (following the window's rounded shape),
    /// optionally on the wallpaper. Returns nil for "transparent".
    @MainActor
    static func frameWindow(_ image: CGImage, scale: CGFloat, style: Settings.WindowStyle) -> CGImage? {
        guard style != .transparent else { return nil }
        let pad = Int(((style == .background ? CGFloat(Settings.shared.windowPadding) : 40) * scale).rounded())
        let width = image.width + 2 * pad, height = image.height + 2 * pad
        guard let ctx = AnnotationRenderer.makeContext(width: width, height: height, like: image) else { return nil }
        if style == .background {
            BackgroundFill.wallpaper.fill(CGRect(x: 0, y: 0, width: width, height: height), in: ctx, flipped: false)
        }
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 36 * scale,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.draw(image, in: CGRect(x: pad, y: pad, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// Places the flattened screenshot on the background at full resolution.
    @MainActor
    static func compose(_ image: CGImage, scale: CGFloat, style: BackgroundStyle) -> CGImage? {
        let inset = style.insets(for: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        let padX = Int((inset.width * scale).rounded()), padY = Int((inset.height * scale).rounded())
        let width = image.width + 2 * padX
        let height = image.height + 2 * padY
        guard let ctx = AnnotationRenderer.makeContext(width: width, height: height, like: image) else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        let imageRect = CGRect(x: padX, y: padY, width: image.width, height: image.height)
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
        view = makeView()
    }

    /// Rebuilt when a preset is applied so every control shows the new values.
    private func makeView() -> NSView {
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
        // Custom: any two colours (or the same one twice for a solid) from the OKLCH picker.
        let from = OklchColorButton(color: style.customFrom.flatMap(NSColor.init(saved:)) ?? .systemIndigo,
                                    size: CGSize(width: 36, height: 22))
        let to = OklchColorButton(color: style.customTo.flatMap(NSColor.init(saved:)) ?? .systemPink,
                                  size: CGSize(width: 36, height: 22))
        from.onChange = { [weak self, weak to] color in self?.pickCustom(from: color, to: to?.color) }
        to.onChange = { [weak self, weak from] color in self?.pickCustom(from: from?.color, to: color) }
        let customLabel = label("Custom")
        let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil) ?? NSImage())
        arrow.contentTintColor = .tertiaryLabelColor
        let row3 = NSStackView(views: [customLabel, from, arrow, to])
        row3.spacing = 6
        let grid = NSStackView(views: [row1, row2, row3])
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 6

        let padding = slider(value: style.padding, max: 200, action: #selector(paddingChanged(_:)))
        let radius = slider(value: style.cornerRadius, max: 40, action: #selector(radiusChanged(_:)))
        let shadow = NSButton(checkboxWithTitle: "Shadow", target: self, action: #selector(shadowToggled(_:)))
        shadow.state = style.shadow ? .on : .off
        let aspect = NSPopUpButton(frame: .zero, pullsDown: false)
        aspect.addItems(withTitles: BackgroundStyle.aspects.map(\.title))
        aspect.selectItem(at: style.aspect)
        aspect.target = self
        aspect.action = #selector(aspectChanged(_:))
        let presets = NSButton(title: "Presets ▾", target: self, action: #selector(showPresets(_:)))
        presets.bezelStyle = .rounded

        let stack = NSStackView(views: [header, grid,
                                        row(label("Padding"), padding),
                                        row(label("Corners"), radius),
                                        row(label("Shape"), aspect),
                                        NSStackView(views: [shadow, NSView(), presets])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalToConstant: 232).isActive = true
        if let last = stack.views.last {
            last.translatesAutoresizingMaskIntoConstraints = false
            last.widthAnchor.constraint(equalToConstant: 232).isActive = true
        }
        return stack
    }

    @objc private func aspectChanged(_ sender: NSPopUpButton) {
        update { $0.aspect = sender.indexOfSelectedItem; $0.enabled = true }
        toggle.state = .on
    }

    @objc private func showPresets(_ sender: NSButton) {
        let menu = NSMenu()
        let saved = BackgroundPresets.all
        for preset in saved {
            menu.addItem(ClosureMenuItem(title: preset.name) { [weak self] in
                guard let self else { return }
                self.style = preset.style
                self.onChange(self.style)
                self.view = self.makeView()
            })
        }
        if !saved.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem(title: "Save Current as Preset…") { [weak self] in self?.savePreset() })
        if !saved.isEmpty {
            let delete = NSMenuItem(title: "Delete Preset", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for preset in saved { sub.addItem(ClosureMenuItem(title: preset.name) { BackgroundPresets.delete(preset.name) }) }
            delete.submenu = sub
            menu.addItem(delete)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    private func savePreset() {
        let alert = NSAlert()
        alert.messageText = "Save background preset"
        alert.informativeText = "Name this style so you can reuse it, or apply it to every screenshot in Preferences → Screenshots."
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "e.g. Blog post"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        BackgroundPresets.save(style, as: name)
        Toast.show("Saved preset “\(name)”")
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

    private func pickCustom(from: NSColor?, to: NSColor?) {
        for s in swatches { s.isSelected = false }
        update {
            $0.fillIndex = -1
            $0.customFrom = (from ?? .systemIndigo).p3String
            $0.customTo = (to ?? from ?? .systemIndigo).p3String
            $0.enabled = true
        }
        toggle.state = .on
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
