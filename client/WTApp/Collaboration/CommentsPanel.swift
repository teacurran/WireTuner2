import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel

/// What the Comments panel lists (comments.adoc, "The Comments panel"): by state, page, person
/// and *Mentions me*, narrowed by the search field; newest activity first.
struct CommentFilter: Equatable {
    enum State: String, CaseIterable, Identifiable {
        case open, resolved, all
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum Place: Hashable {
        case everywhere
        case thisPage
        case page(OpID)
        case pasteboard
    }

    var state = State.open
    var place = Place.everywhere
    /// An account: threads it started or replied to.
    var person: String?
    var mentionsMe = false
    var search = ""

    /// The threads of `model` that pass, newest activity first.  `activePage` resolves *This page*.
    func apply(_ model: CommentThreadModel, account: String, members: [CommentMember], activePage: OpID? = nil) -> [CommentThread] {
        let teams = Set(members.filter(\.isTeam).map { String($0.id.dropFirst(CommentFields.teamPrefix.count)) })
        return model.byActivity.filter { thread in
            switch state {
            case .open: if thread.resolved { return false }
            case .resolved: if !thread.resolved { return false }
            case .all: break
            }
            switch place {
            case .everywhere: break
            case .thisPage: if thread.page == nil || thread.page != activePage { return false }
            case .page(let page): if thread.page != page { return false }
            case .pasteboard: if thread.page != nil { return false }
            }
            if let person, !thread.participants.contains(person) { return false }
            if mentionsMe, !thread.mentions(account, teams: teams) { return false }
            return thread.matches(search)
        }
    }
}

/// The Comments panel's app-wide state: the front window it follows and a revision its body reads.
@MainActor
@Observable
final class CommentsPanelState {
    private(set) var revision = 0
    @ObservationIgnored var window: @MainActor () -> DocumentWindowController? = { nil }
    @ObservationIgnored var comments: @MainActor (DocumentWindowController) -> WindowComments? = { _ in nil }

    init() {}

    func touch() { revision += 1 }

    var front: WindowComments? { window().flatMap(comments) }
}

/// The Comments panel (COLLAB-029): filters, search, one row per thread with its pin number,
/// first line, author, replies, last activity and unread dot; select to scroll to the pin and
/// open the thread, double-click to zoom; the row menu's Resolve, Reopen, Copy Link and the
/// owner's Delete Thread.
enum CommentsPanel {
    @MainActor
    static func descriptor(state: CommentsPanelState) -> PanelDescriptor {
        PanelDescriptor(id: CommentsFeatures.panelID, title: "Comments", icon: "text.bubble", defaultGroup: CommentsFeatures.panelGroup, menuOrder: 72,
                        helpSlug: "comments") {
            CommentsPanelBody(state: state)
        }
    }

    /// One row as the panel shows it.
    struct Row: Identifiable, Equatable {
        let id: OpID
        let number: Int
        let firstLine: String
        let author: String
        let replies: Int
        let activity: String
        let unread: Bool
        let resolved: Bool
    }

    @MainActor
    static func rows(_ comments: WindowComments) -> [Row] {
        comments.filter.apply(comments.model, account: comments.account, members: comments.members, activePage: comments.document.activePageID).map { thread in
            Row(id: thread.id, number: thread.number, firstLine: thread.openerDeleted ? "Comment deleted" : thread.firstLine,
                author: comments.name(of: thread.opener.author), replies: thread.replies.filter { !$0.deleted }.count,
                activity: ThreadViewModel.time(thread.lastActivityMs), unread: thread.unreadCount > 0, resolved: thread.resolved)
        }
    }

    /// The page popup's choices: everywhere, this page, each page by name, the pasteboard.
    @MainActor
    static func places(_ comments: WindowComments) -> [(CommentFilter.Place, String)] {
        [(.everywhere, "Everywhere"), (.thisPage, "This page")] + comments.document.pageList.pages.map { (.page($0.id), $0.name) } + [(.pasteboard, "Pasteboard")]
    }

    /// The person popup's choices: everyone, then each participant.
    @MainActor
    static func people(_ comments: WindowComments) -> [(String?, String)] {
        let accounts = Set(comments.model.threads.flatMap(\.participants)).sorted()
        return [(nil, "Everyone")] + accounts.map { ($0, comments.name(of: $0)) }
    }

    @MainActor
    static func menu(_ comments: WindowComments, row: Row) -> [(String, @MainActor () -> Void)] {
        guard let thread = comments.model[row.id] else { return [] }
        var items: [(String, @MainActor () -> Void)] = []
        if comments.permissions.canResolve(thread) {
            items.append((thread.resolved ? "Reopen" : "Resolve", { comments.setResolved(row.id, !thread.resolved) }))
        }
        items.append(("Copy Link", { comments.copyLink(row.id) }))
        if comments.permissions.canDeleteThreads { items.append(("Delete Thread", { comments.deleteThread(row.id) })) }
        return items
    }

    @MainActor
    static func binding<Value>(_ comments: WindowComments, _ keyPath: WritableKeyPath<CommentFilter, Value>) -> Binding<Value> {
        Binding(get: { comments.filter[keyPath: keyPath] }, set: { value in
            comments.filter[keyPath: keyPath] = value
            comments.setNeedsDisplay()
        })
    }

    @MainActor
    static func select(_ comments: WindowComments, _ id: OpID, zoom: Bool) -> () -> Void { { comments.show(id, zoom: zoom) } }
}

struct CommentsPanelBody: View {
    let state: CommentsPanelState

    var body: some View {
        let _ = state.revision
        if let comments = state.front {
            CommentsPanelContent(comments: comments)
        } else {
            Text("Open a document to see its comments.").font(.callout).foregroundStyle(.secondary).padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct CommentsPanelContent: View {
    let comments: WindowComments

    var body: some View {
        let _ = comments.revision
        let rows = CommentsPanel.rows(comments)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: CommentsPanel.binding(comments, \.state)) {
                    ForEach(CommentFilter.State.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
                Picker("", selection: CommentsPanel.binding(comments, \.place)) {
                    ForEach(CommentsPanel.places(comments), id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().fixedSize()
            }
            HStack {
                Picker("", selection: CommentsPanel.binding(comments, \.person)) {
                    ForEach(CommentsPanel.people(comments), id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().fixedSize()
                Toggle("Mentions me", isOn: CommentsPanel.binding(comments, \.mentionsMe)).toggleStyle(.checkbox)
            }
            TextField("Search", text: CommentsPanel.binding(comments, \.search)).textFieldStyle(.roundedBorder).accessibilityIdentifier("comments.search")
            Text(comments.unreadTotal == 0 ? "No unread comments" : "\(comments.unreadTotal) unread").font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("comments.unread")
            List(rows) { row in
                CommentsPanelRow(comments: comments, row: row)
            }
            .accessibilityIdentifier("comments.list")
        }
        .padding(8)
    }
}

struct CommentsPanelRow: View {
    let comments: WindowComments
    let row: CommentsPanel.Row

    var body: some View {
        HStack(alignment: .top) {
            Text("\(row.number)").font(.caption.bold()).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.firstLine).lineLimit(2)
                Text("\(row.author) · \(row.replies) \(row.replies == 1 ? "reply" : "replies") · \(row.activity)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if row.unread { Circle().fill(SwiftUI.Color.blue).frame(width: 8, height: 8) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: CommentsPanel.select(comments, row.id, zoom: true))
        .onTapGesture(perform: CommentsPanel.select(comments, row.id, zoom: false))
        .contextMenu {
            ForEach(Array(CommentsPanel.menu(comments, row: row).enumerated()), id: \.offset) { _, item in
                Button(item.0, action: item.1)
            }
        }
    }
}
