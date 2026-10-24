import Foundation
import os

/// Timing marks for the capture path. Each one is a signpost (Instruments → Points of Interest
/// and os_signpost) and a log line in milliseconds (category "perf"), which scripts/perf.sh reads.
/// Both cost next to nothing while nobody is recording or streaming the log.
enum Perf {
    private static let subsystem = "com.scottmackey.clarishot"
    private static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
    private static let log = Logger(subsystem: subsystem, category: "perf")
    /// When the current capture was asked for (shortcut, menu, URL), for end-to-end marks.
    nonisolated(unsafe) private static var triggered: ContinuousClock.Instant?

    struct Span {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
        fileprivate let start = ContinuousClock.now

        func end() {
            Perf.signposter.endInterval(name, state)
            Perf.log.debug("span \(String(describing: name), privacy: .public) \(Perf.ms(ContinuousClock.now - start), privacy: .public)")
        }
    }

    static func begin(_ name: StaticString) -> Span {
        Span(name: name, state: signposter.beginInterval(name))
    }

    /// Times `body`, including any awaits inside it.
    static func measure<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let span = begin(name)
        defer { span.end() }
        return try await body()
    }

    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let span = begin(name)
        defer { span.end() }
        return try body()
    }

    /// Start of a user-visible capture.
    static func trigger(_ name: String) {
        triggered = .now
        signposter.emitEvent("trigger")
        log.debug("trigger \(name, privacy: .public)")
    }

    /// A user-visible moment (overlay shown, preview card shown), timed from the last trigger.
    static func mark(_ name: StaticString) {
        signposter.emitEvent(name)
        guard let triggered else { return }
        log.debug("mark \(String(describing: name), privacy: .public) \(ms(ContinuousClock.now - triggered), privacy: .public)")
    }

    private static func ms(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return String(format: "%.2f", Double(seconds) * 1000 + Double(attoseconds) / 1e15)
    }
}
