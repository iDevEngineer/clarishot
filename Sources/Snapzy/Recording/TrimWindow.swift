import AppKit
import AVKit

/// Plays a recording with Apple's trim bar; "Trim" saves the kept part to the Desktop.
@available(macOS 15.0, *)
@MainActor
final class TrimWindowController: NSObject, NSWindowDelegate {
    private static var openControllers: [TrimWindowController] = []

    static func open(_ url: URL, makeGIF: Bool) {
        let controller = TrimWindowController(url: url, makeGIF: makeGIF)
        openControllers.append(controller)
        NSApp.activate(ignoringOtherApps: true)
        controller.window.makeKeyAndOrderFront(nil)
        controller.startTrimming()
    }

    private let url: URL
    private let makeGIF: Bool
    private let window: NSWindow
    private let playerView = AVPlayerView()

    private init(url: URL, makeGIF: Bool) {
        self.url = url
        self.makeGIF = makeGIF
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = makeGIF ? "Trim GIF" : "Trim Recording"
        window.delegate = self
        window.center()
        playerView.player = AVPlayer(url: url)
        playerView.controlsStyle = .inline
        window.contentView = playerView
    }

    /// Waits for the movie to load, then shows the trim bar.
    private func startTrimming() {
        Task {
            for _ in 0..<50 where !playerView.canBeginTrimming {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard playerView.canBeginTrimming else { return }
            let result = await playerView.beginTrimming()
            if result == .okButton { export() } else { window.close() }
        }
    }

    private func export() {
        guard let item = playerView.player?.currentItem else { return }
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
        let range = CMTimeRange(start: start, end: end)
        let name = "Snapzy Recording \(Capture.timestamp(Date())) (trimmed)"
        let asset = AVURLAsset(url: url)
        window.orderOut(nil)

        Task {
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
            session.timeRange = range
            do {
                let movie = makeGIF
                    ? try Capture.temporaryDirectory().appendingPathComponent("\(name).mp4")
                    : Capture.saveDirectory.appendingPathComponent("\(name).mp4")
                try? FileManager.default.removeItem(at: movie)
                try await session.export(to: movie, as: .mp4)
                if makeGIF {
                    guard let gif = await RecordingCoordinator.makeGIF(from: movie) else { window.close(); return }
                    let destination = Capture.saveDirectory.appendingPathComponent("\(name).gif")
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: gif, to: destination)
                    Toast.show("Trimmed GIF saved to Desktop")
                } else {
                    Toast.show("Trimmed recording saved to Desktop")
                }
            } catch {
                NSAlert(error: error).runModal()
            }
            window.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        Self.openControllers.removeAll { $0 === self }
    }
}
