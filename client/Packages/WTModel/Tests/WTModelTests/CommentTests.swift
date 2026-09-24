import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// COLLAB-026: the comment thread model and its commands (comments.adoc, "Client").
@Suite struct CommentTests {
    static let posted = Date(timeIntervalSince1970: 2_000_000)

    /// A replica with one triangle path; returns the path's id.
    static func withObject(_ replica: inout Replica) throws -> OpID {
        let change = try replica.perform(PathFixture.closed([(0, 0), (100, 0), (100, 100)]))
        return change!.createdObjects[0]
    }

    static func thread(_ replica: inout Replica, on anchor: OpID? = nil, at point: Point = Point(x: 10, y: 20),
                       text: String = "Make this red", author: String = "priya") throws -> OpID {
        let command = CreateThread(at: point, on: anchor, author: author, body: CommentBody(text), postedAt: posted, in: replica.state)
        return try replica.perform(command)!.createdNodes[0]
    }

    static func model(_ replica: Replica, members: Set<String>? = nil, unread: [OpID: Set<OpID>] = [:]) -> CommentThreadModel {
        CommentThreadModel(replica.state, members: members, unread: unread)
    }

    // MARK: Pins

    @Test func anchoredPinFollowsTheObjectAndWritesNothingUnderComments() throws {
        var replica = Replica(0xA)
        let object = try Self.withObject(&replica)
        let thread = try Self.thread(&replica, on: object, at: Point(x: 50, y: 10))
        let created = try #require(Self.model(replica)[thread])
        #expect(created.anchoring == .object(object))
        #expect(created.pin == Point(x: 50, y: 10))
        #expect(created.anchorName == "Path")
        let collection = StateHash.of(replica.state.store, node: thread)
        let transforms: [WTGeometry.AffineTransform] = [
            .identity.concatenating(WTGeometry.AffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 30, ty: 40)),
            WTGeometry.AffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0),
            WTGeometry.AffineTransform(a: 2, b: 0, c: 0, d: 3, tx: 5, ty: 5),
        ]
        var pins: [Point] = []
        for transform in transforms {
            try replica.perform(SetTransforms([(object, transform)]))
            let pin = try #require(Self.model(replica)[thread]?.pin)
            #expect(pin == transform.apply(Point(x: 50, y: 10)))
            pins.append(pin)
            #expect(StateHash.of(replica.state.store, node: thread) == collection)
        }
        #expect(Set(pins.map { "\($0.x),\($0.y)" }).count == 3)
    }

    @Test func pointPinsStayPutAndGroupByPage() throws {
        var replica = Replica(0xA)
        let onPage = try Self.thread(&replica, at: Point(x: 10, y: 10))
        let pasteboard = try Self.thread(&replica, at: Point(x: -5_000, y: -5_000))
        let model = Self.model(replica)
        #expect(model[onPage]?.anchoring == .point)
        #expect(model[onPage]?.pin == Point(x: 10, y: 10))
        #expect(model[onPage]?.anchorName == nil)
        let page = PageList(replica.state).pages[0].id
        #expect(model.byPage[page]?.map(\.id) == [onPage])
        #expect(model.byPage[nil]?.map(\.id) == [pasteboard])
        #expect(model.threads.map(\.number) == [1, 2])
        #expect(model.pins().count == 2)
    }

    @Test func deletedAnchorHidesThePinAndRestoringBringsItBack() throws {
        var replica = Replica(0xA)
        let object = try Self.withObject(&replica)
        try replica.perform(SetNameOrNote([object], .name, "Logo mark"))
        let thread = try Self.thread(&replica, on: object)
        try replica.perform(DeleteNodes([object]))
        let hidden = try #require(Self.model(replica)[thread])
        #expect(hidden.pin == nil)
        #expect(hidden.anchoring == .deleted(object))
        #expect(hidden.anchorName == "Logo mark (deleted)")
        #expect(Self.model(replica).pins().isEmpty)
        replica.undo()
        #expect(Self.model(replica)[thread]?.pin == Point(x: 10, y: 20))
    }

    @Test func compactedAnchorFallsBackToTheFallbackPoint() throws {
        var replica = Replica(0xA)
        let thread = try Self.thread(&replica, at: Point(x: 7, y: 8))
        let unknown = OpID(counter: 99, replica: 0xDEAD)
        try replica.perform(MovePin(thread, to: Point(x: 70, y: 80), on: unknown, in: replica.state))
        let fallen = try #require(Self.model(replica)[thread])
        #expect(fallen.anchoring == .compacted(unknown))
        #expect(fallen.pin == Point(x: 70, y: 80))
        #expect(fallen.anchorName == nil)
    }

    @Test func movePinReanchorsAndDetaches() throws {
        var replica = Replica(0xA)
        let object = try Self.withObject(&replica)
        try replica.perform(SetTransforms([(object, WTGeometry.AffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 100, ty: 0))]))
        let thread = try Self.thread(&replica)
        let move = MovePin(thread, to: Point(x: 150, y: 20), on: object, in: replica.state)
        #expect(move.label == "Move Pin")
        #expect(move.point == Point(x: 50, y: 20))
        try replica.perform(move)
        #expect(Self.model(replica)[thread]?.anchoring == .object(object))
        #expect(Self.model(replica)[thread]?.pin == Point(x: 150, y: 20))
        let page = PageList(replica.state).pages[0].id
        try replica.perform(MovePin(thread, to: Point(x: 1, y: 2), page: page, in: replica.state))
        #expect(Self.model(replica)[thread]?.anchoring == .point)
        #expect(Self.model(replica)[thread]?.page == page)
    }

    // MARK: Commands

    @Test func threadAndReplyLabelsAndContent() throws {
        var replica = Replica(0xA)
        let object = try Self.withObject(&replica)
        try replica.perform(SetNameOrNote([object], .name, "Logo mark"))
        let create = CreateThread(at: Point(x: 1, y: 1), on: object, author: "tom", body: CommentBody("Is this the logo?"),
                                  postedAt: Self.posted, in: replica.state)
        #expect(create.label == "Comment on Logo mark")
        #expect(CreateThread(at: .init(x: 0, y: 0), author: "tom", body: CommentBody("x"), in: replica.state).label == "Comment")
        let thread = try replica.perform(create)!.createdNodes[0]
        let body = CommentBody("@Priya check the kerning", mentions: [.init(range: 0..<6, account: "priya")])
        let reply = Reply(to: thread, author: "tom", body: body, postedAt: Self.posted.addingTimeInterval(60), recipient: "Tom")
        #expect(reply.label == "Reply to Tom")
        #expect(Reply(to: thread, author: "a", body: body).label == "Reply")
        try replica.perform(reply)
        let read = try #require(Self.model(replica)[thread])
        #expect(read.comments.count == 2)
        #expect(read.opener.text == "Is this the logo?")
        #expect(read.opener.author == "tom")
        #expect(read.opener.wallTimeMs == 2_000_000_000)
        #expect(!read.opener.isEdited)
        #expect(read.replies.first?.mentions == ["priya"])
        #expect(read.replies.first?.mentionTags == [.init(range: 0..<6, account: "priya")])
        #expect(read.replies.first?.body == body)
        #expect(read.lastActivityMs == 2_000_060_000)
        #expect(read.firstLine == "Is this the logo?")
        #expect(read.participants == ["tom"])
        #expect(read.mentions("priya"))
        #expect(!read.mentions("sam"))
        #expect(read.matches("KERNING") && read.matches("") && !read.matches("colour"))
    }

    @Test func teamMentionsAndMembersFilter() throws {
        var replica = Replica(0xA)
        let body = CommentBody("@Marketing and @Sam", mentions: [.init(range: 0..<10, account: "team:mkt"), .init(range: 15..<19, account: "sam")])
        let thread = try replica.perform(CreateThread(at: .init(x: 0, y: 0), author: "tom", body: body, in: replica.state))!.createdNodes[0]
        let all = try #require(Self.model(replica)[thread])
        #expect(all.opener.mentions == ["sam", "team:mkt"])
        #expect(all.mentions("jo", teams: ["mkt"]))
        #expect(!all.mentions("jo", teams: ["sales"]))
        // Sam lost access: the tag is drawn as plain text; the team tag stays.
        let filtered = try #require(Self.model(replica, members: ["tom"])[thread])
        #expect(filtered.opener.mentionTags == [.init(range: 0..<10, account: "team:mkt")])
    }

    @Test func editRewritesTextTagsAndMentions() throws {
        var replica = Replica(0xA)
        let first = CommentBody("Hi @Priya and @Sam", mentions: [.init(range: 3..<9, account: "priya"), .init(range: 14..<18, account: "sam")])
        let thread = try replica.perform(CreateThread(at: .init(x: 0, y: 0), author: "tom", body: first, in: replica.state))!.createdNodes[0]
        let comment = try #require(Self.model(replica)[thread]).opener.id
        let second = CommentBody("Hello @Priya and @Jo!", mentions: [.init(range: 6..<12, account: "priya"), .init(range: 17..<20, account: "jo")])
        let edit = EditComment(thread: thread, comment: comment, body: second, editedAt: Self.posted.addingTimeInterval(5))
        #expect(edit.label == "Edit Comment")
        try replica.perform(edit)
        let read = try #require(Self.model(replica)[thread]).opener
        #expect(read.text == "Hello @Priya and @Jo!")
        #expect(read.mentions == ["jo", "priya"])
        #expect(read.mentionTags == second.mentions)
        #expect(read.isEdited && read.editedWallTimeMs == 2_000_005_000)
        // The same body again writes nothing.
        #expect(try replica.perform(EditComment(thread: thread, comment: comment, body: second)) == nil)
        // Removing every tag clears them and empties the set.
        try replica.perform(EditComment(thread: thread, comment: comment, body: CommentBody("Hello Priya and Jo!")))
        let plain = try #require(Self.model(replica)[thread]).opener
        #expect(plain.mentions.isEmpty && plain.mentionTags.isEmpty && plain.text == "Hello Priya and Jo!")
    }

    @Test func longBodiesAreChunked() throws {
        var replica = Replica(0xA)
        let text = String(repeating: "abcdefghij", count: 2_000)
        let change = try replica.perform(CreateThread(at: .init(x: 0, y: 0), author: "tom", body: CommentBody(text), in: replica.state))!
        #expect(change.ops.filter { if case .textInsert = $0.op { return true } else { return false } }.count == 3)
        #expect(Self.model(replica).threads[0].opener.text == text)
    }

    @Test func deletingRepliesOpenersAndThreads() throws {
        var replica = Replica(0xA)
        let thread = try Self.thread(&replica)
        try replica.perform(Reply(to: thread, author: "tom", body: CommentBody("Done")))
        let ids = try #require(Self.model(replica)[thread]).comments.map(\.id)
        let deleteReply = DeleteComment(thread: thread, comment: ids[1], in: replica.state)
        #expect(deleteReply.label == "Delete Comment")
        try replica.perform(Reply(to: thread, author: "sam", body: CommentBody("Also")))
        try replica.perform(deleteReply)
        #expect(Self.model(replica)[thread]?.comments.count == 2)
        // The opener with a live reply stays as "Comment deleted".
        let deleteOpener = DeleteComment(thread: thread, comment: ids[0], in: replica.state)
        #expect(deleteOpener.label == "Delete Comment")
        try replica.perform(deleteOpener)
        let kept = try #require(Self.model(replica)[thread])
        #expect(kept.openerDeleted && kept.firstLine == "")
        #expect(kept.participants == ["sam"])
        // A thread whose opener has no replies goes with it.
        let lonely = try Self.thread(&replica, text: "Alone")
        let opener = try #require(Self.model(replica)[lonely]).opener.id
        let command = DeleteComment(thread: lonely, comment: opener, in: replica.state)
        #expect(command.label == "Delete Thread")
        try replica.perform(command)
        #expect(Self.model(replica)[lonely] == nil)
        #expect(replica.state.store.deleted(lonely)?.current.value == true)
        // The owner's Delete Thread removes a thread with replies.
        let owner = DeleteThread(thread)
        #expect(owner.label == "Delete Thread")
        try replica.perform(owner)
        #expect(Self.model(replica).threads.isEmpty)
    }

    @Test func resolvingAndReopening() throws {
        var replica = Replica(0xA)
        _ = try Self.thread(&replica)
        let thread = try Self.thread(&replica)
        let resolve = SetResolved(thread, resolved: true, in: replica.state)
        #expect(resolve.label == "Resolve thread 2")
        try replica.perform(resolve)
        #expect(Self.model(replica)[thread]?.resolved == true)
        #expect(Self.model(replica).pins().count == 1)
        #expect(Self.model(replica).pins(showResolved: true).count == 2)
        #expect(try replica.perform(SetResolved(thread, resolved: true, in: replica.state)) == nil)
        // Replying does not reopen.
        try replica.perform(Reply(to: thread, author: "sam", body: CommentBody("ok")))
        #expect(Self.model(replica)[thread]?.resolved == true)
        let reopen = SetResolved(thread, resolved: false, in: replica.state)
        #expect(reopen.label == "Reopen thread 2")
        try replica.perform(reopen)
        #expect(Self.model(replica)[thread]?.resolved == false)
    }

    @Test func reactionsToggleAndValidate() throws {
        var replica = Replica(0xA)
        let thread = try Self.thread(&replica)
        let comment = try #require(Self.model(replica)[thread]).opener.id
        let add = React(thread: thread, comment: comment, account: "sam", emoji: "👍", in: replica.state)
        #expect(add.label == "React")
        try replica.perform(add)
        try replica.perform(React(thread: thread, comment: comment, account: "jo", emoji: "👍", adding: true, in: replica.state))
        try replica.perform(React(thread: thread, comment: comment, account: "jo", emoji: "🎉", in: replica.state))
        // Adding again writes nothing.
        #expect(try replica.perform(React(thread: thread, comment: comment, account: "jo", emoji: "🎉", adding: true, in: replica.state)) == nil)
        var entry = try #require(Self.model(replica)[thread]).opener
        #expect(entry.reactionCounts.map(\.emoji) == ["👍", "🎉"])
        #expect(entry.reactionCounts[0].accounts == ["jo", "sam"])
        let remove = React(thread: thread, comment: comment, account: "sam", emoji: "👍", in: replica.state)
        #expect(remove.label == "Remove Reaction")
        try replica.perform(remove)
        entry = try #require(Self.model(replica)[thread]).opener
        #expect(entry.reactions.count == 2)
        // A member outside the six, or of someone without access, is not drawn.
        try replica.perform(OpsCommand("odd", ops: [Ops.setAdd(thread, CommentFields.reactions(comment),
                                                              values: CommentFields.commentValues { $0.reactions = ["sam:🦄", "nocolon"] })]))
        #expect(try #require(Self.model(replica)[thread]).opener.reactions.count == 2)
        #expect(try #require(Self.model(replica, members: ["sam"])[thread]).opener.reactions.isEmpty)
        #expect(throws: CommentError.invalidReaction("🦄")) {
            try replica.perform(React(thread: thread, comment: comment, account: "sam", emoji: "🦄", adding: true, in: replica.state))
        }
        #expect(throws: CommentError.noAuthor) {
            try replica.perform(React(thread: thread, comment: comment, account: "", emoji: "👍", in: replica.state))
        }
        #expect(CommentReactions.parse(":👍") == nil)
    }

    @Test func refusals() throws {
        var replica = Replica(0xA)
        let object = try Self.withObject(&replica)
        let thread = try Self.thread(&replica)
        #expect(throws: CommentError.emptyBody) {
            try replica.perform(CreateThread(at: .init(x: 0, y: 0), author: "tom", body: CommentBody("  \n"), in: replica.state))
        }
        #expect(throws: CommentError.noAuthor) {
            try replica.perform(CreateThread(at: .init(x: 0, y: 0), author: "", body: CommentBody("x"), in: replica.state))
        }
        #expect(throws: CommentError.noAuthor) {
            try replica.perform(Reply(to: thread, author: "", body: CommentBody("x")))
        }
        for mention in [CommentBody.Mention(range: 0..<9, account: "a"), .init(range: 1..<1, account: "a"), .init(range: 0..<1, account: "")] {
            #expect(throws: CommentError.self) {
                try replica.perform(Reply(to: thread, author: "tom", body: CommentBody("abc", mentions: [mention])))
            }
        }
        #expect(throws: CommentError.invalidMention("b")) {
            try replica.perform(Reply(to: thread, author: "tom", body: CommentBody("abcd", mentions: [.init(range: 0..<2, account: "a"),
                                                                                                         .init(range: 1..<3, account: "b")])))
        }
        #expect(throws: CommentError.notAThread(object)) {
            try replica.perform(Reply(to: object, author: "tom", body: CommentBody("x")))
        }
        let stranger = OpID(counter: 1, replica: 77)
        #expect(throws: CommentError.unknownComment(stranger)) {
            try replica.perform(EditComment(thread: thread, comment: stranger, body: CommentBody("x")))
        }
        #expect(throws: CommentError.notAThread(object)) {
            try replica.perform(SetResolved(object, resolved: true, in: replica.state))
        }
    }

    @Test func unreadOverlayAndActivityOrder() throws {
        var replica = Replica(0xA)
        let older = try Self.thread(&replica)
        let newer = try replica.perform(CreateThread(at: .init(x: 0, y: 0), author: "tom", body: CommentBody("later"),
                                                     postedAt: Self.posted.addingTimeInterval(100), in: replica.state))!.createdNodes[0]
        try replica.perform(Reply(to: older, author: "sam", body: CommentBody("bump"), postedAt: Self.posted.addingTimeInterval(200)))
        let replyID = try #require(Self.model(replica)[older]).comments[1].id
        let model = Self.model(replica, unread: [older: [replyID]])
        #expect(model.byActivity.map(\.id) == [older, newer])
        #expect(model[older]?.unreadCount == 1)
        #expect(model.unreadTotal == 1)
    }

    @Test func normalizationShowsADeletedThreadWithALiveReply() throws {
        var replica = Replica(0xA)
        let thread = try Self.thread(&replica)
        try replica.perform(Reply(to: thread, author: "sam", body: CommentBody("still here")))
        try replica.perform(OpsCommand("delete", ops: [Ops.setDeleted(thread)]))
        let shown = try #require(Self.model(replica)[thread])
        #expect(shown.comments.count == 2)
        // A thread whose every comment is gone is not shown.
        let empty = try replica.perform(OpsCommand("bare", ops: [Ops.create(parent: CommentFields.collection, position: [0xF0],
                                                                           props: CommentFields.values { $0.resolved = false })]))!.createdNodes[0]
        #expect(Self.model(replica)[empty] == nil)
    }

    // MARK: Edge cases

    /// A thread written by hand: anchored to `anchor` (maybe unknown), at `point`, no fallback, with
    /// one comment element and no text.
    static func bareThread(_ replica: inout Replica, anchor: OpID? = nil, page: OpID? = nil) throws -> (OpID, OpID) {
        let props = CommentFields.values { thread in
            if let anchor { thread.anchor = CommentFields.ref(anchor) }
            thread.point = CommentFields.point(Point(x: 3, y: 4))
            if let page { thread.page = CommentFields.ref(page) }
        }
        let create = Ops.create(parent: CommentFields.collection, position: [0xF0], props: props)
        var builder = ChangeBuilder(replica: replica.core.replica, startCounter: replica.state.clock.peek)
        let thread = builder.append(create)
        let comment = builder.append(Ops.elementInsert(thread, CommentFields.comments, positions: [[0x80]],
                                                       values: CommentFields.commentValues { $0.authorAccountID = "tom" }))
        try replica.perform(OpsCommand("bare", ops: builder.ops))
        return (thread, comment)
    }

    @Test func pathsAndMentionedAccounts() {
        let id = OpID(counter: 3, replica: 4)
        #expect(CommentFields.comment(id) == CommentFields.comments.element(id))
        #expect(CommentFields.author(id) == CommentFields.comments.element(id).child(2))
        #expect(CommentFields.wallTime(id) == CommentFields.comments.element(id).child(4))
        let body = CommentBody("@a @a @b", mentions: [.init(range: 0..<2, account: "a"), .init(range: 3..<5, account: "a"), .init(range: 6..<8, account: "b")])
        #expect(body.mentionedAccounts == ["a", "b"])
    }

    @Test func handWrittenThreadsReadSafely() throws {
        var replica = Replica(0xA)
        let unknown = OpID(counter: 50, replica: 0xBEEF)
        let (thread, comment) = try Self.bareThread(&replica, anchor: unknown, page: unknown)
        let read = try #require(Self.model(replica)[thread])
        // No fallback point: the pin falls back to `point`; an unknown page reads as none.
        #expect(read.anchoring == .compacted(unknown) && read.pin == Point(x: 3, y: 4))
        #expect(read.page == PageList(replica.state).page(containing: Point(x: 3, y: 4))?.id)
        #expect(read.opener.text == "")
        // A comment without text can still be edited.
        try replica.perform(EditComment(thread: thread, comment: comment, body: CommentBody("now")))
        #expect(Self.model(replica)[thread]?.opener.text == "now")
        // A deleted thread whose opener stands and has no replies is not shown.
        try replica.perform(OpsCommand("delete", ops: [Ops.setDeleted(thread)]))
        #expect(Self.model(replica)[thread] == nil)
    }

    @Test func aTagSplitByOtherFormattingReadsAsOne() throws {
        var replica = Replica(0xA)
        let body = CommentBody("@Priya hi", mentions: [.init(range: 0..<6, account: "priya")])
        let thread = try replica.perform(CreateThread(at: .init(x: 0, y: 0), author: "tom", body: body, in: replica.state))!.createdNodes[0]
        let comment = try #require(Self.model(replica)[thread]).opener.id
        let chars = replica.state.text(thread, CommentFields.body(comment))!.liveChars
        var mark = Wiretuner_Doc_V1_TextMark()
        mark.node = thread.proto
        mark.text = CommentFields.body(comment).proto
        mark.start.char = chars[2].elementID
        mark.start.before = true
        mark.end.char = chars[3].elementID
        mark.value.size = 20
        var op = Wiretuner_Doc_V1_Op()
        op.textMark = mark
        try replica.perform(OpsCommand("size", ops: [op]))
        #expect(try #require(Self.model(replica)[thread]).opener.mentionTags == body.mentions)
    }

    @Test func pinsOnGroupedAndDegenerateObjectsAndNames() throws {
        var replica = Replica(0xA)
        let object = try Self.withObject(&replica)
        let ellipse = try replica.perform(CreateShape(.ellipse, size: Size(width: 4, height: 4)))!.createdObjects[0]
        try replica.perform(GroupObjects([object, ellipse]))
        let page = PageList(replica.state).pages[0].id
        let thread = try replica.perform(CreateThread(at: Point(x: 10, y: 10), on: ellipse, page: page, author: "tom",
                                                      body: CommentBody("in a group"), in: replica.state))!.createdNodes[0]
        let read = try #require(Self.model(replica)[thread])
        #expect(read.anchorName == "Ellipse" && read.page == page && read.pin == Point(x: 10, y: 10))
        // An anchor whose transform cannot be inverted keeps the point as given.
        try replica.perform(SetTransforms([(object, WTGeometry.AffineTransform(a: 0, b: 0, c: 0, d: 0, tx: 1, ty: 1))]))
        #expect(CreateThread(at: Point(x: 7, y: 8), on: object, author: "tom", body: CommentBody("x"), in: replica.state).point == Point(x: 7, y: 8))
        #expect(MovePin(thread, to: Point(x: 7, y: 8), on: object, in: replica.state).point == Point(x: 7, y: 8))
        // A node of a kind without a name of its own reads as "Object".
        let other = try Self.thread(&replica)
        try replica.perform(MovePin(thread, to: Point(x: 1, y: 1), on: other, in: replica.state))
        #expect(Self.model(replica)[thread]?.anchorName == "Object")
    }
}
