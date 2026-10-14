import AppKit

/// Capture Menu: finds the open menu, submenu or menu-bar popover on screen and captures just
/// that, without showing an overlay (which would close it).
extension CaptureCoordinator {
    /// From a shortcut it captures straight away. From Clarishot's own menu it waits a few
    /// seconds first, because opening Clarishot's menu closes any other menu.
    func captureMenu(delay: Int = 0) {
        guard delay > 0 else { return captureOpenMenu() }
        Toast.show("Open the menu or popover to capture… \(delay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in self?.captureOpenMenu() }
    }

    private func captureOpenMenu() {
        guard let (frame, pid) = MenuFinder.openMenu() else {
            Toast.show("No open menu or popover found")
            return
        }
        Task {
            do {
                let shots = try await ScreenCapturer.captureAllScreens()
                // Use the screen holding most of the menu.
                guard let shot = shots.max(by: {
                    $0.screen.frame.intersection(frame).area < $1.screen.frame.intersection(frame).area
                }) else { return }
                let local = frame.intersection(shot.screen.frame)
                    .offsetBy(dx: -shot.screen.frame.minX, dy: -shot.screen.frame.minY)
                guard !local.isEmpty, let image = ScreenCapturer.crop(shot, to: local) else { return }
                let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                deliver(Capture(image: image, scale: shot.screen.backingScaleFactor).from(bundle))
            } catch {
                showCaptureError(error)
            }
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

@MainActor
enum MenuFinder {
    /// The frontmost open menu or popover (joined with any submenus touching it), in AppKit
    /// global coordinates, and the app that owns it.
    static func openMenu() -> (CGRect, pid_t)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let menuBarHeight = NSApp.mainMenu?.menuBarHeight ?? 24
        var candidates: [(rect: CGRect, pid: pid_t)] = []
        for info in list { // front to back
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: dict)
            else { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            // Menus, popovers and menu-bar extras sit above normal windows (layer 0) and below
            // the cursor and screen shields. Skip the menu bar strip itself and status icons.
            guard layer > 0, layer < 1000, owner != "Window Server", owner != "Dock",
                  cg.width > 40, cg.height > 30,
                  !(cg.minY < 1 && cg.height <= menuBarHeight + 6)
            else { continue }
            let rect = CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
            candidates.append((rect, pid))
        }
        guard let first = candidates.first else { return nil }
        // Join submenus and attached panels that touch the frontmost one.
        var frame = first.rect
        var rest = Array(candidates.dropFirst())
        var grew = true
        while grew {
            grew = false
            for (i, c) in rest.enumerated() where c.rect.intersects(frame.insetBy(dx: -6, dy: -6)) {
                frame = frame.union(c.rect)
                rest.remove(at: i)
                grew = true
                break
            }
        }
        return (frame, first.pid)
    }
}
