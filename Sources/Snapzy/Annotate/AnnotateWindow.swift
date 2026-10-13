import AppKit

/// The annotate editor: a toolbar across the top and the canvas below.
@MainActor
final class AnnotateWindowController: NSObject, NSWindowDelegate {
    private static var openControllers: [AnnotateWindowController] = []

    static func open(_ capture: Capture) {
        let controller = AnnotateWindowController(capture: capture)
        openControllers.append(controller)
        NSApp.activate(ignoringOtherApps: true)
        controller.window.makeKeyAndOrderFront(nil)
        controller.window.makeFirstResponder(controller.canvas)
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
    private var popover: NSPopover?

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
        window.minSize = CGSize(width: 900, height: 420)
        window.delegate = self
        window.commands = self
        buildContent()
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

        let actions = NSStackView(views: [backgroundButton, separator(), colorButton, widthButton, separator(), undoButton, redoButton, separator(), copy, save])
        actions.spacing = 4

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
        let palette = ColorPaletteViewController(colors: Self.colors) { [weak self] color in
            guard let self else { return }
            self.canvas.color = color
            self.colorButton.color = color
            self.canvas.applyStyleToSelection()
            self.popover?.close()
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = palette
        popover.show(relativeTo: colorButton.bounds, of: colorButton, preferredEdge: .maxY)
        self.popover = popover
    }

    private func showBackground() {
        let controller = BackgroundViewController(style: document.background) { [weak self] style in
            guard let self else { return }
            self.document.background = style
            self.backgroundButton.isSelected = style.enabled
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
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.openControllers.removeAll { $0 === self }
    }
}

/// Handles ⌘ shortcuts, since Snapzy has no main menu bar.
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
final class ColorPaletteViewController: NSViewController {
    private let colors: [NSColor]
    private let onPick: (NSColor) -> Void

    init(colors: [NSColor], onPick: @escaping (NSColor) -> Void) {
        self.colors = colors
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let stack = NSStackView(views: colors.map { color in
            let swatch = ColorSwatchButton(color: color, size: 22)
            swatch.onClick = { [weak self] in self?.onPick(color) }
            return swatch
        })
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view = stack
    }
}
