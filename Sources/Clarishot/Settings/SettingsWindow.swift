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
        window.title = "Preferences"
        // Tall, but never taller than the screen allows.
        let available = (NSScreen.main?.visibleFrame.height ?? 900) - 40
        window.setContentSize(CGSize(width: 810, height: min(860, available)))
        window.minSize = CGSize(width: 810, height: 480)
        window.maxSize = CGSize(width: 1600, height: 4000)
        super.init(window: window)
        window.delegate = self
        window.useRoundedCorners()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}

/// The tabs, in sidebar order, with their tile colour and icon.
enum SettingsTab: CaseIterable {
    case general, shortcuts, quickAccess, wallpaper, screenshots, recording, annotate, advanced, about

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .quickAccess: return "Quick Access"
        case .wallpaper: return "Wallpaper"
        case .screenshots: return "Screenshots"
        case .recording: return "Screen Recording"
        case .annotate: return "Annotate"
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
        case .annotate: return "pencil"
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
        case .annotate: return .systemOrange
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
        case .annotate: return AnnotatePane(title: title)
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
        sidebar.layer?.cornerRadius = 18 // window radius (26) minus the 8 pt inset, so the curves match
        sidebar.layer?.cornerCurve = .continuous
        sidebar.layer?.borderWidth = 0.5
        sidebar.layer?.borderColor = NSColor.separatorColor.cgColor
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let top = NSStackView()
        top.orientation = .vertical
        top.spacing = 6
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
        // Don't start with a text or search field focused.
        DispatchQueue.main.async { [weak self] in self?.view.window?.makeFirstResponder(nil) }
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
        tile.layer?.cornerRadius = 5
        tile.layer?.backgroundColor = tab.color.cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        icon.contentTintColor = .white
        for view in [tile, icon] { view.translatesAutoresizingMaskIntoConstraints = false }
        tile.addSubview(icon)

        let label = NSTextField(labelWithString: tab.title)
        label.font = .systemFont(ofSize: 13)
        let stack = NSStackView(views: [tile, label])
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 22),
            tile.heightAnchor.constraint(equalToConstant: 22),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 34)
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

    /// Shown at the right of the title row (e.g. a search field).
    var headerAccessory: NSView? { nil }
    private let body = NSStackView()

    override func loadView() {
        let heading = NSTextField(labelWithString: paneTitle)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let headerRow = NSStackView(views: [heading, NSView()] + (headerAccessory.map { [$0] } ?? []))
        headerRow.alignment = .centerY
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.heightAnchor.constraint(equalToConstant: 26).isActive = true

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 26
        rebuild()

        let stack = NSStackView(views: [headerRow, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        // The title sits level with the window buttons, like the reference.
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 20, bottom: 24, right: 20)
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
        // Everything stretches with the window; 540 pt is the narrowest.
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            body.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.contentWidth),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        view = scroll
    }

    /// Clears the sections and runs `build()` again (e.g. after filtering).
    func rebuild() {
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        targets.removeAll()
        blocks = []
        build()
        for block in blocks {
            body.addArrangedSubview(block)
            block.translatesAutoresizingMaskIntoConstraints = false
            block.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
    }

    /// Subclasses add sections here.
    func build() {}

    /// A titled group of rows, with an optional grey line under the title.
    func section(_ title: String?, symbol: String? = nil, subtitle: String? = nil, _ rows: [NSView]) {
        guard !rows.isEmpty else { return }
        var views: [NSView] = []
        if let title {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let icon = NSImageView(image: image)
                icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
                icon.contentTintColor = .labelColor
                let header = NSStackView(views: [icon, label])
                header.spacing = 6
                views.append(header)
            } else {
                views.append(label)
            }
        }
        if let subtitle {
            let text = NSTextField(wrappingLabelWithString: subtitle)
            text.font = .systemFont(ofSize: 11)
            text.textColor = .secondaryLabelColor
            views.append(text)
        }
        let group = RecordingSettingsViewController.groupBox(rows)
        group.translatesAutoresizingMaskIntoConstraints = false
        views.append(group)
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        group.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        if views.count > 1 { column.setCustomSpacing(9, after: views[views.count - 2]) }
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
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: note == nil ? 8 : 10, right: 0)
        top.translatesAutoresizingMaskIntoConstraints = false
        top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        // 21 pt for ordinary rows (37 pt total); taller controls like picture tiles may grow it.
        top.heightAnchor.constraint(greaterThanOrEqualToConstant: 21).isActive = true
        let fit = top.heightAnchor.constraint(equalToConstant: 21)
        fit.priority = .defaultLow
        fit.isActive = true
        stack.setHuggingPriority(.required, for: .vertical)
        return stack
    }

    /// A row with an icon on the left, like the Appearance rows.
    func iconRow(_ symbol: String, _ title: String, note: String?, _ control: NSView) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        var texts: [NSView] = [label]
        if let note {
            let text = NSTextField(wrappingLabelWithString: note)
            text.font = .systemFont(ofSize: 11)
            text.textColor = .secondaryLabelColor
            text.preferredMaxLayoutWidth = 260
            texts.append(text)
        }
        let column = NSStackView(views: texts)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        let line = NSStackView(views: [icon, column, NSView(), control])
        line.spacing = 12
        line.alignment = .centerY
        // Padding via a container: the group box ignores a stack's own edge insets.
        let container = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            line.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        return container
    }

    func toggle(_ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = .mini
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

    func slider(_ value: Double, _ range: ClosedRange<Double>, ticks: Int = 0, width: CGFloat = 160,
                change: @escaping (Double) -> Void) -> NSSlider {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        slider.controlSize = .small
        slider.numberOfTickMarks = ticks
        slider.target = target { sender in change((sender as? NSSlider)?.doubleValue ?? value) }
        slider.action = #selector(Callback.fire(_:))
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: width).isActive = true
        return slider
    }

    func horizontal(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 8
        return stack
    }

    func target(_ handler: @escaping (Any?) -> Void) -> Callback {
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
    private let folderIcon = NSImageView()

    override func build() {
        let s = Settings.shared
        let languages: [(String, String)] = [("System Default", ""), ("English", "en")]
        let codes = languages.map(\.1)
        let themes = NSStackView(views: AppAppearance.Theme.allCases.map { theme -> NSView in
            ThemeTile(theme: theme, selected: s.theme == theme) { [weak self] in
                s.theme = theme
                self?.rebuild()
            }
        })
        themes.spacing = 12
        var appearance = [
            iconRow("globe", "App Language", note: "Choose the language used across Clarishot",
                    popup(languages.map(\.0), selected: codes.firstIndex(of: s.appLanguage) ?? 0) { index in
                        s.appLanguage = codes[index]
                        Toast.show("Restart Clarishot to change its language")
                    }),
            iconRow("circle.lefthalf.filled", "Theme", note: "Choose your preferred appearance", themes)
        ]
        if #available(macOS 26.0, *) {
            appearance.append(iconRow("sparkles", "Liquid Glass Effect",
                                      note: "Use translucent Liquid Glass for floating bars and panels. Turn off to use solid controls.",
                                      toggle({ s.liquidGlass }, { s.liquidGlass = $0 })))
        }
        section("Startup", [
            row("Launch at login", toggle({ s.launchAtLogin }, { s.launchAtLogin = $0 })),
            row("Show menu bar icon", toggle({ s.showMenuBarIcon }, { s.showMenuBarIcon = $0 }),
                note: "When hidden, open Clarishot again from Finder to get back to Preferences.")
        ])
        section("Appearance", appearance)
        section("Capture", [
            row("Hide desktop icons while capturing",
                toggle({ s.hideDesktopIconsWhileCapturing }, { s.hideDesktopIconsWhileCapturing = $0 }),
                note: "You can set a custom wallpaper to hide desktop icons in Wallpaper settings.")
        ])
        let sounds = CaptureSound.choices
        let shutter = popup(["System Default"] + sounds, selected: (sounds.firstIndex(of: s.shutterSound) ?? -1) + 1) {
            s.shutterSound = $0 == 0 ? "" : sounds[$0 - 1]
            CaptureSound.play()
        }
        shutter.isEnabled = s.playSounds // greyed out while sounds are off, like the reference
        section("Sounds", [
            row("Play sounds", toggle({ s.playSounds }, { on in
                s.playSounds = on
                shutter.isEnabled = on
            })),
            row("Shutter sound", shutter)
        ])

        updateFolderLabel()
        folderIcon.translatesAutoresizingMaskIntoConstraints = false
        folderIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        folderIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let name = horizontal(folderIcon, folderLabel)
        name.spacing = 4
        let folder = horizontal(name, button("Choose…") { [weak self] in self?.pickFolder() })
        section("Export", [row("Export location", folder,
                               note: "Set the default save location used when saving from the Quick Access Overlay, After Capture, and other Save actions across the app.")])

        // After Capture: Screenshot and Recording columns, like the reference.
        let header = row("Action", nil)
        if let top = (header as? NSStackView)?.arrangedSubviews.first as? NSStackView {
            (top.arrangedSubviews.first as? NSTextField)?.textColor = .secondaryLabelColor
            for title in ["Screenshot", "Recording"] {
                let column = NSTextField(labelWithString: title)
                column.textColor = .secondaryLabelColor
                column.alignment = .center
                column.translatesAutoresizingMaskIntoConstraints = false
                column.widthAnchor.constraint(equalToConstant: 90).isActive = true
                top.addArrangedSubview(column)
            }
        }
        typealias Option = (get: () -> Bool, set: (Bool) -> Void)
        func cell(_ option: Option?) -> NSView {
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            holder.widthAnchor.constraint(equalToConstant: 90).isActive = true
            holder.heightAnchor.constraint(equalToConstant: 18).isActive = true
            let control: NSView
            if let option {
                control = checkbox(option.get, option.set)
            } else {
                let dash = NSTextField(labelWithString: "—")
                dash.textColor = .tertiaryLabelColor
                control = dash
            }
            control.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(control)
            NSLayoutConstraint.activate([
                control.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
                control.centerYAnchor.constraint(equalTo: holder.centerYAnchor)
            ])
            return holder
        }
        func choice(_ title: String, _ shot: Option?, _ recording: Option?) -> NSView {
            row(title, horizontal(cell(shot), cell(recording)))
        }
        section("After Capture", subtitle: "Decide what should happen after taking a screenshot or recording a video.", [
            header,
            choice("Show Quick Access Overlay", ({ s.afterCaptureShowPreview }, { s.afterCaptureShowPreview = $0 }),
                   ({ s.afterRecordingShowPreview }, { s.afterRecordingShowPreview = $0 })),
            choice("Copy file to clipboard", ({ s.afterCaptureCopy }, { s.afterCaptureCopy = $0 }),
                   ({ s.afterRecordingCopy }, { s.afterRecordingCopy = $0 })),
            choice("Save", ({ s.afterCaptureSave }, { s.afterCaptureSave = $0 }),
                   ({ s.afterRecordingSave }, { s.afterRecordingSave = $0 })),
            choice("Open Annotate tool", ({ s.afterCaptureAnnotate }, { s.afterCaptureAnnotate = $0 }), nil),
            choice("Pin to the screen", ({ s.afterCapturePin }, { s.afterCapturePin = $0 }), nil)
        ])
    }

    private func updateFolderLabel() {
        let url = Settings.shared.exportFolder
        // The folder's real Finder icon (the blue folder, or Desktop's own icon).
        folderIcon.image = NSWorkspace.shared.icon(forFile: url.path)
        folderLabel.stringValue = url.lastPathComponent
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.toolTip = url.path
    }

    private func pickFolder() {
        guard let url = chooseFolder(start: Settings.shared.exportFolder) else { return }
        Settings.shared.exportFolder = url
        updateFolderLabel()
    }
}

final class ShortcutsPane: SettingsPane, NSSearchFieldDelegate {
    private var recorders: [(ShortcutAction, ShortcutRecorder)] = []
    private var query = ""
    private lazy var search: NSSearchField = {
        let field = NSSearchField()
        field.placeholderString = "Search shortcuts"
        field.controlSize = .regular
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return field
    }()

    override var headerAccessory: NSView? { search }

    func controlTextDidChange(_ obj: Notification) {
        query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        rebuild()
    }

    override func build() {
        recorders.removeAll()
        let groups: [(String, String, [[ShortcutAction]])] = [
            ("General", "gearshape", [[.allInOne, .toggleDesktopIcons, .openHistory, .restoreLastCapture]]),
            ("Screenshots", "camera", [[.captureArea, .capturePreviousArea, .captureFullscreen, .captureWindow,
                                        .smartCapture, .objectCutout, .selfTimer],
                                       [.captureAreaCopy, .captureAreaSave, .captureAreaAnnotate, .captureAreaPin]]),
            ("Screen Recording", "video", [[.recordScreen, .pauseRecording]]),
            ("Scrolling Capture", "arrow.down", [[.scrollingCapture]]),
            ("OCR", "text.viewfinder", [[.captureText]])
        ]
        for (title, symbol, boxes) in groups {
            var first = true
            for actions in boxes {
                let matching = actions.filter { query.isEmpty || $0.title.lowercased().contains(query) }
                section(first ? title : nil, symbol: symbol, matching.map { action in
                    let recorder = ShortcutRecorder(shortcut: Settings.shared.shortcut(for: action)) { shortcut in
                        Settings.shared.setShortcut(shortcut, for: action)
                    }
                    recorder.translatesAutoresizingMaskIntoConstraints = false
                    recorder.widthAnchor.constraint(equalToConstant: 180).isActive = true
                    recorders.append((action, recorder))
                    return row(action.title, recorder)
                })
                if !matching.isEmpty { first = false }
            }
        }
        guard query.isEmpty else { return }
        section("Options", [row("Click a shortcut, then press the new keys. Delete turns it off.",
                                button("Restore Defaults") { [weak self] in
            Settings.shared.resetShortcuts()
            self?.recorders.forEach { $0.1.shortcut = Settings.shared.shortcut(for: $0.0) }
        })])
    }
}

final class QuickAccessPane: SettingsPane {
    private var autoCloseRows: [NSView] = []

    override func build() {
        let s = Settings.shared
        let positions = Settings.PreviewPosition.allCases
        section("Appearance", [
            row("Position on screen", popup(positions.map(\.title), selected: positions.firstIndex(of: s.previewPosition) ?? 0) {
                s.previewPosition = positions[$0]
            }),
            row("Move to active screen", toggle({ s.previewOnActiveScreen }, { s.previewOnActiveScreen = $0 }),
                note: "Active screen is the screen where your cursor is pointing."),
            row("Overlay size", slider(s.previewScale, 0.7...1.3, ticks: 5) { s.previewScale = $0 })
        ])

        let delays = [5, 10, 30, 60]
        let interval = popup(["5 seconds", "10 seconds", "30 seconds", "1 minute"],
                             selected: delays.firstIndex(of: s.previewAutoClose) ?? 2) { s.previewAutoClose = delays[$0] }
        let action = popup(["Close", "Save and Close"], selected: s.autoCloseSaves ? 1 : 0) { s.autoCloseSaves = $0 == 1 }
        for control in [interval, action] { control.isEnabled = s.previewAutoClose > 0 }
        section("Behavior", [
            row("Auto-close", toggle({ s.previewAutoClose > 0 }, { on in
                s.previewAutoClose = on ? delays[interval.indexOfSelectedItem] : 0
                for control in [interval, action] { control.isEnabled = on }
            })),
            row("Action", action),
            row("Interval", interval)
        ])
        section(nil, [
            row("Close after dragging", toggle({ s.closePreviewAfterDragging }, { s.closePreviewAfterDragging = $0 }),
                note: "Closes the overlay once you drag the capture into another app."),
            row("Save button behavior", popup(["Save to “Export location”", "Ask where to save"],
                                              selected: s.saveButtonAsks ? 1 : 0) { s.saveButtonAsks = $0 == 1 })
        ])
    }
}

final class WallpaperPane: SettingsPane {
    private var choice: NSPopUpButton?

    override func build() {
        let s = Settings.shared
        let popup = popup(titles(), selected: s.customWallpaper == nil ? 0 : 1) { [weak self] index in
            self?.picked(index)
        }
        choice = popup
        section("Desktop", [
            row("Wallpaper", popup,
                note: "Set a custom wallpaper used to hide desktop icons and as the background behind window screenshots."),
            row("Update wallpaper when switching Spaces", toggle({ s.wallpaperFollowsSpaces }, { s.wallpaperFollowsSpaces = $0 }))
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
    override func build() {
        let s = Settings.shared
        let formats = ImageEncoder.available
        let presets = BackgroundPresets.all.map(\.name)
        var output = [
            row("File format", popup(formats.map(\.title), selected: formats.firstIndex(of: s.imageFormat) ?? 0) { [weak self] in
                s.imageFormat = formats[$0]
                self?.rebuild()
            })
        ]
        if s.imageFormat.isLossy {
            output.append(row("Quality", slider(s.jpegQuality, 0.3...1) { s.jpegQuality = $0 },
                              note: s.imageFormat == .webp ? "All the way right saves lossless WebP." : nil))
        }
        section("Output", output)
        section(nil, [
            row("Convert to sRGB profile", toggle({ s.convertToSRGB }, { s.convertToSRGB = $0 })),
            row("Scale Retina screenshots to 1x", toggle({ s.scaleScreenshotsTo1x }, { s.scaleScreenshotsTo1x = $0 })),
            row("Add 1px border to all screenshots", toggle({ s.addBorder }, { s.addBorder = $0 }))
        ])
        section(nil, [
            row("Background preset", popup(["None"] + presets,
                                           selected: (presets.firstIndex { $0 == s.autoBackgroundPreset } ?? -1) + 1) {
                s.autoBackgroundPreset = $0 == 0 ? nil : presets[$0 - 1]
            }, note: "Apply Background Tool preset to all screenshots. You can create presets in Annotate.")
        ])

        let delays = [3, 5, 10, 15]
        section("Capture", [
            row("Self-Timer interval", popup(["3 Seconds", "5 Seconds", "10 Seconds", "15 Seconds"],
                                             selected: delays.firstIndex(of: s.selfTimerSeconds) ?? 1) {
                s.selfTimerSeconds = delays[$0]
            }),
            row("Show cursor on screenshots", toggle({ s.showCursorInScreenshots }, { s.showCursorInScreenshots = $0 }),
                note: "This works in Fullscreen or Self-Timer modes only."),
            row("Place fullscreen captures on the wallpaper", toggle({ s.fullscreenOnWallpaper },
                                                                    { s.fullscreenOnWallpaper = $0 }))
        ])

        // Window background as two picture tiles, like the reference.
        let onWallpaper = s.windowStyle == .background
        let tiles = horizontal(
            tile("With wallpaper", selected: onWallpaper, wallpaper: true) { [weak self] in
                s.windowStyle = .background
                self?.rebuild()
            },
            tile("Transparent", selected: !onWallpaper, wallpaper: false) { [weak self] in
                s.windowStyle = s.windowStyle == .background ? .shadow : s.windowStyle
                self?.rebuild()
            })
        tiles.spacing = 14
        var window = [row("Background", tiles, note: "You can customize the wallpaper in Wallpaper settings.")]
        if onWallpaper {
            window.append(row("Padding", slider(s.windowPadding, 16...120, ticks: 8) { s.windowPadding = $0 }))
        } else {
            window.append(row("Capture window shadow", toggle({ s.windowStyle == .shadow }, {
                s.windowStyle = $0 ? .shadow : .transparent
            })))
        }
        section("Window Screenshots", window)
        // Below the box, right-aligned, like the reference.
        let reset = button("Reset Defaults") { [weak self] in
            UserDefaults.standard.removeObject(forKey: "windowStyle")
            UserDefaults.standard.removeObject(forKey: "windowPadding")
            self?.rebuild()
        }
        let resetRow = horizontal(NSView(), reset)
        resetRow.translatesAutoresizingMaskIntoConstraints = false
        block(resetRow)

        let magnifier = toggle({ s.showMagnifier }, { s.showMagnifier = $0 })
        magnifier.isEnabled = s.crosshairLines
        section("Crosshair", [
            row("Crosshair Mode", popup(["Disabled", "Enabled"], selected: s.crosshairLines ? 1 : 0) { on in
                s.crosshairLines = on == 1
                magnifier.isEnabled = on == 1
            }, note: "Shows guide lines across the screen through the cursor while selecting."),
            row("Show magnifier", magnifier, note: "To enable magnifier, you must enable Crosshair Mode first.")
        ])
    }

    /// A small picture of a window, on wallpaper or a checkerboard, with a caption.
    private func tile(_ title: String, selected: Bool, wallpaper: Bool, action: @escaping () -> Void) -> NSView {
        let picture = NSView()
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 8
        picture.layer?.masksToBounds = true
        picture.layer?.borderWidth = selected ? 2.5 : 0.5
        picture.layer?.borderColor = (selected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        if wallpaper {
            let gradient = CAGradientLayer()
            gradient.colors = [NSColor.systemOrange.cgColor, NSColor.systemBrown.cgColor]
            gradient.frame = CGRect(x: 0, y: 0, width: 84, height: 60)
            picture.layer?.addSublayer(gradient)
        } else {
            picture.layer?.backgroundColor = NSColor(patternImage: Self.checkerboard).cgColor
        }
        let window = CALayer()
        window.frame = CGRect(x: 16, y: 14, width: 52, height: 34)
        window.backgroundColor = NSColor.white.cgColor
        window.cornerRadius = 4
        window.shadowOpacity = 0.3
        window.shadowRadius = 3
        window.shadowOffset = CGSize(width: 0, height: -1)
        picture.layer?.addSublayer(window)
        picture.translatesAutoresizingMaskIntoConstraints = false
        picture.widthAnchor.constraint(equalToConstant: 84).isActive = true
        picture.heightAnchor.constraint(equalToConstant: 60).isActive = true
        let caption = NSTextField(labelWithString: title)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = selected ? .labelColor : .secondaryLabelColor
        let column = NSStackView(views: [picture, caption])
        column.orientation = .vertical
        column.spacing = 4
        let click = NSClickGestureRecognizer(target: target { _ in action() }, action: #selector(Callback.fire(_:)))
        column.addGestureRecognizer(click)
        return column
    }

    private static let checkerboard: NSImage = NSImage(size: CGSize(width: 12, height: 12), flipped: false) { rect in
        NSColor(white: 0.85, alpha: 1).setFill(); rect.fill()
        NSColor(white: 0.7, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 6, height: 6).fill()
        NSRect(x: 6, y: 6, width: 6, height: 6).fill()
        return true
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

final class AnnotatePane: SettingsPane {
    override func build() {
        let s = Settings.shared
        section("Tools", [
            row("Inverse arrow direction", toggle({ s.annotateInverseArrows }, { s.annotateInverseArrows = $0 }),
                note: "Press ⌥ (option) when drawing to invert the behavior."),
            row("Smooth drawing", toggle({ s.annotateSmoothDrawing }, { s.annotateSmoothDrawing = $0 })),
            row("Remember if background tool was opened", toggle({ s.annotateRememberBackground },
                                                                 { s.annotateRememberBackground = $0 })),
            row("Draw shadow on objects", toggle({ s.annotateShadows }, { s.annotateShadows = $0 })),
            row("Automatically expand canvas", toggle({ s.annotateAutoExpand }, { s.annotateAutoExpand = $0 }),
                note: "Ensures all annotations fit by dynamically resizing canvas.")
        ])
        section("Window", [
            row("Always on top", toggle({ s.annotateAlwaysOnTop }, { s.annotateAlwaysOnTop = $0 })),
            row("Show Dock icon", toggle({ s.annotateShowDockIcon }, { s.annotateShowDockIcon = $0 }),
                note: "Shows Clarishot in the Dock while an Annotate window is open.")
        ])
        section("Accessibility", [
            row("Show color names", toggle({ s.annotateColorNames }, { s.annotateColorNames = $0 }),
                note: "Shows each colour's name when you point at it in the colour picker.")
        ])
    }
}

final class AdvancedPane: SettingsPane {
    private static let languages: [(String, String)] = [
        ("Automatically Detect Language", ""), ("English", "en-US"), ("French", "fr-FR"), ("German", "de-DE"),
        ("Italian", "it-IT"), ("Spanish", "es-ES"), ("Portuguese", "pt-BR"), ("Chinese (Simplified)", "zh-Hans"),
        ("Chinese (Traditional)", "zh-Hant"), ("Japanese", "ja-JP"), ("Korean", "ko-KR"), ("Russian", "ru-RU"),
        ("Ukrainian", "uk-UA")
    ]

    override func build() {
        let s = Settings.shared
        section("File Name", [
            row("Ask for name after every capture", toggle({ s.askForName }, { s.askForName = $0 })),
            row("Screenshot name format", textField(s.screenshotNameTemplate, width: 220) { s.screenshotNameTemplate = $0 }),
            row("Recording name format", textField(s.recordingNameTemplate, width: 220) { s.recordingNameTemplate = $0 },
                note: "Use {date} and {time}, e.g. “Clarishot {date} at {time}”. Press Return to apply."),
            row("Add “@2x” suffix to Retina screenshots", toggle({ s.retinaSuffix }, { s.retinaSuffix = $0 }),
                note: "This option improves compatibility with displaying Retina screenshots in third-party apps.")
        ])
        let modes = Settings.ClipboardMode.allCases
        section("Clipboard", [
            row("Copy to clipboard", popup(modes.map(\.title), selected: modes.firstIndex(of: s.clipboardMode) ?? 0) {
                s.clipboardMode = modes[$0]
            }, note: "Adjust this option if you've encountered any issues with pasting from clipboard or clipboard managers.")
        ])
        let days = [0, 1, 3, 7, 30]
        section("Capture History", [
            row("Keep history", popup(["Never", "1 day", "3 days", "1 week", "1 month"],
                                      selected: days.firstIndex(of: s.historyDays) ?? 4) { s.historyDays = days[$0] },
                note: "You can restore old files with “Capture History” option from the menu bar.")
        ])
        let codes = Self.languages.map(\.1)
        section("Text Recognition", [
            row("Language", popup(Self.languages.map(\.0), selected: codes.firstIndex(of: s.ocrLanguage) ?? 0) {
                s.ocrLanguage = codes[$0]
            }),
            row("Keep line breaks", toggle({ s.keepLineBreaks }, { s.keepLineBreaks = $0 })),
            row("Detect links", toggle({ s.ocrDetectLinks }, { s.ocrDetectLinks = $0 }),
                note: "Reads QR codes and barcodes as links.")
        ])
        section("All-In-One", [
            row("Remember last selection", toggle({ s.allInOneRemember }, { s.allInOneRemember = $0 }))
        ])
        section("Pinned Screenshots", [
            row("Rounded corners", toggle({ s.pinRounded }, { s.pinRounded = $0 })),
            row("Shadow", toggle({ s.pinShadow }, { s.pinShadow = $0 })),
            row("Border", toggle({ s.pinBorder }, { s.pinBorder = $0 }))
        ])
        section("AI Tools & Command Line", [
            row("Allow AI tools & command line", toggle({ s.allowAgentAccess }, { s.allowAgentAccess = $0 }),
                note: "Lets the clarishot command-line tool and AI tools (via MCP) take screenshots, read text and list windows through Clarishot. Any app you run can use it while this is on."),
            row("Add to Claude Code", button("Copy Command") { AgentSetup.copy(AgentSetup.claudeCodeCommand) },
                note: "Copies a command to paste in Terminal."),
            row("Claude Desktop, Cursor and other MCP apps", button("Copy JSON") { AgentSetup.copy(AgentSetup.mcpJSON) }),
            row("Command-line tool", button("Install “clarishot” Command") { AgentSetup.installCommand() },
                note: "Adds clarishot to ~/.local/bin. Run “clarishot help” to see what it can do.")
        ])
        section("API", [
            row("Allow URL scheme API", toggle({ s.allowURLScheme }, { s.allowURLScheme = $0 }),
                note: "Lets other apps and scripts run captures with links like clarishot://capture-area or clarishot://record-screen.")
        ])
        section("Other", [
            row("", button("Reset All Preferences…") { [weak self] in self?.confirmReset() })
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
            rebuild()
        }
    }
}

final class AboutPane: NSViewController {
    override func loadView() {
        let icon = NSImageView(image: AppIcon.current)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 128).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 128).isActive = true
        let name = NSTextField(labelWithString: "Clarishot")
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

/// Helpers for connecting AI tools and the command line to Clarishot.
@MainActor
enum AgentSetup {
    static var cliPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/clarishot").path }

    static var claudeCodeCommand: String { "claude mcp add --scope user clarishot -- \"\(cliPath)\" mcp" }

    static var mcpJSON: String {
        """
        {
          "mcpServers": {
            "clarishot": { "command": "\(cliPath)", "args": ["mcp"] }
          }
        }
        """
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.show("Copied")
    }

    /// Links ~/.local/bin/clarishot to the tool inside the app.
    static func installCommand() {
        let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        let link = bin.appendingPathComponent("clarishot")
        do {
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: cliPath)
            let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").contains(bin.path)
            Toast.show(onPath ? "Installed: run “clarishot help”" : "Installed in ~/.local/bin (add it to your PATH)")
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// A small picture of a window in the System, Light or Dark style, with a caption.
final class ThemeTile: NSView {
    private let onClick: () -> Void

    init(theme: AppAppearance.Theme, selected: Bool, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        let picture = NSView()
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 8
        picture.layer?.cornerCurve = .continuous
        picture.layer?.masksToBounds = true
        picture.layer?.borderWidth = selected ? 2.5 : 0.5
        picture.layer?.borderColor = (selected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        let size = CGSize(width: 76, height: 50)
        func half(_ dark: Bool, _ frame: CGRect) {
            let pane = CALayer()
            pane.frame = frame
            pane.backgroundColor = (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
            picture.layer?.addSublayer(pane)
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                let dot = CALayer()
                dot.frame = CGRect(x: frame.minX + 6 + CGFloat(i) * 7, y: frame.maxY - 9, width: 4.5, height: 4.5)
                dot.cornerRadius = 2.25
                dot.backgroundColor = color.cgColor
                picture.layer?.addSublayer(dot)
            }
            let bar = CALayer()
            bar.frame = CGRect(x: frame.minX + 6, y: frame.minY + 8, width: frame.width - 12, height: 4)
            bar.cornerRadius = 2
            bar.backgroundColor = (dark ? NSColor(white: 0.35, alpha: 1) : NSColor(white: 0.82, alpha: 1)).cgColor
            picture.layer?.addSublayer(bar)
        }
        switch theme {
        case .system:
            half(false, CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
            half(true, CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        case .light: half(false, CGRect(origin: .zero, size: size))
        case .dark: half(true, CGRect(origin: .zero, size: size))
        }
        picture.translatesAutoresizingMaskIntoConstraints = false
        picture.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        picture.heightAnchor.constraint(equalToConstant: size.height).isActive = true

        let caption = NSTextField(labelWithString: theme.title)
        caption.font = .systemFont(ofSize: 11, weight: selected ? .semibold : .regular)
        caption.textColor = selected ? .controlAccentColor : .secondaryLabelColor
        let column = NSStackView(views: [picture, caption])
        column.orientation = .vertical
        column.spacing = 5
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) { onClick() }
}
