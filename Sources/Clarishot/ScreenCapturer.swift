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

    /// Captures every screen at full Retina resolution, leaving out Clarishot's own windows.
    static func captureAllScreens() async throws -> [ScreenShot] {
        let span = Perf.begin("capture.screens")
        defer { span.end() }
        let screens = NSScreen.screens
        let filters = try await contentFilters(for: screens)
        let showsCursor = Settings.shared.showCursorInScreenshots
        // All screens at once: each capture waits on the window server, not on us.
        let shots = try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            for (index, screen) in screens.enumerated() {
                guard let (filter, display) = filters[ScreenCapturer.displayID(for: screen)] else { continue }
                let config = SCStreamConfiguration()
                config.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
                config.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
                config.showsCursor = showsCursor
                config.captureResolution = .best
                group.addTask {
                    let image = try await Perf.measure("capture.screen") {
                        try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    }
                    return (index, image)
                }
            }
            var images: [Int: CGImage] = [:]
            for try await (index, image) in group { images[index] = image }
            return screens.indices.compactMap { i in images[i].map { ScreenShot(screen: screens[i], image: $0) } }
        }
        if shots.isEmpty { throw CaptureError.displayNotFound }
        return shots
    }

    /// The displays and Clarishot's own app, from ScreenCaptureKit. Fetching them takes ~25 ms and they
    /// rarely change, so they're kept between captures; changing screens clears them. Off-screen
    /// windows are included so Clarishot is listed even with no window showing (menu bar icon hidden).
    private static var kept: (displays: [SCDisplay], own: SCRunningApplication)?
    private static var watchingScreens = false

    private static func keptDisplaysAndApp() async -> (displays: [SCDisplay], own: SCRunningApplication)? {
        if let kept { return kept }
        guard let content = try? await Perf.measure("capture.content", {
            try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        }) else { return nil }
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let own = content.applications.first(where: { $0.processID == pid }) else { return nil }
        if !watchingScreens {
            watchingScreens = true
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { kept = nil }
            }
        }
        kept = (content.displays, own)
        return kept
    }

    private static func freshContent() async throws -> SCShareableContent {
        try await Perf.measure("capture.content") {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }

    /// One filter per display ID, leaving out Clarishot's own windows (and the desktop icons, if set).
    private static func contentFilters(for screens: [NSScreen]) async throws
        -> [CGDirectDisplayID: (SCContentFilter, SCDisplay)] {
        let pid = ProcessInfo.processInfo.processIdentifier
        let covers = DesktopIconHider.shared.windows
        let ids = screens.map(displayID(for:))
        // Fast path: only whole apps are left out (Clarishot), so a kept list of displays will do.
        // Leaving out single windows (the desktop icons, or keeping the wallpaper cover) needs today's windows.
        if covers.isEmpty, !Settings.shared.hideDesktopIconsWhileCapturing, let (displays, own) = await keptDisplaysAndApp(),
           ids.allSatisfy({ id in displays.contains { $0.displayID == id } }) {
            var filters: [CGDirectDisplayID: (SCContentFilter, SCDisplay)] = [:]
            for display in displays where ids.contains(display.displayID) {
                filters[display.displayID] = (SCContentFilter(display: display, excludingApplications: [own],
                                                              exceptingWindows: []), display)
            }
            return filters
        }

        let content = try await freshContent()
        // Keep the wallpaper cover in shots so hidden desktop icons stay hidden.
        let coverIDs = Set(covers.map { CGWindowID($0.windowNumber) })
        var excluded = content.windows.filter { $0.owningApplication?.processID == pid && !coverIDs.contains($0.windowID) }
        if Settings.shared.hideDesktopIconsWhileCapturing {
            let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
            excluded += content.windows.filter {
                $0.owningApplication?.bundleIdentifier == "com.apple.finder" && $0.windowLayer == iconLevel
            }
        }
        var filters: [CGDirectDisplayID: (SCContentFilter, SCDisplay)] = [:]
        for display in content.displays where ids.contains(display.displayID) {
            filters[display.displayID] = (SCContentFilter(display: display, excludingWindows: excluded), display)
        }
        return filters
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
        let language = Settings.shared.ocrLanguage, links = Settings.shared.ocrDetectLinks
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: TextRecognizer.recognize(image, keepLineBreaks: keepLineBreaks,
                                                                        language: language, detectLinks: links))
            }
        }
    }
}
