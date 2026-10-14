import AppKit

MainActor.assumeIsolated {
    // Build step: `Snapzy --write-iconset <dir>` writes the icon PNGs for iconutil, then exits.
    if let i = CommandLine.arguments.firstIndex(of: "--write-iconset"), i + 1 < CommandLine.arguments.count {
        AppIcon.writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
