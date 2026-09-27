import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTSync
@testable import WTTestSupport

/// COLLAB-034: comments under concurrency (comments.adoc, "Merge semantics", "Offline behavior",
/// "Server"), through the simulator.  Priya (an editor who opens most threads), Tom (an editor) and
/// Cy (a commenter) share a document owned by Olu.  Every scenario asserts hash convergence on all
/// clients, the exact Comments panel rows and unread counts each client shows -- the panel's model
/// over its own state, with the server's `GetUnread` as its unread overlay -- and the server's
/// notification rows.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(6))) struct CommentCaseScenarioTests {
    struct Room {
        let sim: Simulation
        let server: SimServer
        let priya: SimClient
        let tom: SimClient
        let cy: SimClient
        let shapes: [OpID]
        var everyone: [SimClient] { [priya, tom, cy] }
    }

    static let conditions = LinkConditions(latency: .milliseconds(30), jitter: .milliseconds(20))

    static func room(_ name: String, seed: UInt64) async throws -> Room {
        let sim = try await Simulation(name: name, seed: Simulation.seed(seed), scale: 0.005)
        let server = try #require(sim.server)
        let cyUser = SimUser(id: "u-cy", name: "Cy")
        try await sim.grant(.commenter, to: cyUser)
        let priya = try await sim.addClient("priya", user: SimUser(id: "u-priya", name: "Priya"), conditions: conditions)
        let tom = try await sim.addClient("tom", user: SimUser(id: "u-tom", name: "Tom"), conditions: conditions)
        let cy = try await sim.addClient("cy", user: cyUser, conditions: conditions)
        let shapes = try await Workload.createShapes(tom, count: 3)
        try await sim.settle()
        return Room(sim: sim, server: server, priya: priya, tom: tom, cy: cy, shapes: shapes)
    }

    static func open(_ client: SimClient, on anchor: OpID?, _ text: String, mentions: [CommentBody.Mention] = []) async throws -> OpID {
        let command = CreateThread(at: Point(x: 4, y: 4), on: anchor, author: client.user.id, body: CommentBody(text, mentions: mentions),
                                   postedAt: client.clock(), in: client.state)
        return try #require(await client.perform(command)?.createdNodes.first)
    }

    static func reply(_ client: SimClient, to thread: OpID, _ text: String) async throws -> OpID {
        let change = try #require(await client.perform(Reply(to: thread, author: client.user.id, body: CommentBody(text), postedAt: client.clock())))
        return OpID(counter: change.startCounter, replica: change.replica)
    }

    /// One Comments panel row as a person reads it: the pin number, what it is pinned to, whether
    /// it is resolved, each shown comment (author, text, deleted) and the unread badge.
    struct PanelRow: Hashable, CustomStringConvertible {
        var number: Int
        var anchor: String?
        var resolved: Bool
        var comments: [String]
        var unread: Int

        var description: String { "#\(number) \(anchor ?? "-") \(resolved ? "resolved" : "open") \(comments) unread \(unread)" }
    }

    /// The panel of `client`: its own state, unread from the server for its account.
    static func panel(_ client: SimClient, _ server: SimServer, _ document: String? = nil) async -> [PanelRow] {
        let unread = await server.unread(client.user.id, in: document ?? client.documentID)
        let overlay = Dictionary(uniqueKeysWithValues: unread.map { ($0.thread, Set($0.comments)) })
        return CommentThreadModel(client.state, unread: overlay).threads.map { thread in
            PanelRow(number: thread.number, anchor: thread.anchorName, resolved: thread.resolved,
                     comments: thread.comments.map { "\($0.author): \($0.text)\($0.deleted ? " (deleted)" : "")" }, unread: thread.unreadCount)
        }
    }

    /// Every client converged and shows `expected[client]` in its panel.
    static func expectPanels(_ room: Room, _ expected: [String: [PanelRow]]) async throws {
        try await room.sim.settle()
        try await room.sim.expectConverged()
        for client in room.everyone {
            let rows = await panel(client, room.server)
            #expect(rows == expected[client.name], "\(client.name)'s panel")
        }
    }

    /// The notification rows as (recipient, kind, author), in creation order.
    static func rows(_ server: SimServer, _ document: String) async -> [String] {
        await server.notifications(document).map { "\($0.account) \($0.kind.rawValue) from \($0.author)" }
    }

    // MARK: Concurrent edits

    /// Concurrent replies: Tom and Cy answer Priya's thread at once (Tom's link dropped meanwhile,
    /// so the replies cross); both are kept, in the same order everywhere.  Priya is told of both,
    /// the later replier of the earlier reply; each person's unread is the others' replies.
    @Test func concurrentReplies() async throws {
        let room = try await Self.room("comments-replies", seed: 3401)
        defer { Task { await room.sim.shutdown() } }
        let thread = try await Self.open(room.priya, on: room.shapes[0], "Is this the approved logo?")
        try await room.sim.settle()
        var replies: [String: OpID] = [:]
        _ = try await room.sim.offline(room.tom, hours: 0) {
            replies["tom"] = try await Self.reply(room.tom, to: thread, "Yes")
            replies["cy"] = try await Self.reply(room.cy, to: thread, "No, the older one")
            try await room.sim.settle([room.priya, room.cy])
        }
        try await room.sim.settle()
        let order = try #require(CommentThreadModel(room.priya.state)[thread]).replies.map(\.author)
        #expect(Set(order) == ["u-tom", "u-cy"])
        let text = ["u-tom": "u-tom: Yes", "u-cy": "u-cy: No, the older one"]
        let comments = ["u-priya: Is this the approved logo?"] + order.map { text[$0]! }
        func row(_ unread: Int) -> [PanelRow] { [PanelRow(number: 1, anchor: "Rectangle", resolved: false, comments: comments, unread: unread)] }
        try await Self.expectPanels(room, ["priya": row(2), "tom": row(2), "cy": row(2)])
        let log = await room.server.log(room.sim.documentID)
        let tomSeq = try #require(log.firstIndex { $0.change.label.hasPrefix("tom#") && $0.change.label.contains("Reply") })
        let cySeq = try #require(log.firstIndex { $0.change.label.hasPrefix("cy#") && $0.change.label.contains("Reply") })
        let (first, second) = tomSeq < cySeq ? ("u-tom", "u-cy") : ("u-cy", "u-tom")
        #expect(await Self.rows(room.server, room.sim.documentID).sorted() == [
            "u-priya reply from \(first)", "u-priya reply from \(second)", "\(first) reply from \(second)",
        ].sorted())
        #expect(Set(await room.server.notifications(room.sim.documentID).map(\.comment)) == Set(replies.values))
    }

    /// Resolve vs. reopen: Tom resolves Priya's thread while Priya, offline, resolves and reopens
    /// it.  `resolved` is one register: the greater op id stands everywhere, on the server's record
    /// too; Priya is told only of a resolve by someone else that flipped it.
    @Test func resolveVersusReopen() async throws {
        let room = try await Self.room("comments-resolve", seed: 3402)
        defer { Task { await room.sim.shutdown() } }
        let thread = try await Self.open(room.priya, on: nil, "Tighten the kerning")
        try await room.sim.settle()
        _ = try await room.sim.offline(room.priya, hours: 1) {
            await room.priya.perform(SetResolved(thread, resolved: true, in: room.priya.state))
            await room.priya.perform(SetResolved(thread, resolved: false, in: room.priya.state))
            await room.tom.perform(SetResolved(thread, resolved: true, in: room.tom.state))
            try await room.sim.settle([room.tom, room.cy])
        }
        try await room.sim.settle()
        let winner = try #require(room.priya.state.store.register(thread, CommentFields.resolved)?.op)
        let tomWon = winner.replica == (await room.tom.store.replica)
        let row = PanelRow(number: 1, anchor: nil, resolved: tomWon, comments: ["u-priya: Tighten the kerning"], unread: 0)
        try await Self.expectPanels(room, ["priya": [row], "tom": [PanelRow(number: 1, anchor: nil, resolved: tomWon, comments: row.comments, unread: 1)],
                                          "cy": [PanelRow(number: 1, anchor: nil, resolved: tomWon, comments: row.comments, unread: 1)]])
        #expect(await room.server.comments(room.sim.documentID).isResolved(thread) == tomWon)
        let notes = await room.server.notifications(room.sim.documentID)
        #expect(notes.allSatisfy { $0.account == "u-priya" && $0.kind == .resolved && $0.author == "u-tom" } && notes.count <= 1)
    }

    /// Edit vs. delete of one comment: Tom edits his reply while Olu, the owner, deletes it; it
    /// stays deleted (with the edited text inside it) everywhere, the panel drops it, and nobody
    /// counts it unread.
    @Test func editVersusDelete() async throws {
        let room = try await Self.room("comments-edit-delete", seed: 3403)
        defer { Task { await room.sim.shutdown() } }
        let olu = try await room.sim.addClient("olu", user: room.sim.owner, conditions: Self.conditions)
        let thread = try await Self.open(room.priya, on: room.shapes[1], "Which blue?")
        try await room.sim.settle()
        let reply = try await Self.reply(room.tom, to: thread, "Pantone 286")
        try await room.sim.settle()
        _ = try await room.sim.offline(room.tom, hours: 2) {
            await room.tom.perform(EditComment(thread: thread, comment: reply, body: CommentBody("Pantone 2945"), editedAt: room.tom.clock()))
            await olu.perform(DeleteComment(thread: thread, comment: reply, in: olu.state))
            try await room.sim.settle([room.priya, room.cy, olu])
        }
        try await room.sim.settle()
        let row = PanelRow(number: 1, anchor: "Rectangle", resolved: false, comments: ["u-priya: Which blue?"], unread: 0)
        let others = PanelRow(number: 1, anchor: "Rectangle", resolved: false, comments: row.comments, unread: 1)
        try await Self.expectPanels(room, ["priya": [row], "tom": [others], "cy": [others]])
        for client in room.everyone + [olu] {
            #expect(client.state.text(thread, CommentFields.body(reply))?.string == "Pantone 2945", "the edit is kept inside the deleted comment")
        }
        #expect(await room.server.comments(room.sim.documentID).isDeleted(reply))
        #expect(await Self.rows(room.server, room.sim.documentID) == ["u-priya reply from u-tom"])
    }

    /// Pin drag vs. pin drag: Priya drops her pin on one object while Tom drops it on another at
    /// once.  The four pin fields come from one person's drop on every client, never a mix.
    @Test func pinDragVersusPinDrag() async throws {
        let room = try await Self.room("comments-pin-drag", seed: 3404)
        defer { Task { await room.sim.shutdown() } }
        let thread = try await Self.open(room.priya, on: room.shapes[0], "Move me")
        try await room.sim.settle()
        _ = try await room.sim.offline(room.priya, hours: 0) {
            await room.priya.perform(MovePin(thread, to: Point(x: 40, y: 40), on: room.shapes[1], in: room.priya.state))
            await room.tom.perform(MovePin(thread, to: Point(x: 90, y: 10), on: nil, in: room.tom.state))
            try await room.sim.settle([room.tom, room.cy])
        }
        try await room.sim.settle()
        try await room.sim.expectConverged()
        let fields = [CommentFields.anchor, CommentFields.point, CommentFields.fallbackPoint, CommentFields.page]
        for client in room.everyone {
            let ops = Set(fields.compactMap { client.state.store.register(thread, $0)?.op })
            #expect(ops.count == 1, "\(client.name): one drop wrote every pin field")
        }
        let model = try #require(CommentThreadModel(room.tom.state)[thread])
        let priyaWon = try #require(room.tom.state.store.register(thread, CommentFields.anchor)?.op).replica == (await room.priya.store.replica)
        #expect(model.anchoring == (priyaWon ? .object(room.shapes[1]) : .point))
        let row = PanelRow(number: 1, anchor: priyaWon ? "Rectangle" : nil, resolved: false, comments: ["u-priya: Move me"], unread: 0)
        try await Self.expectPanels(room, ["priya": [row], "tom": [PanelRow(number: 1, anchor: row.anchor, resolved: false, comments: row.comments, unread: 1)],
                                          "cy": [PanelRow(number: 1, anchor: row.anchor, resolved: false, comments: row.comments, unread: 1)]])
        #expect(await room.server.notifications(room.sim.documentID).isEmpty)
    }

    /// A comment on an object another client deletes at the same moment, then restores: the pin
    /// disappears and the panel names the object "(deleted)" everywhere; *Undo* of the delete
    /// brings the object and its pin back with no write under `0:12`.
    @Test func commentOnAnObjectDeletedThenRestored() async throws {
        let room = try await Self.room("comments-delete-restore", seed: 3405)
        defer { Task { await room.sim.shutdown() } }
        var thread: OpID?
        _ = try await room.sim.offline(room.priya, hours: 0) {
            thread = try await Self.open(room.priya, on: room.shapes[2], "Too dark")
            await Workload.delete(room.tom, [room.shapes[2]])
            try await room.sim.settle([room.tom, room.cy])
        }
        let id = try #require(thread)
        let deleted = PanelRow(number: 1, anchor: "Rectangle (deleted)", resolved: false, comments: ["u-priya: Too dark"], unread: 0)
        func others(_ row: PanelRow) -> PanelRow { PanelRow(number: 1, anchor: row.anchor, resolved: false, comments: row.comments, unread: 1) }
        try await Self.expectPanels(room, ["priya": [deleted], "tom": [others(deleted)], "cy": [others(deleted)]])
        for client in room.everyone { #expect(CommentThreadModel(client.state)[id]?.pin == nil) }
        let before = await room.server.head(room.sim.documentID)
        _ = try await room.tom.document.undo()
        await room.tom.client.localChangesAvailable()
        let restored = PanelRow(number: 1, anchor: "Rectangle", resolved: false, comments: deleted.comments, unread: 0)
        try await Self.expectPanels(room, ["priya": [restored], "tom": [others(restored)], "cy": [others(restored)]])
        for client in room.everyone {
            let model = try #require(CommentThreadModel(client.state)[id])
            #expect(model.anchoring == .object(room.shapes[2]) && model.pin != nil)
        }
        let restore = await room.server.log(room.sim.documentID).dropFirst(Int(before))
        #expect(!restore.isEmpty && restore.allSatisfy { entry in entry.change.ops.allSatisfy { !CommentFields.onlyComments([$0], in: room.tom.state) } },
                "nothing written under 0:12")
    }

    // MARK: Offline, notifications and the digest

    /// Offline commenting with mentions: Priya, on a plane, mentions Tom and the design team (Cy,
    /// and Dee who cannot open the document).  Nothing is notified until she lands; then the rows
    /// are dated at landing, Tom's live session is told at once, and Cy -- away -- gets one digest
    /// mail ten minutes later with the opening line and the thread's link, never a second.  A
    /// re-mention within the day notifies nobody again.
    @Test func offlineMentionsAreDeliveredOnSync() async throws {
        let room = try await Self.room("comments-offline-mentions", seed: 3406)
        defer { Task { await room.sim.shutdown() } }
        await room.server.setTeam("design", members: ["u-cy", "u-dee"])
        await room.server.add(SimUser(id: "u-dee", name: "Dee"))
        await room.cy.stop()
        room.priya.goOffline()
        let text = "@Tom @design check the badge\nthanks"
        let thread = try await Self.open(room.priya, on: room.shapes[0], text, mentions: [
            CommentBody.Mention(range: 0..<4, account: "u-tom"), CommentBody.Mention(range: 5..<12, account: "team:design"),
        ])
        room.sim.advance(by: .seconds(5 * 3600))
        #expect(await room.server.notifications(room.sim.documentID).isEmpty, "nothing reaches the server offline")
        let landed = room.sim.clock.nowMs()
        room.priya.goOnline()
        try await room.sim.settle([room.priya, room.tom])
        try await room.sim.expectConverged([room.priya, room.tom])
        let notes = await room.server.notifications(room.sim.documentID)
        #expect(notes.map { "\($0.account) \($0.kind.rawValue)" } == ["u-tom mention", "u-cy mention"])
        #expect(notes.allSatisfy { $0.createdMs >= landed && $0.thread == thread && $0.author == "u-priya" })
        let deadline = ContinuousClock.now + .seconds(10)
        func told() -> Bool {
            room.tom.events.contains { event in
                if case .document(let frame) = event, case .comment(let comment)? = frame.event {
                    return comment.kind == .mention && OpID(comment.thread) == thread
                }
                return false
            }
        }
        while !told(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(told(), "Tom's live session hears of the mention")
        #expect(await room.server.runCommentDigest().isEmpty, "not yet ten minutes old")
        room.sim.advance(by: .seconds(11 * 60))
        let mails = await room.server.runCommentDigest()
        #expect(mails == [SimComments.Mail(account: "u-cy", document: room.sim.documentID, mentions: [
            SimComments.Mail.Mention(author: "Priya", openingLine: "@Tom @design check the badge",
                                     link: "wiretuner://doc/\(room.sim.documentID)/thread/\(thread.counter)-\(thread.replica)"),
        ])], "Tom is on the document; Dee cannot open it")
        let again = await room.server.runCommentDigest()
        let mailbox = await room.server.mailbox
        #expect(again.isEmpty && mailbox.count == 1, "never mailed twice")
        let opener = try #require(CommentThreadModel(room.priya.state)[thread]).opener.id
        await room.priya.perform(EditComment(thread: thread, comment: opener, body: CommentBody("@Tom check the badge", mentions: [
            CommentBody.Mention(range: 0..<4, account: "u-tom"),
        ]), editedAt: room.priya.clock()))
        try await room.sim.settle([room.priya, room.tom])
        #expect(await room.server.notifications(room.sim.documentID).count == 2, "a re-mention within the day is not notified again")
        await room.server.markRead("u-tom", in: room.sim.documentID, thread: thread, through: opener)
        #expect(await room.server.unread("u-tom", in: room.sim.documentID).isEmpty)
        #expect(await room.server.unread("u-cy", in: room.sim.documentID).map(\.mentionsMe) == [true])
    }

    // MARK: Roles

    /// The commenter role: Cy writes threads and replies (a commenter's changes sync), but resolving
    /// Priya's thread is refused with `ROLE_INSUFFICIENT` -- the change never reaches the log and
    /// his document stops sending; discarding it and reconnecting lets him comment again.  An
    /// artwork edit never leaves a commenter's store (`LocalStore` refuses it).
    @Test func commenterRoleRejection() async throws {
        let room = try await Self.room("comments-commenter", seed: 3407)
        defer { Task { await room.sim.shutdown() } }
        let own = try await Self.open(room.cy, on: nil, "Can I suggest a darker red?")
        try await room.sim.settle()
        let priyas = try await Self.open(room.priya, on: room.shapes[0], "Final copy?")
        try await room.sim.settle()
        _ = try await Self.reply(room.cy, to: priyas, "Looks final to me")
        await room.cy.perform(SetResolved(own, resolved: true, in: room.cy.state))
        try await room.sim.settle()
        try await room.sim.expectConverged()
        let isCommenter = await room.cy.client.isCommenter
        let cyState = await room.cy.syncState
        #expect(isCommenter && cyState == .readOnly(.role))
        let refusals = await room.server.stats.roleRefusals
        let refused = try #require(await room.cy.perform(SetResolved(priyas, resolved: true, in: room.cy.state)))
        try await room.cy.waitFor("refused") { $0 == .readOnly(.roleInsufficient) }
        let stats = await room.server.stats
        #expect(stats.roleRefusals == refusals + 1)
        #expect(await room.server.log(room.sim.documentID).allSatisfy { $0.change.label != refused.label })
        try await room.cy.client.discardUnsent()
        room.cy.noteDiscarded([refused.label])
        await room.cy.client.retry()
        try await room.cy.waitFor("commenting again") { $0 == .readOnly(.role) }
        try await room.sim.settle([room.cy])
        _ = try await Self.reply(room.cy, to: priyas, "Sorry, only Priya can resolve it")
        let rows = [
            PanelRow(number: 1, anchor: nil, resolved: true, comments: ["u-cy: Can I suggest a darker red?"], unread: 0),
            PanelRow(number: 2, anchor: "Rectangle", resolved: false,
                     comments: ["u-priya: Final copy?", "u-cy: Looks final to me", "u-cy: Sorry, only Priya can resolve it"], unread: 0),
        ]
        func unread(_ first: Int, _ second: Int) -> [PanelRow] {
            [PanelRow(number: 1, anchor: nil, resolved: true, comments: rows[0].comments, unread: first),
             PanelRow(number: 2, anchor: "Rectangle", resolved: false, comments: rows[1].comments, unread: second)]
        }
        try await Self.expectPanels(room, ["priya": unread(1, 2), "tom": unread(1, 3), "cy": unread(0, 1)])
        #expect(await Self.rows(room.server, room.sim.documentID) == ["u-priya reply from u-cy", "u-priya reply from u-cy"])
        // What the app's AccessController does for a commenter: comments only.
        await room.cy.store.setReadOnly(true, commentsAllowed: true)
        await #expect(throws: LocalStore.Failure.readOnly) {
            _ = try await room.cy.store.perform(SetNameOrNote([room.shapes[0]], .name, "Cy's"), recording: DocumentCore.Recording(limit: 1, now: Date()))
        }
        await room.cy.store.setReadOnly(false)
    }

    // MARK: Branches

    /// Branch comments merged into the parent: on a branch, Tom opens a thread and replies to one
    /// that was on main before the fork, and Cy (a commenter on main, so on the branch) replies to
    /// it too; the merge replays them into main as threads and replies.  Afterwards Cy can reply
    /// on main to the thread from the branch, and main's unread counts and notifications include
    /// the merged comments.
    @Test func branchCommentsMergeIntoTheParent() async throws {
        let room = try await Self.room("comments-branch", seed: 3408)
        defer { Task { await room.sim.shutdown() } }
        let before = try await Self.open(room.priya, on: room.shapes[0], "Before the fork")
        try await room.sim.settle()
        let branch = "doc-branch-1"
        let token = await room.server.issueToken(for: room.priya.user.id, lifetime: .seconds(3600))
        _ = try await room.server.createBranch(.with {
            $0.parentDocumentID = room.sim.documentID
            $0.branchDocumentID = branch
            $0.name = "Explorations"
        }, token: token, device: room.priya.device)
        let bea = try await room.sim.addClient("tom-branch", user: SimUser(id: "u-tom", name: "Tom"), device: "tom-branch", document: branch)
        let cyOnBranch = try await room.sim.addClient("cy-branch", user: room.cy.user, device: "cy-branch", document: branch)
        try await room.sim.settle([bea, cyOnBranch])
        let fresh = try await Self.open(bea, on: room.shapes[1], "On the branch")
        _ = try await Self.reply(bea, to: before, "Branch reply")
        _ = try await Self.reply(cyOnBranch, to: before, "Commenter on the branch")
        try await room.sim.settle([bea, cyOnBranch])
        try await room.sim.expectConverged([bea, cyOnBranch], document: branch)
        #expect(!cyOnBranch.reached { $0 == .readOnly(.roleInsufficient) }, "a commenter may reply to a thread from before the fork")
        try await room.server.mergeBranch(branch, token: token, device: room.priya.device)
        try await room.sim.settle(room.everyone)
        try await room.sim.expectConverged(room.everyone)
        _ = try await Self.reply(room.cy, to: fresh, "Commenter on main, after the merge")
        try await room.sim.settle(room.everyone)
        try await room.sim.expectConverged(room.everyone)
        #expect(!room.cy.reached { $0 == .readOnly(.roleInsufficient) }, "a commenter may reply to a merged thread")
        for client in room.everyone {
            let threads = CommentThreadModel(client.state)
            #expect(Set(threads[before]?.replies.map(\.text) ?? []) == ["Branch reply", "Commenter on the branch"])
            #expect(threads[fresh]?.comments.map(\.text) == ["On the branch", "Commenter on main, after the merge"])
        }
        let unread = await room.server.unread("u-priya", in: room.sim.documentID)
        #expect(unread.map(\.thread) == [before, fresh] && unread.map(\.comments.count) == [2, 2], "merged comments count as unread on main")
        #expect(await Self.rows(room.server, room.sim.documentID).last == "u-tom reply from u-cy", "the merged thread's opener is told on main")
    }
}
