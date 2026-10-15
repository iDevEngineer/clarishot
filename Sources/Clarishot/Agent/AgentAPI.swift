import AppKit

/// The actions available to the `clarishot` CLI and MCP server.
/// Coordinates are global screen points with a top-left origin (the same as most screenshot
/// tools and the window list), not AppKit's bottom-left.
@MainActor
enum AgentAPI {
    static let version = "1"

    static func handle(_ method: String, _ p: [String: Any]) async throws -> Any {
        switch method {
        case "status": return status()
        case "displays": return displays()
        case "windows": return windows(app: p["app"] as? String)
        case "screenshot": return try await screenshot(p)
        case "ocr": return try await ocr(p)
        case "history": return history(limit: p["limit"] as? Int ?? 10, kind: p["kind"] as? String)
        case "open": return try open(p)
        case "record_start": return try recordStart()
        case "record_stop": return try await recordStop()
        case "annotate": return try annotate(p)
        case "elements": return try elements(p)
        default: throw AgentError("Unknown method “\(method)”. Try: status, displays, windows, screenshot, ocr, history, open, annotate, elements, record_start, record_stop.")
        }
    }

    // MARK: Info

    private static func status() -> [String: Any] {
        ["version": version,
         "app": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
         "screenRecordingAllowed": CGPreflightScreenCaptureAccess(),
         "recording": RecordingCoordinator.shared.isRecording,
         "hidesSensitiveInfo": Settings.shared.agentHideSensitive,
         "accessibilityAllowed": AXIsProcessTrusted(),
         "captureFolder": outputFolder.path]
    }

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// AppKit rect (bottom-left origin) → top-left global.
    private static func topLeft(_ r: CGRect) -> [String: Double] {
        ["x": r.minX, "y": primaryHeight - r.maxY, "width": r.width, "height": r.height]
    }

    private static func displays() -> [[String: Any]] {
        NSScreen.screens.enumerated().map { index, screen in
            ["index": index, "name": screen.localizedName, "scale": screen.backingScaleFactor,
             "main": screen == NSScreen.main, "frame": topLeft(screen.frame)]
        }
    }

    private static func windows(app: String?) -> [[String: Any]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let own = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info -> [String: Any]? in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != own,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict), bounds.width > 40, bounds.height > 40 else { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            if let app, !owner.localizedCaseInsensitiveContains(app), !bundle.localizedCaseInsensitiveContains(app) { return nil }
            let rawTitle = info[kCGWindowName as String] as? String ?? ""
            let title = Settings.shared.agentHideSensitive ? SensitiveDataFinder.mask(rawTitle).0 : rawTitle
            return ["id": Int(id), "app": owner, "bundleId": bundle, "title": title,
                    "frame": ["x": bounds.minX, "y": bounds.minY, "width": bounds.width, "height": bounds.height]]
        }
    }

    // MARK: Screenshots

    /// Where captures made through the API are saved.
    static var outputFolder: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clarishot/Agent Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func screenshot(_ p: [String: Any]) async throws -> [String: Any] {
        let mode = p["mode"] as? String ?? (p["window_id"] != nil || p["app"] != nil ? "window" : (p["x"] != nil ? "area" : "fullscreen"))
        var capture = try await image(mode: mode, p)
        var hidden = 0
        if mustRedact(p) {
            (capture, hidden) = await AgentRedaction.redact(capture)
        }
        if (p["show"] as? Bool) == true {
            CaptureCoordinator.shared.deliver(capture)
        } else {
            HistoryStore.shared.add(capture)
            Toast.show("Screenshot taken by an AI tool")
        }
        // Unique even for several captures in the same second.
        var url = outputFolder.appendingPathComponent("Clarishot \(Capture.timestamp(capture.date)).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = outputFolder.appendingPathComponent("Clarishot \(Capture.timestamp(capture.date)) (\(n)).png")
            n += 1
        }
        guard let png = ImageEncoder.encode(capture.image, as: .png, quality: 1, pointSize: capture.pointSize) else {
            throw AgentError("Could not encode the screenshot")
        }
        try png.write(to: url)
        var result: [String: Any] = ["path": url.path, "width": capture.image.width, "height": capture.image.height,
                                     "scale": capture.scale, "mode": mode, "pointWidth": capture.pointSize.width,
                                     "pointHeight": capture.pointSize.height]
        if hidden > 0 { result["hiddenSensitiveItems"] = hidden }
        return result
    }

    /// Saves a PNG to the agent folder with a unique name.
    private static func save(_ capture: Capture, suffix: String) throws -> URL {
        var url = outputFolder.appendingPathComponent("Clarishot \(Capture.timestamp(capture.date)) \(suffix).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = outputFolder.appendingPathComponent("Clarishot \(Capture.timestamp(capture.date)) \(suffix) (\(n)).png")
            n += 1
        }
        guard let png = ImageEncoder.encode(capture.image, as: .png, quality: 1, pointSize: capture.pointSize) else {
            throw AgentError("Could not encode the image")
        }
        try png.write(to: url)
        return url
    }

    // MARK: Drawing on images

    /// Draws arrows, boxes, labels, blur… onto an image. `shapes` use image points (top-left).
    /// open: true also opens it in the editor with every shape still editable.
    private static func annotate(_ p: [String: Any]) throws -> [String: Any] {
        let image = try decodedImage(p)
        let scale = (p["scale"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 2
        let shapes = try AgentAnnotate.shapes(from: p["shapes"] as? [[String: Any]] ?? [])
        guard !shapes.isEmpty else { throw AgentError("annotate needs a list of shapes") }
        let capture = Capture(image: image, scale: scale)
        let document = AnnotateDocument(capture: capture)
        document.annotations = shapes
        guard let result = document.rendered() else { throw AgentError("Could not draw the shapes") }
        let url = try save(result, suffix: "annotated")
        HistoryStore.shared.add(result)
        if (p["open"] as? Bool) == true { AnnotateWindowController.open(capture, shapes: shapes) }
        return ["path": url.path, "shapes": shapes.count, "width": result.image.width, "height": result.image.height]
    }

    // MARK: App elements

    private static func elements(_ p: [String: Any]) throws -> [[String: Any]] {
        guard let app = p["app"] as? String else { throw AgentError("elements needs app") }
        let hide = Settings.shared.agentHideSensitive
        return try AgentElements.list(app: app, query: p["query"] as? String, limit: p["limit"] as? Int ?? 150).map {
            ["role": $0.role, "label": hide ? SensitiveDataFinder.mask($0.label).0 : $0.label,
             "frame": ["x": $0.frame.minX, "y": $0.frame.minY, "width": $0.frame.width, "height": $0.frame.height]]
        }
    }

    /// Captures for `mode`: fullscreen, area (x, y, width, height), window (window_id or app), interactive.
    private static func image(mode: String, _ p: [String: Any]) async throws -> Capture {
        switch mode {
        case "fullscreen":
            let shots = try await ScreenCapturer.captureAllScreens()
            let index = p["display"] as? Int ?? 0
            let shot = shots.first { $0.screen == NSScreen.screens[safe: index] } ?? shots[0]
            return Capture(image: shot.image, scale: shot.screen.backingScaleFactor).from(SourceApp.frontmost())

        case "area":
            guard let x = number(p["x"]), let y = number(p["y"]), let w = number(p["width"]), let h = number(p["height"]),
                  w > 0, h > 0 else { throw AgentError("area needs x, y, width and height (points, top-left origin)") }
            let global = CGRect(x: x, y: primaryHeight - y - h, width: w, height: h)
            let shots = try await ScreenCapturer.captureAllScreens()
            guard let shot = shots.first(where: { $0.screen.frame.contains(CGPoint(x: global.midX, y: global.midY)) }) else {
                throw AgentError("That area isn't on any screen")
            }
            let local = global.offsetBy(dx: -shot.screen.frame.minX, dy: -shot.screen.frame.minY)
                .intersection(CGRect(origin: .zero, size: shot.screen.frame.size))
            guard let image = ScreenCapturer.crop(shot, to: local) else { throw AgentError("Could not crop that area") }
            return Capture(image: image, scale: shot.screen.backingScaleFactor).from(SourceApp.under(local, on: shot.screen))

        case "window":
            var id = (p["window_id"] as? Int).map { CGWindowID($0) }
            if id == nil, let app = p["app"] as? String {
                id = (windows(app: app).first?["id"] as? Int).map { CGWindowID($0) }
                if id == nil { throw AgentError("No visible window for “\(app)”") }
            }
            guard let id else { throw AgentError("window needs window_id or app") }
            let (image, scale) = try await ScreenCapturer.captureWindow(id: id)
            return Capture(image: image, scale: scale)

        case "interactive":
            NSApp.activate(ignoringOtherApps: true)
            return try await withCheckedThrowingContinuation { continuation in
                CaptureCoordinator.shared.selectRegion(hint: "Select an area for the AI tool.") { shot, rect in
                    guard let image = ScreenCapturer.crop(shot, to: rect) else {
                        return continuation.resume(throwing: AgentError("Could not crop that area"))
                    }
                    continuation.resume(returning: Capture(image: image, scale: shot.screen.backingScaleFactor)
                        .from(SourceApp.under(rect, on: shot.screen)))
                } onCancel: {
                    continuation.resume(throwing: AgentError("The selection was cancelled"))
                }
            }

        case "element":
            guard let app = p["app"] as? String, let query = p["query"] as? String else {
                throw AgentError("element needs app and query (a button title, label or role, e.g. \"Save\" or \"sidebar\")")
            }
            let element = try AgentElements.best(app: app, query: query)
            let pad = number(p["padding"]) ?? 8
            var area = p
            let r = element.frame.insetBy(dx: -pad, dy: -pad)
            area["x"] = r.minX; area["y"] = r.minY; area["width"] = r.width; area["height"] = r.height
            return try await image(mode: "area", area)

        case "smart":
            NSApp.activate(ignoringOtherApps: true)
            let (screen, rect, bundle) = try await withCheckedThrowingContinuation { continuation in
                SmartCaptureController.shared.start { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value)
                    case .failure: continuation.resume(throwing: AgentError("Smart Capture was cancelled or needs Accessibility permission"))
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
            let shots = try await ScreenCapturer.captureAllScreens()
            guard let shot = shots.first(where: { $0.screen == screen }), let image = ScreenCapturer.crop(shot, to: rect) else {
                throw AgentError("Could not capture that element")
            }
            return Capture(image: image, scale: screen.backingScaleFactor).from(bundle)

        case "cutout":
            var area = p
            area["mode"] = p["x"] != nil ? "area" : "interactive"
            let source = try await self.image(mode: area["mode"] as! String, area) // swiftlint:disable:this force_cast
            guard let cut = await BackgroundRemover.removeBackgroundAsync(source.image) else {
                throw AgentError("No clear subject found to cut out")
            }
            return Capture(image: cut, scale: source.scale).from(source.sourceBundleID)

        default:
            throw AgentError("mode must be fullscreen, area, window, element, interactive, smart or cutout")
        }
    }

    /// Only the user can switch hiding off (in Preferences); a request can ask for more, never less.
    private static func mustRedact(_ p: [String: Any]) -> Bool {
        Settings.shared.agentHideSensitive || (p["redact"] as? Bool) == true
    }

    private static func number(_ value: Any?) -> CGFloat? {
        (value as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    // MARK: Text

    private static func ocr(_ p: [String: Any]) async throws -> [String: Any] {
        let image: CGImage
        if p["image_base64"] != nil {
            image = try decodedImage(p)
        } else {
            let mode = p["mode"] as? String ?? (p["x"] != nil ? "area" : "interactive")
            var capture = try await self.image(mode: mode, p)
            // Read from the covered image, so private text never reaches the AI tool.
            if mustRedact(p) {
                capture = await AgentRedaction.redact(capture).0
            }
            image = capture.image
        }
        return ["text": await ScreenCapturer.recognizeText(in: image)]
    }

    // MARK: History and opening

    private static func history(limit: Int, kind: String?) -> [[String: Any]] {
        let store = HistoryStore.shared
        let formatter = ISO8601DateFormatter()
        return store.items
            .filter { kind == nil || $0.kind.rawValue == kind }
            .prefix(max(1, min(limit, 100)))
            .map { item in
                ["path": store.url(for: item).path, "kind": item.kind.rawValue, "date": formatter.string(from: item.date),
                 "width": item.pixelWidth, "height": item.pixelHeight, "app": item.sourceBundleID ?? ""]
            }
    }

    /// Files are read by the calling tool and sent as bytes, never opened here by path:
    /// Clarishot may hold folder permissions the caller doesn't, and must not read files for it.
    private static func decodedImage(_ p: [String: Any]) throws -> CGImage {
        guard let base64 = p["image_base64"] as? String, let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw AgentError("That isn't an image Clarishot can read") }
        return image
    }

    private static func open(_ p: [String: Any]) throws -> [String: Any] {
        let image = try decodedImage(p)
        let path = p["name"] as? String ?? "image"
        let capture = Capture(image: image, scale: NSScreen.main?.backingScaleFactor ?? 2)
        switch p["action"] as? String ?? "annotate" {
        case "pin": PinWindow.pin(capture)
        case "preview": PreviewManager.shared.show(capture)
        default: AnnotateWindowController.open(capture)
        }
        return ["opened": path]
    }

    // MARK: Recording

    private static func recordStart() throws -> [String: Any] {
        guard !RecordingCoordinator.shared.isRecording else { throw AgentError("Already recording") }
        RecordingCoordinator.shared.toggle()
        return ["started": "Choose an area and press Record in Clarishot. Call record_stop to finish."]
    }

    private static func recordStop() async throws -> [String: Any] {
        guard RecordingCoordinator.shared.isRecording else { throw AgentError("Not recording") }
        let url: URL = try await withCheckedThrowingContinuation { continuation in
            RecordingCoordinator.shared.onNextSave = { url in
                if let url { continuation.resume(returning: url) } else {
                    continuation.resume(throwing: AgentError("The recording could not be saved"))
                }
            }
            RecordingCoordinator.shared.stop()
        }
        return ["path": url.path]
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
