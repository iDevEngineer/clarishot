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
    var cameraSize = 1          // 0 small, 1 medium, 2 large, 3 huge
    var cameraShape = CameraShape.circle
    var cameraMirrored = true
    var cameraDeviceID: String? // nil = system default
    var microphoneDeviceID: String?
    var dimScreen = false
    var rememberSelection = false
    var clickColor = 0           // index into clickColors (0 = system accent colour)
    var clickScale = 0.5         // 0 … 1, see clickDiameter
    var clickFilled = false      // false = outline
    var clickAnimate = true
    var keystrokePosition = 4    // index into keystrokePositions (4 = Bottom-Center)
    var keystrokeScale = 0.5     // 0 … 1, see keystrokeFontSize
    var keystrokesBlur = true
    var keystrokesLight = false
    var keystrokesCommandOnly = false
    var maxResolution = 0        // index into maxHeights: 0 = original
    var audioMono = false
    var gifFPS = 15
    var gifMaxWidth = 800        // 0 = original size
    var gifOptimize = true
    var gifQuality = 0.75        // 0 (smallest file) … 1 (best colours)

    static let maxHeights: [(title: String, height: Int?)] = [
        ("Original", nil), ("4K", 2160), ("1440p", 1440), ("1080p", 1080), ("720p", 720), ("480p", 480)
    ]

    static let clickColors: [(name: String, color: NSColor)] = [
        ("System Accent color", .controlAccentColor), ("Blue", .systemBlue), ("Purple", .systemPurple),
        ("Pink", .systemPink), ("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow),
        ("Green", .systemGreen), ("Gray", .systemGray)
    ]
    var clickNSColor: NSColor { Self.clickColors[min(max(clickColor, 0), Self.clickColors.count - 1)].color }
    var clickDiameter: CGFloat { 24 + CGFloat(min(max(clickScale, 0), 1)) * 56 }
    var keystrokeFontSize: CGFloat { 16 + CGFloat(min(max(keystrokeScale, 0), 1)) * 28 }

    static let keystrokePositions = ["Top-Left", "Top-Center", "Top-Right", "Bottom-Left", "Bottom-Center", "Bottom-Right"]

    var cameraDiameter: CGFloat { [120, 180, 260, 380][min(max(cameraSize, 0), 3)] }
    /// The bubble's size for the chosen size and shape.
    var cameraBubbleSize: CGSize {
        let d = cameraDiameter
        switch cameraShape {
        case .circle, .square: return CGSize(width: d, height: d)
        case .rectangle: return CGSize(width: (d * 16 / 10).rounded(), height: d)
        case .vertical: return CGSize(width: (d * 3 / 4).rounded(), height: (d * 4 / 3).rounded())
        }
    }

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
        if let raw = d["cameraShape"] as? Int, let shape = CameraShape(rawValue: raw) {
            o.cameraShape = shape
        } else if d["cameraRounded"] as? Bool == true {
            o.cameraShape = .square // from the earlier circle / rounded-square setting
        }
        o.cameraMirrored = d["cameraMirrored"] as? Bool ?? o.cameraMirrored
        o.cameraDeviceID = d["cameraDeviceID"] as? String
        o.microphoneDeviceID = d["microphoneDeviceID"] as? String
        o.dimScreen = d["dimScreen"] as? Bool ?? o.dimScreen
        o.rememberSelection = d["rememberSelection"] as? Bool ?? o.rememberSelection
        o.clickColor = d["clickColor"] as? Int ?? o.clickColor
        o.clickScale = d["clickScale"] as? Double ?? o.clickScale
        o.clickFilled = d["clickFilled"] as? Bool ?? o.clickFilled
        o.clickAnimate = d["clickAnimate"] as? Bool ?? o.clickAnimate
        o.keystrokePosition = d["keystrokePosition"] as? Int ?? o.keystrokePosition
        o.keystrokeScale = d["keystrokeScale"] as? Double ?? o.keystrokeScale
        o.keystrokesBlur = d["keystrokesBlur"] as? Bool ?? o.keystrokesBlur
        o.keystrokesLight = d["keystrokesLight"] as? Bool ?? o.keystrokesLight
        o.keystrokesCommandOnly = d["keystrokesCommandOnly"] as? Bool ?? o.keystrokesCommandOnly
        o.maxResolution = d["maxResolution"] as? Int ?? o.maxResolution
        o.audioMono = d["audioMono"] as? Bool ?? o.audioMono
        o.gifFPS = d["gifFPS"] as? Int ?? o.gifFPS
        o.gifMaxWidth = d["gifMaxWidth"] as? Int ?? o.gifMaxWidth
        o.gifOptimize = d["gifOptimize"] as? Bool ?? o.gifOptimize
        o.gifQuality = d["gifQuality"] as? Double ?? o.gifQuality
        return o
    }

    func save() {
        var d: [String: Any] = [
            "microphone": microphone, "systemAudio": systemAudio, "camera": camera,
            "highlightClicks": highlightClicks, "showKeystrokes": showKeystrokes,
            "showCursor": showCursor, "fps": fps, "countdown": countdown, "scaleTo1x": scaleTo1x,
            "hideDesktopIcons": hideDesktopIcons, "cameraSize": cameraSize,
            "cameraShape": cameraShape.rawValue, "cameraMirrored": cameraMirrored,
            "dimScreen": dimScreen, "rememberSelection": rememberSelection, "clickColor": clickColor,
            "clickScale": clickScale, "clickFilled": clickFilled, "clickAnimate": clickAnimate, "keystrokePosition": keystrokePosition,
            "keystrokeScale": keystrokeScale, "keystrokesBlur": keystrokesBlur, "keystrokesLight": keystrokesLight,
            "keystrokesCommandOnly": keystrokesCommandOnly, "maxResolution": maxResolution,
            "audioMono": audioMono, "gifFPS": gifFPS, "gifMaxWidth": gifMaxWidth,
            "gifOptimize": gifOptimize, "gifQuality": gifQuality
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
    var onCameraFullScreen: (() -> Void)?
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
        hasShadow = false // the cards draw their own soft shadow; the window's made a dark outline
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        buildContent()
        updateSize(size)
    }

    override var canBecomeKey: Bool { true }

    override func orderOut(_ sender: Any?) {
        HintWindow.shared.hide()
        super.orderOut(sender)
    }

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
        let reselect = PanelIconButton(symbol: "crop", tip: "Aspect ratio")
        reselect.onClick = { [weak self, weak reselect] in
            guard let self, let reselect else { return }
            self.showAspectMenu(from: reselect)
        }
        let sizeBox = NSStackView(views: [widthField, times, heightField, fullscreen])
        sizeBox.spacing = 4
        let sizeRow = NSStackView(views: [settingsButton, verticalDivider(), sizeBox, verticalDivider(), reselect])
        sizeRow.spacing = 6

        let toggleSpecs: [(String, String, String, WritableKeyPath<RecordingOptions, Bool>)] = [
            // Same icon on and off (it turns blue when on), like the reference.
            ("mic", "mic", "Record microphone", \.microphone),
            ("tv.and.hifispeaker.fill", "tv.and.hifispeaker.fill", "Record computer audio", \.systemAudio),
            ("video", "video", "Show camera", \.camera),
            ("cursorarrow.rays", "cursorarrow.rays", "Highlight clicks", \.highlightClicks),
            ("command.square.fill", "command.square.fill", "Show keystrokes", \.showKeystrokes)
        ]
        toggles = toggleSpecs.map { off, on, tip, path in
            let button = PanelIconButton(symbol: off, onSymbol: on, tip: tip)
            button.isOn = options[keyPath: path]
            button.onClick = { [weak self, weak button] in
                guard let self, let button else { return }
                // The microphone button picks a device instead of toggling.
                if path == \RecordingOptions.microphone {
                    self.showMicrophoneMenu(from: button)
                    return
                }
                if path == \RecordingOptions.camera {
                    self.showCameraMenu(from: button)
                    return
                }
                button.isOn.toggle()
                self.options[keyPath: path] = button.isOn
                self.onOptionsChange?(self.options)
                self.updateTips()
            }
            return button
        }
        updateTips()
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
    /// A solid dark charcoal card with a thin light edge and a soft shadow, so it looks
    /// the same over light or dark backgrounds.
    private func card(_ views: [NSView], spacing: CGFloat = 8, padding: CGFloat = 8) -> NSView {
        let blur = NSView()
        blur.wantsLayer = true
        blur.layer?.backgroundColor = NSColor(white: 0.16, alpha: 0.96).cgColor
        blur.layer?.cornerRadius = 18
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        blur.layer?.shadowColor = NSColor.black.cgColor
        blur.layer?.shadowOpacity = 0.3
        blur.layer?.shadowRadius = 10
        blur.layer?.shadowOffset = CGSize(width: 0, height: -3)

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

    private var settingsPopover: NSPopover?

    /// The sliders button: grouped recording settings with switches.
    private func showSettingsMenu() {
        let controller = RecordingSettingsViewController(options: options) { [weak self] new in
            guard let self else { return }
            self.options = new
            self.syncToggles()
            self.onOptionsChange?(new)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = controller
        popover.show(relativeTo: settingsButton.bounds, of: settingsButton, preferredEdge: .maxY)
        settingsPopover = popover
    }

    /// Keeps the toggle row in step with changes made in the settings popover.
    private func syncToggles() {
        let paths: [WritableKeyPath<RecordingOptions, Bool>] = [\.microphone, \.systemAudio, \.camera,
                                                                \.highlightClicks, \.showKeystrokes]
        for (button, path) in zip(toggles, paths) { button.isOn = options[keyPath: path] }
        updateTips()
    }

    /// Hover hints that say what each toggle does and whether it is on.
    private func updateTips() {
        guard toggles.count == 5 else { return }
        let micName = Devices.microphones().first { $0.uniqueID == options.microphoneDeviceID }?.localizedName
            ?? AVCaptureDevice.default(for: .audio)?.localizedName ?? "Default"
        func state(_ on: Bool) -> String { on ? "On" : "Off" }
        toggles[0].hint = options.microphone ? "Microphone: \(micName)" : "Microphone: Off (click to choose)"
        toggles[1].hint = "Computer audio: \(state(options.systemAudio))"
        let cameraName = Devices.cameras().first { $0.uniqueID == options.cameraDeviceID }?.localizedName
            ?? AVCaptureDevice.default(for: .video)?.localizedName ?? "Default"
        toggles[2].hint = options.camera ? "Camera: \(cameraName)" : "Camera: Off (click to choose)"
        toggles[3].hint = "Highlight clicks: \(state(options.highlightClicks))"
        toggles[4].hint = "Show keystrokes: \(state(options.showKeystrokes))"
    }

    /// "Do Not Record Microphone", then every microphone on this Mac.
    private func showMicrophoneMenu(from view: NSView) {
        HintWindow.shared.hide()
        let menu = NSMenu()
        let none = ClosureMenuItem(title: "Do Not Record Microphone") { [weak self] in
            self?.setMicrophone(on: false, id: nil)
        }
        none.state = options.microphone ? .off : .on
        menu.addItem(none)
        menu.addItem(.separator())
        let chosen = options.microphoneDeviceID ?? AVCaptureDevice.default(for: .audio)?.uniqueID
        for mic in Devices.microphones() {
            let item = ClosureMenuItem(title: mic.localizedName) { [weak self] in
                self?.setMicrophone(on: true, id: mic.uniqueID)
            }
            item.state = options.microphone && chosen == mic.uniqueID ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: -4), in: view)
    }

    /// Camera, size, full screen, shape and flip, in one menu like the reference.
    private func showCameraMenu(from view: NSView) {
        HintWindow.shared.hide()
        let menu = NSMenu()
        func item(_ title: String, checked: Bool, _ action: @escaping (inout RecordingOptions) -> Void) -> NSMenuItem {
            let item = ClosureMenuItem(title: title) { [weak self] in
                guard let self else { return }
                action(&self.options)
                self.toggles[2].isOn = self.options.camera
                self.onOptionsChange?(self.options)
                self.updateTips()
            }
            item.state = checked ? .on : .off
            return item
        }

        menu.addItem(.sectionHeader(title: "Camera"))
        menu.addItem(item("None", checked: !options.camera) { $0.camera = false })
        let chosen = options.cameraDeviceID ?? AVCaptureDevice.default(for: .video)?.uniqueID
        for cam in Devices.cameras() {
            menu.addItem(item(cam.localizedName, checked: options.camera && chosen == cam.uniqueID) {
                $0.camera = true
                $0.cameraDeviceID = cam.uniqueID
            })
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Size"))
        for (index, title) in ["Small", "Medium", "Large", "Huge"].enumerated() {
            menu.addItem(item(title, checked: options.cameraSize == index) { $0.cameraSize = index })
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Click on camera to toggle Full Screen"))
        let full = ClosureMenuItem(title: "Full Screen") { [weak self] in self?.onCameraFullScreen?() }
        full.isEnabled = options.camera
        menu.addItem(full)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Shape"))
        for shape in CameraShape.allCases {
            menu.addItem(item(shape.title, checked: options.cameraShape == shape) { $0.cameraShape = shape })
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Options"))
        menu.addItem(item("Flip Camera", checked: options.cameraMirrored) { $0.cameraMirrored.toggle() })

        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: -4), in: view)
    }

    private func setMicrophone(on: Bool, id: String?) {
        options.microphone = on
        if let id { options.microphoneDeviceID = id }
        toggles.first?.isOn = on
        onOptionsChange?(options)
        updateTips()
    }

    // MARK: Size fields

    private var currentRatio: CGFloat?

    /// Ratio list, plus a way to pick a new area. Keeps the width and fits the height.
    private func showAspectMenu(from view: NSView) {
        let menu = NSMenu()
        AspectRatios.addItems(to: menu, current: currentRatio) { [weak self] ratio in
            guard let self else { return }
            self.currentRatio = ratio
            guard let ratio else { return }
            var width = CGFloat(self.widthField.integerValue)
            var height = (width / ratio).rounded()
            let maxHeight = NSScreen.main?.frame.height ?? height
            if height > maxHeight { height = maxHeight; width = (height * ratio).rounded() }
            self.onSizeChange?(CGSize(width: width, height: height))
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Select a New Area…") { [weak self] in self?.onReselect?() })
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: view.bounds.maxY + 4), in: view)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        currentRatio = nil
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
        hint = tip
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
        image = NSImage(systemSymbolName: isOn ? onSymbol : offSymbol, accessibilityDescription: hint)?
            .withSymbolConfiguration(config)
        if isToggle {
            // Like the reference: white icon, a light backing and a small tick underneath when on.
            contentTintColor = NSColor.white.withAlphaComponent(isOn ? 1 : 0.85)
            layer?.backgroundColor = isOn ? NSColor.white.withAlphaComponent(0.14).cgColor : nil
            tick.isHidden = !isOn
        } else {
            contentTintColor = NSColor.white.withAlphaComponent(0.85)
        }
    }

    @objc private func clicked() {
        HintWindow.shared.hide()
        onClick?()
    }

    /// Text shown on hover. AppKit tooltips don't appear over a non-activating panel, so we draw our own.
    var hint: String? {
        didSet { if isHovering, let hint { HintWindow.shared.show(hint, below: self) } }
    }
    private var isHovering = false

    private lazy var tick: NSImageView = {
        let view = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) ?? NSImage())
        view.symbolConfiguration = .init(pointSize: 7, weight: .bold)
        view.contentTintColor = .white
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: centerXAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1)
        ])
        return view
    }()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        if let text = hint ?? toolTip { HintWindow.shared.show(text, below: self) }
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        HintWindow.shared.hide()
    }
}

/// A small dark label that appears under a hovered button after a short delay.
@MainActor
final class HintWindow {
    static let shared = HintWindow()
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var pending: DispatchWorkItem?

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.95).cgColor
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 0.5
        box.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor)
        ])
        panel.contentView = box
    }

    func show(_ text: String, below view: NSView) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view, let window = view.window else { return }
            self.label.stringValue = text
            let size = CGSize(width: self.label.fittingSize.width + 16, height: 24)
            let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
            self.panel.setFrame(CGRect(x: rect.midX - size.width / 2, y: rect.minY - size.height - 6,
                                       width: size.width, height: size.height), display: true)
            self.panel.orderFrontRegardless()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func hide() {
        pending?.cancel()
        panel.orderOut(nil)
    }
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
        backgroundColor = NSColor.white.withAlphaComponent(0.1)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 8
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

/// The camera bubble's outline.
enum CameraShape: Int, CaseIterable {
    case circle, square, rectangle, vertical

    var title: String {
        switch self {
        case .circle: return "Circle"
        case .square: return "Square"
        case .rectangle: return "Rectangle"
        case .vertical: return "Vertical"
        }
    }
}
