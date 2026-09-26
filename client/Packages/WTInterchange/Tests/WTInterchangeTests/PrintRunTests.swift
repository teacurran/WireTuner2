// PRINT-013: a print job drawn from its snapshot with progress and cancellation, the banded
// rasterizer's memory bound, and the print-time raster effect resolution.

import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct PrintRunTests {
    /// Five sheets: the separated page's four process plates and one spot plate.
    static func plan(rasterizeDPI: Double = 0) -> PrintPlan {
        PrintPlan(PrintSheetTests.request([PrintSheetTests.separated], options: PrintOptions(separations: true, marks: [.crop], rasterizeDPI: rasterizeDPI,
                                                                                           plates: PrintSheetTests.plates), paper: PrintSheetTests.small))
    }

    static func context(_ plan: PrintPlan) -> CGContext {
        let surface = BitmapSurface(width: Int(plan.request.paper.size.width), height: Int(plan.request.paper.size.height))!
        return surface.context
    }

    final class Reports: @unchecked Sendable {
        let lock = NSLock()
        var items: [PrintProgress] = []
        var onReport: ((PrintProgress) -> Void)?
        func add(_ progress: PrintProgress) {
            lock.withLock { items.append(progress) }
            onReport?(progress)
        }
    }

    @Test func progressNamesEachSheetAndCancelStopsTheJob() throws {
        let plan = Self.plan()
        #expect(plan.count == 5)
        let reports = Reports()
        let run = PrintRun(plan: plan, progress: reports.add)
        #expect(run.count == 5 && run.plan != nil && !run.isCancelled)
        let context = Self.context(plan)
        try run.draw(sheet: 0, into: context)
        try run.draw(sheet: 1, into: context)
        #expect(reports.items.map(\.sheet) == [0, 1])
        #expect(reports.items[1].label == "Drawing sheet 2 of 5, \(plan.sheets[1].name)")
        #expect(reports.items[0].fraction == 0 && reports.items[1].fraction == 0.2)
        #expect(run.progress(for: 9) == nil)
        run.cancel()
        // Nothing further is drawn and the snapshot is released at once.
        #expect(run.isCancelled && run.plan == nil)
        #expect(throws: CancellationError.self) { try run.draw(sheet: 2, into: context) }
        #expect(run.sheetsDrawn == 2 && reports.items.count == 2)
        #expect(run.progress(for: 0) == nil)
        #expect(throws: CancellationError.self) { try run.pdf() }
        #expect(PrintProgress(sheet: 0, count: 0, name: "").fraction == 1)
    }

    /// The whole job as a PDF, one page per sheet; the snapshot goes when the last sheet is drawn.
    @Test func aFinishedJobReleasesItsSnapshot() async throws {
        let plan = Self.plan()
        let run = PrintRun(plan: plan)
        let data = try await run.pdfInBackground(title: "Job")
        let document = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        #expect(document.numberOfPages == 5)
        #expect(run.plan == nil && run.sheetsDrawn == 5)
        // Same pages as *Save as PDF*.
        #expect(try CGPDFDocument(CGDataProvider(data: PrintPDF.data(plan) as CFData)!)!.numberOfPages == 5)
        let explicit = PrintRun(plan: plan)
        explicit.finish()
        #expect(explicit.plan == nil)
    }

    /// Cancelling while sheet 2 is being drawn stops it at its next band and sends nothing.
    @Test func cancelDuringASheetStopsAtTheNextBand() throws {
        let plan = Self.plan(rasterizeDPI: 144)
        var renderer = PrintSheetRenderer()
        renderer.bandHeight = 8
        let reports = Reports()
        let box = RunBox()
        reports.onReport = { progress in if progress.sheet == 2 { box.run?.cancel() } }
        let run = PrintRun(plan: plan, renderer: renderer, progress: reports.add)
        box.run = run
        #expect(throws: CancellationError.self) { try run.pdf() }
        #expect(run.sheetsDrawn == 2 && run.plan == nil)
        #expect(reports.items.map(\.sheet) == [0, 1, 2])
    }

    final class RunBox: @unchecked Sendable {
        var run: PrintRun?
    }

    /// A tabloid sheet at 1200 dpi rasterizes in bands whose bitmap stays under 512 MiB.
    @Test func rasterBandsBoundTheMemory() {
        let tabloid = PrintPaper(size: Size(width: 792, height: 1224), imageable: Rect(x: 0, y: 0, width: 792, height: 1224))
        let page = ExportPage(bounds: Rect(x: 0, y: 0, width: 792, height: 1224), displayList: DisplayList(canvas: "p", items: [
            PrintSheetTests.square(Rect(x: 0, y: 0, width: 792, height: 1224), Color(red: 0.2, green: 0.4, blue: 0.6)),
        ]), number: 1)
        let plan = PrintPlan(PrintSheetTests.request([page], options: PrintOptions(rasterizeDPI: 1200), paper: tabloid))
        let bytes = PrintSheetRenderer().rasterBandBytes(plan)
        #expect(bytes > 0 && bytes < 512 * 1024 * 1024, "\(bytes)")
        #expect((13_200 * 4096 * 4...13_202 * 4096 * 4).contains(bytes))
    }

    /// Sheets render raster effects at each object's own resolution, synchronously, whatever the
    /// window's preview preference.
    @Test func printTimeRasterEffectResolution() {
        var base = CoreGraphicsRenderer()
        base.rasterPreview = .off
        base.rasterEffectsReady = { _ in }
        let renderer = PrintSheetRenderer(base: base).renderer(for: Self.plan())
        #expect(renderer.rasterPreview == .document)
        #expect(renderer.rasterEffectsReady == nil)
    }
}
