import Foundation
import GRPCCore
import SwiftProtobuf
import WTProto

/// The `TeamService` RPCs the team settings sheet and the invitation flow use (SEC-003).  A
/// protocol so the models are tested against fakes.  Lists come back whole: the client walks
/// the cursors.
protocol TeamClient: Sendable {
    func getTeam(teamID: String, accessToken: String) async throws -> TeamDetail
    func setDefaultDocumentRole(teamID: String, role: DocumentRole, accessToken: String) async throws -> TeamDetail
    func listMembers(teamID: String, accessToken: String) async throws -> [TeamMemberInfo]
    func listInvites(teamID: String, accessToken: String) async throws -> [TeamInviteInfo]
    /// Also resends: inviting an address with a pending invitation replaces it.
    func invite(teamID: String, email: String, role: TeamRole, accessToken: String) async throws -> TeamInviteInfo
    func revokeInvite(teamID: String, inviteID: String, accessToken: String) async throws
    func setMemberRole(teamID: String, accountID: String, role: TeamRole, accessToken: String) async throws -> TeamMemberInfo
    func removeMember(teamID: String, accountID: String, accessToken: String) async throws
    func addDomain(teamID: String, domain: String, accessToken: String) async throws -> WorkspaceDomainInfo
    func verifyDomain(teamID: String, domain: String, accessToken: String) async throws -> WorkspaceDomainInfo
    func removeDomain(teamID: String, domain: String, accessToken: String) async throws
    func setWorkspaceSettings(teamID: String, settings: WorkspaceSettingsValue, accessToken: String) async throws -> WorkspaceInfo
    func acceptInvite(token: String, accessToken: String) async throws -> TeamDetail
}

/// `AccountService.ListDevices` and `RevokeDevice` for the account window (SEC-003).
protocol DeviceClient: Sendable {
    func listDevices(accessToken: String) async throws -> [AccountProfile.Device]
    func revokeDevice(deviceID: String, accessToken: String) async throws -> AccountProfile.Device
}

/// The request messages, built apart from the calls so they are tested without a server.
enum TeamRequests {
    static let pageSize: UInt32 = 50

    /// Every page of a cursor-paged list: `fetch` gets a cursor ("" first) and answers the
    /// page's items and the next cursor ("" at the end).
    static func allPages<Item>(_ fetch: (String) async throws -> ([Item], String)) async throws -> [Item] {
        var items: [Item] = []
        var cursor = ""
        repeat {
            let (page, next) = try await fetch(cursor)
            items += page
            cursor = next
        } while !cursor.isEmpty
        return items
    }

    static func updateDefaultRole(teamID: String, role: DocumentRole) -> Wiretuner_Account_V1_UpdateTeamRequest {
        var message = Wiretuner_Account_V1_UpdateTeamRequest()
        message.teamID = teamID
        message.defaultDocumentRole = role.proto
        return message
    }

    static func listMembers(teamID: String, cursor: String) -> Wiretuner_Account_V1_ListMembersRequest {
        var message = Wiretuner_Account_V1_ListMembersRequest()
        message.teamID = teamID
        message.cursor = cursor
        message.pageSize = pageSize
        return message
    }

    static func listInvites(teamID: String, cursor: String) -> Wiretuner_Account_V1_ListInvitesRequest {
        var message = Wiretuner_Account_V1_ListInvitesRequest()
        message.teamID = teamID
        message.cursor = cursor
        message.pageSize = pageSize
        return message
    }

    static func invite(teamID: String, email: String, role: TeamRole) -> Wiretuner_Account_V1_InviteMemberRequest {
        var message = Wiretuner_Account_V1_InviteMemberRequest()
        message.teamID = teamID
        message.email = email
        message.role = role.proto
        return message
    }

    static func revokeInvite(teamID: String, inviteID: String) -> Wiretuner_Account_V1_RevokeInviteRequest {
        var message = Wiretuner_Account_V1_RevokeInviteRequest()
        message.teamID = teamID
        message.inviteID = inviteID
        return message
    }

    static func setMemberRole(teamID: String, accountID: String, role: TeamRole) -> Wiretuner_Account_V1_SetMemberRoleRequest {
        var message = Wiretuner_Account_V1_SetMemberRoleRequest()
        message.teamID = teamID
        message.accountID = accountID
        message.role = role.proto
        return message
    }

    static func removeMember(teamID: String, accountID: String) -> Wiretuner_Account_V1_RemoveMemberRequest {
        var message = Wiretuner_Account_V1_RemoveMemberRequest()
        message.teamID = teamID
        message.accountID = accountID
        return message
    }

    static func setWorkspaceSettings(teamID: String, settings: WorkspaceSettingsValue) -> Wiretuner_Account_V1_SetWorkspaceSettingsRequest {
        var message = Wiretuner_Account_V1_SetWorkspaceSettingsRequest()
        message.teamID = teamID
        message.settings = settings.proto
        return message
    }

    static func listDevices(cursor: String) -> Wiretuner_Account_V1_ListDevicesRequest {
        var message = Wiretuner_Account_V1_ListDevicesRequest()
        message.cursor = cursor
        message.pageSize = pageSize
        return message
    }
}

/// `TeamService` and the device RPCs of `AccountService` over gRPC (`UnaryCaller`; in the app
/// `GRPCUnaryCaller`, one connection per call).  Requests are built by `TeamRequests` and
/// responses mapped by the extensions below, so each call here is one line.
struct GRPCTeamClient: TeamClient, DeviceClient {
    typealias Team = Wiretuner_Account_V1_TeamService.Method
    typealias Account = Wiretuner_Account_V1_AccountService.Method

    let caller: any UnaryCaller

    init(caller: any UnaryCaller) {
        self.caller = caller
    }

    init(api: URL, clientVersion: String, deviceID: String) {
        self.init(caller: GRPCUnaryCaller(api: api, clientVersion: clientVersion, deviceID: deviceID))
    }

    /// `wt-client`'s version, for the launch environment's tests.
    var clientVersion: String? { (caller as? GRPCUnaryCaller)?.clientVersion }

    func getTeam(teamID: String, accessToken: String) async throws -> TeamDetail {
        let response: Team.GetTeam.Output = try await caller.unary(Team.GetTeam.descriptor, Team.GetTeam.Input.with { $0.teamID = teamID }, accessToken: accessToken)
        return response.detail
    }

    func setDefaultDocumentRole(teamID: String, role: DocumentRole, accessToken: String) async throws -> TeamDetail {
        let response: Team.UpdateTeam.Output = try await caller.unary(Team.UpdateTeam.descriptor, TeamRequests.updateDefaultRole(teamID: teamID, role: role), accessToken: accessToken)
        return response.detail
    }

    func listMembers(teamID: String, accessToken: String) async throws -> [TeamMemberInfo] {
        try await TeamRequests.allPages { cursor in
            let response: Team.ListMembers.Output = try await caller.unary(Team.ListMembers.descriptor, TeamRequests.listMembers(teamID: teamID, cursor: cursor), accessToken: accessToken)
            return response.page
        }
    }

    func listInvites(teamID: String, accessToken: String) async throws -> [TeamInviteInfo] {
        try await TeamRequests.allPages { cursor in
            let response: Team.ListInvites.Output = try await caller.unary(Team.ListInvites.descriptor, TeamRequests.listInvites(teamID: teamID, cursor: cursor), accessToken: accessToken)
            return response.page
        }
    }

    func invite(teamID: String, email: String, role: TeamRole, accessToken: String) async throws -> TeamInviteInfo {
        let response: Team.InviteMember.Output = try await caller.unary(Team.InviteMember.descriptor, TeamRequests.invite(teamID: teamID, email: email, role: role), accessToken: accessToken)
        return response.info
    }

    func revokeInvite(teamID: String, inviteID: String, accessToken: String) async throws {
        let _: Team.RevokeInvite.Output = try await caller.unary(Team.RevokeInvite.descriptor, TeamRequests.revokeInvite(teamID: teamID, inviteID: inviteID), accessToken: accessToken)
    }

    func setMemberRole(teamID: String, accountID: String, role: TeamRole, accessToken: String) async throws -> TeamMemberInfo {
        let request = TeamRequests.setMemberRole(teamID: teamID, accountID: accountID, role: role)
        let response: Team.SetMemberRole.Output = try await caller.unary(Team.SetMemberRole.descriptor, request, accessToken: accessToken)
        return response.info
    }

    func removeMember(teamID: String, accountID: String, accessToken: String) async throws {
        let _: Team.RemoveMember.Output = try await caller.unary(Team.RemoveMember.descriptor, TeamRequests.removeMember(teamID: teamID, accountID: accountID), accessToken: accessToken)
    }

    func addDomain(teamID: String, domain: String, accessToken: String) async throws -> WorkspaceDomainInfo {
        let request = Team.AddWorkspaceDomain.Input.with { $0.teamID = teamID; $0.domain = domain }
        let response: Team.AddWorkspaceDomain.Output = try await caller.unary(Team.AddWorkspaceDomain.descriptor, request, accessToken: accessToken)
        return response.info
    }

    func verifyDomain(teamID: String, domain: String, accessToken: String) async throws -> WorkspaceDomainInfo {
        let request = Team.VerifyWorkspaceDomain.Input.with { $0.teamID = teamID; $0.domain = domain }
        let response: Team.VerifyWorkspaceDomain.Output = try await caller.unary(Team.VerifyWorkspaceDomain.descriptor, request, accessToken: accessToken)
        return response.info
    }

    func removeDomain(teamID: String, domain: String, accessToken: String) async throws {
        let request = Team.RemoveWorkspaceDomain.Input.with { $0.teamID = teamID; $0.domain = domain }
        let _: Team.RemoveWorkspaceDomain.Output = try await caller.unary(Team.RemoveWorkspaceDomain.descriptor, request, accessToken: accessToken)
    }

    func setWorkspaceSettings(teamID: String, settings: WorkspaceSettingsValue, accessToken: String) async throws -> WorkspaceInfo {
        let request = TeamRequests.setWorkspaceSettings(teamID: teamID, settings: settings)
        let response: Team.SetWorkspaceSettings.Output = try await caller.unary(Team.SetWorkspaceSettings.descriptor, request, accessToken: accessToken)
        return response.info
    }

    func acceptInvite(token: String, accessToken: String) async throws -> TeamDetail {
        let response: Team.AcceptInvite.Output = try await caller.unary(Team.AcceptInvite.descriptor, Team.AcceptInvite.Input.with { $0.token = token }, accessToken: accessToken)
        return response.detail
    }

    // MARK: Devices

    func listDevices(accessToken: String) async throws -> [AccountProfile.Device] {
        try await TeamRequests.allPages { cursor in
            let response: Account.ListDevices.Output = try await caller.unary(Account.ListDevices.descriptor, TeamRequests.listDevices(cursor: cursor), accessToken: accessToken)
            return response.page
        }
    }

    func revokeDevice(deviceID: String, accessToken: String) async throws -> AccountProfile.Device {
        let response: Account.RevokeDevice.Output = try await caller.unary(Account.RevokeDevice.descriptor, Account.RevokeDevice.Input.with { $0.deviceID = deviceID }, accessToken: accessToken)
        return response.info
    }
}

// MARK: Response mapping (tested with proto messages)

extension Wiretuner_Account_V1_GetTeamResponse {
    var detail: TeamDetail { TeamDetail(team) }
}

extension Wiretuner_Account_V1_UpdateTeamResponse {
    var detail: TeamDetail { TeamDetail(team) }
}

extension Wiretuner_Account_V1_AcceptInviteResponse {
    var detail: TeamDetail { TeamDetail(team) }
}

extension Wiretuner_Account_V1_ListMembersResponse {
    var page: ([TeamMemberInfo], String) { (members.map(TeamMemberInfo.init), nextCursor) }
}

extension Wiretuner_Account_V1_ListInvitesResponse {
    var page: ([TeamInviteInfo], String) { (invites.map(TeamInviteInfo.init), nextCursor) }
}

extension Wiretuner_Account_V1_InviteMemberResponse {
    var info: TeamInviteInfo { TeamInviteInfo(invite) }
}

extension Wiretuner_Account_V1_SetMemberRoleResponse {
    var info: TeamMemberInfo { TeamMemberInfo(member) }
}

extension Wiretuner_Account_V1_AddWorkspaceDomainResponse {
    var info: WorkspaceDomainInfo { WorkspaceDomainInfo(domain) }
}

extension Wiretuner_Account_V1_VerifyWorkspaceDomainResponse {
    var info: WorkspaceDomainInfo { WorkspaceDomainInfo(domain) }
}

extension Wiretuner_Account_V1_SetWorkspaceSettingsResponse {
    var info: WorkspaceInfo { WorkspaceInfo(workspace) }
}

extension Wiretuner_Account_V1_ListDevicesResponse {
    var page: ([AccountProfile.Device], String) { (devices.map(AccountProfile.Device.init), nextCursor) }
}

extension Wiretuner_Account_V1_RevokeDeviceResponse {
    var info: AccountProfile.Device { AccountProfile.Device(device) }
}
