import AppKit
import UniformTypeIdentifiers

/// One finished screenshot or screen recording, and the things you can do with it.
/// For a recording, `image` is a thumbnail and `videoURL` points at the movie file.
@MainActor
final class Capture {
    let image: CGImage
    let scale: CGFloat
    let videoURL: URL?
    /// For a GIF: the movie it was made from, so it can be trimmed.
    let sourceVideoURL: URL?
    let duration: Double
    let date = Date()
    /// Bundle ID of the app the capture came from (for Capture History's icon).
    var sourceBundleID: String?

    /// Sets the source app and returns self, for chaining.
    func from(_ bundleID: String?) -> Capture {
        sourceBundleID = bundleID
        return self
    }

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

    /// A copy resized to one pixel per point (Settings → "Scale Retina screenshots to 1x").
    func scaledTo1x() -> Capture {
        guard scale > 1, !isVideo else { return self }
        let size = pointSize
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard let ctx = AnnotationRenderer.makeContext(width: width, height: height, like: image) else { return self }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = ctx.makeImage() else { return self }
        return Capture(image: scaled, scale: 1).from(sourceBundleID)
    }

    // MARK: Files

    /// Built from the name templates in Settings, e.g. "Clarishot 2026-10-13 at 09.41.07@2x.png".
    var fileName: String {
        let settings = Settings.shared
        if let videoURL {
            return "\(Self.expand(settings.recordingNameTemplate, date)).\(videoURL.pathExtension)"
        }
        let suffix = scale > 1 && settings.retinaSuffix ? "@\(Int(scale))x" : ""
        let ext = settings.imageFormat.fileExtension
        return "\(Self.expand(settings.screenshotNameTemplate, date))\(suffix).\(ext)"
    }

    /// Fills in `{date}` and `{time}` and removes characters that aren't allowed in file names.
    static func expand(_ template: String, _ date: Date) -> String {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.dateFormat = "HH.mm.ss"
        let name = template
            .replacingOccurrences(of: "{date}", with: day.string(from: date))
            .replacingOccurrences(of: "{time}", with: time.string(from: date))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Clarishot \(day.string(from: date)) at \(time.string(from: date))" : name
    }

    static func timestamp(_ date: Date) -> String {
        expand("{date} at {time}", date)
    }

    /// Encoded image in the format chosen in Settings.
    func imageData() -> Data? {
        let settings = Settings.shared
        return ImageEncoder.encode(image, as: settings.imageFormat, quality: settings.jpegQuality, pointSize: pointSize)
            ?? ImageEncoder.encode(image, as: .png, quality: 1, pointSize: pointSize)
    }

    /// Images go on the clipboard as pictures; recordings as the file itself.
    func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let videoURL {
            pasteboard.writeObjects([videoURL as NSURL])
            return
        }
        let mode = Settings.shared.clipboardMode
        // Offer PNG as well as TIFF: browsers and Electron apps (Slack, Chrome, VS Code) read PNG.
        let item = NSPasteboardItem()
        if mode != .file {
            let rep = NSBitmapImageRep(cgImage: image)
            rep.size = pointSize
            if let png = rep.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
            if let tiff = nsImage.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        }
        if mode != .image, let file = try? temporaryFile() {
            item.setString(file.absoluteString, forType: .fileURL)
        }
        pasteboard.writeObjects([item])
    }

    /// Saves to `directory`, or the export folder. With `ask` (or "Ask for name after every capture")
    /// a save panel picks the name and place; cancelling throws `CocoaError(.userCancelled)`.
    @discardableResult
    func save(to directory: URL? = nil, ask: Bool = false) throws -> URL {
        let folder = directory ?? Capture.saveDirectory
        var url = folder.appendingPathComponent(fileName)
        if directory == nil, ask || Settings.shared.askForName {
            let panel = NSSavePanel()
            panel.directoryURL = folder
            panel.nameFieldStringValue = fileName
            panel.canCreateDirectories = true
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let chosen = panel.url else { throw CocoaError(.userCancelled) }
            url = chosen
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let videoURL {
            if videoURL != url {
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.copyItem(at: videoURL, to: url)
            }
        } else {
            try imageData()?.write(to: url)
        }
        return url
    }

    /// A file to drag out or open in another app. Recordings already live in one.
    func temporaryFile() throws -> URL {
        if let videoURL { return videoURL }
        return try save(to: Capture.temporaryDirectory())
    }

    nonisolated static func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Clarishot", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The export folder from Settings (Desktop by default).
    static var saveDirectory: URL { Settings.shared.exportFolder }

    /// e.g. "Saved to Desktop"
    static var savedMessage: String { "Saved to \(saveDirectory.lastPathComponent)" }
}

/// The system's screenshot sound.
@MainActor
enum CaptureSound {
    private static let sound = NSSound(contentsOfFile:
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        byReference: true)

    static func play() {
        let name = Settings.shared.shutterSound
        let chosen = name.isEmpty ? sound : NSSound(named: NSSound.Name(name))
        chosen?.stop()
        chosen?.play()
    }

    /// Sounds offered in Settings (from /System/Library/Sounds).
    static var choices: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        return files.map { ($0 as NSString).deletingPathExtension }.sorted()
    }
}

extension Capture {
    /// Applies "Convert to sRGB" and "Add 1px border" from Settings to a screenshot.
    @MainActor
    func finishedForExport() -> Capture {
        guard !isVideo else { return self }
        let settings = Settings.shared
        guard settings.convertToSRGB || settings.addBorder else { return self }
        let space = settings.convertToSRGB ? CGColorSpace(name: CGColorSpace.sRGB)! : (image.colorSpace ?? CGColorSpaceCreateDeviceRGB())
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return self }
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.draw(image, in: full)
        if settings.addBorder {
            let width = max(scale, 1)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.25).cgColor)
            ctx.setLineWidth(width)
            ctx.stroke(full.insetBy(dx: width / 2, dy: width / 2))
        }
        guard let output = ctx.makeImage() else { return self }
        return Capture(image: output, scale: scale).from(sourceBundleID)
    }
}
