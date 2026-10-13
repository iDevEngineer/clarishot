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
    private var dim: ScrollDimWindow?
    private var preview: ScrollPreviewPanel?
    private var controls: ScrollControlsPanel?
    private var autoPill: ScrollAutoPill?
    private var autoScroller: AutoScroller?
    private var screen: NSScreen?
    private var globalRect: CGRect = .zero
    private var axis: ScrollStitcher.Axis?

    /// Pick the scrolling part of the screen (adjustable), then press Start Capture.
    func start() {
        guard session == nil else { return }
        CaptureCoordinator.shared.selectScrollingArea { [weak self] shot, rect in
            self?.begin(screen: shot.screen, rect: rect)
        }
    }

    /// Starts straight away on an area that was already chosen (e.g. from All-In-One).
    func begin(screen: NSScreen, rect: CGRect) {
        guard session == nil else { return }
        self.screen = screen
        globalRect = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)

        // Dim everything except the area. It ignores the mouse, so you scroll the app underneath.
        let dim = ScrollDimWindow(screen: screen, hole: globalRect)
        dim.orderFrontRegardless()
        self.dim = dim

        let preview = ScrollPreviewPanel()
        preview.anchor(to: globalRect, on: screen)
        self.preview = preview

        let controls = ScrollControlsPanel()
        controls.onDone = { [weak self] in self?.done() }
        controls.onCancel = { [weak self] in self?.cancel() }
        controls.place(below: globalRect, on: screen)
        controls.orderFrontRegardless()
        controls.makeKey() // for Return / Esc, without taking focus from the app you scroll
        self.controls = controls

        let pill = ScrollAutoPill()
        pill.onToggle = { [weak self] in self?.toggleAutoScroll() }
        pill.place(insideBottomOf: globalRect)
        pill.orderFrontRegardless()
        autoPill = pill

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
        preview?.show(update)
        axis = update.axis ?? axis
        if update.status == .capturing { autoScroller?.noteMovement() }
        if update.status == .limitReached { autoScroller?.stop() }
    }

    private func toggleAutoScroll() {
        if let scroller = autoScroller {
            scroller.stop()
            autoScroller = nil
            autoPill?.setActive(false)
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
        autoPill?.setActive(true)
    }

    private func done() {
        guard let session, let screen else { return }
        let source = SourceApp.under(globalRect)
        autoScroller?.stop()
        autoScroller = nil
        controls?.setBusy()
        Task {
            let image = await session.finish()
            cleanUp()
            guard let image else { Toast.show("Nothing was captured"); return }
            CaptureCoordinator.shared.deliver(Capture(image: image, scale: screen.backingScaleFactor).from(source))
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
        for window in [dim, preview, controls, autoPill] as [NSWindow?] { window?.orderOut(nil) }
        dim = nil
        preview = nil
        controls = nil
        autoPill = nil
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
        case .appended, .moved: post(.capturing)
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

// MARK: - On-screen pieces

/// Darkens the screen around the area with a thin white frame. Click-through.
@MainActor
final class ScrollDimWindow: NSWindow {
    init(screen: NSScreen, hole: CGRect) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let local = hole.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        contentView = DimView(frame: CGRect(origin: .zero, size: screen.frame.size), hole: local)
        setFrame(screen.frame, display: false)
    }

    private final class DimView: NSView {
        let hole: CGRect
        init(frame: CGRect, hole: CGRect) {
            self.hole = hole
            super.init(frame: frame)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(hole)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(hole.insetBy(dx: -0.5, dy: -0.5))
        }
    }
}

/// The stitched image so far, beside the area (left if there's room), bottom-aligned
/// with it and growing upward as you scroll. Turns orange if frames stop lining up.
@MainActor
final class ScrollPreviewPanel: NSPanel {
    private let imageView = NSImageView()
    private var area: CGRect = .zero
    private var visibleArea: CGRect = .zero
    private static let maxWidth: CGFloat = 220

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.white.cgColor
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 0
        contentView = imageView
    }

    func anchor(to area: CGRect, on screen: NSScreen) {
        self.area = area
        visibleArea = screen.visibleFrame
    }

    func show(_ update: ScrollCaptureSession.Update) {
        guard let image = update.preview else { return }
        // Fit inside a box beside the area: up to 220 wide and most of the screen tall.
        let maxHeight = visibleArea.height - 40
        let fit = min(Self.maxWidth / CGFloat(image.width), maxHeight / CGFloat(image.height))
        let size = CGSize(width: (CGFloat(image.width) * fit).rounded(), height: (CGFloat(image.height) * fit).rounded())
        imageView.image = NSImage(cgImage: image, size: size)

        var x = area.minX - size.width - 16
        if x < visibleArea.minX + 8 { x = area.maxX + 16 }
        if x + size.width > visibleArea.maxX - 8 { x = area.minX + 8 }
        var y = area.minY
        if y + size.height > visibleArea.maxY - 8 { y = visibleArea.maxY - 8 - size.height }
        y = max(y, visibleArea.minY + 8)
        setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: true)

        let lost = update.status == .lost
        imageView.layer?.borderWidth = lost ? 3 : 0
        imageView.layer?.borderColor = NSColor.systemOrange.cgColor
        imageView.toolTip = lost ? "Lost track — scroll back a little and go slower" : nil
        if !isVisible { orderFrontRegardless() }
    }
}

/// Cancel and Done pills under the area. Return finishes, Esc cancels.
@MainActor
final class ScrollControlsPanel: NSPanel {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    private var doneButton: PillLabelButton!

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 200, height: 36),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let cancel = PillLabelButton(title: "Cancel", symbol: "xmark", light: false) { [weak self] in self?.onCancel?() }
        doneButton = PillLabelButton(title: "Done", symbol: "checkmark", light: true) { [weak self] in self?.onDone?() }
        let stack = NSStackView(views: [cancel, doneButton])
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        contentView = stack
        setContentSize(stack.fittingSize)
    }

    override var canBecomeKey: Bool { true }

    func place(below area: CGRect, on screen: NSScreen) {
        let size = frame.size
        let visible = screen.visibleFrame
        var origin = CGPoint(x: area.midX - size.width / 2, y: area.minY - size.height - 10)
        if origin.y < visible.minY + 4 { origin.y = area.minY + 10 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        setFrameOrigin(origin)
    }

    func setBusy() {
        doneButton.isEnabled = false
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
}

/// Small "Auto-Scroll" pill inside the bottom of the area.
@MainActor
final class ScrollAutoPill: NSPanel {
    var onToggle: (() -> Void)?
    private var button: PillLabelButton!

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 120, height: 28),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setActive(false)
    }

    func setActive(_ active: Bool) {
        button = PillLabelButton(title: active ? "Stop Scrolling" : "Auto-Scroll",
                                 symbol: active ? "stop.fill" : "arrow.down.circle.fill", light: false) { [weak self] in
            self?.onToggle?()
        }
        contentView = button
        setContentSize(button.fittingSize)
        if frame.width > 0, let center = centerPoint { setFrameOrigin(CGPoint(x: center.x - frame.width / 2, y: frame.minY)) }
    }

    private var centerPoint: CGPoint?

    func place(insideBottomOf area: CGRect) {
        centerPoint = CGPoint(x: area.midX, y: area.minY)
        setFrameOrigin(CGPoint(x: area.midX - frame.width / 2, y: area.minY + 12))
    }
}
