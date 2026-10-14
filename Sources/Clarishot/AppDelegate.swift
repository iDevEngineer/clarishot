import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?

    /// Opening Clarishot again (e.g. from Finder) shows Settings, the way back when the menu-bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsWindowController.show() }
        return true
    }

    /// clarishot://<action>, e.g. clarishot://capture-area. Only when allowed in Preferences → Advanced.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Project files double-clicked in Finder.
        let projects = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "clarishot" }
        projects.forEach(AnnotateWindowController.openProject)
        guard projects.count < urls.count else { return }
        guard Settings.shared.allowURLScheme else {
            Toast.show("Turn on “Allow URL scheme API” in Preferences → Advanced")
            return
        }
        for url in urls where url.scheme == "clarishot" {
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
        AppAppearance.apply()
        // Re-register hotkeys whenever shortcuts change in Settings.
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                AgentServer.shared.sync()
                AppAppearance.apply()
                guard !HotkeyCenter.shared.isSuspended else { return }
                Shortcuts.registerAll()
            }
        }
        // `open Clarishot.app --args --settings` opens Settings straight away.
        if let i = CommandLine.arguments.firstIndex(of: "--settings") {
            let name = CommandLine.arguments.dropFirst(i + 1).first ?? ""
            SettingsWindowController.show(tab: SettingsTab.allCases.first { $0.title.lowercased().hasPrefix(name.lowercased()) && !name.isEmpty } ?? .general)
            // `--width N`: open Preferences at that width (handy for checking layouts).
            if let w = CommandLine.arguments.firstIndex(of: "--width").flatMap({ CommandLine.arguments.dropFirst($0 + 1).first }).flatMap(Double.init),
               let window = NSApp.windows.first(where: { $0.title == "Preferences" }) {
                window.setContentSize(CGSize(width: w, height: window.contentLayoutRect.height))
            }
        }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }
}
