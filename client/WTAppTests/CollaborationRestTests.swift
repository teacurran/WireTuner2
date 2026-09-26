import AppKit
import Foundation
import Synchronization
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTSync
@testable import WireTuner

/// A `CommentService` answering from memory.
final class FakeCommentReadService: CommentReadService {
    let threads = Mutex<[CommentThreadUnread]>([])
    let marks = Mutex<[(OpID, OpID)]>([])

    func unread(document: String) async throws -> [CommentThreadUnread] { threads.withLock { $0 } }

    func markRead(document: String, thread: OpID, through: OpID) async throws {
        marks.withLock { $0.append((thread, through)) }
    }
}

/// `ListMentionedDocuments` from memory.
final class FakeMentions: MentionedDocumentsClient {
    let documents = Mutex<Set<String>?>(["d1"])
    let calls = Mutex(0)

    struct Offline: Error {}

    func mentionedDocuments() async throws -> Set<String> {
        calls.withLock { $0 += 1 }
        guard let documents = documents.withLock({ $0 }) else { throw Offline() }
        return documents
    }
}

/// The rests of COLLAB-018 (the merge toast), COLLAB-022 (the object history popover) and COLLAB-027
/// (read state against the server, `CommentEvent`s, the toolbar button's count, the library's dots).
@Suite(.serialized) @MainActor struct CollaborationRestTests {
    // MARK: COLLAB-027

    @Test func unreadCountsFollowTheServerEventsAndDisplay() async throws {
        let world = CommentWorld()
        defer { world.close() }
        let service = FakeCommentReadService()
        // A comment on a thread this Mac has not received yet counts too.
        let unseen = OpID(counter: 900, replica: 7)
        service.threads.withLock { $0 = [CommentThreadUnread(thread: OpID(counter: 899, replica: 7), unread: [unseen], mentionsMe: true)] }
        world.features.readService = { _ in service }
        let comments = world.comments
        #expect(await eventually { comments.readState.isLoaded })
        #expect(comments.unreadTotal == 1 && comments.readState.mentions.count == 1)
        let toolbar = try #require(world.window.mainToolbar)
        #expect(toolbar.badgeCount(MainToolbarController.comments) == 1 && toolbar.badgeCount(StandardCommands.ID.new) == nil)
        let item = toolbar.item(for: MainToolbarController.comments)
        if #available(macOS 26.0, *) { #expect(item.badge != nil && item.label == "Comments") } else { #expect(item.label == "Comments (1)") }
        // Ann's thread, then Bo's reply from another Mac: unread in the thread and the total.
        let thread = try #require(await world.thread("Mine"))
        comments.close()
        await world.document.receiveRemote(Reply(to: thread, author: "acct-bo", body: CommentBody("reply")))
        #expect(comments.unreadTotal == 2 && comments.model[thread]?.unreadCount == 1)
        // A CommentEvent for a comment not here yet counts at once.
        var event = Wiretuner_Sync_V1_CommentEvent()
        event.thread = thread.proto
        event.comment.counter = 5_000
        event.comment.replica = 9
        event.kind = .reply
        comments.commentEvent(event)
        #expect(comments.unreadTotal == 3)
        // Displaying the thread reads it through its newest comment and tells the server.
        comments.open(thread)
        let newest = try #require(comments.model[thread]?.comments.map(\.id).max())
        #expect(await eventually { service.marks.withLock { $0.last?.1 } == newest })
        #expect(service.marks.withLock { $0.last?.0 } == thread)
        #expect(comments.unreadTotal == 2 && comments.model[thread]?.unreadCount == 0, "the event's later comment is still unread")
        toolbar.refreshBadges()
        _ = toolbar.validateToolbarItem(item)
        comments.tearDown()
    }

    @Test func theLibraryShowsMentionDotsAndPollsThem() async throws {
        let library = LibraryModel(services: FakeLibraryServer().services(), store: nil, thumbnails: ThumbnailCache(directory: nil))
        await library.refreshMentions()
        #expect(library.mentioned.isEmpty, "no client, no dots")
        let mentions = FakeMentions()
        library.mentions = mentions
        await library.refreshMentions()
        #expect(library.mentioned == ["d1"])
        mentions.documents.withLock { $0 = nil }
        await library.refreshMentions()
        #expect(library.mentioned == ["d1"], "kept when the call fails")
        mentions.documents.withLock { $0 = [] }
        library.mentionInterval = .milliseconds(10)
        library.startMentionPolling()
        library.startMentionPolling()
        #expect(await eventually { mentions.calls.withLock { $0 } >= 5 && library.mentioned.isEmpty })
        library.stopMentionPolling()
        #expect(library.mentionPolling == nil)
    }

    @Test func theCommentClientsSpeakTheCommentService() async throws {
        typealias Comments = Wiretuner_Docs_V1_CommentService.Method
        let caller = FakeUnaryCaller([
            route(Comments.GetUnread.descriptor) { (request: Wiretuner_Docs_V1_GetUnreadRequest) -> Wiretuner_Docs_V1_GetUnreadResponse in
                .with { response in
                    response.total = 1
                    response.threads = [.with { $0.thread.counter = 3; $0.thread.replica = 1; $0.unread = [.with { $0.counter = 4; $0.replica = 2 }] }]
                }
            },
            route(Comments.MarkRead.descriptor) { (_: Wiretuner_Docs_V1_MarkReadRequest) -> Wiretuner_Docs_V1_MarkReadResponse in .init() },
            route(Comments.ListMentionedDocuments.descriptor) { (request: Wiretuner_Docs_V1_ListMentionedDocumentsRequest) -> Wiretuner_Docs_V1_ListMentionedDocumentsResponse in
                .with { response in
                    response.documentIds = request.cursor.isEmpty ? ["a", "b"] : ["c"]
                    response.nextCursor = request.cursor.isEmpty ? "next" : ""
                }
            },
        ])
        let service = GRPCCommentReadService(caller: caller) { "token" }
        let threads = try await service.unread(document: "d")
        #expect(threads.first?.thread == OpID(counter: 3, replica: 1) && threads.first?.unread == [OpID(counter: 4, replica: 2)])
        try await service.markRead(document: "d", thread: OpID(counter: 3, replica: 1), through: OpID(counter: 4, replica: 2))
        let mentions = GRPCMentionedDocuments(caller: caller) { "token" }
        #expect(try await mentions.mentionedDocuments() == ["a", "b", "c"])
    }

    // MARK: COLLAB-018

    @Test func aMergeIntoThisDocumentToastsAndPulsesAsTheMerger() async throws {
        let world = CollaborationWorld()
        defer { world.close() }
        let collaboration = world.window.collaboration
        let id = world.document.id
        var event = Wiretuner_Sync_V1_BranchEvent()
        event.kind = .merged
        event.name = "Autumn palette"
        event.parentDocumentID = id
        event.branchDocumentID = "branch-1"
        event.actor.displayName = "Priya"
        event.actor.userID = "acct-priya"
        #expect(WindowCollaboration.mergeToast(event, document: id) == "Autumn palette merged by Priya")
        #expect(WindowCollaboration.mergeToast(event, document: "branch-1") == "Autumn palette was merged into main by Priya")
        #expect(WindowCollaboration.mergeToast(event, document: "other") == nil)
        var anonymous = event
        anonymous.name = ""
        anonymous.actor = Wiretuner_Sync_V1_Participant()
        #expect(WindowCollaboration.mergeToast(anonymous, document: id) == "A branch merged by someone")
        var created = event
        created.kind = .created
        #expect(WindowCollaboration.mergeToast(created, document: id) == nil)
        // The event on the subscription: the toast, then remote changes pulse as Priya for a while.
        var change = Wiretuner_Doc_V1_Change()
        change.replica = 0xABC
        #expect(collaboration.author(of: change) == nil)
        collaboration.documentEvent(.with { $0.branch = event })
        #expect(world.window.statusBar.message.stringValue == "Autumn palette merged by Priya")
        #expect(collaboration.author(of: change)?.name == "Priya")
        let later = Date().addingTimeInterval(WindowCollaboration.mergeAttributionWindow + 1)
        collaboration.now = { later }
        #expect(collaboration.author(of: change) == nil)
        // Other events change nothing.
        collaboration.documentEvent(.with { $0.renamed = .with { $0.name = "R" } })
        collaboration.documentEvent(.with { $0.branch = created })
        let rects = await world.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        await world.document.receiveRemote(OpsCommand("Move", ops: [Ops.setDeleted(rects[0].opID, false)]))
    }

    // MARK: COLLAB-022

    @Test func theObjectHistoryPopoverListsChangesAndViewsBeforeOne() async throws {
        let w = HistoryTests.World()
        defer { w.close() }
        let client = NodeHistoryFake()
        w.model.client = { client }
        let node = OpID(counter: 5, replica: 1)
        let model = NodeHistoryModel(node: node, history: w.model)
        #expect(model.line == nil && model.isAvailable)
        let now = Date(timeIntervalSince1970: 2_000_000)
        model.now = { now }
        client.pages = [
            NodeHistoryPage(entries: [
                NodeHistoryEntry(serverSeq: 12, label: "Fill", author: "Priya", wallTime: now.addingTimeInterval(-300), attributes: ["Fill", "Stroke"], lost: ["Stroke"]),
                NodeHistoryEntry(serverSeq: 7, label: "Move", author: "Tom", wallTime: nil, attributes: [], lost: []),
            ], nextCursor: "more"),
            NodeHistoryPage(entries: [NodeHistoryEntry(serverSeq: 3, label: "Create", author: "Tom", wallTime: nil, attributes: [], lost: [])], nextCursor: ""),
        ]
        await model.load()
        #expect(model.entries.count == 2 && model.nextCursor == "more" && client.cursors == [""])
        #expect(model.line == "Changed by Priya, 5 minutes ago")
        #expect(NodeHistoryModel.what(model.entries[0]) == "Fill, Stroke (did not apply)" && NodeHistoryModel.what(model.entries[1]) == "Move")
        #expect(NodeHistoryModel.byline(model.entries[0]).hasPrefix("Priya · ") && NodeHistoryModel.byline(model.entries[1]) == "Tom")
        await model.load(more: true)
        #expect(model.entries.map(\.serverSeq) == [12, 7, 3] && model.nextCursor.isEmpty && client.cursors == ["", "more"])
        await model.load(more: true)
        #expect(client.cursors.count == 2, "no more pages")
        // View: the version window at the state just before the change.
        #expect(await model.view(model.entries[0]))
        #expect(w.shown.last?.0 == "Before \u{201C}Fill\u{201D} by Priya")
        w.shown.last?.1.restore()
        w.shown.last?.1.restoreAsCopy()
        w.shown.last?.1.compare()
        #expect(await model.view(NodeHistoryEntry(serverSeq: 0, label: "x", author: "y", wallTime: nil, attributes: [], lost: [])) == false)
        // A change without a time; a failing call; no client.
        client.pages = [NodeHistoryPage(entries: [NodeHistoryEntry(serverSeq: 7, label: "Move", author: "Tom", wallTime: nil, attributes: [], lost: [])], nextCursor: "")]
        await model.load()
        #expect(model.line == "Changed by Tom")
        client.fails = true
        await model.load()
        #expect(model.message?.hasPrefix("This object's history could not be read") == true)
        w.model.client = { nil }
        #expect(!model.isAvailable)
        await model.load()
        // The panel's hook: one object selected.
        #expect(ObjectPanelBody.blamed(nil) == nil)
        let ids = await w.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 20, y: 0, width: 10, height: 10)])
        let selection = ActiveSelection(model: w.collaboration.window.selection.model, document: w.document)
        w.collaboration.window.selection.model.apply([ids[0]], mode: .replace)
        #expect(ObjectPanelBody.blamed(selection) == ids[0].opID)
        w.collaboration.window.selection.model.apply(ids, mode: .replace)
        #expect(ObjectPanelBody.blamed(selection) == nil)
        // The views build.
        _ = NodeHistoryPopoverView(model: model).body
        _ = BlameLineView(node: node).body
        var shown = false
        BlameLineView.toggling(Binding(get: { shown }, set: { shown = $0 }))()
        #expect(shown)
        // The fake panel client's own history answers nothing.
        #expect(try await w.client.nodeHistory(of: "d", node: node, cursor: "").entries.isEmpty)
    }

    @Test func theNodeHistoryCallSpeaksTheVersionService() async throws {
        typealias Versions = Wiretuner_Docs_V1_VersionService.Method
        let caller = FakeUnaryCaller([
            route(Versions.ListNodeHistory.descriptor) { (request: Wiretuner_Docs_V1_ListNodeHistoryRequest) -> Wiretuner_Docs_V1_ListNodeHistoryResponse in
                .with { response in
                    response.changes = [
                        .with { $0.serverSeq = 9; $0.label = "Fill"; $0.wallTime = .init(date: Date()); $0.attributes = ["Fill"]; $0.lostAttributes = ["Fill"] },
                        .with { $0.serverSeq = 4; $0.label = "Move" },
                    ]
                    response.authors = [.with { $0.displayName = "Priya" }]
                    response.nextCursor = request.node.counter == 5 ? "n" : ""
                }
            },
        ])
        let client = GRPCHistoryClient(caller: caller) { "token" }
        let page = try await client.nodeHistory(of: "d", node: OpID(counter: 5, replica: 1), cursor: "")
        #expect(page.nextCursor == "n" && page.entries.count == 2)
        #expect(page.entries[0].author == "Priya" && page.entries[0].lost == ["Fill"] && page.entries[0].wallTime != nil)
        #expect(page.entries[1].author == "Someone" && page.entries[1].wallTime == nil)
    }
}

/// `ListNodeHistory` pages from memory.
final class NodeHistoryFake: HistoryClient, @unchecked Sendable {
    var pages: [NodeHistoryPage] = []
    var fails = false
    private(set) var cursors: [String] = []

    struct Failure: Error {}

    func history(of document: String, cursor: String, query: String, expandSession: UInt64) async throws -> HistoryPage {
        HistoryPage(rows: [], nextCursor: "", retainedFromSeq: 0)
    }

    func rename(version: String, name: String?, note: String?) async throws {}
    func delete(version: String) async throws {}
    func restoreAsCopy(of document: String, serverSeq: UInt64, newID: String, name: String) async throws -> String { newID }

    func nodeHistory(of document: String, node: OpID, cursor: String) async throws -> NodeHistoryPage {
        if fails { throw Failure() }
        cursors.append(cursor)
        return cursor.isEmpty ? pages[0] : pages[min(1, pages.count - 1)]
    }
}
