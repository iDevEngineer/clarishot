import AppKit
import ApplicationServices

// More for AI tools: covering private text, drawing on screenshots, and finding app elements
// by name. Used by AgentAPI; coordinates are points with a top-left origin.

// MARK: - Hide sensitive info

@MainActor
enum AgentRedaction {
    /// Covers text that looks private (emails, keys, card numbers…) with solid black boxes.
    /// Returns the covered image and how many were covered.
    static func redact(_ capture: Capture) async -> (Capture, Int) {
        let matches = await SensitiveDataFinder.findAsync(in: capture.image, pointSize: capture.pointSize)
        guard !matches.isEmpty,
              let ctx = AnnotationRenderer.makeContext(width: capture.image.width, height: capture.image.height, like: capture.image)
        else { return (capture, 0) }
        let s = capture.scale, h = CGFloat(capture.image.height)
        ctx.draw(capture.image, in: CGRect(x: 0, y: 0, width: capture.image.width, height: capture.image.height))
        ctx.setFillColor(NSColor.black.cgColor)
        for match in matches {
            // Points, top-left origin → pixels, bottom-left origin; a little margin all round.
            let r = match.rect.insetBy(dx: -2, dy: -2)
            ctx.fill(CGRect(x: r.minX * s, y: h - r.maxY * s, width: r.width * s, height: r.height * s))
        }
        guard let image = ctx.makeImage() else { return (capture, 0) }
        return (Capture(image: image, scale: capture.scale).from(capture.sourceBundleID), matches.count)
    }
}

// MARK: - Drawing on screenshots

@MainActor
enum AgentAnnotate {
    /// Builds editor shapes from simple JSON: arrow, line, rectangle, filled_rectangle, ellipse,
    /// text, counter, highlight, blur, pixelate, spotlight. Positions are image points, top-left.
    static func shapes(from list: [[String: Any]]) throws -> [Annotation] {
        var counter = 0
        return try list.enumerated().map { index, item in
            let type = (item["type"] as? String ?? "").lowercased()
            let color = Self.color(item["color"] as? String) ?? (type == "highlight" ? NSColor.systemYellow : NSColor(oklch: 0.63, 0.24, 27))
            let width = CGFloat((item["width_px"] as? NSNumber)?.doubleValue ?? (item["thickness"] as? NSNumber)?.doubleValue ?? 4)
            func num(_ key: String) -> CGFloat? { (item[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
            func box() throws -> (CGPoint, CGPoint) {
                guard let x = num("x"), let y = num("y"), let w = num("width"), let h = num("height") else {
                    throw AgentError("Shape \(index + 1) (\(type)) needs x, y, width and height")
                }
                return (CGPoint(x: x, y: y), CGPoint(x: x + w, y: y + h))
            }
            func ends() throws -> (CGPoint, CGPoint) {
                guard let x1 = num("from_x"), let y1 = num("from_y"), let x2 = num("to_x"), let y2 = num("to_y") else {
                    throw AgentError("Shape \(index + 1) (\(type)) needs from_x, from_y, to_x and to_y")
                }
                return (CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2))
            }
            switch type {
            case "arrow", "line":
                let (a, b) = try ends()
                return Annotation(tool: type == "arrow" ? .arrow : .line, start: a, end: b, color: color, lineWidth: width)
            case "rectangle", "box", "filled_rectangle", "ellipse", "circle", "blur", "pixelate", "spotlight":
                let (a, b) = try box()
                let tool: Tool = ["rectangle": .rectangle, "box": .rectangle, "filled_rectangle": .filledRectangle,
                                  "ellipse": .ellipse, "circle": .ellipse, "blur": .blur, "pixelate": .pixelate,
                                  "spotlight": .spotlight][type]!
                return Annotation(tool: tool, start: a, end: b, color: color, lineWidth: width)
            case "highlight":
                let (a, b) = try box()
                let mid = (a.y + b.y) / 2
                var shape = Annotation(tool: .highlighter, start: CGPoint(x: a.x, y: mid), end: CGPoint(x: b.x, y: mid),
                                       color: color, lineWidth: max(1, (b.y - a.y - 8) / 4))
                shape.points = [CGPoint(x: a.x, y: mid), CGPoint(x: b.x, y: mid)]
                return shape
            case "text":
                guard let x = num("x"), let y = num("y"), let text = item["text"] as? String, !text.isEmpty else {
                    throw AgentError("Shape \(index + 1) (text) needs x, y and text")
                }
                let size = num("font_size") ?? 24
                var shape = Annotation(tool: .text, start: CGPoint(x: x, y: y), end: CGPoint(x: x, y: y),
                                       color: color, lineWidth: max(1, (size - 12) / 3))
                shape.text = text
                return shape
            case "counter", "number":
                guard let x = num("x"), let y = num("y") else { throw AgentError("Shape \(index + 1) (counter) needs x and y") }
                counter += 1
                var shape = Annotation(tool: .counter, start: CGPoint(x: x, y: y), end: CGPoint(x: x, y: y),
                                       color: color, lineWidth: width)
                shape.number = (item["number"] as? Int) ?? counter
                return shape
            default:
                throw AgentError("Shape \(index + 1): unknown type “\(type)”. Use arrow, line, rectangle, filled_rectangle, ellipse, text, counter, highlight, blur, pixelate or spotlight.")
            }
        }
    }

    /// Named colours or #RRGGBB.
    static func color(_ name: String?) -> NSColor? {
        guard let name = name?.lowercased().trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        let named: [String: NSColor] = ["red": NSColor(oklch: 0.63, 0.24, 27), "orange": .systemOrange, "yellow": .systemYellow,
                                        "green": .systemGreen, "blue": .systemBlue, "purple": .systemPurple,
                                        "pink": .systemPink, "black": .black, "white": .white, "gray": .systemGray, "grey": .systemGray]
        return named[name] ?? NSColor(hex: name)
    }
}

// MARK: - Finding app elements

@MainActor
enum AgentElements {
    struct Element {
        let role: String
        let label: String
        let frame: CGRect // points, top-left origin (Accessibility's own coordinates)
    }

    /// Labelled interface elements in an app's front window, biggest first within each depth.
    static func list(app: String, query: String? = nil, limit: Int = 200) throws -> [Element] {
        guard AXIsProcessTrusted() else {
            throw AgentError("Finding elements needs Accessibility permission for Clarishot (System Settings → Privacy & Security → Accessibility)")
        }
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").localizedCaseInsensitiveContains(app) || ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains(app)
        }) else { throw AgentError("“\(app)” isn't running") }
        let root = AXUIElementCreateApplication(running.processIdentifier)
        var windowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &windowRef)
        if windowRef == nil {
            var windows: CFTypeRef?
            AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows)
            windowRef = (windows as? [AXUIElement])?.first
        }
        guard let window = windowRef else { throw AgentError("“\(app)” has no open window") }
        // Breadth-first, capped so a huge web page can't stall Clarishot.
        var queue: [AXUIElement] = [window as! AXUIElement] // swiftlint:disable:this force_cast
        var found: [Element] = []
        var visited = 0
        let needle = query?.lowercased()
        while !queue.isEmpty, visited < 4000, found.count < limit {
            let element = queue.removeFirst()
            visited += 1
            if let item = describe(element), needle == nil || item.label.lowercased().contains(needle!) || item.role.lowercased().contains(needle!) {
                found.append(item)
            }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            queue.append(contentsOf: (children as? [AXUIElement]) ?? [])
        }
        return found
    }

    private static func describe(_ element: AXUIElement) -> Element? {
        func string(_ attribute: String) -> String? {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            return (value as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        var origin = CGPoint.zero, size = CGSize.zero
        guard let posRef, let sizeRef,
              AXValueGetValue(posRef as! AXValue, .cgPoint, &origin), // swiftlint:disable:this force_cast
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size), // swiftlint:disable:this force_cast
              size.width >= 8, size.height >= 8 else { return nil }
        let role = (string(kAXRoleDescriptionAttribute) ?? string(kAXRoleAttribute) ?? "element")
        var label = string(kAXTitleAttribute) ?? string(kAXDescriptionAttribute) ?? string(kAXHelpAttribute)
            ?? string(kAXIdentifierAttribute) ?? ""
        // Masked here, before any search, so a query can't be used to guess a hidden value.
        if Settings.shared.agentHideSensitive { label = SensitiveDataFinder.mask(label).0 }
        guard !label.isEmpty || ["toolbar", "sidebar", "scroll area", "table", "outline", "web area", "list"].contains(role.lowercased()) else {
            return nil
        }
        return Element(role: role, label: label, frame: CGRect(origin: origin, size: size))
    }

    /// The best match for `query`: an exact label first, then the smallest element containing it.
    static func best(app: String, query: String) throws -> Element {
        let matches = try list(app: app, query: query)
        let q = query.lowercased()
        if let exact = matches.first(where: { $0.label.lowercased() == q }) { return exact }
        guard let first = matches.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw AgentError("Nothing in “\(app)” matches “\(query)”. Call list_elements to see what's there.")
        }
        return first
    }
}

// MARK: - Context for "Copy for AI"

@MainActor
enum CaptureContext {
    /// The front window's title and, for browsers, the page address, for an app.
    static func windowInfo(bundleID: String?) -> (title: String?, url: String?) {
        guard AXIsProcessTrusted(), let bundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return (nil, nil) }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard let windowRef else { return (nil, nil) }
        let window = windowRef as! AXUIElement // swiftlint:disable:this force_cast
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        // Browsers expose the page address on the web area (AXURL).
        var url: String?
        var queue = [window], visited = 0
        while !queue.isEmpty, visited < 600, url == nil {
            let element = queue.removeFirst()
            visited += 1
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &value) == .success {
                url = (value as? URL)?.absoluteString ?? (value as? String)
            }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            queue.append(contentsOf: (children as? [AXUIElement]) ?? [])
        }
        return (titleRef as? String, url.flatMap { $0.hasPrefix("http") ? $0 : nil })
    }
}
