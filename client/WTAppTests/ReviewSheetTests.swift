import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// A fork/branch client that records what it was asked.
final class RecordingWork: ReviewWorkClient, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var failure: (any Error)?

    var recorded: [String] { lock.withLock { calls } }

    func fork(source: String, newID: String, atServerSeq: UInt64, changes: [Wiretuner_Doc_V1_Change], name: String) async throws -> String {
        if let failure { throw failure }
        lock.withLock { calls.append("fork \(source) \(newID) @\(atServerSeq) \(changes.count) \(name)") }
        return newID
    }

    func createBranch(parent: String, branchID: String, name: String, forkServerSeq: UInt64, changes: [Wiretuner_Doc_V1_Change]) async throws -> String {
        if let failure { throw failure }
        lock.withLock { calls.append("branch \(parent) \(branchID) @\(forkServerSeq) \(changes.count) \(name)") }
        return branchID
    }
}

@MainActor
final class ReviewHarness {
    var resolutions: [SyncClient.ReviewResolution] = []
    var opened: [String] = []
    var resolveFailure: (any Error)?
    let work = RecordingWork()
    var local: [Wiretuner_Doc_V1_Change] = []

    func context(_ document: DocumentHandle, work: (any ReviewWorkClient)?? = nil) -> ReviewContext {
        ReviewContext(
            documentID: document.id, documentTitle: document.title, perform: { document.perform($0) },
            resolve: { resolution in
                if let failure = self.resolveFailure { throw failure }
                self.resolutions.append(resolution)
            },
            localWork: { (self.local, 5) },
            work: work ?? self.work, openDocument: { id, name in self.opened.append("\(id) \(name)") },
            keepBothOffset: { 10 }, userName: "Sam", makeID: { "new-id" }, now: { Date(timeIntervalSince1970: 0) }
        )
    }
}

@Suite(.serialized) @MainActor struct ReviewSheetTests {
    /// A layer with two rectangles; both sides resized the first (theirs won), mine renamed the
    /// second which they deleted, Priya moved a third, and I renamed a fourth.
    func world() -> (ReviewWorld, [OpID]) {
        var world = ReviewWorld()
        let layer = world.base([Ops.create(parent: ReviewWorld.layers, position: [0x80], props: ReviewWorld.layer("Art"))])
        let a = world.base([Ops.create(parent: layer, position: [0x80], props: ReviewWorld.rect(width: 10, name: "Logo mark"))])
        let b = world.base([Ops.create(parent: layer, position: [0x81], props: ReviewWorld.rect(width: 10, tx: 40))])
        let c = world.base([Ops.create(parent: layer, position: [0x82], props: ReviewWorld.rect(width: 10, tx: 80))])
        let d = world.base([Ops.create(parent: layer, position: [0x83], props: ReviewWorld.rect(width: 10, tx: 120))])
        world.mine([ReviewWorld.resize(a, width: 30)])
        world.mine([ReviewWorld.rename(b, "Header bar")])
        world.mine([ReviewWorld.rename(d, "Mine only")])
        world.theirs([ReviewWorld.resize(a, width: 50)])
        world.theirs([Ops.setDeleted(b)])
        world.theirs([ReviewWorld.move(c, tx: 90)])
        return (world, [a, b, c, d])
    }

    @Test func theSheetListsFiltersAndPreviews() async throws {
        let (world, nodes) = world()
        let review = world.measure()
        // Two of my three objects overlap: over the 25% share, so the whole-document review.
        #expect(review.mode == .wholeDocument && review.entries.count == 2)
        let document = world.document()
        let harness = ReviewHarness()
        let model = ReviewSheetModel(review: review, merged: world.state, local: world.local, remote: world.remote, context: harness.context(document))
        #expect(model.title == "Review changes" && model.summary.hasPrefix("You made 3 changes offline"))
        #expect(model.overlapLine == "2 objects were changed by both you and someone else.")
        #expect(model.filter == .conflicts)
        #expect(ReviewSheetModel.Filter.allCases.map(model.filterTitle) == ["Everything", "Conflicts (2)", "Mine (1 object)", "Theirs (1)"])
        #expect(model.rows.map(\.kind) == ["Edited and deleted", "Same attribute"])
        #expect(model.rows.map(\.name) == ["Header bar", "Logo mark"])
        model.setFilter(.mine)
        #expect(model.rows.map(\.node) == [nodes[3]] && model.rows[0].kind == "Changed by you")
        model.setFilter(.theirs)
        #expect(model.rows.map(\.kind) == ["Changed by Priya"])
        #expect(model.propertyRows.isEmpty && model.paragraphRows.isEmpty && model.actions.isEmpty)
        #expect(model.previewImage() != nil)
        model.setFilter(.everything)
        #expect(model.rows.count == 4)
        model.setFilter(.conflicts)

        // The same-attribute row: both sizes, theirs kept.
        let sameID = try #require(model.rows.first { $0.node == nodes[0] }?.id)
        model.select(sameID)
        #expect(model.selectedRow?.node == nodes[0])
        let property = try #require(model.propertyRows.first)
        #expect(property.title == "Size" && property.kept == .theirs)
        #expect(property.mine.contains("30") && property.theirs.contains("50"))
        #expect(model.actions == [.useMine, .useTheirs, .keepBoth])
        #expect(model.allowsChoices)

        // Previews: each side renders; mine and theirs differ in width.
        #expect(Objects.bounds(of: nodes[0], in: model.state(.mine))?.width == 30)
        #expect(Objects.bounds(of: nodes[0], in: model.state(.theirs))?.width == 50)
        #expect(Objects.bounds(of: nodes[0], in: model.state(.merged))?.width == 50)
        for side in ReviewSheetModel.Side.allCases {
            model.side = side
            #expect(model.previewImage() != nil)
        }
        model.overlay = true
        #expect(model.previewImage(size: Size(width: 120, height: 80)) != nil)
        model.overlay = false

        // Use theirs marks it reviewed; Use mine writes my width back; Keep both adds a copy.
        #expect(model.perform(.useTheirs) == nil && model.isReviewed(sameID))
        _ = await model.perform(.useMine)?.value
        await document.settle()
        #expect(Objects.bounds(of: nodes[0], in: document.state)?.width == 30)
        #expect(document.undoTitle == "Undo Use my size for Logo mark")
        model.stateDidChange(document.state)
        let before = document.state.liveChildren(document.state.store.placement(nodes[0])!.parent).count
        _ = await model.perform(.keepBoth)?.value
        await document.settle()
        let siblings = document.state.liveChildren(document.state.store.placement(nodes[0])!.parent)
        #expect(siblings.count == before + 1)
        let copy = try #require(siblings.first { !nodes.contains($0) })
        #expect(ObjectNaming.common(document.state.props(copy))?.note.hasPrefix("Copy from Sam's offline edits") == true)
        #expect(document.undoTitle == "Undo Keep both copies of Logo mark")

        // Edited and deleted: Restore brings it back.
        let deletedID = try #require(model.rows.first { $0.node == nodes[1] }?.id)
        model.select(deletedID)
        #expect(model.actions.contains(.restore))
        _ = await model.perform(.restore)?.value
        await document.settle()
        #expect(document.state.isLive(nodes[1]))

        // The view hosts every part.
        let view = NSHostingView(rootView: ReviewSheetView(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 560)
        view.layoutSubtreeIfNeeded()
        ReviewSheetView.select(model, sameID)()
        ReviewSheetView.side(model, .mine)()
        #expect(model.side == .mine && !model.overlay)
        ReviewSheetView.overlay(model)()
        #expect(model.overlay)
        _ = ReviewSheetView.filter(model).wrappedValue
        ReviewSheetView.filter(model).wrappedValue = .everything
        #expect(model.filter == .everything)
        ReviewSheetView.action(model, .useTheirs)()
        _ = ReviewSheetView.diffText(ParagraphDiff(segments: [.init(side: .both, text: "a"), .init(side: .mine, text: "b"), .init(side: .theirs, text: "c")], mine: "ab", theirs: "ac"))
        await document.settle()
    }

    @Test func wholeDocumentChoices() async throws {
        let (world, _) = world()
        let review = world.measure()
        let document = world.document()
        let harness = ReviewHarness()
        harness.local = world.local

        // Keep the merged result uploads and finishes.
        let keep = ReviewSheetModel(review: review, merged: world.state, context: harness.context(document))
        var finished = 0
        keep.onFinish = { finished += 1 }
        #expect(keep.documentActions == [.keepMerged, .saveCopy, .keepBranch])
        #expect(keep.documentActions.map(keep.documentActionTitle) == ["Keep the merged result", "Save my version as a copy…", "Keep my changes on a branch"])
        await keep.run(.keepMerged)
        #expect(harness.resolutions == [.upload] && keep.isFinished && finished == 1 && keep.documentActions.isEmpty)
        #expect(keep.actions.isEmpty && keep.perform(.useMine) == nil)
        await keep.run(.keepMerged)
        await keep.done()
        #expect(harness.resolutions == [.upload])

        // Save my version as a copy forks, then discards the local changes and opens the copy.
        let copy = ReviewSheetModel(review: review, merged: world.state, context: harness.context(document))
        await copy.perform(.saveCopy).value
        #expect(harness.work.recorded == ["fork \(document.id) new-id @5 3 Logo (my version)"])
        #expect(harness.resolutions == [.upload, .discardLocalChanges] && harness.opened == ["new-id Logo (my version)"])
        #expect(copy.message == "Your version was saved as Logo (my version)")

        // Keep my changes on a branch.
        let branch = ReviewSheetModel(review: review, merged: world.state, context: harness.context(document))
        await branch.run(.keepBranch)
        #expect(harness.work.recorded.last == "branch \(document.id) new-id @5 3 Sam's offline edits")
        #expect(ReviewSheetModel.copyName(.keepBranch, title: "T", user: "") == "My offline edits")

        // Offline, too many changes, a failing call, a failing resolve.
        let offline = ReviewSheetModel(review: review, merged: world.state, context: harness.context(document, work: .some(nil)))
        #expect(offline.workUnavailableReason != nil)
        await offline.run(.saveCopy)
        #expect(offline.message == offline.workUnavailableReason)
        harness.local = Array(repeating: world.local[0], count: ReviewRequests.changeLimit + 1)
        let large = ReviewSheetModel(review: review, merged: world.state, context: harness.context(document))
        await large.run(.keepBranch)
        #expect(large.message?.contains("more than") == true && !large.isFinished)
        harness.local = world.local
        harness.work.failure = URLError(.notConnectedToInternet)
        let failing = ReviewSheetModel(review: review, merged: world.state, context: harness.context(document))
        await failing.run(.saveCopy)
        #expect(failing.message != nil && !failing.isFinished)
        harness.work.failure = nil
        harness.resolveFailure = URLError(.cancelled)
        let stuck = ReviewSheetModel(review: review, merged: world.state, context: harness.context(document))
        await stuck.dismiss()
        #expect(stuck.message?.hasPrefix("The review could not be settled") == true && !stuck.isFinished)

        // A read-only review only looks; Done closes it without resolving.
        harness.resolveFailure = nil
        var readOnly = review
        readOnly.mode = .readOnly
        readOnly.documentActions = []
        let looking = ReviewSheetModel(review: readOnly, merged: world.state, context: harness.context(document))
        #expect(!looking.allowsChoices && looking.actions.isEmpty && looking.documentActions.isEmpty)
        let count = harness.resolutions.count
        await looking.done()
        #expect(looking.isFinished && harness.resolutions.count == count)

        // Recovered changes: Send and the branch.
        var recovered = ReviewModel(recovered: SalvageReport(reason: .expired, salvagedChanges: 4, dropped: [
            droppedOp(),
        ]))
        recovered.entries = []
        let salvage = ReviewSheetModel(review: recovered, merged: world.state, context: harness.context(document))
        #expect(salvage.title == "Recovered changes" && salvage.summary.contains("4 changes") && salvage.summary.contains("1 could not"))
        #expect(salvage.documentActionTitle(.keepMerged) == "Send" && salvage.filter == .everything && salvage.overlapLine == nil)
        let clean = ReviewSheetModel(review: ReviewModel(recovered: SalvageReport(reason: .conflict)), merged: world.state, context: harness.context(document))
        #expect(!clean.summary.contains("could not"))
        let view = NSHostingView(rootView: ReviewSheetView(model: offline))
        view.layoutSubtreeIfNeeded()
        ReviewSheetView.document(offline, .saveCopy)()
        ReviewSheetView.done(offline)()
        #expect(await eventually { offline.isFinished })
        await document.settle()
    }

    @Test func sameTextShowsADiffAndParagraphChoices() async throws {
        var world = ReviewWorld()
        let layer = world.base([Ops.create(parent: ReviewWorld.layers, position: [0x80], props: ReviewWorld.layer("Text"))])
        let block = world.base([Ops.create(parent: layer, position: [0x80], props: ReviewWorld.textBlock())])
        let text = world.base([Ops.textInsert(block, ReviewWorld.text, "ab\ncd")])
        let id = { (offset: UInt64) in OpID(counter: text.counter + offset, replica: text.replica) }
        // Mine types "x" after "a" and deletes "d"; theirs deletes "b" and types "!" at the end of the first paragraph.
        world.mine([Ops.textInsert(block, ReviewWorld.text, "x", left: id(0), right: id(1))])
        world.mine([Ops.textDelete(block, ReviewWorld.text, first: id(4), count: 1)])
        world.theirs([Ops.textDelete(block, ReviewWorld.text, first: id(1), count: 1)])
        world.theirs([Ops.textInsert(block, ReviewWorld.text, "!", left: id(1), right: id(2))])
        let review = world.measure()
        let entry = try #require(review.entries.first)
        #expect(entry.kind == .sameText)
        let document = world.document()
        let harness = ReviewHarness()
        let model = ReviewSheetModel(review: review, merged: world.state, local: world.local, remote: world.remote, context: harness.context(document))
        let paragraph = try #require(model.paragraphRows.first)
        #expect(paragraph.diff.mine == "axb\n" && paragraph.diff.theirs == "a!\n")
        #expect(paragraph.diff.segments.map(\.side) == [.both, .mine, .theirs, .both])
        #expect(model.perform(.useTheirs, paragraph: paragraph) == nil && model.isReviewed(paragraph.id))
        _ = await model.perform(.useMine, paragraph: paragraph)?.value
        await document.settle()
        let merged = try #require(document.state.store.text(block, ReviewWorld.text))
        #expect(merged.string == "axb\nc")
        model.stateDidChange(document.state)
        let after = try #require(model.paragraphRows.first)
        _ = await model.perform(.keepBoth, paragraph: after)?.value
        await document.settle()
        #expect(document.state.store.text(block, ReviewWorld.text)?.string.contains("\n") == true)
        // The last paragraph (no newline) keeps both after a newline.
        let last = ParagraphDiff.paragraph(merged, terminator: .zero)
        #expect(last.map { ParagraphDiff.character($0, in: merged) }.joined() == "cd", "tombstones included")
        #expect(ParagraphChoices.keepBoth(node: block, field: ReviewWorld.text, text: merged, ids: last, sides: ChangeSides(), name: "T")?.ops.count == 1)
        #expect(ParagraphChoices.keepBoth(node: block, field: ReviewWorld.text, text: merged, ids: [], sides: ChangeSides(), name: "T") == nil)
        #expect(ParagraphChoices.useMine(node: block, field: ReviewWorld.text, text: merged, ids: [], sides: ChangeSides(), name: "T") == nil)
        #expect(ParagraphDiff.presence(OpID(counter: 999, replica: 3), in: merged, sides: ChangeSides()) == nil)
        #expect(ParagraphDiff.paragraph(merged, terminator: OpID(counter: 999, replica: 3)) == last)
        let view = NSHostingView(rootView: ReviewSheetView(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 560)
        view.layoutSubtreeIfNeeded()
        ReviewSheetView.paragraph(model, .useTheirs, after)()
    }

    @Test func formattingAndHelpers() throws {
        let path = RegisterPath([NodeKind.rect.rawValue, 2])
        #expect(ReviewSheetModel.title(.register(path)) == "Size")
        #expect(ReviewSheetModel.title(.deleted) == "Deleted" && ReviewSheetModel.title(.placement) == "Position")
        #expect(ReviewSheetModel.title(.elementPosition(RegisterPath([NodeKind.path.rawValue, 2]))) == "Contours order")
        #expect(ReviewSheetModel.title(.elementDeleted(RegisterPath([NodeKind.path.rawValue, 2]))) == "Contours removed")
        let state = EngineState()
        #expect(ReviewSheetModel.describe(nil, property: .deleted, state: state) == "Unchanged")
        #expect(ReviewSheetModel.describe(.flag(true), property: .deleted, state: state) == "Deleted")
        #expect(ReviewSheetModel.describe(.flag(false), property: .deleted, state: state) == "Kept")
        #expect(ReviewSheetModel.describe(.flag(true), property: .register(path), state: state) == "Yes")
        #expect(ReviewSheetModel.describe(.flag(false), property: .register(path), state: state) == "No")
        #expect(ReviewSheetModel.describe(.placement(parent: WellKnown.settings, position: [1]), property: .placement, state: state) == "In Document settings")
        #expect(ReviewSheetModel.describe(.register(nil), property: .register(path), state: state) == "Not set")
        #expect(ReviewSheetModel.describe(.register([1, 2]), property: .deleted, state: state) == "2 bytes")
        #expect(ReviewSheetModel.describe([0xFF], path: path) == "1 bytes")
        #expect(ReviewSheetModel.describe([], path: path) == "Default")
        #expect(ReviewSheetModel.varint(300) == [0xAC, 0x02])
        #expect(ReviewSheetModel.actionTitle(.restore) == "Restore" && ReviewSheetModel.actionTitle(.keepBoth) == "Keep both copies")
        var entry = ReviewEntry(node: OpID(counter: 1, replica: 1), kinds: [.sameRegister], properties: [
            PropertyConflict(property: .register(path), mine: .register([1]), theirs: .register([2]), merged: .register([2]), kept: .theirs),
            PropertyConflict(property: .deleted, mine: .flag(false), theirs: .flag(true), merged: .flag(true), kept: .other),
        ])
        #expect(ReviewSheetModel.useMineLabel(entry, name: "Star") == "Use my version of Star")
        entry.properties.removeLast()
        #expect(ReviewSheetModel.useMineLabel(entry, name: "Star") == "Use my size for Star")
        let swapped = ReviewSides.swapped(ReviewEntry(node: entry.node, kinds: [], properties: [
            PropertyConflict(property: .deleted, mine: .flag(true), theirs: .flag(false), merged: nil, kept: .mine),
            PropertyConflict(property: .deleted, mine: nil, theirs: nil, merged: nil, kept: .theirs),
            PropertyConflict(property: .deleted, mine: nil, theirs: nil, merged: nil, kept: .other),
        ]))
        #expect(swapped.properties.map(\.kept) == [.theirs, .mine, .other] && swapped.properties[0].mine == .flag(false))
        #expect(ReviewSides.applying(nil, to: state).stateHash == state.stateHash)

        var props = Wiretuner_Doc_V1_NodeProps()
        for kind in ["path", "rect", "ellipse", "polygon", "group", "text", "image", "layer"] {
            switch kind {
            case "path": props.path = Wiretuner_Doc_V1_PathProps()
            case "rect": props.rect = Wiretuner_Doc_V1_RectProps()
            case "ellipse": props.ellipse = Wiretuner_Doc_V1_EllipseProps()
            case "polygon": props.polygon = Wiretuner_Doc_V1_PolygonProps()
            case "group": props.group = Wiretuner_Doc_V1_GroupProps()
            case "text": props.text = Wiretuner_Doc_V1_TextProps()
            case "image": props.image = Wiretuner_Doc_V1_ImageProps()
            default: props.layer = Wiretuner_Doc_V1_LayerProps()
            }
            KeepBothCopies.setNote("n", on: &props)
            #expect(kind == "layer" || ObjectNaming.common(props)?.note == "n")
        }
        #expect(KeepBothCopies.noteText(user: "", date: Date()).hasPrefix("Copy from your offline edits"))
        var local = Wiretuner_Doc_V1_Change()
        local.replica = 1
        local.startCounter = 10
        local.ops = [Ops.noop(), Ops.noop()]
        var empty = Wiretuner_Doc_V1_Change()
        empty.replica = 2
        let sides = ChangeSides(local: [local, empty], remote: [])
        #expect(sides.isLocal(OpID(counter: 11, replica: 1)) && !sides.isLocal(OpID(counter: 12, replica: 1)) && !sides.isRemote(OpID(counter: 11, replica: 1)))
    }

    @Test func forkAndBranchRequests() async throws {
        typealias Documents = Wiretuner_Docs_V1_DocumentService.Method
        typealias Branches = Wiretuner_Docs_V1_BranchService.Method
        let caller = FakeUnaryCaller([
            route(Documents.Fork.descriptor) { (request: Wiretuner_Docs_V1_ForkRequest) in
                Wiretuner_Docs_V1_ForkResponse.with { $0.document.id = request.newDocumentID + "-made" }
            },
            route(Branches.CreateBranch.descriptor) { (request: Wiretuner_Docs_V1_CreateBranchRequest) in
                Wiretuner_Docs_V1_CreateBranchResponse.with { $0.branch.branchDocumentID = request.branchDocumentID + "-made" }
            },
        ])
        let client = GRPCReviewWorkClient(caller: caller, accessToken: { "t" })
        #expect(try await client.fork(source: "s", newID: "n", atServerSeq: 3, changes: [], name: "x") == "n-made")
        #expect(try await client.createBranch(parent: "p", branchID: "b", name: "y", forkServerSeq: 4, changes: []) == "b-made")
        #expect(caller.tokens.all == ["t", "t"])
        let fork = ReviewRequests.fork(source: "s", newID: "n", atServerSeq: 3, changes: [Wiretuner_Doc_V1_Change()], name: String(repeating: "a", count: 300))
        #expect(fork.sourceDocumentID == "s" && fork.newDocumentID == "n" && fork.atServerSeq == 3 && fork.changes.count == 1 && fork.name.count == 256)
        let branch = ReviewRequests.createBranch(parent: "p", branchID: "b", name: "y", forkServerSeq: 4, changes: [])
        #expect(branch.parentDocumentID == "p" && branch.branchDocumentID == "b" && branch.forkServerSeq == 4 && branch.name == "y")
    }

    @Test func theWindowPresentsAHeldReview() async throws {
        let environment = TestEnvironment()
        let (world, nodes) = world()
        let handle = world.document()
        var document = environment.document
        let session = DocumentSession(document: handle, connector: nil, localUserID: "me")
        document.session = { _ in session }
        let work = RecordingWork()
        document.reviewWork = { work }
        let controller = DocumentWindowController(document: handle, environment: document)
        defer { controller.close() }
        #expect(controller.reviewMerge() == nil)
        let review = world.measure()
        session.handle(.reviewNeeded(review))
        #expect(await eventually { controller.collaboration.review.isShown })
        let model = try #require(controller.collaboration.review.model)
        #expect(model.review == review && model.context.work != nil)
        #expect(controller.presentReview(review) == nil)
        model.select(model.rows.first { $0.node == nodes[0] }?.id)
        _ = await model.perform(.useMine)?.value
        await handle.settle()
        #expect(model.merged.stateHash == handle.state.stateHash)
        await controller.collaboration.review.dismiss()?.value
        #expect(!controller.collaboration.review.isShown)
        #expect(controller.collaboration.review.dismiss() == nil)
        // File > Review Merge… opens the last merge read-only.
        var merged = review
        merged.mode = .readOnly
        session.handle(.merged(merged))
        #expect(controller.statusBar.message.stringValue.hasPrefix("Merged 3 changes from Priya"))
        await controller.reviewMerge()?.value
        #expect(controller.collaboration.review.isShown)
        controller.collaboration.review.close()
        withExtendedLifetime(environment) {}
    }
}
