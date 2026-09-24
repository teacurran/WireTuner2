import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// A comment being typed, with the people it mentions (comments.adoc, "Mentioning people"):
/// typing kbd:[@] and part of a name offers the matching members; choosing one writes "@Name"
/// and remembers whom it names.  The tags become `CommentBody.Mention`s over the names that are
/// still in the text when the comment is posted.
struct MentionDraft: Equatable {
    var text = ""
    private(set) var tags: [CommentMember] = []

    init(_ text: String = "") {
        self.text = text
    }

    /// The partial name after a trailing `@`, when the text ends in one.
    var query: String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let tail = text[text.index(after: at)...]
        guard !tail.contains(where: \.isNewline), tail.count <= 40, !tail.hasPrefix(" ") else { return nil }
        let before = text[..<at].last
        guard before == nil || before!.isWhitespace else { return nil }
        return String(tail)
    }

    /// The members matching the partial name, the team after people.
    func completions(_ members: [CommentMember]) -> [CommentMember] {
        guard let query else { return [] }
        let matches = members.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        return matches.filter { !$0.isTeam } + matches.filter(\.isTeam)
    }

    /// Replaces the partial name with "@Name " and tags it.
    mutating func choose(_ member: CommentMember) {
        guard let query, let at = text.lastIndex(of: "@") else { return }
        _ = query
        text = String(text[..<at]) + "@" + member.name + " "
        tags.append(member)
    }

    /// The comment as the command takes it: each tag over the first "@Name" after the previous.
    var body: CommentBody {
        let scalars = Array(text.unicodeScalars)
        var mentions: [CommentBody.Mention] = []
        var start = 0
        for tag in tags {
            let needle = Array(("@" + tag.name).unicodeScalars)
            guard needle.count <= scalars.count, start <= scalars.count - needle.count else { continue }
            if let found = (start...(scalars.count - needle.count)).first(where: { Array(scalars[$0..<($0 + needle.count)]) == needle }) {
                mentions.append(CommentBody.Mention(range: found..<(found + needle.count), account: tag.id))
                start = found + needle.count
            }
        }
        return CommentBody(text, mentions: mentions)
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The thread popover's state (COLLAB-028): the thread shown (or the composer of a pending
/// one), the reply or composer draft, the comment being edited, and the actions, each gated by
/// the caller's role.
@MainActor
@Observable
final class ThreadViewModel {
    @ObservationIgnored let comments: WindowComments
    var draft = MentionDraft()
    /// The comment being edited and its text.
    var editing: OpID?
    var editDraft = MentionDraft()
    /// The comment whose reactions bar is open.
    var reacting: OpID?

    init(comments: WindowComments) {
        self.comments = comments
    }

    var isComposer: Bool { comments.pending != nil }
    var thread: CommentThread? { comments.openThread.flatMap { comments.model[$0] } }
    var permissions: CommentPermissions { comments.permissions }

    var title: String {
        if isComposer { return "New comment" }
        guard let thread else { return "Comment" }
        return "Thread \(thread.number)" + (thread.anchorName.map { " — \($0)" } ?? "")
    }

    var completions: [CommentMember] { draft.completions(comments.members) }

    func name(_ account: String) -> String { comments.name(of: account) }

    static func time(_ ms: Int64, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    /// kbd:[Cmd+Return] / btn:[Comment]: posts the composer's thread or a reply.
    @discardableResult
    func submit() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard !draft.isEmpty else { return nil }
        let body = draft.body
        let task: Task<Wiretuner_Doc_V1_Change?, Never>?
        if isComposer {
            task = comments.post(body)
        } else if let thread {
            task = comments.reply(to: thread.id, body)
        } else {
            task = nil
        }
        if task != nil { draft = MentionDraft() }
        return task
    }

    /// kbd:[Esc]: the composer's pin goes away; in a thread the popover closes.
    func cancel() {
        if isComposer { comments.discardPending() } else { comments.close() }
    }

    func beginEdit(_ comment: CommentEntry) {
        guard permissions.canEdit(comment) else { return }
        editing = comment.id
        editDraft = MentionDraft(comment.text)
    }

    @discardableResult
    func saveEdit() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let editing, let thread, !editDraft.isEmpty else { return nil }
        self.editing = nil
        return comments.edit(editing, in: thread.id, editDraft.body)
    }

    func cancelEdit() { editing = nil }

    @discardableResult
    func delete(_ comment: CommentEntry) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let thread else { return nil }
        return comments.delete(comment.id, in: thread.id)
    }

    @discardableResult
    func react(_ emoji: String, _ comment: CommentEntry) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let thread else { return nil }
        reacting = nil
        return comments.react(emoji, to: comment.id, in: thread.id)
    }

    @discardableResult
    func toggleResolved() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let thread else { return nil }
        return comments.setResolved(thread.id, !thread.resolved)
    }
}

/// The thread popover (comments.adoc, "Pins and threads", "Editing and deleting your comments",
/// "Reactions", "Resolving a thread").
struct CommentThreadView: View {
    let model: ThreadViewModel

    static func submit(_ model: ThreadViewModel) -> () -> Void { { model.submit() } }
    static func cancel(_ model: ThreadViewModel) -> () -> Void { { model.cancel() } }
    static func resolve(_ model: ThreadViewModel) -> () -> Void { { model.toggleResolved() } }
    static func choose(_ model: ThreadViewModel, _ member: CommentMember) -> () -> Void { { model.draft.choose(member) } }
    static func edit(_ model: ThreadViewModel, _ comment: CommentEntry) -> () -> Void { { model.beginEdit(comment) } }
    static func delete(_ model: ThreadViewModel, _ comment: CommentEntry) -> () -> Void { { model.delete(comment) } }
    static func react(_ model: ThreadViewModel, _ emoji: String, _ comment: CommentEntry) -> () -> Void { { model.react(emoji, comment) } }
    static func openReactions(_ model: ThreadViewModel, _ comment: CommentEntry) -> () -> Void {
        { model.reacting = model.reacting == comment.id ? nil : comment.id }
    }
    static func saveEdit(_ model: ThreadViewModel) -> () -> Void { { model.saveEdit() } }
    static func cancelEdit(_ model: ThreadViewModel) -> () -> Void { { model.cancelEdit() } }
    static func draft(_ model: ThreadViewModel) -> Binding<String> {
        Binding(get: { model.draft.text }, set: { model.draft.text = $0 })
    }
    static func editText(_ model: ThreadViewModel) -> Binding<String> {
        Binding(get: { model.editDraft.text }, set: { model.editDraft.text = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.title).font(.headline).lineLimit(1)
                Spacer()
                if let thread = model.thread, model.permissions.canResolve(thread) {
                    Button(thread.resolved ? "Reopen" : "Resolve", action: Self.resolve(model)).accessibilityIdentifier("thread.resolve")
                }
            }
            if let thread = model.thread {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(thread.comments, id: \.id) { comment in
                            CommentRow(model: model, comment: comment)
                        }
                    }
                }
            }
            if model.isComposer || model.permissions.canComment {
                composer
            }
        }
        .padding(12)
        .frame(width: 320)
        .onExitCommand(perform: Self.cancel(model))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: Self.draft(model))
                .font(.body)
                .frame(minHeight: 44, maxHeight: 90)
                .border(SwiftUI.Color.secondary.opacity(0.3))
                .accessibilityIdentifier("thread.draft")
            ForEach(model.completions) { member in
                Button("@\(member.name)", action: Self.choose(model, member)).buttonStyle(.link).accessibilityIdentifier("thread.mention")
            }
            HStack {
                Button("Cancel", action: Self.cancel(model)).keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.isComposer ? "Comment" : "Reply", action: Self.submit(model))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.draft.isEmpty)
                    .accessibilityIdentifier("thread.submit")
            }
        }
    }
}

/// One comment of the thread: author, time, *edited*, text, reactions and its menu.
struct CommentRow: View {
    let model: ThreadViewModel
    let comment: CommentEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if comment.deleted {
                Text("Comment deleted").italic().foregroundStyle(.secondary)
            } else {
                HStack {
                    Text(model.name(comment.author)).font(.callout.bold())
                    Text(ThreadViewModel.time(comment.wallTimeMs) + (comment.isEdited ? " · edited" : "")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("☺", action: CommentThreadView.openReactions(model, comment)).buttonStyle(.borderless).disabled(!model.permissions.canComment)
                    if model.permissions.canEdit(comment) || model.permissions.canDelete(comment) {
                        Menu("⌄") {
                            if model.permissions.canEdit(comment) { Button("Edit", action: CommentThreadView.edit(model, comment)) }
                            if model.permissions.canDelete(comment) { Button("Delete", action: CommentThreadView.delete(model, comment)) }
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                }
                if model.editing == comment.id {
                    TextEditor(text: CommentThreadView.editText(model)).frame(minHeight: 40, maxHeight: 80).border(SwiftUI.Color.secondary.opacity(0.3))
                    HStack {
                        Button("Cancel", action: CommentThreadView.cancelEdit(model))
                        Button("Save", action: CommentThreadView.saveEdit(model)).accessibilityIdentifier("comment.save")
                    }
                } else {
                    Text(comment.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if model.reacting == comment.id {
                    HStack {
                        ForEach(CommentFields.reactionEmoji, id: \.self) { emoji in
                            Button(emoji, action: CommentThreadView.react(model, emoji, comment)).buttonStyle(.borderless)
                        }
                    }
                }
                let reactions = comment.reactionCounts
                if !reactions.isEmpty {
                    HStack {
                        ForEach(reactions, id: \.emoji) { reaction in
                            Button("\(reaction.emoji) \(reaction.accounts.count)", action: CommentThreadView.react(model, reaction.emoji, comment))
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}
