import AppKit
import UniformTypeIdentifiers

/// Clarishot's background style (inside an NSView, plain `BackgroundStyle` means AppKit's own type).
typealias CanvasBackground = BackgroundStyle

/// The editor's background panel, shown as a column on the left: presets, None, gradients,
/// wallpapers, blurred wallpapers, plain colours, then padding / inset / shadow / corners,
/// alignment and ratio. Every change is reported through `onChange`.
@MainActor
final class BackgroundSidebarView: NSView {
    static let width: CGFloat = 252

    private var style: CanvasBackground
    private let onChange: (CanvasBackground) -> Void
    private var showAllGradients = false
    private var targets: [Callback] = []
    private let content = NSStackView()
    private static let picturesKey = "backgroundPictures"

    init(style: CanvasBackground, onChange: @escaping (CanvasBackground) -> Void) {
        self.style = style
        self.onChange = onChange
        super.init(frame: .zero)
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .withinWindow
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 16, right: 12)
        content.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        // A plain view, not NSBox: a separator box prefers to be 1 pt tall, and spanning the full
        // height that preference squashed the whole editor window.
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor.separatorColor.cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor), effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor), effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor), border.topAnchor.constraint(equalTo: topAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor), border.widthAnchor.constraint(equalToConstant: 1),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Replace the shown style (e.g. after undo or opening a preset) without reporting a change.
    func setStyle(_ new: CanvasBackground) {
        style = new
        rebuild()
    }

    // MARK: Building

    private var innerWidth: CGFloat { Self.width - 24 }

    private func rebuild() {
        targets.removeAll()
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Presets… ▾ and +
        let presets = NSPopUpButton(frame: .zero, pullsDown: true)
        presets.addItem(withTitle: "Presets…")
        let saved = BackgroundPresets.all
        for preset in saved {
            presets.menu?.addItem(ClosureMenuItem(title: preset.name) { [weak self] in self?.apply(preset.style) })
        }
        if saved.isEmpty {
            let empty = NSMenuItem(title: "No saved presets yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            presets.menu?.addItem(empty)
        } else {
            presets.menu?.addItem(.separator())
            let delete = NSMenuItem(title: "Delete Preset", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for preset in saved {
                sub.addItem(ClosureMenuItem(title: preset.name) { [weak self] in
                    BackgroundPresets.delete(preset.name)
                    self?.rebuild()
                })
            }
            delete.submenu = sub
            presets.menu?.addItem(delete)
        }
        let add = button(symbol: "plus", tip: "Save as preset") { [weak self] in self?.savePreset() }
        let presetRow = NSStackView(views: [presets, add])
        presetRow.spacing = 6
        fixWidth(presetRow)

        // None
        let none = NoneTile(selected: !style.enabled) { [weak self] in
            self?.change { $0.enabled = false }
        }
        none.translatesAutoresizingMaskIntoConstraints = false
        none.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        none.heightAnchor.constraint(equalToConstant: 30).isActive = true

        // Gradients
        let gradients = MeshBackground.designs.indices.map { index in
            tile(.mesh(index), spec: "mesh:\(index)")
        }
        let shown = showAllGradients ? gradients : Array(gradients.prefix(10))
        let toggle = linkButton(showAllGradients ? "Show less ⌃" : "Show more ⌄") { [weak self] in
            self?.showAllGradients.toggle()
            self?.rebuild()
        }

        // Wallpapers: desktop picture, your saved pictures, then +
        var wallpapers = [tile(.wallpaper, spec: "wallpaper", tip: "Desktop wallpaper")]
        for path in savedPictures() {
            wallpapers.append(tile(.picture(URL(fileURLWithPath: path)), spec: "picture:\(path)",
                                   tip: (path as NSString).lastPathComponent))
        }
        wallpapers.append(AddTile { [weak self] in self?.choosePicture() })

        // Blurred
        let blurred = (0..<3).map { tile(.blurredWallpaper($0), spec: "blur:\($0)", tip: ["Soft", "Frosted", "Dim"][$0]) }

        // Plain colours + custom OKLCH colour
        var plain: [NSView] = BackgroundFill.plainColors.map { color in
            let spec = "solid:\(color.p3String)"
            return ColorDot(color: color, selected: style.enabled && style.fillSpec == spec) { [weak self] in
                self?.change { $0.fillSpec = spec; $0.enabled = true }
            }
        }
        let current = (style.fillSpec?.hasPrefix("solid:") == true) ? style.fill : nil
        var customColor = NSColor(oklch: 0.65, 0.2, 280)
        if case .solid(let c)? = current { customColor = c }
        let custom = OklchColorButton(color: customColor, size: CGSize(width: 20, height: 20))
        custom.toolTip = "Custom colour…"
        custom.showsWheel = true
        custom.onChange = { [weak self] color in
            self?.change { $0.fillSpec = "solid:\(color.p3String)"; $0.enabled = true }
        }
        plain.append(custom)

        let full = innerWidth, half = (innerWidth - 14) / 2
        let padding = slider(style.padding, 0...200, width: full) { s, v in s.padding = v }
        let inset = slider(style.effectiveInset, 0...60, width: half) { s, v in s.inset = v }
        let shadow = slider(style.effectiveShadow, 0...1, width: half) { s, v in s.shadowAmount = v; s.shadow = v > 0 }
        let corners = slider(style.cornerRadius, 0...40, width: half) { s, v in s.cornerRadius = v }
        let ratio = NSPopUpButton(frame: .zero, pullsDown: false)
        ratio.addItems(withTitles: CanvasBackground.aspects.map(\.title).map { $0 == "Auto" ? "Auto" : $0 })
        ratio.selectItem(at: style.aspect)
        bind(ratio) { [weak self, weak ratio] in
            let index = ratio?.indexOfSelectedItem ?? 0
            self?.change { $0.aspect = index; $0.enabled = true }
        }

        let sliders = NSStackView(views: [
            labelled("Padding", padding),
            twoColumns(labelled("Inset", inset), labelled("Corners", corners)),
            twoColumns(labelled("Shadow", shadow), NSView()),
            twoColumns(labelled("Alignment", alignmentGrid()), labelled("Ratio", ratio))
        ])
        sliders.orientation = .vertical
        sliders.alignment = .leading
        sliders.spacing = 12

        let divider = NSBox()
        divider.boxType = .separator
        fixWidth(divider)

        for view in [presetRow, none,
                     header("Gradients", accessory: toggle), grid(shown, columns: 5),
                     header("Wallpapers"), grid(wallpapers, columns: 5),
                     header("Blurred"), grid(blurred, columns: 5),
                     header("Plain color"), grid(plain, columns: 9, size: 20, spacing: 5),
                     divider, sliders] {
            content.addArrangedSubview(view)
        }
    }

    // MARK: Pieces

    private func tile(_ fill: BackgroundFill, spec: String, tip: String? = nil) -> NSView {
        let tile = FillTile(fill: fill, selected: style.enabled && style.fillSpec == spec) { [weak self] in
            self?.change { $0.fillSpec = spec; $0.enabled = true }
        }
        tile.toolTip = tip
        return tile
    }

    private func grid(_ views: [NSView], columns: Int, size: CGFloat = 40, spacing: CGFloat = 8) -> NSView {
        let rows = stride(from: 0, to: views.count, by: columns).map { start -> NSView in
            let row = NSStackView(views: Array(views[start..<min(start + columns, views.count)]))
            row.spacing = spacing
            for v in row.arrangedSubviews {
                v.translatesAutoresizingMaskIntoConstraints = false
                v.widthAnchor.constraint(equalToConstant: size).isActive = true
                v.heightAnchor.constraint(equalToConstant: size).isActive = true
            }
            return row
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func header(_ title: String, accessory: NSView? = nil) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        let row = NSStackView(views: [label, NSView()] + (accessory.map { [$0] } ?? []))
        fixWidth(row)
        return row
    }

    private func labelled(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    private func twoColumns(_ a: NSView, _ b: NSView) -> NSView {
        let row = NSStackView(views: [a, b])
        row.distribution = .fillEqually
        row.alignment = .top
        row.spacing = 14
        fixWidth(row)
        return row
    }

    private func slider(_ value: CGFloat, _ range: ClosedRange<CGFloat>, width: CGFloat,
                        set: @escaping (inout CanvasBackground, CGFloat) -> Void) -> NSSlider {
        let slider = NSSlider(value: Double(value), minValue: Double(range.lowerBound), maxValue: Double(range.upperBound),
                              target: nil, action: nil)
        slider.controlSize = .small
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: width).isActive = true
        bind(slider) { [weak self, weak slider] in
            let v = CGFloat(slider?.doubleValue ?? 0)
            self?.change(rebuildAfter: false) { set(&$0, v); $0.enabled = true }
        }
        return slider
    }

    /// 3 × 3 buttons choosing where the screenshot sits when the ratio leaves spare room.
    private func alignmentGrid() -> NSView {
        let current = style.alignment ?? 4
        let rows = (0..<3).map { row -> NSView in
            let buttons = (0..<3).map { col -> NSView in
                let index = row * 3 + col
                return AlignmentDot(position: index, selected: index == current) { [weak self] in
                    self?.change { $0.alignment = index; $0.enabled = true }
                }
            }
            let stack = NSStackView(views: buttons)
            stack.spacing = 6
            return stack
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.spacing = 6
        return stack
    }

    private func button(symbol: String, tip: String, action: @escaping () -> Void) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                              target: nil, action: nil)
        button.bezelStyle = .rounded
        button.toolTip = tip
        bind(button, action)
        return button
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.isBordered = false
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = .secondaryLabelColor
        bind(button, action)
        return button
    }

    private func bind(_ control: NSControl, _ action: @escaping () -> Void) {
        let target = Callback { _ in action() }
        targets.append(target)
        control.target = target
        control.action = #selector(Callback.fire(_:))
    }

    private func fixWidth(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
    }

    // MARK: Changes

    private func change(rebuildAfter: Bool = true, _ edit: (inout CanvasBackground) -> Void) {
        edit(&style)
        onChange(style)
        // Rebuild on the next turn so the clicked control finishes handling the click first.
        if rebuildAfter { DispatchQueue.main.async { [weak self] in self?.rebuild() } }
    }

    private func apply(_ preset: CanvasBackground) {
        style = preset
        onChange(style)
        DispatchQueue.main.async { [weak self] in self?.rebuild() }
    }

    private func savePreset() {
        let alert = NSAlert()
        alert.messageText = "Save background preset"
        alert.informativeText = "Name this style so you can reuse it, or apply it to every screenshot in Preferences → Screenshots."
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Preset name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            BackgroundPresets.save(self.style, as: name)
            self.rebuild()
        }
    }

    private func savedPictures() -> [String] {
        (UserDefaults.standard.stringArray(forKey: Self.picturesKey) ?? []).filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            var list = self.savedPictures().filter { $0 != url.path }
            list.insert(url.path, at: 0)
            UserDefaults.standard.set(Array(list.prefix(8)), forKey: Self.picturesKey)
            self.change { $0.fillSpec = "picture:\(url.path)"; $0.enabled = true }
        }
    }
}

// MARK: - Tiles

/// A rounded square showing a background fill; outlined when selected.
private final class FillTile: NSView {
    private let fill: BackgroundFill
    private let selected: Bool
    private let onClick: () -> Void

    init(fill: BackgroundFill, selected: Bool, onClick: @escaping () -> Void) {
        self.fill = fill
        self.selected = selected
        self.onClick = onClick
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        fill.fill(rect, in: ctx, flipped: true)
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor((selected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor)
        ctx.setLineWidth(selected ? 2.5 : 0.5)
        ctx.strokePath()
    }

    override func mouseDown(with event: NSEvent) { onClick() }
}

/// The wide "None" button at the top.
private final class NoneTile: NSView {
    private let selected: Bool
    private let onClick: () -> Void

    init(selected: Bool, onClick: @escaping () -> Void) {
        self.selected = selected
        self.onClick = onClick
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        path.fill()
        (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = selected ? 2.5 : 0.5
        path.stroke()
        let text = NSAttributedString(string: "None", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                                    .foregroundColor: NSColor.labelColor])
        let size = text.size()
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func mouseDown(with event: NSEvent) { onClick() }
}

/// Dashed "+" tile for adding a picture.
private final class AddTile: NSView {
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        toolTip = "Add a picture"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        path.setLineDash([3, 3], count: 2, phase: 0)
        path.lineWidth = 1
        NSColor.secondaryLabelColor.setStroke()
        path.stroke()
        let plus = NSBezierPath()
        plus.move(to: CGPoint(x: bounds.midX - 6, y: bounds.midY)); plus.line(to: CGPoint(x: bounds.midX + 6, y: bounds.midY))
        plus.move(to: CGPoint(x: bounds.midX, y: bounds.midY - 6)); plus.line(to: CGPoint(x: bounds.midX, y: bounds.midY + 6))
        plus.lineWidth = 1.5
        NSColor.labelColor.setStroke()
        plus.stroke()
    }

    override func mouseDown(with event: NSEvent) { onClick() }
}

/// A round colour swatch.
private final class ColorDot: NSView {
    private let color: NSColor
    private let selected: Bool
    private let onClick: () -> Void

    init(color: NSColor, selected: Bool, onClick: @escaping () -> Void) {
        self.color = color
        self.selected = selected
        self.onClick = onClick
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let dot = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        color.setFill()
        dot.fill()
        (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        dot.lineWidth = selected ? 2 : 0.5
        dot.stroke()
    }

    override func mouseDown(with event: NSEvent) { onClick() }
}

/// One of the 3 × 3 alignment buttons: a small framed square, filled when chosen.
private final class AlignmentDot: NSView {
    private let position: Int
    private let selected: Bool
    private let onClick: () -> Void

    init(position: Int, selected: Bool, onClick: @escaping () -> Void) {
        self.position = position
        self.selected = selected
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        NSColor.labelColor.withAlphaComponent(selected ? 0.2 : 0.08).setFill()
        outer.fill()
        // A small "screenshot" block pushed toward the matching corner or edge.
        let box = bounds.insetBy(dx: 4, dy: 3)
        let size = CGSize(width: box.width * 0.5, height: box.height * 0.5)
        let fx = CGFloat(position % 3) / 2, fy = CGFloat(position / 3) / 2
        let block = CGRect(x: box.minX + (box.width - size.width) * fx,
                           y: box.maxY - size.height - (box.height - size.height) * fy,  // row 0 is the top
                           width: size.width, height: size.height)
        let inner = NSBezierPath(roundedRect: block, xRadius: 1.5, yRadius: 1.5)
        (selected ? NSColor.labelColor : NSColor.secondaryLabelColor).setFill()
        inner.fill()
    }

    override func mouseDown(with event: NSEvent) { onClick() }
}
