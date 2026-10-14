import AppKit
import AVFoundation

/// The recording panel's settings popover: grouped sections of switches and pop-ups
/// (General, Cursor, Keystrokes, Video, Audio, Camera, GIF). Every change is reported
/// straight away through `onChange`.
@MainActor
final class RecordingSettingsViewController: NSViewController {
    private var options: RecordingOptions
    private let onChange: (RecordingOptions) -> Void
    private var targets: [AnyObject] = []
    private let width: CGFloat
    /// Inside the Settings window: no own scrolling or background (the window provides them).
    private let embedded: Bool
    private static let frameRates = [10, 15, 24, 25, 30, 48, 50, 60]
    private static let gifFrameRates = [5, 10, 15, 20, 25, 30, 40, 50, 60]
    private static let gifWidths = [1200, 960, 800, 640, 500, 480, 320, 256, 200]

    init(options: RecordingOptions, width: CGFloat = 360, embedded: Bool = false,
         onChange: @escaping (RecordingOptions) -> Void) {
        self.options = options
        self.width = width
        self.embedded = embedded
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let s = Settings.shared
        let stack = NSStackView(views: [
            section("General", [
                row("Show controls while recording", control: toggle({ s.showControlsWhileRecording },
                                                                     { s.showControlsWhileRecording = $0 })),
                row("Remember last selection", control: optionToggle(\.rememberSelection)),
                row("Display recording time in menu bar", control: toggle({ s.showRecordingTimeInMenuBar },
                                                                          { s.showRecordingTimeInMenuBar = $0 })),
                row("Dim screen while recording", control: optionToggle(\.dimScreen)),
                row("Show countdown", control: optionToggle(\.countdown)),
                row("Hide desktop icons while recording", control: optionToggle(\.hideDesktopIcons))
            ]),
            section("Cursor", [
                row("Show cursor", control: optionToggle(\.showCursor)),
                row("Highlight clicks", control: withOptionsPanel({ [unowned self] in self.showClickOptions(from: $0) },
                                                                  optionToggle(\.highlightClicks)))
            ]),
            section("Keystrokes", [
                row("Show keystrokes", control: withOptionsPanel({ [unowned self] in self.showKeystrokeOptions(from: $0) },
                                                                 optionToggle(\.showKeystrokes)),
                    note: "Needs Accessibility permission to see keys typed in other apps.")
            ]),
            section("Video", [
                row("Frame rate", control: popup(Self.frameRates.map { "\($0) fps" }, values: Self.frameRates, \.fps)),
                row("Max resolution", control: popup(RecordingOptions.maxHeights.map(\.title),
                                                     values: Array(RecordingOptions.maxHeights.indices), \.maxResolution),
                    note: "Set a maximum resolution to reduce file size and upload time."),
                row("Scale Retina videos to 1x", control: optionToggle(\.scaleTo1x))
            ]),
            section("Audio", [
                row("Record audio in mono", control: optionToggle(\.audioMono)),
                row("Record system audio", control: optionToggle(\.systemAudio),
                    note: "Records sound coming from other apps."),
                row("Microphone", control: devicePopup(Devices.microphones(), \.microphoneDeviceID))
            ]),
            section("GIF", [
                row("Frame rate", control: popup(Self.gifFrameRates.map { "\($0) fps" }, values: Self.gifFrameRates, \.gifFPS)),
                row("Resolution", control: popup(["Original", "-"] + Self.gifWidths.map { $0 == 800 ? "800 x auto (default)" : "\($0) x auto" },
                                                 values: [0, 0] + Self.gifWidths, \.gifMaxWidth)),
                row("Optimize GIFs", control: optionToggle(\.gifOptimize),
                    note: "Merges frames that don't change, for smaller files."),
                row("Quality", control: qualitySlider())
            ])
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        if embedded {
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.widthAnchor.constraint(equalToConstant: width - 40).isActive = true // the sections' width
            view = stack
            return
        }
        // Scroll if it's taller than the screen allows.
        let document = FlippedView()
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: width)
        ])
        let size = stack.fittingSize
        document.frame = CGRect(origin: .zero, size: size)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: size.width,
                                                height: min(size.height, ((NSScreen.main?.visibleFrame.height ?? 900) - 120) * 2 / 3)))
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Self.panelColor
        scroll.autohidesScrollers = true
        view = scroll
        preferredContentSize = scroll.frame.size
    }

    // MARK: Building blocks

    private func section(_ title: String, _ rows: [NSView]) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let group = Self.groupBox(rows)
        let column = NSStackView(views: [label, group])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        group.translatesAutoresizingMaskIntoConstraints = false
        group.widthAnchor.constraint(equalToConstant: width - 40).isActive = true
        return column
    }

    /// Title (and optional grey note) on the left, control on the right.
    private func row(_ title: String, control: NSView, note: String? = nil) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        let top = NSStackView(views: [label, NSView(), control])
        top.alignment = .centerY
        var views: [NSView] = [top]
        if let note {
            let text = NSTextField(wrappingLabelWithString: note)
            text.font = .systemFont(ofSize: 11)
            text.textColor = .secondaryLabelColor
            text.preferredMaxLayoutWidth = width - 60
            views.append(text)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        top.translatesAutoresizingMaskIntoConstraints = false
        top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        top.heightAnchor.constraint(greaterThanOrEqualToConstant: 22).isActive = true
        let minimum = stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 40)
        minimum.priority = .required
        minimum.isActive = true
        stack.setHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        return stack
    }

    /// Solid dark background for a popover's content (the default material is see-through).
    static let panelColor = NSColor(white: 0.14, alpha: 1)

    /// Rows inside a lighter rounded box, separated by hairlines.
    static func groupBox(_ rows: [NSView]) -> NSView {
        var items: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 { items.append(hairline()) }
            items.append(row)
        }
        let stack = NSStackView(views: items)
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        box.layer?.cornerRadius = 10
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14)
        ])
        for item in items {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return box
    }

    /// Pop-up menu drawn as plain text with up/down arrows, like the reference.
    static func plainPopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.isBordered = false
        popup.controlSize = .regular
        return popup
    }

    /// A 1-point divider between rows (NSBox separators added uneven extra height).
    static func hairline() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func toggle(_ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = .small
        control.state = get() ? .on : .off
        let target = Callback { sender in set((sender as? NSSwitch)?.state == .on) }
        targets.append(target)
        control.target = target
        control.action = #selector(Callback.fire(_:))
        return control
    }

    /// Low … High slider for GIF colours.
    private func qualitySlider() -> NSView {
        let slider = NSSlider(value: options.gifQuality, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.controlSize = .small
        slider.numberOfTickMarks = 9
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let target = Callback { [unowned self] sender in
            self.options.gifQuality = (sender as? NSSlider)?.doubleValue ?? 0.75
            self.onChange(self.options)
        }
        targets.append(target)
        slider.target = target
        slider.action = #selector(Callback.fire(_:))
        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            return field
        }
        let stack = NSStackView(views: [label("Low"), slider, label("High")])
        stack.spacing = 6
        return stack
    }

    private func optionToggle(_ path: WritableKeyPath<RecordingOptions, Bool>) -> NSSwitch {
        toggle({ [unowned self] in self.options[keyPath: path] }) { [unowned self] on in
            self.options[keyPath: path] = on
            self.onChange(self.options)
        }
    }

    private func popup<T: Equatable>(_ titles: [String], values: [T], _ path: WritableKeyPath<RecordingOptions, T>) -> NSPopUpButton {
        // A "-" title becomes a divider; items carry their value's index as a tag.
        let control = Self.plainPopup()
        control.removeAllItems()
        for (index, title) in titles.enumerated() {
            if title == "-" {
                control.menu?.addItem(.separator())
            } else {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.tag = index
                control.menu?.addItem(item)
            }
        }
        let current = values.firstIndex(of: options[keyPath: path]) ?? 0
        control.selectItem(withTag: current)
        let target = Callback { [unowned self] sender in
            guard let index = (sender as? NSPopUpButton)?.selectedItem?.tag, values.indices.contains(index) else { return }
            self.options[keyPath: path] = values[index]
            self.onChange(self.options)
        }
        targets.append(target)
        control.target = target
        control.action = #selector(Callback.fire(_:))
        return control
    }

    private func devicePopup(_ devices: [AVCaptureDevice], _ path: WritableKeyPath<RecordingOptions, String?>) -> NSPopUpButton {
        let ids: [String?] = [nil] + devices.map(\.uniqueID)
        return popup(["System Default"] + devices.map(\.localizedName), values: ids, path)
    }

    /// An "Options…" button that runs `open`, next to a switch.
    private func withOptionsPanel(_ open: @escaping (NSView) -> Void, _ control: NSView) -> NSView {
        let button = NSButton(title: "Options…", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        let target = Callback { sender in if let view = sender as? NSView { open(view) } }
        targets.append(target)
        button.target = target
        button.action = #selector(Callback.fire(_:))
        let stack = NSStackView(views: [button, control])
        stack.spacing = 10
        return stack
    }

    private var clickPopover: NSPopover?

    private func showClickOptions(from button: NSView) {
        let controller = ClickOptionsViewController(options: options) { [weak self] new in
            guard let self else { return }
            self.options = new
            self.onChange(new)
        }
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = controller
        controller.onDone = { [weak popover] in popover?.close() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxX)
        clickPopover = popover
    }

    private var keystrokePopover: NSPopover?

    private func showKeystrokeOptions(from button: NSView) {
        let controller = KeystrokeOptionsViewController(options: options) { [weak self] new in
            guard let self else { return }
            self.options = new
            self.onChange(new)
        }
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = controller
        controller.onDone = { [weak popover] in popover?.close() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxX)
        keystrokePopover = popover
    }
}

/// Top-left origin, so a scroll view starts at the top of the content.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Highlight-click options: size, colour, style, animation, a live preview and Done.
@MainActor
final class ClickOptionsViewController: NSViewController {
    var onDone: (() -> Void)?
    private var options: RecordingOptions
    private let onChange: (RecordingOptions) -> Void
    private var targets: [AnyObject] = []
    private static let width: CGFloat = 380

    init(options: RecordingOptions, onChange: @escaping (RecordingOptions) -> Void) {
        self.options = options
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let size = NSSlider(value: options.clickScale, minValue: 0, maxValue: 1, target: nil, action: nil)
        size.numberOfTickMarks = 3
        size.translatesAutoresizingMaskIntoConstraints = false
        size.widthAnchor.constraint(equalToConstant: 190).isActive = true
        bind(size) { [unowned self] in self.options.clickScale = ($0 as? NSSlider)?.doubleValue ?? 0.5 }

        let color = RecordingSettingsViewController.plainPopup()
        color.addItems(withTitles: RecordingOptions.clickColors.map(\.name))
        color.selectItem(at: options.clickColor)
        bind(color) { [unowned self] in self.options.clickColor = ($0 as? NSPopUpButton)?.indexOfSelectedItem ?? 0 }

        let style = RecordingSettingsViewController.plainPopup()
        style.addItems(withTitles: ["Outline", "Filled"])
        style.selectItem(at: options.clickFilled ? 1 : 0)
        bind(style) { [unowned self] in self.options.clickFilled = ($0 as? NSPopUpButton)?.indexOfSelectedItem == 1 }

        let animate = NSSwitch()
        animate.state = options.clickAnimate ? .on : .off
        bind(animate) { [unowned self] in self.options.clickAnimate = ($0 as? NSSwitch)?.state == .on }

        let rows: [NSView] = [("Size", size as NSView), ("Color", color), ("Style", style),
                              ("Animate clicks", animate)].map { title, control in
            let label = NSTextField(labelWithString: title)
            let row = NSStackView(views: [label, NSView(), control])
            row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 40).isActive = true
            return row
        }
        let group = RecordingSettingsViewController.groupBox(rows)

        let preview = ClickPreviewView { [unowned self] in self.options }
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), done])

        let divider = RecordingSettingsViewController.hairline()
        let stack = NSStackView(views: [group, preview, divider, footer])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        for v in [group, preview, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: Self.width - 40).isActive = true
        }
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        stack.wantsLayer = true
        stack.layer?.backgroundColor = RecordingSettingsViewController.panelColor.cgColor
        view = stack
        preferredContentSize = stack.fittingSize
    }

    private func bind(_ control: NSControl, _ change: @escaping (Any?) -> Void) {
        let target = Callback { [unowned self] sender in
            change(sender)
            self.onChange(self.options)
        }
        targets.append(target)
        control.target = target
        control.action = #selector(Callback.fire(_:))
    }

    @objc private func done() { onDone?() }
}

/// "Click here to preview": shows the click ring with the current options.
@MainActor
private final class ClickPreviewView: NSView {
    private let options: () -> RecordingOptions

    init(options: @escaping () -> RecordingOptions) {
        self.options = options
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        let label = NSTextField(labelWithString: "Click here to preview")
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {
        guard let layer else { return }
        ClickRipple.add(to: layer, at: convert(event.locationInWindow, from: nil), options: options())
    }
}

/// Keystroke display options: size, appearance, position, which keys, blur, Preview and Done.
@MainActor
final class KeystrokeOptionsViewController: NSViewController {
    var onDone: (() -> Void)?
    private var options: RecordingOptions
    private let onChange: (RecordingOptions) -> Void
    private var targets: [AnyObject] = []
    private var previewWindow: KeystrokeWindow?
    private static let width: CGFloat = 400

    init(options: RecordingOptions, onChange: @escaping (RecordingOptions) -> Void) {
        self.options = options
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let size = NSSlider(value: options.keystrokeScale, minValue: 0, maxValue: 1, target: nil, action: nil)
        size.numberOfTickMarks = 7
        size.translatesAutoresizingMaskIntoConstraints = false
        size.widthAnchor.constraint(equalToConstant: 190).isActive = true
        bind(size) { [unowned self] in self.options.keystrokeScale = ($0 as? NSSlider)?.doubleValue ?? 0.5 }

        let appearance = RecordingSettingsViewController.plainPopup()
        appearance.addItems(withTitles: ["Dark", "Light"])
        appearance.selectItem(at: options.keystrokesLight ? 1 : 0)
        bind(appearance) { [unowned self] in self.options.keystrokesLight = ($0 as? NSPopUpButton)?.indexOfSelectedItem == 1 }

        let position = RecordingSettingsViewController.plainPopup()
        position.addItems(withTitles: RecordingOptions.keystrokePositions)
        position.selectItem(at: options.keystrokePosition)
        bind(position) { [unowned self] in self.options.keystrokePosition = ($0 as? NSPopUpButton)?.indexOfSelectedItem ?? 4 }

        let keys = RecordingSettingsViewController.plainPopup()
        keys.addItems(withTitles: ["Show all keys", "Show only command keys"])
        keys.selectItem(at: options.keystrokesCommandOnly ? 1 : 0)
        bind(keys) { [unowned self] in self.options.keystrokesCommandOnly = ($0 as? NSPopUpButton)?.indexOfSelectedItem == 1 }

        let blur = NSSwitch()
        blur.state = options.keystrokesBlur ? .on : .off
        bind(blur) { [unowned self] in self.options.keystrokesBlur = ($0 as? NSSwitch)?.state == .on }

        let rows: [NSView] = [("Size", size as NSView), ("Appearance", appearance), ("Position", position),
                              ("Keys", keys), ("Blur background", blur)].map { title, control in
            let row = NSStackView(views: [NSTextField(labelWithString: title), NSView(), control])
            row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 40).isActive = true
            return row
        }
        let group = RecordingSettingsViewController.groupBox(rows)

        let preview = NSButton(title: "Preview", target: self, action: #selector(showPreview))
        preview.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [preview, NSView(), done])

        let divider = RecordingSettingsViewController.hairline()
        let stack = NSStackView(views: [group, divider, footer])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        for v in [group, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: Self.width - 40).isActive = true
        }
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        stack.wantsLayer = true
        stack.layer?.backgroundColor = RecordingSettingsViewController.panelColor.cgColor
        view = stack
        preferredContentSize = stack.fittingSize
    }

    private func bind(_ control: NSControl, _ change: @escaping (Any?) -> Void) {
        let target = Callback { [unowned self] sender in
            change(sender)
            self.onChange(self.options)
        }
        targets.append(target)
        control.target = target
        control.action = #selector(Callback.fire(_:))
    }

    /// Shows a sample key press on screen with the current settings.
    @objc private func showPreview() {
        previewWindow?.orderOut(nil)
        guard let screen = NSScreen.main else { return }
        let window = KeystrokeWindow(rect: screen.visibleFrame, options: options)
        window.orderFrontRegardless()
        window.showSample("⌘⇧4")
        previewWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak window] in
            window?.orderOut(nil)
            if self?.previewWindow === window { self?.previewWindow = nil }
        }
    }

    @objc private func done() {
        previewWindow?.orderOut(nil)
        onDone?()
    }
}
