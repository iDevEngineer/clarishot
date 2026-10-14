import AppKit

/// The annotate editor: a toolbar across the top and the canvas below.
@MainActor
final class AnnotateWindowController: NSObject, NSWindowDelegate {
    private static var openControllers: [AnnotateWindowController] = []

    /// `onDone`: opened by "Capture & Annotate" — a Done button sends the edited capture on
    /// to the usual after-capture actions (preview card, copy, save…).
    static func open(_ capture: Capture, onDone: ((Capture) -> Void)? = nil) {
        let controller = AnnotateWindowController(capture: capture)
        controller.onDone = onDone
        if onDone != nil { controller.addDoneButton() }
        openControllers.append(controller)
        let settings = Settings.shared
        if settings.annotateShowDockIcon { NSApp.setActivationPolicy(.regular) }
        if settings.annotateAlwaysOnTop { controller.window.level = .floating }
        NSApp.activate(ignoringOtherApps: true)
        controller.window.makeKeyAndOrderFront(nil)
        controller.window.makeFirstResponder(controller.canvas)
        if settings.annotateRememberBackground && settings.annotateBackgroundWasOpen {
            DispatchQueue.main.async { controller.showBackground() }
        }
    }

    private static let colors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .black, .white
    ]
    private static let widths: [CGFloat] = [2, 4, 8]
    private static let toolbarHeight: CGFloat = 52

    private let document: AnnotateDocument
    private let window: AnnotateWindow
    private let canvas: CanvasView
    private var toolButtons: [Tool: ToolButton] = [:]
    private let colorButton = ColorSwatchButton(color: .systemRed)
    private let widthButton = ToolButton(symbol: "line.3.horizontal", tip: "Line width")
    private let undoButton = ToolButton(symbol: "arrow.uturn.backward", tip: "Undo (⌘Z)")
    private let redoButton = ToolButton(symbol: "arrow.uturn.forward", tip: "Redo (⇧⌘Z)")
    private let backgroundButton = ToolButton(symbol: "photo.artframe", tip: "Background")
    private let styleButton = ToolButton(symbol: "paintbrush", tip: "Style: arrow, text and crop shape")
    private let imageButton = ToolButton(symbol: "wand.and.stars", tip: "Image: rotate, flip, remove background, hide sensitive info")
    private var popover: NSPopover?
    private var onDone: ((Capture) -> Void)?
    private var actionsStack: NSStackView?

    private func addDoneButton() {
        let done = NSButton(title: "Done", target: self, action: #selector(doneEditing))
        done.bezelStyle = .rounded
        done.bezelColor = .controlAccentColor
        done.keyEquivalent = "\r"
        actionsStack?.addArrangedSubview(done)
    }

    @objc private func doneEditing() {
        canvas.commitText()
        guard let result = document.rendered() else { return }
        let callback = onDone
        onDone = nil
        window.close()
        callback?(result.from(document.capture.sourceBundleID))
    }

    private init(capture: Capture) {
        document = AnnotateDocument(capture: capture)
        canvas = CanvasView(document: document)
        window = AnnotateWindow(contentRect: Self.initialFrame(for: capture.pointSize),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Annotate"
        window.minSize = CGSize(width: 1000, height: 420)
        window.delegate = self
        window.commands = self
        buildContent()
        window.useRoundedCorners()
        selectTool(.arrow)
        updateWidthIcon()
        refreshUndo()
    }

    private static func initialFrame(for imageSize: CGSize) -> CGRect {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(max(imageSize.width + 120, 960), visible.width * 0.9)
        let height = min(max(imageSize.height + toolbarHeight + 120, 460), visible.height * 0.85)
        return CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
    }

    // MARK: Layout

    private func buildContent() {
        let content = NSView()
        window.contentView = content

        let toolbar = ToolbarView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(canvas)
        content.addSubview(toolbar)

        let tools = NSStackView(views: Tool.allCases.map { tool in
            let button = ToolButton(symbol: tool.symbol, tip: "\(tool.title) (\(tool.key.uppercased()))")
            button.onClick = { [weak self] in self?.selectTool(tool) }
            toolButtons[tool] = button
            return button
        })
        tools.spacing = 2

        colorButton.toolTip = "Colour"
        colorButton.onClick = { [weak self] in self?.showColors() }
        widthButton.onClick = { [weak self] in self?.cycleWidth() }
        undoButton.onClick = { [weak self] in self?.undo() }
        redoButton.onClick = { [weak self] in self?.redo() }
        backgroundButton.onClick = { [weak self] in self?.showBackground() }

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyImage))
        let save = NSButton(title: "Save", target: self, action: #selector(saveImage))
        save.bezelColor = .controlAccentColor
        for b in [copy, save] { b.bezelStyle = .rounded; b.controlSize = .regular }

        styleButton.onClick = { [weak self] in self?.showStyleMenu() }
        imageButton.onClick = { [weak self] in self?.showImageMenu() }
        let actions = NSStackView(views: [backgroundButton, imageButton, separator(), styleButton, colorButton, widthButton,
                                          separator(), undoButton, redoButton, separator(), copy, save])
        actions.spacing = 4
        actionsStack = actions

        tools.translatesAutoresizingMaskIntoConstraints = false
        actions.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(tools)
        toolbar.addSubview(actions)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Self.toolbarHeight),

            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            tools.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            tools.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 84), // room for traffic lights
            actions.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -14),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: tools.trailingAnchor, constant: 12)
        ])

        canvas.onChange = { [weak self] in self?.refreshUndo() }
        canvas.onToolShortcut = { [weak self] tool in self?.selectTool(tool) }
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return line
    }

    // MARK: Tools and style

    private func selectTool(_ tool: Tool) {
        canvas.tool = tool
        for (t, button) in toolButtons { button.isSelected = t == tool }
        window.makeFirstResponder(canvas)
    }

    private func showColors() {
        let palette = ColorPaletteViewController(colors: Self.colors) { [weak self] color, close in
            guard let self else { return }
            self.canvas.color = color
            self.colorButton.color = color
            self.canvas.applyStyleToSelection()
            if close { self.popover?.close() }
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = palette
        popover.show(relativeTo: colorButton.bounds, of: colorButton, preferredEdge: .maxY)
        self.popover = popover
    }

    /// Arrow shape, text style and crop ratio, with the current choice ticked.
    private func showStyleMenu() {
        let menu = NSMenu()
        func header(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        header("Arrow")
        for style in ArrowStyle.allCases {
            let item = ClosureMenuItem(title: style.title) { [weak self] in
                self?.canvas.arrowStyle = style
                self?.canvas.applyStyleToSelection()
                self?.selectTool(.arrow)
            }
            item.state = canvas.arrowStyle == style ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        header("Text")
        for style in TextStyle.allCases {
            let item = ClosureMenuItem(title: style.title) { [weak self] in
                self?.canvas.textStyle = style
                self?.canvas.applyStyleToSelection()
                self?.selectTool(.text)
            }
            item.state = canvas.textStyle == style ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        header("Crop")
        let ratios: [(String, CGFloat?)] = [("Free", nil), ("1:1 Square", 1), ("4:3", 4.0 / 3), ("3:2", 1.5),
                                           ("16:9", 16.0 / 9), ("9:16 Portrait", 9.0 / 16)]
        for (title, ratio) in ratios {
            let item = ClosureMenuItem(title: title) { [weak self] in
                self?.canvas.cropAspect = ratio
                self?.selectTool(.crop)
            }
            item.state = canvas.cropAspect == ratio ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: styleButton.bounds.maxY + 4), in: styleButton)
    }

    private func showImageMenu() {
        let menu = NSMenu()
        let ops: [(String, AnnotateDocument.Transform)] = [
            ("Rotate Left", .rotateLeft), ("Rotate Right", .rotateRight),
            ("Flip Horizontally", .flipHorizontal), ("Flip Vertically", .flipVertical)
        ]
        for (title, op) in ops {
            menu.addItem(ClosureMenuItem(title: title) { [weak self] in
                guard let self else { return }
                self.canvas.commitText()
                self.document.apply(op)
                self.canvas.refresh()
                self.refreshUndo()
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Remove Background") { [weak self] in
            guard let self else { return }
            self.canvas.commitText()
            Task {
                if await self.document.removeBackground() {
                    self.canvas.refresh()
                    self.refreshUndo()
                } else {
                    Toast.show("No clear subject found to cut out")
                }
            }
        })
        menu.addItem(ClosureMenuItem(title: "Hide Sensitive Info") { [weak self] in
            guard let self else { return }
            self.canvas.commitText()
            Task {
                let count = await self.document.hideSensitiveInfo()
                self.canvas.refresh()
                self.refreshUndo()
                Toast.show(count == 0 ? "No sensitive info found" : "Hid \(count) item\(count == 1 ? "" : "s")")
            }
        })
        menu.addItem(.separator())
        let note = NSMenuItem(title: "Drawings are merged into the image first", action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: imageButton.bounds.maxY + 4), in: imageButton)
    }

    fileprivate func showBackground() {
        Settings.shared.annotateBackgroundWasOpen = true
        let controller = BackgroundViewController(style: document.background) { [weak self] style in
            guard let self else { return }
            self.document.background = style
            self.backgroundButton.isSelected = style.enabled
            Settings.shared.annotateBackgroundWasOpen = style.enabled
            self.canvas.refresh()
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: backgroundButton.bounds, of: backgroundButton, preferredEdge: .maxY)
        self.popover = popover
    }

    private func cycleWidth() {
        let widths = Self.widths
        let index = widths.firstIndex(of: canvas.lineWidth) ?? 0
        canvas.lineWidth = widths[(index + 1) % widths.count]
        updateWidthIcon()
        canvas.applyStyleToSelection()
    }

    private func updateWidthIcon() {
        let w = canvas.lineWidth
        let image = NSImage(size: CGSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: CGRect(x: 1, y: rect.midY - w / 2, width: 16, height: w),
                         xRadius: w / 2, yRadius: w / 2).fill()
            return true
        }
        image.isTemplate = true
        widthButton.image = image
        widthButton.toolTip = "Line width: \(["Thin", "Medium", "Thick"][Self.widths.firstIndex(of: w) ?? 1])"
    }

    // MARK: Commands

    func undo() {
        canvas.commitText()
        document.undo()
        canvas.refresh()
        refreshUndo()
    }

    func redo() {
        document.redo()
        canvas.refresh()
        refreshUndo()
    }

    private func refreshUndo() {
        undoButton.isEnabled = document.canUndo
        redoButton.isEnabled = document.canRedo
    }

    @objc func copyImage() {
        canvas.commitText()
        guard let result = document.rendered() else { return }
        result.copyToClipboard()
        Toast.show("Copied to clipboard")
    }

    @objc func saveImage() {
        canvas.commitText()
        guard let result = document.rendered() else { return }
        do {
            try result.save()
            Toast.show(Capture.savedMessage)
            window.close()
        } catch let error as CocoaError where error.code == .userCancelled {
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.openControllers.removeAll { $0 === self }
        // Back to a menu-bar-only app once the last editor closes.
        if Self.openControllers.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Handles ⌘ shortcuts, since Clarishot has no main menu bar.
final class AnnotateWindow: NSWindow {
    weak var commands: AnnotateWindowController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let editingText = firstResponder is NSText
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }

        switch (key, flags.contains(.shift)) {
        case ("z", false) where !editingText: commands?.undo(); return true
        case ("z", true) where !editingText: commands?.redo(); return true
        case ("c", false) where !editingText: commands?.copyImage(); return true
        case ("s", false): commands?.saveImage(); return true
        case ("w", false): close(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

/// Toolbar background; dragging it moves the window.
private final class ToolbarView: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .titlebar
        blendingMode = .withinWindow
        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var mouseDownCanMoveWindow: Bool { true }
}

/// Square icon button that can show a selected state.
final class ToolButton: NSButton {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { updateLook() } }

    init(symbol: String, tip: String) {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(config)
        imagePosition = .imageOnly
        toolTip = tip
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.35 } }

    private func updateLook() {
        layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : nil
        contentTintColor = isSelected ? .controlAccentColor : .labelColor
    }

    @objc private func clicked() { onClick?() }
}

/// Round button filled with the current colour.
final class ColorSwatchButton: NSButton {
    var onClick: (() -> Void)?
    var color: NSColor { didSet { needsDisplay = true } }

    init(color: NSColor, size: CGFloat = 20) {
        self.color = color
        super.init(frame: .zero)
        isBordered = false
        title = ""
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size + 10).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let d = min(bounds.width, bounds.height) - 8
        let circle = NSBezierPath(ovalIn: CGRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d))
        color.setFill()
        circle.fill()
        NSColor.separatorColor.setStroke()
        circle.lineWidth = 1
        circle.stroke()
    }

    @objc private func clicked() { onClick?() }
}

/// A row of colour swatches shown in a popover.
/// Colour popover: standard colours, your recent custom colours, a screen
/// colour picker and the full system colour panel.
@MainActor
final class ColorPaletteViewController: NSViewController {
    private let colors: [NSColor]
    /// The colour, and whether the popover should close.
    private let onPick: (NSColor, Bool) -> Void
    private static let savedKey = "customColors"

    init(colors: [NSColor], onPick: @escaping (NSColor, Bool) -> Void) {
        self.colors = colors
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let standard = row(colors)
        let saved = Self.savedColors()
        let recent = row(saved)
        let picker = ToolButton(symbol: "eyedropper", tip: "Pick a colour from the screen")
        picker.onClick = { [weak self] in self?.pickFromScreen() }
        let more = ToolButton(symbol: "paintpalette", tip: "More colours…")
        more.onClick = { [weak self] in self?.openColorPanel() }
        let tools = NSStackView(views: [picker, more, NSView()])
        let stack = NSStackView(views: saved.isEmpty ? [standard, tools] : [standard, recent, tools])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view = stack
    }

    private func row(_ colors: [NSColor]) -> NSStackView {
        let stack = NSStackView(views: colors.map { color in
            let swatch = ColorSwatchButton(color: color, size: 22)
            swatch.onClick = { [weak self] in self?.onPick(color, true) }
            if Settings.shared.annotateColorNames { swatch.toolTip = Self.name(of: color) }
            return swatch
        })
        stack.spacing = 2
        return stack
    }

    /// A plain name for a colour, e.g. "Red" or "#3A7BFF" for custom ones.
    static func name(of color: NSColor) -> String {
        let named: [(NSColor, String)] = [(.systemRed, "Red"), (.systemOrange, "Orange"), (.systemYellow, "Yellow"),
                                          (.systemGreen, "Green"), (.systemBlue, "Blue"), (.systemPurple, "Purple"),
                                          (.black, "Black"), (.white, "White")]
        if let match = named.first(where: { $0.0 == color }) { return match.1 }
        guard let c = color.usingColorSpace(.sRGB) else { return "Custom" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    private func pickFromScreen() {
        view.window?.orderOut(nil)
        NSColorSampler().show { [weak self] color in
            guard let color else { return }
            MainActor.assumeIsolated {
                Self.remember(color)
                self?.onPick(color, true)
            }
        }
    }

    private func openColorPanel() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.isContinuous = true
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        Self.remember(sender.color)
        onPick(sender.color, false)
    }

    // MARK: Saved colours (up to 8, newest first)

    private static func savedColors() -> [NSColor] {
        (UserDefaults.standard.stringArray(forKey: savedKey) ?? []).compactMap(color(hex:))
    }

    private static func remember(_ color: NSColor) {
        guard let hex = hex(color) else { return }
        var list = UserDefaults.standard.stringArray(forKey: savedKey) ?? []
        list.removeAll { $0 == hex }
        list.insert(hex, at: 0)
        UserDefaults.standard.set(Array(list.prefix(8)), forKey: savedKey)
    }

    private static func hex(_ color: NSColor) -> String? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    private static func color(hex: String) -> NSColor? {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
