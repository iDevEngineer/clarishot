import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIcon.current
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
        // `open Snapzy.app --args --settings` opens Settings straight away.
        if let i = CommandLine.arguments.firstIndex(of: "--settings") {
            let name = CommandLine.arguments.dropFirst(i + 1).first ?? ""
            SettingsWindowController.show(tab: SettingsTab.allCases.first { $0.title.lowercased().hasPrefix(name.lowercased()) && !name.isEmpty } ?? .general)
        }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }
}
