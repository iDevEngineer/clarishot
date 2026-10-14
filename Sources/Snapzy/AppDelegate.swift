import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?

    /// Opening Snapzy again (e.g. from Finder) shows Settings, the way back when the menu-bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsWindowController.show() }
        return true
    }

    /// snapzy://<action>, e.g. snapzy://capture-area. Only when allowed in Settings → Advanced.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard Settings.shared.allowURLScheme else {
            Toast.show("Turn on “Allow URL scheme API” in Settings → Advanced")
            return
        }
        for url in urls where url.scheme == "snapzy" {
            let name = (url.host ?? "").replacingOccurrences(of: "-", with: "").lowercased()
            if name == "opensettings" { SettingsWindowController.show(); continue }
            ShortcutAction.allCases.first { $0.rawValue.lowercased() == name }?.perform()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIcon.current
        statusMenu = StatusMenuController()
        Shortcuts.registerAll()
        Wallpaper.startWatching()
        AgentServer.shared.sync()
        // Re-register hotkeys whenever shortcuts change in Settings.
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                AgentServer.shared.sync()
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
