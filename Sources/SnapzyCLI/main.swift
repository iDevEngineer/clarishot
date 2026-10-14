import Foundation
import ImageIO
import UniformTypeIdentifiers

// `snapzy`: command-line control of the running Snapzy app, plus `snapzy mcp`, an MCP server
// (stdio, JSON-RPC 2.0) so AI tools such as Claude Code, Claude Desktop and Cursor can use it.
// Talks to the app over its local socket; turn on Settings → Advanced → "Allow AI tools & command line".

// MARK: - Talking to the app

struct CLIError: Error { let message: String }

let socketPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Snapzy/agent.sock").path

/// Reads an image file with the caller's own permissions and returns the params Snapzy expects.
func imageParams(_ path: String) throws -> [String: Any] {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard let data = try? Data(contentsOf: url) else { throw CLIError(message: "Can't read \(url.path)") }
    return ["image_base64": data.base64EncodedString(), "name": url.path]
}

/// Sends one request and returns `result`, or throws the app's error.
func call(_ method: String, _ params: [String: Any] = [:]) throws -> Any {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CLIError(message: "Could not open a socket") }
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketPath.utf8CString)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in path.withUnsafeBytes { raw.copyMemory(from: $0) } }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else {
        throw CLIError(message: "Snapzy isn't reachable. Open Snapzy and turn on Settings → Advanced → “Allow AI tools & command line”.")
    }
    var request = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
    request.append(UInt8(ascii: "\n"))
    _ = request.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer[0..<count])
        if data.last == UInt8(ascii: "\n") { break }
    }
    guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CLIError(message: "Snapzy sent an unreadable reply")
    }
    if reply["ok"] as? Bool == true { return reply["result"] ?? NSNull() }
    throw CLIError(message: reply["error"] as? String ?? "Snapzy reported an error")
}

func json(_ value: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "null"
}

/// PNG at `path`, shrunk so its longest side is at most `maxSide`, as base64 (for MCP image results).
func base64PNG(_ path: String, maxSide: Int = 1568) -> String? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceThumbnailMaxPixelSize: maxSide,
                                    kCGImageSourceCreateThumbnailWithTransform: true]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest) ? (data as Data).base64EncodedString() : nil
}

// MARK: - Command line

let usage = """
snapzy: control Snapzy from the terminal or an AI tool.

  snapzy status                       Is Snapzy reachable, and is screen recording allowed?
  snapzy displays                     List screens (index, size, position)
  snapzy windows [APP]                List visible windows (id, app, title, frame)
  snapzy screenshot [options]         Take a screenshot; prints the PNG path
      --fullscreen [--display N]      Whole screen (default)
      --area X,Y,W,H                  Points, top-left origin
      --window ID | --app NAME        One window
      --interactive                   Let you drag an area
      --show                          Also show it in Snapzy (preview, after-capture actions)
  snapzy ocr [--path FILE | --area X,Y,W,H | --interactive]   Print the text it reads
  snapzy history [--limit N] [--kind screenshot|recording|gif]
  snapzy open FILE [--pin | --preview]   Open an image in Annotate (or pin / preview it)
  snapzy record start | stop          Start the recording flow / stop and print the file
  snapzy mcp                          Run as an MCP server over stdio (for AI tools)

Add --json to print raw JSON. Needs Settings → Advanced → “Allow AI tools & command line”.
"""

func value(after flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func areaParams(_ text: String) throws -> [String: Any] {
    let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 4 else { throw CLIError(message: "--area needs X,Y,W,H") }
    return ["x": parts[0], "y": parts[1], "width": parts[2], "height": parts[3]]
}

func captureParams(_ args: [String]) throws -> [String: Any] {
    var p: [String: Any] = [:]
    if let area = value(after: "--area", in: args) { p = try areaParams(area); p["mode"] = "area" }
    if let id = value(after: "--window", in: args).flatMap(Int.init) { p = ["mode": "window", "window_id": id] }
    if let app = value(after: "--app", in: args) { p = ["mode": "window", "app": app] }
    if args.contains("--interactive") { p = ["mode": "interactive"] }
    if args.contains("--fullscreen") || p.isEmpty { p["mode"] = p["mode"] ?? "fullscreen" }
    if let display = value(after: "--display", in: args).flatMap(Int.init) { p["display"] = display }
    return p
}

func runCommand(_ args: [String]) throws {
    let raw = args.contains("--json")
    let command = args.first ?? "help"
    func show(_ result: Any, _ plain: (Any) -> String) { print(raw ? json(result) : plain(result)) }

    switch command {
    case "status":
        show(try call("status")) { json($0) }
    case "displays":
        show(try call("displays")) { json($0) }
    case "windows":
        let app = args.dropFirst().first { !$0.hasPrefix("--") }
        show(try call("windows", app.map { ["app": $0] } ?? [:])) { result in
            ((result as? [[String: Any]]) ?? []).map { w in
                "\(w["id"] ?? "")\t\(w["app"] ?? "")\t\(w["title"] ?? "")"
            }.joined(separator: "\n")
        }
    case "screenshot":
        var p = try captureParams(Array(args.dropFirst()))
        if args.contains("--show") { p["show"] = true }
        show(try call("screenshot", p)) { ($0 as? [String: Any])?["path"] as? String ?? "" }
    case "ocr":
        var p: [String: Any] = [:]
        if let path = value(after: "--path", in: args) { p = try imageParams(path) }
        else if let area = value(after: "--area", in: args) { p = try areaParams(area); p["mode"] = "area" }
        else { p["mode"] = "interactive" }
        show(try call("ocr", p)) { ($0 as? [String: Any])?["text"] as? String ?? "" }
    case "history":
        var p: [String: Any] = ["limit": Int(value(after: "--limit", in: args) ?? "") ?? 10]
        if let kind = value(after: "--kind", in: args) { p["kind"] = kind }
        show(try call("history", p)) { result in
            ((result as? [[String: Any]]) ?? []).map { "\($0["date"] ?? "")\t\($0["kind"] ?? "")\t\($0["path"] ?? "")" }
                .joined(separator: "\n")
        }
    case "open":
        guard let file = args.dropFirst().first(where: { !$0.hasPrefix("--") }) else { throw CLIError(message: "open needs a file") }
        let action = args.contains("--pin") ? "pin" : (args.contains("--preview") ? "preview" : "annotate")
        var p = try imageParams(file)
        p["action"] = action
        show(try call("open", p)) { _ in "Opened \(file)" }
    case "record":
        switch args.dropFirst().first {
        case "start": show(try call("record_start")) { ($0 as? [String: Any])?["started"] as? String ?? "" }
        case "stop": show(try call("record_stop")) { ($0 as? [String: Any])?["path"] as? String ?? "" }
        default: throw CLIError(message: "Use: snapzy record start | stop")
        }
    case "mcp":
        MCPServer().run()
    case "help", "-h", "--help":
        print(usage)
    default:
        throw CLIError(message: "Unknown command “\(command)”.\n\n\(usage)")
    }
}

// MARK: - MCP server (stdio)

final class MCPServer {
    private let tools: [[String: Any]] = [
        tool("snapzy_status", "Check that Snapzy is running and allowed to capture the screen.", [:]),
        tool("list_displays", "List the connected screens with their index, size and position (points, top-left origin).", [:]),
        tool("list_windows", "List visible app windows with id, app name, title and frame (points, top-left origin).",
             ["app": ["type": "string", "description": "Only windows whose app name or bundle id contains this"]]),
        tool("take_screenshot",
             "Take a screenshot with Snapzy. Returns the saved PNG path and the image. mode: fullscreen (default), area (x, y, width, height in points, top-left origin), window (window_id from list_windows, or app name), or interactive (the user drags an area).",
             ["mode": ["type": "string", "enum": ["fullscreen", "area", "window", "interactive"]],
              "display": ["type": "integer", "description": "Screen index for fullscreen"],
              "x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"],
              "window_id": ["type": "integer"], "app": ["type": "string"],
              "show": ["type": "boolean", "description": "Also show it in Snapzy's preview and run its after-capture actions"],
              "include_image": ["type": "boolean", "description": "Return the image itself (default true)"]]),
        tool("read_text",
             "Read the text (OCR) and any QR codes in an image file, a screen area, or an area the user selects.",
             ["path": ["type": "string"], "mode": ["type": "string", "enum": ["area", "interactive", "fullscreen", "window"]],
              "x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"],
              "window_id": ["type": "integer"], "app": ["type": "string"]]),
        tool("recent_captures", "List recent screenshots and recordings from Snapzy's capture history, newest first.",
             ["limit": ["type": "integer"], "kind": ["type": "string", "enum": ["screenshot", "recording", "gif"]]]),
        tool("open_capture", "Open an image in Snapzy: annotate (editor), pin (floating on screen) or preview (Quick Access card).",
             ["path": ["type": "string"], "action": ["type": "string", "enum": ["annotate", "pin", "preview"]]], required: ["path"]),
        tool("start_recording", "Start Snapzy's screen recording flow; the user picks the area and presses Record.", [:]),
        tool("stop_recording", "Stop the current recording and return the saved file path.", [:])
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any],
                             required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard let id = message["id"] else { continue } // notifications need no reply
            let method = message["method"] as? String ?? ""
            let params = message["params"] as? [String: Any] ?? [:]
            var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
            switch method {
            case "initialize":
                reply["result"] = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                                   "capabilities": ["tools": [:]],
                                   "serverInfo": ["name": "snapzy", "version": "1.0.0"],
                                   "instructions": "Snapzy captures the user's screen. Coordinates are points with a top-left origin. Use list_windows to find a window id, then take_screenshot with mode window."]
            case "ping":
                reply["result"] = [:]
            case "tools/list":
                reply["result"] = ["tools": tools]
            case "tools/call":
                reply["result"] = callTool(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
            default:
                reply["error"] = ["code": -32601, "message": "Method not found: \(method)"]
            }
            if let out = try? JSONSerialization.data(withJSONObject: reply) {
                FileHandle.standardOutput.write(out)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        }
    }

    private func text(_ string: String, error: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": string]], "isError": error]
    }

    private func callTool(_ name: String, _ args: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "snapzy_status": return text(json(try call("status")))
            case "list_displays": return text(json(try call("displays")))
            case "list_windows": return text(json(try call("windows", args)))
            case "take_screenshot":
                var params = args
                params.removeValue(forKey: "include_image")
                let result = try call("screenshot", params) as? [String: Any] ?? [:]
                var content: [[String: Any]] = [["type": "text", "text": json(result)]]
                if args["include_image"] as? Bool ?? true, let path = result["path"] as? String, let png = base64PNG(path) {
                    content.append(["type": "image", "data": png, "mimeType": "image/png"])
                }
                return ["content": content, "isError": false]
            case "read_text":
                var params = args
                if let path = params.removeValue(forKey: "path") as? String {
                    params.merge(try imageParams(path)) { $1 }
                } else if params["mode"] == nil {
                    params["mode"] = params["x"] != nil ? "area" : "interactive"
                }
                return text((try call("ocr", params) as? [String: Any])?["text"] as? String ?? "")
            case "recent_captures": return text(json(try call("history", args)))
            case "open_capture":
                guard let path = args["path"] as? String else { return text("open_capture needs path", error: true) }
                var params = try imageParams(path)
                params["action"] = args["action"] ?? "annotate"
                return text(json(try call("open", params)))
            case "start_recording": return text(json(try call("record_start")))
            case "stop_recording": return text(json(try call("record_stop")))
            default: return text("Unknown tool \(name)", error: true)
            }
        } catch {
            return text((error as? CLIError)?.message ?? error.localizedDescription, error: true)
        }
    }
}

// MARK: - Entry

do {
    try runCommand(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("snapzy: \((error as? CLIError)?.message ?? error.localizedDescription)\n".utf8))
    exit(1)
}
