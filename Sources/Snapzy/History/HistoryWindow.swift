import AppKit

/// Grid of recent captures. Double-click puts one back on a preview card;
/// right-click for Annotate, Copy, Save, Pin, Show in Finder and Delete.
@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate, NSCollectionViewDataSource,
                                     NSCollectionViewDelegate {
    private static var current: HistoryWindowController?

    static func show() {
        let controller = current ?? HistoryWindowController()
        current = controller
        controller.reload()
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private let collection = NSCollectionView()
    private let filter = NSSegmentedControl(labels: ["All", "Screenshots", "Recordings", "GIFs"],
                                            trackingMode: .selectOne, target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "")
    private var shown: [HistoryStore.Item] = []
    private var observer: NSObjectProtocol?

    private init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 860, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Capture History"
        window.minSize = CGSize(width: 520, height: 360)
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        build()
        window.center()
        observer = NotificationCenter.default.addObserver(forName: HistoryStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        Self.current = nil
    }

    // MARK: Layout

    private func build() {
        guard let content = window?.contentView else { return }
        filter.selectedSegment = 0
        filter.target = self
        filter.action = #selector(filterChanged)
        let clear = NSButton(title: "Clear All…", target: self, action: #selector(clearAll))
        clear.bezelStyle = .rounded
        let reveal = NSButton(title: "Show Folder", target: self, action: #selector(showFolder))
        reveal.bezelStyle = .rounded
        let top = NSStackView(views: [filter, NSView(), reveal, clear])
        top.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 190, height: 160)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.dataSource = self
        collection.delegate = self
        collection.backgroundColors = [.clear]
        collection.register(HistoryCell.self, forItemWithIdentifier: HistoryCell.identifier)
        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        for v in [top, scroll, emptyLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
    }

    private func reload() {
        let kinds: [HistoryStore.Kind?] = [nil, .screenshot, .recording, .gif]
        let kind = kinds[max(filter.selectedSegment, 0)]
        shown = HistoryStore.shared.items.filter { kind == nil || $0.kind == kind }
        collection.reloadData()
        if Settings.shared.historyDays == 0 {
            emptyLabel.stringValue = "Capture history is off. Turn it on in Settings → General."
        } else {
            emptyLabel.stringValue = shown.isEmpty ? "No captures yet." : ""
        }
        emptyLabel.isHidden = !shown.isEmpty && Settings.shared.historyDays > 0
    }

    // MARK: Data

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { shown.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: HistoryCell.identifier, for: indexPath) as! HistoryCell
        let item = shown[indexPath.item]
        cell.configure(item)
        cell.onOpen = { [weak self] in self?.restore(item) }
        cell.menuProvider = { [weak self] in self?.menu(for: item) }
        return cell
    }

    // MARK: Actions

    private func menu(for item: HistoryStore.Item) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            menu.addItem(ClosureMenuItem(title: title, handler: action))
        }
        add("Show in Quick Access") { [weak self] in self?.restore(item) }
        if item.kind == .screenshot {
            add("Open in Annotate") { [weak self] in self?.with(item) { AnnotateWindowController.open($0) } }
            add("Pin to the Screen") { [weak self] in self?.with(item) { PinWindow.pin($0) } }
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

    private func restore(_ item: HistoryStore.Item) {
        with(item) { PreviewManager.shared.show($0) }
    }

    private func with(_ item: HistoryStore.Item, _ action: @escaping (Capture) -> Void) {
        Task {
            guard let capture = await HistoryStore.shared.capture(for: item) else {
                Toast.show("That file is no longer available")
                return
            }
            action(capture)
        }
    }

    @objc private func filterChanged() { reload() }

    @objc private func showFolder() { NSWorkspace.shared.open(HistoryStore.shared.folder) }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Delete all capture history?"
        alert.informativeText = "This removes Snapzy's copies only. Files you saved elsewhere are kept."
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { HistoryStore.shared.clear() }
    }
}

/// One tile: thumbnail, date and type.
@MainActor
final class HistoryCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("HistoryCell")
    var onOpen: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private let thumb = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var itemID: UUID?

    override func loadView() {
        let root = CellView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 10
        root.onDoubleClick = { [weak self] in self?.onOpen?() }
        root.onMenu = { [weak self] in self?.menuProvider?() }
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 8
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        for v in [thumb, titleLabel, detail] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            thumb.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            thumb.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            thumb.heightAnchor.constraint(equalToConstant: 112),
            titleLabel.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            detail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8)
        ])
        view = root
    }

    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor : nil }
    }

    func configure(_ item: HistoryStore.Item) {
        itemID = item.id
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        titleLabel.stringValue = formatter.string(from: item.date)
        let size = "\(Int(Double(item.pixelWidth) / item.scale)) × \(Int(Double(item.pixelHeight) / item.scale))"
        switch item.kind {
        case .screenshot: detail.stringValue = "Screenshot · \(size)"
        case .recording, .gif:
            let s = Int(item.duration.rounded())
            detail.stringValue = "\(item.kind == .gif ? "GIF" : "Recording") · \(String(format: "%d:%02d", s / 60, s % 60))"
        }
        thumb.image = nil
        HistoryStore.shared.thumbnail(for: item) { [weak self] image in
            guard let self, self.itemID == item.id else { return }
            self.thumb.image = image
        }
    }

    /// Handles double-click and right-click for the tile.
    private final class CellView: NSView {
        var onDoubleClick: (() -> Void)?
        var onMenu: (() -> NSMenu?)?

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            if event.clickCount == 2 { onDoubleClick?() }
        }

        override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
    }
}
