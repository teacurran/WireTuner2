import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
@testable import WireTuner

/// One person's app in a comment scenario: a window on the shared document with the comments
/// features installed, signed in as that person with that role.
@MainActor
final class CommentClient {
    let name: String
    let account: String
    let environment = TestEnvironment()
    let features: CommentsFeatures
    let window: DocumentWindowController
    /// Changes made here and not yet relayed (the outbox).
    var outbox: [Wiretuner_Doc_V1_Change] = []
    private var token: DocumentHandle.ObservationToken?

    init(name: String, account: String, role: DocumentRole, documentID: String, base: EngineState, roster: [CommentMember]) {
        self.name = name
        self.account = account
        features = CommentsFeatures(preferences: environment.preferences)
        features.account = { (account, name) }
        features.members = { _ in roster }
        features.role = { _ in role }
        features.pasteboard = NSPasteboard(name: NSPasteboard.Name("CommentClient-\(UUID().uuidString)"))
        let core = DocumentCore(state: base, replica: UInt64.random(in: 1...UInt64.max))
        let document = DocumentHandle(id: documentID, title: "Catalogue", model: WTModel.Document(memory: core))
        window = DocumentWindowController(document: document, environment: environment.document)
        window.confirm = { _, _ in true }
        let window = window
        features.install(commands: environment.commands, panels: environment.panels, tools: environment.tools) { window }
        token = document.observe { [weak self] change in
            if change.summary.origin != .remote, let applied = change.change, !applied.ops.isEmpty { self?.outbox.append(applied) }
        }
    }

    var document: DocumentHandle { window.documentHandle }
    var comments: WindowComments { features.attach(window) }

    /// The Comments panel's rows (open and resolved), newest activity first: number, object, state,
    /// comments (author: text) and unread badge.
    var rows: [String] {
        comments.refresh(force: true)
        var filter = CommentFilter()
        filter.state = .all
        return filter.apply(comments.model, account: account, members: comments.members).map { thread in
            let texts = thread.comments.map { $0.deleted ? "(deleted)" : "\($0.author): \($0.text)" }.joined(separator: " | ")
            return "#\(thread.number) \(thread.anchorName ?? "point") \(thread.resolved ? "resolved" : "open") [\(texts)] unread \(thread.unreadCount)"
        }
    }

    func close() {
        if let token { document.stopObserving(token) }
        features.detach(window)
        window.close()
    }
}

/// Priya (owner), Tom (editor) and Cy (commenter) on one document, each in their own window, with
/// their changes relayed as the server sequences them.
@MainActor
struct CommentScenario {
    static let roster = [CommentMember(id: "acct-priya", name: "Priya"), CommentMember(id: "acct-tom", name: "Tom"), CommentMember(id: "acct-cy", name: "Cy")]

    let priya: CommentClient
    let tom: CommentClient
    let cy: CommentClient
    /// The object threads are anchored to.
    let box: OpID

    var clients: [CommentClient] { [priya, tom, cy] }

    static func make() async -> CommentScenario {
        let seed = DocumentHandle.memory(title: "Seed")
        let ids = await seed.addRectangles([Rect(x: 40, y: 40, width: 120, height: 80)])
        let base = seed.state
        let id = UUID().uuidString
        let priya = CommentClient(name: "Priya", account: "acct-priya", role: .owner, documentID: id, base: base, roster: roster)
        let tom = CommentClient(name: "Tom", account: "acct-tom", role: .editor, documentID: id, base: base, roster: roster)
        let cy = CommentClient(name: "Cy", account: "acct-cy", role: .commenter, documentID: id, base: base, roster: roster)
        let scenario = CommentScenario(priya: priya, tom: tom, cy: cy, box: ids[0].opID)
        for client in scenario.clients {
            for _ in 0..<50 where client.comments.members.isEmpty { await Task.yield() }
        }
        return scenario
    }

    func close() {
        for client in clients { client.close() }
    }

    /// Every outbox, in the order given, delivered to the others (the server's order).
    func sync(_ order: [CommentClient]? = nil) async {
        for sender in order ?? clients {
            let changes = sender.outbox
            sender.outbox = []
            for change in changes {
                for receiver in clients where receiver !== sender {
                    _ = await receiver.document.receive(change).value
                }
            }
        }
        for client in clients {
            await client.document.settle()
            client.comments.refresh(force: true)
        }
    }

    /// Every client holds the same state (hash) and lists the same threads.
    func expectConvergence(sourceLocation: SourceLocation = #_sourceLocation) {
        let hashes = Set(clients.map { $0.document.state.stateHash })
        #expect(hashes.count == 1, "state hashes differ", sourceLocation: sourceLocation)
        let lists = clients.map { client in client.rows.map { $0.replacingOccurrences(of: #" unread \d+$"#, with: "", options: .regularExpression) } }
        #expect(Set(lists.map { $0.joined(separator: "\n") }).count == 1, "panels differ: \(lists)", sourceLocation: sourceLocation)
    }

    /// Opens a thread on the box from `client`; returns its id.
    func thread(_ client: CommentClient, _ text: String, mentions: [String] = []) async -> OpID? {
        client.comments.begin(at: Point(x: 60, y: 60), on: box)
        var body = CommentBody(text)
        for account in mentions {
            let name = Self.roster.first { $0.id == account }?.name ?? account
            let tag = "@\(name)"
            body = CommentBody(body.text + " " + tag, mentions: body.mentions + [CommentBody.Mention(range: (body.text.count + 1)..<(body.text.count + 1 + tag.count), account: account)])
        }
        _ = await client.comments.post(body)?.value
        // The popover closes: comments arriving later count as unread.
        client.comments.close()
        client.comments.refresh(force: true)
        return client.comments.model.threads.last?.id
    }
}

/// COLLAB-034's UI scenarios as app-hosted tests (XCUITest does not run on the build machine): three
/// windows, three people, the comments made through each window's `WindowComments` (what the pins,
/// the popover and the panel call) and relayed between them.  Each asserts convergence (one state
/// hash), every window's panel rows and unread counts.  The server's notification rows are the
/// simulator half's (`CommentCaseScenarioTests`) and the digest the server's (`CommentDigestMailpitTest`).
@Suite(.serialized) @MainActor struct CommentScenarioUITests {
    @Test func concurrentRepliesLandInOneOrderEverywhere() async throws {
        let s = await CommentScenario.make()
        defer { s.close() }
        let thread = try #require(await s.thread(s.priya, "Is this the final red?"))
        await s.sync()
        #expect(s.tom.comments.unreadTotal == 1 && s.cy.comments.unreadTotal == 1 && s.priya.comments.unreadTotal == 0)
        // Tom and Cy reply at the same moment, before either sees the other.
        _ = await s.tom.comments.reply(to: thread, CommentBody("Yes"))?.value
        _ = await s.cy.comments.reply(to: thread, CommentBody("Looks orange to me"))?.value
        await s.sync([s.cy, s.tom, s.priya])
        s.expectConvergence()
        let replies = try #require(s.priya.comments.model[thread]).comments.map(\.author)
        #expect(replies.count == 3 && replies[0] == "acct-priya" && Set(replies.dropFirst()) == ["acct-tom", "acct-cy"])
        #expect(s.priya.comments.unreadTotal == 2 && s.tom.comments.unreadTotal == 2 && s.cy.comments.unreadTotal == 2)
        // Opening the thread reads it.
        s.tom.comments.open(thread)
        s.tom.comments.refresh(force: true)
        #expect(s.tom.comments.unreadTotal == 0 && s.tom.rows.first?.hasSuffix("unread 0") == true)
    }

    @Test func resolveAgainstReopenAndPinDragAgainstPinDragSettleTheSameEverywhere() async throws {
        let s = await CommentScenario.make()
        defer { s.close() }
        let thread = try #require(await s.thread(s.tom, "Check the bleed"))
        await s.sync()
        _ = await s.priya.comments.setResolved(thread, true)?.value
        await s.sync()
        #expect(s.clients.allSatisfy { $0.comments.model[thread]?.resolved == true })
        // Priya reopens while Tom resolves again (he has not seen the reopen): one answer everywhere.
        _ = await s.priya.comments.setResolved(thread, false)?.value
        _ = await s.tom.comments.setResolved(thread, true)?.value
        await s.sync()
        s.expectConvergence()
        // Both drag the pin to different places at once.
        _ = await s.priya.comments.movePin(thread, to: Point(x: 300, y: 200), on: nil)?.value
        _ = await s.tom.comments.movePin(thread, to: Point(x: 400, y: 250), on: nil)?.value
        await s.sync()
        s.expectConvergence()
        let pins = Set(s.clients.compactMap { $0.comments.model[thread]?.pin })
        #expect(pins.count == 1 && s.clients.allSatisfy { $0.comments.model[thread]?.anchoring == .point })
        // A commenter can neither resolve nor move someone else's thread.
        #expect(s.cy.comments.setResolved(thread, false) == nil && s.cy.comments.movePin(thread, to: Point(x: 0, y: 0), on: nil) == nil)
        #expect(s.cy.outbox.isEmpty)
    }

    @Test func anEditAgainstADeleteAndTheCommenterRoleRefusals() async throws {
        let s = await CommentScenario.make()
        defer { s.close() }
        let thread = try #require(await s.thread(s.priya, "Swap the photo?"))
        await s.sync()
        _ = await s.tom.comments.reply(to: thread, CommentBody("Which one"))?.value
        await s.sync()
        let reply = try #require(s.tom.comments.model[thread]?.comments.last?.id)
        // Tom edits his reply while Priya, the owner, deletes it.
        _ = await s.tom.comments.edit(reply, in: thread, CommentBody("Which one, the cover?"))?.value
        _ = await s.priya.comments.delete(reply, in: thread)?.value
        await s.sync()
        s.expectConvergence()
        #expect(s.clients.allSatisfy { $0.comments.model[thread]?.comments.count == 1 })
        // Cy may comment, but not edit or delete others' comments, nor delete threads.
        let opener = try #require(s.cy.comments.model[thread]?.comments.first?.id)
        #expect(s.cy.comments.edit(opener, in: thread, CommentBody("x")) == nil && s.cy.comments.delete(opener, in: thread) == nil)
        #expect(s.cy.comments.deleteThread(thread) == nil && s.tom.comments.deleteThread(thread) == nil)
        _ = await s.cy.comments.reply(to: thread, CommentBody("The cover, please"))?.value
        await s.sync()
        s.expectConvergence()
        #expect(s.priya.rows == ["#1 Rectangle open [acct-priya: Swap the photo? | acct-cy: The cover, please] unread 1"])
    }

    @Test func aCommentOnAnObjectDeletedAtTheSameMomentComesBackWithTheObject() async throws {
        let s = await CommentScenario.make()
        defer { s.close() }
        // Tom deletes the box as Priya comments on it.
        _ = await s.tom.document.perform(DeleteNodes([s.box])).value
        await s.tom.document.settle()
        let thread = try #require(await s.thread(s.priya, "Keep this box"))
        await s.sync()
        s.expectConvergence()
        #expect(s.clients.allSatisfy { $0.comments.model[thread]?.anchorName?.hasSuffix("(deleted)") == true && $0.comments.model[thread]?.pin == nil })
        // Tom undoes: the object and its pin come back everywhere.
        _ = await s.tom.document.undo().value
        await s.tom.document.settle()
        await s.sync()
        s.expectConvergence()
        #expect(s.clients.allSatisfy { $0.comments.model[thread]?.anchoring == .object(s.box) && $0.comments.model[thread]?.pin != nil })
    }

    @Test func offlineCommentsWithMentionsAreDeliveredOnSync() async throws {
        let s = await CommentScenario.make()
        defer { s.close() }
        // Cy is offline: two threads, one mentioning Tom, wait in the outbox.
        _ = try #require(await s.thread(s.cy, "Typo in the headline", mentions: ["acct-tom"]))
        _ = try #require(await s.thread(s.cy, "Logo too small"))
        #expect(s.cy.outbox.count == 2 && s.tom.comments.model.threads.isEmpty)
        #expect(s.tom.window.collaboration.banner.actions.isEmpty)
        // Back online: both arrive; Tom is told once that Cy mentioned him.
        await s.sync()
        s.expectConvergence()
        #expect(s.tom.comments.unreadTotal == 2 && s.priya.comments.unreadTotal == 2 && s.cy.comments.unreadTotal == 0)
        #expect(s.tom.window.collaboration.banner.actions.map(\.text) == ["Cy mentioned you"])
        #expect(s.priya.window.collaboration.banner.actions.isEmpty)
        var mine = CommentFilter()
        mine.mentionsMe = true
        #expect(mine.apply(s.tom.comments.model, account: "acct-tom", members: s.tom.comments.members).map(\.firstLine) == ["Typo in the headline @Tom"])
        // A second sync changes nothing and tells nobody again.
        await s.sync()
        #expect(s.tom.window.collaboration.banner.actions.count == 1)
    }
}
