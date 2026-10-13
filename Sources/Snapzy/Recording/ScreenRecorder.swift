import AppKit
import AVFoundation
import ScreenCaptureKit

/// Records part of one screen to MP4 using ScreenCaptureKit's built-in recording
/// output (macOS 15+). Pausing ends the current segment; resuming starts a new
/// one; finishing joins the segments into a single movie.
@available(macOS 15.0, *)
@MainActor
final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    /// Called if recording stops by itself (e.g. the display went away).
    var onUnexpectedStop: ((Error) -> Void)?
    /// Snapzy windows (camera, click rings, keystrokes, wallpaper cover) to show in the video.
    var includedWindows: [NSWindow] = []

    private let screen: NSScreen
    private let rect: CGRect // screen-local points, bottom-left origin
    private let options: RecordingOptions
    private var stream: SCStream?
    private var segments: [URL] = []
    private var segmentFinished: CheckedContinuation<Void, Never>?
    private var stopping = false

    private(set) var isPaused = false
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?

    /// Recorded time so far, not counting pauses.
    var elapsed: TimeInterval {
        accumulated + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0)
    }

    init(screen: NSScreen, rect: CGRect, options: RecordingOptions) {
        self.screen = screen
        self.rect = rect
        self.options = options
    }

    // MARK: Controls

    func start() async throws {
        try await startSegment()
    }

    func pause() async {
        guard !isPaused else { return }
        isPaused = true
        await stopSegment()
    }

    func resume() async throws {
        guard isPaused else { return }
        isPaused = false
        try await startSegment()
    }

    /// Stops and returns the finished movie.
    func finish() async throws -> URL {
        if !isPaused { await stopSegment() }
        return try await joinSegments()
    }

    /// Stops and deletes everything recorded.
    func discard() async {
        if !isPaused { await stopSegment() }
        segments.forEach { try? FileManager.default.removeItem(at: $0) }
        segments.removeAll()
    }

    // MARK: Segments

    private func startSegment() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let id = ScreenCapturer.displayID(for: screen)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.displayNotFound }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let includedIDs = Set(includedWindows.map { CGWindowID($0.windowNumber) })
        let keep = content.windows.filter { includedIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: keep)

        let scale = options.scaleTo1x ? 1 : screen.backingScaleFactor
        let config = SCStreamConfiguration()
        // ScreenCaptureKit wants a top-left origin within the display.
        config.sourceRect = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY, width: rect.width, height: rect.height)
        config.width = Self.even(rect.width * scale)
        config.height = Self.even(rect.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.showsCursor = options.showCursor
        config.queueDepth = 6
        config.capturesAudio = options.systemAudio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = options.microphone
        if let mic = options.microphoneDeviceID { config.microphoneCaptureDeviceID = mic }

        let url = try Capture.temporaryDirectory().appendingPathComponent("Segment \(UUID().uuidString).mp4")
        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = url
        recordingConfig.outputFileType = .mp4
        recordingConfig.videoCodecType = .h264

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        self.stream = stream
        segments.append(url)
        segmentStart = Date()
    }

    private func stopSegment() async {
        guard let stream else { return }
        stopping = true
        if let start = segmentStart { accumulated += Date().timeIntervalSince(start) }
        segmentStart = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            segmentFinished = continuation
            Task { try? await stream.stopCapture() }
            // Fallback in case the finish callback never arrives.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.segmentDidFinish() }
            }
        }
        self.stream = nil
        stopping = false
    }

    private func segmentDidFinish() {
        segmentFinished?.resume()
        segmentFinished = nil
    }

    private func joinSegments() async throws -> URL {
        let files = segments.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let first = files.first else { throw CocoaError(.fileNoSuchFile) }
        if files.count == 1 { return first }

        let composition = AVMutableComposition()
        for file in files {
            let asset = AVURLAsset(url: file)
            let duration = try await asset.load(.duration)
            try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                                  of: asset, at: composition.duration)
        }
        let output = try Capture.temporaryDirectory().appendingPathComponent("Recording \(UUID().uuidString).mp4")
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
        else { throw CocoaError(.fileWriteUnknown) }
        try await session.export(to: output, as: .mp4)
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        return output
    }

    // MARK: Delegates (called on background queues)

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.segmentDidFinish() }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            self.segmentDidFinish()
            if !self.stopping { self.onUnexpectedStop?(error) }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.segmentDidFinish()
            if !self.stopping { self.onUnexpectedStop?(error) }
        }
    }

    /// Video encoders need even pixel dimensions.
    private static func even(_ value: CGFloat) -> Int {
        let n = Int(value.rounded())
        return n % 2 == 0 ? n : n - 1
    }
}
