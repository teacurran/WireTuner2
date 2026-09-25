import Foundation
import WTCRDT
import WTGeometry
import WTProto

/// The register paths of comment threads (`NodeProps.comment_thread = 210`, `CommentThreadProps`
/// in comments.proto; docs/_includes/collaboration/comments.adoc, "Data model").  Threads are
/// children of the well-known collection `comments (0:12)`; each comment is an element of the
/// thread's `comments` SEQUENCE with its own registers, TEXT body and SET fields.
public enum CommentFields {
    /// `NodeProps.comment_thread`.
    public static let kind: UInt32 = 210
    /// The well-known collection holding every thread.
    public static let collection = OpID.wellKnown(12)
    /// `CommentThreadProps.anchor` (a `NodeRef`, REF_FALLBACK_UNSET).
    public static let anchor = RegisterPath([210, 2])
    /// `CommentThreadProps.point` (ATOMIC).
    public static let point = RegisterPath([210, 3])
    /// `CommentThreadProps.fallback_point` (ATOMIC).
    public static let fallbackPoint = RegisterPath([210, 4])
    /// `CommentThreadProps.page` (a `NodeRef`).
    public static let page = RegisterPath([210, 5])
    /// `CommentThreadProps.resolved`.
    public static let resolved = RegisterPath([210, 6])
    /// `CommentThreadProps.comments` (SEQUENCE).
    public static let comments = RegisterPath([210, 7])

    /// The element path of comment `comment`.
    public static func comment(_ comment: OpID) -> RegisterPath { comments.element(comment) }
    /// `Comment.author_account_id` of `comment`.
    public static func author(_ comment: OpID) -> RegisterPath { comments.element(comment).child(2) }
    /// `Comment.body` of `comment` (TEXT).
    public static func body(_ comment: OpID) -> RegisterPath { comments.element(comment).child(3) }
    /// `Comment.wall_time_ms` of `comment`.
    public static func wallTime(_ comment: OpID) -> RegisterPath { comments.element(comment).child(4) }
    /// `Comment.edited_wall_time_ms` of `comment`.
    public static func editedTime(_ comment: OpID) -> RegisterPath { comments.element(comment).child(5) }
    /// `Comment.mentions` of `comment` (SET).
    public static func mentions(_ comment: OpID) -> RegisterPath { comments.element(comment).child(6) }
    /// `Comment.reactions` of `comment` (SET).
    public static func reactions(_ comment: OpID) -> RegisterPath { comments.element(comment).child(7) }
    /// `Comment.deleted` of `comment`.
    public static func deleted(_ comment: OpID) -> RegisterPath { comments.element(comment).child(8) }

    /// The six reactions the guide allows (comments.adoc, "Reactions").
    public static let reactionEmoji = ["👍", "❤️", "👀", "✅", "❓", "🎉"]
    /// The prefix of a whole-team mention: `team:<team id>`.
    public static let teamPrefix = "team:"

    /// Whether `node` is a comment thread.
    public static func isThread(_ node: OpID, in state: EngineState) -> Bool {
        state.store.kind(node) == kind
    }

    /// Sparse `NodeProps` holding `thread` at `comment_thread`.
    static func values(_ build: (inout Wiretuner_Doc_V1_CommentThreadProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var thread = Wiretuner_Doc_V1_CommentThreadProps()
        build(&thread)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.commentThread = thread
        return props
    }

    /// Sparse `NodeProps` holding one comment element at `comments` (element segments are
    /// transparent in values).
    static func commentValues(_ build: (inout Wiretuner_Doc_V1_Comment) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var comment = Wiretuner_Doc_V1_Comment()
        build(&comment)
        return values { $0.comments = [comment] }
    }

    static func point(_ point: Point) -> Wiretuner_Doc_V1_Point {
        var value = Wiretuner_Doc_V1_Point()
        value.x = point.x
        value.y = point.y
        return value
    }

    static func ref(_ node: OpID) -> Wiretuner_Doc_V1_NodeRef {
        var ref = Wiretuner_Doc_V1_NodeRef()
        ref.id = node.proto
        return ref
    }
}

/// A comment's text as the composer hands it over: plain text with line breaks and the mentions
/// placed in it (comments.adoc, "Mentioning people").  Offsets are Unicode scalars.
public struct CommentBody: Hashable, Sendable {
    /// One `@` tag: the characters it covers and the account id or `team:<id>` it names.
    public struct Mention: Hashable, Sendable {
        public var range: Range<Int>
        public var account: String

        public init(range: Range<Int>, account: String) {
            self.range = range
            self.account = account
        }
    }

    public var text: String
    public var mentions: [Mention]

    public init(_ text: String, mentions: [Mention] = []) {
        self.text = text
        self.mentions = mentions
    }

    /// The accounts mentioned, each once, in order of first mention: the `mentions` set.
    public var mentionedAccounts: [String] {
        var seen: Set<String> = []
        return mentions.compactMap { seen.insert($0.account).inserted ? $0.account : nil }
    }

    /// Throws unless the text holds something besides whitespace and every mention lies inside
    /// it, names someone and does not overlap another.
    func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CommentError.emptyBody }
        let count = text.unicodeScalars.count
        var end = 0
        for mention in mentions.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard !mention.account.isEmpty, !mention.range.isEmpty, mention.range.lowerBound >= end,
                  mention.range.upperBound <= count else { throw CommentError.invalidMention(mention.account) }
            end = mention.range.upperBound
        }
    }
}

/// Why a comment command refused to build its change.  Thrown before anything is appended.
public enum CommentError: Error, Hashable, Sendable {
    /// The text is empty or whitespace.
    case emptyBody
    /// A mention is out of the text, empty, overlapping, or names nobody.
    case invalidMention(String)
    /// The node is not a comment thread.
    case notAThread(OpID)
    /// The thread holds no such comment.
    case unknownComment(OpID)
    /// The author (or reacting account) is empty.
    case noAuthor
    /// A reaction outside the six allowed.
    case invalidReaction(String)
}

/// One comment as read from the merged state.
public struct CommentEntry: Hashable, Sendable {
    /// One reaction: who and which of the six.
    public struct Reaction: Hashable, Sendable, Comparable {
        public var account: String
        public var emoji: String

        public static func < (lhs: Reaction, rhs: Reaction) -> Bool {
            (lhs.emoji, lhs.account) < (rhs.emoji, rhs.account)
        }
    }

    /// The element id.
    public let id: OpID
    public let author: String
    public let text: String
    /// The `mentions` set (the authoritative list), sorted.
    public let mentions: [String]
    /// The mention tags in the text, to draw as tags; a tag naming an account without access is
    /// left out (drawn as plain text).
    public let mentionTags: [CommentBody.Mention]
    /// The reactions to draw, sorted by emoji then account: members outside the six or of an
    /// account without access are left out.
    public let reactions: [Reaction]
    /// When posted and last edited, Unix milliseconds (0: never edited).
    public let wallTimeMs: Int64
    public let editedWallTimeMs: Int64
    /// The soft delete.
    public let deleted: Bool

    /// Whether the comment shows _edited_.
    public var isEdited: Bool { editedWallTimeMs != 0 }

    /// The body with its tags, as the composer takes it for *Edit*.
    public var body: CommentBody { CommentBody(text, mentions: mentionTags) }

    /// The reactions grouped: each emoji with the accounts that chose it, in the guide's order.
    public var reactionCounts: [(emoji: String, accounts: [String])] {
        CommentFields.reactionEmoji.compactMap { emoji in
            let accounts = reactions.filter { $0.emoji == emoji }.map(\.account)
            return accounts.isEmpty ? nil : (emoji, accounts)
        }
    }
}

/// One thread as the pins and the panel show it (comments.adoc, "Pins and threads").
public struct CommentThread: Hashable, Sendable, Identifiable {
    /// What the pin is attached to.
    public enum Anchoring: Hashable, Sendable {
        /// A point pin at `point` (pasteboard).
        case point
        /// Attached to a live object.
        case object(OpID)
        /// Attached to an object that is deleted: the pin is not drawn; the panel names it with
        /// "(deleted)"; restoring the object brings the pin back.
        case deleted(OpID)
        /// Attached to an object this state does not know (compacted out): the pin is drawn at
        /// `fallback_point` and the panel names no object.
        case compacted(OpID)
    }

    public let id: OpID
    /// The pin number: the thread's place among every thread ever created, from 1.
    public let number: Int
    public let anchoring: Anchoring
    /// Where the pin is drawn (pasteboard); nil when it is not drawn (a deleted anchor).
    public let pin: Point?
    /// The page the pin is on; nil on the pasteboard.
    public let page: OpID?
    /// The anchored object's name for the panel: its `CommonProps.name` (or kind) with
    /// " (deleted)" for a deleted anchor; nil for point pins and compacted anchors.
    public let anchorName: String?
    public let resolved: Bool
    /// Every live comment in thread order, the opener first; a deleted opener stays in place
    /// (the panel shows "Comment deleted"); deleted replies are left out.
    public let comments: [CommentEntry]
    /// Comments in the unread overlay (`CommentThreadModel(unread:)`).
    public let unreadCount: Int

    /// The opening comment.
    public var opener: CommentEntry { comments[0] }
    /// Whether the opening comment was deleted and replies keep the thread.
    public var openerDeleted: Bool { opener.deleted }
    /// The replies, in order.
    public var replies: ArraySlice<CommentEntry> { comments.dropFirst() }
    /// The newest post or edit, Unix milliseconds: the panel's sort key.
    public var lastActivityMs: Int64 { comments.reduce(0) { max($0, $1.wallTimeMs, $1.editedWallTimeMs) } }
    /// The first line of the opening comment ("" for a deleted opener).
    public var firstLine: String {
        openerDeleted ? "" : String(opener.text.prefix { $0 != "\n" })
    }
    /// Everyone who started or replied to the thread.
    public var participants: Set<String> { Set(comments.filter { !$0.deleted }.map(\.author)) }

    /// Whether `account` (or a team in `teams`) is mentioned in a live comment of the thread.
    public func mentions(_ account: String, teams: Set<String> = []) -> Bool {
        let prefix = CommentFields.teamPrefix
        return comments.contains { comment in
            !comment.deleted && comment.mentions.contains { member in
                member == account || (member.hasPrefix(prefix) && teams.contains(String(member.dropFirst(prefix.count))))
            }
        }
    }

    /// Whether a live comment's text contains `query`, ignoring case.
    public func matches(_ query: String) -> Bool {
        query.isEmpty || comments.contains { !$0.deleted && $0.text.localizedCaseInsensitiveContains(query) }
    }
}

/// Every thread of a document with resolved pin positions (COLLAB-026; comments.adoc, "Client"):
/// what the pin layer, the panel and the tool read.  Built from the merged state; nothing here
/// writes, and the pin of an anchored thread follows the object because it is computed from the
/// object's current transform (`anchor`'s pasteboard transform applied to `point`).
///
/// Read-time normalizations (comments.adoc, "Merge semantics"): a deleted thread with a live
/// reply after its opener is shown with a deleted opener; a thread with no live comment, or a
/// deleted one with none, is not shown; reactions outside the six, and reactions or mention tags
/// of accounts not in `members`, are not drawn.
public struct CommentThreadModel: Sendable {
    /// Every visible thread, in creation order.
    public let threads: [CommentThread]

    /// The threads of `state`.  `pages` groups pins by page (the state's own page list when nil);
    /// `members` are the accounts with access (nil: do not filter); `unread` maps a thread to the
    /// comment ids its reader has not seen.
    public init(_ state: EngineState, pages: PageList? = nil, members: Set<String>? = nil, unread: [OpID: Set<OpID>] = [:]) {
        let pages = pages ?? PageList(state)
        var threads: [CommentThread] = []
        var number = 0
        for node in state.store.children(CommentFields.collection) where CommentFields.isThread(node, in: state) {
            number += 1
            if let thread = Self.thread(node, number: number, state: state, pages: pages, members: members, unread: unread[node] ?? []) {
                threads.append(thread)
            }
        }
        self.threads = threads
    }

    /// The thread `id`, when visible.
    public subscript(id: OpID) -> CommentThread? {
        threads.first { $0.id == id }
    }

    /// The threads the panel lists first: newest activity first.
    public var byActivity: [CommentThread] {
        threads.sorted { ($0.lastActivityMs, $0.number) > ($1.lastActivityMs, $1.number) }
    }

    /// Threads grouped by the page their pin is on; the key nil is the pasteboard.
    public var byPage: [OpID?: [CommentThread]] {
        Dictionary(grouping: threads, by: \.page)
    }

    /// The open threads whose pins are drawn (the resolved ones too with `showResolved`).
    public func pins(showResolved: Bool = false) -> [CommentThread] {
        threads.filter { $0.pin != nil && (showResolved || !$0.resolved) }
    }

    /// The unread comments over every thread (the toolbar count).
    public var unreadTotal: Int { threads.reduce(0) { $0 + $1.unreadCount } }

    // MARK: Reading

    static func thread(_ node: OpID, number: Int, state: EngineState, pages: PageList, members: Set<String>?,
                       unread: Set<OpID>) -> CommentThread? {
        let props = state.props(node).commentThread
        let threadDeleted = state.store.deleted(node)?.current.value == true
        var entries = props.comments.map { comment in
            entry(node, OpID(counter: comment.id.counter, replica: comment.id.replica), comment, state: state, members: members)
        }
        // The opener keeps its place when deleted; deleted replies are dropped.
        guard let first = entries.first else { return nil }
        entries = [first] + entries.dropFirst().filter { !$0.deleted }
        let hasLiveReply = entries.count > 1
        if first.deleted && !hasLiveReply { return nil }
        if threadDeleted && !hasLiveReply { return nil }
        let point = Point(x: props.point.x, y: props.point.y)
        let fallback = props.hasFallbackPoint ? Point(x: props.fallbackPoint.x, y: props.fallbackPoint.y) : point
        let storedPage = props.hasPage ? OpID(props.page.id) : nil
        let livePage = storedPage.flatMap { pages[$0] != nil ? $0 : nil }
        var anchoring = CommentThread.Anchoring.point
        var pin: Point? = point
        var page: OpID? = livePage ?? pages.page(containing: point)?.id
        var anchorName: String?
        if props.hasAnchor, OpID(props.anchor.id) != .zero {
            let anchor = OpID(props.anchor.id)
            if !state.store.isCreated(anchor) {
                anchoring = .compacted(anchor)
                pin = fallback
                page = livePage ?? pages.page(containing: fallback)?.id
            } else if !isShown(anchor, in: state) {
                anchoring = .deleted(anchor)
                pin = nil
                page = livePage
                anchorName = objectName(anchor, in: state) + " (deleted)"
            } else {
                anchoring = .object(anchor)
                let position = Objects.pasteboardTransform(of: anchor, in: state).apply(point)
                pin = position
                let top = topLevel(anchor, in: state)
                page = Objects.bounds(of: top, in: state).flatMap(pages.page(ofBounds:))?.id ?? pages.page(containing: position)?.id
                anchorName = objectName(anchor, in: state)
            }
        }
        let unreadCount = entries.filter { !$0.deleted && unread.contains($0.id) }.count
        return CommentThread(id: node, number: number, anchoring: anchoring, pin: pin, page: page, anchorName: anchorName,
                             resolved: props.resolved, comments: entries, unreadCount: unreadCount)
    }

    static func entry(_ node: OpID, _ id: OpID, _ comment: Wiretuner_Doc_V1_Comment, state: EngineState,
                      members: Set<String>?) -> CommentEntry {
        let text = state.text(node, CommentFields.body(id)) ?? TextSequence()
        let allowed = { (account: String) in members.map { $0.contains(account) || account.hasPrefix(CommentFields.teamPrefix) } ?? true }
        var tags: [CommentBody.Mention] = []
        for run in text.runs {
            for attribute in run.attributes {
                guard let value = try? Wiretuner_Doc_V1_TextMarkValue(serializedBytes: attribute.value),
                      case .mention(let account)? = value.value, !account.isEmpty, allowed(account) else { continue }
                if let last = tags.last, last.account == account, last.range.upperBound == run.start {
                    tags[tags.count - 1].range = last.range.lowerBound..<(run.start + run.length)
                } else {
                    tags.append(CommentBody.Mention(range: run.start..<(run.start + run.length), account: account))
                }
            }
        }
        let reactions = state.store.members(node, CommentFields.reactions(id)).compactMap { member -> CommentEntry.Reaction? in
            guard let reaction = CommentReactions.parse(String(decoding: member, as: UTF8.self)), allowed(reaction.account) else { return nil }
            return reaction
        }
        let mentions = state.store.members(node, CommentFields.mentions(id)).map { String(decoding: $0, as: UTF8.self) }
        return CommentEntry(id: id, author: comment.authorAccountID, text: text.string, mentions: mentions.sorted(),
                            mentionTags: tags, reactions: reactions.sorted(), wallTimeMs: comment.wallTimeMs,
                            editedWallTimeMs: comment.editedWallTimeMs, deleted: comment.deleted)
    }

    /// Whether `node` and every ancestor are live (a node under a deleted group is not shown).
    static func isShown(_ node: OpID, in state: EngineState) -> Bool {
        var current: OpID? = node
        var steps = 0
        while let id = current, id != WellKnown.document, steps < 10_000 {
            if state.store.deleted(id)?.current.value == true { return false }
            current = state.store.placement(id)?.parent
            steps += 1
        }
        return true
    }

    /// The object directly on a layer that holds `node`.
    static func topLevel(_ node: OpID, in state: EngineState) -> OpID {
        var current = node
        var steps = 0
        while let parent = state.store.placement(current)?.parent, state.nodeKind(parent) != .layer,
              parent != WellKnown.layers, parent != WellKnown.document, steps < 10_000 {
            current = parent
            steps += 1
        }
        return current
    }

    /// The name the panel and the change labels give `node`: its `CommonProps.name`, or its kind.
    static func objectName(_ node: OpID, in state: EngineState) -> String {
        if let name = NodeValues.common(state.props(node))?.name, !name.isEmpty { return name }
        return state.nodeKind(node).flatMap { kindNames[$0] } ?? "Object"
    }

    static let kindNames: [NodeKind: String] = [
        .path: "Path", .rect: "Rectangle", .ellipse: "Ellipse", .polygon: "Polygon", .text: "Text", .group: "Group",
        .instance: "Symbol Instance", .layer: "Layer", .chart: "Chart", .connector: "Connector", .barcode: "Barcode",
        .placedFile: "Placed File", .blend: "Blend", .extrude: "Extrusion", .image: "Image", .svgAnimation: "SVG Animation",
    ]
}

/// Reaction members: `<account id>:<emoji>`.
public enum CommentReactions {
    /// The member string of `account`'s `emoji`.
    public static func member(account: String, emoji: String) -> String { "\(account):\(emoji)" }

    /// The reaction a member names, or nil for a malformed one or an emoji outside the six.
    public static func parse(_ member: String) -> CommentEntry.Reaction? {
        guard let colon = member.lastIndex(of: ":") else { return nil }
        let account = String(member[..<colon])
        let emoji = String(member[member.index(after: colon)...])
        guard !account.isEmpty, CommentFields.reactionEmoji.contains(emoji) else { return nil }
        return CommentEntry.Reaction(account: account, emoji: emoji)
    }
}
