import Foundation
import WTCRDT
import WTGeometry
import WTProto

/// Building comment ops (COLLAB-026; docs/_includes/collaboration/comments.adoc, "Client"): every
/// command is one change and one undo step, and a comment's mention tags (`mention` marks over the
/// names) and its `mentions` set are written by the same change.
enum CommentEditing {
    /// The largest run of scalars one `TextInsert` carries (the op allows 64 KiB of UTF-8).
    static let chunk = 8_000

    static func requireThread(_ node: OpID, in state: EngineState) throws {
        guard CommentFields.isThread(node, in: state), state.store.isCreated(node) else { throw CommentError.notAThread(node) }
    }

    /// The live comment elements of `thread`, in order.
    static func comments(_ thread: OpID, in state: EngineState) -> [OpID] {
        state.liveElements(thread, CommentFields.comments)
    }

    static func requireComment(_ thread: OpID, _ comment: OpID, in state: EngineState) throws {
        try requireThread(thread, in: state)
        guard comments(thread, in: state).contains(comment) else { throw CommentError.unknownComment(comment) }
    }

    /// Appends `TextInsert`s of `scalars` into the body of `comment` between `left` and `right`,
    /// and returns the new characters' ids in order.
    static func insert(_ scalars: [Unicode.Scalar], thread: OpID, comment: OpID, left: OpID, right: OpID,
                       builder: inout ChangeBuilder) -> [OpID] {
        var ids: [OpID] = []
        var left = left
        var start = 0
        while start < scalars.count {
            let end = min(scalars.count, start + chunk)
            var string = String.UnicodeScalarView()
            string.append(contentsOf: scalars[start..<end])
            let first = builder.append(Ops.textInsert(thread, CommentFields.body(comment), String(string), left: left, right: right))
            for index in 0..<(end - start) {
                ids.append(OpID(counter: first.counter + UInt64(index), replica: first.replica))
            }
            left = ids[ids.count - 1]
            start = end
        }
        return ids
    }

    /// `TextDelete`s of `ids` (document order), one per run of consecutive counters of one replica.
    static func delete(_ ids: [OpID], thread: OpID, comment: OpID) -> [Wiretuner_Doc_V1_Op] {
        var ops: [Wiretuner_Doc_V1_Op] = []
        var index = 0
        while index < ids.count {
            let first = ids[index]
            var count: UInt64 = 1
            while index + Int(count) < ids.count, ids[index + Int(count)] == OpID(counter: first.counter + count, replica: first.replica) {
                count += 1
            }
            ops.append(Ops.textDelete(thread, CommentFields.body(comment), first: first, count: count))
            index += Int(count)
        }
        return ops
    }

    /// A `mention` mark over the characters `first` ... `last` (a tag never grows: its end is
    /// after the last character); an empty `account` clears the attribute there.
    static func mention(_ account: String, thread: OpID, comment: OpID, first: OpID, last: OpID) -> Wiretuner_Doc_V1_Op {
        var mark = Wiretuner_Doc_V1_TextMark()
        mark.node = thread.proto
        mark.text = CommentFields.body(comment).proto
        mark.start.char = first.elementID
        mark.start.before = true
        mark.end.char = last.elementID
        mark.value.mention = account
        var op = Wiretuner_Doc_V1_Op()
        op.textMark = mark
        return op
    }

    /// The comment element, its text, tags and mentions set of a new comment: `ElementInsert`
    /// after the thread's last element, then its body, its tags and its `mentions` members.
    @discardableResult
    static func post(_ body: CommentBody, author: String, at time: Date, thread: OpID, state: EngineState,
                     builder: inout ChangeBuilder) throws -> OpID {
        let last = state.store.elementOrder(thread, CommentFields.comments).last
            .flatMap { state.position(thread, CommentFields.comments, $0) }
        let position = try PathEditing.keys(between: last, and: nil, count: 1)[0]
        let values = CommentFields.commentValues {
            $0.authorAccountID = author
            $0.wallTimeMs = DocumentCore.milliseconds(time)
        }
        let comment = builder.append(Ops.elementInsert(thread, CommentFields.comments, positions: [position], values: values))
        let ids = insert(Array(body.text.unicodeScalars), thread: thread, comment: comment, left: .zero, right: .zero, builder: &builder)
        for tag in body.mentions {
            builder.append(mention(tag.account, thread: thread, comment: comment, first: ids[tag.range.lowerBound],
                                   last: ids[tag.range.upperBound - 1]))
        }
        let accounts = body.mentionedAccounts
        if !accounts.isEmpty {
            builder.append(Ops.setAdd(thread, CommentFields.mentions(comment), values: CommentFields.commentValues { $0.mentions = accounts }))
        }
        return comment
    }

    /// The pin number of `thread` (its place among every thread created), for labels.
    static func number(of thread: OpID, in state: EngineState) -> Int {
        (state.store.children(CommentFields.collection).filter { CommentFields.isThread($0, in: state) }.firstIndex(of: thread) ?? 0) + 1
    }
}

/// Starts a thread on an object or at a point (comments.adoc, "Adding a comment"): the thread node
/// under `comments (0:12)` with its pin fields and its opening comment.  With `anchor`, `point` is
/// in the anchored object's local space; without, pasteboard points.  `fallbackPoint` is the pin's
/// pasteboard position now and `page` the page it is on.  Label "Comment on <object>" or
/// "Comment".
public struct CreateThread: Command {
    public var anchor: OpID?
    public var point: Point
    public var fallbackPoint: Point
    public var page: OpID?
    public var author: String
    public var body: CommentBody
    public var postedAt: Date
    private let name: String?

    public var label: String { name.map { "Comment on \($0)" } ?? "Comment" }

    /// A thread at the pasteboard point `point` (a point pin), or on `anchor` with the pin at
    /// the pasteboard point `point` (converted into the object's local space from `state`).
    public init(at point: Point, on anchor: OpID? = nil, page: OpID? = nil, author: String, body: CommentBody,
                postedAt: Date = Date(), in state: EngineState) {
        self.anchor = anchor
        fallbackPoint = point
        if let anchor {
            let transform = Objects.pasteboardTransform(of: anchor, in: state)
            self.point = transform.inverted().map { $0.apply(point) } ?? point
            name = CommentThreadModel.objectName(anchor, in: state)
        } else {
            self.point = point
            name = nil
        }
        self.page = page
        self.author = author
        self.body = body
        self.postedAt = postedAt
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !author.isEmpty else { throw CommentError.noAuthor }
        try body.validate()
        let values = CommentFields.values { thread in
            if let anchor { thread.anchor = CommentFields.ref(anchor) }
            thread.point = CommentFields.point(point)
            thread.fallbackPoint = CommentFields.point(fallbackPoint)
            if let page { thread.page = CommentFields.ref(page) }
        }
        let position = try PathEditing.topPosition(in: CommentFields.collection, state: state)
        let thread = builder.append(Ops.create(parent: CommentFields.collection, position: position, props: values))
        try CommentEditing.post(body, author: author, at: postedAt, thread: thread, state: state, builder: &builder)
    }
}

/// Posts a reply at the end of a thread (comments.adoc, "Adding a comment").  Replying to a
/// resolved thread does not reopen it.  Label "Reply to <name>" (`recipient`, the opener's
/// display name) or "Reply".
public struct Reply: Command {
    public var thread: OpID
    public var author: String
    public var body: CommentBody
    public var postedAt: Date
    public var recipient: String?

    public var label: String { recipient.map { "Reply to \($0)" } ?? "Reply" }

    public init(to thread: OpID, author: String, body: CommentBody, postedAt: Date = Date(), recipient: String? = nil) {
        self.thread = thread
        self.author = author
        self.body = body
        self.postedAt = postedAt
        self.recipient = recipient
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !author.isEmpty else { throw CommentError.noAuthor }
        try body.validate()
        try CommentEditing.requireThread(thread, in: state)
        try CommentEditing.post(body, author: author, at: postedAt, thread: thread, state: state, builder: &builder)
    }
}

/// Rewrites a comment's text (comments.adoc, "Editing and deleting your comments"): the
/// characters that changed between the common prefix and suffix are deleted and typed, tags that
/// no longer stand are cleared, new ones marked, the `mentions` set brought in line, and
/// `edited_wall_time_ms` written.  Nothing is written when the text and tags are unchanged.
/// Label "Edit Comment".
public struct EditComment: Command {
    public var thread: OpID
    public var comment: OpID
    public var body: CommentBody
    public var editedAt: Date
    public var label: String { "Edit Comment" }

    public init(thread: OpID, comment: OpID, body: CommentBody, editedAt: Date = Date()) {
        self.thread = thread
        self.comment = comment
        self.body = body
        self.editedAt = editedAt
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try body.validate()
        try CommentEditing.requireComment(thread, comment, in: state)
        let path = CommentFields.body(comment)
        let sequence = state.text(thread, path) ?? TextSequence()
        let oldIDs = sequence.liveChars
        let oldScalars = oldIDs.map { Unicode.Scalar(sequence.codepoint($0)!)! }
        let newScalars = Array(body.text.unicodeScalars)
        var prefix = 0
        while prefix < oldScalars.count, prefix < newScalars.count, oldScalars[prefix] == newScalars[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldScalars.count - prefix, suffix < newScalars.count - prefix,
              oldScalars[oldScalars.count - 1 - suffix] == newScalars[newScalars.count - 1 - suffix] {
            suffix += 1
        }
        let removed = Array(oldIDs[prefix..<(oldIDs.count - suffix)])
        let typed = Array(newScalars[prefix..<(newScalars.count - suffix)])
        // The tags and the mentions set, read from the text and the set.
        let oldEntry = CommentThreadModel.entry(thread, comment, Wiretuner_Doc_V1_Comment(), state: state, members: nil)
        let origins = state.insertionOrigins(thread, path, at: prefix, stableSeq: 0)
        var inserted: [OpID] = []
        for op in CommentEditing.delete(removed, thread: thread, comment: comment) {
            builder.append(op)
        }
        if !typed.isEmpty {
            inserted = CommentEditing.insert(typed, thread: thread, comment: comment, left: origins.left, right: origins.right,
                                             builder: &builder)
        }
        let newIDs = Array(oldIDs[..<prefix]) + inserted + Array(oldIDs[(oldIDs.count - suffix)...])
        // Tags: an old tag whose account and characters the new body keeps stands; the rest are
        // cleared, and new ones marked.
        var kept: Set<CommentBody.Mention> = []
        for tag in oldEntry.mentionTags {
            let chars = Array(oldIDs[tag.range])
            if let same = body.mentions.first(where: { $0.account == tag.account && Array(newIDs[$0.range]) == chars }) {
                kept.insert(same)
            } else {
                builder.append(CommentEditing.mention("", thread: thread, comment: comment, first: chars[0], last: chars[chars.count - 1]))
            }
        }
        for tag in body.mentions where !kept.contains(tag) {
            builder.append(CommentEditing.mention(tag.account, thread: thread, comment: comment, first: newIDs[tag.range.lowerBound],
                                                  last: newIDs[tag.range.upperBound - 1]))
        }
        let before = Set(oldEntry.mentions)
        let after = body.mentionedAccounts
        let added = after.filter { !before.contains($0) }
        let dropped = oldEntry.mentions.filter { !after.contains($0) }
        if !added.isEmpty {
            builder.append(Ops.setAdd(thread, CommentFields.mentions(comment), values: CommentFields.commentValues { $0.mentions = added }))
        }
        if !dropped.isEmpty {
            builder.append(Ops.setRemove(thread, CommentFields.mentions(comment), values: CommentFields.commentValues { $0.mentions = dropped }))
        }
        guard !builder.ops.isEmpty else { return }
        builder.append(Ops.set(thread, [CommentFields.editedTime(comment)],
                               values: CommentFields.commentValues { $0.editedWallTimeMs = DocumentCore.milliseconds(editedAt) }))
    }
}

/// Deletes a comment (its `deleted` register; comments.adoc, "Editing and deleting your
/// comments").  A deleted reply leaves the thread; a deleted opener with live replies stays at the
/// head as "Comment deleted"; the opener of a thread without live replies deletes the thread as
/// well (`SetDeleted`).  Label "Delete Comment", or "Delete Thread" for the last case.
public struct DeleteComment: Command {
    public var thread: OpID
    public var comment: OpID
    private let deletesThread: Bool

    public var label: String { deletesThread ? "Delete Thread" : "Delete Comment" }

    public init(thread: OpID, comment: OpID, in state: EngineState) {
        self.thread = thread
        self.comment = comment
        deletesThread = Self.deletesThread(thread, comment, state)
    }

    static func deletesThread(_ thread: OpID, _ comment: OpID, _ state: EngineState) -> Bool {
        let ids = CommentEditing.comments(thread, in: state)
        guard ids.first == comment else { return false }
        let props = state.props(thread).commentThread.comments
        return !props.dropFirst().contains { !$0.deleted }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try CommentEditing.requireComment(thread, comment, in: state)
        builder.append(Ops.set(thread, [CommentFields.deleted(comment)], values: CommentFields.commentValues { $0.deleted = true }))
        if Self.deletesThread(thread, comment, state) {
            builder.append(Ops.setDeleted(thread))
        }
    }
}

/// The owner's *Delete Thread* (comments.adoc, "The Comments panel"): every comment's `deleted`
/// and the thread node's, so the thread is gone whatever replies it held.  Label "Delete Thread".
public struct DeleteThread: Command {
    public var thread: OpID
    public var label: String { "Delete Thread" }

    public init(_ thread: OpID) {
        self.thread = thread
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try CommentEditing.requireThread(thread, in: state)
        for comment in CommentEditing.comments(thread, in: state) {
            builder.append(Ops.set(thread, [CommentFields.deleted(comment)], values: CommentFields.commentValues { $0.deleted = true }))
        }
        builder.append(Ops.setDeleted(thread))
    }
}

/// Resolves or reopens a thread (comments.adoc, "Resolving a thread"): the `resolved` register,
/// last writer wins.  Nothing is written when it already holds the value.  Label "Resolve thread N"
/// or "Reopen thread N".
public struct SetResolved: Command {
    public var thread: OpID
    public var resolved: Bool
    private let number: Int

    public var label: String { "\(resolved ? "Resolve" : "Reopen") thread \(number)" }

    public init(_ thread: OpID, resolved: Bool, in state: EngineState) {
        self.thread = thread
        self.resolved = resolved
        number = CommentEditing.number(of: thread, in: state)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try CommentEditing.requireThread(thread, in: state)
        guard state.props(thread).commentThread.resolved != resolved else { return }
        builder.append(Ops.set(thread, [CommentFields.resolved], values: CommentFields.values { $0.resolved = resolved }))
    }
}

/// Drops a pin (comments.adoc, "Adding a comment": dragging a pin): `anchor`, `point`,
/// `fallback_point` and `page` in one `SetFields`, so two people dragging one pin end with one
/// person's drop, never a mix.  `point` is the pasteboard drop point, converted into the new
/// anchor's local space; no anchor makes a point pin.  Label "Move Pin".
public struct MovePin: Command {
    public var thread: OpID
    public var anchor: OpID?
    public var point: Point
    public var fallbackPoint: Point
    public var page: OpID?
    public var label: String { "Move Pin" }

    public init(_ thread: OpID, to point: Point, on anchor: OpID? = nil, page: OpID? = nil, in state: EngineState) {
        self.thread = thread
        self.anchor = anchor
        fallbackPoint = point
        if let anchor {
            self.point = Objects.pasteboardTransform(of: anchor, in: state).inverted().map { $0.apply(point) } ?? point
        } else {
            self.point = point
        }
        self.page = page
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try CommentEditing.requireThread(thread, in: state)
        let values = CommentFields.values { thread in
            if let anchor { thread.anchor = CommentFields.ref(anchor) }
            thread.point = CommentFields.point(point)
            thread.fallbackPoint = CommentFields.point(fallbackPoint)
            if let page { thread.page = CommentFields.ref(page) }
        }
        builder.append(Ops.set(thread, [CommentFields.anchor, CommentFields.point, CommentFields.fallbackPoint, CommentFields.page],
                               values: values))
    }
}

/// Adds or takes back one of the six reactions (comments.adoc, "Reactions"): a `SetAdd` or
/// `SetRemove` of `<account>:<emoji>` (add-wins).  `adding` nil toggles.  A client removes only
/// its own members.  Nothing is written when the member is already as asked.  Label "React" or
/// "Remove Reaction".
public struct React: Command {
    public var thread: OpID
    public var comment: OpID
    public var account: String
    public var emoji: String
    public var adding: Bool?
    private let resolvedAdding: Bool

    public var label: String { resolvedAdding ? "React" : "Remove Reaction" }

    public init(thread: OpID, comment: OpID, account: String, emoji: String, adding: Bool? = nil, in state: EngineState) {
        self.thread = thread
        self.comment = comment
        self.account = account
        self.emoji = emoji
        self.adding = adding
        resolvedAdding = adding ?? !Self.present(thread, comment, CommentReactions.member(account: account, emoji: emoji), state)
    }

    static func present(_ thread: OpID, _ comment: OpID, _ member: String, _ state: EngineState) -> Bool {
        !state.store.liveTags(thread, CommentFields.reactions(comment), Array(member.utf8)).isEmpty
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !account.isEmpty else { throw CommentError.noAuthor }
        guard CommentFields.reactionEmoji.contains(emoji) else { throw CommentError.invalidReaction(emoji) }
        try CommentEditing.requireComment(thread, comment, in: state)
        let member = CommentReactions.member(account: account, emoji: emoji)
        let add = adding ?? !Self.present(thread, comment, member, state)
        guard add != Self.present(thread, comment, member, state) else { return }
        let values = CommentFields.commentValues { $0.reactions = [member] }
        builder.append(add ? Ops.setAdd(thread, CommentFields.reactions(comment), values: values)
                           : Ops.setRemove(thread, CommentFields.reactions(comment), values: values))
    }
}
