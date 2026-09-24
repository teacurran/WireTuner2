import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// COLLAB-017: branch stores and offline branch creation (branches.adoc, "Offline-created branch").
@Suite(.timeLimit(.minutes(2))) struct BranchStoreTests {
    /// A parent store with two remote changes and `unsent` local ones (with undo steps).
    static func parent(_ scratch: Scratch, unsent: Int = 5) async throws -> LocalStore {
        let store = try await LocalStore.open(documentID: "parent", at: scratch.url("parent"), options: options())
        try await store.receive(remoteChange(seq: 1), serverSeq: 1)
        try await store.receive(remoteChange(seq: 2), serverSeq: 2)
        for index in 0..<unsent {
            _ = try await store.perform(createLayer("L\(index)"), recording: Fixture.recording())
        }
        return store
    }

    @Test func keepingChangesOnABranchWritesAStoreHoldingThem() async throws {
        let scratch = Scratch()
        let parent = try await Self.parent(scratch)
        let root = scratch.directory.appending(component: "branches")
        let entry = try await BranchStores.keepChangesOnBranch(parent: parent, name: "Priya's offline edits", branchID: "branch-1", root: root)
        #expect(entry.documentID == "branch-1")
        #expect(entry.meta == LocalStore.BranchMeta(parentDocumentID: "parent", name: "Priya's offline edits", forkServerSeq: 2,
                                                    onServer: false, parentReplica: 42, movedThroughSeq: 5))
        let branch = try await LocalStore.open(documentID: "branch-1", at: entry.url, options: options())
        let branchHash = await branch.read { $0.stateHash }
        #expect(branchHash == (await parent.read { $0.stateHash }))
        #expect(try await branch.outbox() == (try await parent.outbox()))
        let (replica, next, applied) = (await branch.replica, await branch.nextSeq, await branch.lastServerSeq)
        #expect(replica == 42 && next == 6 && applied == 2)
        #expect(await branch.summary().undo.undoCount == 5)
        #expect(try await branch.branchMeta() == entry.meta)
        #expect(try await parent.branchMeta() == nil)
        #expect(try BranchStores.branches(of: "parent", in: root).map(\.documentID) == ["branch-1"])
        #expect(try BranchStores.branches(of: "other", in: root).isEmpty)
        #expect(try BranchStores.pendingCreations(in: root).map(\.documentID) == ["branch-1"])
        // Exporting again (a retry after a crash) answers the branch already written.
        try await branch.close()
        let again = try await BranchStores.keepChangesOnBranch(parent: parent, name: "x", branchID: "branch-1", root: root)
        #expect(again.meta == entry.meta)
        // A store of another document at the path is refused.
        await #expect(throws: LocalStore.Failure.wrongDocument("parent")) {
            try await parent.exportBranch(documentID: "branch-2", name: "x", to: scratch.url("parent"))
        }
        try await parent.close()
        await #expect(throws: LocalStore.Failure.closed) { try await parent.exportBranch(documentID: "b", name: "x", to: scratch.url("b")) }
        await #expect(throws: LocalStore.Failure.closed) { try await parent.branchMeta() }
    }

    @Test func anInterruptedMoveCompletesOnTheNextOpen() async throws {
        let scratch = Scratch()
        let parent = try await Self.parent(scratch)
        let root = scratch.directory.appending(component: "branches")
        _ = try await BranchStores.keepChangesOnBranch(parent: parent, name: "b", branchID: "branch-1", root: root)
        // The app died before the parent reverted: the next open finishes it.
        #expect(try await BranchStores.completeMoves(parent: parent, in: root))
        #expect(try await parent.outboxCount() == 0)
        #expect(try await !BranchStores.completeMoves(parent: parent, in: root))
        // A directory without a store and a store that is not a branch are passed over.
        try FileManager.default.createDirectory(at: root.appending(component: "empty"), withIntermediateDirectories: true)
        let plain = try await LocalStore.open(documentID: "plain", at: root.appending(components: "plain", "store.sqlite"), options: options())
        try await plain.close()
        #expect(try BranchStores.branches(in: root).map(\.documentID) == ["branch-1"])
        #expect(try BranchStores.branches(in: scratch.directory.appending(component: "missing")).isEmpty)
        #expect(BranchStores.read(scratch.directory.appending(component: "nothing.sqlite")) == nil)
        #expect(try BranchStores.defaultRoot().lastPathComponent == "Documents")
    }

    @Test func theCreatorSendsTheFirstChangesAndMarksTheBranchOnServer() async throws {
        let scratch = Scratch()
        let parent = try await Self.parent(scratch, unsent: 3)
        let root = scratch.directory.appending(component: "branches")
        let entry = try await BranchStores.keepChangesOnBranch(parent: parent, name: "", branchID: "branch-1", root: root)
        let branch = try await LocalStore.open(documentID: "branch-1", at: entry.url, options: options())
        let copies = FakeCopies()
        let creator = BranchCreator(transport: copies, tokens: FakeTokens())
        #expect(try await creator.ensureOnServer(branch))
        let request = try #require(copies.branches.withLock { $0.first })
        #expect(request.parentDocumentID == "parent" && request.branchDocumentID == "branch-1" && request.name == "Branch")
        #expect(request.forkServerSeq == 2 && request.initialChanges.map(\.seq) == [1, 2, 3])
        #expect(try await branch.outboxCount() == 0)
        #expect(try await branch.branchMeta()?.onServer == true)
        #expect(try await !creator.ensureOnServer(branch))
        #expect(try await !creator.ensureOnServer(parent))
        #expect(copies.branches.withLock { $0.count } == 1)
        #expect(try BranchStores.pendingCreations(in: root).isEmpty)
        try await branch.close()
        try await parent.close()
    }

    @Test func aReplicaConflictTakesTheRotationPath() async throws {
        let scratch = Scratch()
        let parent = try await Self.parent(scratch, unsent: 2)
        let root = scratch.directory.appending(component: "branches")
        let entry = try await BranchStores.keepChangesOnBranch(parent: parent, name: "b", branchID: "branch-1", root: root)
        let branch = try await LocalStore.open(documentID: "branch-1", at: entry.url, options: options(replicas: Replicas(from: 900)))
        let copies = FakeCopies()
        copies.failures.withLock { $0 = [SyncCallError(code: SyncCallError.failedPrecondition, reason: .replicaConflict)] }
        #expect(try await BranchCreator(transport: copies, tokens: FakeTokens()).ensureOnServer(branch))
        #expect(copies.branches.withLock { $0.map(\.initialChanges.count) } == [0])
        #expect(try await branch.pendingSalvageCount() == 2)
        #expect(await branch.replica == 900)
        #expect(try await branch.branchMeta()?.onServer == true)
        try await branch.close()
        try await parent.close()
    }

    @Test func offlineTheBranchStaysNotYetOnTheServer() async throws {
        let scratch = Scratch()
        let parent = try await Self.parent(scratch, unsent: 1)
        let root = scratch.directory.appending(component: "branches")
        let entry = try await BranchStores.keepChangesOnBranch(parent: parent, name: "b", branchID: "branch-1", root: root)
        let branch = try await LocalStore.open(documentID: "branch-1", at: entry.url, options: options())
        let copies = FakeCopies()
        copies.failures.withLock { $0 = [SyncCallError(code: SyncCallError.unavailable)] }
        await #expect(throws: SyncCallError.self) { try await BranchCreator(transport: copies, tokens: FakeTokens()).ensureOnServer(branch) }
        #expect(try await branch.branchMeta()?.onServer == false)
        // Editable meanwhile.
        _ = try await branch.perform(createLayer("more"), recording: Fixture.recording())
        #expect(try await branch.outboxCount() == 2)
        try await branch.setBranchMeta(LocalStore.BranchMeta(parentDocumentID: "parent", name: "renamed", forkServerSeq: 2, onServer: true))
        #expect(try await branch.branchMeta()?.name == "renamed")
        try await branch.close()
        try await parent.close()
    }

    @Test func documentIdentifiersAreVersion7() {
        let id = DocumentIdentifier.make(milliseconds: 0x0123_4567_89AB, random: [0xFF, 1, 0xFF, 2, 3, 4, 5, 6, 7, 8])
        #expect(id == "01234567-89ab-7f01-bf02-030405060708")
        #expect(DocumentIdentifier.make(random: [1]).count == 36)
        #expect(DocumentIdentifier.make() != DocumentIdentifier.make())
    }
}
