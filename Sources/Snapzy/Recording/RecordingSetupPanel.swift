import AppKit
import AVFoundation

/// Recording choices, remembered between recordings.
struct RecordingOptions {
    var microphone = false
    var systemAudio = true
    var camera = false
    var highlightClicks = false
    var showKeystrokes = false
    var showCursor = true
    var fps = 60
    var countdown = true
    var scaleTo1x = false
    var hideDesktopIcons = false
    var cameraSize = 1          // 0 small, 1 medium, 2 large
    var cameraRounded = false   // false = circle, true = rounded square
    var cameraMirrored = true
    var cameraDeviceID: String? // nil = system default
    var microphoneDeviceID: String?

    var cameraDiameter: CGFloat { [120, 180, 260][min(max(cameraSize, 0), 2)] }

    private static let key = "recordingOptions"

    static func load() -> RecordingOptions {
        var o = RecordingOptions()
        guard let d = UserDefaults.standard.dictionary(forKey: key) else { return o }
        o.microphone = d["microphone"] as? Bool ?? o.microphone
        o.systemAudio = d["systemAudio"] as? Bool ?? o.systemAudio
        o.camera = d["camera"] as? Bool ?? o.camera
        o.highlightClicks = d["highlightClicks"] as? Bool ?? o.highlightClicks
        o.showKeystrokes = d["showKeystrokes"] as? Bool ?? o.showKeystrokes
        o.showCursor = d["showCursor"] as? Bool ?? o.showCursor
        o.fps = d["fps"] as? Int ?? o.fps
        o.countdown = d["countdown"] as? Bool ?? o.countdown
        o.scaleTo1x = d["scaleTo1x"] as? Bool ?? o.scaleTo1x
        o.hideDesktopIcons = d["hideDesktopIcons"] as? Bool ?? o.hideDesktopIcons
        o.cameraSize = d["cameraSize"] as? Int ?? o.cameraSize
        o.cameraRounded = d["cameraRounded"] as? Bool ?? o.cameraRounded
        o.cameraMirrored = d["cameraMirrored"] as? Bool ?? o.cameraMirrored
        o.cameraDeviceID = d["cameraDeviceID"] as? String
        o.microphoneDeviceID = d["microphoneDeviceID"] as? String
        return o
    }

    func save() {
        var d: [String: Any] = [
            "microphone": microphone, "systemAudio": systemAudio, "camera": camera,
            "highlightClicks": highlightClicks, "showKeystrokes": showKeystrokes,
            "showCursor": showCursor, "fps": fps, "countdown": countdown, "scaleTo1x": scaleTo1x,
            "hideDesktopIcons": hideDesktopIcons, "cameraSize": cameraSize,
            "cameraRounded": cameraRounded, "cameraMirrored": cameraMirrored
        ]
        if let cameraDeviceID { d["cameraDeviceID"] = cameraDeviceID }
        if let microphoneDeviceID { d["microphoneDeviceID"] = microphoneDeviceID }
        UserDefaults.standard.set(d, forKey: Self.key)
    }
}

enum RecordingFormat {
    case video
    case gif
}

/// The dark panel shown after choosing an area: size, options, and Record GIF / Record Video.
/// Return records video, ⌥Return records a GIF, Esc cancels.
@MainActor
final class RecordingSetupPanel: NSPanel, NSTextFieldDelegate {
    var onOptionsChange: ((RecordingOptions) -> Void)?
    var onSizeChange: ((CGSize) -> Void)?
    var onFullscreen: (() -> Void)?
    var onReselect: (() -> Void)?
    var onRecord: ((RecordingFormat) -> Void)?
    var onCancel: (() -> Void)?

    private var options: RecordingOptions
    private let widthField = SizeField()
    private let heightField = SizeField()
    private let settingsButton = PanelIconButton(symbol: "slider.vertical.3", tip: "Recording settings")
    private var toggles: [PanelIconButton] = []

    private static let panelWidth: CGFloat = 268

    init(options: RecordingOptions, size: CGSize) {
        self.options = options
        super.init(contentRect: CGRect(x: 0, y: 0, width: Self.panelWidth, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        buildContent()
        updateSize(size)
    }

    override var canBecomeKey: Bool { true }

    // MARK: Layout

    private func buildContent() {
        // No outer box: each section is its own frosted card with a gap between them.
        let background = NSView()

        // Card 1: size row + option toggles.
        for field in [widthField, heightField] { field.delegate = self }
        settingsButton.onClick = { [weak self] in self?.showSettingsMenu() }
        let times = NSTextField(labelWithString: "×")
        times.textColor = .secondaryLabelColor
        let fullscreen = PanelIconButton(symbol: "arrow.up.left.and.arrow.down.right", tip: "Record full screen")
        fullscreen.onClick = { [weak self] in self?.onFullscreen?() }
        let reselect = PanelIconButton(symbol: "crop", tip: "Select a different area")
        reselect.onClick = { [weak self] in self?.onReselect?() }
        let sizeBox = NSStackView(views: [widthField, times, heightField, fullscreen])
        sizeBox.spacing = 4
        let sizeRow = NSStackView(views: [settingsButton, verticalDivider(), sizeBox, verticalDivider(), reselect])
        sizeRow.spacing = 6

        let toggleSpecs: [(String, String, String, WritableKeyPath<RecordingOptions, Bool>)] = [
            ("mic", "mic.fill", "Record microphone", \.microphone),
            ("speaker.slash", "speaker.wave.2.fill", "Record computer audio", \.systemAudio),
            ("video.slash", "video.fill", "Show camera", \.camera),
            ("cursorarrow.click", "cursorarrow.click.2", "Highlight clicks", \.highlightClicks),
            ("command.square", "command.square.fill", "Show keystrokes", \.showKeystrokes)
        ]
        toggles = toggleSpecs.map { off, on, tip, path in
            let button = PanelIconButton(symbol: off, onSymbol: on, tip: tip)
            button.isOn = options[keyPath: path]
            button.onClick = { [weak self, weak button] in
                guard let self, let button else { return }
                button.isOn.toggle()
                self.options[keyPath: path] = button.isOn
                self.onOptionsChange?(self.options)
            }
            return button
        }
        let toggleRow = NSStackView(views: toggles)
        toggleRow.distribution = .equalSpacing

        let card1 = card([sizeRow, horizontalDivider(), toggleRow])

        // Card 2: record actions.
        let gif = ActionRow(icon: Self.gifBadge(), title: "Record GIF", shortcut: "⌥↩") { [weak self] in
            self?.onRecord?(.gif)
        }
        let video = ActionRow(icon: NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)!,
                              title: "Record Video", shortcut: "↩") { [weak self] in
            self?.onRecord?(.video)
        }
        let card2 = card([gif, video], spacing: 0, padding: 4)

        let stack = NSStackView(views: [card1, card2])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.panelWidth)
        ])
        for c in [card1, card2] {
            c.widthAnchor.constraint(equalToConstant: Self.panelWidth - 16).isActive = true
        }
        contentView = background
        setContentSize(stack.fittingSize)
    }

    /// Slightly lighter rounded box grouping controls.
    /// A frosted dark card with a faint light edge.
    private func card(_ views: [NSView], spacing: CGFloat = 8, padding: CGFloat = 8) -> NSView {
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: padding + 2, left: padding + 2, bottom: padding + 2, right: padding + 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor)
        ])
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * (padding + 2)).isActive = true
        }
        return blur
    }

    private func horizontalDivider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func verticalDivider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return box
    }

    /// Small "GIF" label drawn as an icon.
    private static func gifBadge() -> NSImage {
        let image = NSImage(size: CGSize(width: 22, height: 14), flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            let text = NSAttributedString(string: "GIF", attributes: [
                .font: NSFont.systemFont(ofSize: 8.5, weight: .heavy),
                .foregroundColor: NSColor.black
            ])
            let size = text.size()
            text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
        return image
    }

    // MARK: State

    func updateSize(_ size: CGSize) {
        widthField.integerValue = Int(size.width.rounded())
        heightField.integerValue = Int(size.height.rounded())
    }

    /// Centres the panel under the area, or inside it when there's no room outside.
    func place(near rect: CGRect, on screen: NSScreen) {
        let size = frame.size
        let visible = screen.visibleFrame
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 14)
        if origin.y < visible.minY + 8 { origin.y = rect.maxY + 14 }
        if origin.y + size.height > visible.maxY - 8 { origin.y = max(rect.minY, visible.minY) + 40 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        setFrameOrigin(origin)
    }

    private func showSettingsMenu() {
        let menu = NSMenu()
        menu.addItem(toggleItem("Show Cursor", \.showCursor))
        menu.addItem(toggleItem("Hide Desktop Icons", \.hideDesktopIcons))
        menu.addItem(toggleItem("Countdown (3s)", \.countdown))
        menu.addItem(toggleItem("Scale Retina to 1x", \.scaleTo1x))
        menu.addItem(.separator())
        for fps in [60, 30] {
            menu.addItem(choiceItem("\(fps) FPS", selected: options.fps == fps) { $0.fps = fps })
        }
        menu.addItem(.separator())

        let mics = NSMenu()
        mics.addItem(choiceItem("System Default", selected: options.microphoneDeviceID == nil) { $0.microphoneDeviceID = nil })
        for device in Devices.microphones() {
            mics.addItem(choiceItem(device.localizedName, selected: options.microphoneDeviceID == device.uniqueID) {
                $0.microphoneDeviceID = device.uniqueID
            })
        }
        menu.addItem(submenu("Microphone", mics))

        let cams = NSMenu()
        cams.addItem(choiceItem("System Default", selected: options.cameraDeviceID == nil) { $0.cameraDeviceID = nil })
        for device in Devices.cameras() {
            cams.addItem(choiceItem(device.localizedName, selected: options.cameraDeviceID == device.uniqueID) {
                $0.cameraDeviceID = device.uniqueID
            })
        }
        cams.addItem(.separator())
        for (index, name) in ["Small", "Medium", "Large"].enumerated() {
            cams.addItem(choiceItem(name, selected: options.cameraSize == index) { $0.cameraSize = index })
        }
        cams.addItem(.separator())
        cams.addItem(choiceItem("Circle", selected: !options.cameraRounded) { $0.cameraRounded = false })
        cams.addItem(choiceItem("Rounded Square", selected: options.cameraRounded) { $0.cameraRounded = true })
        cams.addItem(.separator())
        cams.addItem(toggleItem("Mirror Camera", \.cameraMirrored))
        menu.addItem(submenu("Camera", cams))

        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: settingsButton.bounds.maxY + 4), in: settingsButton)
    }

    private func toggleItem(_ title: String, _ path: WritableKeyPath<RecordingOptions, Bool>) -> NSMenuItem {
        choiceItem(title, selected: options[keyPath: path]) { $0[keyPath: path].toggle() }
    }

    private func choiceItem(_ title: String, selected: Bool, change: @escaping (inout RecordingOptions) -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title) { [weak self] in
            guard let self else { return }
            change(&self.options)
            self.onOptionsChange?(self.options)
        }
        item.state = selected ? .on : .off
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    // MARK: Size fields

    func controlTextDidEndEditing(_ obj: Notification) {
        let size = CGSize(width: max(CGFloat(widthField.integerValue), 20), height: max(CGFloat(heightField.integerValue), 20))
        onSizeChange?(size)
    }

    // MARK: Keys

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let editing = firstResponder is NSText
            switch event.keyCode {
            case 36, 76: // return, enter
                if editing {
                    makeFirstResponder(nil) // commit the size first
                } else {
                    onRecord?(event.modifierFlags.contains(.option) ? .gif : .video)
                }
                return
            case 53: // esc
                onCancel?()
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }
}

// MARK: - Controls

/// Menu item that runs a closure when chosen.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }
    @objc private func run() { handler() }
}

/// Cameras and microphones connected to this Mac.
enum Devices {
    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio, position: .unspecified).devices
    }
}

/// Borderless icon button; dimmed when off, white when on.
final class PanelIconButton: NSButton {
    var onClick: (() -> Void)?
    var isOn = false { didSet { update() } }
    private let offSymbol: String
    private let onSymbol: String
    private let isToggle: Bool

    init(symbol: String, onSymbol: String? = nil, tip: String) {
        offSymbol = symbol
        self.onSymbol = onSymbol ?? symbol
        isToggle = onSymbol != nil
        super.init(frame: .zero)
        isBordered = false
        toolTip = tip
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = 7
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func update() {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        image = NSImage(systemSymbolName: isOn ? onSymbol : offSymbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(config)
        if isToggle {
            contentTintColor = isOn ? .white : NSColor.white.withAlphaComponent(0.5)
            layer?.backgroundColor = isOn ? NSColor.white.withAlphaComponent(0.14).cgColor : nil
        } else {
            contentTintColor = NSColor.white.withAlphaComponent(0.8)
        }
    }

    @objc private func clicked() { onClick?() }
}

/// Number field for the width/height boxes.
final class SizeField: NSTextField {
    init() {
        super.init(frame: .zero)
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 20
        formatter.maximum = 20000
        self.formatter = formatter
        alignment = .center
        font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        textColor = .white
        isBordered = false
        drawsBackground = true
        backgroundColor = NSColor.white.withAlphaComponent(0.08)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 56).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Full-width row: icon, title, and a grey shortcut hint. Highlights on hover.
final class ActionRow: NSView {
    private let action: () -> Void

    init(icon: NSImage, title: String, shortcut: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        let iconView = NSImageView(image: icon)
        iconView.contentTintColor = .white
        iconView.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .white
        let hint = NSTextField(labelWithString: shortcut)
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = NSColor.white.withAlphaComponent(0.5)

        let stack = NSStackView(views: [iconView, titleLabel, NSView(), hint])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
    }

    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}
