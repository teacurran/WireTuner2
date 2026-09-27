import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTSync
@testable import WireTuner

/// The review sheet's rows for released pages (DOC-013), rescaled glyph objects (FONT-007) and
/// removed symbols and styles (LIB-023).
@Suite(.serialized) @MainActor struct ReviewRowsGlueTests {
    @Test func releasedPagesRescalesAndRemovedTargetsAreRowsWithTheirChoices() async throws {
        let document = DocumentHandle.memory(title: "Rows")
        await document.settle()
        let objects = await document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 20, y: 0, width: 10, height: 10),
                                                    Rect(x: 40, y: 0, width: 10, height: 10), Rect(x: 60, y: 0, width: 10, height: 10)]).map(\.opID)
        let page = document.activePage.id
        let master = OpID(counter: 7, replica: 9)
        let release = ReleasedPage(page: page, master: master, replica: 2, change: OpID(counter: 50, replica: 2), groups: [objects[0]])
        var review = ReviewModel(recovered: SalvageReport(reason: .conflict))
        review.entries = [ReviewEntry(node: objects[3], kinds: [.bothEdited], actions: [.useMine, .useTheirs])]
        review.releaseOverlaps = [ReleaseOverlap(kind: .duplicateRelease, page: page, master: master, release: release, earlier: release, authors: [2]),
                                  ReleaseOverlap(kind: .staleMaster, page: objects[1], master: master, release: release, authors: [2])]
        review.rescaleRows = [RescaleEntry(node: objects[2], glyph: page, reason: .drawnWhileRescaled, factor: 2, authors: [2]),
                              RescaleEntry(node: objects[3], glyph: page, reason: .transformKept, factor: 2, authors: [2])]
        review.removedTargets = [RemovedTargetEntry(kind: .removedStyle, object: objects[1], target: OpID(counter: 404, replica: 9), authors: [2])]
        let harness = ReviewHarness()
        let model = ReviewSheetModel(review: review, merged: document.state, context: harness.context(document))
        #expect(model.filter == .conflicts)
        // The transform-kept rescale is not a row of its own: its object is listed already.
        #expect(model.rows.map(\.kind) == ["Both edited", "Duplicate release", "Released stale master", "Drawn while the font was rescaled",
                                           "Uses a removed style"])
        #expect(model.rows[1].name.hasSuffix(" from \(ObjectNaming.name(of: master, in: document.state))"))
        Render.view(ReviewSheetView(model: model), size: CGSize(width: 800, height: 560))

        // The object row carries *Rescale* beside its own choices.
        model.select(review.entries[0].id)
        #expect(model.dataChoices == ["Rescale"])
        let rescaled = try #require(model.performData("Rescale"))
        #expect(await rescaled.value?.label == "Rescale Object")

        // Duplicate release: *Remove duplicates* deletes the later release's copies; *Keep my copies* writes nothing.
        model.select(review.releaseOverlaps[0].id)
        #expect(model.dataChoices == ["Remove duplicates", "Keep my copies"])
        #expect(model.performData("Keep my copies") == nil)
        let removed = try #require(model.performData("Remove duplicates"))
        _ = await removed.value
        await document.settle()
        #expect(!document.state.isLive(objects[0]) && model.isReviewed(review.releaseOverlaps[0].id))
        model.select(review.releaseOverlaps[1].id)
        #expect(model.dataChoices == ["Update the copies", "Keep my copies"])

        // Drawn while rescaled: *Rescale mine*.
        model.select(review.rescaleRows[0].id)
        #expect(model.dataChoices == ["Rescale mine"])
        #expect(await model.performData("Rescale mine")?.value?.label == "Rescale Object")

        // A removed style that is not here: Restore writes nothing, Keep look reports why it failed.
        model.select(review.removedTargets[0].id)
        #expect(model.dataChoices == ["Restore", "Keep look"])
        #expect(model.performData("Restore") == nil)
        _ = model.performData("Keep look")

        // Rescale all: every rescale row in one change.
        #expect(model.rescaleAll?.nodes == [objects[2], objects[3]])
        ReviewSheetView.rescaleAll(model)()
        let all = try #require(model.performRescaleAll())
        #expect(await all.value?.label == "Rescale 2 Objects")
        #expect(model.isReviewed(review.rescaleRows[0].id) && model.isReviewed(review.entries[0].id))
    }

    @Test func aReadOnlyReviewOffersNoRowChoices() async throws {
        let document = DocumentHandle.memory(title: "Rows")
        await document.settle()
        let node = try #require(await document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)]).first?.opID)
        var review = ReviewModel(recovered: SalvageReport(reason: .conflict))
        review.mode = .readOnly
        review.rescaleRows = [RescaleEntry(node: node, glyph: node, reason: .drawnWhileRescaled, factor: 2, authors: [])]
        let model = ReviewSheetModel(review: review, merged: document.state, context: ReviewHarness().context(document))
        #expect(model.rows.count == 1 && model.dataChoices.isEmpty && model.rescaleAll == nil && model.performRescaleAll() == nil)
    }
}
