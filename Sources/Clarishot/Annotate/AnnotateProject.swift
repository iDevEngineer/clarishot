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
        guard project.format == "clarishot-project" else { throw CocoaError(.fileReadCorruptFile) }
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
