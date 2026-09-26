import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync

/// Someone the composer can mention (comments.adoc, "Mentioning people"): a person with access to
/// the document, or the document's team (`team:<id>`).
struct CommentMember: Hashable, Sendable, Identifiable {
    var id: String
    var name: String

    var isTeam: Bool { id.hasPrefix(CommentFields.teamPrefix) }

    /// The people with access in `roster` and, for a team document, the team.
    static func members(_ roster: ShareRoster) -> [CommentMember] {
        var result = roster.members.filter { !$0.accountID.isEmpty && !$0.isPending }.map { CommentMember(id: $0.accountID, name: $0.displayName) }
        if let team = roster.teamAccess { result.append(CommentMember(id: CommentFields.teamPrefix + team.teamID, name: team.teamName)) }
        return result
    }
}

/// Who may do what with comments (comments.adoc, "Who may do what"): viewers read; commenters,
/// editors and owners write; people move, resolve, edit and delete what is theirs, editors move
/// and resolve anyone's, owners delete anyone's.
struct CommentPermissions: Equatable, Sendable {
    var role: DocumentRole
    var account: String

    var canComment: Bool { role != .viewer && !account.isEmpty }
    private var isEditor: Bool { role == .editor || role == .owner }

    func canMove(_ thread: CommentThread) -> Bool { canComment && (isEditor || thread.opener.author == account) }
    func canResolve(_ thread: CommentThread) -> Bool { canMove(thread) }
    func canEdit(_ comment: CommentEntry) -> Bool { canComment && !comment.deleted && comment.author == account }
    func canDelete(_ comment: CommentEntry) -> Bool { !comment.deleted && (canEdit(comment) || (role == .owner && !account.isEmpty)) }
    var canDeleteThreads: Bool { role == .owner && !account.isEmpty }
}

/// The comments of the COLLAB epic's client-ui tasks (COLLAB-027's glue, COLLAB-028, COLLAB-029):
/// the pins over every canvas, the Comment tool, the thread popover, the Comments panel, the
/// menu:View[Comments] switches, menu:Object[Add Comment…] and the mention notice.  One object per
/// app; each window keeps its own `WindowComments`.
@MainActor
final class CommentsFeatures {
    enum ID {
        static let addComment: CommandID = "object.addComment"
        static let showPins: CommandID = "view.comments.showPins"
        static let showResolved: CommandID = "view.comments.showResolved"
        static let followFilter: CommandID = "view.comments.followFilter"
    }

    static let menu = "Comments"
    static let panelID: PanelID = "comments"
    static let panelGroup = "Comments"
    static let noDocument = DocumentSetupFeatures.noDocument
    static let noSelection = "Select an object to comment on"
    static let cannotComment = "Your role cannot add comments"

    let preferences: PreferenceStore
    let panel = CommentsPanelState()
    /// The front document window.
    var window: @MainActor () -> DocumentWindowController? = { nil }
    /// The signed-in account (id, display name); empty when signed out.
    var account: @MainActor () -> (id: String, name: String) = { ("", "") }
    /// The document's people and team, for `@` completion and display names.
    var members: @MainActor (String) async -> [CommentMember] = { _ in [] }
    /// The caller's role in the document (the owner for a document of one's own).
    var role: @MainActor (String) -> DocumentRole = { _ in .owner }
    /// The link *Copy Link* puts on the pasteboard.
    var link: @MainActor (String, OpID) -> URL = { document, thread in
        URL(string: "wiretuner://document/\(document)?thread=\(thread.counter).\(thread.replica)")!
    }
    var pasteboard: NSPasteboard = .general
    /// Shows a panel by id.
    var showPanel: @MainActor (PanelID) -> Void = { _ in }
    /// The server's read state for a document (`CommentService`); nil keeps it on this Mac.
    var readService: @MainActor (String) -> (any CommentReadService)? = { _ in nil }
    private var windows: [ObjectIdentifier: (window: DocumentWindowController, comments: WindowComments)] = [:]
    private var closing: [ObjectIdentifier: NSObjectProtocol] = [:]

    init(preferences: PreferenceStore) {
        self.preferences = preferences
    }

    func install(commands: CommandRegistry, panels: PanelRegistry, tools: ToolRegistry, window: @escaping @MainActor () -> DocumentWindowController?) {
        self.window = window
        panel.window = window
        panel.comments = { [weak self] in self?.attach($0) }
        panels.groupDefaults[Self.panelGroup] = panels.groupDefaults[Self.panelGroup] ?? PanelGroupDefaults(position: 11, isOpen: false)
        panels.registerIfAbsent(CommentsPanel.descriptor(state: panel))
        tools.replace(CommentTool.descriptor { [weak self] document in self?.comments(for: document) })
        for command in self.commands() { commands.replace(command) }
        preferences.observe { [weak self] change in self?.preferenceDidChange(change.id) }
    }

    // MARK: Windows

    /// The window's comments, made (with its pin layer) on first use.
    @discardableResult
    func attach(_ window: DocumentWindowController) -> WindowComments {
        let key = ObjectIdentifier(window)
        if let existing = windows[key] { return existing.comments }
        let comments = WindowComments(window: window, features: self)
        windows[key] = (window, comments)
        comments.install()
        if let nswindow = window.window {
            closing[key] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nswindow, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated { if let window { self?.detach(window) } }
            }
        }
        panel.touch()
        return comments
    }

    func detach(_ window: DocumentWindowController) {
        guard let entry = windows.removeValue(forKey: ObjectIdentifier(window)) else { return }
        if let observer = closing.removeValue(forKey: ObjectIdentifier(window)) { NotificationCenter.default.removeObserver(observer) }
        entry.comments.tearDown()
        panel.touch()
    }

    /// The comments of the window showing `document`.
    func comments(for document: DocumentHandle) -> WindowComments? {
        windows.values.first { $0.window.documentHandle === document }?.comments
    }

    /// The front window and its comments.
    var front: WindowComments? { window().map(attach) }

    // MARK: Commands

    func commands() -> [Command] {
        let toggles: [(CommandID, PreferenceKey<Bool>)] = [
            (ID.showPins, PreferenceCatalog.Sync.showCommentPins), (ID.showResolved, PreferenceCatalog.Sync.showResolvedPins),
            (ID.followFilter, PreferenceCatalog.Sync.pinsFollowFilter),
        ]
        let preferences = preferences
        let view = MenuPath(StandardCommands.Menu.view, Self.menu, section: StandardCommands.Section.viewVisibility, subsection: 0)
        return [
            Command(id: ID.addComment, title: "Add Comment…", menu: MenuPath(ContextMenuCatalog.Menu.object, section: 9), keywords: ["comment", "note", "review"],
                    validation: { [weak self] in self?.addCommentValidation() ?? .disabled(Self.noDocument) },
                    action: .perform { [weak self] in self?.front?.commentOnSelection() }),
        ] + toggles.map { id, key in
            Command(id: id, title: key.title, menu: view, keywords: ["comments", "pins"], validation: { .checked(preferences[key]) },
                    action: .perform { preferences.set(!preferences[key], for: key) })
        }
    }

    func addCommentValidation() -> CommandValidation {
        guard let comments = front else { return .disabled(Self.noDocument) }
        guard comments.permissions.canComment else { return .disabled(Self.cannotComment) }
        return comments.selectedAnchor == nil ? .disabled(Self.noSelection) : .enabled
    }

    private func preferenceDidChange(_ id: String) {
        guard [PreferenceCatalog.Sync.showCommentPins.id, PreferenceCatalog.Sync.showResolvedPins.id, PreferenceCatalog.Sync.pinsFollowFilter.id].contains(id) else { return }
        for entry in windows.values { entry.comments.setNeedsDisplay() }
    }
}

extension AppDelegate {
    /// The comments UI: the account and roster it reads, then the features.
    func installComments() {
        let documents = documents!
        let account = account
        let collaboration = collaboration
        let library = library
        comments.account = { (account.profile?.accountID ?? "", account.profile?.displayName ?? "") }
        comments.members = { documentID in
            guard account.isSignedIn, let token = try? await collaboration.accessToken(),
                  let roster = try? await collaboration.shares.listMembers(documentID: documentID, accessToken: token) else { return [] }
            return CommentMember.members(roster)
        }
        comments.role = { documentID in library.cache.documents[documentID]?.role ?? .owner }
        let layout = layout
        comments.showPanel = { layout.showPanel($0) }
        // Read state and the library's mention dots against the server (COLLAB-027/029).
        let configuration = AuthConfiguration(infoDictionary: Bundle.main.infoDictionary)
        let caller = GRPCUnaryCaller(api: configuration.api, clientVersion: LaunchEnvironment.clientVersion(Bundle.main.infoDictionary),
                                     deviceID: DeviceIdentity.current(defaults: preferences.defaults))
        let auth = account.auth
        let token: @Sendable () async throws -> String = { try await auth.validAccessToken() }
        let service = GRPCCommentReadService(caller: caller, accessToken: token)
        let testing = launchEnvironment.isTesting
        comments.readService = { _ in !testing && account.isSignedIn ? service : nil }
        if !testing {
            library.mentions = GRPCMentionedDocuments(caller: caller, accessToken: token)
            library.startMentionPolling()
        }
        comments.install(commands: commands, panels: panels, tools: tools) { documents.activeWindowController }
    }
}
