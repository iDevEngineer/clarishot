import AppKit
import ApplicationServices
import CoreImage
import ScreenCaptureKit

/// Runs a scrolling capture: pick the scrolling part of the screen, scroll
/// (by hand or with Auto-Scroll) while a live preview builds, then Done.
@MainActor
final class ScrollCaptureCoordinator {
    static let shared = ScrollCaptureCoordinator()

    private var session: ScrollCaptureSession?
    private var panel: ScrollCapturePanel?
    private var outline: RegionOutlineWindow?
    private var autoScroller: AutoScroller?
    private var screen: NSScreen?
    private var globalRect: CGRect = .zero
    private var axis: ScrollStitcher.Axis?

    func start() {
        guard session == nil else { return }
        CaptureCoordinator.shared.selectRegion(hint: "Drag to capture the scrolling part of the screen.") { [weak self] shot, rect in
            self?.begin(screen: shot.screen, rect: rect)
        }
    }

    private func begin(screen: NSScreen, rect: CGRect) {
        self.screen = screen
        globalRect = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)

        let outline = RegionOutlineWindow(rect: globalRect)
        outline.orderFrontRegardless()
        self.outline = outline

        let panel = ScrollCapturePanel()
        panel.onDone = { [weak self] in self?.done() }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onAutoScroll = { [weak self] in self?.toggleAutoScroll() }
        panel.place(beside: globalRect, on: screen)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        let session = ScrollCaptureSession()
        session.onUpdate = { [weak self] update in self?.handle(update) }
        self.session = session
        Task {
            do {
                try await session.start(screen: screen, rect: rect)
            } catch {
                cleanUp()
                NSAlert(error: error).runModal()
            }
        }
    }

    private func handle(_ update: ScrollCaptureSession.Update) {
        panel?.show(update)
        axis = update.axis ?? axis
        if update.status == .capturing { autoScroller?.noteMovement() }
        if update.status == .limitReached { autoScroller?.stop() }
    }

    private func toggleAutoScroll() {
        if let scroller = autoScroller {
            scroller.stop()
            autoScroller = nil
            panel?.setAutoScrolling(false)
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            Toast.show("Auto-Scroll needs accessibility permissions")
            return
        }
        let scroller = AutoScroller()
        scroller.onReachedEnd = { [weak self] in self?.done() }
        scroller.start(at: CGPoint(x: globalRect.midX, y: globalRect.midY), horizontal: axis == .horizontal)
        autoScroller = scroller
        panel?.setAutoScrolling(true)
    }

    private func done() {
        guard let session, let screen else { return }
        autoScroller?.stop()
        autoScroller = nil
        panel?.setBusy()
        Task {
            let image = await session.finish()
            cleanUp()
            guard let image else { Toast.show("Nothing was captured"); return }
            CaptureCoordinator.shared.deliver(Capture(image: image, scale: screen.backingScaleFactor))
        }
    }

    private func cancel() {
        autoScroller?.stop()
        autoScroller = nil
        let session = self.session
        Task { await session?.cancel() }
        cleanUp()
    }

    private func cleanUp() {
        session = nil
        panel?.orderOut(nil)
        panel = nil
        outline?.orderOut(nil)
        outline = nil
        screen = nil
        axis = nil
    }
}

// MARK: - Live frames + stitching

/// Streams frames of the chosen area and feeds them to a `ScrollStitcher`
/// on a background queue, reporting progress to the main thread.
final class ScrollCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Status { case waiting, capturing, lost, limitReached }

    struct Update {
        let status: Status
        let preview: CGImage?
        let pixelSize: (width: Int, height: Int)
        let axis: ScrollStitcher.Axis?
    }

    /// Called on the main thread.
    var onUpdate: (@MainActor (Update) -> Void)?

    private let queue = DispatchQueue(label: "snapzy.scrolling-capture")
    private let ciContext = CIContext()
    private var stream: SCStream?
    private var stitcher: ScrollStitcher? // used only on `queue`
    private var lastStatus: Status?

    @MainActor
    func start(screen: NSScreen, rect: CGRect) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let id = ScreenCapturer.displayID(for: screen)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.displayNotFound }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY, width: rect.width, height: rect.height)
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.showsCursor = false // the cursor would break frame matching
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 4

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// Stops and returns the full stitched image.
    @MainActor
    func finish() async -> CGImage? {
        try? await stream?.stopCapture()
        stream = nil
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.stitcher?.compose()) }
        }
    }

    @MainActor
    func cancel() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    // Runs on `queue`.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let frame = image(from: sampleBuffer) else { return }
        guard let stitcher else {
            stitcher = ScrollStitcher(firstFrame: frame)
            post(.waiting)
            return
        }
        switch stitcher.add(frame) {
        case .appended: post(.capturing)
        case .noMovement: break
        case .lost: if lastStatus != .lost { post(.lost) }
        case .limitReached: if lastStatus != .limitReached { post(.limitReached) }
        }
    }

    private func image(from sampleBuffer: CMSampleBuffer) -> CGImage? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(image, from: image.extent, format: .RGBA8,
                                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    private func post(_ status: Status) {
        lastStatus = status
        let update = Update(status: status, preview: stitcher?.preview(maxWidth: 432),
                            pixelSize: stitcher?.pixelSize ?? (0, 0), axis: stitcher?.axis)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onUpdate?(update) }
        }
    }
}

// MARK: - Auto-Scroll

/// Scrolls the content under the area by posting gentle scroll-wheel events.
/// Stops by itself when nothing has moved for 2 seconds (end of the page).
@MainActor
final class AutoScroller {
    var onReachedEnd: (() -> Void)?
    private var timer: Timer?
    private var lastMovement = Date()

    func start(at point: CGPoint, horizontal: Bool) {
        // Put the cursor over the content; event coordinates have a top-left origin.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: primaryHeight - point.y))
        CGAssociateMouseAndMouseCursorPosition(1)
        lastMovement = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(horizontal: horizontal) }
        }
    }

    func noteMovement() { lastMovement = Date() }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick(horizontal: Bool) {
        let step: Int32 = -16
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: horizontal ? 0 : step, wheel2: horizontal ? step : 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
        if Date().timeIntervalSince(lastMovement) > 2 {
            stop()
            onReachedEnd?()
        }
    }
}

// MARK: - Panel

/// Dark panel beside the area: live preview, size, tips, Auto-Scroll, Cancel, Done.
/// Return finishes, Esc cancels.
@MainActor
final class ScrollCapturePanel: NSPanel {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    var onAutoScroll: (() -> Void)?

    private let sizeLabel = NSTextField(labelWithString: "")
    private let preview = NSImageView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let autoButton = NSButton(title: "Auto-Scroll", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private static let width: CGFloat = 248

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 420),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        build()
        show(.init(status: .waiting, preview: nil, pixelSize: (0, 0), axis: nil))
    }

    override var canBecomeKey: Bool { true }

    private func build() {
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "Scrolling Capture")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        let header = NSStackView(views: [title, NSView(), sizeLabel])

        preview.imageScaling = .scaleProportionallyDown
        preview.imageAlignment = .alignBottom
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        preview.layer?.cornerRadius = 8
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 280).isActive = true

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        autoButton.target = self
        autoButton.action = #selector(autoScroll)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.bezelColor = .controlAccentColor
        for b in [autoButton, cancel, doneButton] { b.bezelStyle = .rounded; b.controlSize = .regular }
        let buttons = NSStackView(views: [autoButton, NSView(), cancel, doneButton])

        let stack = NSStackView(views: [header, preview, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width)
        ])
        for v in [header, preview, statusLabel, buttons] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        }
        contentView = background
        setContentSize(stack.fittingSize)
    }

    func show(_ update: ScrollCaptureSession.Update) {
        if let image = update.preview {
            preview.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        }
        if update.pixelSize.width > 0 {
            sizeLabel.stringValue = "\(update.pixelSize.width) × \(update.pixelSize.height) px"
        }
        switch update.status {
        case .waiting:
            statusLabel.stringValue = "Slowly scroll down (or sideways) through the content, or click Auto-Scroll. Only the moving part should be inside the frame."
        case .capturing:
            statusLabel.stringValue = "Keep scrolling slowly. Press Done (↩) when you reach the end."
        case .lost:
            statusLabel.stringValue = "Lost track — scroll back a little and go slower, in a straight line. Scrolling up isn't supported."
        case .limitReached:
            statusLabel.stringValue = "Maximum length reached. Press Done."
        }
    }

    func setAutoScrolling(_ on: Bool) {
        autoButton.title = on ? "Stop Scrolling" : "Auto-Scroll"
    }

    func setBusy() {
        statusLabel.stringValue = "Finishing…"
        doneButton.isEnabled = false
        autoButton.isEnabled = false
    }

    /// To the right of the area, else to the left, else inside its right edge.
    func place(beside rect: CGRect, on screen: NSScreen) {
        let size = frame.size
        let visible = screen.visibleFrame
        var x = rect.maxX + 16
        if x + size.width > visible.maxX - 8 { x = rect.minX - size.width - 16 }
        if x < visible.minX + 8 { x = rect.maxX - size.width - 16 }
        var y = rect.maxY - size.height
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrameOrigin(CGPoint(x: x, y: y))
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            switch event.keyCode {
            case 36, 76: onDone?(); return
            case 53: onCancel?(); return
            default: break
            }
        }
        super.sendEvent(event)
    }

    @objc private func autoScroll() { onAutoScroll?() }
    @objc private func cancel() { onCancel?() }
    @objc private func done() { onDone?() }
}
