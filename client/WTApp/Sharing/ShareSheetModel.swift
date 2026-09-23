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
}

/// The Share sheet's state (COLLAB-013; sharing.adoc, "The Share sheet"): the People list with
/// role popups and the team row, invitations by email, share links, access requests and
/// ownership transfer.  Who may do what follows sharing.adoc's roles table and D-063: the
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
    }

    enum Action: Equatable, Sendable {
        case reload
        case invite
        case setRole(ShareMember, DocumentRole)
        case confirm(Confirmation)
        case cancelConfirmation
        case remove(ShareMember)
        case setTeamAccess(DocumentRole?)
        case createLink
        case copyLink(ShareLinkInfo)
        case revokeLink(ShareLinkInfo)
        /// Grants at `requestRole`, or declines with nil.
        case resolve(AccessRequestInfo, DocumentRole?)
        case confirmTransfer
        case transfer(ShareMember)
        case done
    }

    static let offlineNotice = "Sharing needs a connection. It will be available when you reconnect."
    static let notUploadedNotice = "This document is not in your library on the server yet. Sharing is available once it has uploaded."
    static let linkCopied = "Link copied."
    static let noTokenHelp = "A link’s address is shown only when it is made. Make a new link to copy one."
    static let defaultExpiry: TimeInterval = 7 * 24 * 3600

    let document: ShareDocument
    @ObservationIgnored let services: CollaborationServices
    @ObservationIgnored let accountID: String?
    @ObservationIgnored var pasteboard: NSPasteboard = .general
    @ObservationIgnored var onDone: @MainActor () -> Void = {}
    @ObservationIgnored private(set) var lastTask: Task<Void, Never>?

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

    init(document: ShareDocument, services: CollaborationServices, accountID: String?, isOnline: Bool = true, now: Date = Date()) {
        self.document = document
        self.services = services
        self.accountID = accountID
        self.isOnline = isOnline
        linkExpiry = now.addingTimeInterval(Self.defaultExpiry)
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
    var canInvite: Bool { isAvailable && mayInvite && inviteEmail.contains("@") && inviteRoles.contains(inviteRole) }

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
        case let .setRole(member, role): await setRole(member, role)
        case let .confirm(confirmation): confirming = confirmation
        case .cancelConfirmation: confirming = nil
        case let .remove(member): await remove(member)
        case let .setTeamAccess(role): await setTeamAccess(role)
        case .createLink: await createLink()
        case let .copyLink(link): copy(link)
        case let .revokeLink(link): await revoke(link)
        case let .resolve(request, grant): await resolve(request, grant)
        case .confirmTransfer: confirming = transferCandidates.first { $0.accountID == transferTargetID }.map(Confirmation.transfer)
        case let .transfer(member): await transfer(member)
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
            }
            self.linkTeamMembersOnly = self.linkTeamMembersOnly || self.isRestricted
        }
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
        let email = inviteEmail.trimmingCharacters(in: .whitespaces)
        notice = nil
        let invited = await run { token in
            self.upsert(try await self.services.shares.invite(documentID: self.document.id, email: email, role: self.inviteRole, message: self.inviteMessage, accessToken: token))
        }
        guard invited else { return }
        notice = "Invited \(email)."
        inviteEmail = ""
        inviteMessage = ""
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

    private func resolve(_ request: AccessRequestInfo, _ grant: DocumentRole?) async {
        _ = await run { token in
            if let member = try await self.services.shares.resolveAccessRequest(requestID: request.id, grant: grant, accessToken: token) { self.upsert(member) }
            self.requests.removeAll { $0.id == request.id }
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
            self.notice = "\(result.owner.name) is now the owner. You are an editor."
        }
    }
}
