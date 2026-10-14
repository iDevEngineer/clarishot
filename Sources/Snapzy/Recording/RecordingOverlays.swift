import AppKit
@preconcurrency import AVFoundation
import ApplicationServices
import UniformTypeIdentifiers

// These windows belong to Snapzy, which is normally left out of captures.
// The recorder adds them back in explicitly so they appear in the video.

// MARK: - Camera bubble

/// A draggable webcam preview (circle or rounded square). Click it to fill the
/// recorded area; click again to shrink it back.
@MainActor
final class CameraBubble: NSPanel {
    private let session = AVCaptureSession()
    private let preview: AVCaptureVideoPreviewLayer
    private let options: RecordingOptions
    private var normalFrame: CGRect?
    /// The recorded area (global coordinates), used for full-screen camera.
    var region: CGRect = .zero

    init(options: RecordingOptions) {
        self.options = options
        let d = options.cameraDiameter
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(contentRect: CGRect(x: 0, y: 0, width: d, height: d),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = CameraView(frame: CGRect(x: 0, y: 0, width: d, height: d))
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        view.layer?.borderWidth = 3
        view.layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.insertSublayer(preview, at: 0)
        view.onClick = { [weak self] in self?.toggleFullScreen() }
        contentView = view
        applyShape()
    }

    /// Asks for camera access and starts the preview. Returns false if unavailable.
    func start() async -> Bool {
        let device = options.cameraDeviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .video)
        guard await AVCaptureDevice.requestAccess(for: .video), let device,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = options.cameraMirrored
        }
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        return true
    }

    func stop() {
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        orderOut(nil)
    }

    /// Bottom-left corner of the recorded area (global coordinates).
    func place(in rect: CGRect) {
        region = rect
        normalFrame = nil
        setFrame(CGRect(x: rect.minX + 20, y: rect.minY + 20, width: options.cameraDiameter, height: options.cameraDiameter),
                 display: true)
        applyShape()
    }

    private func toggleFullScreen() {
        if let normal = normalFrame {
            normalFrame = nil
            setFrame(normal, display: true, animate: true)
        } else {
            normalFrame = frame
            setFrame(region, display: true, animate: true)
        }
        applyShape()
    }

    private func applyShape() {
        let size = frame.size
        let radius: CGFloat
        if normalFrame != nil {
            radius = 0
        } else {
            radius = options.cameraRounded ? min(size.width, size.height) * 0.18 : min(size.width, size.height) / 2
        }
        contentView?.layer?.cornerRadius = radius
        contentView?.layer?.borderWidth = normalFrame != nil ? 0 : 3
    }

    /// Drag to move; a click without moving toggles full screen.
    private final class CameraView: NSView {
        var onClick: (() -> Void)?
        private var start: CGPoint?
        private var moved = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            start = NSEvent.mouseLocation
            moved = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let start else { return }
            let now = NSEvent.mouseLocation
            let dx = now.x - start.x, dy = now.y - start.y
            if abs(dx) + abs(dy) > 2 { moved = true }
            window.setFrameOrigin(CGPoint(x: window.frame.minX + dx, y: window.frame.minY + dy))
            self.start = now
        }

        override func mouseUp(with event: NSEvent) {
            if !moved { onClick?() }
            start = nil
        }
    }
}

// MARK: - Countdown

/// Big 3-2-1 shown over the area before recording starts. Esc cancels.
@MainActor
final class CountdownWindow: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private var cancelled = false

    init(centeredIn rect: CGRect) {
        let size: CGFloat = 140
        super.init(contentRect: CGRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let box = NSView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        box.layer?.cornerRadius = 28
        label.font = .systemFont(ofSize: 72, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = CGRect(x: 0, y: (size - 90) / 2, width: size, height: 90)
        box.addSubview(label)
        contentView = box
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { cancelled = true }

    /// Red while there's time, orange for 3 and 2, green for the last second.
    private func setColor(for n: Int) {
        let color: NSColor = n == 1 ? .systemGreen : (n <= 3 ? .systemOrange : .systemRed)
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.duration = 0.25
        contentView?.layer?.add(animation, forKey: "color")
        contentView?.layer?.backgroundColor = color.withAlphaComponent(0.9).cgColor
    }

    /// Counts down from `seconds`. Returns false if cancelled with Esc.
    func run(seconds: Int = 3) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        for n in stride(from: seconds, through: 1, by: -1) {
            label.stringValue = "\(n)"
            setColor(for: n)
            NSSound(named: "Tink")?.play()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if cancelled { break }
        }
        orderOut(nil)
        return !cancelled
    }
}

// MARK: - Control bar

/// Floating bar shown during recording: stop, time, pause/resume, restart, discard.
@MainActor
final class RecordingControlBar: NSPanel {
    var onStop: (() -> Void)?
    var onPauseToggle: (() -> Void)?
    var onRestart: (() -> Void)?
    var onDiscard: (() -> Void)?

    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let pauseButton = PanelIconButton(symbol: "pause.fill", tip: "Pause recording")

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 220, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        let stop = PanelIconButton(symbol: "stop.fill", tip: "Stop recording")
        stop.contentTintColor = .systemRed
        stop.onClick = { [weak self] in self?.onStop?() }
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        timeLabel.textColor = .white
        pauseButton.onClick = { [weak self] in self?.onPauseToggle?() }
        let restart = PanelIconButton(symbol: "arrow.counterclockwise", tip: "Restart recording")
        restart.onClick = { [weak self] in self?.onRestart?() }
        let discard = PanelIconButton(symbol: "trash", tip: "Discard recording")
        discard.onClick = { [weak self] in self?.onDiscard?() }

        let stack = NSStackView(views: [stop, timeLabel, NSView(), pauseButton, restart, discard])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        contentView = background
    }

    func update(elapsed: TimeInterval, paused: Bool) {
        let s = Int(elapsed)
        timeLabel.stringValue = String(format: "%d:%02d", s / 60, s % 60)
        timeLabel.textColor = paused ? NSColor.white.withAlphaComponent(0.5) : .white
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                    accessibilityDescription: paused ? "Resume" : "Pause")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        pauseButton.toolTip = paused ? "Resume recording" : "Pause recording"
    }

    /// Under the area, or inside its bottom edge if there's no room.
    func place(below rect: CGRect, on screen: NSScreen) {
        let size = frame.size
        let visible = screen.visibleFrame
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if origin.y < visible.minY + 8 { origin.y = max(rect.minY, visible.minY) + 12 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        setFrameOrigin(origin)
    }
}

// MARK: - Progress popup

/// Small dark popup with a progress bar, e.g. while making a GIF.
@MainActor
final class ProgressHUD: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    init(title: String) {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 240, height: 64),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        let background = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: 240, height: 64))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        label.stringValue = title
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.frame = CGRect(x: 16, y: 34, width: 208, height: 18)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.frame = CGRect(x: 16, y: 12, width: 208, height: 14)
        background.addSubview(label)
        background.addSubview(bar)
        contentView = background
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            setFrameOrigin(CGPoint(x: v.midX - 120, y: v.minY + 60))
        }
    }

    func update(_ fraction: Double) { bar.doubleValue = fraction }
}

// MARK: - Desktop icon cover

/// Hides desktop icons by covering them with the wallpaper (Finder is left alone).
@MainActor
final class DesktopIconHider {
    static let shared = DesktopIconHider()
    private(set) var windows: [NSWindow] = []

    var isHiding: Bool { !windows.isEmpty }

    func toggle() { isHiding ? show() : hide() }

    func hide() {
        guard !isHiding else { return }
        for screen in NSScreen.screens {
            guard let image = Wallpaper.image(for: screen) else { continue }
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            view.layer?.contents = image
            view.layer?.contentsGravity = .resizeAspectFill
            window.contentView = view
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            windows.append(window)
        }
        if windows.isEmpty { Toast.show("Couldn't read your wallpaper to hide desktop icons") }
    }

    func show() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

// MARK: - Click highlights

/// Draws an expanding ring wherever the mouse is clicked inside the area.
@MainActor
final class ClickHighlightWindow: NSWindow {
    private var monitors: [Any] = []
    private let options: RecordingOptions

    init(rect: CGRect, options: RecordingOptions) {
        self.options = options
        super.init(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = NSView(frame: CGRect(origin: .zero, size: rect.size))
        view.wantsLayer = true
        contentView = view
    }

    func startMonitoring() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.ripple(at: NSEvent.mouseLocation) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.ripple(at: NSEvent.mouseLocation) }
            return event
        }) { monitors.append(local) }
    }

    func stopMonitoring() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        orderOut(nil)
    }

    private func ripple(at global: CGPoint) {
        guard frame.contains(global), let layer = contentView?.layer else { return }
        ClickRipple.add(to: layer, at: CGPoint(x: global.x - frame.minX, y: global.y - frame.minY), options: options)
    }
}

/// The ring drawn where you click; shared by recordings and the options preview.
@MainActor
enum ClickRipple {
    static func add(to layer: CALayer, at point: CGPoint, options: RecordingOptions) {
        let size = options.clickDiameter
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: size, height: size), transform: nil)
        let color = options.clickNSColor
        ring.fillColor = options.clickFilled ? color.withAlphaComponent(0.85).cgColor : NSColor.clear.cgColor
        ring.strokeColor = color.cgColor
        ring.lineWidth = 3
        layer.addSublayer(ring)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        if options.clickAnimate {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.4
            scale.toValue = 1.3
            group.animations = [scale, fade]
        } else {
            fade.beginTime = 0.3 // hold still, then fade
            group.animations = [fade]
        }
        group.duration = options.clickAnimate ? 0.5 : 0.6
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.opacity = 0
        ring.add(group, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { ring.removeFromSuperlayer() }
    }
}

// MARK: - Keystrokes

/// Shows pressed keys (e.g. "⌘⇧4") in a pill at the bottom of the area.
/// Needs Accessibility permission to see keys typed in other apps.
@MainActor
final class KeystrokeWindow: NSWindow {
    private var monitors: [Any] = []
    private let label = NSTextField(labelWithString: "")
    private let pill = NSView()
    private var hideWork: DispatchWorkItem?

    /// True if Snapzy may read keystrokes; otherwise asks macOS to show the permission prompt.
    static func ensurePermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private let options: RecordingOptions

    init(rect: CGRect, options: RecordingOptions) {
        self.options = options
        let height = options.keystrokeFontSize * 2.6
        let y = options.keystrokesAtTop ? rect.maxY - 24 - height : rect.minY + 24
        let frame = CGRect(x: rect.minX, y: y, width: rect.width, height: height)
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let root = NSView(frame: CGRect(origin: .zero, size: frame.size))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = (options.keystrokesLight ? NSColor.white.withAlphaComponent(0.92)
                                                               : NSColor.black.withAlphaComponent(0.75)).cgColor
        pill.layer?.cornerRadius = 12
        pill.alphaValue = 0
        label.font = .systemFont(ofSize: options.keystrokeFontSize, weight: .semibold)
        label.textColor = options.keystrokesLight ? .black : .white
        pill.addSubview(label)
        root.addSubview(pill)
        contentView = root
    }

    func startMonitoring() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.show(event) }
        }) { monitors.append(global) }
    }

    func stopMonitoring() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        orderOut(nil)
    }

    private func show(_ event: NSEvent) {
        if options.keystrokesCommandOnly,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return }
        var text = ""
        let flags = event.modifierFlags
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        text += Self.name(for: event)
        label.stringValue = text
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 32, height: label.frame.height + 16)
        let root = contentView!.bounds
        pill.frame = CGRect(x: root.midX - size.width / 2, y: root.midY - size.height / 2, width: size.width, height: size.height)
        label.setFrameOrigin(CGPoint(x: 16, y: 8))
        pill.alphaValue = 1

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self?.pill.animator().alphaValue = 0
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private static func name(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return (event.charactersIgnoringModifiers ?? "").uppercased()
        }
    }
}

// MARK: - GIF export

enum GIFExporter {
    /// Turns a recording into a looping GIF next to it (15 fps, at most 960 px wide).
    /// - maxWidth: nil keeps the recording's size.
    /// - optimize: frames that look the same as the one before are merged (longer delay).
    /// - quality: 0…1; lower uses fewer colours for smaller files.
    static func convert(_ url: URL, fps: Double = 15, maxWidth: CGFloat? = 800, optimize: Bool = true,
                        quality: Double = 0.75, progress: ((Double) -> Void)? = nil) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let maxWidth { generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4) }
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let count = max(1, Int(duration * fps))
        let output = url.deletingPathExtension().appendingPathExtension("gif")
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        let context = CIContext()
        let levels = 4 + quality * 28 // colour steps per channel; ignored at full quality
        func reduceColours(_ image: CGImage) -> CGImage {
            guard quality < 0.98, let filter = CIFilter(name: "CIColorPosterize") else { return image }
            let input = CIImage(cgImage: image)
            filter.setValue(input, forKey: kCIInputImageKey)
            filter.setValue(levels, forKey: "inputLevels")
            guard let result = filter.outputImage, let cg = context.createCGImage(result, from: input.extent) else { return image }
            return cg
        }
        func add(_ image: CGImage, delay: Double) {
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
            CGImageDestinationAddImage(destination, image, properties)
        }

        var pending: (image: CGImage, signature: [UInt8], delay: Double)?
        for i in 0..<count {
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            let (raw, _) = try await generator.image(at: time)
            let signature = Self.signature(of: raw)
            if optimize, var last = pending, Self.same(last.signature, signature) {
                last.delay += 1 / fps
                pending = last
            } else {
                if let last = pending { add(last.image, delay: last.delay) }
                pending = (reduceColours(raw), signature, 1 / fps)
            }
            progress?(Double(i + 1) / Double(count))
        }
        if let last = pending { add(last.image, delay: last.delay) }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output
    }

    /// A tiny 32×32 copy of a frame, for spotting frames that didn't change.
    private static func signature(of image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return pixels
    }

    private static func same(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var total = 0
        for i in 0..<a.count { total += abs(Int(a[i]) - Int(b[i])) }
        return Double(total) / Double(a.count) < 0.6
    }
}
