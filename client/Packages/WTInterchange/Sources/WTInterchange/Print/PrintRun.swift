// One print job being drawn (PRINT-013; docs/_includes/printing/print-performance.adoc,
// "Watching and cancelling a job", "Client").  The job draws from its plan -- an immutable
// snapshot of the document taken at btn:[Print] -- off the main actor, reports the sheet being
// drawn (`Drawing sheet 3 of 8, Magenta`) to the progress sheet, and stops on btn:[Cancel]:
// the sheet in progress stops at its next band or screener tile, no further sheet is drawn, and
// the plan -- the snapshot -- is released at once.  The print view's `draw` calls
// `draw(sheet:into:)` per sheet; `pdf()` is the same drawing into a PDF for callers without a
// print operation.

import CoreGraphics
import Foundation

/// What the progress sheet shows.
public struct PrintProgress: Hashable, Sendable {
    /// The sheet being drawn, from 0.
    public var sheet: Int
    public var count: Int
    /// The sheet's name (`Page 1, Magenta`).
    public var name: String

    public init(sheet: Int, count: Int, name: String) {
        self.sheet = sheet
        self.count = count
        self.name = name
    }

    /// The bar: sheets finished over sheets.
    public var fraction: Double { count > 0 ? Double(sheet) / Double(count) : 1 }

    /// `Drawing sheet 3 of 8, Page 1, Magenta`.
    public var label: String { "Drawing sheet \(sheet + 1) of \(count), \(name)" }
}

/// A print job drawing its sheets.  Thread-safe: the progress sheet cancels from the main actor
/// while the job draws on another thread.
public final class PrintRun: @unchecked Sendable {
    private let lock = NSLock()
    private var heldPlan: PrintPlan?
    private var cancelled = false
    private var drawn = 0
    /// The sheet count, kept after the plan is released.
    public let count: Int
    private let renderer: PrintSheetRenderer
    private let report: @Sendable (PrintProgress) -> Void

    /// A job over `plan` drawn by `renderer` (whose cancellation check is replaced by the
    /// job's), reporting each sheet to `progress` before drawing it.
    public init(plan: PrintPlan, renderer: PrintSheetRenderer = PrintSheetRenderer(), progress: @escaping @Sendable (PrintProgress) -> Void = { _ in }) {
        heldPlan = plan
        count = plan.count
        report = progress
        var renderer = renderer
        let flag = CancelFlag()
        renderer.isCancelled = { flag.isSet }
        self.renderer = renderer
        self.flag = flag
    }

    private let flag: CancelFlag

    /// The job's snapshot, until the job finishes or is cancelled.
    public var plan: PrintPlan? { lock.withLock { heldPlan } }

    public var isCancelled: Bool { lock.withLock { cancelled } }

    /// Sheets drawn to the end.
    public var sheetsDrawn: Int { lock.withLock { drawn } }

    /// btn:[Cancel]: the sheet in progress stops at its next band or tile, no further sheet is
    /// drawn, and the snapshot is released.
    public func cancel() {
        flag.set()
        lock.withLock {
            cancelled = true
            heldPlan = nil
        }
    }

    /// Releases the snapshot once the job is spooled.
    public func finish() {
        lock.withLock { heldPlan = nil }
    }

    /// The progress for sheet `index` (nil once the snapshot is released).
    public func progress(for index: Int) -> PrintProgress? {
        guard let plan, plan.sheets.indices.contains(index) else { return nil }
        return PrintProgress(sheet: index, count: count, name: plan.sheets[index].name)
    }

    /// Sheet `index` into `context` (a y-up context whose user space is the paper in points).
    /// Throws `CancellationError` without drawing once the job is cancelled, and from inside the
    /// sheet when it is cancelled while drawing; the last sheet releases the snapshot.
    public func draw(sheet index: Int, into context: CGContext) throws {
        try draw(sheet: index, into: context, renderer: renderer)
    }

    func draw(sheet index: Int, into context: CGContext, renderer: PrintSheetRenderer) throws {
        guard let plan, !isCancelled, let progress = progress(for: index) else { throw CancellationError() }
        report(progress)
        try renderer.draw(sheet: index, of: plan, into: context)
        let finished = lock.withLock {
            drawn += 1
            return drawn == count
        }
        if finished { finish() }
    }

    /// Every sheet as one PDF page each, drawn for vector output as `PrintPDF.data` draws them;
    /// throws `CancellationError` when cancelled before or during the job (nothing is returned,
    /// so nothing reaches a queue).
    public func pdf(title: String? = nil) throws -> Data {
        guard let plan else { throw CancellationError() }
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: plan.request.paper.size.width, height: plan.request.paper.size.height)
        let info = [kCGPDFContextTitle: title ?? plan.request.scene.name, kCGPDFContextCreator: "WireTuner"] as CFDictionary
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &mediaBox, info)!
        var vector = renderer
        vector.base = renderer.base.forVectorOutput()
        do {
            for index in 0..<count {
                context.beginPDFPage(nil)
                defer { context.endPDFPage() }
                try draw(sheet: index, into: context, renderer: vector)
            }
        } catch {
            context.closePDF()
            throw error
        }
        context.closePDF()
        return data as Data
    }

    /// Draws the job on a background task: `pdf()` off the caller's actor.
    public func pdfInBackground(title: String? = nil) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { [self] in try pdf(title: title) }.value
    }
}

/// The cancellation flag the renderer polls between bands (no reference to the job, so a
/// renderer copy never keeps the snapshot alive).
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}
