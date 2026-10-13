import AppKit

/// One finished screenshot or screen recording, and the things you can do with it.
/// For a recording, `image` is a thumbnail and `videoURL` points at the movie file.
final class Capture {
    let image: CGImage
    let scale: CGFloat
    let videoURL: URL?
    /// For a GIF: the movie it was made from, so it can be trimmed.
    let sourceVideoURL: URL?
    let duration: Double
    let date = Date()

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = max(scale, 1)
        videoURL = nil
        sourceVideoURL = nil
        duration = 0
    }

    init(videoURL: URL, thumbnail: CGImage, scale: CGFloat, duration: Double, sourceVideoURL: URL? = nil) {
        image = thumbnail
        self.scale = max(scale, 1)
        self.videoURL = videoURL
        self.sourceVideoURL = sourceVideoURL
        self.duration = duration
    }

    var isVideo: Bool { videoURL != nil }
    var isGIF: Bool { videoURL?.pathExtension.lowercased() == "gif" }

    /// Size in points, so Retina captures display at their real size.
    var pointSize: CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    var nsImage: NSImage { NSImage(cgImage: image, size: pointSize) }

    /// e.g. "Snapzy 2026-10-13 at 09.41.07@2x.png" or "Snapzy Recording 2026-10-13 at 09.41.07.mp4"
    var fileName: String {
        let stamp = Capture.timestamp(date)
        if let videoURL { return "Snapzy Recording \(stamp).\(videoURL.pathExtension)" }
        let suffix = scale > 1 ? "@\(Int(scale))x" : ""
        return "Snapzy \(stamp)\(suffix).png"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }

    func pngData() -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Images go on the clipboard as pictures; recordings as the file itself.
    func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let videoURL {
            pasteboard.writeObjects([videoURL as NSURL])
        } else {
            pasteboard.writeObjects([nsImage])
        }
    }

    @discardableResult
    func save(to directory: URL = Capture.saveDirectory) throws -> URL {
        let url = directory.appendingPathComponent(fileName)
        if let videoURL {
            if videoURL != url {
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.copyItem(at: videoURL, to: url)
            }
        } else {
            try pngData()?.write(to: url)
        }
        return url
    }

    /// A file to drag out or open in another app. Recordings already live in one.
    func temporaryFile() throws -> URL {
        if let videoURL { return videoURL }
        return try save(to: Capture.temporaryDirectory())
    }

    static func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Snapzy", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var saveDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
}
