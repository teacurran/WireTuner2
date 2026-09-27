import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTModel
import WTProto
import WTSync
@testable import WireTuner

/// The review sheet over the feature file (opentype-features.adoc, "Working with others";
/// FONT-022): a line both sides edited offline is listed line by line under "Feature file, line N"
/// with *Use mine*, *Use theirs* and *Keep merged*.
@Suite @MainActor struct FeatureFileReviewTests {
    static let features = "feature liga {\n  sub f i by f_i;\n} liga;\n"

    /// Mine types "@A " before "f i" on line 2; theirs replaces "f_i" with "fi_lig" on the same line.
    static func world() -> ReviewWorld {
        var world = ReviewWorld()
        let text = world.base([Ops.textInsert(WellKnown.settings, FontFields.features, features)])
        let id = { (offset: UInt64) in OpID(counter: text.counter + offset, replica: text.replica) }
        world.mine([Ops.textInsert(WellKnown.settings, FontFields.features, "@A ", left: id(20), right: id(21))])
        world.theirs([Ops.textDelete(WellKnown.settings, FontFields.features, first: id(28), count: 3)])
        world.theirs([Ops.textInsert(WellKnown.settings, FontFields.features, "fi_lig", left: id(27), right: id(31))])
        return world
    }

    func model(_ world: ReviewWorld, _ document: DocumentHandle) throws -> (ReviewSheetModel, ReviewSheetModel.ParagraphRow) {
        let review = world.measure()
        let entry = try #require(review.entries.first { $0.node == WellKnown.settings })
        #expect(entry.kinds.contains(.sameText))
        let model = ReviewSheetModel(review: review, merged: world.state, local: world.local, remote: world.remote, context: ReviewHarness().context(document))
        model.select(model.rows.first { $0.node == WellKnown.settings }?.id)
        return (model, try #require(model.paragraphRows.first))
    }

    func features(_ document: DocumentHandle) -> String? { document.state.store.text(WellKnown.settings, FontFields.features)?.string }

    @Test func useTheirsRewritesTheLineToTheirText() async throws {
        let world = Self.world()
        let document = world.document()
        let (model, line) = try model(world, document)
        #expect(line.diff.mine == "  sub @A f i by f_i;\n" && line.diff.theirs == "  sub f i by fi_lig;\n")
        #expect(model.isFeatureFile(line) && model.paragraphChoices(line) == [.mine, .theirs, .merged])
        #expect(model.paragraphTitle(line) == "Feature file, line 2")
        #expect(model.paragraphChoices(line).map(\.title) == ["Use mine", "Use theirs", "Keep merged"])
        let view = NSHostingView(rootView: ReviewSheetView(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 560)
        view.layoutSubtreeIfNeeded()
        _ = await model.perform(.theirs, paragraph: line)?.value
        await document.settle()
        #expect(features(document) == "feature liga {\n  sub f i by fi_lig;\n} liga;\n")
        #expect(model.isReviewed(line.id) && document.undoTitle.contains("Use their text"))
    }

    @Test func useMineRewritesTheLineToMyText() async throws {
        let world = Self.world()
        let document = world.document()
        let (model, line) = try model(world, document)
        ReviewSheetView.paragraph(model, choice: .mine, line)()
        await document.settle()
        #expect(features(document) == "feature liga {\n  sub @A f i by f_i;\n} liga;\n")
    }

    @Test func keepMergedWritesNothing() async throws {
        let world = Self.world()
        let document = world.document()
        let (model, line) = try model(world, document)
        let merged = features(document)
        #expect(merged?.contains("@A") == true && merged?.contains("fi_lig") == true)
        #expect(model.perform(.merged, paragraph: line) == nil && model.isReviewed(line.id))
        await document.settle()
        #expect(features(document) == merged)
        // A read-only review offers nothing.
        var review = world.measure()
        review.mode = .readOnly
        let readOnly = ReviewSheetModel(review: review, merged: world.state, local: world.local, remote: world.remote,
                                        context: ReviewHarness().context(document))
        readOnly.select(readOnly.rows.first { $0.node == WellKnown.settings }?.id)
        if let row = readOnly.paragraphRows.first { #expect(readOnly.perform(.theirs, paragraph: row) == nil) }
    }

    /// A text block's paragraph keeps its three choices, *Use theirs* writing nothing, and no title.
    @Test func aTextBlockKeepsMineTheirsAndBoth() async throws {
        var world = ReviewWorld()
        let layer = world.base([Ops.create(parent: ReviewWorld.layers, position: [0x80], props: ReviewWorld.layer("Text"))])
        let block = world.base([Ops.create(parent: layer, position: [0x80], props: ReviewWorld.textBlock())])
        let text = world.base([Ops.textInsert(block, ReviewWorld.text, "ab")])
        let id = { (offset: UInt64) in OpID(counter: text.counter + offset, replica: text.replica) }
        world.mine([Ops.textInsert(block, ReviewWorld.text, "x", left: id(0), right: id(1))])
        world.theirs([Ops.textInsert(block, ReviewWorld.text, "y", left: id(0), right: id(1))])
        let document = world.document()
        let model = ReviewSheetModel(review: world.measure(), merged: world.state, local: world.local, remote: world.remote,
                                     context: ReviewHarness().context(document))
        let paragraph = try #require(model.paragraphRows.first)
        #expect(!model.isFeatureFile(paragraph) && model.paragraphTitle(paragraph) == nil)
        #expect(model.paragraphChoices(paragraph) == [.mine, .theirs, .both])
        #expect(model.perform(ReviewSheetModel.ParagraphChoice.theirs, paragraph: paragraph) == nil && model.isReviewed(paragraph.id))
        _ = await model.perform(ReviewSheetModel.ParagraphChoice.both, paragraph: paragraph)?.value
        await document.settle()
        #expect(document.state.store.text(block, ReviewWorld.text)?.string.contains("\n") == true)
    }
}
