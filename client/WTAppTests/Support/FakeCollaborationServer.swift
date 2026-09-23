import AppKit
import Foundation
import SwiftUI
import GRPCCore
@testable import WireTuner

/// An in-memory `TeamService`, `ShareService` and the device RPCs of `AccountService`, for the
/// team settings, Join Team and Share sheet tests: no network.  `offline` makes every call fail
/// as a lost connection would; `failNext` makes the next call throw.
final class FakeCollaborationServer: TeamClient, ShareClient, DeviceClient, @unchecked Sendable {
    static let me = "a0000000-0000-4000-8000-000000000001"
    static let teamID = "t0000000-0000-4000-8000-000000000001"

    private let lock = NSLock()
    private var _offline = false
    private var _failure: (any Error)?
    private var _calls: [String] = []
    private var counter = 0

    private var _team = TeamDetail(id: FakeCollaborationServer.teamID, name: "Marketing", defaultDocumentRole: .editor, callerRole: .owner)
    private var _members: [TeamMemberInfo] = []
    private var _invites: [TeamInviteInfo] = []
    private var _verifies = false
    private var _roster = ShareRoster(members: [], teamAccess: nil)
    private var _links: [ShareLinkInfo] = []
    private var _requests: [AccessRequestInfo] = []
    private var _devices: [AccountProfile.Device] = []
    /// Whether `RemoveMember` leaves the person access through the team or a link.
    var removalLeavesAccess = false
    /// Whether `GetTeam` refuses (the caller left the team meanwhile).
    var teamUnavailable = false
    /// How long `accessToken` takes, so a test can look at a sheet while it loads.
    var tokenDelay: Duration = .zero

    init() {}

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    var offline: Bool {
        get { locked { _offline } }
        set { locked { _offline = newValue } }
    }

    var calls: [String] { locked { _calls } }
    var team: TeamDetail {
        get { locked { _team } }
        set { locked { _team = newValue } }
    }
    var members: [TeamMemberInfo] {
        get { locked { _members } }
        set { locked { _members = newValue } }
    }
    var invites: [TeamInviteInfo] {
        get { locked { _invites } }
        set { locked { _invites = newValue } }
    }
    var verifies: Bool {
        get { locked { _verifies } }
        set { locked { _verifies = newValue } }
    }
    var roster: ShareRoster {
        get { locked { _roster } }
        set { locked { _roster = newValue } }
    }
    var links: [ShareLinkInfo] {
        get { locked { _links } }
        set { locked { _links = newValue } }
    }
    var requests: [AccessRequestInfo] {
        get { locked { _requests } }
        set { locked { _requests = newValue } }
    }
    var devices: [AccountProfile.Device] {
        get { locked { _devices } }
        set { locked { _devices = newValue } }
    }

    func failNext(with error: any Error) { locked { _failure = error } }

    func services(signedIn: Bool = true, tokens: ShareLinkTokens = ShareLinkTokens()) -> CollaborationServices {
        let delay = tokenDelay
        return CollaborationServices(
            teams: self, shares: self,
            accessToken: {
                try await Task.sleep(for: delay)
                guard signedIn else { throw AuthError.notSignedIn }
                return "token"
            },
            links: URL(string: "https://links.example")!, linkTokens: tokens
        )
    }

    private func enter(_ call: String) throws {
        try locked {
            _calls.append(call)
            if let failure = _failure {
                _failure = nil
                throw failure
            }
            if _offline { throw LibraryClientError.offline }
        }
    }

    private func nextID(_ prefix: String) -> String {
        locked {
            counter += 1
            return "\(prefix)-\(counter)"
        }
    }

    // MARK: TeamClient

    func getTeam(teamID: String, accessToken: String) async throws -> TeamDetail {
        try enter("getTeam")
        if teamUnavailable { throw RPCError(code: .notFound, message: "TEAM_NOT_FOUND") }
        return team
    }

    func setDefaultDocumentRole(teamID: String, role: DocumentRole, accessToken: String) async throws -> TeamDetail {
        try enter("setDefaultDocumentRole")
        return locked {
            _team.defaultDocumentRole = role
            return _team
        }
    }

    func listMembers(teamID: String, accessToken: String) async throws -> [TeamMemberInfo] {
        try enter("listTeamMembers")
        return members
    }

    func listInvites(teamID: String, accessToken: String) async throws -> [TeamInviteInfo] {
        try enter("listInvites")
        return invites
    }

    func invite(teamID: String, email: String, role: TeamRole, accessToken: String) async throws -> TeamInviteInfo {
        try enter("inviteTeam")
        let invite = TeamInviteInfo(id: nextID("invite"), email: email, role: role, expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
        locked {
            _invites.removeAll { $0.email == email }
            _invites.append(invite)
        }
        return invite
    }

    func revokeInvite(teamID: String, inviteID: String, accessToken: String) async throws {
        try enter("revokeInvite")
        locked { _invites.removeAll { $0.id == inviteID } }
    }

    func setMemberRole(teamID: String, accountID: String, role: TeamRole, accessToken: String) async throws -> TeamMemberInfo {
        try enter("setMemberRole")
        return try locked {
            guard let index = _members.firstIndex(where: { $0.accountID == accountID }) else { throw RPCError(code: .notFound, message: "MEMBER_NOT_FOUND") }
            _members[index].role = role
            return _members[index]
        }
    }

    func removeMember(teamID: String, accountID: String, accessToken: String) async throws {
        try enter("removeTeamMember")
        locked { _members.removeAll { $0.accountID == accountID } }
    }

    func addDomain(teamID: String, domain: String, accessToken: String) async throws -> WorkspaceDomainInfo {
        try enter("addDomain")
        let info = WorkspaceDomainInfo(domain: domain, verificationToken: "0123abcd", verifiedAt: nil)
        locked { _team.workspace.domains.append(info) }
        return info
    }

    func verifyDomain(teamID: String, domain: String, accessToken: String) async throws -> WorkspaceDomainInfo {
        try enter("verifyDomain")
        return WorkspaceDomainInfo(domain: domain, verificationToken: "0123abcd", verifiedAt: verifies ? Date(timeIntervalSince1970: 1_800_000_000) : nil)
    }

    func removeDomain(teamID: String, domain: String, accessToken: String) async throws {
        try enter("removeDomain")
        locked { _team.workspace.domains.removeAll { $0.domain == domain } }
    }

    func setWorkspaceSettings(teamID: String, settings: WorkspaceSettingsValue, accessToken: String) async throws -> WorkspaceInfo {
        try enter("setWorkspaceSettings")
        return locked {
            _team.workspace.settings = settings
            return _team.workspace
        }
    }

    func acceptInvite(token: String, accessToken: String) async throws -> TeamDetail {
        try enter("acceptInvite:\(token)")
        return TeamDetail(id: "t-joined", name: "Design", callerRole: .member)
    }

    // MARK: DeviceClient

    func listDevices(accessToken: String) async throws -> [AccountProfile.Device] {
        try enter("listDevices")
        return devices
    }

    func revokeDevice(deviceID: String, accessToken: String) async throws -> AccountProfile.Device {
        try enter("revokeDevice:\(deviceID)")
        return try locked {
            guard let index = _devices.firstIndex(where: { $0.id == deviceID }) else { throw RPCError(code: .notFound, message: "no device") }
            _devices[index].revokedAt = Date()
            return _devices.remove(at: index)
        }
    }

    // MARK: ShareClient

    func listMembers(documentID: String, accessToken: String) async throws -> ShareRoster {
        try enter("listMembers")
        return roster
    }

    func invite(documentID: String, email: String, role: DocumentRole, message: String, accessToken: String) async throws -> ShareMember {
        try enter("invite:\(email):\(role.rawValue):\(message)")
        let member = ShareMember(accountID: "", displayName: "", email: email, role: role, sources: [.named], effectiveRole: role, isPending: true)
        locked { _roster.members.append(member) }
        return member
    }

    func setRole(documentID: String, accountID: String, role: DocumentRole, accessToken: String) async throws -> ShareMember {
        try enter("setRole:\(accountID):\(role.rawValue)")
        return try locked {
            guard let index = _roster.members.firstIndex(where: { $0.accountID == accountID }) else { throw RPCError(code: .notFound, message: "MEMBER_NOT_FOUND") }
            _roster.members[index].role = role
            _roster.members[index].effectiveRole = role
            return _roster.members[index]
        }
    }

    func removeMember(documentID: String, accountID: String, accessToken: String) async throws -> ShareMember? {
        try enter("removeMember:\(accountID)")
        return locked {
            guard let index = _roster.members.firstIndex(where: { $0.accountID == accountID }) else { return nil }
            if removalLeavesAccess {
                _roster.members[index].role = nil
                _roster.members[index].sources = [.link]
                _roster.members[index].effectiveRole = .viewer
                return _roster.members[index]
            }
            _roster.members.remove(at: index)
            return nil
        }
    }

    func setTeamAccess(documentID: String, override: DocumentRole?, accessToken: String) async throws -> TeamAccessInfo {
        try enter("setTeamAccess:\(override?.rawValue ?? "clear")")
        return try locked {
            guard _roster.teamAccess != nil else { throw RPCError(code: .failedPrecondition, message: "personal document") }
            _roster.teamAccess?.override = override
            return _roster.teamAccess!
        }
    }

    func listLinks(documentID: String, accessToken: String) async throws -> [ShareLinkInfo] {
        try enter("listLinks")
        return links
    }

    func createLink(documentID: String, options: ShareLinkOptions, accessToken: String) async throws -> CreatedShareLink {
        try enter("createLink:\(options.role.rawValue):expires=\(options.expiresAt != nil):revoke=\(options.revokeOnExpiry):password=\(!options.password.isEmpty):team=\(options.teamMembersOnly)")
        let link = ShareLinkInfo(
            id: nextID("link"), role: options.role, expiresAt: options.expiresAt, revokeOnExpiry: options.revokeOnExpiry,
            hasPassword: !options.password.isEmpty, teamMembersOnly: options.teamMembersOnly
        )
        locked { _links.insert(link, at: 0) }
        return CreatedShareLink(link: link, token: "tok\(link.id)")
    }

    func revokeLink(linkID: String, accessToken: String) async throws {
        try enter("revokeLink:\(linkID)")
        locked { _links.removeAll { $0.id == linkID } }
    }

    func listAccessRequests(documentID: String, accessToken: String) async throws -> [AccessRequestInfo] {
        try enter("listAccessRequests")
        return requests
    }

    func resolveAccessRequest(requestID: String, grant: DocumentRole?, accessToken: String) async throws -> ShareMember? {
        try enter("resolve:\(requestID):\(grant?.rawValue ?? "decline")")
        return locked {
            guard let index = _requests.firstIndex(where: { $0.id == requestID }) else { return nil }
            let request = _requests.remove(at: index)
            guard let grant else { return nil }
            let member = ShareMember(accountID: request.accountID, displayName: request.displayName, role: grant, effectiveRole: grant)
            _roster.members.append(member)
            return member
        }
    }

    func transferOwnership(documentID: String, newOwnerID: String, accessToken: String) async throws -> (owner: ShareMember, previousOwner: ShareMember) {
        try enter("transfer:\(newOwnerID)")
        return try locked {
            guard let owner = _roster.members.firstIndex(where: { $0.accountID == newOwnerID }),
                  let previous = _roster.members.firstIndex(where: { $0.role == .owner })
            else { throw RPCError(code: .failedPrecondition, message: "not a member") }
            _roster.members[owner].role = .owner
            _roster.members[owner].effectiveRole = .owner
            _roster.members[previous].role = .editor
            _roster.members[previous].effectiveRole = .editor
            return (_roster.members[owner], _roster.members[previous])
        }
    }
}

/// Renders a SwiftUI view once, off screen, so its body runs.
@MainActor
enum Render {
    @discardableResult
    static func view<V: View>(_ view: V, size: CGSize = CGSize(width: 600, height: 700)) -> NSView {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        return host
    }
}
