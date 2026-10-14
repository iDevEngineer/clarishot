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
    private static let width: CGFloat = 360

    init(options: RecordingOptions, onChange: @escaping (RecordingOptions) -> Void) {
        self.options = options
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
                row("Highlight clicks", control: withOptions(clickMenu, optionToggle(\.highlightClicks)))
            ]),
            section("Keystrokes", [
                row("Show keystrokes", control: withOptions(keystrokeMenu, optionToggle(\.showKeystrokes)),
                    note: "Needs Accessibility permission to see keys typed in other apps.")
            ]),
            section("Video", [
                row("Frame rate", control: popup(["60 fps", "30 fps", "24 fps"], values: [60, 30, 24], \.fps)),
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
            section("Camera", [
                row("Camera", control: devicePopup(Devices.cameras(), \.cameraDeviceID)),
                row("Size", control: popup(["Small", "Medium", "Large"], values: [0, 1, 2], \.cameraSize)),
                row("Shape", control: popup(["Circle", "Rounded square"], values: [false, true], \.cameraRounded)),
                row("Mirror camera", control: optionToggle(\.cameraMirrored))
            ]),
            section("GIF", [
                row("Frame rate", control: popup(["10 fps", "15 fps", "20 fps", "30 fps"], values: [10, 15, 20, 30], \.gifFPS)),
                row("Resolution", control: popup(["480 × auto", "640 × auto", "800 × auto (default)", "1024 × auto",
                                                  "1280 × auto", "Original"],
                                                 values: [480, 640, 800, 1024, 1280, 0], \.gifMaxWidth)),
                row("Optimize GIFs", control: optionToggle(\.gifOptimize),
                    note: "Merges frames that don't change, for smaller files."),
                row("Quality", control: qualitySlider())
            ])
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Scroll if it's taller than the screen allows.
        let document = FlippedView()
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width)
        ])
        let size = stack.fittingSize
        document.frame = CGRect(origin: .zero, size: size)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: size.width,
                                                height: min(size.height, (NSScreen.main?.visibleFrame.height ?? 900) - 120)))
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        view = scroll
        preferredContentSize = scroll.frame.size
    }

    // MARK: Building blocks

    private func section(_ title: String, _ rows: [NSView]) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        var items: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                items.append(line)
            }
            items.append(row)
        }
        let group = NSStackView(views: items)
        group.orientation = .vertical
        group.spacing = 0
        group.edgeInsets = NSEdgeInsets(top: 2, left: 12, bottom: 2, right: 12)
        group.wantsLayer = true
        group.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        group.layer?.cornerRadius = 10
        for item in items {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.widthAnchor.constraint(equalTo: group.widthAnchor, constant: -24).isActive = true
        }
        let column = NSStackView(views: [label, group])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        group.translatesAutoresizingMaskIntoConstraints = false
        group.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true
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
            text.preferredMaxLayoutWidth = Self.width - 60
            views.append(text)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        top.translatesAutoresizingMaskIntoConstraints = false
        top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
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
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        control.controlSize = .small
        control.addItems(withTitles: titles)
        control.selectItem(at: values.firstIndex(of: options[keyPath: path]) ?? 0)
        let target = Callback { [unowned self] sender in
            guard let index = (sender as? NSPopUpButton)?.indexOfSelectedItem, values.indices.contains(index) else { return }
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

    /// An "Options…" button that opens `menu`, next to a switch.
    private func withOptions(_ menu: @escaping () -> NSMenu, _ control: NSView) -> NSView {
        let button = NSButton(title: "Options…", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        let target = Callback { sender in
            guard let button = sender as? NSButton else { return }
            menu().popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.maxY + 2), in: button)
        }
        targets.append(target)
        button.target = target
        button.action = #selector(Callback.fire(_:))
        let stack = NSStackView(views: [button, control])
        stack.spacing = 10
        return stack
    }

    // MARK: Options menus

    private func choice(_ title: String, on: Bool, _ change: @escaping (inout RecordingOptions) -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title) { [weak self] in
            guard let self else { return }
            change(&self.options)
            self.onChange(self.options)
        }
        item.state = on ? .on : .off
        return item
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func clickMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(header("Colour"))
        for (index, entry) in RecordingOptions.clickColors.enumerated() {
            menu.addItem(choice(entry.name, on: options.clickColor == index) { $0.clickColor = index })
        }
        menu.addItem(.separator())
        menu.addItem(header("Size"))
        for (index, name) in ["Small", "Medium", "Large"].enumerated() {
            menu.addItem(choice(name, on: options.clickSize == index) { $0.clickSize = index })
        }
        menu.addItem(.separator())
        menu.addItem(header("Style"))
        menu.addItem(choice("Filled", on: options.clickFilled) { $0.clickFilled = true })
        menu.addItem(choice("Outline", on: !options.clickFilled) { $0.clickFilled = false })
        return menu
    }

    private func keystrokeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(header("Position"))
        menu.addItem(choice("Bottom", on: !options.keystrokesAtTop) { $0.keystrokesAtTop = false })
        menu.addItem(choice("Top", on: options.keystrokesAtTop) { $0.keystrokesAtTop = true })
        menu.addItem(.separator())
        menu.addItem(header("Size"))
        for (index, name) in ["Small", "Medium", "Large"].enumerated() {
            menu.addItem(choice(name, on: options.keystrokeSize == index) { $0.keystrokeSize = index })
        }
        menu.addItem(.separator())
        menu.addItem(header("Style"))
        menu.addItem(choice("Dark", on: !options.keystrokesLight) { $0.keystrokesLight = false })
        menu.addItem(choice("Light", on: options.keystrokesLight) { $0.keystrokesLight = true })
        menu.addItem(.separator())
        menu.addItem(choice("Show only shortcuts (⌘ ⌥ ⌃ keys)", on: options.keystrokesCommandOnly) {
            $0.keystrokesCommandOnly.toggle()
        })
        return menu
    }
}

/// Top-left origin, so a scroll view starts at the top of the content.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
