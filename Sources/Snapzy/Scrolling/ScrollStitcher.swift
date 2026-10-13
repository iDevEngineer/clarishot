import CoreGraphics
import Foundation

/// Joins successive frames of a scrolling area into one long image.
///
/// Each frame is reduced to a "signature": one grey value per row (sampled
/// across a few columns) for vertical scrolling, or per column for horizontal.
/// The scroll distance is the shift that best lines up the new frame's
/// signature with the previous one; the newly revealed strip is then appended.
/// Not thread-safe: use from one queue.
final class ScrollStitcher {
    enum Axis { case vertical, horizontal }

    enum Outcome {
        case appended(pixels: Int)
        case noMovement
        /// Frames didn't line up (scrolling too fast, upwards, or diagonally).
        case lost
        case limitReached
    }

    static let maxLength = 30_000

    let frameWidth: Int
    let frameHeight: Int
    private(set) var axis: Axis?
    private(set) var length: Int

    private let first: CGImage
    private var strips: [CGImage] = []
    private var reference: CGImage
    private var referenceSignatures: [Axis: Signature] = [:]
    private let samples = 48

    init(firstFrame: CGImage) {
        first = firstFrame
        reference = firstFrame
        frameWidth = firstFrame.width
        frameHeight = firstFrame.height
        length = firstFrame.height
    }

    var pixelSize: (width: Int, height: Int) {
        axis == .horizontal ? (length, frameHeight) : (frameWidth, length)
    }

    // MARK: Adding frames

    func add(_ frame: CGImage) -> Outcome {
        guard frame.width == frameWidth, frame.height == frameHeight else { return .lost }
        if length >= Self.maxLength { return .limitReached }

        let axes: [Axis] = axis.map { [$0] } ?? [.vertical, .horizontal]
        var best: (axis: Axis, offset: Int, score: Double, still: Double)?
        for a in axes {
            let old = signature(of: reference, axis: a, cacheAsReference: true)
            let new = signature(of: frame, axis: a, cacheAsReference: false)
            let (offset, score, still) = Self.bestOffset(old: old, new: new)
            if best == nil || (offset > 0 && (best!.offset == 0 || score < best!.score)) {
                best = (a, offset, score, still)
            }
        }
        guard let match = best else { return .lost }

        // Nothing moved: the frame matches the reference without shifting.
        if match.still < 1.5 { return .noMovement }
        // A good match must be close and clearly better than "no shift".
        guard match.offset > 0, match.score < 8, match.score < match.still * 0.5 else { return .lost }

        if axis == nil {
            axis = match.axis
            length = match.axis == .vertical ? frameHeight : frameWidth
        }
        let offset = min(match.offset, Self.maxLength - length)
        guard let strip = Self.copyStrip(of: frame, axis: match.axis, length: offset) else { return .lost }
        strips.append(strip)
        length += offset
        reference = frame
        referenceSignatures = [:]
        return .appended(pixels: offset)
    }

    // MARK: Output

    /// The whole stitched image at full resolution.
    func compose() -> CGImage? {
        render(scale: 1)
    }

    /// A small copy for the live preview, at most `maxWidth` pixels wide.
    func preview(maxWidth: Int) -> CGImage? {
        let across = axis == .horizontal ? frameHeight : frameWidth
        return render(scale: min(1, CGFloat(maxWidth) / CGFloat(max(across, 1))))
    }

    private func render(scale: CGFloat) -> CGImage? {
        let (w, h) = pixelSize
        let width = max(Int(CGFloat(w) * scale), 1)
        let height = max(Int(CGFloat(h) * scale), 1)
        let space = first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = scale < 1 ? .medium : .none
        ctx.scaleBy(x: scale, y: scale)

        // Place pieces from the start (top or left). CG's origin is bottom-left.
        var cursor = 0
        for (index, piece) in ([first] + strips).enumerated() {
            if axis == .horizontal {
                ctx.draw(piece, in: CGRect(x: cursor, y: 0, width: piece.width, height: piece.height))
                cursor += index == 0 ? first.width : piece.width
            } else {
                let y = h - cursor - piece.height
                ctx.draw(piece, in: CGRect(x: 0, y: y, width: piece.width, height: piece.height))
                cursor += piece.height
            }
        }
        return ctx.makeImage()
    }

    // MARK: Matching

    /// Grey values along the axis: `values[line * samples + sample]`.
    private struct Signature {
        let lines: Int
        let samples: Int
        let values: [Float]
    }

    private func signature(of image: CGImage, axis: Axis, cacheAsReference: Bool) -> Signature {
        if cacheAsReference, let cached = referenceSignatures[axis] { return cached }
        let lines = axis == .vertical ? image.height : image.width
        // Squash the other direction down to `samples` pixels.
        let width = axis == .vertical ? samples : lines
        let height = axis == .vertical ? lines : samples
        var buffer = [UInt8](repeating: 0, count: width * height)
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var values = [Float](repeating: 0, count: lines * samples)
        for line in 0..<lines {
            for s in 0..<samples {
                // Buffer row 0 is the top of the image.
                let pixel = axis == .vertical ? buffer[line * width + s] : buffer[s * width + line]
                values[line * samples + s] = Float(pixel)
            }
        }
        let result = Signature(lines: lines, samples: samples, values: values)
        if cacheAsReference { referenceSignatures[axis] = result }
        return result
    }

    /// Finds how far the content moved toward the start (up or left).
    /// Returns the best shift, its average difference, and the difference with no shift.
    private static func bestOffset(old: Signature, new: Signature) -> (offset: Int, score: Double, still: Double) {
        let lines = old.lines, n = old.samples
        let maxShift = Int(Double(lines) * 0.85)
        let step = max(1, lines / 400) // compare every few lines on tall frames
        var bestOffset = 0
        var bestScore = Double.greatestFiniteMagnitude
        var still = Double.greatestFiniteMagnitude

        old.values.withUnsafeBufferPointer { o in
            new.values.withUnsafeBufferPointer { m in
                for shift in 0...maxShift {
                    var total: Float = 0
                    var count = 0
                    var line = 0
                    // new line `line` should equal old line `line + shift`.
                    while line + shift < lines {
                        let a = (line + shift) * n, b = line * n
                        for s in 0..<n { total += abs(o[a + s] - m[b + s]) }
                        count += n
                        line += step
                    }
                    let score = count > 0 ? Double(total) / Double(count) : .greatestFiniteMagnitude
                    if shift == 0 { still = score; continue }
                    if score < bestScore - 0.01 {
                        bestScore = score
                        bestOffset = shift
                    }
                }
            }
        }
        return (bestOffset, bestScore, still)
    }

    /// Copies the newly revealed end of a frame (bottom rows or right columns).
    private static func copyStrip(of frame: CGImage, axis: Axis, length: Int) -> CGImage? {
        guard length > 0 else { return nil }
        let rect = axis == .vertical
            ? CGRect(x: 0, y: frame.height - length, width: frame.width, height: length)
            : CGRect(x: frame.width - length, y: 0, width: length, height: frame.height)
        guard let cropped = frame.cropping(to: rect) else { return nil }
        // Copy so the full frame's memory can be released.
        let space = frame.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return ctx.makeImage()
    }
}
