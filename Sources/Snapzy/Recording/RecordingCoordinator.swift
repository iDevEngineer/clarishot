import AppKit
import AVFoundation

/// Runs a screen recording: pick an area, set options, count down, record
/// (with pause/restart/discard), stop, preview.
@MainActor
final class RecordingCoordinator {
    static let shared = RecordingCoordinator()

    private var options = RecordingOptions.load()
    private var setupPanel: RecordingSetupPanel?
    private var outline: RegionOutlineWindow?
    private var controlBar: RecordingControlBar?
    private var camera: CameraBubble?
    private var clicks: ClickHighlightWindow?
    private var keys: KeystrokeWindow?
    private var recorder: AnyObject? // ScreenRecorder (macOS 15+)
    private var tick: Timer?
    private var hidIconsForRecording = false
    private var format: RecordingFormat = .video
    private var region: (screen: NSScreen, rect: CGRect)?
    private var busy = false

    var isRecording: Bool { recorder != nil }

    /// Menu item / shortcut: starts the flow, or stops a recording in progress.
    func toggle() {
        if isRecording { stop(); return }
        guard setupPanel == nil, !busy else { return }
        guard #available(macOS 15.0, *) else {
            let alert = NSAlert()
            alert.messageText = "Screen recording needs macOS 15 or later"
            alert.runModal()
            return
        }
        chooseArea()
    }

    private func chooseArea() {
        CaptureCoordinator.shared.selectRegion { [weak self] shot, rect in
            self?.showSetup(screen: shot.screen, rect: rect)
        }
    }

    /// The recorded area in global screen coordinates.
    private var globalRect: CGRect? {
        guard let region else { return nil }
        return region.rect.offsetBy(dx: region.screen.frame.minX, dy: region.screen.frame.minY)
    }

    // MARK: Setup

    private func showSetup(screen: NSScreen, rect: CGRect) {
        region = (screen, rect)
        guard let globalRect else { return }
        let outline = RegionOutlineWindow(rect: globalRect)
        outline.orderFrontRegardless()
        self.outline = outline

        let panel = RecordingSetupPanel(options: options, size: rect.size)
        panel.onOptionsChange = { [weak self] new in self?.optionsChanged(new) }
        panel.onSizeChange = { [weak self] size in self?.resize(to: size) }
        panel.onFullscreen = { [weak self] in self?.useFullScreen() }
        panel.onReselect = { [weak self] in self?.reselect() }
        panel.onRecord = { [weak self] format in self?.beginRecording(format) }
        panel.onCancel = { [weak self] in self?.cancelSetup() }
        panel.place(near: globalRect, on: screen)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        setupPanel = panel

        if options.camera { showCamera() }
    }

    private func optionsChanged(_ new: RecordingOptions) {
        let old = options
        options = new
        options.save()
        let cameraLookChanged = new.cameraSize != old.cameraSize || new.cameraRounded != old.cameraRounded
            || new.cameraMirrored != old.cameraMirrored || new.cameraDeviceID != old.cameraDeviceID
        if new.camera != old.camera || (new.camera && cameraLookChanged) {
            hideCamera()
            if new.camera { showCamera() }
        }
        if new.showKeystrokes && !old.showKeystrokes && !KeystrokeWindow.ensurePermission() {
            Toast.show("Allow Snapzy in Accessibility settings to show keystrokes")
        }
    }

    private func resize(to size: CGSize) {
        guard let region else { return }
        let bounds = CGRect(origin: .zero, size: region.screen.frame.size)
        // Keep the top-left corner where it is.
        var rect = CGRect(x: region.rect.minX, y: region.rect.maxY - size.height, width: size.width, height: size.height)
        rect.size.width = min(rect.width, bounds.width)
        rect.size.height = min(rect.height, bounds.height)
        rect.origin.x = min(max(rect.minX, 0), bounds.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, 0), bounds.maxY - rect.height)
        applyRegion(rect.integral)
    }

    private func useFullScreen() {
        guard let region else { return }
        applyRegion(CGRect(origin: .zero, size: region.screen.frame.size))
    }

    private func applyRegion(_ rect: CGRect) {
        guard let screen = region?.screen else { return }
        region = (screen, rect)
        guard let globalRect else { return }
        outline?.setRegion(globalRect)
        setupPanel?.updateSize(rect.size)
        setupPanel?.place(near: globalRect, on: screen)
        camera?.place(in: globalRect)
    }

    private func reselect() {
        hideCamera()
        closeSetupWindows()
        region = nil
        chooseArea()
    }

    private func cancelSetup() {
        hideCamera()
        closeSetupWindows()
        region = nil
    }

    private func closeSetupWindows() {
        setupPanel?.orderOut(nil)
        setupPanel = nil
        outline?.orderOut(nil)
        outline = nil
    }

    private func showCamera() {
        guard camera == nil, let globalRect else { return }
        let bubble = CameraBubble(options: options)
        bubble.place(in: globalRect)
        camera = bubble
        Task {
            if await bubble.start() {
                bubble.orderFrontRegardless()
            } else {
                camera = nil
                options.camera = false
                options.save()
                Toast.show("Camera unavailable — check Camera access in System Settings")
            }
        }
    }

    private func hideCamera() {
        camera?.stop()
        camera = nil
    }

    // MARK: Recording

    private func beginRecording(_ format: RecordingFormat) {
        guard #available(macOS 15.0, *), globalRect != nil else { return }
        self.format = format
        setupPanel?.orderOut(nil)
        setupPanel = nil
        busy = true
        Task {
            if options.microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                options.microphone = false
                Toast.show("Microphone access is off — recording without it")
            }
            await startRecorder()
        }
    }

    /// Counts down (if on), then starts a fresh recorder for the current area.
    @available(macOS 15.0, *)
    private func startRecorder() async {
        guard let region, let globalRect else { busy = false; return }
        if options.countdown {
            let countdown = CountdownWindow(centeredIn: globalRect)
            guard await countdown.run() else { busy = false; cancelAll(); return }
        }

        if options.hideDesktopIcons && !DesktopIconHider.shared.isHiding {
            DesktopIconHider.shared.hide()
            hidIconsForRecording = true
        }
        var included: [NSWindow] = DesktopIconHider.shared.windows
        if let camera { included.append(camera) }
        if options.highlightClicks, clicks == nil {
            let window = ClickHighlightWindow(rect: globalRect)
            window.orderFrontRegardless()
            window.startMonitoring()
            clicks = window
        }
        if let clicks { included.append(clicks) }
        if options.showKeystrokes, keys == nil, AXIsProcessTrusted() {
            let window = KeystrokeWindow(rect: globalRect)
            window.orderFrontRegardless()
            window.startMonitoring()
            keys = window
        }
        if let keys { included.append(keys) }

        let recorder = ScreenRecorder(screen: region.screen, rect: region.rect, options: options)
        recorder.includedWindows = included
        recorder.onUnexpectedStop = { [weak self] error in self?.handleFailure(error) }
        do {
            try await recorder.start()
        } catch {
            busy = false
            handleFailure(error)
            return
        }
        self.recorder = recorder
        busy = false
        outline?.setRecording(true)
        showControls(for: recorder)
    }

    @available(macOS 15.0, *)
    private func showControls(for recorder: ScreenRecorder) {
        guard let region, let globalRect else { return }
        if controlBar == nil, Settings.shared.showControlsWhileRecording {
            let bar = RecordingControlBar()
            bar.onStop = { [weak self] in self?.stop() }
            bar.onPauseToggle = { [weak self] in self?.togglePause() }
            bar.onRestart = { [weak self] in self?.restart() }
            bar.onDiscard = { [weak self] in self?.discard() }
            bar.place(below: globalRect, on: region.screen)
            bar.orderFrontRegardless()
            controlBar = bar
        }
        StatusMenuController.shared?.showRecording(elapsed: { recorder.elapsed }) { [weak self] in self?.stop() }
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.controlBar?.update(elapsed: recorder.elapsed, paused: recorder.isPaused) }
        }
        controlBar?.update(elapsed: recorder.elapsed, paused: recorder.isPaused)
    }

    func togglePause() {
        guard #available(macOS 15.0, *), let recorder = recorder as? ScreenRecorder, !busy else { return }
        busy = true
        Task {
            if recorder.isPaused {
                do { try await recorder.resume() } catch { handleFailure(error) }
                outline?.setRecording(true)
            } else {
                await recorder.pause()
                outline?.setRecording(false)
            }
            busy = false
            controlBar?.update(elapsed: recorder.elapsed, paused: recorder.isPaused)
        }
    }

    private func restart() {
        guard #available(macOS 15.0, *), let recorder = recorder as? ScreenRecorder, !busy else { return }
        busy = true
        Task {
            await recorder.discard()
            self.recorder = nil
            outline?.setRecording(false)
            await startRecorder()
        }
    }

    private func discard() {
        guard #available(macOS 15.0, *), let recorder = recorder as? ScreenRecorder, !busy else { return }
        busy = true
        Task {
            await recorder.discard()
            busy = false
            cancelAll()
            Toast.show("Recording discarded")
        }
    }

    func stop() {
        guard #available(macOS 15.0, *), let recorder = recorder as? ScreenRecorder, !busy else { return }
        busy = true
        StatusMenuController.shared?.showSaving()
        let format = self.format
        Task {
            do {
                let url = try await recorder.finish()
                busy = false
                cancelAll()
                showPreview(for: url, format: format)
            } catch {
                busy = false
                handleFailure(error)
            }
        }
    }

    private func handleFailure(_ error: Error) {
        cancelAll()
        showError(error)
    }

    /// Removes every recording window and restores the menu-bar icon.
    private func cancelAll() {
        recorder = nil
        tick?.invalidate()
        tick = nil
        controlBar?.orderOut(nil)
        controlBar = nil
        clicks?.stopMonitoring()
        clicks = nil
        keys?.stopMonitoring()
        keys = nil
        hideCamera()
        closeSetupWindows()
        region = nil
        if hidIconsForRecording {
            DesktopIconHider.shared.show()
            hidIconsForRecording = false
        }
        StatusMenuController.shared?.endRecording()
    }

    private func showPreview(for url: URL, format: RecordingFormat) {
        Task {
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 800, height: 800)
            guard duration > 0, let (thumbnail, _) = try? await generator.image(at: .zero) else {
                Toast.show("The recording could not be saved")
                return
            }
            var fileURL = url
            if format == .gif {
                guard let gif = await Self.makeGIF(from: url) else { return }
                fileURL = gif
            }
            PreviewManager.shared.show(Capture(videoURL: fileURL, thumbnail: thumbnail, scale: 1, duration: duration,
                                               sourceVideoURL: format == .gif ? url : nil))
        }
    }

    /// Converts a movie to GIF with a progress popup. Returns nil on failure.
    static func makeGIF(from url: URL) async -> URL? {
        let hud = ProgressHUD(title: "Making GIF…")
        hud.orderFrontRegardless()
        defer { hud.orderOut(nil) }
        do {
            return try await GIFExporter.convert(url) { fraction in
                DispatchQueue.main.async { MainActor.assumeIsolated { hud.update(fraction) } }
            }
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Recording failed"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

// MARK: - Area outline

/// A click-through frame drawn just outside the recorded area.
/// Dashed white while setting up or paused, solid red while recording.
@MainActor
final class RegionOutlineWindow: NSWindow {
    private static let border: CGFloat = 3
    private let outlineView = OutlineView()

    init(rect: CGRect) {
        let frame = rect.insetBy(dx: -Self.border, dy: -Self.border)
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        outlineView.frame = CGRect(origin: .zero, size: frame.size)
        outlineView.autoresizingMask = [.width, .height]
        contentView = outlineView
    }

    func setRegion(_ rect: CGRect) {
        setFrame(rect.insetBy(dx: -Self.border, dy: -Self.border), display: true)
    }

    func setRecording(_ recording: Bool) {
        outlineView.recording = recording
    }

    private final class OutlineView: NSView {
        var recording = false { didSet { needsDisplay = true } }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 2
            if recording {
                NSColor.systemRed.withAlphaComponent(0.9).setStroke()
            } else {
                NSColor.white.withAlphaComponent(0.9).setStroke()
                path.setLineDash([6, 4], count: 2, phase: 0)
            }
            path.stroke()
        }
    }
}
