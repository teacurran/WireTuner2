import Foundation
import WTCRDT
import WTProto
import WTSync

/// The server's record of comments in the simulator (COLLAB-034; comments.adoc, "Server" as built
/// by COLLAB-030 and COLLAB-031), one per document: what `CommentOps`, `CommentRules`,
/// `CommentIndex`, `CommentGrpcService` and `CommentDigestJob` do, so a scenario can assert the
/// notification rows, the unread counts and the digest mails the real server would produce.
///
/// * `parse` reads every op of a change once, by its field path (paths under a thread start at
///   `NodeProps` field 210); `check` applies the ownership rules to a change before it is accepted
///   (`ROLE_INSUFFICIENT`); `index` records an accepted one -- threads with their opener and
///   `resolved`, comments with their author, `deleted` and a preview -- and returns the
///   notifications it caused: mentions (from the `mentions` set and from `mention` marks, once per
///   recipient and comment in 24 hours, `team:` members expanding to the team's members with
///   access), replies (the opener and earlier authors) and resolves (the opener).
/// * `unread` is `GetUnread`: per thread, the live comments by others past the account's mark;
///   `markRead` is `MarkRead`, raising the mark and marking the thread's notifications seen.
/// * `digest` is one run of the Comment digest job: every mention older than the delay, unseen,
///   unmailed and less than a week old, of an account with no live session on the document and
///   mails not turned off, becomes one mail per (account, document).
///
/// Not modelled: the preference store (a scenario passes the accounts that turned mails off) and
/// `ListMentionedDocuments` paging.
public struct SimComments: Sendable {
    /// What one op means for comments (`CommentOps.CommentOp`).
    public enum Op: Sendable, Hashable {
        case foreign
        case createThread(thread: OpID, parent: OpID)
        case node(target: OpID, delete: Bool, parent: OpID?)
        case threadWrite(target: OpID)
        case resolve(target: OpID, resolved: Bool, op: OpID)
        case elementWrite(target: OpID, element: OpID, ownerMay: Bool, authors: [String], authorRequired: Bool, deleted: Bool?, op: OpID)
        case newComments(target: OpID, elements: [OpID], authors: [String], mentions: [[String]])
        case reaction(target: OpID, members: [String])
        case typed(target: OpID, element: OpID, chars: String)
        case mentioned(target: OpID, element: OpID, mentions: [String])
    }

    /// A `comment_notification` row.
    public struct Notification: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable {
            case mention, reply, resolved
        }

        public var account: String
        public var thread: OpID
        public var comment: OpID
        public var kind: Kind
        public var author: String
        /// When it was created: the simulated time the change was sequenced.
        public var createdMs: Int64
        public var seenMs: Int64?
        public var emailedMs: Int64?
    }

    /// One digest mail: to whom, about which document, one line per mention (the author's name,
    /// the thread's opening line and its `wiretuner://doc/<id>/thread/<counter>-<replica>` link).
    public struct Mail: Sendable, Hashable {
        public struct Mention: Sendable, Hashable {
            public var author: String
            public var openingLine: String
            public var link: String
        }

        public var account: String
        public var document: String
        public var mentions: [Mention]
    }

    /// `ThreadUnread`: a thread's unread comments for one account, and whether an unseen mention of
    /// the account is in it.
    public struct Unread: Sendable, Hashable {
        public var thread: OpID
        public var comments: [OpID]
        public var mentionsMe: Bool
    }

    static let threadField: UInt32 = 210
    static let resolvedField: UInt32 = 6
    static let commentsField: UInt32 = 7
    static let authorField: UInt32 = 2
    static let bodyField: UInt32 = 3
    static let mentionsField: UInt32 = 6
    static let reactionsField: UInt32 = 7
    static let deletedField: UInt32 = 8
    static let collection = OpID.wellKnown(12)
    /// The digest quotes at most this many characters of a comment.
    static let previewScalars = 200
    static let day: Int64 = 24 * 3600 * 1_000

    /// Threads: opener, creation order, `resolved` and the op that wrote it.
    public private(set) var openers: [OpID: String] = [:]
    private var threadOrder: [OpID] = []
    private var resolved: [OpID: (value: Bool, op: OpID)] = [:]
    /// Comments: their thread, author, `deleted` with its op, and preview.
    private var commentThread: [OpID: OpID] = [:]
    private var authors: [OpID: String] = [:]
    private var deleted: [OpID: (value: Bool, op: OpID)] = [:]
    private var previews: [OpID: String] = [:]
    /// `comment_read`: account -> thread -> the mark.
    private var reads: [String: [OpID: OpID]] = [:]
    /// Every notification in creation order.
    public private(set) var notifications: [Notification] = []

    public init() {}

    // MARK: Parsing (CommentOps)

    private enum Place {
        case foreign, thread, resolved, comments
        case element(OpID, field: UInt32)
    }

    private static func place(_ path: Wiretuner_Doc_V1_FieldPath) -> Place {
        let segments = path.segments
        guard let first = segments.first, first.field == threadField else { return .foreign }
        guard segments.count > 1 else { return .resolved }
        let field = segments[1].field
        if field == resolvedField { return .resolved }
        guard field == commentsField else { return field == 0 ? .foreign : .thread }
        guard segments.count > 2 else { return .comments }
        guard case .element(let element)? = segments[2].segment else { return .foreign }
        let id = OpID(counter: element.counter, replica: element.replica)
        return .element(id, field: segments.count == 3 ? 0 : segments[3].field)
    }

    /// The meaning of every op of `change`, in order; empty when nothing concerns comments.
    public static func parse(_ change: Wiretuner_Doc_V1_Change) -> [Op] {
        var out: [Op] = []
        var counter = change.startCounter
        for op in change.ops {
            read(op, OpID(counter: counter, replica: change.replica), &out)
            counter += EngineState.counters(op)
        }
        return out
    }

    private static func read(_ op: Wiretuner_Doc_V1_Op, _ id: OpID, _ out: inout [Op]) {
        switch op.op {
        case .create(let create)?:
            if case .commentThread? = create.props.kind {
                out.append(.createThread(thread: id, parent: OpID(create.parent)))
            } else {
                out.append(.foreign)
            }
        case .set(let set)?:
            for path in set.paths {
                out.append(write(OpID(set.node), place(path), set.values, id))
            }
        case .move(let move)?:
            out.append(.node(target: OpID(move.node), delete: false, parent: OpID(move.parent)))
        case .setDeleted(let setDeleted)?:
            out.append(.node(target: OpID(setDeleted.node), delete: true, parent: nil))
        case .elementInsert(let insert)?:
            let node = OpID(insert.node)
            let place = place(insert.sequence)
            if case .comments = place {
                let comments = insert.values.commentThread.comments
                let elements = (0..<max(1, insert.positions.count)).map { OpID(counter: id.counter + UInt64($0), replica: id.replica) }
                out.append(.newComments(target: node, elements: elements, authors: comments.map(\.authorAccountID),
                                        mentions: comments.map(\.mentions)))
            } else {
                out.append(generic(node, place, id))
            }
        case .elementMove(let move)?:
            out.append(generic(OpID(move.node), place(move.element), id))
        case .elementDelete(let delete)?:
            let node = OpID(delete.node)
            for path in delete.elements {
                let place = place(path)
                if case .element(let element, 0) = place {
                    out.append(.elementWrite(target: node, element: element, ownerMay: true, authors: [], authorRequired: false,
                                             deleted: delete.deleted, op: id))
                } else {
                    out.append(generic(node, place, id))
                }
            }
        case .textInsert(let insert)?:
            let node = OpID(insert.node)
            let place = place(insert.text)
            out.append(generic(node, place, id))
            if case .element(let element, bodyField) = place {
                out.append(.typed(target: node, element: element, chars: insert.chars))
            }
        case .textDelete(let delete)?:
            out.append(generic(OpID(delete.node), place(delete.text), id))
        case .textMark(let mark)?:
            let node = OpID(mark.node)
            let place = place(mark.text)
            out.append(generic(node, place, id))
            if case .element(let element, _) = place, case .mention(let account)? = mark.value.value {
                out.append(.mentioned(target: node, element: element, mentions: [account]))
            }
        case .setAdd(let add)?:
            members(OpID(add.node), place(add.set), add.values, adding: true, id, &out)
        case .setRemove(let remove)?:
            members(OpID(remove.node), place(remove.set), remove.values, adding: false, id, &out)
        default:
            break
        }
    }

    private static func write(_ node: OpID, _ place: Place, _ values: Wiretuner_Doc_V1_NodeProps, _ id: OpID) -> Op {
        let thread = values.commentThread
        if case .resolved = place { return .resolve(target: node, resolved: thread.resolved, op: id) }
        guard case .element(let element, let field) = place else { return generic(node, place, id) }
        let authors = thread.comments.map(\.authorAccountID).filter { !$0.isEmpty }
        let whole = field == 0
        let deleted = (whole || field == deletedField) ? (thread.comments.last?.deleted ?? false) : nil
        return .elementWrite(target: node, element: element, ownerMay: field == deletedField, authors: authors,
                             authorRequired: whole || field == authorField, deleted: deleted, op: id)
    }

    private static func members(_ node: OpID, _ place: Place, _ values: Wiretuner_Doc_V1_NodeProps, adding: Bool, _ id: OpID,
                                _ out: inout [Op]) {
        if case .element(_, reactionsField) = place {
            out.append(.reaction(target: node, members: values.commentThread.comments.flatMap(\.reactions)))
            return
        }
        out.append(generic(node, place, id))
        if adding, case .element(let element, mentionsField) = place {
            out.append(.mentioned(target: node, element: element, mentions: values.commentThread.comments.flatMap(\.mentions)))
        }
    }

    private static func generic(_ node: OpID, _ place: Place, _ id: OpID) -> Op {
        switch place {
        case .foreign: .foreign
        case .element(let element, _): .elementWrite(target: node, element: element, ownerMay: false, authors: [], authorRequired: false,
                                                      deleted: nil, op: id)
        default: .threadWrite(target: node)
        }
    }

    // MARK: The role rule (CommentRules)

    /// Why `ops` may not be made by `caller` holding `role`, or nil when they may.  Threads and
    /// comments the change itself creates count as the caller's for its later ops.
    public func refusal(_ ops: [Op], caller: String, role: Wiretuner_Account_V1_DocumentRole) -> String? {
        var openers = openers
        var authors = authors
        let editor = role == .editor || role == .owner
        func opener(_ target: OpID) -> Result<String?, Refusal> {
            guard editor || openers[target] != nil else { return .failure(Refusal("the commenter role may only change comments")) }
            return .success(openers[target])
        }
        do {
            for op in ops {
                switch op {
                case .foreign:
                    try require(editor, "the commenter role may only change comments")
                case .createThread(let thread, let parent):
                    try require(editor || parent == Self.collection, "a thread must be created under the comments collection")
                    openers[thread] = caller
                case .node(let target, let delete, let parent):
                    let own = try opener(target).get() == caller
                    try require(openers[target] == nil || (delete ? role == .owner || own : editor || own && parent == Self.collection),
                                "only the thread's opener, an editor or the owner may do that to a thread")
                case .threadWrite(let target), .resolve(let target, _, _):
                    let owner = try opener(target).get()
                    try require(editor || owner == caller, "only the thread's opener or an editor may change it")
                case .elementWrite(let target, let element, let ownerMay, let written, let authorRequired, _, _):
                    _ = try opener(target).get()
                    if openers[target] != nil {
                        try require(written.allSatisfy { $0 == caller } && (!authorRequired || !written.isEmpty), "a comment's author must be the caller")
                        try require(authors[element] == caller || ownerMay && role == .owner, "only its author may change a comment")
                    }
                case .newComments(let target, let elements, let written, _):
                    _ = try opener(target).get()
                    for (index, element) in elements.enumerated() {
                        let author = index < written.count ? written[index] : ""
                        try require(openers[target] == nil || author == caller, "a new comment's author must be the caller")
                        authors[element] = caller
                    }
                case .reaction(let target, let members):
                    _ = try opener(target).get()
                    try require(openers[target] == nil || members.allSatisfy { $0.hasPrefix(caller + ":") },
                                "a reaction may only be added or removed by its own account")
                case .typed, .mentioned:
                    break
                }
            }
        } catch let refusal as Refusal {
            return refusal.why
        } catch {
            return "\(error)"
        }
        return nil
    }

    private struct Refusal: Error {
        let why: String
        init(_ why: String) { self.why = why }
    }

    private func require(_ allowed: Bool, _ why: String) throws {
        if !allowed { throw Refusal(why) }
    }

    // MARK: The record (CommentIndex)

    /// Records what an accepted change by `author` did, at `nowMs`, and returns the notifications
    /// it caused.  `canOpen` says whether an account may open the document; `teams` expands a
    /// `team:<id>` mention.
    ///
    /// `notify` false records without notifying: a copy's record taken from its source, or a
    /// branch's merged into its parent (COLLAB-034's finding; the branch's sessions were told).
    public mutating func index(_ ops: [Op], author: String, nowMs: Int64, canOpen: (String) -> Bool,
                               teams: [String: [String]] = [:], notify: Bool = true) -> [Notification] {
        var notes: [Notification] = []
        for op in ops {
            switch op {
            case .createThread(let thread, _):
                if openers[thread] == nil {
                    openers[thread] = author
                    threadOrder.append(thread)
                }
            case .newComments(let thread, let elements, _, let mentions) where openers[thread] != nil:
                var fresh: [(OpID, [String])] = []
                for (index, element) in elements.enumerated() where commentThread[element] == nil {
                    commentThread[element] = thread
                    authors[element] = author
                    fresh.append((element, index < mentions.count ? mentions[index] : []))
                }
                guard !fresh.isEmpty else { continue }
                let freshIDs = Set(fresh.map(\.0))
                var earlier = Set(commentThread.filter { $0.value == thread && !freshIDs.contains($0.key) }.compactMap { authors[$0.key] })
                if let opener = openers[thread] { earlier.insert(opener) }
                for account in earlier.sorted() where account != author && canOpen(account) {
                    for (element, _) in fresh {
                        notes.append(notification(account, thread, element, .reply, author, nowMs))
                    }
                }
                for (element, named) in fresh {
                    notes += mention(named, thread: thread, comment: element, author: author, nowMs: nowMs, canOpen: canOpen, teams: teams,
                                     pending: notes)
                }
            case .typed(let thread, let element, let chars) where openers[thread] != nil:
                if (previews[element] ?? "").isEmpty {
                    previews[element] = String(String.UnicodeScalarView(chars.unicodeScalars.prefix(Self.previewScalars)))
                }
            case .mentioned(let thread, let element, let named) where openers[thread] != nil:
                notes += mention(named, thread: thread, comment: element, author: author, nowMs: nowMs, canOpen: canOpen, teams: teams,
                                 pending: notes)
            case .resolve(let thread, let value, let op) where openers[thread] != nil:
                let old = resolved[thread] ?? (false, .zero)
                guard old.op < op else { continue }
                resolved[thread] = (value, op)
                if value, !old.value, let opener = openers[thread], opener != author {
                    notes.append(notification(opener, thread, op, .resolved, author, nowMs))
                }
            case .elementWrite(let thread, let element, _, _, _, let value?, let op) where openers[thread] != nil:
                if (deleted[element]?.op ?? .zero) < op { deleted[element] = (value, op) }
            default:
                continue
            }
        }
        guard notify else { return [] }
        notifications += notes
        return notes
    }

    private func notification(_ account: String, _ thread: OpID, _ comment: OpID, _ kind: Notification.Kind, _ author: String,
                        _ nowMs: Int64) -> Notification {
        Notification(account: account, thread: thread, comment: comment, kind: kind, author: author, createdMs: nowMs)
    }

    private func mention(_ named: [String], thread: OpID, comment: OpID, author: String, nowMs: Int64, canOpen: (String) -> Bool,
                         teams: [String: [String]], pending: [Notification]) -> [Notification] {
        var recipients: [String] = []
        for value in named {
            let expanded = value.hasPrefix("team:") ? teams[String(value.dropFirst(5))] ?? [] : [value]
            for account in expanded where !recipients.contains(account) { recipients.append(account) }
        }
        return recipients.compactMap { account in
            guard account != author, canOpen(account) else { return nil }
            let recent = (notifications + pending).contains {
                $0.account == account && $0.comment == comment && $0.kind == .mention && $0.createdMs > nowMs - Self.day
            }
            return recent ? nil : notification(account, thread, comment, .mention, author, nowMs)
        }
    }

    // MARK: Reading (CommentGrpcService)

    /// Whether `comment` is recorded as deleted.
    public func isDeleted(_ comment: OpID) -> Bool { deleted[comment]?.value ?? false }

    /// Whether `thread` is recorded as resolved.
    public func isResolved(_ thread: OpID) -> Bool { resolved[thread]?.value ?? false }

    /// The recorded author of `comment`.
    public func author(of comment: OpID) -> String? { authors[comment] }

    /// `GetUnread` for `account`: per thread in creation order, the live comments by others past its
    /// mark, oldest first; threads with none are left out.
    public func unread(for account: String) -> [Unread] {
        let unseenMentions = Set(notifications.filter { $0.account == account && $0.kind == .mention && $0.seenMs == nil }.map(\.thread))
        return threadOrder.compactMap { thread in
            let mark = reads[account]?[thread]
            let comments = commentThread.filter { $0.value == thread }.map(\.key).sorted().filter { comment in
                !isDeleted(comment) && authors[comment] != account && mark.map { $0 < comment } ?? true
            }
            return comments.isEmpty ? nil : Unread(thread: thread, comments: comments, mentionsMe: unseenMentions.contains(thread))
        }
    }

    /// The toolbar count: every unread comment of `account`.
    public func unreadTotal(for account: String) -> Int {
        unread(for: account).reduce(0) { $0 + $1.comments.count }
    }

    /// `MarkRead`: raises `account`'s mark on `thread` to `through` (never lowers it) and marks the
    /// thread's notifications up to the mark seen (a resolve notification with any mark).
    public mutating func markRead(_ account: String, thread: OpID, through: OpID, nowMs: Int64) {
        var marks = reads[account, default: [:]]
        let mark = max(marks[thread] ?? .zero, through)
        marks[thread] = mark
        reads[account] = marks
        for index in notifications.indices where notifications[index].account == account && notifications[index].thread == thread
            && notifications[index].seenMs == nil && (notifications[index].kind == .resolved || !(mark < notifications[index].comment)) {
            notifications[index].seenMs = nowMs
        }
    }

    // MARK: The digest job (CommentDigestJob)

    /// One run at `nowMs`: the mails due, each mention marked mailed.  `live` says whether an
    /// account has a session on the document; `names` gives authors' display names.
    public mutating func digest(document: String, nowMs: Int64, delayMs: Int64 = 10 * 60 * 1_000, live: (String) -> Bool,
                                mailsOff: Set<String> = [], names: (String) -> String) -> [Mail] {
        var mails: [Mail] = []
        var order: [String] = []
        var due: [String: [Int]] = [:]
        for (index, note) in notifications.enumerated() where note.kind == .mention && note.seenMs == nil && note.emailedMs == nil
            && note.createdMs <= nowMs - delayMs && note.createdMs > nowMs - 7 * Self.day && !mailsOff.contains(note.account) {
            if due[note.account] == nil { order.append(note.account) }
            due[note.account, default: []].append(index)
        }
        for account in order where !live(account) {
            let indices = due[account]!
            mails.append(Mail(account: account, document: document, mentions: indices.map { index in
                let note = notifications[index]
                let opening = commentThread.filter { $0.value == note.thread }.map(\.key).min()
                let line = opening.flatMap { previews[$0] }?.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
                return Mail.Mention(author: names(note.author), openingLine: line,
                                    link: "wiretuner://doc/\(document)/thread/\(note.thread.counter)-\(note.thread.replica)")
            }))
            for index in indices { notifications[index].emailedMs = nowMs }
        }
        return mails
    }
}
