import Foundation
import WTCRDT
import WTProto

/// One thread's unread comments as `CommentService.GetUnread` answers them.
public struct CommentThreadUnread: Hashable, Sendable {
    /// The `comment_thread` node.
    public var thread: OpID
    /// The unread comments' element ids.
    public var unread: [OpID]
    /// A comment among them mentions the caller (or a team of theirs).
    public var mentionsMe: Bool

    public init(thread: OpID, unread: [OpID], mentionsMe: Bool = false) {
        self.thread = thread
        self.unread = unread
        self.mentionsMe = mentionsMe
    }
}

/// The server's side of comment read state (`CommentService`, comment.proto; COLLAB-030).
public protocol CommentReadService: Sendable {
    /// `GetUnread`: the caller's unread comments in `document`, per thread.
    func unread(document: String) async throws -> [CommentThreadUnread]
    /// `MarkRead`: the caller has seen `thread` through `through` (idempotent, monotone).
    func markRead(document: String, thread: OpID, through: OpID) async throws
}

/// Which comments of one document this account has not seen (comments.adoc, "Being told about
/// comments"; the local mirror of the server's `comment_read`, COLLAB-027/029): the threads' unread
/// comment ids -- the server's (`GetUnread`, which counts comments this Mac has not received yet),
/// plus those that arrived since, by someone else, from the document or a `CommentEvent` -- less
/// every comment at or before the thread's read mark.  Displaying a thread marks it read through
/// its newest comment at once here and sends `MarkRead`; a mark that cannot be sent (offline)
/// waits and goes with the next `flush()`, and until then this state is what the badges read.
@MainActor
public final class CommentReadState {
    public let documentID: String
    let service: (any CommentReadService)?
    /// Unread comment ids per thread.
    public private(set) var unread: [OpID: Set<OpID>] = [:]
    /// Threads holding an unseen mention of this account.
    public private(set) var mentions: Set<OpID> = []
    /// The newest comment each thread has been read through.
    public private(set) var marks: [OpID: OpID] = [:]
    /// Marks not yet accepted by the server.
    public private(set) var pending: [OpID: OpID] = [:]
    /// `GetUnread` has answered at least once.
    public private(set) var isLoaded = false
    /// Called after every change of what is unread.
    public var onChange: @MainActor () -> Void = {}

    /// `service` nil keeps the state on this Mac only (a document without a server).
    public init(documentID: String, service: (any CommentReadService)?) {
        self.documentID = documentID
        self.service = service
    }

    /// The toolbar count: unread comments over every thread.
    public var total: Int { unread.values.reduce(0) { $0 + $1.count } }

    /// The unread comments of `thread`.
    public func unread(in thread: OpID) -> Set<OpID> { unread[thread] ?? [] }

    private func isRead(_ comment: OpID, in thread: OpID) -> Bool {
        marks[thread].map { comment <= $0 } ?? false
    }

    /// Reads the server's unread state, which replaces what this Mac thought (the server knows of
    /// reads on the person's other Macs), keeping this Mac's own marks; false when it could not.
    @discardableResult
    public func load() async -> Bool {
        guard let service else { return false }
        guard let threads = try? await service.unread(document: documentID) else { return false }
        var unread: [OpID: Set<OpID>] = [:]
        var mentions: Set<OpID> = []
        for thread in threads {
            let ids = Set(thread.unread.filter { !isRead($0, in: thread.thread) })
            guard !ids.isEmpty else { continue }
            unread[thread.thread] = ids
            if thread.mentionsMe { mentions.insert(thread.thread) }
        }
        self.unread = unread
        self.mentions = mentions
        isLoaded = true
        onChange()
        return true
    }

    /// A comment by someone else arrived (in the document, or announced by a `CommentEvent`).
    public func arrived(_ comment: OpID, in thread: OpID, mentionsMe: Bool = false) {
        guard !isRead(comment, in: thread) else { return }
        let inserted = unread[thread, default: []].insert(comment).inserted
        let mentioned = mentionsMe && mentions.insert(thread).inserted
        if inserted || mentioned { onChange() }
    }

    /// A `CommentEvent` on the subscription: the comment counts as unread (a resolve names the
    /// resolving op, which no thread lists, so it only counts until the thread is displayed).
    public func handle(_ event: Wiretuner_Sync_V1_CommentEvent) {
        let thread = OpID(event.thread)
        let comment = OpID(counter: event.comment.counter, replica: event.comment.replica)
        arrived(comment, in: thread, mentionsMe: event.kind == .mention)
    }

    /// `thread` was displayed with `through` its newest comment: everything at or before it is
    /// read here at once, and the mark goes to the server.
    public func displayed(_ thread: OpID, through: OpID) async {
        guard mark(thread, through: through), let mark = pending[thread] else { return }
        await send(thread, mark)
    }

    /// The local half of `displayed`, at once: true when a mark now waits to be sent (`flush`).
    @discardableResult
    public func mark(_ thread: OpID, through: OpID) -> Bool {
        if let mark = marks[thread], through <= mark, unread(in: thread).isEmpty { return false }
        let mark = max(through, marks[thread] ?? through)
        marks[thread] = mark
        let left = unread(in: thread).filter { $0 > mark }
        unread[thread] = left.isEmpty ? nil : left
        mentions.remove(thread)
        onChange()
        guard service != nil else { return false }
        pending[thread] = mark
        return true
    }

    /// Sends every mark still waiting (the session came back).
    public func flush() async {
        for (thread, mark) in pending.sorted(by: { $0.key < $1.key }) {
            await send(thread, mark)
        }
    }

    private func send(_ thread: OpID, _ mark: OpID) async {
        guard let service else { return }
        do {
            try await service.markRead(document: documentID, thread: thread, through: mark)
            if pending[thread] == mark { pending[thread] = nil }
        } catch {
            // Kept in `pending` for the next flush.
        }
    }
}

/// `CommentService` over a gRPC unary call (the app gives it its caller).
public struct GRPCCommentReadService: CommentReadService {
    let getUnread: @Sendable (Wiretuner_Docs_V1_GetUnreadRequest) async throws -> Wiretuner_Docs_V1_GetUnreadResponse
    let mark: @Sendable (Wiretuner_Docs_V1_MarkReadRequest) async throws -> Void

    public init(getUnread: @escaping @Sendable (Wiretuner_Docs_V1_GetUnreadRequest) async throws -> Wiretuner_Docs_V1_GetUnreadResponse,
                markRead: @escaping @Sendable (Wiretuner_Docs_V1_MarkReadRequest) async throws -> Void) {
        self.getUnread = getUnread
        mark = markRead
    }

    public func unread(document: String) async throws -> [CommentThreadUnread] {
        var request = Wiretuner_Docs_V1_GetUnreadRequest()
        request.documentID = document
        let response = try await getUnread(request)
        return response.threads.map { thread in
            CommentThreadUnread(thread: OpID(thread.thread), unread: thread.unread.map { OpID(counter: $0.counter, replica: $0.replica) },
                                mentionsMe: thread.mentionsMe)
        }
    }

    public func markRead(document: String, thread: OpID, through: OpID) async throws {
        var request = Wiretuner_Docs_V1_MarkReadRequest()
        request.documentID = document
        request.thread = thread.proto
        request.through.counter = through.counter
        request.through.replica = through.replica
        try await mark(request)
    }
}
