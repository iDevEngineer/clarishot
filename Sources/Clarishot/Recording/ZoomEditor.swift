import AppKit
import AVKit

/// Edit Zooms: a preview of the recording, a timeline of zoom segments, and Export.
///
/// Zooms start from the clicks logged while recording. Click a zoom on the timeline to select it,
/// drag it to move, drag its ends to resize, double-click empty timeline to add one. With a zoom
/// selected, the preview shows the whole frame with the zoomed area outlined: click or drag in
/// the preview to aim it.
@available(macOS 15.0, *)
@MainActor
final class ZoomEditorController: NSObject, NSWindowDelegate {
    private static var openControllers: [ZoomEditorController] = []

    static func open(_ url: URL, sourceBundleID: String?) {
        let controller = ZoomEditorController(url: url, sourceBundleID: sourceBundleID)
        openControllers.append(controller)
        NSApp.activate(ignoringOtherApps: true)
        controller.window.makeKeyAndOrderFront(nil)
        Task { await controller.load() }
    }

    private let url: URL
    private let sourceBundleID: String?
    private let asset: AVURLAsset
    private let window: NSWindow
    private let player = AVPlayer()
    private let playerView = AVPlayerView()
    private let focus = FocusOverlayView()
    private let timeline = ZoomTimelineView()
    private let playButton = NSButton()
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let scaleSlider = NSSlider(value: 2, minValue: 1.25, maxValue: 3.5, target: nil, action: nil)
    private let scaleLabel = NSTextField(labelWithString: "2.0×")
    private let deleteButton = NSButton(title: "Delete Zoom", target: nil, action: nil)
    private var clicks: [RecordedClick] = []
    private var duration: Double = 0
    private var timeObserver: Any?
    private var compositionTask: Task<Void, Never>?

    private var plan = ZoomPlan() { didSet { planChanged() } }
    private var selected: Int? { didSet { selectionChanged() } }

    private init(url: URL, sourceBundleID: String?) {
        self.url = url
        self.sourceBundleID = sourceBundleID
        asset = AVURLAsset(url: url)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = "Edit Zooms"
        window.minSize = CGSize(width: 720, height: 480)
        window.delegate = self
        window.center()
        build()
    }

    // MARK: Layout

    private func build() {
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.translatesAutoresizingMaskIntoConstraints = false
        focus.translatesAutoresizingMaskIntoConstraints = false
        focus.videoBounds = { [weak self] in self?.playerView.videoBounds ?? .zero }
        focus.onAim = { [weak self] point in self?.aim(at: point) }

        timeline.translatesAutoresizingMaskIntoConstraints = false
        timeline.onSeek = { [weak self] t in self?.seek(to: t) }
        timeline.onSelect = { [weak self] index in self?.selected = index }
        timeline.onChange = { [weak self] segments in self?.plan.segments = segments }
        timeline.onAdd = { [weak self] t in self?.addZoom(at: t) }

        playButton.bezelStyle = .rounded
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        playButton.target = self
        playButton.action = #selector(togglePlay)
        playButton.keyEquivalent = " "
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor

        let auto = NSButton(title: "Auto Zoom", target: self, action: #selector(autoZoom))
        auto.bezelStyle = .rounded
        auto.toolTip = "Place zooms at every click made while recording"
        let add = NSButton(title: "Add Zoom", target: self, action: #selector(addAtPlayhead))
        add.bezelStyle = .rounded
        add.toolTip = "Add a zoom at the playhead (or double-click the timeline)"
        scaleSlider.target = self
        scaleSlider.action = #selector(scaleChanged)
        scaleSlider.controlSize = .small
        scaleSlider.translatesAutoresizingMaskIntoConstraints = false
        scaleSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        scaleLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteZoom)
        let zoomLabel = NSTextField(labelWithString: "Zoom")
        zoomLabel.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let export = NSButton(title: "Export", target: self, action: #selector(exportMovie))
        export.bezelStyle = .rounded
        export.bezelColor = .controlAccentColor
        export.keyEquivalent = "\r"

        let controls = NSStackView(views: [playButton, timeLabel, NSView(), auto, add, zoomLabel, scaleSlider, scaleLabel,
                                           deleteButton, NSView(), cancel, export])
        controls.spacing = 8
        controls.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        controls.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        for view in [playerView, focus, timeline, controls] as [NSView] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            focus.topAnchor.constraint(equalTo: playerView.topAnchor),
            focus.bottomAnchor.constraint(equalTo: playerView.bottomAnchor),
            focus.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
            focus.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
            timeline.topAnchor.constraint(equalTo: playerView.bottomAnchor, constant: 8),
            timeline.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            timeline.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            timeline.heightAnchor.constraint(equalToConstant: 64),
            controls.topAnchor.constraint(equalTo: timeline.bottomAnchor, constant: 8),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            controls.heightAnchor.constraint(equalToConstant: 44),
            controls.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6)
        ])
        window.contentView = content
        selectionChanged()
    }

    private func load() async {
        duration = (try? await asset.load(.duration).seconds) ?? 0
        clicks = ClickLog.load(for: url)
        timeline.duration = duration
        timeline.clicks = clicks
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.timeChanged(time.seconds) }
        }
        plan = ZoomPlan.automatic(from: clicks, duration: duration)
        timeChanged(0)
        if clicks.isEmpty {
            Toast.show("No clicks were recorded: double-click the timeline to add a zoom")
        }
    }

    // MARK: Changes

    private func planChanged() {
        timeline.segments = plan.segments
        if let selected, !plan.segments.indices.contains(selected) { self.selected = nil }
        refreshControls()
        rebuildComposition()
    }

    private func selectionChanged() {
        timeline.selected = selected
        focus.segment = selected.map { plan.segments[$0] }
        refreshControls()
        rebuildComposition()
        if let selected, let segment = plan.segments[safe: selected] {
            // Show the middle of the zoom while aiming it.
            player.pause()
            seek(to: (segment.start + segment.end) / 2)
        }
    }

    private func refreshControls() {
        let segment = selected.flatMap { plan.segments[safe: $0] }
        scaleSlider.isEnabled = segment != nil
        deleteButton.isEnabled = segment != nil
        let scale: Double = segment?.scale ?? 2.0
        scaleSlider.doubleValue = scale
        scaleLabel.stringValue = String(format: "%.1f×", scale)
        scaleLabel.textColor = segment == nil ? .tertiaryLabelColor : .labelColor
        focus.segment = segment
    }

    /// Re-applies the zooms to the preview; with a zoom selected it shows the plain frame to aim on.
    private func rebuildComposition() {
        compositionTask?.cancel()
        let plan = self.plan, showZoom = selected == nil, asset = self.asset
        compositionTask = Task { [weak self] in
            guard let composition = try? await plan.composition(for: asset, showZoom: showZoom),
                  !Task.isCancelled, let self, let item = self.player.currentItem else { return }
            item.videoComposition = composition
            // Redraw the current frame when paused.
            if self.player.rate == 0 {
                await self.player.seek(to: self.player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    private func timeChanged(_ t: Double) {
        timeline.playhead = t
        timeLabel.stringValue = "\(Self.clock(t)) / \(Self.clock(duration))"
        let playing = player.rate != 0
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        if playing, t >= duration - 0.05 { player.pause() }
    }

    private static func clock(_ t: Double) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Actions

    private func seek(to t: Double) {
        player.seek(to: CMTime(seconds: min(max(t, 0), duration), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        timeChanged(t)
    }

    @objc private func togglePlay() {
        if player.rate != 0 { player.pause(); return }
        selected = nil // play shows the finished zooms
        if player.currentTime().seconds >= duration - 0.05 { seek(to: 0) }
        player.play()
    }

    @objc private func autoZoom() {
        guard !clicks.isEmpty else {
            Toast.show("No clicks were recorded in this video")
            return
        }
        selected = nil
        plan = ZoomPlan.automatic(from: clicks, duration: duration)
        Toast.show("\(plan.segments.count) zoom\(plan.segments.count == 1 ? "" : "s") placed at your clicks")
    }

    @objc private func addAtPlayhead() { addZoom(at: player.currentTime().seconds) }

    private func addZoom(at t: Double) {
        guard duration > ZoomPlan.minLength else { return }
        var start = max(0, t - 0.2), end = min(duration, start + 2.5)
        // Fit into the gap around t, without overlapping neighbours.
        if let before = plan.segments.last(where: { $0.end <= t }) { start = max(start, before.end) }
        if let after = plan.segments.first(where: { $0.start >= t }) { end = min(end, after.start) }
        if plan.segments.contains(where: { t > $0.start && t < $0.end }) || end - start < ZoomPlan.minLength {
            Toast.show("No room for a zoom here")
            return
        }
        var segments = plan.segments
        segments.append(ZoomSegment(start: start, end: end))
        segments.sort { $0.start < $1.start }
        plan.segments = segments
        selected = segments.firstIndex { $0.start == start }
    }

    @objc private func scaleChanged() {
        guard let selected, plan.segments.indices.contains(selected) else { return }
        plan.segments[selected].scale = (scaleSlider.doubleValue * 4).rounded() / 4
    }

    @objc private func deleteZoom() {
        guard let selected, plan.segments.indices.contains(selected) else { return }
        self.selected = nil
        plan.segments.remove(at: selected)
    }

    /// Clicking the preview with a zoom selected moves its centre there.
    private func aim(at point: CGPoint) {
        guard let selected, plan.segments.indices.contains(selected) else { return }
        plan.segments[selected].center = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }

    @objc private func cancel() { window.close() }

    @objc private func exportMovie() {
        player.pause()
        let plan = self.plan
        let hud = ProgressHUD(title: "Exporting…")
        hud.orderFrontRegardless()
        window.orderOut(nil)
        Task {
            defer { hud.orderOut(nil); window.close() }
            do {
                let name = "Clarishot Recording \(Capture.timestamp(Date())) (zoomed).mp4"
                let out = try Capture.temporaryDirectory().appendingPathComponent(name)
                try await plan.export(asset, to: out)
                let result = AVURLAsset(url: out)
                let generator = AVAssetImageGenerator(asset: result)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 800, height: 800)
                let length = (try? await result.load(.duration).seconds) ?? duration
                guard let (thumbnail, _) = try? await generator.image(at: .zero) else { throw CocoaError(.fileWriteUnknown) }
                let capture = Capture(videoURL: out, thumbnail: thumbnail, scale: 1, duration: length).from(sourceBundleID)
                HistoryStore.shared.add(capture)
                PreviewManager.shared.show(capture)
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                NSAlert(error: error).runModal()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        compositionTask?.cancel()
        Self.openControllers.removeAll { $0 === self }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Aiming overlay

/// Over the preview: with a zoom selected, dims everything outside the zoomed area and lets you
/// click or drag to move it.
@MainActor
private final class FocusOverlayView: NSView {
    var segment: ZoomSegment? { didSet { needsDisplay = true } }
    var videoBounds: () -> CGRect = { .zero }
    var onAim: ((CGPoint) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { segment == nil ? nil : super.hitTest(point) }

    override func draw(_ dirtyRect: NSRect) {
        guard let segment else { return }
        let video = videoBounds()
        guard video.width > 0 else { return }
        let rect = ZoomPlan(segments: [segment]).visibleRect(at: (segment.start + segment.end) / 2)
        let zoom = CGRect(x: video.minX + rect.minX * video.width,
                          y: video.maxY - rect.maxY * video.height, // view is bottom-left origin
                          width: rect.width * video.width, height: rect.height * video.height)
        let dim = NSBezierPath(rect: video)
        dim.append(NSBezierPath(roundedRect: zoom, xRadius: 6, yRadius: 6).reversed)
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()
        let outline = NSBezierPath(roundedRect: zoom, xRadius: 6, yRadius: 6)
        outline.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        outline.stroke()
        let label = String(format: "%.1f×  ·  click or drag to aim", segment.scale) as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                    .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attrs)
        let pill = CGRect(x: zoom.minX + 8, y: zoom.maxY - size.height - 12, width: size.width + 14, height: size.height + 6)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        label.draw(at: CGPoint(x: pill.minX + 7, y: pill.minY + 3), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) { aim(event) }
    override func mouseDragged(with event: NSEvent) { aim(event) }

    private func aim(_ event: NSEvent) {
        let video = videoBounds()
        guard video.width > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        onAim?(CGPoint(x: (p.x - video.minX) / video.width, y: (video.maxY - p.y) / video.height))
    }

    override func resetCursorRects() {
        if segment != nil { addCursorRect(bounds, cursor: .crosshair) }
    }
}

// MARK: - Timeline

/// The zoom track: segments as bars, click markers as dots, and a playhead.
@MainActor
private final class ZoomTimelineView: NSView {
    var duration: Double = 0 { didSet { needsDisplay = true } }
    var segments: [ZoomSegment] = [] { didSet { needsDisplay = true } }
    var clicks: [RecordedClick] = [] { didSet { needsDisplay = true } }
    var selected: Int? { didSet { needsDisplay = true } }
    var playhead: Double = 0 { didSet { needsDisplay = true } }

    var onSeek: ((Double) -> Void)?
    var onSelect: ((Int?) -> Void)?
    var onChange: (([ZoomSegment]) -> Void)?
    var onAdd: ((Double) -> Void)?

    private enum Drag { case seek, move(Int, grab: Double), start(Int), end(Int) }
    private var drag: Drag?
    private var dragOriginal: [ZoomSegment] = []

    private var track: CGRect { bounds.insetBy(dx: 2, dy: 10) }
    private func x(_ t: Double) -> CGFloat { track.minX + CGFloat(t / max(duration, 0.001)) * track.width }
    private func time(_ x: CGFloat) -> Double { min(max(Double((x - track.minX) / track.width) * duration, 0), duration) }

    override func draw(_ dirtyRect: NSRect) {
        let trackPath = NSBezierPath(roundedRect: track, xRadius: 8, yRadius: 8)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        trackPath.fill()

        // Seconds ticks.
        if duration > 0 {
            let step = duration > 120 ? 10.0 : (duration > 30 ? 5 : 1)
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            var t = step
            while t < duration {
                NSRect(x: x(t), y: track.minY, width: 1, height: 5).fill()
                t += step
            }
        }

        for (i, segment) in segments.enumerated() {
            let rect = CGRect(x: x(segment.start), y: track.minY + 6, width: x(segment.end) - x(segment.start),
                              height: track.height - 12)
            let isSelected = i == selected
            let bar = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.withAlphaComponent(isSelected ? 0.95 : 0.55).setFill()
            bar.fill()
            if isSelected {
                NSColor.white.setFill()
                for edge in [rect.minX + 3, rect.maxX - 6] {
                    NSBezierPath(roundedRect: CGRect(x: edge, y: rect.midY - 8, width: 3, height: 16), xRadius: 1.5, yRadius: 1.5).fill()
                }
            }
            let label = String(format: "%.1f×", segment.scale) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                        .foregroundColor: NSColor.white]
            let size = label.size(withAttributes: attrs)
            if size.width + 20 < rect.width {
                label.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
            }
        }

        // Click markers.
        NSColor.systemOrange.setFill()
        for click in clicks where duration > 0 {
            NSBezierPath(ovalIn: CGRect(x: x(click.t) - 3, y: track.maxY - 8, width: 6, height: 6)).fill()
        }

        // Playhead.
        if duration > 0 {
            NSColor.labelColor.setFill()
            NSRect(x: x(playhead) - 1, y: bounds.minY + 2, width: 2, height: bounds.height - 4).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let t = time(p.x)
        if event.clickCount == 2, !segments.contains(where: { t >= $0.start && t <= $0.end }) {
            onAdd?(t)
            return
        }
        dragOriginal = segments
        if let i = segments.firstIndex(where: { abs(x($0.start) - p.x) < 7 }) {
            drag = .start(i); onSelect?(i)
        } else if let i = segments.firstIndex(where: { abs(x($0.end) - p.x) < 7 }) {
            drag = .end(i); onSelect?(i)
        } else if let i = segments.firstIndex(where: { t >= $0.start && t <= $0.end }) {
            drag = .move(i, grab: t - segments[i].start); onSelect?(i)
        } else {
            drag = .seek
            onSelect?(nil)
            onSeek?(t)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let t = time(convert(event.locationInWindow, from: nil).x)
        var s = dragOriginal
        switch drag {
        case .seek?:
            onSeek?(t)
            return
        case .move(let i, let grab)?:
            let length = s[i].duration
            let lower = i > 0 ? s[i - 1].end : 0
            let upper = i < s.count - 1 ? s[i + 1].start : duration
            let start = min(max(t - grab, lower), upper - length)
            s[i].start = start
            s[i].end = start + length
        case .start(let i)?:
            let lower = i > 0 ? s[i - 1].end : 0
            s[i].start = min(max(t, lower), s[i].end - ZoomPlan.minLength)
        case .end(let i)?:
            let upper = i < s.count - 1 ? s[i + 1].start : duration
            s[i].end = max(min(t, upper), s[i].start + ZoomPlan.minLength)
        case nil:
            return
        }
        onChange?(s)
    }

    override func mouseUp(with event: NSEvent) { drag = nil }

    override func resetCursorRects() {
        for segment in segments {
            for edge in [segment.start, segment.end] {
                addCursorRect(CGRect(x: x(edge) - 6, y: track.minY, width: 12, height: track.height), cursor: .resizeLeftRight)
            }
        }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        window?.invalidateCursorRects(for: self)
    }
}
