import AppKit
import UniformTypeIdentifiers

extension UTType {
    /// A re-editable Annotate project (.clarishot): the picture plus every shape, crop and background.
    static let clarishotProject = UTType(exportedAs: "com.scottmackey.clarishot.project", conformingTo: .json)
}

/// One shape in a form that can be written to a file or the clipboard.
struct AnnotationRecord: Codable {
    var tool: String
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint]
    var color: String
    var lineWidth: CGFloat
    var text: String
    var number: Int
    var style: Int
    var picture: Data?
    var dash: Int
    var arrowType: Int
    var startHead: Int
    var endHead: Int
    var control: CGPoint?
    var opacity: CGFloat
    var rotation: CGFloat
}

extension Annotation {
    var record: AnnotationRecord {
        AnnotationRecord(tool: "\(tool)", start: start, end: end, points: points, color: color.p3String,
                         lineWidth: lineWidth, text: text, number: number, style: style,
                         picture: picture.flatMap(AnnotateProject.png), dash: dash, arrowType: arrowType,
                         startHead: startHead, endHead: endHead, control: control, opacity: opacity, rotation: rotation)
    }

    init?(record r: AnnotationRecord) {
        guard let tool = Tool.allCases.first(where: { "\($0)" == r.tool }) else { return nil }
        self.init(tool: tool, start: r.start, end: r.end, color: NSColor(saved: r.color) ?? .systemRed, lineWidth: r.lineWidth)
        points = r.points
        text = r.text
        number = r.number
        style = r.style
        picture = r.picture.flatMap(AnnotateProject.image)
        dash = r.dash
        arrowType = r.arrowType
        startHead = r.startHead
        endHead = r.endHead
        control = r.control
        opacity = r.opacity
        rotation = r.rotation
    }
}

/// The file format behind "Save Project…": open it again later and every shape is still editable.
struct AnnotateProject: Codable {
    var format = "clarishot-project"
    var version = 1
    var scale: CGFloat
    var image: Data
    var crop: CGRect
    var background: BackgroundStyle
    var annotations: [AnnotationRecord]
    var sourceBundleID: String?
    /// A custom background picture, embedded so the project never refers to files by path.
    var backgroundPicture: Data?

    /// The background as saved: a custom picture's path is replaced by the embedded bytes.
    @MainActor static func packBackground(_ style: BackgroundStyle) -> (BackgroundStyle, Data?) {
        var style = style
        guard let spec = style.fillSpec, spec.hasPrefix("picture:") else { return (style, nil) }
        let url = URL(fileURLWithPath: String(spec.dropFirst("picture:".count)))
        let data = BackgroundFill.pictureImage(url).flatMap(png)
        style.fillSpec = data == nil ? nil : "picture:embedded"
        return (style, data)
    }

    /// The background to use when opening: values clamped, and a picture only from the embedded
    /// bytes (copied into Clarishot's own folder). A path written in the file is never read.
    func unpackedBackground() -> BackgroundStyle {
        var style = background
        style.padding = min(max(style.padding, 0), 400)
        style.cornerRadius = min(max(style.cornerRadius, 0), 100)
        style.inset = style.inset.map { min(max($0, 0), 200) }
        style.shadowAmount = style.shadowAmount.map { min(max($0, 0), 1) }
        style.alignment = style.alignment.map { min(max($0, 0), 8) }
        // Only known background kinds with strict formats; anything else is dropped.
        if let spec = style.fillSpec,
           spec.range(of: #"^(gradient:\d{1,3}|mesh:\d{1,3}|blur:\d|wallpaper|solid:P3 [0-9.]+ [0-9.]+ [0-9.]+|picture:embedded)$"#,
                      options: .regularExpression) == nil {
            style.fillSpec = nil
        }
        // Parse with the same code that draws it, so nothing that resolves to a file path slips through.
        if style.fillSpec != nil, case .picture = style.fill {
            style.fillSpec = nil
            if let data = backgroundPicture, Self.image(data) != nil,
               let folder = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true)
                    .appendingPathComponent("Clarishot/Project Pictures", isDirectory: true) {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent(UUID().uuidString + ".png")
                if (try? data.write(to: file)) != nil { style.fillSpec = "picture:" + file.path }
            }
        }
        return style
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func read(_ url: URL) throws -> AnnotateProject {
        let project = try JSONDecoder().decode(AnnotateProject.self, from: Data(contentsOf: url))
        guard project.format == "clarishot-project", (0.5...8).contains(project.scale)
        else { throw CocoaError(.fileReadCorruptFile) }
        return project
    }
}

/// Shapes on the clipboard, so they can be pasted into this or another editor window.
enum ShapeClipboard {
    static let type = NSPasteboard.PasteboardType("com.scottmackey.clarishot.shapes")

    static func write(_ shapes: [Annotation]) {
        guard let data = try? JSONEncoder().encode(shapes.map(\.record)) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: type)
    }

    static func read() -> [Annotation]? {
        guard let data = NSPasteboard.general.data(forType: type),
              let records = try? JSONDecoder().decode([AnnotationRecord].self, from: data) else { return nil }
        let shapes = records.compactMap(Annotation.init(record:))
        return shapes.isEmpty ? nil : shapes
    }
}
