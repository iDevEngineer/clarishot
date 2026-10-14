import AppKit

/// The menu-bar icon and its menu.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    static private(set) weak var shared: StatusMenuController?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var previousAreaItem: NSMenuItem?
    private var menu: NSMenu?
    private var desktopIconsItem: NSMenuItem?
    private var restoreItem: NSMenuItem?
    /// Menu items whose shortcut comes from Settings.
    private var actionItems: [(NSMenuItem, ShortcutAction)] = []
    private var recordingTimer: Timer?
    private var onStopRecording: (() -> Void)?

    override init() {
        super.init()
        let image: NSImage? = AppIcon.menuBar()
        statusItem.button?.image = image
        let menu = buildMenu()
        self.menu = menu
        statusItem.menu = menu
        Self.shared = self
        applyVisibility()
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyVisibility() }
        }
    }

    /// "Show menu bar icon" off hides it, except while recording (the stop button lives there).
    private func applyVisibility() {
        statusItem.isVisible = Settings.shared.showMenuBarIcon || onStopRecording != nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        add(menu, "All-In-One", symbol: "1.circle", action: #selector(allInOne), shortcut: .allInOne)
        add(menu, "Capture Area", symbol: "viewfinder", action: #selector(captureArea), shortcut: .captureArea)
        previousAreaItem = add(menu, "Capture Previous Area", symbol: "arrow.clockwise",
                               action: #selector(capturePreviousArea), shortcut: .capturePreviousArea)
        add(menu, "Capture Fullscreen", symbol: "display", action: #selector(captureFullscreen), shortcut: .captureFullscreen)
        add(menu, "Capture Window", symbol: "macwindow", action: #selector(captureWindow), shortcut: .captureWindow)
        add(menu, "Smart Capture", symbol: "cursorarrow.rays", action: #selector(smartCapture), shortcut: .smartCapture)
        add(menu, "Capture Object", symbol: "scissors", action: #selector(objectCutout),
            shortcut: .objectCutout)
        add(menu, "Capture & Annotate", symbol: "pencil.and.outline", action: #selector(captureAndAnnotate),
            shortcut: .captureAreaAnnotate)
        add(menu, "Scrolling Capture", symbol: "arrow.down", action: #selector(scrollingCapture), shortcut: .scrollingCapture)
        add(menu, "Self-Timer", symbol: "timer", action: #selector(selfTimer), shortcut: .selfTimer)
        add(menu, "Capture Text (OCR)", symbol: "textformat", action: #selector(captureText), shortcut: .captureText)
        add(menu, "Record Screen", symbol: "video", action: #selector(recordScreen), shortcut: .recordScreen)
        menu.addItem(.separator())
        desktopIconsItem = add(menu, "Hide Desktop Icons", symbol: "eye.slash", action: #selector(toggleDesktopIcons))
        menu.addItem(.separator())
        add(menu, "Open...", symbol: "pencil", action: #selector(openImage))
        add(menu, "Pin to the Screen...", symbol: "pin", action: #selector(pinImage))
        menu.addItem(.separator())
        add(menu, "Capture History...", symbol: "clock.arrow.circlepath", action: #selector(openHistory))
        restoreItem = add(menu, "Restore Recently Closed", symbol: "arrow.uturn.backward", action: #selector(restoreClosed))
        menu.addItem(.separator())
        add(menu, "About Clarishot", symbol: nil, action: #selector(about))
        menu.addItem(.separator())
        let settings = add(menu, "Preferences...", symbol: nil, action: #selector(openSettings))
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        menu.addItem(.separator())
        add(menu, "Quit", symbol: nil, action: #selector(quit))
        return menu
    }

    /// Adds a menu item. Items without an action are shown disabled (not built yet).
    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, symbol: String?, action: Selector?,
                     shortcut: ShortcutAction? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = action != nil
        if let shortcut {
            actionItems.append((item, shortcut))
            applyShortcut(to: item, shortcut)
        }
        if let symbol {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        }
        menu.addItem(item)
        return item
    }

    private func applyShortcut(to item: NSMenuItem, _ action: ShortcutAction) {
        let shortcut = Settings.shared.shortcut(for: action)
        item.keyEquivalent = shortcut?.key ?? ""
        item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for (item, action) in actionItems { applyShortcut(to: item, action) }
        restoreItem?.isEnabled = PreviewManager.shared.canRestore
        let hiding = DesktopIconHider.shared.isHiding
        desktopIconsItem?.title = hiding ? "Show Desktop Icons" : "Hide Desktop Icons"
        desktopIconsItem?.image = NSImage(systemSymbolName: hiding ? "eye" : "eye.slash", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    }

    @objc private func allInOne() { CaptureCoordinator.shared.allInOne() }
    @objc private func selfTimer() { CaptureCoordinator.shared.selfTimer() }
    @objc private func captureArea() { CaptureCoordinator.shared.captureArea() }
    @objc private func capturePreviousArea() { CaptureCoordinator.shared.capturePreviousArea() }
    @objc private func captureFullscreen() { CaptureCoordinator.shared.captureFullscreen() }
    @objc private func captureWindow() { CaptureCoordinator.shared.captureWindow() }
    @objc private func smartCapture() { CaptureCoordinator.shared.captureSmart() }
    @objc private func objectCutout() { CaptureCoordinator.shared.captureCutout() }
    @objc private func captureAndAnnotate() { CaptureCoordinator.shared.captureAndAnnotate() }
    @objc private func captureText() { CaptureCoordinator.shared.captureText() }
    @objc private func scrollingCapture() { ScrollCaptureCoordinator.shared.start() }
    @objc private func toggleDesktopIcons() { DesktopIconHider.shared.toggle() }
    @objc private func recordScreen() { RecordingCoordinator.shared.toggle() }
    @objc private func openImage() { CaptureCoordinator.shared.openImage() }
    @objc private func pinImage() { CaptureCoordinator.shared.pinImageFromFile() }

    @objc private func openHistory() { HistoryWindowController.show() }
    @objc private func restoreClosed() { PreviewManager.shared.restoreRecentlyClosed() }
    @objc private func openSettings() { SettingsWindowController.show() }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Recording state

    /// Swaps the icon for a red stop button with a running timer. Clicking it stops.
    func showRecording(elapsed: @escaping () -> TimeInterval, onStop: @escaping () -> Void) {
        onStopRecording = onStop
        statusItem.isVisible = true
        statusItem.menu = nil
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
        button.image?.isTemplate = false
        button.contentTintColor = .systemRed
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(stopClicked)
        let showTime = Settings.shared.showRecordingTimeInMenuBar
        let update = { [weak button] in
            let seconds = Int(elapsed())
            button?.title = showTime ? String(format: " %d:%02d", seconds / 60, seconds % 60) : ""
        }
        update()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { update() }
        }
    }

    func showSaving() {
        recordingTimer?.invalidate()
        statusItem.button?.title = " Saving…"
    }

    func endRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        onStopRecording = nil
        guard let button = statusItem.button else { return }
        button.title = ""
        button.contentTintColor = nil
        button.action = nil
        let image: NSImage? = AppIcon.menuBar()
        button.image = image
        statusItem.menu = menu
        applyVisibility()
    }

    @objc private func stopClicked() { onStopRecording?() }
}
