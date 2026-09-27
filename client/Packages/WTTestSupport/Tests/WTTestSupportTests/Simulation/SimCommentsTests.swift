import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTSync
@testable import WTTestSupport

/// `SimComments`, the simulator's copy of the server's record of comments (COLLAB-030, COLLAB-031,
/// COLLAB-034): the parse, the role rule's branches, the record, unread, and the digest.
@Suite struct SimCommentsTests {
    static let recording = DocumentCore.Recording(limit: 10, now: Date(timeIntervalSince1970: 1))

    /// One replica's document core and the changes it made.
    struct Writer {
        var core: DocumentCore
        var account: String

        init(_ account: String, replica: UInt64, state: EngineState = EngineState()) {
            core = DocumentCore(state: state, replica: replica)
            self.account = account
        }

        mutating func make(_ command: any Command) throws -> Wiretuner_Doc_V1_Change {
            try #require(try core.perform(command, recording: SimCommentsTests.recording)?.outbox)
        }
    }

    static func open(_ writer: inout Writer, _ text: String, mentions: [CommentBody.Mention] = []) throws -> (Wiretuner_Doc_V1_Change, OpID, OpID) {
        let change = try writer.make(CreateThread(at: Point(x: 1, y: 1), author: writer.account, body: CommentBody(text, mentions: mentions),
                                                   postedAt: Date(timeIntervalSince1970: 1), in: writer.core.state))
        let thread = change.createdNodes[0]
        let opener = try #require(CommentThreadModel(writer.core.state)[thread]?.opener.id)
        return (change, thread, opener)
    }

    @Test func theRuleRefusesWhatTheServerRefuses() throws {
        var record = SimComments()
        var alice = Writer("alice", replica: 1)
        let (created, thread, opener) = try Self.open(&alice, "Hello")
        #expect(record.refusal(SimComments.parse(created), caller: "alice", role: .commenter) == nil)
        _ = record.index(SimComments.parse(created), author: "alice", nowMs: 0, canOpen: { _ in true })
        var carol = Writer("carol", replica: 2, state: alice.core.state)
        let refused: [(any Command, String)] = [
            (SetResolved(thread, resolved: true, in: carol.core.state), "only the thread's opener or an editor may change it"),
            (MovePin(thread, to: Point(x: 5, y: 5), in: carol.core.state), "only the thread's opener or an editor may change it"),
            (EditComment(thread: thread, comment: opener, body: CommentBody("Mine now")), "only its author may change a comment"),
            (DeleteThread(thread), "only the thread's opener, an editor or the owner may do that to a thread"),
            (React(thread: thread, comment: opener, account: "alice", emoji: "👍", in: carol.core.state),
             "a reaction may only be added or removed by its own account"),
            (CreateLayer(name: "Art"), "the commenter role may only change comments"),
        ]
        for (command, why) in refused {
            var trial = carol
            let change = try trial.make(command)
            let refusal = record.refusal(SimComments.parse(change), caller: "carol", role: .commenter)
            #expect(refusal != nil && (command is DeleteThread || refusal == why), "\(command.label): \(refusal ?? "allowed")")
        }
        // Allowed: a reply, a reaction of her own; an editor resolves; the owner deletes anyone's comment.
        let reply = try carol.make(Reply(to: thread, author: "carol", body: CommentBody("Hi")))
        #expect(record.refusal(SimComments.parse(reply), caller: "carol", role: .commenter) == nil)
        let react = try carol.make(React(thread: thread, comment: opener, account: "carol", emoji: "🎉", in: carol.core.state))
        #expect(record.refusal(SimComments.parse(react), caller: "carol", role: .commenter) == nil)
        var bob = Writer("bob", replica: 3, state: alice.core.state)
        let resolve = try bob.make(SetResolved(thread, resolved: true, in: bob.core.state))
        #expect(record.refusal(SimComments.parse(resolve), caller: "bob", role: .editor) == nil)
        let delete = try bob.make(DeleteComment(thread: thread, comment: opener, in: bob.core.state))
        #expect(record.refusal(SimComments.parse(delete), caller: "bob", role: .editor) != nil)
        #expect(record.refusal(SimComments.parse(delete), caller: "bob", role: .owner) == nil)
        // A reply naming someone else as its author, and a thread outside 0:12.
        var forged = reply
        forged.ops[0].elementInsert.values.commentThread.comments[0].authorAccountID = "alice"
        #expect(record.refusal(SimComments.parse(forged), caller: "carol", role: .commenter) == "a new comment's author must be the caller")
        var misplaced = created
        misplaced.ops[0].create.parent = OpID.wellKnown(4).proto
        #expect(record.refusal(SimComments.parse(misplaced), caller: "carol", role: .commenter) == "a thread must be created under the comments collection")
        var move = Wiretuner_Doc_V1_Change()
        move.replica = 2
        move.startCounter = 900
        move.ops = [Ops.move(thread, parent: CommentFields.collection, position: [0x90])]
        #expect(record.refusal(SimComments.parse(move), caller: "carol", role: .commenter) != nil)
        #expect(record.refusal(SimComments.parse(move), caller: "alice", role: .commenter) == nil)
    }

    @Test func theRecordNotifiesAndReadsAsTheServerDoes() throws {
        var record = SimComments()
        var alice = Writer("alice", replica: 1)
        let (created, thread, opener) = try Self.open(&alice, "Look @Bob\nsecond line", mentions: [CommentBody.Mention(range: 5..<9, account: "bob")])
        let open = { (account: String) in account != "mallory" }
        let first = record.index(SimComments.parse(created), author: "alice", nowMs: 1_000, canOpen: open)
        #expect(first.map(\.kind) == [.mention] && first[0].account == "bob")
        #expect(record.index(SimComments.parse(created), author: "alice", nowMs: 2_000, canOpen: open).isEmpty, "a retry notifies nobody")
        var bob = Writer("bob", replica: 2, state: alice.core.state)
        let reply = try bob.make(Reply(to: thread, author: "bob", body: CommentBody("Seen")))
        #expect(record.index(SimComments.parse(reply), author: "bob", nowMs: 3_000, canOpen: open).map(\.kind) == [.reply])
        let resolve = try bob.make(SetResolved(thread, resolved: true, in: bob.core.state))
        #expect(record.index(SimComments.parse(resolve), author: "bob", nowMs: 4_000, canOpen: open).map(\.kind) == [.resolved])
        #expect(record.isResolved(thread) && record.author(of: opener) == "alice" && record.openers[thread] == "alice")
        let delete = try bob.make(DeleteComment(thread: thread, comment: OpID(counter: reply.startCounter, replica: 2), in: bob.core.state))
        _ = record.index(SimComments.parse(delete), author: "bob", nowMs: 5_000, canOpen: open, notify: false)
        #expect(record.isDeleted(OpID(counter: reply.startCounter, replica: 2)))
        #expect(record.unread(for: "bob").map(\.comments) == [[opener]] && record.unread(for: "bob")[0].mentionsMe)
        #expect(record.unreadTotal(for: "alice") == 0 && record.unreadTotal(for: "bob") == 1)
        #expect(record.index(SimComments.parse(resolve), author: "bob", nowMs: 4_500, canOpen: open).isEmpty, "an older resolve is no news")
        #expect(!record.isResolved(OpID(counter: 77, replica: 7)))
        record.markRead("bob", thread: thread, through: opener, nowMs: 6_000)
        record.markRead("bob", thread: thread, through: .zero, nowMs: 6_000)
        #expect(record.unread(for: "bob").isEmpty && record.notifications.first { $0.account == "bob" }?.seenMs == 6_000)
        // The digest: only unseen, unmailed mentions older than the delay, by account.
        #expect(record.digest(document: "d", nowMs: 700_000, live: { _ in false }, names: { $0 }).isEmpty, "bob saw his mention")
        var carol = Writer("carol", replica: 3, state: bob.core.state)
        let mention = try carol.make(Reply(to: thread, author: "carol", body: CommentBody("@Dee @team", mentions: [
            CommentBody.Mention(range: 0..<4, account: "dee"), CommentBody.Mention(range: 5..<10, account: "team:t"),
        ])))
        let notes = record.index(SimComments.parse(mention), author: "carol", nowMs: 10_000, canOpen: open, teams: ["t": ["erin", "mallory", "carol"]])
        #expect(Set(notes.filter { $0.kind == .mention }.map(\.account)) == ["dee", "erin"])
        #expect(record.digest(document: "d", nowMs: 20_000, live: { _ in false }, names: { $0 }).isEmpty, "not ten minutes old")
        let mails = record.digest(document: "d", nowMs: 700_000, live: { $0 == "erin" }, mailsOff: [], names: { $0.uppercased() })
        #expect(mails.map(\.account) == ["dee"] && mails[0].mentions[0].author == "CAROL" && mails[0].mentions[0].openingLine == "Look @Bob")
        #expect(record.digest(document: "d", nowMs: 700_000, live: { _ in false }, mailsOff: ["erin"], names: { $0 }).isEmpty)
        #expect(record.digest(document: "d", nowMs: 8 * 86_400_000, live: { _ in false }, names: { $0 }).isEmpty, "a week old")
    }

    @Test func foreignOpsAndUnknownThreadsConcernNothing() throws {
        var record = SimComments()
        var writer = Writer("zed", replica: 9)
        let layer = try writer.make(CreateLayer(name: "Art"))
        #expect(SimComments.parse(layer).allSatisfy { $0 == .foreign })
        #expect(record.refusal(SimComments.parse(layer), caller: "zed", role: .editor) == nil)
        #expect(record.index(SimComments.parse(layer), author: "zed", nowMs: 0, canOpen: { _ in true }).isEmpty)
        // A comment-shaped op on a node that is no known thread: an editor's passes, a commenter's does not.
        var stray = Wiretuner_Doc_V1_Change()
        stray.replica = 9
        stray.startCounter = 50
        stray.ops = [Ops.set(OpID(counter: 3, replica: 3), [CommentFields.resolved], values: Wiretuner_Doc_V1_NodeProps()),
                     Ops.setDeleted(OpID(counter: 3, replica: 3))]
        #expect(record.refusal(SimComments.parse(stray), caller: "zed", role: .editor) == nil)
        #expect(record.refusal(SimComments.parse(stray), caller: "zed", role: .commenter) == "the commenter role may only change comments")
        #expect(record.index(SimComments.parse(stray), author: "zed", nowMs: 0, canOpen: { _ in true }).isEmpty)
    }

    @Test func unusualPathsAndEmptyOpenersParse() throws {
        let thread = OpID(counter: 5, replica: 1)
        let element = OpID(counter: 6, replica: 1)
        func path(_ segments: [Wiretuner_Doc_V1_PathSegment]) -> Wiretuner_Doc_V1_FieldPath { .with { $0.segments = segments } }
        func field(_ number: UInt32) -> Wiretuner_Doc_V1_PathSegment { .with { $0.field = number } }
        let elementSegment = Wiretuner_Doc_V1_PathSegment.with { $0.element = .with { $0.counter = element.counter; $0.replica = element.replica } }
        var set = Wiretuner_Doc_V1_SetFields()
        set.node = thread.proto
        set.paths = [path([field(210)]), path([field(210), field(0)]), path([field(210), field(7), field(3)]),
                     path([field(210), field(7), elementSegment])]
        var change = Wiretuner_Doc_V1_Change()
        change.replica = 1
        change.startCounter = 20
        change.ops = [.with { $0.set = set }, Ops.elementDelete(thread, [CommentFields.comment(element)])]
        let ops = SimComments.parse(change)
        #expect(ops.count == 5)
        #expect(ops[0] == .resolve(target: thread, resolved: false, op: OpID(counter: 20, replica: 1)) && ops[1] == .foreign && ops[2] == .foreign)
        if case .elementWrite(_, let written, _, _, let required, let deleted, _) = ops[3] { #expect(written == element && required && deleted == false) }
        if case .elementWrite(_, _, let ownerMay, _, _, let deleted, _) = ops[4] { #expect(ownerMay && deleted == true) }
        // An author written by someone else, a team nobody knows, and a thread whose opener has no text.
        var record = SimComments()
        var dee = Writer("dee", replica: 4)
        var (created, id, opener) = try SimCommentsTests.open(&dee, "x")
        created.ops.removeAll { if case .textInsert? = $0.op { true } else { false } }
        _ = record.index(SimComments.parse(created), author: "dee", nowMs: 0, canOpen: { _ in true })
        var author = Wiretuner_Doc_V1_Change()
        author.replica = 5
        author.startCounter = 90
        author.ops = [Ops.set(id, [CommentFields.author(opener)], values: .with { $0.commentThread.comments = [.with { $0.authorAccountID = "eve" }] })]
        #expect(record.refusal(SimComments.parse(author), caller: "eve", role: .commenter) == "only its author may change a comment")
        #expect(record.refusal(SimComments.parse(author), caller: "fay", role: .editor) == "a comment's author must be the caller")
        var mention = Wiretuner_Doc_V1_Change()
        mention.replica = 4
        mention.startCounter = 95
        mention.ops = [Ops.setAdd(id, CommentFields.mentions(opener), values: .with { $0.commentThread.comments = [.with { $0.mentions = ["team:ghost", "gus"] }] })]
        #expect(record.index(SimComments.parse(mention), author: "dee", nowMs: 0, canOpen: { _ in true }).map(\.account) == ["gus"])
        let mails = record.digest(document: "d", nowMs: 3_600_000, live: { _ in false }, names: { $0 })
        #expect(mails.first?.mentions.first?.openingLine == "")
    }
    /// `SimServer.mergeBranch`'s refusals: a document that is not a branch, and a caller who is not
    /// an editor on the parent.
    @Test func mergeBranchRefusals() async throws {
        let (server, alice, bob) = await SimServerTests.server()
        _ = try await server.createBranch(.with {
            $0.parentDocumentID = SimServerTests.doc
            $0.branchDocumentID = "B1"
            $0.name = "Branch"
        }, token: bob, device: SimServerTests.d2)
        func code(_ body: () async throws -> Void) async -> Int? {
            do { try await body(); return nil } catch let error as SyncCallError { return error.code } catch { return -1 }
        }
        #expect(await code { try await server.mergeBranch(SimServerTests.doc, token: alice, device: SimServerTests.d1) } == SyncCallError.notFound)
        await server.setRole(.viewer, for: SimServerTests.bob.id, on: SimServerTests.doc)
        #expect(await code { try await server.mergeBranch("B1", token: bob, device: SimServerTests.d2) } == SyncCallError.permissionDenied)
        #expect(try await server.mergeBranch("B1", token: alice, device: SimServerTests.d1) == nil, "nothing to replay")
    }
}
