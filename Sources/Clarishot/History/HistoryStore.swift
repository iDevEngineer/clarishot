import AppKit
import AVFoundation

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
        do {
            if let video = capture.videoURL {
                try FileManager.default.copyItem(at: video, to: url)
            } else {
                // Always PNG here so history keeps full quality.
                let rep = NSBitmapImageRep(cgImage: capture.image)
                guard let png = rep.representation(using: .png, properties: [:]) else { return }
                try png.write(to: url)
            }
        } catch {
            return
        }
        items.insert(Item(id: id, date: capture.date, kind: kind, file: file, scale: capture.scale,
                          duration: capture.duration, pixelWidth: capture.image.width,
                          pixelHeight: capture.image.height, sourceBundleID: capture.sourceBundleID), at: 0)
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
            } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                               kCGImageSourceThumbnailMaxPixelSize: 480] as CFDictionary
                image = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
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
