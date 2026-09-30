import AppKit
import Foundation
import Observation
import SwiftUI

/// The document the Share sheet is about.
struct ShareDocument: Equatable, Sendable {
    var id: String
    var name: String
    /// False until the document is on the server (a new document waiting to upload, or one not
    /// in the library yet): nothing can be shared.
    var isUploaded: Bool
    /// The caller's role as the library last listed it, until `ListMembers` says.
    var libraryRole: DocumentRole?
    /// The space the document is in (for *Move to…*); nil when the library has no entry.
    var spaceID: String?
}

/// The Share sheet's state (COLLAB-013; sharing.adoc, "The Share sheet"): the People list with
/// role popups and the team row, invitations by email or by a name the caller's teams suggest,
/// share links (made, edited, copied, revoked), access requests, and the Actions menu's ownership
/// transfer and move to another space.  Who may do what follows sharing.adoc's roles table and D-063: the
/// owner (a team admin on a team document) changes and removes anyone, manages links, the team
/// row and requests, and transfers ownership; an editor invites at editor or below and changes
/// or removes only viewers and commenters; anyone may remove themselves.  Popups never offer a
/// role above the caller's.  A workspace that restricts sharing keeps links team-only and says
/// so; offline, every control is disabled and the sheet explains why.  Sharing actions are
/// server calls, not undoable: destructive ones are confirmed inline.
@MainActor
@Observable
final class ShareSheetModel: Identifiable {
    enum Confirmation: Equatable, Sendable {
        case remove(ShareMember)
        case revokeLink(ShareLinkInfo)
        case transfer(ShareMember)
        case move(LibrarySpace)
    }

    enum Action: Equatable, Sendable {
        case reload
        case invite
        /// Picks a suggested person for the Invite field.
        case pick(InviteSuggestion)
        case setRole(ShareMember, DocumentRole)
        case confirm(Confirmation)
        case cancelConfirmation
        case remove(ShareMember)
        case setTeamAccess(DocumentRole?)
        case createLink
        case copyLink(ShareLinkInfo)
        case revokeLink(ShareLinkInfo)
        /// Opens a link's options for editing, saves them, or leaves them.
        case editLink(ShareLinkInfo)
        case saveLink
        case cancelEdit
        /// Grants at `requestRole`, or declines with nil.
        case resolve(AccessRequestInfo, DocumentRole?)
        case confirmTransfer
        case transfer(ShareMember)
        case move(LibrarySpace)
        case done
    }

    static let offlineNotice = "Sharing needs a connection. It will be available when you reconnect."
    static let notUploadedNotice = "This document is not in your library on the server yet. Sharing is available once it has uploaded."
    static let linkCopied = "Link copied."
    static let noTokenHelp = "A link’s address is shown only when it is made. Make a new link to copy one."
    static let defaultExpiry: TimeInterval = 7 * 24 * 3600
    static let linkUpdated = "Link updated."
    /// How many suggestions the Invite field lists at once.
    static let suggestionLimit = 6

    let document: ShareDocument
    @ObservationIgnored let services: CollaborationServices
    @ObservationIgnored let accountID: String?
    @ObservationIgnored var pasteboard: NSPasteboard = .general
    @ObservationIgnored var onDone: @MainActor () -> Void = {}
    @ObservationIgnored private(set) var lastTask: Task<Void, Never>?
    /// The caller's teams: whose members the Invite field suggests.
    @ObservationIgnored var teams: [LibrarySpace] = []
    /// Every space the caller has (Personal and teams): where *Move to…* may take the document.
    @ObservationIgnored var spaces: [LibrarySpace] = []
    /// Moves the document to a space (`DocumentService.MoveToFolder` through the library); nil
    /// when there is no library to move it in.  True when it moved.
    @ObservationIgnored var moveToSpace: (@MainActor (String) async -> Bool)?
    /// The pending access requests were counted (the toolbar button's badge follows).
    @ObservationIgnored var requestsDidChange: @MainActor (_ documentID: String, _ count: Int) -> Void = { _, _ in }

    private(set) var roster = ShareRoster(members: [], teamAccess: nil)
    /// The document's team, for the workspace's restrict-sharing switch and the caller's team
    /// role (admins hold the owner's powers).
    private(set) var team: TeamDetail?
    private(set) var links: [ShareLinkInfo] = []
    private(set) var requests: [AccessRequestInfo] = []
    private(set) var isOnline: Bool
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var notice: String?
    private(set) var confirming: Confirmation?
    /// The people of the caller's teams, for the Invite field's suggestions.
    private(set) var suggestionPool: [InviteSuggestion] = []
    /// The suggestion picked for the Invite field, while the field still shows its name.
    private(set) var invitePick: InviteSuggestion?
    /// The link whose options are being edited.
    private(set) var editingLink: ShareLinkInfo?
    /// Where the document is now (moves change it).
    private(set) var spaceID: String?

    var inviteEmail = ""
    var inviteRole: DocumentRole = .editor
    var inviteMessage = ""
    var requestRole: DocumentRole = .viewer
    var linkRole: DocumentRole = .viewer
    var linkExpires = false
    var linkExpiry: Date
    var linkRevokeOnExpiry = false
    var linkPassword = ""
    var linkTeamMembersOnly = false
    var transferTargetID: String?
    var editRole: DocumentRole = .viewer
    var editExpires = false
    var editExpiry: Date
    var editRevokeOnExpiry = false
    /// A new password; empty keeps the one the link has (see `editClearPassword`).
    var editPassword = ""
    var editClearPassword = false
    var editTeamMembersOnly = false

    init(document: ShareDocument, services: CollaborationServices, accountID: String?, isOnline: Bool = true, now: Date = Date()) {
        self.document = document
        self.services = services
        self.accountID = accountID
        self.isOnline = isOnline
        linkExpiry = now.addingTimeInterval(Self.defaultExpiry)
        editExpiry = now.addingTimeInterval(Self.defaultExpiry)
        spaceID = document.spaceID
    }

    // MARK: Who may do what

    func isMe(_ member: ShareMember) -> Bool { accountID.map { $0 == member.accountID } ?? false }

    var me: ShareMember? { roster.members.first(where: isMe) }
    var isTeamDocument: Bool { roster.teamAccess != nil }
    var isTeamAdmin: Bool { isTeamDocument && (team?.callerRole?.administers ?? false) }
    /// The caller's role on the document; a team admin counts as owner (D-063).
    var callerRole: DocumentRole? { isTeamAdmin ? .owner : (me?.effectiveRole ?? document.libraryRole) }
    var isOwner: Bool { callerRole == .owner }
    /// Controls are live: online, and the document is on the server.
    var isAvailable: Bool { isOnline && document.isUploaded }

    var unavailableNotice: String? {
        if !document.isUploaded { return Self.notUploadedNotice }
        return isOnline ? nil : Self.offlineNotice
    }

    /// The People list: everyone but those who have access only through the team row.
    var people: [ShareMember] { roster.members.filter { !$0.isOnlyThroughTeam } }

    /// Editor or owner may invite, at or below their own role (never owner).
    var inviteRoles: [DocumentRole] { callerRole.map { $0.rank >= DocumentRole.editor.rank ? $0.grantableRoles : [] } ?? [] }
    var mayInvite: Bool { !inviteRoles.isEmpty }
    var canInvite: Bool { isAvailable && mayInvite && invitee != nil && inviteRoles.contains(inviteRole) }

    /// Whom Invite would invite: the picked suggestion while the field shows its name, an
    /// address, or the one suggestion whose name the field spells out.
    var invitee: ShareInvitee? {
        let text = inviteEmail.trimmingCharacters(in: .whitespaces)
        if let pick = invitePick, pick.name == text { return .account(id: pick.accountID, name: pick.name) }
        if text.contains("@") { return .email(text) }
        let exact = suggestions.filter { $0.name.caseInsensitiveCompare(text) == .orderedSame }
        return exact.count == 1 ? .account(id: exact[0].accountID, name: exact[0].name) : nil
    }

    /// The people of the caller's teams the Invite field's text starts (their name, a word of it,
    /// or their address), leaving out those who already have a named role and the caller.
    var suggestions: [InviteSuggestion] {
        guard mayInvite, invitePick?.name != inviteEmail else { return [] }
        let named = Set(roster.members.filter { $0.role != nil }.map(\.accountID))
        return Array(suggestionPool.filter { !named.contains($0.accountID) && $0.accountID != accountID && $0.matches(inviteEmail) }.prefix(Self.suggestionLimit))
    }

    /// The owner changes anyone's named role but the owner's; an editor only a viewer's or
    /// commenter's (only the owner may lower another editor).
    func canChangeRole(_ member: ShareMember) -> Bool {
        guard isAvailable, !isMe(member), !member.isPending, let role = member.role, role != .owner else { return false }
        return isOwner || (callerRole == .editor && role.rank < DocumentRole.editor.rank)
    }

    func roleOptions(for member: ShareMember) -> [DocumentRole] {
        let options = inviteRoles
        guard let role = member.role, !options.contains(role) else { return options }
        return [role] + options
    }

    /// Anyone may remove themselves (not the owner); otherwise as `canChangeRole`.
    func canRemove(_ member: ShareMember) -> Bool {
        guard isAvailable, let role = member.role, role != .owner else { return false }
        return isMe(member) || canChangeRole(member)
    }

    var isRestricted: Bool { isTeamDocument && (team?.workspace.settings.restrictSharing ?? false) }

    var restrictionNotice: String? {
        guard let access = roster.teamAccess, isRestricted else { return nil }
        return "\(access.teamName)’s workspace restricts sharing to team members: only members can be invited, and links open only for them."
    }

    var canCreateLink: Bool { isAvailable && isOwner }
    var canManageTeamAccess: Bool { isAvailable && isOwner }
    var canResolveRequests: Bool { isAvailable && isOwner }

    /// Named members who could become owner; personal documents only (a team owns its own).
    var transferCandidates: [ShareMember] {
        guard isOwner, !isTeamDocument else { return [] }
        return people.filter { !isMe($0) && !$0.isPending && $0.role != nil && $0.role != .owner }
    }

    var canTransfer: Bool { isAvailable && transferCandidates.contains { $0.accountID == transferTargetID } }

    /// Where *Move to…* may take the document: the owner's other spaces.  Moving into a team makes
    /// the team the owner; moving out of one needs a team admin (the server says so otherwise).
    var moveTargets: [LibrarySpace] {
        guard isOwner, moveToSpace != nil, let spaceID else { return [] }
        return spaces.filter { $0.id != spaceID }
    }

    var canMove: Bool { isAvailable && !moveTargets.isEmpty }

    /// The Actions menu has something to offer.
    var hasActions: Bool { !transferCandidates.isEmpty || !moveTargets.isEmpty }

    /// What saving the link being edited would change; empty when nothing would.
    var linkChanges: ShareLinkChanges {
        guard let link = editingLink else { return ShareLinkChanges() }
        var changes = ShareLinkChanges()
        if editRole != link.role { changes.role = editRole }
        let expiry: Date? = editExpires ? editExpiry : nil
        if expiry != link.expiresAt { changes.expiresAt = .some(expiry) }
        let revoke = editExpires && editRevokeOnExpiry
        if revoke != link.revokeOnExpiry { changes.revokeOnExpiry = revoke }
        if !editPassword.isEmpty {
            changes.password = editPassword
        } else if editClearPassword, link.hasPassword {
            changes.password = ""
        }
        let teamOnly = editTeamMembersOnly || isRestricted
        if teamOnly != link.teamMembersOnly { changes.teamMembersOnly = teamOnly }
        return changes
    }

    var canSaveLink: Bool { isAvailable && isOwner && editingLink != nil && !linkChanges.isEmpty }

    func linkURL(_ link: ShareLinkInfo) -> URL? {
        services.linkTokens[link.id].map { LinkConfiguration.shareURL(base: services.links, token: $0) }
    }

    /// "Viewer · expires Sep 30, 2026 · password · team only · 3 uses".
    static func summary(_ link: ShareLinkInfo) -> String {
        var parts = [link.role.title]
        parts.append(link.expiresAt.map { "expires \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "never expires")
        if link.hasPassword { parts.append("password") }
        if link.teamMembersOnly { parts.append("team only") }
        parts.append(link.uses == 1 ? "1 use" : "\(link.uses) uses")
        return parts.joined(separator: " · ")
    }

    /// What a confirmation says and its button.
    static func prompt(_ confirmation: Confirmation) -> (message: String, button: String, action: Action) {
        switch confirmation {
        case let .remove(member):
            ("Remove \(member.name)’s access to this document?", "Remove", .remove(member))
        case let .revokeLink(link):
            ("Revoke this \(link.role.title.lowercased()) link? It stops working at once.", "Revoke", .revokeLink(link))
        case let .transfer(member):
            ("Make \(member.name) the owner? You keep the document as an editor, and the new owner may remove you.", "Transfer", .transfer(member))
        case let .move(space):
            (space.kind == .team
                ? "Move this document to \(space.name)? The team becomes its owner and the team’s access applies."
                : "Move this document to your Personal space? You become its owner.", "Move", .move(space))
        }
    }

    // MARK: Bindings for the popups

    func roleBinding(for member: ShareMember) -> Binding<DocumentRole> {
        Binding(get: { member.role ?? .viewer }, set: { [weak self] role in self?.send(.setRole(member, role)) })
    }

    var teamAccessBinding: Binding<DocumentRole?> {
        Binding(get: { [weak self] in self?.roster.teamAccess?.override }, set: { [weak self] role in self?.send(.setTeamAccess(role)) })
    }

    // MARK: Actions

    func handler(_ action: Action) -> () -> Void {
        { [weak self] in self?.send(action) }
    }

    @discardableResult
    func send(_ action: Action) -> Task<Void, Never> {
        let task = Task { await perform(action) }
        lastTask = task
        return task
    }

    func perform(_ action: Action) async {
        switch action {
        case .reload: await load()
        case .invite: await invite()
        case let .pick(suggestion):
            invitePick = suggestion
            inviteEmail = suggestion.name
        case let .setRole(member, role): await setRole(member, role)
        case let .confirm(confirmation): confirming = confirmation
        case .cancelConfirmation: confirming = nil
        case let .remove(member): await remove(member)
        case let .setTeamAccess(role): await setTeamAccess(role)
        case .createLink: await createLink()
        case let .copyLink(link): copy(link)
        case let .revokeLink(link): await revoke(link)
        case let .editLink(link): edit(link)
        case .saveLink: await saveLink()
        case .cancelEdit: editingLink = nil
        case let .resolve(request, grant): await resolve(request, grant)
        case .confirmTransfer: confirming = transferCandidates.first { $0.accountID == transferTargetID }.map(Confirmation.transfer)
        case let .transfer(member): await transfer(member)
        case let .move(space): await move(space)
        case .done: onDone()
        }
    }

    /// The members (and team row), the team's workspace, and for owners the links and requests.
    func load() async {
        guard document.isUploaded else { return }
        isLoading = true
        defer { isLoading = false }
        _ = await run { token in
            let roster = try await self.services.shares.listMembers(documentID: self.document.id, accessToken: token)
            self.roster = roster
            if let access = roster.teamAccess {
                self.team = try? await self.services.teams.getTeam(teamID: access.teamID, accessToken: token)
            }
            self.links = []
            self.requests = []
            if self.isOwner {
                self.links = try await self.services.shares.listLinks(documentID: self.document.id, accessToken: token)
                self.requests = try await self.services.shares.listAccessRequests(documentID: self.document.id, accessToken: token)
                self.requestsDidChange(self.document.id, self.requests.count)
            }
            self.linkTeamMembersOnly = self.linkTeamMembersOnly || self.isRestricted
            if self.mayInvite { self.suggestionPool = await self.teamPeople(token) }
        }
    }

    /// Every member of the caller's teams, once each (a team that cannot be read is left out).
    private func teamPeople(_ token: String) async -> [InviteSuggestion] {
        var seen = Set<String>()
        var people: [InviteSuggestion] = []
        for team in teams where team.kind == .team {
            guard let members = try? await services.teams.listMembers(teamID: team.id, accessToken: token) else { continue }
            for member in members where seen.insert(member.accountID).inserted {
                people.append(InviteSuggestion(accountID: member.accountID, displayName: member.displayName, email: member.email, teamName: team.name))
            }
        }
        return people
    }

    private func run(_ body: (String) async throws -> Void) async -> Bool {
        do {
            try await body(try await services.accessToken())
            isOnline = true
            errorMessage = nil
            return true
        } catch where CollaborationErrors.isOffline(error) {
            isOnline = false
            errorMessage = nil
            return false
        } catch {
            errorMessage = CollaborationErrors.message(for: error)
            return false
        }
    }

    private func upsert(_ member: ShareMember) {
        if let index = roster.members.firstIndex(where: { $0.id == member.id }) {
            roster.members[index] = member
        } else {
            roster.members.append(member)
        }
    }

    private func invite() async {
        guard let invitee else { return }
        notice = nil
        let invited = await run { token in
            let shares = self.services.shares
            switch invitee {
            case let .email(email):
                self.upsert(try await shares.invite(documentID: self.document.id, email: email, role: self.inviteRole, message: self.inviteMessage, accessToken: token))
            case let .account(id, _):
                self.upsert(try await shares.invite(documentID: self.document.id, accountID: id, role: self.inviteRole, message: self.inviteMessage, accessToken: token))
            }
        }
        guard invited else { return }
        notice = "Invited \(invitee.title)."
        inviteEmail = ""
        inviteMessage = ""
        invitePick = nil
    }

    private func setRole(_ member: ShareMember, _ role: DocumentRole) async {
        guard role != member.role else { return }
        _ = await run { token in
            self.upsert(try await self.services.shares.setRole(documentID: self.document.id, accountID: member.accountID, role: role, accessToken: token))
        }
    }

    private func remove(_ member: ShareMember) async {
        confirming = nil
        _ = await run { token in
            if let remaining = try await self.services.shares.removeMember(documentID: self.document.id, accountID: member.accountID, accessToken: token) {
                self.upsert(remaining)
            } else {
                self.roster.members.removeAll { $0.id == member.id }
            }
            self.notice = self.isMe(member) ? "You removed your access to this document." : "\(member.name) was removed."
        }
    }

    private func setTeamAccess(_ role: DocumentRole?) async {
        guard role != roster.teamAccess?.override else { return }
        _ = await run { token in
            self.roster.teamAccess = try await self.services.shares.setTeamAccess(documentID: self.document.id, override: role, accessToken: token)
        }
    }

    private func createLink() async {
        let options = ShareLinkOptions(
            role: linkRole, expiresAt: linkExpires ? linkExpiry : nil, revokeOnExpiry: linkExpires && linkRevokeOnExpiry,
            password: linkPassword, teamMembersOnly: linkTeamMembersOnly || isRestricted
        )
        _ = await run { token in
            let created = try await self.services.shares.createLink(documentID: self.document.id, options: options, accessToken: token)
            self.services.linkTokens[created.link.id] = created.token
            self.links.insert(created.link, at: 0)
            self.linkPassword = ""
            self.copy(created.link)
        }
    }

    private func copy(_ link: ShareLinkInfo) {
        guard let url = linkURL(link) else {
            notice = Self.noTokenHelp
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        notice = Self.linkCopied
    }

    private func revoke(_ link: ShareLinkInfo) async {
        confirming = nil
        guard await run({ try await self.services.shares.revokeLink(linkID: link.id, accessToken: $0) }) else { return }
        links.removeAll { $0.id == link.id }
        services.linkTokens[link.id] = nil
        notice = "Link revoked."
    }

    private func edit(_ link: ShareLinkInfo) {
        editingLink = link
        editRole = link.role
        editExpires = link.expiresAt != nil
        editExpiry = link.expiresAt ?? linkExpiry
        editRevokeOnExpiry = link.revokeOnExpiry
        editPassword = ""
        editClearPassword = false
        editTeamMembersOnly = link.teamMembersOnly
    }

    private func saveLink() async {
        guard let link = editingLink else { return }
        let changes = linkChanges
        guard !changes.isEmpty else {
            editingLink = nil
            return
        }
        _ = await run { token in
            let updated = try await self.services.shares.updateLink(linkID: link.id, changes: changes, accessToken: token)
            if let index = self.links.firstIndex(where: { $0.id == link.id }) { self.links[index] = updated }
            self.editingLink = nil
            self.editPassword = ""
            self.notice = Self.linkUpdated
        }
    }

    private func move(_ space: LibrarySpace) async {
        confirming = nil
        guard let moveToSpace else { return }
        guard await moveToSpace(space.id) else {
            errorMessage = "The document could not be moved to \(space.name)."
            return
        }
        spaceID = space.id
        errorMessage = nil
        notice = "Moved to \(space.name)."
        await load()
    }

    private func resolve(_ request: AccessRequestInfo, _ grant: DocumentRole?) async {
        _ = await run { token in
            if let member = try await self.services.shares.resolveAccessRequest(requestID: request.id, grant: grant, accessToken: token) { self.upsert(member) }
            self.requests.removeAll { $0.id == request.id }
            self.requestsDidChange(self.document.id, self.requests.count)
            self.notice = grant.map { "\(request.name) can now open this document as \($0.title.lowercased())." } ?? "\(request.name)’s request was declined."
        }
    }

    private func transfer(_ member: ShareMember) async {
        confirming = nil
        _ = await run { token in
            let result = try await self.services.shares.transferOwnership(documentID: self.document.id, newOwnerID: member.accountID, accessToken: token)
            self.upsert(result.owner)
            self.upsert(result.previousOwner)
            self.transferTargetID = nil
            self.links = []
            self.requests = []
            self.requestsDidChange(self.document.id, 0)
            self.notice = "\(result.owner.name) is now the owner. You are an editor."
        }
    }
}
