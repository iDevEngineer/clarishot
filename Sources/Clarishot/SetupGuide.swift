import AppKit
import AVFoundation

/// The first-run setup guide: Welcome → Permissions → Shortcuts → Ready.
/// Opens on first launch, and later from "Setup Guide…" in the menu.
@MainActor
final class SetupGuideController: NSObject, NSWindowDelegate {
    private static var shared: SetupGuideController?

    /// `atPermissions`: reopen on the permissions page (after restarting for Screen Recording).
    static func show(atPermissions: Bool = false, page index: Int? = nil) {
        let controller = shared ?? SetupGuideController()
        shared = controller
        if atPermissions { controller.page = .permissions }
        if let index, let page = Page(rawValue: index) { controller.page = page }
        NSApp.activate(ignoringOtherApps: true)
        controller.window.makeKeyAndOrderFront(nil)
    }

    private enum Page: Int, CaseIterable { case welcome, permissions, shortcuts, ready }

    private let window: NSWindow
    private let body = NSView()
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let nextButton = NSButton(title: "Continue", target: nil, action: nil)
    private let dots = NSStackView()
    private var page: Page = .welcome { didSet { showPage() } }
    private var statusTimer: Timer?
    private var permissionRows: [PermissionRow] = []

    private override init() {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 540),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to Clarishot"
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.center()
        build()
        window.useRoundedCorners()
        showPage()
    }

    private func build() {
        let content = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(back)
        nextButton.bezelStyle = .rounded
        nextButton.bezelColor = .controlAccentColor
        nextButton.keyEquivalent = "\r"
        nextButton.target = self
        nextButton.action = #selector(next)
        dots.spacing = 6
        let footer = NSStackView(views: [backButton, NSView(), dots, NSView(), nextButton])
        footer.translatesAutoresizingMaskIntoConstraints = false
        for view in [body, footer] as [NSView] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 40),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -40),
            body.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -20),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            footer.heightAnchor.constraint(equalToConstant: 32)
        ])
        window.contentView = content
    }

    // MARK: Pages

    private func showPage() {
        body.subviews.forEach { $0.removeFromSuperview() }
        statusTimer?.invalidate()
        statusTimer = nil
        let view: NSView
        switch page {
        case .welcome: view = welcomePage()
        case .permissions: view = permissionsPage()
        case .shortcuts: view = shortcutsPage()
        case .ready: view = readyPage()
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: body.topAnchor),
            view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: body.trailingAnchor)
        ])
        backButton.isHidden = page == .welcome
        nextButton.title = page == .ready ? "Start Using Clarishot" : (page == .welcome ? "Get Started" : "Continue")
        dots.setViews(Page.allCases.map { p in
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = (p == page ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: p == page ? 18 : 7).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
            return dot
        }, in: .center)
    }

    private func welcomePage() -> NSView {
        let icon = NSImageView(image: AppIcon.current)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 112).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 112).isActive = true
        let title = label("Welcome to Clarishot", size: 28, weight: .bold)
        let subtitle = label("Screenshots and screen recordings for your Mac: capture anything, mark it up, " +
                             "and share it in seconds.", size: 14, color: .secondaryLabelColor)
        let points = NSStackView(views: [
            point("viewfinder", "Capture an area, a window, a scrolling page or a single button"),
            point("pencil.and.outline", "Annotate with arrows, text, blur and backgrounds"),
            point("record.circle", "Record video or GIFs, with zooms that follow your clicks"),
            point("text.viewfinder", "Copy text out of anything on screen")
        ])
        points.orientation = .vertical
        points.alignment = .leading
        points.spacing = 12
        let stack = NSStackView(views: [icon, title, subtitle, points])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(26, after: subtitle)
        return stack
    }

    private func permissionsPage() -> NSView {
        let title = label("A few permissions", size: 24, weight: .bold)
        let subtitle = label("macOS asks you to allow these once. Only Screen Recording is needed to take " +
                             "screenshots; the others switch on extra features.", size: 13, color: .secondaryLabelColor)
        permissionRows = Permission.allCases.map { PermissionRow(permission: $0) }
        let list = NSStackView(views: permissionRows)
        list.orientation = .vertical
        list.spacing = 10
        for row in permissionRows {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        let stack = NSStackView(views: [title, subtitle, list])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(22, after: subtitle)
        list.translatesAutoresizingMaskIntoConstraints = false
        list.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        // Keep the ticks live while the user flips switches in System Settings.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.permissionRows.forEach { $0.refresh() } }
        }
        return stack
    }

    private func shortcutsPage() -> NSView {
        let title = label("Your shortcuts", size: 24, weight: .bold)
        let subtitle = label("Press these from any app. Change any of them in Preferences → Shortcuts.",
                             size: 13, color: .secondaryLabelColor)
        let actions: [(ShortcutAction, String)] = [
            (.captureArea, "viewfinder"), (.allInOne, "square.grid.2x2"), (.captureWindow, "macwindow"),
            (.scrollingCapture, "arrow.down.to.line"), (.captureText, "text.viewfinder"), (.recordScreen, "record.circle")
        ]
        let rows = actions.map { action, symbol -> NSView in
            let keys = Settings.shared.shortcut(for: action)?.displayString ?? "Not set"
            let key = label(keys, size: 13, weight: .semibold)
            key.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
            let keyBox = NSView()
            keyBox.wantsLayer = true
            keyBox.layer?.cornerRadius = 6
            keyBox.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            key.translatesAutoresizingMaskIntoConstraints = false
            keyBox.addSubview(key)
            NSLayoutConstraint.activate([
                key.leadingAnchor.constraint(equalTo: keyBox.leadingAnchor, constant: 10),
                key.trailingAnchor.constraint(equalTo: keyBox.trailingAnchor, constant: -10),
                key.topAnchor.constraint(equalTo: keyBox.topAnchor, constant: 4),
                key.bottomAnchor.constraint(equalTo: keyBox.bottomAnchor, constant: -4)
            ])
            let row = NSStackView(views: [icon(symbol), label(action.title, size: 13), NSView(), keyBox])
            row.spacing = 10
            return row
        }
        let list = NSStackView(views: rows)
        list.orientation = .vertical
        list.spacing = 18
        for row in rows {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        // Same columns as the rows above: the box sits in the icon column, the text with the titles.
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleLogin(_:)))
        box.state = Settings.shared.launchAtLogin ? .on : .off
        loginBox = box
        let boxColumn = NSView()
        boxColumn.translatesAutoresizingMaskIntoConstraints = false
        box.translatesAutoresizingMaskIntoConstraints = false
        boxColumn.addSubview(box)
        NSLayoutConstraint.activate([
            boxColumn.widthAnchor.constraint(equalToConstant: 24),
            box.centerXAnchor.constraint(equalTo: boxColumn.centerXAnchor),
            box.centerYAnchor.constraint(equalTo: boxColumn.centerYAnchor),
            boxColumn.heightAnchor.constraint(equalTo: box.heightAnchor)
        ])
        let loginText = label("Open Clarishot when I log in", size: 13)
        loginText.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggleLoginText)))
        let login = NSStackView(views: [boxColumn, loginText])
        login.spacing = 10
        let stack = NSStackView(views: [title, subtitle, list, login])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(22, after: subtitle)
        stack.setCustomSpacing(22, after: list)
        list.translatesAutoresizingMaskIntoConstraints = false
        list.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func readyPage() -> NSView {
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 64, weight: .regular))!)
        check.contentTintColor = .systemGreen
        let title = label("You're all set", size: 28, weight: .bold)
        let keys = Settings.shared.shortcut(for: .captureArea)?.displayString ?? "Capture Area"
        let subtitle = label("Try it now: press \(keys) and drag over anything on screen. Clarishot lives in " +
                             "the menu bar; click its icon for every other option.", size: 14, color: .secondaryLabelColor)
        var views: [NSView] = [check, title, subtitle]
        if !CGPreflightScreenCaptureAccess() {
            let warning = label("Screen Recording isn't on yet, so captures won't work. Go back a step to turn it on.",
                                size: 13, color: .systemOrange)
            views.append(warning)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 14
        return stack
    }

    // MARK: Pieces

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.alignment = page == .welcome || page == .ready ? .center : .left
        field.preferredMaxLayoutWidth = 520
        return field
    }

    private func icon(_ symbol: String) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        view.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        view.contentTintColor = .controlAccentColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return view
    }

    private func point(_ symbol: String, _ text: String) -> NSView {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 13)
        let row = NSStackView(views: [icon(symbol), field])
        row.spacing = 10
        return row
    }

    // MARK: Actions

    @objc private func back() {
        if let previous = Page(rawValue: page.rawValue - 1) { page = previous }
    }

    @objc private func next() {
        if let following = Page(rawValue: page.rawValue + 1) { page = following; return }
        Settings.shared.setupGuideDone = true
        window.close()
    }

    private weak var loginBox: NSButton?

    @objc private func toggleLoginText() {
        guard let box = loginBox else { return }
        box.state = box.state == .on ? .off : .on
        toggleLogin(box)
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        Settings.shared.launchAtLogin = sender.state == .on
        sender.state = Settings.shared.launchAtLogin ? .on : .off
    }

    func windowWillClose(_ notification: Notification) {
        statusTimer?.invalidate()
        statusTimer = nil
        // Closing early still counts as seen; it's in the menu if needed again.
        Settings.shared.setupGuideDone = true
        Self.shared = nil
    }
}

// MARK: - Permissions

private enum Permission: CaseIterable {
    case screenRecording, accessibility, microphone, camera

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .microphone: return "Microphone"
        case .camera: return "Camera"
        }
    }

    var detail: String {
        switch self {
        case .screenRecording: return "Required. Lets Clarishot take screenshots and recordings."
        case .accessibility: return "Optional. Smart Capture, Paste on pins, Auto-Scroll and keystroke display."
        case .microphone: return "Optional. Your voice in screen recordings."
        case .camera: return "Optional. The camera bubble in screen recordings."
        }
    }

    var symbol: String {
        switch self {
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility: return "accessibility"
        case .microphone: return "mic"
        case .camera: return "video"
        }
    }

    var pane: String {
        switch self {
        case .screenRecording: return "Privacy_ScreenCapture"
        case .accessibility: return "Privacy_Accessibility"
        case .microphone: return "Privacy_Microphone"
        case .camera: return "Privacy_Camera"
        }
    }

    @MainActor var isGranted: Bool {
        switch self {
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .accessibility: return AXIsProcessTrusted()
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .camera: return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
    }

    /// Asks macOS (which shows its own prompt the first time), or opens the right System Settings page.
    @MainActor func request() {
        switch self {
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { openSettings() }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { openSettings() }
        case .microphone, .camera:
            let type: AVMediaType = self == .microphone ? .audio : .video
            if AVCaptureDevice.authorizationStatus(for: type) == .notDetermined {
                AVCaptureDevice.requestAccess(for: type) { _ in }
            } else {
                openSettings()
            }
        }
    }

    @MainActor private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// One permission: icon, name, what it's for, and a Grant button that turns into a tick.
@MainActor
private final class PermissionRow: NSView {
    private let permission: Permission
    private let button = NSButton(title: "Allow…", target: nil, action: nil)
    private let tick = NSImageView()
    private let note = NSTextField(labelWithString: "")
    /// Screen Recording only takes effect after a restart.
    private var wasGrantedAtStart: Bool

    init(permission: Permission) {
        self.permission = permission
        wasGrantedAtStart = permission.isGranted
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor

        let icon = NSImageView(image: NSImage(systemSymbolName: permission.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 17, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let title = NSTextField(labelWithString: permission.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: permission.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11, weight: .medium)
        note.textColor = .systemOrange
        note.isHidden = true
        let text = NSStackView(views: [title, detail, note])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(grant)
        tick.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Allowed")?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        tick.contentTintColor = .systemGreen
        let row = NSStackView(views: [icon, text, NSView(), tick, button])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Room above and below the text, set here because stack-view insets alone get squeezed.
            row.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func refresh() {
        let granted = permission.isGranted
        tick.isHidden = !granted
        button.isHidden = granted
        // Screen Recording switched on in System Settings needs a restart before macOS reports it.
        if permission == .screenRecording, !granted, !wasGrantedAtStart, button.title == "Restart" {
            note.stringValue = "Turned it on? Click Restart so macOS applies it."
            note.isHidden = false
        }
    }

    @objc private func grant() {
        if permission == .screenRecording, button.title == "Restart" {
            AppRestart.relaunch()
            return
        }
        permission.request()
        if permission == .screenRecording {
            button.title = "Restart"
            refresh()
        }
    }
}

/// Quits and opens Clarishot again (needed after granting Screen Recording).
enum AppRestart {
    @MainActor static func relaunch() {
        Settings.shared.setupGuideResume = true
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
