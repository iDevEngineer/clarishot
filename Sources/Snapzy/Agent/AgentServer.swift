import AppKit
import Darwin

/// Local connection for the `snapzy` command-line tool and its MCP server mode, so AI tools
/// and scripts can drive Snapzy. Off unless "Allow AI tools & command line" is on in Settings.
///
/// A Unix socket at ~/Library/Application Support/Snapzy/agent.sock, readable only by this
/// user (folder 0700, socket 0600; peers from other users are refused). Each connection sends
/// one line of JSON `{"method": "...", "params": {...}}` and gets one line back:
/// `{"ok": true, "result": ...}` or `{"ok": false, "error": "..."}`.
@MainActor
final class AgentServer {
    static let shared = AgentServer()

    static var socketURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snapzy/agent.sock")
    }

    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    /// Starts or stops to match the setting. Call at launch and whenever settings change.
    func sync() {
        if Settings.shared.allowAgentAccess { start() } else { stop() }
    }

    private func start() {
        guard listener < 0 else { return }
        let url = Self.socketURL
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        chmod(folder.path, 0o700)
        unlink(url.path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return }
        chmod(url.path, 0o600)
        listener = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { Self.acceptOne(fd) }
        source.resume()
        self.source = source
    }

    private func stop() {
        guard listener >= 0 else { return }
        source?.cancel()
        source = nil
        close(listener)
        listener = -1
        unlink(Self.socketURL.path)
    }

    /// Accepts a connection, reads one request line, answers it on the main actor.
    nonisolated private static func acceptOne(_ listener: Int32) {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        // Only processes running as this same user.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); return }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.last != UInt8(ascii: "\n"), data.count < 80_000_000 { // room for an image sent as base64
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let method = request["method"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]
        let paramData = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)

        Task { @MainActor in
            var reply: [String: Any]
            do {
                let decoded = (try? JSONSerialization.jsonObject(with: paramData)) as? [String: Any] ?? [:]
                reply = ["ok": true, "result": try await AgentAPI.handle(method, decoded)]
            } catch {
                reply = ["ok": false, "error": (error as? AgentError)?.message ?? error.localizedDescription]
            }
            var bytes = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(#"{"ok":false}"#.utf8)
            bytes.append(UInt8(ascii: "\n"))
            DispatchQueue.global().async {
                bytes.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let written = write(client, raw.baseAddress! + offset, raw.count - offset)
                        if written <= 0 { break }
                        offset += written
                    }
                }
                close(client)
            }
        }
    }
}

struct AgentError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
