import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto

/// COLLAB-026's merge cases (comments.adoc, "Merge semantics") through two in-process replicas.
@Suite struct CommentMergeTests {
    /// Two replicas sharing one thread by A.
    static func pair() throws -> (Pair, OpID) {
        var pair = Pair()
        let thread = try CommentTests.thread(&pair.a)
        pair.sync()
        return (pair, thread)
    }

    static func converged(_ pair: Pair) -> CommentThreadModel {
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let a = CommentThreadModel(pair.a.state)
        #expect(a.threads == CommentThreadModel(pair.b.state).threads)
        return a
    }

    static func later(_ a: Wiretuner_Doc_V1_Change, _ b: Wiretuner_Doc_V1_Change) -> Bool {
        OpID(counter: a.startCounter, replica: a.replica) > OpID(counter: b.startCounter, replica: b.replica)
    }

    @Test func concurrentRepliesBothLandInOneOrder() throws {
        var (pair, thread) = try Self.pair()
        try pair.a.perform(Reply(to: thread, author: "tom", body: CommentBody("from A")))
        try pair.b.perform(Reply(to: thread, author: "sam", body: CommentBody("from B")))
        pair.sync()
        let texts = try #require(Self.converged(pair)[thread]).replies.map(\.text)
        #expect(Set(texts) == ["from A", "from B"])
    }

    @Test func concurrentResolveAndReopenConvergeOnTheGreaterOpID() throws {
        var (pair, thread) = try Self.pair()
        try pair.a.perform(SetResolved(thread, resolved: true, in: pair.a.state))
        pair.sync()
        let reopen = try pair.a.perform(SetResolved(thread, resolved: false, in: pair.a.state))!
        let resolve = try pair.b.perform(OpsCommand("Resolve", ops: [Ops.set(thread, [CommentFields.resolved],
                                                                           values: CommentFields.values { $0.resolved = true })]))!
        pair.sync()
        #expect(Self.converged(pair)[thread]?.resolved == Self.later(resolve, reopen))
    }

    @Test func twoPinDragsEndWithOneWholeDrop() throws {
        var (pair, thread) = try Self.pair()
        let object = try CommentTests.withObject(&pair.b)
        pair.sync()
        let a = try pair.a.perform(MovePin(thread, to: Point(x: 500, y: 500), in: pair.a.state))!
        let b = try pair.b.perform(MovePin(thread, to: Point(x: 60, y: 30), on: object, in: pair.b.state))!
        pair.sync()
        let merged = try #require(Self.converged(pair)[thread])
        if Self.later(a, b) {
            #expect(merged.anchoring == .point && merged.pin == Point(x: 500, y: 500))
        } else {
            #expect(merged.anchoring == .object(object) && merged.pin == Point(x: 60, y: 30))
        }
    }

    @Test func editVersusDeleteStaysDeletedWithTheEdit() throws {
        var (pair, thread) = try Self.pair()
        try pair.a.perform(Reply(to: thread, author: "tom", body: CommentBody("typo")))
        pair.sync()
        let reply = try #require(CommentThreadModel(pair.a.state)[thread]).replies.first!.id
        try pair.a.perform(EditComment(thread: thread, comment: reply, body: CommentBody("typo fixed")))
        try pair.b.perform(DeleteComment(thread: thread, comment: reply, in: pair.b.state))
        pair.sync()
        #expect(try #require(Self.converged(pair)[thread]).replies.isEmpty)
        #expect(pair.a.state.text(thread, CommentFields.body(reply))?.string == "typo fixed")
    }

    @Test func aReplyConcurrentWithDeletingTheOpenerKeepsTheThread() throws {
        var (pair, thread) = try Self.pair()
        let opener = try #require(CommentThreadModel(pair.a.state)[thread]).opener.id
        try pair.a.perform(DeleteComment(thread: thread, comment: opener, in: pair.a.state))
        try pair.b.perform(Reply(to: thread, author: "sam", body: CommentBody("wait")))
        pair.sync()
        let merged = try #require(Self.converged(pair)[thread])
        #expect(merged.openerDeleted && merged.replies.map(\.text) == ["wait"])
    }

    @Test func concurrentAddAndRemoveOfOneReactionKeepsIt() throws {
        var (pair, thread) = try Self.pair()
        let opener = try #require(CommentThreadModel(pair.a.state)[thread]).opener.id
        try pair.a.perform(React(thread: thread, comment: opener, account: "sam", emoji: "👀", in: pair.a.state))
        pair.sync()
        try pair.a.perform(React(thread: thread, comment: opener, account: "sam", emoji: "👀", adding: false, in: pair.a.state))
        try pair.b.perform(OpsCommand("again", ops: [Ops.setAdd(thread, CommentFields.reactions(opener),
                                                               values: CommentFields.commentValues { $0.reactions = ["sam:👀"] })]))
        pair.sync()
        #expect(try #require(Self.converged(pair)[thread]).opener.reactions.map(\.emoji) == ["👀"])
    }

    @Test func concurrentMentionEditsBothApply() throws {
        var (pair, thread) = try Self.pair()
        let opener = try #require(CommentThreadModel(pair.a.state)[thread]).opener.id
        try pair.a.perform(OpsCommand("add jo", ops: [Ops.setAdd(thread, CommentFields.mentions(opener),
                                                                values: CommentFields.commentValues { $0.mentions = ["jo"] })]))
        try pair.b.perform(OpsCommand("add sam", ops: [Ops.setAdd(thread, CommentFields.mentions(opener),
                                                                 values: CommentFields.commentValues { $0.mentions = ["sam"] })]))
        pair.sync()
        #expect(try #require(Self.converged(pair)[thread]).opener.mentions == ["jo", "sam"])
    }

    @Test func undoOfAReplyRemovesItAndLeavesOtherPeoplesText() throws {
        var (pair, thread) = try Self.pair()
        try pair.a.perform(Reply(to: thread, author: "tom", body: CommentBody("mine")))
        pair.sync()
        #expect(pair.a.undo() != nil)
        pair.sync()
        #expect(try #require(Self.converged(pair)[thread]).replies.isEmpty)
        // Undo after someone else typed into the reply: the others' characters stay, the rest undoes.
        try pair.a.perform(Reply(to: thread, author: "tom", body: CommentBody("again")))
        pair.sync()
        let reply = try #require(CommentThreadModel(pair.b.state)[thread]).replies.first!.id
        let path = CommentFields.body(reply)
        let end = pair.b.state.text(thread, path)!.liveChars.last!
        try pair.b.perform(OpsCommand("type", ops: [Ops.textInsert(thread, path, "!", left: end)]))
        pair.sync()
        #expect(pair.a.undo() != nil)
        pair.sync()
        #expect(try #require(Self.converged(pair)[thread]).replies.isEmpty)
        #expect(pair.a.state.text(thread, path)?.string == "!")
    }
}
