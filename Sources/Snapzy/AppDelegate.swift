import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenu = StatusMenuController()
        Shortcuts.registerAll()
        Wallpaper.startWatching()
        // Re-register hotkeys whenever shortcuts change in Settings.
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard !HotkeyCenter.shared.isSuspended else { return }
                Shortcuts.registerAll()
            }
        }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }
}
