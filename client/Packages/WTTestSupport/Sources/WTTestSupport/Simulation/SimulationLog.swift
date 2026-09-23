import Foundation
import Synchronization

/// The simulator's trace: every edit batch, fault, transition and check, stamped with simulated
/// time, which a failure prints the end of and writes out whole.
public final class SimulationLog: Sendable {
    private let clock: SimClock
    private let lines = Mutex<[String]>([])

    public init(clock: SimClock) {
        self.clock = clock
    }

    public func record(_ line: String) {
        let seconds = SimClock.seconds(clock.elapsed)
        let stamped = String(format: "[%10.3fs] ", seconds) + line
        lines.withLock { $0.append(stamped) }
    }

    public var all: [String] { lines.withLock { $0 } }

    public func tail(_ count: Int) -> [String] {
        lines.withLock { Array($0.suffix(count)) }
    }

    /// Writes the trace, after `header`, to `url` (creating its directory).
    public func write(to url: URL, header: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = header + "\n\n" + all.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url)
    }
}
