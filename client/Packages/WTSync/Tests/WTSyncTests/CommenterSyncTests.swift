import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
@testable import WTSync

/// COLLAB-034's finding: a commenter could not comment.  `SyncClient` sent nothing while the role
/// was viewer or commenter and `AccessController` made the whole store read-only, so a thread written
/// by a commenter stayed in the outbox forever.  A commenter's document is now read-only for
/// everything but comments, whose changes are sent.
@Suite(.timeLimit(.minutes(2))) struct CommenterSyncTests {
    static func thread(_ text: String, in state: EngineState) -> CreateThread {
        CreateThread(at: Point(x: 1, y: 1), author: "carol", body: CommentBody(text), postedAt: Date(timeIntervalSince1970: 1), in: state)
    }

    @Test func aCommentersThreadsAreSentAndOtherEditsStayOut() async throws {
        let harness = try await Harness()
        let copies = FakeCopies()
        let controller = AccessController(store: harness.store, client: harness.client, sync: BulkSink(), copies: copies, tokens: harness.tokens)
        await harness.server.update { $0.role = .commenter }
        _ = try await harness.store.perform(Self.thread("Written before the session", in: harness.store.read { $0 }), recording: Fixture.recording())
        await controller.start()
        await harness.client.start()
        try await harness.waitFor(.readOnly(.role))
        #expect(await harness.client.isCommenter)
        try await eventually("the waiting thread is sent, not frozen") { await harness.server.pushes.count == 1 }
        let status = await controller.status
        #expect(status.unsent == 0 && !status.editable)
        let allows = await harness.store.allowsComments
        let readOnly = await harness.store.isReadOnly
        #expect(allows && readOnly)
        // A reply, and undoing it, are comments; an artwork edit is refused before the outbox.
        let state = await harness.store.read { $0 }
        let thread = try #require(CommentThreadModel(state).threads.first?.id)
        _ = try await harness.store.perform(Reply(to: thread, author: "carol", body: CommentBody("And a reply")), recording: Fixture.recording())
        await #expect(throws: LocalStore.Failure.readOnly) { try await harness.store.perform(createLayer("no"), recording: Fixture.recording()) }
        _ = try await harness.store.undo(recording: Fixture.recording())
        await harness.client.localChangesAvailable()
        try await harness.expectConverged()
        #expect(CommentThreadModel(await harness.store.read { $0 }).threads.first?.replies.isEmpty == true)
        // Raised to editor: everything is editable again and the commenter flag clears.
        await harness.server.update { $0.role = .editor }
        await harness.server.send(.with { $0.event.roleChanged.role = .editor })
        try await harness.waitFor(.saved)
        #expect(!(await harness.client.isCommenter))
        try await eventually("editable") { await controller.status.editable }
        #expect(!(await harness.store.allowsComments))
        try await harness.stop()
    }

    @Test func aCommenterWithUnsentArtworkChangesIsFrozen() async throws {
        let harness = try await Harness()
        let controller = AccessController(store: harness.store, client: harness.client, sync: BulkSink(), copies: FakeCopies(), tokens: harness.tokens)
        try await harness.edit(2)
        await harness.server.update { $0.role = .commenter }
        await controller.start()
        await harness.client.start()
        try await eventually("frozen") { await controller.status.unsent == 2 }
        #expect(await harness.server.pushes.isEmpty)
        try await harness.stop()
    }

    @Test func undoOfAnArtworkChangeIsRefusedToACommenter() async throws {
        let harness = try await Harness()
        try await harness.edit(1)
        await harness.store.setReadOnly(true, commentsAllowed: true)
        await #expect(throws: LocalStore.Failure.readOnly) { try await harness.store.undo(recording: Fixture.recording()) }
        await harness.store.setReadOnly(true)
        await #expect(throws: LocalStore.Failure.readOnly) {
            try await harness.store.perform(Self.thread("viewer", in: EngineState()), recording: Fixture.recording())
        }
        try await harness.stop()
    }

    @Test func onlyCommentsReadsEveryOpKind() throws {
        var core = DocumentCore(state: EngineState(), replica: 0xC)
        let created = try #require(try core.perform(Self.thread("Hello", in: core.state), recording: Fixture.recording())?.change)
        let thread = created.createdNodes[0]
        let state = core.state
        let opener = try #require(CommentThreadModel(state)[thread]?.opener.id)
        #expect(CommentFields.onlyComments(created.ops, in: state))
        let comment = CommentFields.comment(opener)
        let others: [Wiretuner_Doc_V1_Op] = [
            Ops.move(thread, parent: CommentFields.collection, position: [0x90]), Ops.setDeleted(thread),
            Ops.elementMove(thread, comment, position: [0x90]), Ops.elementDelete(thread, [comment]),
            Ops.textDelete(thread, CommentFields.body(opener), first: opener, count: 1),
            Ops.setRemove(thread, CommentFields.reactions(opener), values: Wiretuner_Doc_V1_NodeProps()), {
                var op = Wiretuner_Doc_V1_Op()
                op.noop = Wiretuner_Doc_V1_Noop()
                return op
            }(),
        ]
        #expect(CommentFields.onlyComments(others, in: state))
        #expect(!CommentFields.onlyComments([Fixture.createLayer("L")], in: state))
        #expect(!CommentFields.onlyComments([Ops.move(thread, parent: OpID.wellKnown(4), position: [0x90])], in: state))
        #expect(!CommentFields.onlyComments([Ops.setDeleted(OpID.wellKnown(4))], in: state))
        #expect(!CommentFields.onlyComments([Wiretuner_Doc_V1_Op()], in: state))
        var threadElsewhere = created.ops[0]
        threadElsewhere.create.parent = OpID.wellKnown(4).proto
        #expect(!CommentFields.onlyComments([threadElsewhere], in: state))
    }
}
