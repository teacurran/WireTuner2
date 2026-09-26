import Foundation
import Synchronization
import Testing
import WTCRDT
import WTProto
@testable import WTSync

/// COLLAB-027/029's client read state: `GetUnread` on open, arrivals and `CommentEvent`s, marks on
/// display sent as `MarkRead` and kept while they cannot be.
@Suite @MainActor struct CommentReadStateTests {
    final class FakeService: CommentReadService {
        let threads = Mutex<[CommentThreadUnread]>([])
        let marks = Mutex<[(OpID, OpID)]>([])
        let offline = Mutex(false)

        struct Offline: Error {}

        func unread(document: String) async throws -> [CommentThreadUnread] {
            if offline.withLock({ $0 }) { throw Offline() }
            return threads.withLock { $0 }
        }

        func markRead(document: String, thread: OpID, through: OpID) async throws {
            if offline.withLock({ $0 }) { throw Offline() }
            marks.withLock { $0.append((thread, through)) }
        }
    }

    nonisolated static let thread = OpID(counter: 10, replica: 1)
    nonisolated static let other = OpID(counter: 20, replica: 1)
    nonisolated static func comment(_ counter: UInt64) -> OpID { OpID(counter: counter, replica: 2) }

    @Test func theServersCountIsReadAndDisplayingMarksThroughTheNewest() async {
        let service = FakeService()
        service.threads.withLock {
            $0 = [CommentThreadUnread(thread: Self.thread, unread: [Self.comment(11), Self.comment(12)], mentionsMe: true),
                  CommentThreadUnread(thread: Self.other, unread: [], mentionsMe: false)]
        }
        let state = CommentReadState(documentID: "d", service: service)
        var changes = 0
        state.onChange = { changes += 1 }
        #expect(state.total == 0 && !state.isLoaded)
        #expect(await state.load())
        #expect(state.isLoaded && state.total == 2 && state.mentions == [Self.thread] && state.unread[Self.other] == nil)
        // A later comment arrives; one already listed changes nothing.
        state.arrived(Self.comment(13), in: Self.thread)
        state.arrived(Self.comment(13), in: Self.thread)
        #expect(state.unread(in: Self.thread).count == 3 && changes == 2)
        // Displayed through 12: 13 stays unread; the mark reaches the server.
        await state.displayed(Self.thread, through: Self.comment(12))
        #expect(state.unread(in: Self.thread) == [Self.comment(13)] && state.mentions.isEmpty && state.marks[Self.thread] == Self.comment(12))
        #expect(service.marks.withLock { $0.count } == 1 && state.pending.isEmpty)
        // Anything at or before the mark is read already, however it arrives.
        state.arrived(Self.comment(12), in: Self.thread)
        #expect(state.unread(in: Self.thread) == [Self.comment(13)])
        // Displaying again with nothing new sends nothing; an older mark never moves it back.
        await state.displayed(Self.thread, through: Self.comment(13))
        await state.displayed(Self.thread, through: Self.comment(11))
        #expect(state.marks[Self.thread] == Self.comment(13) && state.total == 0)
        #expect(service.marks.withLock { $0.map(\.1) } == [Self.comment(12), Self.comment(13)])
        // A reload keeps this Mac's marks over the server's older answer.
        #expect(await state.load())
        #expect(state.total == 0)
    }

    @Test func eventsCountAndMarksWaitWhileOffline() async {
        let service = FakeService()
        service.offline.withLock { $0 = true }
        let state = CommentReadState(documentID: "d", service: service)
        #expect(await state.load() == false && !state.isLoaded)
        var event = Wiretuner_Sync_V1_CommentEvent()
        event.thread = Self.thread.proto
        event.comment.counter = 30
        event.comment.replica = 2
        event.kind = .mention
        state.handle(event)
        #expect(state.total == 1 && state.mentions == [Self.thread])
        // The same comment again as a mention changes nothing; a reply elsewhere counts.
        state.handle(event)
        event.thread = Self.other.proto
        event.kind = .reply
        state.handle(event)
        #expect(state.total == 2 && state.mentions == [Self.thread])
        await state.displayed(Self.thread, through: Self.comment(30))
        #expect(state.pending == [Self.thread: Self.comment(30)] && state.total == 1)
        await state.flush()
        #expect(state.pending.count == 1)
        service.offline.withLock { $0 = false }
        await state.flush()
        #expect(state.pending.isEmpty && service.marks.withLock { $0.count } == 1)
    }

    @Test func withoutAServerTheStateStaysOnThisMac() async {
        let state = CommentReadState(documentID: "d", service: nil)
        #expect(await state.load() == false)
        state.arrived(Self.comment(5), in: Self.thread)
        await state.displayed(Self.thread, through: Self.comment(5))
        await state.flush()
        #expect(state.total == 0 && state.pending.isEmpty && state.marks[Self.thread] == Self.comment(5))
    }

    @Test func theGRPCServiceMapsTheMessages() async throws {
        let sent = Mutex<[Wiretuner_Docs_V1_MarkReadRequest]>([])
        let service = GRPCCommentReadService(getUnread: { request in
            #expect(request.documentID == "d")
            return .with { response in
                response.total = 1
                response.threads = [.with { $0.thread = Self.thread.proto; $0.unread = [.with { $0.counter = 11; $0.replica = 2 }]; $0.mentionsMe = true }]
            }
        }, markRead: { request in sent.withLock { $0.append(request) } })
        let threads = try await service.unread(document: "d")
        #expect(threads == [CommentThreadUnread(thread: Self.thread, unread: [Self.comment(11)], mentionsMe: true)])
        try await service.markRead(document: "d", thread: Self.thread, through: Self.comment(11))
        let request = try #require(sent.withLock { $0.first })
        #expect(request.documentID == "d" && OpID(request.thread) == Self.thread && request.through.counter == 11 && request.through.replica == 2)
    }
}
