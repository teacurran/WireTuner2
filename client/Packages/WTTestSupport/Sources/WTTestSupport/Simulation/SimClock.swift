import Foundation
import Synchronization

/// Simulated time (docs/spec/testing.adoc, "Multi-client simulation").
///
/// A scenario speaks in simulated time -- ten minutes of editing, 200 ms of latency, 48 hours
/// offline -- and runs compressed: `scale` real seconds pass per simulated second, so ten
/// simulated minutes at 0.01 take six real seconds and 200 ms of latency is 2 ms.  `advance(by:)`
/// jumps the clock without waiting (a day offline, a token lifetime): everything that reads
/// wall time -- the server's token expiry and stability job, the clients' change timestamps and
/// reconnect gap -- sees the jump.  The sync client's own timers (ack interval, backoff) are
/// real durations and are not scaled; the simulation gives them short values instead.
public final class SimClock: Sendable {
    /// Real seconds per simulated second.
    public let scale: Double
    private let origin: Date
    private let started: ContinuousClock.Instant
    private let jumped = Mutex<Duration>(.zero)

    /// A clock reading `origin` now.  The default origin is a fixed date, so change timestamps
    /// do not depend on when the test ran.
    public init(scale: Double = 0.01, origin: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        precondition(scale > 0)
        self.scale = scale
        self.origin = origin
        started = .now
    }

    /// Simulated time elapsed since the clock started.
    public var elapsed: Duration {
        let real = ContinuousClock.now - started
        return real / scale + jumped.withLock { $0 }
    }

    /// The simulated wall time.
    public func now() -> Date {
        origin.addingTimeInterval(Self.seconds(elapsed))
    }

    /// The simulated wall time in milliseconds since the epoch.
    public func nowMs() -> Int64 {
        Int64((now().timeIntervalSince1970 * 1_000).rounded(.down))
    }

    /// Jumps simulated time forward by `duration` at once.
    public func advance(by duration: Duration) {
        jumped.withLock { $0 += max(duration, .zero) }
    }

    /// The real duration `duration` of simulated time takes.
    public func real(_ duration: Duration) -> Duration {
        duration * scale
    }

    /// Sleeps for `duration` of simulated time (scaled to real time).
    public func sleep(_ duration: Duration) async throws {
        guard duration > .zero else { return }
        try await Task.sleep(for: real(duration))
    }

    /// A reading of this clock off by `skew` (a client whose clock runs ahead or behind).
    public func skewed(by skew: Duration) -> @Sendable () -> Date {
        { self.now().addingTimeInterval(Self.seconds(skew)) }
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
