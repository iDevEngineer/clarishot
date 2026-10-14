import AppKit
import ApplicationServices

/// Smart Capture: point at any part of an app (a button, sidebar, dialog, menu) and it is
/// outlined; click to capture exactly that element. ↑ / scroll up selects the element around it,
/// ↓ / scroll down goes back in. Esc or a click outside cancels.
///
/// Works live (no frozen screen) using the Accessibility API to find each element's frame.
@MainActor
final class SmartCaptureController {
    static let shared = SmartCaptureController()

    private var panels: [SmartOverlayPanel] = []
    private var completion: ((Result<(NSScreen, CGRect, String?), Error>) -> Void)?
    private var monitors: [Any] = []
    private var lastQuery = Date.distantPast
    /// The element under the cursor and the chain of elements around it (innermost first).
    private var chain: [(rect: CGRect, role: String, element: AXUIElement)] = []
    private var level = 0
    private var bundleID: String?

    var isActive: Bool { !panels.isEmpty }

    /// Starts a session. `done` gets the screen, rect (screen-local AppKit points) and source app,
    /// or an error if cancelled.
    func start(done: @escaping (Result<(NSScreen, CGRect, String?), Error>) -> Void) {
        guard !isActive else { return }
        guard Self.ensurePermission() else {
            Toast.show("Allow Clarishot in Accessibility settings to use Smart Capture")
            done(.failure(SmartCaptureError.noPermission))
            return
        }
        completion = done
        panels = NSScreen.screens.map { SmartOverlayPanel(screen: $0, controller: self) }
        panels.forEach { $0.orderFrontRegardless() }
        NSApp.activate(ignoringOtherApps: true)
        panels.first { $0.screen == NSScreen.main }?.makeKey()
        NSCursor.pointingHand.push()

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.mouseMoved()
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53: self.finish(nil); return nil                 // Esc
            case 126: self.changeLevel(+1); return nil            // ↑ outer element
            case 125: self.changeLevel(-1); return nil            // ↓ inner element
            case 36, 76: self.commit(); return nil                // Return
            default: return event
            }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            if abs(event.scrollingDeltaY) > 2 { self?.changeLevel(event.scrollingDeltaY > 0 ? +1 : -1) }
            return nil
        } as Any)
        mouseMoved()
    }

    static func ensurePermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Finding the element

    private func mouseMoved() {
        // Throttle: AX queries are cheap but not free.
        guard Date().timeIntervalSince(lastQuery) > 0.03 else { return }
        lastQuery = Date()
        let point = NSEvent.mouseLocation
        guard let (pid, bundle) = Self.appUnder(point) else { setChain([]); return }
        bundleID = bundle
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let app = AXUIElementCreateApplication(pid)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(primary - point.y), &element) == .success,
              let element else { setChain([]); return }

        // Build innermost → outermost, skipping slivers and duplicates of the same frame.
        var result: [(CGRect, String, AXUIElement)] = []
        var current: AXUIElement? = element
        while let node = current, result.count < 24 {
            if let rect = Self.frame(of: node, primaryHeight: primary), rect.width >= 6, rect.height >= 6,
               result.last.map({ $0.0 != rect }) ?? true {
                result.append((rect, Self.role(of: node), node))
            }
            current = Self.parent(of: node)
        }
        // Keep the user's chosen level when still over the same element.
        let sameElement = chain.first.map { CFEqual($0.element, element) } ?? false
        setChain(result.map { (rect: $0.0, role: $0.1, element: $0.2) }, keepLevel: sameElement)
    }

    private func setChain(_ new: [(rect: CGRect, role: String, element: AXUIElement)], keepLevel: Bool = false) {
        chain = new
        if !keepLevel { level = 0 }
        level = min(level, max(chain.count - 1, 0))
        redraw()
    }

    private func changeLevel(_ delta: Int) {
        guard !chain.isEmpty else { return }
        level = min(max(level + delta, 0), chain.count - 1)
        redraw()
    }

    private var current: (rect: CGRect, role: String)? {
        chain.indices.contains(level) ? (chain[level].rect, chain[level].role) : nil
    }

    private func redraw() {
        for panel in panels {
            panel.show(rect: current?.rect, label: current.map { "\($0.role) · \(Int($0.rect.width)) × \(Int($0.rect.height))" })
        }
    }

    // MARK: Finishing

    /// A click: capture if it's inside the outline, otherwise cancel.
    func clicked(at point: CGPoint) {
        guard let rect = current?.rect, rect.contains(point) else { return finish(nil) }
        commit()
    }

    private func commit() {
        guard let rect = current?.rect,
              let screen = NSScreen.screens.max(by: { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area })
        else { return finish(nil) }
        let local = rect.intersection(screen.frame).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        finish((screen, local, bundleID))
    }

    private func finish(_ result: (NSScreen, CGRect, String?)?) {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        NSCursor.pop()
        chain = []
        let done = completion
        completion = nil
        if let result { done?(.success(result)) } else { done?(.failure(SmartCaptureError.cancelled)) }
    }

    // MARK: Accessibility helpers

    /// The front-most normal window under `point` that isn't Clarishot's, and its app.
    private static func appUnder(_ point: CGPoint) -> (pid_t, String?)? {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let quartz = CGPoint(x: point.x, y: primary - point.y)
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict), bounds.contains(quartz),
                  (info[kCGWindowLayer as String] as? Int ?? 0) < Int(CGWindowLevelForKey(.screenSaverWindow)) else { continue }
            return (pid, NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
        }
        return nil
    }

    private static func frame(of element: AXUIElement, primaryHeight: CGFloat) -> CGRect? {
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        // swiftlint:disable force_cast
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        // swiftlint:enable force_cast
        return CGRect(x: position.x, y: primaryHeight - position.y - size.height, width: size.width, height: size.height)
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement) // swiftlint:disable:this force_cast
    }

    private static func role(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &value) == .success,
           let text = value as? String, !text.isEmpty {
            return text.prefix(1).uppercased() + text.dropFirst()
        }
        return "Element"
    }
}

enum SmartCaptureError: Error { case cancelled, noPermission }

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// Clear full-screen panel drawing the outline of the element under the cursor.
final class SmartOverlayPanel: NSPanel {
    private let outline = SmartOutlineView()
    private weak var controller: SmartCaptureController?

    init(screen: NSScreen, controller: SmartCaptureController) {
        self.controller = controller
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        outline.frame = CGRect(origin: .zero, size: screen.frame.size)
        outline.onClick = { [weak self] point in
            guard let self else { return }
            MainActor.assumeIsolated { self.controller?.clicked(at: CGPoint(x: point.x + self.frame.minX, y: point.y + self.frame.minY)) }
        }
        contentView = outline
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }

    /// `rect` in global AppKit coordinates.
    func show(rect: CGRect?, label: String?) {
        outline.rect = rect.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) }
        outline.label = label
        outline.needsDisplay = true
    }
}

final class SmartOutlineView: NSView {
    var rect: CGRect?
    var label: String?
    var onClick: ((CGPoint) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        // An almost-clear fill so every click lands on this panel, not the app underneath.
        NSColor.black.withAlphaComponent(0.001).setFill()
        bounds.fill()
        guard let rect, rect.intersects(bounds) else { return }
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.stroke()

        guard let label else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                         .foregroundColor: NSColor.white]
        let text = NSAttributedString(string: label, attributes: attributes)
        let size = text.size()
        var box = CGRect(x: rect.minX, y: rect.maxY + 6, width: size.width + 14, height: size.height + 6)
        if box.maxY > bounds.maxY - 4 { box.origin.y = rect.minY - box.height - 6 }
        if box.minY < 4 { box.origin.y = rect.maxY - box.height - 6 }
        box.origin.x = min(max(box.minX, 4), bounds.maxX - box.width - 4)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        text.draw(at: CGPoint(x: box.minX + 7, y: box.minY + 3))
    }
}
