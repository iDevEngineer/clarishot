import AppKit
import UniformTypeIdentifiers

/// Runs each capture mode from start to finish.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var overlay: SelectionOverlayController?
    private var lastArea: (displayID: CGDirectDisplayID, rect: CGRect)?
    /// All-In-One remembers its last selection.
    private var lastAllInOne: (displayID: CGDirectDisplayID, rect: CGRect)?

    var hasPreviousArea: Bool { lastArea != nil }

    // MARK: Capture modes

    func captureArea() {
        selectArea { [weak self] capture in self?.deliver(capture) }
    }

    func captureText() {
        selectArea { [weak self] capture in self?.copyText(from: capture) }
    }

    private func copyText(from capture: Capture) {
        Task {
            let text = await ScreenCapturer.recognizeText(in: capture.image)
            guard !text.isEmpty else { Toast.show("No text found"); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Toast.show("Text copied to clipboard")
        }
    }

    /// One shortcut for everything: pick (or adjust the remembered) area, then choose
    /// screenshot, text, scrolling, record or self-timer from the bar.
    func allInOne() {
        guard overlay == nil else { return }
        Task {
            do {
                let shots = try await ScreenCapturer.captureAllScreens()
                present(shots, mode: .allInOne, targets: [], initial: lastAllInOne) { [weak self] result in
                    guard let self, case let .allInOne(shot, rect, action)? = result else { return }
                    let display = ScreenCapturer.displayID(for: shot.screen)
                    self.lastAllInOne = (display, rect)
                    self.lastArea = (display, rect)
                    switch action {
                    case .screenshot:
                        guard let image = ScreenCapturer.crop(shot, to: rect) else { return }
                        self.deliver(Capture(image: image, scale: shot.screen.backingScaleFactor))
                    case .text:
                        guard let image = ScreenCapturer.crop(shot, to: rect) else { return }
                        self.copyText(from: Capture(image: image, scale: shot.screen.backingScaleFactor))
                    case .scrolling:
                        ScrollCaptureCoordinator.shared.begin(screen: shot.screen, rect: rect)
                    case .record:
                        RecordingCoordinator.shared.showSetup(screen: shot.screen, rect: rect)
                    case .timer:
                        self.timedCapture(screen: shot.screen, rect: rect)
                    }
                }
            } catch {
                showCaptureError(error)
            }
        }
    }

    /// The scrolling-capture selection: dimmed screen, adjustable area, Start Capture pill.
    func selectScrollingArea(then handle: @escaping (ScreenShot, CGRect) -> Void) {
        guard overlay == nil else { return }
        Task {
            do {
                let shots = try await ScreenCapturer.captureAllScreens()
                present(shots, mode: .scrollArea, targets: [],
                        hint: "Drag to capture the scrolling part of the screen.") { result in
                    guard case let .allInOne(shot, rect, _)? = result else { return }
                    handle(shot, rect)
                }
            } catch {
                showCaptureError(error)
            }
        }
    }

    /// Pick an area, wait (Settings → Screenshots), then capture what's there at that moment.
    func selfTimer() {
        selectRegion(hint: "Drag an area — Snapzy will capture it after \(Settings.shared.selfTimerSeconds) seconds.") { [weak self] shot, rect in
            self?.timedCapture(screen: shot.screen, rect: rect)
        }
    }

    private func timedCapture(screen: NSScreen, rect: CGRect) {
        let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        Task {
            let countdown = CountdownWindow(centeredIn: global)
            guard await countdown.run(seconds: Settings.shared.selfTimerSeconds) else { return }
            try? await Task.sleep(nanoseconds: 150_000_000) // let the countdown fade from the screen
            do {
                let shots = try await ScreenCapturer.captureAllScreens()
                guard let shot = shots.first(where: { $0.screen == screen }) ?? shots.first,
                      let image = ScreenCapturer.crop(shot, to: rect) else { return }
                lastArea = (ScreenCapturer.displayID(for: screen), rect)
                deliver(Capture(image: image, scale: screen.backingScaleFactor))
            } catch {
                showCaptureError(error)
            }
        }
    }

    func captureFullscreen() {
        Task {
            do {
                let shots = try await ScreenCapturer.captureAllScreens()
                let mouse = NSEvent.mouseLocation
                guard let shot = shots.first(where: { $0.screen.frame.contains(mouse) }) ?? shots.first else { return }
                deliver(Capture(image: shot.image, scale: shot.screen.backingScaleFactor))
            } catch {
                showCaptureError(error)
            }
        }
    }

    func capturePreviousArea() {
        guard let lastArea else { return }
        Task {
            do {
                let shots = try await ScreenCapturer.captureAllScreens()
                guard let shot = shots.first(where: { ScreenCapturer.displayID(for: $0.screen) == lastArea.displayID }),
                      let image = ScreenCapturer.crop(shot, to: lastArea.rect) else { return }
                deliver(Capture(image: image, scale: shot.screen.backingScaleFactor))
            } catch {
                showCaptureError(error)
            }
        }
    }

    func captureWindow() {
        guard overlay == nil else { return }
        Task {
            do {
                let targets = ScreenCapturer.windowTargets()
                let shots = try await ScreenCapturer.captureAllScreens()
                present(shots, mode: .window, targets: targets) { [weak self] result in
                    guard case let .window(id)? = result else { return }
                    self?.finishWindowCapture(id)
                }
            } catch {
                showCaptureError(error)
            }
        }
    }

    // MARK: After capture

    /// Runs the after-capture actions from Settings → Screenshots for a finished screenshot.
    func deliver(_ original: Capture) {
        let settings = Settings.shared
        var capture = settings.scaleScreenshotsTo1x ? original.scaledTo1x() : original
        if !capture.isVideo, let name = settings.autoBackgroundPreset, let style = BackgroundPresets.style(named: name),
           let framed = BackgroundRenderer.compose(capture.image, scale: capture.scale, style: style) {
            capture = Capture(image: framed, scale: capture.scale)
        }
        if settings.playSounds { CaptureSound.play() }
        HistoryStore.shared.add(capture)
        var acted = false
        if settings.afterCaptureCopy {
            capture.copyToClipboard()
            acted = true
        }
        if settings.afterCaptureSave {
            do {
                try capture.save()
                acted = true
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if settings.afterCaptureAnnotate {
            AnnotateWindowController.open(capture)
            acted = true
        }
        if settings.afterCaptureShowPreview || !acted {
            PreviewManager.shared.show(capture)
        } else if settings.afterCaptureSave {
            Toast.show(settings.afterCaptureCopy ? "Copied and saved" : "Saved")
        } else if settings.afterCaptureCopy {
            Toast.show("Copied to clipboard")
        }
    }

    // MARK: Files

    func openImage() {
        guard let capture = chooseImage() else { return }
        AnnotateWindowController.open(capture)
    }

    func pinImageFromFile() {
        guard let capture = chooseImage() else { return }
        PinWindow.pin(capture)
    }

    // MARK: Helpers

    private func selectArea(then handle: @escaping (Capture) -> Void) {
        selectRegion { [weak self] shot, rect in
            guard let image = ScreenCapturer.crop(shot, to: rect) else { return }
            self?.lastArea = (ScreenCapturer.displayID(for: shot.screen), rect)
            handle(Capture(image: image, scale: shot.screen.backingScaleFactor))
        }
    }

    /// Shows the area overlay and reports the chosen screen and rectangle (screen-local points).
    /// `hint` is shown at the top of the screen, e.g. "Drag to capture the scrolling part of the screen."
    func selectRegion(hint: String? = nil, then handle: @escaping (ScreenShot, CGRect) -> Void) {
        guard overlay == nil else { return }
        Task {
            do {
                let shots = try await ScreenCapturer.captureAllScreens()
                present(shots, mode: .area, targets: [], hint: hint) { result in
                    guard case let .area(shot, rect)? = result else { return }
                    handle(shot, rect)
                }
            } catch {
                showCaptureError(error)
            }
        }
    }

    private func present(_ shots: [ScreenShot], mode: SelectionMode, targets: [WindowTarget], hint: String? = nil,
                         initial: (displayID: CGDirectDisplayID, rect: CGRect)? = nil,
                         completion: @escaping (SelectionResult?) -> Void) {
        let controller = SelectionOverlayController(shots: shots, mode: mode, targets: targets,
                                                    hint: hint, initial: initial) { [weak self] result in
            self?.overlay = nil
            completion(result)
        }
        overlay = controller
        controller.show()
    }

    private func finishWindowCapture(_ id: CGWindowID) {
        Task {
            do {
                let (image, scale) = try await ScreenCapturer.captureWindow(id: id)
                let framed = BackgroundRenderer.frameWindow(image, scale: scale, style: Settings.shared.windowStyle)
                deliver(Capture(image: framed ?? image, scale: scale))
            } catch {
                showCaptureError(error)
            }
        }
    }

    private func chooseImage() -> Capture? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .webP]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let scale: CGFloat = url.deletingPathExtension().lastPathComponent.hasSuffix("@2x") ? 2 : 1
        return Capture(image: image, scale: scale)
    }

    private func showCaptureError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if CGPreflightScreenCaptureAccess() {
            alert.messageText = "Capture failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        alert.messageText = "Snapzy needs Screen Recording permission"
        alert.informativeText = "Turn on Snapzy in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
