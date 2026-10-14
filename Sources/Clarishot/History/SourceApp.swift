import AppKit

/// Works out which app a capture came from, and its icon, for Capture History.
@MainActor
enum SourceApp {
    private static var icons: [String: NSImage] = [:]

    /// The app owning the front-most normal window under the middle of `rect`
    /// (global AppKit coordinates).
    static func under(_ rect: CGRect) -> String? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // Window-server coordinates have a top-left origin.
        let point = CGPoint(x: rect.midX, y: primaryHeight - rect.midY)
        for info in windowList() {
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.contains(point),
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
        return frontmost()
    }

    /// `rect` in screen-local points on `screen`.
    static func under(_ rect: CGRect, on screen: NSScreen) -> String? {
        under(rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY))
    }

    static func owner(of window: CGWindowID) -> String? {
        let match = windowList().first { ($0[kCGWindowNumber as String] as? CGWindowID) == window }
        guard let pid = match?[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    static func frontmost() -> String? {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.processIdentifier == getpid() ? nil : app?.bundleIdentifier
    }

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }

    /// Normal app windows on screen, front-most first, excluding Clarishot's own.
    private static func windowList() -> [[String: Any]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = getpid()
        return list.filter {
            ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? pid_t) != ownPID
        }
    }
}
