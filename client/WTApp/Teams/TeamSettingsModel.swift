import Foundation
import Observation
import SwiftUI

/// The team settings sheet's state (SEC-003; security.adoc, "Teams"): the members and their
/// roles, pending invitations with resend and revoke, the team's default document access, and
/// the company workspace -- domains with their verification state and the require-SSO,
/// auto-admit and restrict-sharing switches.  Admins change things; members see them; guests
/// see only the team.  The rules follow SEC-001 as built: only the owner deals in admins, and
/// nobody changes the owner's row here (ownership is a transfer).  Offline, nothing changes
/// and the sheet says why.
@MainActor
@Observable
final class TeamSettingsModel: Identifiable {
    enum Action: Equatable, Sendable {
        case reload
        case invite
        case resend(TeamInviteInfo)
        case revoke(TeamInviteInfo)
        case setRole(TeamMemberInfo, TeamRole)
        /// Asks before removing (the sheet confirms destructive actions inline).
        case confirmRemove(TeamMemberInfo)
        case remove(TeamMemberInfo)
        case cancelConfirmation
        case addDomain
        case verify(WorkspaceDomainInfo)
        case removeDomain(WorkspaceDomainInfo)
        case setDefaultRole(DocumentRole)
        case setSwitch(WorkspaceSwitch, Bool)
        case done
    }

    /// The workspace's on/off settings the sheet offers.
    enum WorkspaceSwitch: String, Equatable, Sendable, CaseIterable {
        case requireSSO, autoAdmit, restrictSharing

        var title: String {
            switch self {
            case .requireSSO: "Require sign-in with the workspace’s SSO"
            case .autoAdmit: "Admit everyone with a verified address on these domains"
            case .restrictSharing: "Restrict sharing of team documents to team members"
            }
        }

        func value(in settings: WorkspaceSettingsValue) -> Bool {
            switch self {
            case .requireSSO: settings.requireSSO
            case .autoAdmit: settings.autoAdmit
            case .restrictSharing: settings.restrictSharing
            }
        }

        func set(_ value: Bool, in settings: inout WorkspaceSettingsValue) {
            switch self {
            case .requireSSO: settings.requireSSO = value
            case .autoAdmit: settings.autoAdmit = value
            case .restrictSharing: settings.restrictSharing = value
            }
        }
    }

    static let adminOnlyNote = "Only the team’s owner and admins can change these settings."
    static let ssoNeedsConnection = "Requiring SSO needs an SSO connection for this workspace."
    static let guestNote = "Guests see only the documents shared with them."

    let teamID: String
    @ObservationIgnored let services: CollaborationServices
    /// The signed-in account, so its own row is not offered for removal.
    @ObservationIgnored let accountID: String?
    @ObservationIgnored var onDone: @MainActor () -> Void = {}
    /// The action running now; tests await it.
    @ObservationIgnored private(set) var lastTask: Task<Void, Never>?

    private(set) var team: TeamDetail?
    private(set) var members: [TeamMemberInfo] = []
    private(set) var invites: [TeamInviteInfo] = []
    private(set) var isOnline = true
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// What the last action did ("Invitation sent to …").
    private(set) var notice: String?
    private(set) var confirmingRemoval: TeamMemberInfo?
    var inviteEmail = ""
    var inviteRole: TeamRole = .member
    var newDomain = ""

    init(teamID: String, services: CollaborationServices, accountID: String?) {
        self.teamID = teamID
        self.services = services
        self.accountID = accountID
    }

    // MARK: What the sheet may do

    var callerRole: TeamRole? { team?.callerRole }
    var canAdminister: Bool { callerRole?.administers ?? false }
    /// Admin controls are live: an admin, online.
    var canEdit: Bool { canAdminister && isOnline }
    var canSeeMembers: Bool { callerRole != nil && callerRole != .guest }
    var inviteRoles: [TeamRole] { callerRole?.assignableRoles ?? [] }
    var canInvite: Bool { canEdit && inviteEmail.contains("@") && inviteRoles.contains(inviteRole) }
    var canAddDomain: Bool { canEdit && newDomain.trimmingCharacters(in: .whitespaces).contains(".") }
    var settings: WorkspaceSettingsValue { team?.workspace.settings ?? WorkspaceSettingsValue() }
    var domains: [WorkspaceDomainInfo] { team?.workspace.domains ?? [] }

    /// Only the owner changes or removes an admin; nobody changes the owner or themselves here.
    func canChange(_ member: TeamMemberInfo) -> Bool {
        canEdit && member.accountID != accountID && member.role != .owner && (member.role != .admin || callerRole == .owner)
    }

    /// The roles `member`'s popup offers: what the caller may assign, and the current role.
    func roleOptions(for member: TeamMemberInfo) -> [TeamRole] {
        let options = inviteRoles
        return options.contains(member.role) ? options : [member.role] + options
    }

    func isEnabled(_ workspaceSwitch: WorkspaceSwitch) -> Bool {
        canEdit && (workspaceSwitch != .requireSSO || !settings.ssoAlias.isEmpty)
    }

    // MARK: Bindings for the sheet's controls

    func roleBinding(for member: TeamMemberInfo) -> Binding<TeamRole> {
        Binding(get: { member.role }, set: { [weak self] role in self?.send(.setRole(member, role)) })
    }

    func switchBinding(_ workspaceSwitch: WorkspaceSwitch) -> Binding<Bool> {
        Binding(get: { workspaceSwitch.value(in: self.settings) }, set: { [weak self] value in self?.send(.setSwitch(workspaceSwitch, value)) })
    }

    var defaultRoleBinding: Binding<DocumentRole> {
        Binding(get: { [weak self] in self?.team?.defaultDocumentRole ?? .viewer }, set: { [weak self] role in self?.send(.setDefaultRole(role)) })
    }

    // MARK: Actions

    /// A button's action; the sheet's buttons hold these rather than closures of their own.
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
        case .invite: await invite(email: inviteEmail.trimmingCharacters(in: .whitespaces), role: inviteRole, again: false)
        case let .resend(invite): await self.invite(email: invite.email, role: invite.role, again: true)
        case let .revoke(invite): await revoke(invite)
        case let .setRole(member, role): await setRole(member, role)
        case let .confirmRemove(member): confirmingRemoval = member
        case let .remove(member): await remove(member)
        case .cancelConfirmation: confirmingRemoval = nil
        case .addDomain: await addDomain()
        case let .verify(domain): await verify(domain)
        case let .removeDomain(domain): await removeDomain(domain)
        case let .setDefaultRole(role): await setDefaultRole(role)
        case let .setSwitch(workspaceSwitch, value): await setSwitch(workspaceSwitch, value)
        case .done: onDone()
        }
    }

    /// The team, then (for members) its members and (for admins) its invitations.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        _ = await run { token in
            let team = try await self.services.teams.getTeam(teamID: self.teamID, accessToken: token)
            self.team = team
            self.members = []
            self.invites = []
            if self.canSeeMembers { self.members = try await self.services.teams.listMembers(teamID: self.teamID, accessToken: token) }
            if self.canAdminister { self.invites = try await self.services.teams.listInvites(teamID: self.teamID, accessToken: token) }
        }
    }

    /// One RPC with a token: online again on success; offline or a refusal otherwise.
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

    private func invite(email: String, role: TeamRole, again: Bool) async {
        notice = nil
        let sent = await run { token in
            let invite = try await self.services.teams.invite(teamID: self.teamID, email: email, role: role, accessToken: token)
            self.invites.removeAll { $0.email.caseInsensitiveCompare(email) == .orderedSame }
            self.invites.append(invite)
        }
        guard sent else { return }
        notice = again ? "Invitation sent again to \(email)." : "Invitation sent to \(email)."
        if !again { inviteEmail = "" }
    }

    private func revoke(_ invite: TeamInviteInfo) async {
        guard await run({ try await self.services.teams.revokeInvite(teamID: self.teamID, inviteID: invite.id, accessToken: $0) }) else { return }
        invites.removeAll { $0.id == invite.id }
        notice = "Invitation to \(invite.email) withdrawn."
    }

    private func setRole(_ member: TeamMemberInfo, _ role: TeamRole) async {
        guard role != member.role else { return }
        _ = await run { token in
            let updated = try await self.services.teams.setMemberRole(teamID: self.teamID, accountID: member.accountID, role: role, accessToken: token)
            self.members = self.members.map { $0.accountID == updated.accountID ? updated : $0 }
        }
    }

    private func remove(_ member: TeamMemberInfo) async {
        confirmingRemoval = nil
        guard await run({ try await self.services.teams.removeMember(teamID: self.teamID, accountID: member.accountID, accessToken: $0) }) else { return }
        members.removeAll { $0.accountID == member.accountID }
        notice = "\(member.displayName) was removed from the team."
    }

    private func addDomain() async {
        let domain = newDomain.trimmingCharacters(in: .whitespaces).lowercased()
        let added = await run { token in
            let info = try await self.services.teams.addDomain(teamID: self.teamID, domain: domain, accessToken: token)
            self.replace(info)
        }
        if added { newDomain = "" }
    }

    private func verify(_ domain: WorkspaceDomainInfo) async {
        _ = await run { token in
            let info = try await self.services.teams.verifyDomain(teamID: self.teamID, domain: domain.domain, accessToken: token)
            self.replace(info)
            self.notice = info.isVerified ? "\(info.domain) is verified." : "\(info.domain) is not verified yet. Add the TXT record and try again."
        }
    }

    private func replace(_ domain: WorkspaceDomainInfo) {
        var domains = self.domains.filter { $0.domain != domain.domain }
        domains.append(domain)
        team?.workspace.domains = domains.sorted { $0.domain < $1.domain }
    }

    private func removeDomain(_ domain: WorkspaceDomainInfo) async {
        guard await run({ try await self.services.teams.removeDomain(teamID: self.teamID, domain: domain.domain, accessToken: $0) }) else { return }
        team?.workspace.domains.removeAll { $0.domain == domain.domain }
    }

    private func setDefaultRole(_ role: DocumentRole) async {
        guard role != team?.defaultDocumentRole else { return }
        _ = await run { token in
            let updated = try await self.services.teams.setDefaultDocumentRole(teamID: self.teamID, role: role, accessToken: token)
            self.team?.defaultDocumentRole = updated.defaultDocumentRole
        }
    }

    private func setSwitch(_ workspaceSwitch: WorkspaceSwitch, _ value: Bool) async {
        var settings = self.settings
        guard workspaceSwitch.value(in: settings) != value else { return }
        workspaceSwitch.set(value, in: &settings)
        _ = await run { token in
            let workspace = try await self.services.teams.setWorkspaceSettings(teamID: self.teamID, settings: settings, accessToken: token)
            self.team?.workspace = workspace
        }
    }
}

/// Joining a team from an invitation (SEC-003): a `wiretuner://invite/<token>` URL the app was
/// asked to open, or the mail's link pasted into the Join Team sheet.
@MainActor
@Observable
final class JoinTeamModel: Identifiable {
    static let invalidLink = "That is not a WireTuner invitation link."

    @ObservationIgnored let services: CollaborationServices
    /// After joining: the library refreshes and shows the team.
    @ObservationIgnored var onJoined: @MainActor (TeamDetail) async -> Void = { _ in }
    @ObservationIgnored var onDone: @MainActor () -> Void = {}

    var link: String
    private(set) var joined: TeamDetail?
    private(set) var isJoining = false
    private(set) var isOnline = true
    private(set) var errorMessage: String?

    init(services: CollaborationServices, link: String = "") {
        self.services = services
        self.link = link
    }

    var token: String? { InviteLink.token(in: link) }
    var canJoin: Bool { token != nil && !isJoining && joined == nil }
    /// Shown under the field when something is typed that is not a link.
    var linkProblem: String? { link.trimmingCharacters(in: .whitespaces).isEmpty || token != nil ? nil : Self.invalidLink }

    func join() async {
        guard let token, !isJoining else { return }
        isJoining = true
        defer { isJoining = false }
        do {
            let team = try await services.teams.acceptInvite(token: token, accessToken: try await services.accessToken())
            joined = team
            isOnline = true
            errorMessage = nil
            await onJoined(team)
        } catch where CollaborationErrors.isOffline(error) {
            isOnline = false
        } catch {
            errorMessage = CollaborationErrors.message(for: error)
        }
    }

    /// The sheet's buttons.
    func joinHandler() -> () -> Void { { [weak self] in Task { await self?.join() } } }
    func doneHandler() -> () -> Void { { [weak self] in self?.onDone() } }
}
