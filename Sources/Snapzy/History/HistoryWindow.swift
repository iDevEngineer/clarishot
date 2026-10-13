import AppKit

/// Capture History as a dark strip across the top of the screen: filters centred at the
/// top, a "…" menu on the right, and a row of captures that scrolls sideways.
/// Hover a capture to show Restore; double-click also restores; right-click for more.
/// Esc or clicking elsewhere closes it.
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private static var current: HistoryWindowController?

    static func show() {
        if let current {
            current.close()
            return
        }
        let controller = HistoryWindowController()
        current = controller
        controller.reload()
        NSApp.activate(ignoringOtherApps: true)
        controller.animateIn()
    }

    private static let slide: CGFloat = 24

    /// Slides down a little and fades in.
    private func animateIn() {
        let target = panel.frame
        panel.setFrame(target.offsetBy(dx: 0, dy: Self.slide), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private let panel: HistoryPanel
    private let collection = NSCollectionView()
    private var filterButtons: [HistoryFilterPill] = []
    private var filter: HistoryStore.Kind?
    private let emptyLabel = NSTextField(labelWithString: "")
    private var shown: [HistoryStore.Item] = []
    private var observer: NSObjectProtocol?
    private static let stripHeight: CGFloat = 176

    private override init() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let visible = screen.visibleFrame
        let frame = CGRect(x: visible.minX + 16, y: visible.maxY - Self.stripHeight - 8,
                           width: visible.width - 32, height: Self.stripHeight)
        panel = HistoryPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.close() }
        build()
        observer = NotificationCenter.default.addObserver(forName: HistoryStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// Slides up a little and fades out.
    private func close() {
        guard Self.current === self else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        Self.current = nil
        let panel = self.panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: Self.slide), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    func windowDidResignKey(_ notification: Notification) {
        // Close when you click elsewhere, but not while a menu or alert from the strip is open.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.panel.isKeyWindow, NSApp.modalWindow == nil else { return }
                self.close()
            }
        }
    }

    // MARK: Layout

    private func build() {
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        panel.contentView = background

        let kinds: [(String, HistoryStore.Kind?)] = [("All", nil), ("Screenshots", .screenshot),
                                                     ("Recordings", .recording), ("GIFs", .gif)]
        filterButtons = kinds.map { title, kind in
            let pill = HistoryFilterPill(title: title)
            pill.onClick = { [weak self] in
                self?.filter = kind
                self?.reload()
            }
            return pill
        }
        let filters = NSStackView(views: filterButtons)
        filters.spacing = 4

        let more = HistoryFilterPill(title: "", symbol: "ellipsis")
        more.onClick = { [weak self, weak more] in
            guard let self, let more else { return }
            self.showMoreMenu(from: more)
        }

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 150, height: 122)
        layout.minimumLineSpacing = 14
        layout.sectionInset = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        collection.collectionViewLayout = layout
        collection.isSelectable = false
        collection.dataSource = self
        collection.delegate = self
        collection.backgroundColors = [.clear]
        collection.register(HistoryCell.self, forItemWithIdentifier: HistoryCell.identifier)
        let scroll = SidewaysScrollView()
        scroll.documentView = collection
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .none

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        for v in [filters, more, scroll, emptyLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(v)
        }
        NSLayoutConstraint.activate([
            filters.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            filters.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            more.centerYAnchor.constraint(equalTo: filters.centerYAnchor),
            more.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
    }

    private func reload() {
        let kinds: [HistoryStore.Kind?] = [nil, .screenshot, .recording, .gif]
        for (pill, kind) in zip(filterButtons, kinds) { pill.isSelected = kind == filter }
        shown = HistoryStore.shared.items.filter { filter == nil || $0.kind == filter }
        collection.reloadData()
        if Settings.shared.historyDays == 0 {
            emptyLabel.stringValue = "Capture history is off. Turn it on in Settings → General."
        } else {
            emptyLabel.stringValue = shown.isEmpty ? "No captures yet." : ""
        }
        emptyLabel.isHidden = !shown.isEmpty && Settings.shared.historyDays > 0
    }

    private func showMoreMenu(from view: NSView) {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Keep History", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (title, days) in [("Never", 0), ("1 day", 1), ("3 days", 3), ("1 week", 7), ("1 month", 30)] {
            let item = ClosureMenuItem(title: title) { [weak self] in
                Settings.shared.historyDays = days
                self?.reload()
            }
            item.state = Settings.shared.historyDays == days ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Clear History…") { [weak self] in self?.clearAll() })
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: view.bounds.maxY + 4), in: view)
    }

    // MARK: Data

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { shown.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: HistoryCell.identifier, for: indexPath) as! HistoryCell
        let item = shown[indexPath.item]
        cell.configure(item)
        cell.onRestore = { [weak self] in self?.restore(item) }
        cell.menuProvider = { [weak self] in self?.menu(for: item) }
        return cell
    }

    // MARK: Actions

    private func menu(for item: HistoryStore.Item) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            menu.addItem(ClosureMenuItem(title: title, handler: action))
        }
        add("Restore") { [weak self] in self?.restore(item) }
        if item.kind == .screenshot {
            add("Open in Annotate") { [weak self] in self?.with(item, closing: true) { AnnotateWindowController.open($0) } }
            add("Pin to the Screen") { [weak self] in self?.with(item, closing: true) { PinWindow.pin($0) } }
        }
        add("Copy") { [weak self] in self?.with(item) { $0.copyToClipboard(); Toast.show("Copied to clipboard") } }
        add("Save to Export Folder") { [weak self] in
            self?.with(item) { capture in
                if (try? capture.save()) != nil { Toast.show(Capture.savedMessage) }
            }
        }
        add("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.shared.url(for: item)]) }
        menu.addItem(.separator())
        add("Delete") { HistoryStore.shared.delete(item) }
        return menu
    }

    /// Puts the capture back on a preview card.
    private func restore(_ item: HistoryStore.Item) {
        with(item, closing: true) { PreviewManager.shared.show($0) }
    }

    private func with(_ item: HistoryStore.Item, closing: Bool = false, _ action: @escaping (Capture) -> Void) {
        Task {
            guard let capture = await HistoryStore.shared.capture(for: item) else {
                Toast.show("That file is no longer available")
                return
            }
            if closing { close() }
            action(capture)
        }
    }

    private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Delete all capture history?"
        alert.informativeText = "This removes Snapzy's copies only. Files you saved elsewhere are kept."
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { HistoryStore.shared.clear() }
        panel.makeKeyAndOrderFront(nil)
    }
}

/// Borderless panel that can take key status (for Esc) and reports Esc.
final class HistoryPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// A vertical mouse wheel scrolls the row sideways.
final class SidewaysScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaX) < abs(event.scrollingDeltaY),
              let cgEvent = event.cgEvent?.copy() else {
            super.scrollWheel(with: event)
            return
        }
        // Swap the axes so up/down moves left/right.
        cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: event.cgEvent?.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) ?? 0)
        cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: event.cgEvent?.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) ?? 0)
        cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        if let swapped = NSEvent(cgEvent: cgEvent) { super.scrollWheel(with: swapped) } else { super.scrollWheel(with: event) }
    }
}

/// Small rounded filter tab ("All", "Screenshots"…) or icon button.
@MainActor
final class HistoryFilterPill: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { updateLook() } }
    private let label = NSTextField(labelWithString: "")

    init(title: String, symbol: String? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        let content: NSView
        if let symbol {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage())
            icon.contentTintColor = .white
            content = icon
        } else {
            label.stringValue = title
            label.font = .systemFont(ofSize: 12, weight: .medium)
            content = label
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        ])
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    private func updateLook() {
        layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.white.withAlphaComponent(0.08).cgColor
        label.textColor = isSelected ? .white : NSColor.white.withAlphaComponent(0.75)
    }
}

/// One capture: thumbnail with its app's icon, and "24 minutes" — or a Restore pill while hovered.
@MainActor
final class HistoryCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("HistoryCell")
    var onRestore: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    /// Fills the tile (cropping as needed) so every capture shows at the same size.
    private let thumb = NSView()
    private let badge = NSImageView()
    private let timeLabel = NSTextField(labelWithString: "")
    private var restoreButton: PillLabelButton!
    private var itemID: UUID?

    override func loadView() {
        let root = CellView()
        root.onDoubleClick = { [weak self] in self?.onRestore?() }
        root.onMenu = { [weak self] in self?.menuProvider?() }
        root.onHover = { [weak self] hovering in self?.setHover(hovering) }

        thumb.wantsLayer = true
        thumb.layer?.contentsGravity = .resizeAspectFill
        thumb.layer?.cornerRadius = 7
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        thumb.layer?.borderColor = NSColor.controlAccentColor.cgColor

        badge.wantsLayer = true
        badge.layer?.cornerRadius = 9
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        badge.contentTintColor = .white
        badge.symbolConfiguration = .init(pointSize: 9, weight: .bold)

        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        timeLabel.alignment = .center

        restoreButton = PillLabelButton(title: "Restore", symbol: "arrow.uturn.backward", light: false) { [weak self] in
            self?.onRestore?()
        }
        restoreButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        restoreButton.isHidden = true

        for v in [thumb, badge, timeLabel, restoreButton!] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            thumb.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            thumb.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            thumb.heightAnchor.constraint(equalToConstant: 84),
            badge.widthAnchor.constraint(equalToConstant: 22),
            badge.heightAnchor.constraint(equalToConstant: 22),
            badge.trailingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: -5),
            badge.bottomAnchor.constraint(equalTo: thumb.bottomAnchor, constant: -5),
            timeLabel.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 8),
            timeLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            restoreButton.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),
            restoreButton.centerXAnchor.constraint(equalTo: root.centerXAnchor)
        ])
        view = root
    }

    private func setHover(_ hovering: Bool) {
        thumb.layer?.borderWidth = hovering ? 2.5 : 0
        restoreButton.isHidden = !hovering
        timeLabel.isHidden = hovering
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setHover(false)
    }

    func configure(_ item: HistoryStore.Item) {
        itemID = item.id
        timeLabel.stringValue = Self.age(of: item.date)
        if let bundle = item.sourceBundleID, let icon = SourceApp.icon(for: bundle) {
            // The app it came from, e.g. the browser's own icon.
            badge.image = icon
            badge.symbolConfiguration = nil
            badge.layer?.backgroundColor = nil
            badge.imageScaling = .scaleProportionallyUpOrDown
        } else {
            let (symbol, color): (String, NSColor) = {
                switch item.kind {
                case .screenshot: return ("photo", .systemRed)
                case .recording: return ("video.fill", .systemBlue)
                case .gif: return ("sparkles", .systemPurple)
                }
            }()
            badge.symbolConfiguration = .init(pointSize: 9, weight: .bold)
            badge.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.kind.title)
            badge.layer?.backgroundColor = color.cgColor
        }
        let size = "\(Int(Double(item.pixelWidth) / item.scale)) × \(Int(Double(item.pixelHeight) / item.scale))"
        view.toolTip = "\(item.kind == .screenshot ? "Screenshot" : item.kind == .gif ? "GIF" : "Recording") · \(size)"
        thumb.layer?.contents = nil
        HistoryStore.shared.thumbnail(for: item) { [weak self] image in
            guard let self, self.itemID == item.id else { return }
            self.thumb.layer?.contents = image
        }
    }

    /// "Just now", "24 minutes", "4 days", "1 month"…
    private static func age(of date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.minute, .hour, .day, .weekOfMonth, .month, .year]
        return formatter.string(from: seconds) ?? ""
    }

    /// Handles double-click and right-click for the tile.
    private final class CellView: NSView {
        var onDoubleClick: (() -> Void)?
        var onMenu: (() -> NSMenu?)?
        var onHover: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            if event.clickCount == 2 { onDoubleClick?() }
        }

        override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
    }
}
