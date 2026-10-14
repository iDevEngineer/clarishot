import AppKit
import UniformTypeIdentifiers

/// Runs each capture mode from start to finish.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var overlay: SelectionOverlayController?
    /// The last area captured. Saved, so Capture Previous Area works after Clarishot restarts.
    private var lastArea: (displayID: CGDirectDisplayID, rect: CGRect)? {
        get {
            guard let d = UserDefaults.standard.dictionary(forKey: "lastCaptureArea"),
                  let id = d["display"] as? UInt32, let rect = d["rect"] as? String else { return nil }
            return (id, NSRectFromString(rect))
        }
        set {
            guard let newValue else { UserDefaults.standard.removeObject(forKey: "lastCaptureArea"); return }
            UserDefaults.standard.set(["display": newValue.displayID, "rect": NSStringFromRect(newValue.rect)],
                                      forKey: "lastCaptureArea")
        }
    }
    /// All-In-One remembers its last selection.
    private var lastAllInOne: (displayID: CGDirectDisplayID, rect: CGRect)?

    var hasPreviousArea: Bool { lastArea != nil }

    // MARK: Capture modes

    func captureArea() {
        selectArea { [weak self] capture in self?.deliver(capture) }
    }

    enum AreaAction { case copy, save, annotate, pin }

    /// Capture Area followed by one fixed action instead of the After Capture settings.
    func captureArea(then action: AreaAction) {
        selectArea { capture in
            let capture = capture.finishedForExport()
            if Settings.shared.playSounds { CaptureSound.play() }
            HistoryStore.shared.add(capture)
            switch action {
            case .copy:
                capture.copyToClipboard()
                Toast.show("Copied to clipboard")
            case .save:
                if (try? capture.save()) != nil { Toast.show(Capture.savedMessage) }
            case .annotate: AnnotateWindowController.open(capture)
            case .pin: PinWindow.pin(capture)
            }
        }
    }

    func captureText() {
        selectArea { [weak self] capture in self?.copyText(from: capture) }
    }

    private func copyText(from capture: Capture) {
        Task {
            let text = await ScreenCapturer.recognizeText(in: capture.image)
            guard !text.isEmpty else { Toast.show("No text or QR code found"); return }
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
                present(shots, mode: .allInOne, targets: [],
                        initial: Settings.shared.allInOneRemember ? lastAllInOne : nil) { [weak self] result in
                    guard let self, case let .allInOne(shot, rect, action)? = result else { return }
                    let display = ScreenCapturer.displayID(for: shot.screen)
                    self.lastAllInOne = (display, rect)
                    self.lastArea = (display, rect)
                    switch action {
                    case .screenshot:
                        guard let image = ScreenCapturer.crop(shot, to: rect) else { return }
                        self.deliver(Capture(image: image, scale: shot.screen.backingScaleFactor)
                            .from(SourceApp.under(rect, on: shot.screen)))
                    case .text:
                        guard let image = ScreenCapturer.crop(shot, to: rect) else { return }
                        self.copyText(from: Capture(image: image, scale: shot.screen.backingScaleFactor))
                    case .scrolling:
                        ScrollCaptureCoordinator.shared.begin(screen: shot.screen, rect: rect)
                    case .record:
                        RecordingCoordinator.shared.showSetup(screen: shot.screen, rect: rect)
                    case .timer:
                        self.timedCapture(screen: shot.screen, rect: rect)
                    case .fullscreen:
                        self.captureFullscreen()
                    case .window:
                        self.captureWindow()
                    case .smart:
                        self.captureSmart()
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
        selectRegion(hint: "Drag an area — Clarishot will capture it after \(Settings.shared.selfTimerSeconds) seconds.") { [weak self] shot, rect in
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
                deliver(Capture(image: image, scale: screen.backingScaleFactor).from(SourceApp.under(rect, on: screen)))
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
                var image = shot.image
                if Settings.shared.fullscreenOnWallpaper {
                    await Wallpaper.refresh()
                    var style = BackgroundStyle()
                    style.enabled = true
                    style.fillIndex = BackgroundFill.presets.count - 1 // wallpaper
                    style.padding = 32
                    style.cornerRadius = 14
                    image = BackgroundRenderer.compose(image, scale: shot.screen.backingScaleFactor, style: style) ?? image
                }
                deliver(Capture(image: image, scale: shot.screen.backingScaleFactor).from(SourceApp.frontmost()))
            } catch {
                showCaptureError(error)
            }
        }
    }

    func capturePreviousArea() {
        // Nothing captured yet: pick an area instead (it becomes the previous area).
        guard let lastArea else { return captureArea() }
        Task {
            // Let the menu (if it was used) finish fading so it isn't in the shot.
            try? await Task.sleep(nanoseconds: 150_000_000)
            do {
                let shots = try await ScreenCapturer.captureAllScreens()
                // The screen it was on may be unplugged; then pick a new area.
                guard let shot = shots.first(where: { ScreenCapturer.displayID(for: $0.screen) == lastArea.displayID }),
                      let image = ScreenCapturer.crop(shot, to: lastArea.rect) else {
                    Toast.show("That screen isn't connected. Select an area.")
                    return captureArea()
                }
                deliver(Capture(image: image, scale: shot.screen.backingScaleFactor)
                    .from(SourceApp.under(lastArea.rect, on: shot.screen)))
            } catch {
                showCaptureError(error)
            }
        }
    }

    /// Smart Capture: hover an element of any app, click to capture just that element.
    func captureSmart() {
        SmartCaptureController.shared.start { [weak self] result in
            guard let self, case let .success((screen, rect, bundle)) = result else { return }
            Task {
                try? await Task.sleep(nanoseconds: 120_000_000) // let the outline leave the screen
                do {
                    let shots = try await ScreenCapturer.captureAllScreens()
                    guard let shot = shots.first(where: { $0.screen == screen }),
                          let image = ScreenCapturer.crop(shot, to: rect) else { return }
                    self.lastArea = (ScreenCapturer.displayID(for: screen), rect)
                    self.deliver(Capture(image: image, scale: screen.backingScaleFactor).from(bundle))
                } catch {
                    self.showCaptureError(error)
                }
            }
        }
    }

    /// Object cutout: select an area, keep only its main subject on a transparent background.
    func captureCutout() {
        selectRegion(hint: "Drag around the object to cut out.") { [weak self] shot, rect in
            guard let self, let image = ScreenCapturer.crop(shot, to: rect) else { return }
            Task {
                guard let cut = await BackgroundRemover.removeBackgroundAsync(image) else {
                    Toast.show("No clear subject found to cut out")
                    return
                }
                self.deliver(Capture(image: cut, scale: shot.screen.backingScaleFactor)
                    .from(SourceApp.under(rect, on: shot.screen)))
            }
        }
    }

    /// Capture & Annotate: select an area and edit it before anything is saved or copied;
    /// Done then runs the normal after-capture actions.
    func captureAndAnnotate() {
        selectArea { [weak self] capture in
            AnnotateWindowController.open(capture) { edited in self?.deliver(edited) }
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

    /// Runs the after-capture actions from Preferences → Screenshots for a finished screenshot.
    func deliver(_ original: Capture) {
        let settings = Settings.shared
        var capture = settings.scaleScreenshotsTo1x ? original.scaledTo1x() : original
        if !capture.isVideo, let name = settings.autoBackgroundPreset, let style = BackgroundPresets.style(named: name),
           let framed = BackgroundRenderer.compose(capture.image, scale: capture.scale, style: style) {
            capture = Capture(image: framed, scale: capture.scale).from(capture.sourceBundleID)
        }
        capture = capture.finishedForExport()
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
            } catch let error as CocoaError where error.code == .userCancelled {
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if settings.afterCapturePin {
            PinWindow.pin(capture)
            acted = true
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
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .webP, .clarishotProject]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.pathExtension.lowercased() == "clarishot" { return AnnotateWindowController.openProject(url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let scale: CGFloat = url.deletingPathExtension().lastPathComponent.hasSuffix("@2x") ? 2 : 1
        AnnotateWindowController.open(Capture(image: image, scale: scale))
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
            handle(Capture(image: image, scale: shot.screen.backingScaleFactor).from(SourceApp.under(rect, on: shot.screen)))
        }
    }

    /// Shows the area overlay and reports the chosen screen and rectangle (screen-local points).
    /// `hint` is shown at the top of the screen, e.g. "Drag to capture the scrolling part of the screen."
    /// `allowsWindowPick`: Space switches to clicking a whole window, reported as its area.
    func selectRegion(hint: String? = nil, allowsWindowPick: Bool = false,
                      then handle: @escaping (ScreenShot, CGRect) -> Void,
                      onCancel: (() -> Void)? = nil) {
        guard overlay == nil else { onCancel?(); return }
        Task {
            do {
                let targets = allowsWindowPick ? ScreenCapturer.windowTargets() : []
                let shots = try await ScreenCapturer.captureAllScreens()
                present(shots, mode: .area, targets: targets, hint: hint, allowsWindowPick: allowsWindowPick) { result in
                    guard case let .area(shot, rect)? = result else { onCancel?(); return }
                    handle(shot, rect)
                }
            } catch {
                showCaptureError(error)
                onCancel?()
            }
        }
    }

    private func present(_ shots: [ScreenShot], mode: SelectionMode, targets: [WindowTarget], hint: String? = nil,
                         allowsWindowPick: Bool = false,
                         initial: (displayID: CGDirectDisplayID, rect: CGRect)? = nil,
                         completion: @escaping (SelectionResult?) -> Void) {
        let controller = SelectionOverlayController(shots: shots, mode: mode, targets: targets, hint: hint,
                                                    allowsWindowPick: allowsWindowPick,
                                                    initial: initial) { [weak self] result in
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
                if Settings.shared.windowStyle == .background { await Wallpaper.refresh() }
                let framed = BackgroundRenderer.frameWindow(image, scale: scale, style: Settings.shared.windowStyle)
                deliver(Capture(image: framed ?? image, scale: scale).from(SourceApp.owner(of: id)))
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

    func showCaptureError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if CGPreflightScreenCaptureAccess() {
            alert.messageText = "Capture failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        alert.messageText = "Clarishot needs Screen Recording permission"
        alert.informativeText = "Turn on Clarishot in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
