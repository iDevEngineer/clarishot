import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Keeps a copy of every capture for Preferences → General → "Keep capture history"
/// (off, 1 day, 1 week or 1 month). Files live in Application Support/Clarishot/History.
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()
    static let didChange = Notification.Name("ClarishotHistoryDidChange")

    enum Kind: String, Codable {
        case screenshot, recording, gif

        var title: String {
            switch self {
            case .screenshot: return "Screenshots"
            case .recording: return "Recordings"
            case .gif: return "GIFs"
            }
        }
    }

    struct Item: Codable, Equatable {
        let id: UUID
        let date: Date
        let kind: Kind
        let file: String     // file name inside the history folder
        let scale: Double
        let duration: Double
        let pixelWidth: Int
        let pixelHeight: Int
        /// The app it was captured from; missing for older captures.
        var sourceBundleID: String?
    }

    private(set) var items: [Item] = []
    private var thumbnails: [UUID: NSImage] = [:]

    let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clarishot/History", isDirectory: true)
    }()

    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    private init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
        prune()
    }

    // MARK: Adding

    func add(_ capture: Capture) {
        guard Settings.shared.historyDays > 0 else { return }
        let id = UUID()
        let kind: Kind = capture.isGIF ? .gif : (capture.isVideo ? .recording : .screenshot)
        let ext = capture.videoURL?.pathExtension ?? "png"
        let file = "\(id.uuidString).\(ext)"
        let url = folder.appendingPathComponent(file)
        let item = Item(id: id, date: capture.date, kind: kind, file: file, scale: capture.scale,
                        duration: capture.duration, pixelWidth: capture.image.width,
                        pixelHeight: capture.image.height, sourceBundleID: capture.sourceBundleID)
        if let video = capture.videoURL {
            do {
                try FileManager.default.copyItem(at: video, to: url)
                ClickLog.copy(from: capture.sourceVideoURL ?? video, to: url)
            } catch {
                return
            }
            insert(item)
            return
        }
        // Encoding a full-screen PNG takes tens of milliseconds, so it happens off the main thread;
        // the item appears once its file is written. One queue keeps captures in order.
        let image = capture.image
        Self.writer.async {
            // Always PNG here so history keeps full quality.
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.insert(item) } }
        }
    }

    private static let writer = DispatchQueue(label: "com.scottmackey.clarishot.history", qos: .utility)

    private func insert(_ item: Item) {
        items.insert(item, at: 0)
        save()
    }

    // MARK: Reading

    func url(for item: Item) -> URL { folder.appendingPathComponent(item.file) }

    /// Rebuilds a `Capture` so it can go back on a preview card, into Annotate, etc.
    func capture(for item: Item) async -> Capture? {
        let url = url(for: item)
        switch item.kind {
        case .screenshot:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return Capture(image: image, scale: item.scale)
        case .recording, .gif:
            guard let thumb = await Self.firstFrame(of: url) else { return nil }
            return Capture(videoURL: url, thumbnail: thumb, scale: 1, duration: item.duration)
        }
    }

    func thumbnail(for item: Item, completion: @escaping (NSImage?) -> Void) {
        if let cached = thumbnails[item.id] { completion(cached); return }
        let url = url(for: item)
        Task {
            var image: CGImage?
            if item.kind == .recording {
                image = await Self.firstFrame(of: url)
            } else {
                // Decoding a full-screen PNG takes ~70 ms; off the main thread, a window of them loads
                // in parallel instead of freezing the app while History opens.
                image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                    let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                   kCGImageSourceThumbnailMaxPixelSize: 480] as CFDictionary
                    return Perf.measure("history.thumbnail") { CGImageSourceCreateThumbnailAtIndex(source, 0, options) }
                }.value
            }
            let result = image.map { NSImage(cgImage: $0, size: CGSize(width: $0.width, height: $0.height)) }
            if let result { thumbnails[item.id] = result }
            completion(result)
        }
    }

    private static func firstFrame(of url: URL) async -> CGImage? {
        if url.pathExtension.lowercased() == "gif",
           let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        return try? await generator.image(at: .zero).image
    }

    // MARK: Removing

    func delete(_ item: Item) {
        try? FileManager.default.removeItem(at: url(for: item))
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        save()
    }

    func clear() {
        for item in items { try? FileManager.default.removeItem(at: url(for: item)) }
        items.removeAll()
        thumbnails.removeAll()
        save()
    }

    /// Drops items older than the chosen number of days (all of them if history is off).
    func prune() {
        let days = Settings.shared.historyDays
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let old = items.filter { days == 0 || $0.date < cutoff }
        guard !old.isEmpty else { return }
        for item in old { try? FileManager.default.removeItem(at: url(for: item)) }
        items.removeAll { old.contains($0) }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: indexURL, options: .atomic) }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
