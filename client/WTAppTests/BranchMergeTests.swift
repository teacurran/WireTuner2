import AppKit
import Foundation
import GRPCCore
import GRPCProtobuf
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// A flag a `Sendable` route reads.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A merge client answering from a script.
final class FakeBranchMerging: BranchMerging, @unchecked Sendable {
    var answers: [Result<MergeResult, any Error>] = []
    private(set) var requests: [(seq: UInt64, excluded: [OpID], keepOpen: Bool)] = []

    func merge(branch: String, reviewedParentSeq: UInt64, excluded: [OpID], keepOpen: Bool) async throws -> MergeResult {
        requests.append((reviewedParentSeq, excluded, keepOpen))
        return try (answers.isEmpty ? .success(MergeResult(firstParentSeq: 1, lastParentSeq: 1, droppedOps: 0)) : answers.removeFirst()).get()
    }
}

/// COLLAB-018: the merge review, exclusions (*Use main*), *Keep branch open*, `MERGE_STALE` reopening
/// the review, and the result.
@Suite(.serialized) @MainActor struct BranchMergeTests {
    @Test func theClientSendsExclusionsAndMapsAStaleMain() async throws {
        typealias Methods = Wiretuner_Docs_V1_BranchService.Method
        let stale = LockedFlag()
        let caller = FakeUnaryCaller([
            route(Methods.MergeBranch.descriptor) { (request: Wiretuner_Docs_V1_MergeBranchRequest) -> Wiretuner_Docs_V1_MergeBranchResponse in
                if stale.value {
                    throw RPCError(GoogleRPCStatus(code: .failedPrecondition, message: "stale", details: [.errorInfo(reason: "MERGE_STALE", domain: "wiretuner.app")]))
                }
                return .with {
                    $0.firstParentSeq = request.reviewedParentSeq + 1
                    $0.lastParentSeq = request.reviewedParentSeq + UInt64(request.excludedNodes.count) + 3
                    $0.droppedOps = request.keepOpen ? 2 : 0
                }
            },
        ])
        let client = GRPCBranchMerging(caller: caller) { "token" }
        let result = try await client.merge(branch: "b1", reviewedParentSeq: 10, excluded: [OpID(counter: 5, replica: 1)], keepOpen: true)
        #expect(result == MergeResult(firstParentSeq: 11, lastParentSeq: 14, droppedOps: 2))
        stale.value = true
        await #expect(throws: MergeFailure.stale) { _ = try await client.merge(branch: "b1", reviewedParentSeq: 10, excluded: [], keepOpen: false) }
        let other = RPCError(code: .internalError, message: "boom")
        #expect(GRPCBranchMerging.mapped(other) is RPCError && GRPCBranchMerging.mapped(CocoaError(.fileNoSuchFile)) is CocoaError)
    }

    @Test func theReviewExcludesUseMainAndReopensWhenMainMovedOn() async throws {
        let main = DocumentHandle.memory(title: "Main")
        let shared = await main.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 20, y: 0, width: 10, height: 10)])
        var branchCore = DocumentCore(state: main.state, replica: 0xB)
        _ = try branchCore.perform(MoveObjects([shared[0].opID], by: Vector(dx: 5, dy: 0)), recording: DocumentCore.Recording(limit: 1, now: Date()))
        _ = try branchCore.perform(MoveObjects([shared[1].opID], by: Vector(dx: 0, dy: 5)), recording: DocumentCore.Recording(limit: 1, now: Date()))
        let branch = branchCore.state
        let merging = FakeBranchMerging()
        let reads = TestBox(0)
        let mainState = TestBox(main.state)
        let model = BranchMergeModel(branchID: "b1", branchName: "Try colours", branch: branch, main: main.state, mainSeq: 7, merging: merging) {
            reads.value += 1
            return (branch, mainState.value, 9)
        }
        #expect(model.entries.count == 2 && model.entries.allSatisfy { model.choice($0.node) == .branch })
        #expect(model.name(model.entries[0]).isEmpty == false && BranchMergeModel.kindTitle(.changed) == "Changed on the branch")
        #expect(BranchMergeModel.kindTitle(.onlyA) == "Added on the branch" && BranchMergeModel.kindTitle(.onlyB) == "Only on main")
        // Use main on one object: it is excluded; Keep branch open travels.
        model.choose(.main, for: shared[1].opID)
        BranchMergeSheet.keepOpen(model).wrappedValue = true
        #expect(model.excluded == [shared[1].opID])
        PanelRendering.host(BranchMergeSheet(model: model), size: NSSize(width: 480, height: 420))
        // Main moved on: the review reopens over it, keeping the choices.
        merging.answers = [.failure(MergeFailure.stale), .success(MergeResult(firstParentSeq: 10, lastParentSeq: 21, droppedOps: 1))]
        mainState.value = branch
        #expect(await model.merge() == nil)
        #expect(model.reopened == 1 && model.phase == .reviewing && reads.value == 1 && model.choice(shared[1].opID) == .main)
        #expect(merging.requests.first?.seq == 7 && merging.requests.first?.keepOpen == true)
        PanelRendering.host(BranchMergeSheet(model: model), size: NSSize(width: 480, height: 420))
        var merged: [MergeResult] = []
        model.onMerged = { merged.append($0) }
        let result = try #require(await model.merge())
        #expect(merging.requests.last?.seq == 9 && merged == [result] && model.phase.isDone)
        #expect(BranchMergeModel.summary(result) == "Merged 12 changes into main. 1 no longer applied and were left out.")
        #expect(BranchMergeModel.summary(MergeResult(firstParentSeq: 3, lastParentSeq: 3, droppedOps: 0)) == "Merged 1 change into main.")
        #expect(BranchMergeModel.summary(MergeResult(firstParentSeq: 0, lastParentSeq: 0, droppedOps: 0)) == "Merged 0 changes into main.")
        PanelRendering.host(BranchMergeSheet(model: model), size: NSSize(width: 480, height: 420))
        // A failure says so; a main gone from this Mac cannot reopen.
        merging.answers = [.failure(CocoaError(.fileNoSuchFile))]
        #expect(await model.merge() == nil)
        guard case .failed = model.phase else { Issue.record("failed"); return }
        PanelRendering.host(BranchMergeSheet(model: model), size: NSSize(width: 480, height: 420))
        let gone = BranchMergeModel(branchID: "b1", branchName: "x", branch: branch, main: branch, mainSeq: 0, merging: merging) { nil }
        merging.answers = [.failure(MergeFailure.stale)]
        await gone.merge()
        #expect(gone.phase == .failed("Main is not on this Mac"))
        BranchMergeSheet.merging(gone)()
        BranchMergeSheet.choice(gone, shared[0].opID).wrappedValue = .main
        #expect(gone.choice(shared[0].opID) == .main)
        #expect(!BranchMergeModel.Phase.reviewing.isDone)
    }

    @Test func theCommandOpensTheReviewInABranchWindow() async throws {
        let parent = CollaborationWorld()
        defer { parent.close() }
        let merging = FakeBranchMerging()
        let features = parent.features
        let command = BranchMergeCommand.command(features: features, merging: { merging }, window: { parent.window })
        #expect(command.validation() == .disabled(BranchMergeCommand.notBranch))
        #expect(await BranchMergeCommand.present(features: features, merging: { merging }, window: { parent.window }).value == nil)
        #expect(BranchMergeCommand.command(features: features, merging: { nil }, window: { nil }).validation() == .disabled(BranchMergeCommand.notBranch))
        // A branch window: the review over main as this Mac holds it.
        let world = CollaborationWorld(document: .memory(id: "branch-doc", title: "Branch"),
                                       branches: [BranchInfo(id: "branch-doc", parentID: "parent-doc", name: "Try colours", forkServerSeq: 3)])
        defer { world.close() }
        await world.ui.branches.load()
        let branchFeatures = world.features
        let branchCommand = BranchMergeCommand.command(features: branchFeatures, merging: { merging }, window: { world.window })
        let main = DocumentHandle.memory(title: "Main")
        branchFeatures.state = { id in id == "parent-doc" ? main.state : nil }
        #expect(branchCommand.validation() == .enabled)
        #expect(BranchMergeCommand.command(features: branchFeatures, merging: { nil }, window: { world.window }).validation() == .disabled(BranchMergeCommand.offline))
        let model = try #require(await BranchMergeCommand.present(features: branchFeatures, merging: { merging }, window: { world.window }).value)
        #expect(model.branchName == "Try colours" && world.sheets.value.count == 1)
        _ = await model.merge()
        model.onClose()
        // Main not here: nothing.
        branchFeatures.state = { _ in nil }
        #expect(await BranchMergeCommand.present(features: branchFeatures, merging: { merging }, window: { world.window }).value == nil)
        let registry = CommandRegistry()
        registry.replace(branchCommand)
        _ = registry.perform(CollaborationFeatures.ID.mergeBranch)
        #expect(await BranchMergeCommand.parentSeq("x") == 0)
    }
}
