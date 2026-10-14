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

    @objc private func doneEditing() {
        canvas.commitText()
        guard let result = document.rendered() else { return }
        let callback = onDone
        onDone = nil
        window.close()
        let edited = result.from(document.capture.sourceBundleID)
        // Opened from Capture & Annotate: hand back. Otherwise run the usual after-capture actions.
        if let callback { callback(edited) } else { CaptureCoordinator.shared.deliver(edited) }
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
        window.minSize = CGSize(width: 1080, height: 460)
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
        let width = min(max(imageSize.width + 120, 1080), visible.width * 0.9)
        let height = min(max(imageSize.height + toolbarHeight + 40 + bottomBarHeight + 120, 540), visible.height * 0.85)
        return CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
    }

    // MARK: Layout

    private static let bottomBarHeight: CGFloat = 46
    private let lockButton = ToolButton(symbol: "lock.fill", tip: "Unlock canvas")
    private let zoomButton = NSPopUpButton(frame: .zero, pullsDown: true)

    private func buildContent() {
        let content = NSView()
        window.contentView = content

        let toolbar = ToolbarView()
        let bottomBar = ToolbarView(edge: .top)
        for view in [toolbar, propertiesBar, bottomBar, canvas] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        // Left: crop, add screenshot, background — each in its own rounded button.
        let crop = ToolButton(symbol: Tool.crop.symbol, tip: "Crop (C)")
        crop.onClick = { [weak self] in self?.selectTool(.crop) }
        toolButtons[.crop] = crop
        let addShot = ToolButton(symbol: "photo.badge.plus", tip: "Add screenshot")
        addShot.onClick = { [weak self] in self?.addScreenshot() }
        backgroundButton.toolTip = "Add background (B)"
        backgroundButton.onClick = { [weak self] in self?.showBackground() }
        let leftGroup = NSStackView(views: [crop, addShot, backgroundButton].map { Self.capsule([$0]) })
        leftGroup.spacing = 6

        // Middle: every drawing tool in one rounded strip.
        let drawing: [Tool] = [.select, .rectangle, .filledRectangle, .ellipse, .line, .arrow, .text,
                               .pixelate, .blur, .spotlight, .counter, .pencil, .highlighter, .watermark]
        let toolsCapsule = Self.capsule(drawing.map { tool in
            let button = ToolButton(symbol: tool.symbol, tip: "\(tool.title) (\(tool.key.uppercased()))")
            button.onClick = { [weak self] in self?.selectTool(tool) }
            toolButtons[tool] = button
            return button
        })

        // Style: colour ▾, line width and styles ▾, canvas lock, image menu.
        colorButton.toolTip = "Colour"
        colorButton.onClick = { [weak self] in self?.showColors() }
        widthButton.onClick = { [weak self] in self?.showStrokeMenu() }
        lockButton.onClick = { [weak self] in self?.toggleCanvasLock() }
        imageButton.onClick = { [weak self] in self?.showImageMenu() }
        let styleGroup = NSStackView(views: [Self.capsule([lockButton]), Self.capsule([imageButton])])
        styleGroup.spacing = 6
        updateLockIcon()

        // Right: Save as… and Done.
        let saveAs = NSButton(title: "Save as…", target: self, action: #selector(saveImageAs))
        saveAs.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(doneEditing))
        done.bezelStyle = .rounded
        done.bezelColor = .controlAccentColor
        done.keyEquivalent = "\r"
        // Undo / redo (⌘Z / ⇧⌘Z), next to Save as… like the reference.
        undoButton.onClick = { [weak self] in self?.undo() }
        redoButton.onClick = { [weak self] in self?.redo() }
        let history = Self.capsule([undoButton, redoButton])
        let finish = NSStackView(views: [history, saveAs, done])
        finish.spacing = 8
        finish.setCustomSpacing(12, after: history)

        for view in [leftGroup, toolsCapsule, styleGroup, finish] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            toolbar.addSubview(view)
        }

        // Bottom bar: zoom ▾, Drag Me, share / pin / copy.
        zoomButton.isBordered = false
        zoomButton.addItem(withTitle: "100%")
        for (title, value) in [("Fit to Window", nil), ("50%", 0.5), ("100%", 1.0), ("200%", 2.0)] as [(String, CGFloat?)] {
            zoomButton.menu?.addItem(ClosureMenuItem(title: title) { [weak self] in self?.canvas.zoom = value })
        }
        let zoomCapsule = Self.capsule([zoomButton])
        canvas.onZoomChange = { [weak self] in self?.updateZoomLabel() }

        let dragHandle = DragOutHandle { [weak self] in self?.renderedFile() }
        let share = ToolButton(symbol: "square.and.arrow.up", tip: "Share")
        share.onClick = { [weak self, weak share] in
            guard let self, let share, let file = self.renderedFile() else { return }
            NSSharingServicePicker(items: [file]).show(relativeTo: share.bounds, of: share, preferredEdge: .maxY)
        }
        let pin = ToolButton(symbol: "pin.fill", tip: "Pin to the screen")
        pin.onClick = { [weak self] in
            guard let self, let result = self.document.rendered() else { return }
            self.canvas.commitText()
            PinWindow.pin(result)
        }
        let copy = ToolButton(symbol: "doc.on.doc.fill", tip: "Copy (⌘C)")
        copy.onClick = { [weak self] in self?.copyImage() }
        let outputs = NSStackView(views: [share, pin, copy].map { Self.capsule([$0]) })
        outputs.spacing = 6
        for view in [zoomCapsule, dragHandle, outputs] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            bottomBar.addSubview(view)
        }

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Self.toolbarHeight),

            bottomBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: Self.bottomBarHeight),

            propertiesBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            propertiesBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            propertiesBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            propertiesBar.heightAnchor.constraint(equalToConstant: 40),

            canvas.topAnchor.constraint(equalTo: propertiesBar.bottomAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            leftGroup.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            leftGroup.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 92), // room for traffic lights
            toolsCapsule.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            toolsCapsule.leadingAnchor.constraint(equalTo: leftGroup.trailingAnchor, constant: 12),
            styleGroup.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            styleGroup.leadingAnchor.constraint(equalTo: toolsCapsule.trailingAnchor, constant: 12),
            finish.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            finish.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -14),
            finish.leadingAnchor.constraint(greaterThanOrEqualTo: styleGroup.trailingAnchor, constant: 12),

            zoomCapsule.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            zoomCapsule.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 12),
            dragHandle.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            dragHandle.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
            outputs.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            outputs.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -12)
        ])

        canvas.onChange = { [weak self] in
            self?.refreshUndo()
            self?.updateZoomLabel()
        }
        canvas.onToolShortcut = { [weak self] tool in self?.selectTool(tool) }
        canvas.onSelectionChange = { [weak self] in self?.refreshProperties() }
        DispatchQueue.main.async { [weak self] in self?.updateZoomLabel() }
    }

    /// A rounded, lightly filled holder for one or more toolbar buttons.
    private static func capsule(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        stack.layer?.cornerRadius = 9
        stack.layer?.cornerCurve = .continuous
        return stack
    }

    private static func chevron() -> NSView {
        let image = NSImageView(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: 8, weight: .bold)
        image.contentTintColor = .secondaryLabelColor
        return image
    }

    private func updateZoomLabel() {
        zoomButton.item(at: 0)?.title = "\(Int((canvas.currentScale * 100).rounded()))%"
    }

    private func toggleCanvasLock() {
        document.canvasLocked.toggle()
        updateLockIcon()
        if !document.canvasLocked {
            document.expandToFitAnnotations()
            canvas.refresh()
        }
    }

    private func updateLockIcon() {
        let locked = document.canvasLocked
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        lockButton.image = NSImage(systemSymbolName: locked ? "lock.fill" : "lock.open.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        lockButton.toolTip = locked ? "Unlock canvas: let drawings extend past the edges" : "Lock canvas to the picture's size"
        lockButton.isSelected = !locked
    }

    /// Add screenshot: select an area of the screen and place it next to the current picture.
    private func addScreenshot() {
        window.orderOut(nil)
        CaptureCoordinator.shared.selectRegion(hint: "Drag an area to add to the picture.") { [weak self] shot, rect in
            guard let self else { return }
            self.window.makeKeyAndOrderFront(nil)
            guard let image = ScreenCapturer.crop(shot, to: rect) else { return }
            self.canvas.commitText()
            self.document.addPicture(image, pointSize: rect.size)
            self.selectTool(.select)
            self.canvas.refresh()
            self.refreshUndo()
        } onCancel: { [weak self] in
            self?.window.makeKeyAndOrderFront(nil)
        }
    }

    /// Line width plus arrow, text and crop styles, in one menu.
    private func showStrokeMenu() {
        let menu = NSMenu()
        func header(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        header("Line Width")
        for (title, width) in zip(["Thin", "Medium", "Thick"], Self.widths) {
            let item = ClosureMenuItem(title: title) { [weak self] in
                self?.canvas.lineWidth = width
                self?.updateWidthIcon()
                self?.canvas.applyStyleToSelection()
            }
            item.state = canvas.lineWidth == width ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        appendStyleItems(to: menu)
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: widthButton.bounds.maxY + 4), in: widthButton)
    }

    /// The rendered picture as a temporary file, for dragging and sharing.
    private func renderedFile() -> URL? {
        canvas.commitText()
        return try? document.rendered()?.temporaryFile()
    }

    @objc func saveImageAs() {
        canvas.commitText()
        guard let result = document.rendered() else { return }
        do {
            try result.save(ask: true)
            Toast.show("Saved")
        } catch let error as CocoaError where error.code == .userCancelled {
        } catch {
            NSAlert(error: error).runModal()
        }
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
        refreshProperties()
    }

    // MARK: Properties bar

    private let propertiesBar = PropertiesBarView()
    private var propertyTargets: [Callback] = []

    /// Rebuilds the properties bar for the selected shape, or else the current tool.
    private func refreshProperties() {
        propertyTargets.removeAll()
        let selected = canvas.selectedAnnotation
        let tool = selected?.tool ?? canvas.tool
        // Editing a shape starts from its own settings, so changing one setting leaves the others alone.
        if let selected { canvas.loadDefaults(from: selected) }
        var items: [NSView] = []

        let icon = NSImageView(image: NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        items.append(Self.badge(icon))

        let drawsLines: Set<Tool> = [.rectangle, .ellipse, .line, .arrow, .pencil, .highlighter]
        let hasColor: Set<Tool> = drawsLines.union([.filledRectangle, .text, .counter])

        if tool == .watermark {
            colorButton.color = selected?.color ?? canvas.color
            let field = NSTextField(string: canvas.watermarkText)
            field.placeholderString = "Watermark text"
            field.controlSize = .small
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 150).isActive = true
            bindSender(field) { [weak self] sender in
                self?.canvas.watermarkText = (sender as? NSTextField)?.stringValue ?? ""
                self?.applyToSelection()
            }
            let style = segmented(["textformat", "line.diagonal", "square.grid.3x3"].map(Self.symbol),
                                  selected: canvas.watermarkStyle.rawValue, tips: WatermarkStyle.allCases.map(\.title)) { [weak self] i in
                self?.canvas.watermarkStyle = WatermarkStyle(rawValue: i) ?? .single
                self?.applyToSelection()
            }
            items.append(group("Text", [field]))
            items.append(group("Style", [style]))
            items.append(group("Color", [colorButton]))
            items.append(group("Size", [valueSlider(canvas.watermarkSize, 12...160, format: { "\(Int($0))" }) { [weak self] in
                self?.canvas.watermarkSize = $0 }]))
            items.append(group("Opacity", [valueSlider(canvas.watermarkOpacity, 0.05...1, format: { "\(Int(($0 * 100).rounded()))%" }) { [weak self] in
                self?.canvas.watermarkOpacity = $0 }]))
            items.append(group("Rotation", [valueSlider(canvas.watermarkRotation, -90...90, format: { "\(Int($0))°" }) { [weak self] in
                self?.canvas.watermarkRotation = $0 }]))
            propertiesBar.show(items)
            return
        }
        if hasColor.contains(tool) {
            colorButton.color = selected?.color ?? canvas.color
            items.append(group("Color", [colorButton]))
        }
        if drawsLines.contains(tool) || [.text, .counter, .filledRectangle].contains(tool) {
            let title = tool == .text ? "Size" : (tool == .counter ? "Size" : "Stroke")
            items.append(group(title, [strokeSlider(value: selected?.lineWidth ?? canvas.lineWidth)]))
        }
        // Line style and end heads only apply to classic arrows: hide them otherwise.
        let classicArrow = tool != .arrow || (selected?.arrowLook ?? canvas.arrowType) == .classic
        if [.rectangle, .ellipse, .line, .arrow].contains(tool), classicArrow {
            let dash = selected.map(\.lineDash) ?? canvas.lineDash
            let control = segmented(LineDash.allCases.map { Self.dashImage($0) }, selected: dash.rawValue,
                                    tips: LineDash.allCases.map(\.title)) { [weak self] i in
                self?.canvas.lineDash = LineDash(rawValue: i) ?? .solid
                self?.applyToSelection()
            }
            items.append(group("Line Style", [control]))
        }
        if tool == .arrow {
            let style = selected?.arrowStyle ?? canvas.arrowStyle
            items.append(group("Style", [segmented(["arrow.up.right", "arrow.turn.up.right"].map(Self.symbol), selected: style.rawValue,
                                                   tips: ArrowStyle.allCases.map(\.title)) { [weak self] i in
                self?.canvas.arrowStyle = ArrowStyle(rawValue: i) ?? .straight
                self?.applyToSelection()
            }]))
            let look = selected?.arrowLook ?? canvas.arrowType
            // Same order as the reference: classic, tapered, outlined.
            let order: [ArrowType] = [.classic, .tapered, .outlined]
            items.append(group("Display", [segmented(order.map(Self.arrowLookImage), selected: order.firstIndex(of: look) ?? 1,
                                                     tips: order.map(\.title)) { [weak self] i in
                self?.canvas.arrowType = order[i]
                self?.applyToSelection()
                DispatchQueue.main.async { self?.refreshProperties() }
            }]))
            let classic = look == .classic
            let start = segmented(Self.headImages(pointingRight: false), selected: (selected?.startEnd ?? canvas.startHead).rawValue,
                                  tips: ArrowHead.allCases.map(\.title)) { [weak self] i in
                self?.canvas.startHead = ArrowHead(rawValue: i) ?? .none
                self?.applyToSelection()
            }
            let end = segmented(Self.headImages(pointingRight: true), selected: (selected?.endEnd ?? canvas.endHead).rawValue,
                                tips: ArrowHead.allCases.map(\.title)) { [weak self] i in
                self?.canvas.endHead = ArrowHead(rawValue: i) ?? .arrow
                self?.applyToSelection()
            }
            if classic {
                items.append(group("Start", [start]))
                items.append(group("End", [end]))
            }
        }
        if tool == .text {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.isBordered = false
            popup.addItems(withTitles: TextStyle.allCases.map(\.title))
            popup.selectItem(at: (selected?.textStyle ?? canvas.textStyle).rawValue)
            bind(popup) { [weak self, weak popup] in
                self?.canvas.textStyle = TextStyle(rawValue: popup?.indexOfSelectedItem ?? 0) ?? .outline
                self?.applyToSelection()
            }
            items.append(group("Style", [popup]))
        }
        if tool == .crop {
            let ratios: [(String, CGFloat?)] = [("Free", nil), ("1:1", 1), ("4:3", 4.0 / 3), ("3:2", 1.5), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16)]
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.isBordered = false
            popup.addItems(withTitles: ratios.map(\.0))
            popup.selectItem(at: ratios.firstIndex { $0.1 == canvas.cropAspect } ?? 0)
            bind(popup) { [weak self, weak popup] in self?.canvas.cropAspect = ratios[popup?.indexOfSelectedItem ?? 0].1 }
            items.append(group("Aspect Ratio", [popup]))
            let snap = NSSwitch()
            snap.controlSize = .mini
            snap.state = Settings.shared.annotateSnapToEdges ? .on : .off
            bind(snap) { [weak snap] in Settings.shared.annotateSnapToEdges = snap?.state == .on }
            items.append(group("Snap to Edges", [snap]))
        }
        if tool == .highlighter {
            let snap = NSSwitch()
            snap.controlSize = .mini
            snap.state = Settings.shared.annotateSnapHighlight ? .on : .off
            bind(snap) { [weak snap] in Settings.shared.annotateSnapHighlight = snap?.state == .on }
            items.append(group("Snap to Text", [snap]))
        }
        if [.select, .pixelate, .blur, .spotlight].contains(tool), selected == nil {
            let hint = NSTextField(labelWithString: tool == .select ? "Click a shape to edit it. Drag to move it." : "Drag over the area to cover.")
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            items.append(hint)
        }
        propertiesBar.show(items)
    }

    private func applyToSelection() {
        guard canvas.selectedAnnotation != nil else { return }
        canvas.applyStyleToSelection()
    }

    /// A small slider with its value beside it; changes apply to the selected shape.
    private func valueSlider(_ value: CGFloat, _ range: ClosedRange<CGFloat>, format: @escaping (CGFloat) -> String,
                             set: @escaping (CGFloat) -> Void) -> NSView {
        let slider = NSSlider(value: Double(value), minValue: Double(range.lowerBound), maxValue: Double(range.upperBound),
                              target: nil, action: nil)
        slider.controlSize = .small
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let label = NSTextField(labelWithString: format(value))
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        bindSender(slider) { [weak self] sender in
            let v = CGFloat((sender as? NSSlider)?.doubleValue ?? Double(value))
            label.stringValue = format(v)
            set(v)
            self?.applyToSelection()
        }
        let stack = NSStackView(views: [slider, label])
        stack.spacing = 6
        return stack
    }

    private func strokeSlider(value: CGFloat) -> NSView {
        let slider = NSSlider(value: Double(value), minValue: 1, maxValue: 20, target: nil, action: nil)
        slider.controlSize = .small
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let label = NSTextField(labelWithString: "\(Int(value))")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        bind(slider) { [weak self, weak slider] in
            guard let self, let slider else { return }
            let v = CGFloat(slider.doubleValue.rounded())
            label.stringValue = "\(Int(v))"
            self.canvas.lineWidth = v
            // Live while dragging; one undo step per change is fine for a toolbar slider.
            if self.canvas.selectedAnnotation != nil { self.canvas.applyStyleToSelection() }
        }
        let stack = NSStackView(views: [slider, label])
        stack.spacing = 6
        return stack
    }

    private func segmented(_ images: [NSImage], selected: Int, tips: [String], change: @escaping (Int) -> Void) -> NSSegmentedControl {
        let control = NSSegmentedControl(images: images, trackingMode: .selectOne, target: nil, action: nil)
        control.controlSize = .small
        control.segmentStyle = .automatic
        control.selectedSegment = selected
        for (i, tip) in tips.enumerated() where i < control.segmentCount { control.setToolTip(tip, forSegment: i) }
        // Read the choice from the control that sent the click (never default to the first option).
        bindSender(control) { sender in
            guard let segment = (sender as? NSSegmentedControl)?.selectedSegment, segment >= 0 else { return }
            change(segment)
        }
        return control
    }

    private func group(_ title: String, _ views: [NSView]) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label] + views)
        stack.spacing = 6
        return stack
    }

    private func bind(_ control: NSControl, _ action: @escaping () -> Void) {
        bindSender(control) { _ in action() }
    }

    private func bindSender(_ control: NSControl, _ action: @escaping (Any?) -> Void) {
        let target = Callback { sender in
            // Rebuild the bar after the click has finished, not while the clicked control is still handling it.
            action(sender)
        }
        propertyTargets.append(target)
        control.target = target
        control.action = #selector(Callback.fire(_:))
    }

    private static func badge(_ view: NSView) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        box.layer?.cornerRadius = 12
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 24), box.heightAnchor.constraint(equalToConstant: 24),
            view.centerXAnchor.constraint(equalTo: box.centerXAnchor), view.centerYAnchor.constraint(equalTo: box.centerYAnchor)
        ])
        return box
    }

    private static func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) ?? NSImage()
    }

    /// Classic: an even line with a head. Tapered: a solid wedge from thin to thick. Outlined: the same, hollow.
    private static func arrowLookImage(_ look: ArrowType) -> NSImage {
        let image = NSImage(size: CGSize(width: 22, height: 12), flipped: false) { rect in
            NSColor.black.set()
            let y = rect.midY
            switch look {
            case .classic:
                let line = NSBezierPath()
                line.move(to: CGPoint(x: 1, y: y)); line.line(to: CGPoint(x: 15, y: y))
                line.lineWidth = 1.6
                line.stroke()
                let head = NSBezierPath()
                head.move(to: CGPoint(x: 21, y: y)); head.line(to: CGPoint(x: 14, y: y + 4)); head.line(to: CGPoint(x: 14, y: y - 4))
                head.close(); head.fill()
            case .tapered, .outlined:
                let shape = NSBezierPath()
                shape.move(to: CGPoint(x: 1, y: y + 0.4))
                shape.line(to: CGPoint(x: 14, y: y + 1.8)); shape.line(to: CGPoint(x: 14, y: y + 5))
                shape.line(to: CGPoint(x: 21, y: y))
                shape.line(to: CGPoint(x: 14, y: y - 5)); shape.line(to: CGPoint(x: 14, y: y - 1.8))
                shape.line(to: CGPoint(x: 1, y: y - 0.4))
                shape.close()
                if look == .tapered { shape.fill() } else { shape.lineWidth = 1.1; shape.lineJoinStyle = .round; shape.stroke() }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Little pictures of solid / dashed / dotted lines.
    private static func dashImage(_ dash: LineDash) -> NSImage {
        let image = NSImage(size: CGSize(width: 22, height: 12), flipped: false) { rect in
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 1, y: rect.midY)); path.line(to: CGPoint(x: rect.maxX - 1, y: rect.midY))
            path.lineWidth = 2
            switch dash {
            case .solid: break
            case .dashed: path.setLineDash([5, 3], count: 2, phase: 0)
            case .dotted: path.lineCapStyle = .round; path.setLineDash([0, 4], count: 2, phase: 0)
            }
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// None / arrowhead / dot pictures for one end of an arrow.
    private static func headImages(pointingRight: Bool) -> [NSImage] {
        ArrowHead.allCases.map { head in
            let image = NSImage(size: CGSize(width: 16, height: 12), flipped: false) { rect in
                NSColor.black.set()
                switch head {
                case .none:
                    let line = NSBezierPath()
                    line.move(to: CGPoint(x: 2, y: rect.midY)); line.line(to: CGPoint(x: rect.maxX - 2, y: rect.midY))
                    line.lineWidth = 1.5
                    line.stroke()
                case .dot:
                    NSBezierPath(ovalIn: CGRect(x: rect.midX - 4, y: rect.midY - 4, width: 8, height: 8)).fill()
                case .arrow:
                    let tri = NSBezierPath()
                    if pointingRight {
                        tri.move(to: CGPoint(x: 3, y: 1)); tri.line(to: CGPoint(x: rect.maxX - 2, y: rect.midY)); tri.line(to: CGPoint(x: 3, y: rect.maxY - 1))
                    } else {
                        tri.move(to: CGPoint(x: rect.maxX - 3, y: 1)); tri.line(to: CGPoint(x: 2, y: rect.midY)); tri.line(to: CGPoint(x: rect.maxX - 3, y: rect.maxY - 1))
                    }
                    tri.close()
                    tri.fill()
                }
                return true
            }
            image.isTemplate = true
            return image
        }
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
    private func appendStyleItems(to menu: NSMenu) {
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
        // Undo and redo are ⌘Z / ⇧⌘Z (no toolbar buttons, like the reference layout).
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
        case ("s", true): commands?.saveImageAs(); return true
        case ("w", false): close(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

/// Toolbar background; dragging it moves the window.
private final class ToolbarView: NSVisualEffectView {
    enum Edge { case top, bottom }

    /// `edge`: where the dividing line goes (bottom for the top bar, top for the bottom bar).
    init(edge: Edge = .bottom) {
        super.init(frame: .zero)
        material = .titlebar
        blendingMode = .withinWindow
        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            edge == .bottom ? border.bottomAnchor.constraint(equalTo: bottomAnchor) : border.topAnchor.constraint(equalTo: topAnchor)
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

/// "Drag Me": drag the finished picture straight into another app.
final class DragOutHandle: NSView, NSDraggingSource {
    private let file: () -> URL?

    init(file: @escaping () -> URL?) {
        self.file = file
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        func grip() -> NSImageView {
            let view = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil) ?? NSImage())
            view.symbolConfiguration = .init(pointSize: 10, weight: .regular)
            view.contentTintColor = .tertiaryLabelColor
            return view
        }
        let label = NSTextField(labelWithString: "Drag Me")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [grip(), label, grip()])
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 116), heightAnchor.constraint(equalToConstant: 30)
        ])
        toolTip = "Drag the picture into another app"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDragged(with event: NSEvent) {
        guard let url = file(), let image = NSImage(contentsOf: url) else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let size = image.size.applying(.init(scaleX: 140 / max(image.size.width, 1), y: 140 / max(image.size.width, 1)))
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                              contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}

/// The row under the toolbar holding the current tool's or shape's settings.
final class PropertiesBarView: NSVisualEffectView {
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        material = .titlebar
        blendingMode = .withinWindow
        stack.spacing = 18
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ items: [NSView]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, item) in items.enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                line.heightAnchor.constraint(equalToConstant: 18).isActive = true
                line.widthAnchor.constraint(equalToConstant: 1).isActive = true
                stack.addArrangedSubview(line)
            }
            stack.addArrangedSubview(item)
        }
    }
}
