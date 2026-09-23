import Darwin
import Foundation
import Testing
@testable import WTRender

/// IMG-021, IMG-022: a trace in flight stops promptly when cancelled.  `Trace.run` polls
/// `isCancelled` at least once per row and per contour, and every longer pass polls every few
/// thousand steps, so no stage runs long between polls.
@Suite struct TraceCancellationTests {
    /// The calling thread's CPU time in seconds.  The gaps are measured in the trace thread's
    /// own CPU time rather than wall time, so a loaded machine (a parallel test run, a coverage
    /// build sharing the cores) does not stretch them: only work done between polls counts.
    private static func threadTime() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9
    }

    /// The longest stretch of CPU time between two polls of `isCancelled` while tracing
    /// `bitmap`, and the number of polls; the trace is cancelled once `stop` says so, given the
    /// last progress reported and the polls so far.
    private static func longestGap(
        _ bitmap: Trace.Bitmap,
        options: Trace.Options,
        stop: (_ progress: Double, _ polls: Int) -> Bool
    ) -> (gap: Double, polls: Int) {
        var progress = 0.0
        var polls = 0
        var gap = 0.0
        var previous = threadTime()
        _ = try? Trace.run(bitmap, options: options, progress: { progress = $0 }, isCancelled: {
            let now = threadTime()
            gap = max(gap, now - previous)
            polls += 1
            previous = now
            return stop(progress, polls)
        })
        return (gap, polls)
    }

    /// A debug build polls about every millisecond or two on these inputs; before polling was
    /// added inside the per-label mask pass, the flood fills, the median cut, thinning and the
    /// skeleton graph, single gaps ran from a third of a second up to minutes.  The bound leaves
    /// room for a coverage build and a busy machine.
    static let bound = 0.1

    @Test func outlinePollsOftenOnALargePhotograph() {
        // The input that once took minutes to cancel: quantization, then the per-label passes of
        // the first few palette entries (every entry does the same work).
        let big = TraceFixtures.photograph(width: 1200, height: 1200)
        let measured = Self.longestGap(big, options: Trace.Options(colors: 64)) { progress, _ in progress > 0.36 }
        #expect(measured.polls > 1000)
        #expect(measured.gap < Self.bound, "longest gap \(measured.gap) s over \(measured.polls) polls")
    }

    @Test func noiseMergePollsInsideOneLargeRegion() {
        // The sand band is one 480,000-pixel region: a single flood fill.
        let big = TraceFixtures.photograph(width: 1200, height: 1200)
        let measured = Self.longestGap(big, options: Trace.Options(colors: 64, noiseTolerance: 8)) { progress, _ in progress > 0.31 }
        #expect(measured.gap < Self.bound, "longest gap \(measured.gap) s over \(measured.polls) polls")
    }

    @Test func centerlinePollsWhileThinningALargeFeature() {
        // Each band is one wide feature: flood fill, distance transform, thinning and the
        // skeleton graph all run over it.
        let big = TraceFixtures.photograph(width: 600, height: 600)
        var entered = 0
        let measured = Self.longestGap(big, options: Trace.Options(colors: 4, mode: .centerline)) { progress, polls in
            if progress >= 0.3 && entered == 0 {
                entered = polls
            }
            return entered > 0 && polls - entered > 3000
        }
        #expect(measured.gap < Self.bound, "longest gap \(measured.gap) s over \(measured.polls) polls")
    }

    @Test func longBoundaryPollsWhileWalking() throws {
        // A 5,000 × 1 strip: one boundary of 10,002 lattice steps, polled on entry and every
        // `stepsPerPoll` steps along it.
        var tracer = TraceOutline(width: 5000, height: 1)
        try tracer.load(check: {}) { _ in true }
        var polls = 0
        let area = try tracer.walk(fromX: 0, y: 0, check: { polls += 1 })
        #expect(area == 2 * 5000)
        #expect(polls == 1 + 10_002 / TraceOutline.stepsPerPoll)
        var remaining = 2
        #expect(throws: Trace.Cancelled.self) {
            try tracer.walk(fromX: 0, y: 0, check: {
                remaining -= 1
                if remaining == 0 {
                    throw Trace.Cancelled()
                }
            })
        }
    }

    @Test func outerEdgePollsWhileLoadingTheMask() {
        let big = TraceFixtures.photograph(width: 1200, height: 1200)
        let measured = Self.longestGap(big, options: Trace.Options(colors: 64, outerEdge: true)) { _, _ in false }
        #expect(measured.gap < Self.bound, "longest gap \(measured.gap) s over \(measured.polls) polls")
    }
}
