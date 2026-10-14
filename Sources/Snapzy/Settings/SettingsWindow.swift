import AppKit

/// The Settings window: a sidebar of coloured tabs on the left, grouped rows on the right.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var current: SettingsWindowController?

    static func show(tab: SettingsTab = .general) {
        let controller = current ?? SettingsWindowController()
        current = controller
        controller.split.select(tab)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private let split = SettingsSplitController()

    private init() {
        let window = NSWindow(contentViewController: split)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Settings"
        window.setContentSize(CGSize(width: 810, height: 760))
        window.minSize = CGSize(width: 810, height: 480)
        window.maxSize = CGSize(width: 810, height: 4000)
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}

/// The tabs, in sidebar order, with their tile colour and icon.
enum SettingsTab: CaseIterable {
    case general, shortcuts, quickAccess, wallpaper, screenshots, recording, advanced, about

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .quickAccess: return "Quick Access"
        case .wallpaper: return "Wallpaper"
        case .screenshots: return "Screenshots"
        case .recording: return "Screen Recording"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .shortcuts: return "command"
        case .quickAccess: return "rectangle.on.rectangle"
        case .wallpaper: return "photo.fill"
        case .screenshots: return "camera.fill"
        case .recording: return "video.fill"
        case .advanced: return "wrench.and.screwdriver.fill"
        case .about: return "info"
        }
    }

    var color: NSColor {
        switch self {
        case .general, .shortcuts: return .systemGray
        case .quickAccess: return .systemGreen
        case .wallpaper: return .systemTeal
        case .screenshots: return .systemBlue
        case .recording: return .systemRed
        case .advanced: return .systemPurple
        case .about: return .systemGray
        }
    }

    @MainActor
    func makePane() -> NSViewController {
        switch self {
        case .general: return GeneralPane(title: title)
        case .shortcuts: return ShortcutsPane(title: title)
        case .quickAccess: return QuickAccessPane(title: title)
        case .wallpaper: return WallpaperPane(title: title)
        case .screenshots: return ScreenshotsPane(title: title)
        case .recording: return RecordingPane(title: title)
        case .advanced: return AdvancedPane(title: title)
        case .about: return AboutPane()
        }
    }
}

// MARK: - Sidebar + content

@MainActor
final class SettingsSplitController: NSViewController {
    private var buttons: [SettingsTab: SidebarButton] = [:]
    private let content = NSView()
    private var pane: NSViewController?

    override func loadView() {
        let root = NSView()

        // Sidebar: a rounded inset panel, like the system Settings style.
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.wantsLayer = true
        sidebar.layer?.cornerRadius = 12
        sidebar.layer?.borderWidth = 0.5
        sidebar.layer?.borderColor = NSColor.separatorColor.cgColor
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let top = NSStackView()
        top.orientation = .vertical
        top.spacing = 2
        top.alignment = .leading
        for tab in SettingsTab.allCases where tab != .about { top.addArrangedSubview(button(for: tab)) }
        let about = button(for: .about)
        for view in [top, about] {
            view.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(view)
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        root.addSubview(content)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            sidebar.widthAnchor.constraint(equalToConstant: 212),
            top.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 46),
            top.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            top.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            about.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -8),
            about.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            about.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        for view in top.arrangedSubviews { view.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true }
        view = root
        if pane == nil { select(.general) }
    }

    private func button(for tab: SettingsTab) -> SidebarButton {
        let button = SidebarButton(tab: tab) { [weak self] in self?.select(tab) }
        buttons[tab] = button
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    func select(_ tab: SettingsTab) {
        _ = view // make sure the sidebar exists
        buttons.forEach { $0.value.isSelected = $0.key == tab }
        pane?.view.removeFromSuperview()
        pane?.removeFromParent()
        let next = tab.makePane()
        addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            next.view.topAnchor.constraint(equalTo: content.topAnchor),
            next.view.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        pane = next
    }
}

/// One sidebar row: a coloured rounded icon tile and the tab name; highlighted when selected.
final class SidebarButton: NSView {
    var isSelected = false { didSet { updateLayer() } }
    private let onClick: () -> Void

    init(tab: SettingsTab, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7

        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 6
        tile.layer?.backgroundColor = tab.color.cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        icon.contentTintColor = .white
        for view in [tile, icon] { view.translatesAutoresizingMaskIntoConstraints = false }
        tile.addSubview(icon)

        let label = NSTextField(labelWithString: tab.title)
        label.font = .systemFont(ofSize: 13)
        let stack = NSStackView(views: [tile, label])
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 24),
            tile.heightAnchor.constraint(equalToConstant: 24),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = isSelected ? NSColor.labelColor.withAlphaComponent(0.1).cgColor : nil
    }

    override func mouseDown(with event: NSEvent) { onClick() }
}

// MARK: - Form building

/// Base pane: a scrolling column with the tab title, then titled sections of grouped rows.
@MainActor
class SettingsPane: NSViewController {
    static let contentWidth: CGFloat = 540
    private var targets: [AnyObject] = []
    private var blocks: [NSView] = []
    private let paneTitle: String

    init(title: String) {
        paneTitle = title
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let heading = NSTextField(labelWithString: paneTitle)
        heading.font = .systemFont(ofSize: 15, weight: .bold)
        blocks = [heading]
        build()
        let stack = NSStackView(views: blocks)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.setCustomSpacing(16, after: heading)
        // The title sits level with the window buttons, like the reference.
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 24, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        view = scroll
    }

    /// Subclasses add sections here.
    func build() {}

    /// A titled group of rows, with an optional grey line under the title.
    func section(_ title: String?, subtitle: String? = nil, _ rows: [NSView]) {
        var views: [NSView] = []
        if let title {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13, weight: .bold)
            views.append(label)
        }
        if let subtitle {
            let text = NSTextField(wrappingLabelWithString: subtitle)
            text.font = .systemFont(ofSize: 11)
            text.textColor = .secondaryLabelColor
            views.append(text)
        }
        let group = RecordingSettingsViewController.groupBox(rows)
        group.translatesAutoresizingMaskIntoConstraints = false
        group.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        views.append(group)
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.setCustomSpacing(8, after: views[views.count - 2 < 0 ? 0 : views.count - 2])
        blocks.append(column)
    }

    /// Adds any view (e.g. an embedded controller's view) as its own block.
    func block(_ view: NSView) { blocks.append(view) }

    /// Title (and optional grey note) on the left, control on the right.
    func row(_ title: String, _ control: NSView?, note: String? = nil) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        let top = NSStackView(views: [label, NSView()] + (control.map { [$0] } ?? []))
        top.alignment = .centerY
        var views: [NSView] = [top]
        if let note {
            let text = NSTextField(wrappingLabelWithString: note)
            text.font = .systemFont(ofSize: 11)
            text.textColor = .secondaryLabelColor
            text.preferredMaxLayoutWidth = Self.contentWidth - 40
            views.append(text)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 0, bottom: 9, right: 0)
        top.translatesAutoresizingMaskIntoConstraints = false
        top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        top.heightAnchor.constraint(greaterThanOrEqualToConstant: 22).isActive = true
        stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        return stack
    }

    func toggle(_ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = .small
        control.state = get() ? .on : .off
        control.target = target { sender in set((sender as? NSSwitch)?.state == .on) }
        control.action = #selector(Callback.fire(_:))
        return control
    }

    func checkbox(_ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        button.state = get() ? .on : .off
        button.target = target { sender in set((sender as? NSButton)?.state == .on) }
        button.action = #selector(Callback.fire(_:))
        return button
    }

    func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: target { _ in action() }, action: #selector(Callback.fire(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    func popup(_ titles: [String], selected: Int, change: @escaping (Int) -> Void) -> NSPopUpButton {
        let popup = RecordingSettingsViewController.plainPopup()
        popup.addItems(withTitles: titles)
        popup.selectItem(at: max(selected, 0))
        popup.target = target { sender in change((sender as? NSPopUpButton)?.indexOfSelectedItem ?? 0) }
        popup.action = #selector(Callback.fire(_:))
        return popup
    }

    func textField(_ value: String, width: CGFloat = 240, change: @escaping (String) -> Void) -> NSTextField {
        let field = NSTextField(string: value)
        field.target = target { sender in change((sender as? NSTextField)?.stringValue ?? "") }
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

    private func target(_ handler: @escaping (Any?) -> Void) -> Callback {
        let callback = Callback(handler)
        targets.append(callback)
        return callback
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
        section("App", [row("Launch at login", toggle({ s.launchAtLogin }, { s.launchAtLogin = $0 }))])
        section("Sounds", [row("Play sounds", toggle({ s.playSounds }, { s.playSounds = $0 }))])

        updateFolderLabel()
        let folder = horizontal(folderLabel, button("Choose…") { [weak self] in self?.pickFolder() })
        section("Export", [row("Export location", folder,
                               note: "Where Save puts files from the Quick Access Overlay, After Capture and other Save actions.")])

        // After Capture: a two-column table like the reference (only screenshots have options so far).
        let header = row("Action", nil)
        if let top = (header as? NSStackView)?.arrangedSubviews.first as? NSStackView {
            (top.arrangedSubviews.first as? NSTextField)?.textColor = .secondaryLabelColor
            let column = NSTextField(labelWithString: "Screenshot")
            column.textColor = .secondaryLabelColor
            top.addArrangedSubview(column)
        }
        func choice(_ title: String, _ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) -> NSView {
            let box = checkbox(get, set)
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            holder.widthAnchor.constraint(equalToConstant: 72).isActive = true
            box.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(box)
            NSLayoutConstraint.activate([
                box.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
                box.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                holder.heightAnchor.constraint(equalToConstant: 18)
            ])
            return row(title, holder)
        }
        section("After Capture", subtitle: "Decide what should happen after taking a screenshot.", [
            header,
            choice("Show Quick Access Overlay", { s.afterCaptureShowPreview }, { s.afterCaptureShowPreview = $0 }),
            choice("Copy file to clipboard", { s.afterCaptureCopy }, { s.afterCaptureCopy = $0 }),
            choice("Save", { s.afterCaptureSave }, { s.afterCaptureSave = $0 }),
            choice("Open Annotate tool", { s.afterCaptureAnnotate }, { s.afterCaptureAnnotate = $0 })
        ])
    }

    private func updateFolderLabel() {
        let url = Settings.shared.exportFolder
        folderLabel.stringValue = "📁 " + url.lastPathComponent
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.toolTip = url.path
    }

    private func pickFolder() {
        guard let url = chooseFolder(start: Settings.shared.exportFolder) else { return }
        Settings.shared.exportFolder = url
        updateFolderLabel()
    }
}

final class ShortcutsPane: SettingsPane {
    private var recorders: [(ShortcutAction, ShortcutRecorder)] = []

    override func build() {
        let groups: [(String, String, [ShortcutAction])] = [
            ("General", "gearshape", [.allInOne]),
            ("Screenshots", "camera", [.captureArea, .capturePreviousArea, .captureFullscreen, .captureWindow,
                                       .selfTimer, .scrollingCapture, .captureText]),
            ("Screen Recording", "video", [.recordScreen, .pauseRecording])
        ]
        for (title, _, actions) in groups {
            section(title, actions.map { action in
                let recorder = ShortcutRecorder(shortcut: Settings.shared.shortcut(for: action)) { shortcut in
                    Settings.shared.setShortcut(shortcut, for: action)
                }
                recorder.translatesAutoresizingMaskIntoConstraints = false
                recorder.widthAnchor.constraint(equalToConstant: 180).isActive = true
                recorders.append((action, recorder))
                return row(action.title, recorder)
            })
        }
        section("Options", [row("Click a shortcut, then press the new keys. Delete turns it off.",
                                button("Restore Defaults") { [weak self] in
            Settings.shared.resetShortcuts()
            self?.recorders.forEach { $0.1.shortcut = Settings.shared.shortcut(for: $0.0) }
        })])
    }
}

final class QuickAccessPane: SettingsPane {
    private var intervalPopup: NSPopUpButton?

    override func build() {
        let s = Settings.shared
        let positions = Settings.PreviewPosition.allCases
        section("Appearance", [
            row("Position on screen", popup(positions.map(\.title), selected: positions.firstIndex(of: s.previewPosition) ?? 0) {
                s.previewPosition = positions[$0]
            }),
            row("Move to active screen", toggle({ s.previewOnActiveScreen }, { s.previewOnActiveScreen = $0 }),
                note: "Active screen is the screen where your cursor is pointing.")
        ])

        let delays = [5, 10, 30, 60]
        let interval = popup(["5 seconds", "10 seconds", "30 seconds", "1 minute"],
                             selected: delays.firstIndex(of: s.previewAutoClose) ?? 2) { s.previewAutoClose = delays[$0] }
        interval.isEnabled = s.previewAutoClose > 0
        intervalPopup = interval
        section("Behavior", [
            row("Auto-close", toggle({ s.previewAutoClose > 0 }, { [weak self] on in
                s.previewAutoClose = on ? delays[self?.intervalPopup?.indexOfSelectedItem ?? 2] : 0
                self?.intervalPopup?.isEnabled = on
            })),
            row("Interval", interval)
        ])
        section(nil, [
            row("Close after dragging", toggle({ s.closePreviewAfterDragging }, { s.closePreviewAfterDragging = $0 }),
                note: "Closes the overlay once you drag the capture into another app.")
        ])
    }
}

final class WallpaperPane: SettingsPane {
    private var choice: NSPopUpButton?

    override func build() {
        let popup = popup(titles(), selected: Settings.shared.customWallpaper == nil ? 0 : 1) { [weak self] index in
            self?.picked(index)
        }
        choice = popup
        section("Desktop", [
            row("Wallpaper", popup,
                note: "Set a custom wallpaper used to hide desktop icons and as the background behind window screenshots.")
        ])
    }

    private func titles() -> [String] {
        var titles = ["Desktop wallpaper"]
        if let custom = Settings.shared.customWallpaper { titles.append(custom.lastPathComponent) }
        titles.append("Choose Picture…")
        return titles
    }

    private func picked(_ index: Int) {
        let s = Settings.shared
        if index == 0 {
            s.customWallpaper = nil
        } else if index == (choice?.numberOfItems ?? 0) - 1 {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            if panel.runModal() == .OK, let url = panel.url { s.customWallpaper = url }
        }
        choice?.removeAllItems()
        choice?.addItems(withTitles: titles())
        choice?.selectItem(at: s.customWallpaper == nil ? 0 : 1)
    }
}

final class ScreenshotsPane: SettingsPane {
    private var qualityRow: NSView?

    override func build() {
        let s = Settings.shared
        let formats = Settings.ImageFormat.allCases
        let quality = NSSlider(value: s.jpegQuality, minValue: 0.3, maxValue: 1, target: nil, action: nil)
        quality.controlSize = .small
        let sliderTarget = Callback { sender in s.jpegQuality = (sender as? NSSlider)?.doubleValue ?? 0.85 }
        quality.target = sliderTarget
        quality.action = #selector(Callback.fire(_:))
        objc_setAssociatedObject(quality, "target", sliderTarget, .OBJC_ASSOCIATION_RETAIN)
        quality.translatesAutoresizingMaskIntoConstraints = false
        quality.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let qualityRow = row("JPEG quality", quality)
        qualityRow.isHidden = s.imageFormat != .jpeg
        self.qualityRow = qualityRow

        let presets = BackgroundPresets.all.map(\.name)
        section("Output", [
            row("File format", popup(["PNG", "JPEG"], selected: formats.firstIndex(of: s.imageFormat) ?? 0) { [weak self] in
                s.imageFormat = formats[$0]
                self?.qualityRow?.isHidden = s.imageFormat != .jpeg
            }),
            qualityRow,
            row("Scale Retina screenshots to 1x", toggle({ s.scaleScreenshotsTo1x }, { s.scaleScreenshotsTo1x = $0 })),
            row("Background preset", popup(["None"] + presets,
                                           selected: (presets.firstIndex { $0 == s.autoBackgroundPreset } ?? -1) + 1) {
                s.autoBackgroundPreset = $0 == 0 ? nil : presets[$0 - 1]
            }, note: "Apply a Background Tool preset to all screenshots. You can create presets in Annotate.")
        ])

        let delays = [3, 5, 10]
        section("Capture", [
            row("Self-Timer interval", popup(["3 Seconds", "5 Seconds", "10 Seconds"],
                                             selected: delays.firstIndex(of: s.selfTimerSeconds) ?? 1) {
                s.selfTimerSeconds = delays[$0]
            }),
            row("Show cursor on screenshots", toggle({ s.showCursorInScreenshots }, { s.showCursorInScreenshots = $0 }),
                note: "This works in Fullscreen or Self-Timer modes only."),
            row("Place fullscreen captures on the wallpaper", toggle({ s.fullscreenOnWallpaper },
                                                                    { s.fullscreenOnWallpaper = $0 }))
        ])

        let styles = Settings.WindowStyle.allCases
        section("Window Screenshots", [
            row("Background", popup(styles.map(\.title), selected: styles.firstIndex(of: s.windowStyle) ?? 2) {
                s.windowStyle = styles[$0]
            }, note: "You can customize the wallpaper in the Wallpaper tab.")
        ])

        section("Crosshair", [
            row("Show magnifier", toggle({ s.showMagnifier }, { s.showMagnifier = $0 }))
        ])
    }
}

/// The same grouped settings as the recording panel's sliders button.
final class RecordingPane: SettingsPane {
    private var embedded: RecordingSettingsViewController?

    override func build() {
        let controller = RecordingSettingsViewController(options: RecordingOptions.load(),
                                                         width: Self.contentWidth + 40, embedded: true) { $0.save() }
        addChild(controller)
        embedded = controller
        block(controller.view)
    }
}

final class AdvancedPane: SettingsPane {
    override func build() {
        let s = Settings.shared
        section("File Name", [
            row("Screenshots", textField(s.screenshotNameTemplate) { s.screenshotNameTemplate = $0 }),
            row("Recordings", textField(s.recordingNameTemplate) { s.recordingNameTemplate = $0 },
                note: "Use {date} and {time}, e.g. “Snapzy {date} at {time}”. Press Return to apply.")
        ])
        let days = [0, 1, 3, 7, 30]
        section("Capture History", [
            row("Keep history", popup(["Never", "1 day", "3 days", "1 week", "1 month"],
                                      selected: days.firstIndex(of: s.historyDays) ?? 4) { s.historyDays = days[$0] },
                note: "You can restore old files with “Capture History” from the menu bar.")
        ])
        section("Text Recognition", [
            row("Keep line breaks", toggle({ s.keepLineBreaks }, { s.keepLineBreaks = $0 }))
        ])
        section("Other", [
            row("Restore every option and shortcut to its default.",
                button("Reset All Settings…") { [weak self] in self?.confirmReset() })
        ])
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings?"
        alert.informativeText = "Your screenshots and recordings are not touched."
        alert.icon = AppIcon.current
        alert.addButton(withTitle: "Reset").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Settings.shared.resetAll()
            UserDefaults.standard.removeObject(forKey: "recordingOptions")
            SettingsWindowController.show(tab: .advanced)
        }
    }
}

final class AboutPane: NSViewController {
    override func loadView() {
        let icon = NSImageView(image: AppIcon.current)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 128).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 128).isActive = true
        let name = NSTextField(labelWithString: "Snapzy")
        name.font = .systemFont(ofSize: 22, weight: .bold)
        let info = Bundle.main.infoDictionary
        let version = NSTextField(labelWithString:
            "Version \(info?["CFBundleShortVersionString"] as? String ?? "–") (\(info?["CFBundleVersion"] as? String ?? "–"))")
        version.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, name, version])
        stack.orientation = .vertical
        stack.spacing = 8
        let root = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])
        view = root
    }
}
