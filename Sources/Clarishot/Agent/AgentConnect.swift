import AppKit

/// One-click connection of Clarishot's MCP server to the AI apps on this Mac.
/// Command-line tools are connected with their own `mcp add` command; desktop apps by adding
/// Clarishot to their MCP config file (a backup of the old file is kept beside it).
@MainActor
enum AgentConnect {
    enum Target: CaseIterable {
        case claudeCode, codex, claudeDesktop, cursor

        /// What it covers, shown under the name.
        var detail: String {
            switch self {
            case .claudeCode: return "Terminal and the Code tab in the Claude app."
            case .codex: return "Codex app and codex command line."
            case .claudeDesktop: return "Regular conversations in the Claude app."
            case .cursor: return "Cursor's AI chat and agent."
            }
        }

        var name: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .codex: return "ChatGPT Codex"
            case .claudeDesktop: return "Claude app (Chat)"
            case .cursor: return "Cursor"
            }
        }
    }

    enum State { case notInstalled, notConnected, connected }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Where command-line tools usually live; GUI apps don't get the shell's PATH.
    private static let searchPaths = ["~/.local/bin", "~/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", "~/.npm-global/bin", "~/.bun/bin"]

    private static func tool(_ name: String) -> URL? {
        for dir in searchPaths {
            let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    private static func appInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// JSON config file for the desktop apps.
    static func configFile(_ target: Target) -> URL? {
        switch target {
        case .claudeDesktop: return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case .cursor: return home.appendingPathComponent(".cursor/mcp.json")
        default: return nil
        }
    }

    static func state(_ target: Target) -> State {
        switch target {
        case .claudeCode:
            guard tool("claude") != nil else { return .notInstalled }
            return jsonHasClarishot(home.appendingPathComponent(".claude.json")) ? .connected : .notConnected
        case .codex:
            guard tool("codex") != nil else { return .notInstalled }
            let config = (try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)) ?? ""
            return config.contains("[mcp_servers.clarishot]") ? .connected : .notConnected
        case .claudeDesktop:
            guard appInstalled("com.anthropic.claudefordesktop") else { return .notInstalled }
            return jsonHasClarishot(configFile(target)!) ? .connected : .notConnected
        case .cursor:
            guard appInstalled("com.todesktop.230313mzl4w4u92") || FileManager.default.fileExists(atPath: "/Applications/Cursor.app")
            else { return .notInstalled }
            return jsonHasClarishot(configFile(target)!) ? .connected : .notConnected
        }
    }

    private static func jsonHasClarishot(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return false }
        return servers["clarishot"] != nil
    }

    /// Connects, then reports what happened in a toast. Returns true on success.
    @discardableResult
    static func connect(_ target: Target) -> Bool {
        do {
            switch target {
            case .claudeCode:
                try run(tool("claude"), ["mcp", "add", "--scope", "user", "clarishot", "--", AgentSetup.cliPath, "mcp"])
            case .codex:
                try run(tool("codex"), ["mcp", "add", "clarishot", "--", AgentSetup.cliPath, "mcp"])
            case .claudeDesktop, .cursor:
                try addToJSON(configFile(target)!)
            }
            if !Settings.shared.allowAgentAccess { Settings.shared.allowAgentAccess = true }
            let restart = target == .claudeDesktop ? "Restart the Claude app to use it." : target == .cursor ? "Restart Cursor to use it." : "Start a new session to use it."
            Toast.show("Connected to \(target.name). \(restart)")
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't connect to \(target.name)"
            alert.informativeText = (error as? AgentError)?.message ?? error.localizedDescription
            alert.runModal()
            return false
        }
    }

    private static func run(_ executable: URL?, _ arguments: [String]) throws {
        guard let executable else { throw AgentError("The command-line tool wasn't found") }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchPaths.map { ($0 as NSString).expandingTildeInPath } + ["/usr/bin", "/bin"]).joined(separator: ":")
        process.environment = env
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // Already added counts as connected.
            if message.localizedCaseInsensitiveContains("already exists") { return }
            throw AgentError(message.isEmpty ? "\(executable.lastPathComponent) exited with code \(process.terminationStatus)" : message)
        }
    }

    /// Adds `mcpServers.clarishot` to a JSON config, keeping everything else as it was.
    static func addToJSON(_ url: URL) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentError("\(url.path) isn't a JSON object, so it was left alone.")
            }
            root = parsed
            try? FileManager.default.removeItem(at: url.appendingPathExtension("clarishot-backup"))
            try FileManager.default.copyItem(at: url, to: url.appendingPathExtension("clarishot-backup"))
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["clarishot"] = ["command": AgentSetup.cliPath, "args": ["mcp"]]
        root["mcpServers"] = servers
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
