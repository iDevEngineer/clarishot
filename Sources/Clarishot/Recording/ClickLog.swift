import AppKit

/// Where and when the user clicked during a recording, used to place automatic zooms.
/// Positions are 0…1 within the recorded area, top-left origin; times are recorded seconds.
struct RecordedClick: Codable, Equatable {
    var t: Double
    var x: Double
    var y: Double
}

/// Saved beside the movie as "<movie>.clicks.json".
enum ClickLog {
    static func file(for movie: URL) -> URL { movie.appendingPathExtension("clicks.json") }

    static func save(_ clicks: [RecordedClick], for movie: URL) {
        guard !clicks.isEmpty, let data = try? JSONEncoder().encode(clicks) else { return }
        try? data.write(to: file(for: movie), options: .atomic)
    }

    static func load(for movie: URL) -> [RecordedClick] {
        guard let data = try? Data(contentsOf: file(for: movie)),
              let clicks = try? JSONDecoder().decode([RecordedClick].self, from: data) else { return [] }
        return clicks.filter { $0.t >= 0 && (0...1).contains($0.x) && (0...1).contains($0.y) }
    }

    /// Copies the log along with a movie (e.g. into Capture History).
    static func copy(from movie: URL, to destination: URL) {
        let source = file(for: movie)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.copyItem(at: source, to: file(for: destination))
    }
}
