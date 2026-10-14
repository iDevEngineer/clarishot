import AppKit
import Vision

/// Where things in a screenshot line up: strong straight edges (for snapping the crop) and
/// lines of text (for snapping the highlighter). Worked out once per picture, off the main thread.
/// All values are in image points with a top-left origin, like annotations.
final class SnapGuides: @unchecked Sendable {
    private(set) var verticalEdges: [CGFloat] = []   // x positions
    private(set) var horizontalEdges: [CGFloat] = [] // y positions
    private(set) var textLines: [CGRect] = []
    private(set) var isReady = false

    init(image: CGImage, pointSize: CGSize) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let edges = Self.findEdges(image, pointSize: pointSize)
            let lines = Self.findTextLines(image, pointSize: pointSize)
            DispatchQueue.main.async {
                self.verticalEdges = edges.vertical
                self.horizontalEdges = edges.horizontal
                self.textLines = lines
                self.isReady = true
            }
        }
    }

    /// The nearest edge within `tolerance`, or `value` itself.
    static func snap(_ value: CGFloat, to positions: [CGFloat], tolerance: CGFloat) -> CGFloat {
        guard let nearest = positions.min(by: { abs($0 - value) < abs($1 - value) }),
              abs(nearest - value) <= tolerance else { return value }
        return nearest
    }

    /// The text line a point sits on (a little leeway above and below).
    func textLine(at point: CGPoint) -> CGRect? {
        textLines.first { $0.insetBy(dx: -6, dy: -4).contains(point) }
    }

    // MARK: Edges

    /// Columns and rows where brightness jumps across most of their length: panel borders,
    /// window edges, dividers. Uses a small greyscale copy for speed.
    private static func findEdges(_ image: CGImage, pointSize: CGSize) -> (vertical: [CGFloat], horizontal: [CGFloat]) {
        let scale = min(1, 900 / CGFloat(max(image.width, image.height)))
        let w = max(Int(CGFloat(image.width) * scale), 2), h = max(Int(CGFloat(image.height) * scale), 2)
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return ([], []) }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // CGContext rows run bottom-up; flip so row 0 is the top.
        func px(_ x: Int, _ y: Int) -> Int { Int(pixels[(h - 1 - y) * w + x]) }

        // For each column / row: the longest unbroken run where brightness steps across it.
        // Long runs are borders and dividers; short, scattered ones are text and photos.
        let step = 6
        var colRun = [Int](repeating: 0, count: w)
        var rowRun = [Int](repeating: 0, count: h)
        for x in 1..<w {
            var run = 0, best = 0
            for y in 0..<h {
                if abs(px(x, y) - px(x - 1, y)) > step { run += 1; best = max(best, run) } else { run = 0 }
            }
            colRun[x] = best
        }
        for y in 1..<h {
            var run = 0, best = 0
            for x in 0..<w {
                if abs(px(x, y) - px(x, y - 1)) > step { run += 1; best = max(best, run) } else { run = 0 }
            }
            rowRun[y] = best
        }
        func peaks(_ score: [Int], length: Int, toPoints: CGFloat) -> [CGFloat] {
            let minimum = max(length / 10, 20)
            var result: [CGFloat] = []
            for i in 1..<(score.count - 1) where score[i] >= minimum && score[i] >= score[i - 1] && score[i] >= score[i + 1] {
                result.append(CGFloat(i) * toPoints)
            }
            return result
        }
        var vertical = peaks(colRun, length: h, toPoints: pointSize.width / CGFloat(w))
        var horizontal = peaks(rowRun, length: w, toPoints: pointSize.height / CGFloat(h))
        vertical += [0, pointSize.width]
        horizontal += [0, pointSize.height]
        return (vertical, horizontal)
    }

    // MARK: Text

    private static func findTextLines(_ image: CGImage, pointSize: CGSize) -> [CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).map { obs in
            let b = obs.boundingBox
            return CGRect(x: b.minX * pointSize.width, y: (1 - b.maxY) * pointSize.height,
                          width: b.width * pointSize.width, height: b.height * pointSize.height)
        }
    }
}
