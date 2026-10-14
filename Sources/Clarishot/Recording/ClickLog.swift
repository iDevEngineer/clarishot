import AppKit

/// Where and when the user clicked during a recording, used to place automatic zooms.
/// Positions are 0…1 within the recorded area, top-left origin; times are recorded seconds.
struct RecordedClick: Codable, Equatable {
    var t: Double
    var x: Double
    var y: Double
}

/// Clicks plus the pointer's path (sampled about 20 times a second), same units as clicks.
struct PointerLog: Codable {
    var clicks: [RecordedClick] = []
    var cursor: [RecordedClick] = []
}

/// Saved beside the movie as "<movie>.clicks.json".
enum ClickLog {
    static func file(for movie: URL) -> URL { movie.appendingPathExtension("clicks.json") }

    static func save(_ log: PointerLog, for movie: URL) {
        guard !log.clicks.isEmpty || !log.cursor.isEmpty, let data = try? JSONEncoder().encode(log) else { return }
        try? data.write(to: file(for: movie), options: .atomic)
    }

    static func load(for movie: URL) -> PointerLog {
        guard let data = try? Data(contentsOf: file(for: movie)) else { return PointerLog() }
        let valid: (RecordedClick) -> Bool = { $0.t >= 0 && (0...1).contains($0.x) && (0...1).contains($0.y) }
        if let log = try? JSONDecoder().decode(PointerLog.self, from: data) {
            return PointerLog(clicks: log.clicks.filter(valid), cursor: log.cursor.filter(valid).sorted { $0.t < $1.t })
        }
        // Older logs were a plain list of clicks.
        let clicks = (try? JSONDecoder().decode([RecordedClick].self, from: data)) ?? []
        return PointerLog(clicks: clicks.filter(valid))
    }

    /// Copies the log along with a movie (e.g. into Capture History).
    static func copy(from movie: URL, to destination: URL) {
        let source = file(for: movie)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.copyItem(at: source, to: file(for: destination))
    }
}
