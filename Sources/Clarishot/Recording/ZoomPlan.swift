import AVFoundation
import CoreImage

/// One zoom on the timeline: from `start` to `end` seconds, `scale`× magnification, centred on
/// `center` (0…1 within the frame, top-left origin). It eases in and out at each end.
struct ZoomSegment: Codable, Equatable {
    var start: Double
    var end: Double
    var scale: Double = 2
    var center = CGPoint(x: 0.5, y: 0.5)
    /// Pan smoothly after the pointer instead of holding `center`.
    var follow = false

    var duration: Double { end - start }
}

/// The zooms for one recording, and the maths that turns them into a camera position.
struct ZoomPlan: Equatable {
    var segments: [ZoomSegment] = []
    /// The pointer's path while recording (time-sorted), for zooms that follow the cursor.
    var cursor: [RecordedClick] = []

    /// Time taken to zoom in or out at each end of a segment.
    static let ramp = 0.45
    static let minLength = 0.6

    /// Zooms placed automatically at each click: from just before it to a moment after.
    /// Nearby clicks close in time share one zoom that follows them.
    static func automatic(from clicks: [RecordedClick], cursor: [RecordedClick] = [], duration: Double,
                          scale: Double = 2) -> ZoomPlan {
        var segments: [ZoomSegment] = []
        for click in clicks.sorted(by: { $0.t < $1.t }) {
            let start = max(0, click.t - 0.6), end = min(duration, click.t + 2.2)
            guard end - start >= minLength else { continue }
            let point = CGPoint(x: click.x, y: click.y)
            if var last = segments.last, start <= last.end + 0.4,
               hypot(point.x - last.center.x, point.y - last.center.y) < 0.35 {
                // Close in time and space: extend the current zoom and move its focus between the clicks.
                last.end = max(last.end, end)
                last.center = CGPoint(x: (last.center.x + point.x) / 2, y: (last.center.y + point.y) / 2)
                segments[segments.count - 1] = last
            } else {
                let begin = max(start, segments.last?.end ?? 0)
                guard end - begin >= minLength else { continue }
                segments.append(ZoomSegment(start: begin, end: end, scale: scale, center: point, follow: !cursor.isEmpty))
            }
        }
        return ZoomPlan(segments: segments, cursor: cursor)
    }

    /// Where the pointer was at `t` (the last sample at or before it).
    private func pointer(at t: Double) -> CGPoint? {
        guard let first = cursor.first else { return nil }
        if t <= first.t { return CGPoint(x: first.x, y: first.y) }
        var low = 0, high = cursor.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if cursor[mid].t <= t { low = mid } else { high = mid - 1 }
        }
        return CGPoint(x: cursor[low].x, y: cursor[low].y)
    }

    /// The pointer averaged over about 0.8 s around `t`, weighted toward `t`, so the camera glides.
    func smoothedPointer(at t: Double) -> CGPoint? {
        guard !cursor.isEmpty else { return nil }
        var sum = CGPoint.zero, weights = 0.0
        for k in -8...8 {
            guard let p = pointer(at: t + Double(k) * 0.05) else { continue }
            let w = 9 - Double(abs(k))
            sum.x += p.x * w; sum.y += p.y * w; weights += w
        }
        return weights > 0 ? CGPoint(x: sum.x / weights, y: sum.y / weights) : nil
    }

    /// Magnification and centre at time `t`.
    func camera(at t: Double) -> (scale: Double, center: CGPoint) {
        guard let segment = segments.first(where: { t >= $0.start && t <= $0.end }) else {
            return (1, CGPoint(x: 0.5, y: 0.5))
        }
        let ramp = min(Self.ramp, segment.duration / 2)
        let progress: Double
        if t < segment.start + ramp {
            progress = (t - segment.start) / ramp
        } else if t > segment.end - ramp {
            progress = (segment.end - t) / ramp
        } else {
            progress = 1
        }
        let eased = progress * progress * (3 - 2 * progress) // smoothstep
        let center = segment.follow ? (smoothedPointer(at: t) ?? segment.center) : segment.center
        return (1 + (segment.scale - 1) * eased, center)
    }

    /// The source rectangle (0…1, top-left origin) shown at time `t`.
    func visibleRect(at t: Double) -> CGRect {
        let camera = camera(at: t)
        let w = 1 / camera.scale, h = 1 / camera.scale
        let x = min(max(camera.center.x - w / 2, 0), 1 - w)
        let y = min(max(camera.center.y - h / 2, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// A video composition that applies the zooms, used for both the preview and the export.
    /// `showZoom: false` shows the plain frames (while placing a zoom's centre).
    func composition(for asset: AVAsset, showZoom: Bool = true) async throws -> AVVideoComposition {
        let plan = self
        return try await AVVideoComposition.videoComposition(with: asset) { request in
            let source = request.sourceImage
            let extent = source.extent
            let t = request.compositionTime.seconds
            guard showZoom, plan.camera(at: t).scale > 1.001 else {
                request.finish(with: source, context: nil)
                return
            }
            let visible = plan.visibleRect(at: t)
            // Core Image has a bottom-left origin.
            let crop = CGRect(x: extent.minX + visible.minX * extent.width,
                              y: extent.minY + (1 - visible.maxY) * extent.height,
                              width: visible.width * extent.width, height: visible.height * extent.height)
            let zoom = extent.width / crop.width
            let output = source.cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .transformed(by: CGAffineTransform(scaleX: zoom, y: zoom))
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
                .cropped(to: extent)
            request.finish(with: output, context: nil)
        }
    }

    /// Writes a new movie with the zooms applied.
    func export(_ asset: AVAsset, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        session.videoComposition = try await composition(for: asset)
        try? FileManager.default.removeItem(at: url)
        try await session.export(to: url, as: .mp4)
    }
}
