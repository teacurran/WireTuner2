// Progress and cancellation for long exports (animation.adoc, "Client": MP4 "runs off the main
// actor with progress"; WEB-019, WEB-020).  The exporter reports the fraction done and checks
// `isCancelled` between frames; the Export sheet reads the fraction, and cancelling -- the
// sheet's button or the task running the export -- stops the export, which removes its partial
// file and throws `ExportError.cancelled`.

import Foundation

public final class ExportProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0.0
    private var cancelled = false
    private let changed: (@Sendable (Double) -> Void)?

    /// `onChange` is called on the exporting thread with each new fraction.
    public init(onChange: (@Sendable (Double) -> Void)? = nil) {
        changed = onChange
    }

    /// 0 ... 1.
    public var fraction: Double {
        lock.withLock { done }
    }

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    public func cancel() {
        lock.withLock { cancelled = true }
    }

    func report(_ fraction: Double) {
        let value = min(max(fraction, 0), 1)
        lock.withLock { done = value }
        changed?(value)
    }

    /// Throws `ExportError.cancelled` once cancelled.
    func check() throws {
        if isCancelled {
            throw ExportError.cancelled
        }
    }
}
