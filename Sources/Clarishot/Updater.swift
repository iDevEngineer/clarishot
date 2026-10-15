import AppKit
import Sparkle

/// Auto-updates through Sparkle: checks the release feed (SUFeedURL in Info.plist) once a day,
/// and every download is verified against the public key (SUPublicEDKey) before it installs.
@MainActor
enum Updater {
    private static let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                                  userDriverDelegate: nil)

    /// Starts the daily background checks. Call once at launch.
    static func start() { _ = controller }

    static func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    static var automaticChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    static var automaticDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }
}
