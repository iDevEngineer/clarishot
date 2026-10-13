import AppKit

/// The Settings window: one toolbar tab per area, like the system Settings style.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var current: SettingsWindowController?

    static func show() {
        let controller = current ?? SettingsWindowController()
        current = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let panes: [(String, String, NSViewController)] = [
            ("General", "gearshape", GeneralPane()),
            ("Screenshots", "camera.viewfinder", ScreenshotsPane()),
            ("Quick Access", "rectangle.on.rectangle", QuickAccessPane()),
            ("Recording", "video", RecordingPane()),
            ("Wallpaper", "photo", WallpaperPane()),
            ("Shortcuts", "command", ShortcutsPane()),
            ("Advanced", "slider.horizontal.3", AdvancedPane())
        ]
        for (title, symbol, controller) in panes {
            let item = NSTabViewItem(viewController: controller)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = "Settings"
        window.toolbarStyle = .preference
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}

// MARK: - Form building

/// Base pane: a two-column form (labels on the right-aligned left, controls on the right).
@MainActor
class SettingsPane: NSViewController {
    private var targets: [AnyObject] = []
    private var rows: [[NSView]] = []

    override func loadView() {
        build()
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for (index, row) in rows.enumerated() where row.count == 1 {
            grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: index, length: 1))
            grid.cell(atColumnIndex: 0, rowIndex: index).xPlacement = .leading
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -32),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 560)
        ])
        view = container
    }

    /// Subclasses add rows here.
    func build() {}

    func row(_ label: String, _ controls: NSView...) {
        let stack = NSStackView(views: controls)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        rows.append([NSTextField(labelWithString: label.isEmpty ? "" : "\(label):"), stack])
    }

    func note(_ text: String) {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 380
        rows.append([NSView(), field])
    }

    func separator() {
        let box = NSBox()
        box.boxType = .separator
        rows.append([box])
    }

    func checkbox(_ title: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> NSButton {
        let target = Callback { sender in set((sender as? NSButton)?.state == .on) }
        targets.append(target)
        let button = NSButton(checkboxWithTitle: title, target: target, action: #selector(Callback.fire(_:)))
        button.state = get() ? .on : .off
        return button
    }

    func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let target = Callback { _ in action() }
        targets.append(target)
        let button = NSButton(title: title, target: target, action: #selector(Callback.fire(_:)))
        button.bezelStyle = .rounded
        return button
    }

    func popup(_ titles: [String], selected: Int, change: @escaping (Int) -> Void) -> NSPopUpButton {
        let target = Callback { sender in change((sender as? NSPopUpButton)?.indexOfSelectedItem ?? 0) }
        targets.append(target)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: titles)
        popup.selectItem(at: selected)
        popup.target = target
        popup.action = #selector(Callback.fire(_:))
        return popup
    }

    func textField(_ value: String, width: CGFloat = 280, change: @escaping (String) -> Void) -> NSTextField {
        let target = Callback { sender in change((sender as? NSTextField)?.stringValue ?? "") }
        targets.append(target)
        let field = NSTextField(string: value)
        field.target = target
        field.action = #selector(Callback.fire(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    func horizontal(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 8
        return stack
    }

    func chooseFolder(start: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Lets a closure act as an AppKit target/action.
final class Callback: NSObject {
    private let handler: (Any?) -> Void
    init(_ handler: @escaping (Any?) -> Void) { self.handler = handler }
    @objc func fire(_ sender: Any?) { handler(sender) }
}

// MARK: - Panes

final class GeneralPane: SettingsPane {
    private let folderLabel = NSTextField(labelWithString: "")

    override func build() {
        let s = Settings.shared
        row("Startup", checkbox("Launch Snapzy at login", get: { s.launchAtLogin }, set: { s.launchAtLogin = $0 }))
        row("Sounds", checkbox("Play a sound after taking a screenshot", get: { s.playSounds }, set: { s.playSounds = $0 }))
        separator()
        updateFolderLabel()
        row("Save to", folderLabel,
            horizontal(button("Choose…") { [weak self] in self?.pickFolder() },
                       button("Use Desktop") { [weak self] in self?.resetFolder() }))
        row("Screenshot names", textField(s.screenshotNameTemplate) { s.screenshotNameTemplate = $0 })
        row("Recording names", textField(s.recordingNameTemplate) { s.recordingNameTemplate = $0 })
        note("Use {date} and {time} in names, e.g. “Snapzy {date} at {time}”. Press Return to apply.")
        separator()
        let days = [0, 1, 7, 30]
        row("Capture history", popup(["Off", "1 day", "1 week", "1 month"], selected: days.firstIndex(of: s.historyDays) ?? 3) {
            s.historyDays = days[$0]
        })
        note("Snapzy keeps its own copy of each capture for this long. Open it from Capture History… in the menu.")
    }

    private func updateFolderLabel() {
        folderLabel.stringValue = (Settings.shared.exportFolder.path as NSString).abbreviatingWithTildeInPath
    }

    private func pickFolder() {
        guard let url = chooseFolder(start: Settings.shared.exportFolder) else { return }
        Settings.shared.exportFolder = url
        updateFolderLabel()
    }

    private func resetFolder() {
        UserDefaults.standard.removeObject(forKey: "exportFolder")
        updateFolderLabel()
    }
}

final class ScreenshotsPane: SettingsPane {
    private var qualitySlider: NSSlider?

    override func build() {
        let s = Settings.shared
        row("After capture",
            checkbox("Show Quick Access Overlay", get: { s.afterCaptureShowPreview }, set: { s.afterCaptureShowPreview = $0 }),
            checkbox("Copy to clipboard", get: { s.afterCaptureCopy }, set: { s.afterCaptureCopy = $0 }),
            checkbox("Save to the export folder", get: { s.afterCaptureSave }, set: { s.afterCaptureSave = $0 }),
            checkbox("Open Annotate", get: { s.afterCaptureAnnotate }, set: { s.afterCaptureAnnotate = $0 }))
        note("If none are ticked, the Quick Access Overlay is shown.")
        separator()

        let formats = Settings.ImageFormat.allCases
        let format = popup(["PNG", "JPEG"], selected: formats.firstIndex(of: s.imageFormat) ?? 0) { [weak self] index in
            s.imageFormat = formats[index]
            self?.qualitySlider?.isEnabled = s.imageFormat == .jpeg
        }
        let slider = NSSlider(value: s.jpegQuality, minValue: 0.3, maxValue: 1, target: nil, action: nil)
        let sliderTarget = Callback { sender in s.jpegQuality = (sender as? NSSlider)?.doubleValue ?? 0.85 }
        slider.target = sliderTarget
        slider.action = #selector(Callback.fire(_:))
        objc_setAssociatedObject(slider, "target", sliderTarget, .OBJC_ASSOCIATION_RETAIN)
        slider.isEnabled = s.imageFormat == .jpeg
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        qualitySlider = slider
        row("File format", format)
        row("JPEG quality", slider)
        separator()
        row("Options",
            checkbox("Scale Retina screenshots to 1x", get: { s.scaleScreenshotsTo1x }, set: { s.scaleScreenshotsTo1x = $0 }),
            checkbox("Show cursor on screenshots", get: { s.showCursorInScreenshots }, set: { s.showCursorInScreenshots = $0 }),
            checkbox("Show magnifier while selecting", get: { s.showMagnifier }, set: { s.showMagnifier = $0 }))
        note("Scaling to 1x makes files smaller and helps Retina screenshots display at the right size in other apps.")
        separator()
        let styles = Settings.WindowStyle.allCases
        row("Window captures", popup(styles.map(\.title), selected: styles.firstIndex(of: s.windowStyle) ?? 1) {
            s.windowStyle = styles[$0]
        })
        let presets = BackgroundPresets.all.map(\.name)
        row("Background", popup(["None"] + presets, selected: (presets.firstIndex { $0 == s.autoBackgroundPreset } ?? -1) + 1) {
            s.autoBackgroundPreset = $0 == 0 ? nil : presets[$0 - 1]
        })
        note("Adds a saved background preset to every new screenshot. Create presets in Annotate’s background tool.")
        let delays = [3, 5, 10]
        row("Self-timer", popup(["3 seconds", "5 seconds", "10 seconds"], selected: delays.firstIndex(of: s.selfTimerSeconds) ?? 1) {
            s.selfTimerSeconds = delays[$0]
        })
    }
}

final class QuickAccessPane: SettingsPane {
    override func build() {
        let s = Settings.shared
        let positions = Settings.PreviewPosition.allCases
        row("Position on screen", popup(positions.map(\.title), selected: positions.firstIndex(of: s.previewPosition) ?? 0) {
            s.previewPosition = positions[$0]
        })
        let delays = [0, 5, 10, 30, 60]
        row("Close automatically", popup(["Never", "After 5 seconds", "After 10 seconds", "After 30 seconds", "After 1 minute"],
                                         selected: delays.firstIndex(of: s.previewAutoClose) ?? 0) {
            s.previewAutoClose = delays[$0]
        })
        row("Options",
            checkbox("Show on the screen where the cursor is", get: { s.previewOnActiveScreen }, set: { s.previewOnActiveScreen = $0 }),
            checkbox("Close after dragging into another app", get: { s.closePreviewAfterDragging },
                     set: { s.closePreviewAfterDragging = $0 }))
    }
}

final class RecordingPane: SettingsPane {
    override func build() {
        let s = Settings.shared
        row("While recording",
            checkbox("Show recording time in the menu bar", get: { s.showRecordingTimeInMenuBar },
                     set: { s.showRecordingTimeInMenuBar = $0 }),
            checkbox("Show controls (stop, pause, restart, discard)", get: { s.showControlsWhileRecording },
                     set: { s.showControlsWhileRecording = $0 }))
        note("Audio, camera, clicks, keystrokes, cursor, frame rate and countdown are set in the panel that appears after you choose an area to record. Without the controls, stop from the menu bar or with the Record shortcut.")
    }
}

final class WallpaperPane: SettingsPane {
    private let preview = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override func build() {
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 8
        preview.layer?.masksToBounds = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 240).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 150).isActive = true
        refresh()
        row("Wallpaper", preview, label,
            horizontal(button("Choose Picture…") { [weak self] in self?.choose() },
                       button("Use Desktop Picture") { [weak self] in self?.useDesktop() }))
        note("Used to hide desktop icons and as the “wallpaper” fill in Annotate’s background tool.")
    }

    private func refresh() {
        let url = Wallpaper.url()
        preview.image = url.flatMap { NSImage(contentsOf: $0) }
        label.stringValue = Settings.shared.customWallpaper == nil ? "Desktop picture" : (url?.lastPathComponent ?? "")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Settings.shared.customWallpaper = url
        refresh()
    }

    private func useDesktop() {
        Settings.shared.customWallpaper = nil
        refresh()
    }
}

final class ShortcutsPane: SettingsPane {
    private var recorders: [(ShortcutAction, ShortcutRecorder)] = []

    override func build() {
        for action in ShortcutAction.allCases {
            let recorder = ShortcutRecorder(shortcut: Settings.shared.shortcut(for: action)) { shortcut in
                Settings.shared.setShortcut(shortcut, for: action)
            }
            recorders.append((action, recorder))
            row(action.title, recorder)
        }
        separator()
        row("", button("Restore Defaults") { [weak self] in
            Settings.shared.resetShortcuts()
            self?.recorders.forEach { $0.1.shortcut = Settings.shared.shortcut(for: $0.0) }
        })
        note("Click a shortcut, then press the new keys (include ⌘, ⌥ or ⌃). Press Delete to turn it off, Esc to cancel. ⇧⌘3, ⇧⌘4 and ⇧⌘5 belong to macOS unless you turn them off in System Settings → Keyboard.")
    }
}

final class AdvancedPane: SettingsPane {
    override func build() {
        row("Reset", button("Reset All Settings…") { [weak self] in self?.confirmReset() })
        note("Restores every option and shortcut to its default. Your screenshots and recordings are not touched.")
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings?"
        alert.informativeText = "Close and reopen Settings afterwards to see the defaults."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Settings.shared.resetAll()
            UserDefaults.standard.removeObject(forKey: "recordingOptions")
        }
    }
}
