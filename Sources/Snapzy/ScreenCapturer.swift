import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case displayNotFound
    case windowNotFound

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "The display could not be found."
        case .windowNotFound: return "The window is no longer on screen."
        }
    }
}

/// A frozen image of one screen, taken before the selection overlay appears.
struct ScreenShot {
    let screen: NSScreen
    let image: CGImage
}

/// An on-screen window that can be picked in window-capture mode.
struct WindowTarget {
    let id: CGWindowID
    let frame: CGRect // AppKit global coordinates (bottom-left origin)
}

@MainActor
enum ScreenCapturer {
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.uint32Value ?? CGMainDisplayID()
    }

    /// Captures every screen at full Retina resolution, leaving out Snapzy's own windows.
    static func captureAllScreens() async throws -> [ScreenShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        // Keep the wallpaper cover in shots so hidden desktop icons stay hidden.
        let coverIDs = Set(DesktopIconHider.shared.windows.map { CGWindowID($0.windowNumber) })
        let keep = content.windows.filter { coverIDs.contains($0.windowID) }
        var shots: [ScreenShot] = []
        for screen in NSScreen.screens {
            let id = displayID(for: screen)
            guard let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: keep)
            let config = SCStreamConfiguration()
            config.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
            config.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
            config.showsCursor = Settings.shared.showCursorInScreenshots
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            shots.append(ScreenShot(screen: screen, image: image))
        }
        if shots.isEmpty { throw CaptureError.displayNotFound }
        return shots
    }

    /// Captures a single window on its own, with transparent corners.
    static func captureWindow(id: CGWindowID) async throws -> (CGImage, CGFloat) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.windowNotFound }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = Settings.shared.showCursorInScreenshots
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    /// Normal app windows currently on screen, front-most first.
    static func windowTargets() -> [WindowTarget] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict),
                  cgBounds.width > 40, cgBounds.height > 40
            else { return nil }
            // Window-server coordinates have a top-left origin; flip into AppKit's.
            let frame = CGRect(x: cgBounds.minX, y: primaryHeight - cgBounds.maxY,
                               width: cgBounds.width, height: cgBounds.height)
            return WindowTarget(id: id, frame: frame)
        }
    }

    /// Crops a frozen screen image to a rectangle given in screen-local points.
    static func crop(_ shot: ScreenShot, to rect: CGRect) -> CGImage? {
        let size = shot.screen.frame.size
        let sx = CGFloat(shot.image.width) / size.width
        let sy = CGFloat(shot.image.height) / size.height
        let pixelRect = CGRect(x: rect.minX * sx, y: (size.height - rect.maxY) * sy,
                               width: rect.width * sx, height: rect.height * sy).integral
        return shot.image.cropping(to: pixelRect)
    }

    /// Reads the text in an image using Apple's Vision framework.
    /// Text plus any QR code / barcode contents (see `TextRecognizer`).
    static func recognizeText(in image: CGImage) async -> String {
        let keepLineBreaks = Settings.shared.keepLineBreaks
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: TextRecognizer.recognize(image, keepLineBreaks: keepLineBreaks))
            }
        }
    }
}
