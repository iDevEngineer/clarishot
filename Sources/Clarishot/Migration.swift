import Foundation

/// One-time carry-over from the app's earlier name, so settings, shortcuts and capture
/// history survive the rename. Runs before anything reads settings.
enum Migration {
    /// File-name templates saved under the old name start with it; switch them to Clarishot.
    private static func renameTemplates(_ defaults: UserDefaults) {
        for key in ["screenshotName", "recordingName"] {
            guard let value = defaults.string(forKey: key), value.contains("Snapzy") else { continue }
            defaults.set(value.replacingOccurrences(of: "Snapzy", with: "Clarishot"), forKey: key)
        }
    }

    private static let oldBundleID = "com.scottmackey.snapzy"
    private static let oldFolderName = "Snapzy"
    private static let doneKey = "migratedFromOldName"

    static func run() {
        let defaults = UserDefaults.standard
        renameTemplates(defaults)
        guard !defaults.bool(forKey: doneKey) else { return }

        // Settings and shortcuts.
        if let old = defaults.persistentDomain(forName: oldBundleID), !old.isEmpty,
           let current = Bundle.main.bundleIdentifier {
            var merged = defaults.persistentDomain(forName: current) ?? [:]
            for (key, value) in old where merged[key] == nil { merged[key] = value }
            defaults.setPersistentDomain(merged, forName: current)
        }

        // Capture history and AI captures (Application Support/Snapzy → Clarishot).
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldFolder = support.appendingPathComponent(oldFolderName, isDirectory: true)
        let newFolder = support.appendingPathComponent("Clarishot", isDirectory: true)
        if FileManager.default.fileExists(atPath: oldFolder.path), !FileManager.default.fileExists(atPath: newFolder.path) {
            try? FileManager.default.moveItem(at: oldFolder, to: newFolder)
            try? FileManager.default.removeItem(at: newFolder.appendingPathComponent("agent.sock"))
        }
        defaults.set(true, forKey: doneKey)
    }
}
