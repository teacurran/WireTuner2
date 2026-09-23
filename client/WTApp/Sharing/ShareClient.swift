import Foundation
import GRPCCore
import SwiftProtobuf
import WTProto

/// The `ShareService` RPCs the Share sheet uses (COLLAB-013; sharing.adoc).  A protocol so the
/// sheet's model is tested against fakes.  Paged lists come back whole.
protocol ShareClient: Sendable {
    func listMembers(documentID: String, accessToken: String) async throws -> ShareRoster
    func invite(documentID: String, email: String, role: DocumentRole, message: String, accessToken: String) async throws -> ShareMember
    func setRole(documentID: String, accountID: String, role: DocumentRole, accessToken: String) async throws -> ShareMember
    /// The member when access remains through the team or a link; nil when none is left.
    func removeMember(documentID: String, accountID: String, accessToken: String) async throws -> ShareMember?
    /// nil clears the override.
    func setTeamAccess(documentID: String, override: DocumentRole?, accessToken: String) async throws -> TeamAccessInfo
    func listLinks(documentID: String, accessToken: String) async throws -> [ShareLinkInfo]
    func createLink(documentID: String, options: ShareLinkOptions, accessToken: String) async throws -> CreatedShareLink
    func revokeLink(linkID: String, accessToken: String) async throws
    func listAccessRequests(documentID: String, accessToken: String) async throws -> [AccessRequestInfo]
    /// `grant` nil declines.  The new member when granted.
    func resolveAccessRequest(requestID: String, grant: DocumentRole?, accessToken: String) async throws -> ShareMember?
    /// The new owner and the caller, now an editor.
    func transferOwnership(documentID: String, newOwnerID: String, accessToken: String) async throws -> (owner: ShareMember, previousOwner: ShareMember)
}

/// The request messages, built apart from the calls so they are tested without a server.
enum ShareRequests {
    static func listMembers(documentID: String, cursor: String) -> Wiretuner_Docs_V1_ListMembersRequest {
        var message = Wiretuner_Docs_V1_ListMembersRequest()
        message.documentID = documentID
        message.cursor = cursor
        message.pageSize = TeamRequests.pageSize
        return message
    }

    static func invite(documentID: String, email: String, role: DocumentRole, message note: String) -> Wiretuner_Docs_V1_InviteRequest {
        var message = Wiretuner_Docs_V1_InviteRequest()
        message.documentID = documentID
        message.email = email
        message.role = role.proto
        message.message = note
        return message
    }

    static func setRole(documentID: String, accountID: String, role: DocumentRole) -> Wiretuner_Docs_V1_SetRoleRequest {
        var message = Wiretuner_Docs_V1_SetRoleRequest()
        message.documentID = documentID
        message.accountID = accountID
        message.role = role.proto
        return message
    }

    static func removeMember(documentID: String, accountID: String) -> Wiretuner_Docs_V1_RemoveMemberRequest {
        var message = Wiretuner_Docs_V1_RemoveMemberRequest()
        message.documentID = documentID
        message.accountID = accountID
        return message
    }

    static func setTeamAccess(documentID: String, override: DocumentRole?) -> Wiretuner_Docs_V1_SetTeamAccessRequest {
        var message = Wiretuner_Docs_V1_SetTeamAccessRequest()
        message.documentID = documentID
        message.override = override?.proto ?? .unspecified
        return message
    }

    static func createLink(documentID: String, options: ShareLinkOptions) -> Wiretuner_Docs_V1_CreateLinkRequest {
        var message = Wiretuner_Docs_V1_CreateLinkRequest()
        message.documentID = documentID
        message.role = options.role.proto
        if let expiresAt = options.expiresAt { message.expiresAt = Google_Protobuf_Timestamp(date: expiresAt) }
        message.revokeOnExpiry = options.revokeOnExpiry
        message.password = options.password
        message.teamMembersOnly = options.teamMembersOnly
        return message
    }

    static func listAccessRequests(documentID: String, cursor: String) -> Wiretuner_Docs_V1_ListAccessRequestsRequest {
        var message = Wiretuner_Docs_V1_ListAccessRequestsRequest()
        message.documentID = documentID
        message.cursor = cursor
        message.pageSize = TeamRequests.pageSize
        return message
    }

    static func resolve(requestID: String, grant: DocumentRole?) -> Wiretuner_Docs_V1_ResolveAccessRequestRequest {
        var message = Wiretuner_Docs_V1_ResolveAccessRequestRequest()
        message.requestID = requestID
        message.grant = grant?.proto ?? .unspecified
        return message
    }

    static func transfer(documentID: String, newOwnerID: String) -> Wiretuner_Docs_V1_TransferOwnershipRequest {
        var message = Wiretuner_Docs_V1_TransferOwnershipRequest()
        message.documentID = documentID
        message.newOwnerAccountID = newOwnerID
        return message
    }

    /// Every page of `ListMembers`: the members in order, the team row from the first page.
    static func roster(_ fetch: (String) async throws -> Wiretuner_Docs_V1_ListMembersResponse) async throws -> ShareRoster {
        var teamAccess: TeamAccessInfo?
        let members = try await TeamRequests.allPages { cursor in
            let page = try await fetch(cursor)
            if page.hasTeamAccess, teamAccess == nil { teamAccess = TeamAccessInfo(page.teamAccess) }
            return (page.members.map(ShareMember.init), page.nextCursor)
        }
        return ShareRoster(members: members, teamAccess: teamAccess)
    }
}

/// `ShareService` over gRPC (`UnaryCaller`; in the app `GRPCUnaryCaller`, one connection per
/// call).  Requests are built by `ShareRequests` and responses mapped by the extensions below.
struct GRPCShareClient: ShareClient {
    typealias Share = Wiretuner_Docs_V1_ShareService.Method

    let caller: any UnaryCaller

    init(caller: any UnaryCaller) {
        self.caller = caller
    }

    init(api: URL, clientVersion: String, deviceID: String) {
        self.init(caller: GRPCUnaryCaller(api: api, clientVersion: clientVersion, deviceID: deviceID))
    }

    var clientVersion: String? { (caller as? GRPCUnaryCaller)?.clientVersion }

    func listMembers(documentID: String, accessToken: String) async throws -> ShareRoster {
        try await ShareRequests.roster { cursor in
            try await caller.unary(Share.ListMembers.descriptor, ShareRequests.listMembers(documentID: documentID, cursor: cursor), accessToken: accessToken)
        }
    }

    func invite(documentID: String, email: String, role: DocumentRole, message: String, accessToken: String) async throws -> ShareMember {
        let request = ShareRequests.invite(documentID: documentID, email: email, role: role, message: message)
        let response: Share.Invite.Output = try await caller.unary(Share.Invite.descriptor, request, accessToken: accessToken)
        return response.info
    }

    func setRole(documentID: String, accountID: String, role: DocumentRole, accessToken: String) async throws -> ShareMember {
        let request = ShareRequests.setRole(documentID: documentID, accountID: accountID, role: role)
        let response: Share.SetRole.Output = try await caller.unary(Share.SetRole.descriptor, request, accessToken: accessToken)
        return response.info
    }

    func removeMember(documentID: String, accountID: String, accessToken: String) async throws -> ShareMember? {
        let request = ShareRequests.removeMember(documentID: documentID, accountID: accountID)
        let response: Share.RemoveMember.Output = try await caller.unary(Share.RemoveMember.descriptor, request, accessToken: accessToken)
        return response.info
    }

    func setTeamAccess(documentID: String, override: DocumentRole?, accessToken: String) async throws -> TeamAccessInfo {
        let request = ShareRequests.setTeamAccess(documentID: documentID, override: override)
        let response: Share.SetTeamAccess.Output = try await caller.unary(Share.SetTeamAccess.descriptor, request, accessToken: accessToken)
        return response.info
    }

    func listLinks(documentID: String, accessToken: String) async throws -> [ShareLinkInfo] {
        let response: Share.ListLinks.Output = try await caller.unary(Share.ListLinks.descriptor, Share.ListLinks.Input.with { $0.documentID = documentID }, accessToken: accessToken)
        return response.info
    }

    func createLink(documentID: String, options: ShareLinkOptions, accessToken: String) async throws -> CreatedShareLink {
        let request = ShareRequests.createLink(documentID: documentID, options: options)
        let response: Share.CreateLink.Output = try await caller.unary(Share.CreateLink.descriptor, request, accessToken: accessToken)
        return response.info
    }

    func revokeLink(linkID: String, accessToken: String) async throws {
        let _: Share.RevokeLink.Output = try await caller.unary(Share.RevokeLink.descriptor, Share.RevokeLink.Input.with { $0.linkID = linkID }, accessToken: accessToken)
    }

    func listAccessRequests(documentID: String, accessToken: String) async throws -> [AccessRequestInfo] {
        try await TeamRequests.allPages { cursor in
            let request = ShareRequests.listAccessRequests(documentID: documentID, cursor: cursor)
            let response: Share.ListAccessRequests.Output = try await caller.unary(Share.ListAccessRequests.descriptor, request, accessToken: accessToken)
            return response.page
        }
    }

    func resolveAccessRequest(requestID: String, grant: DocumentRole?, accessToken: String) async throws -> ShareMember? {
        let request = ShareRequests.resolve(requestID: requestID, grant: grant)
        let response: Share.ResolveAccessRequest.Output = try await caller.unary(Share.ResolveAccessRequest.descriptor, request, accessToken: accessToken)
        return response.info
    }

    func transferOwnership(documentID: String, newOwnerID: String, accessToken: String) async throws -> (owner: ShareMember, previousOwner: ShareMember) {
        let request = ShareRequests.transfer(documentID: documentID, newOwnerID: newOwnerID)
        let response: Share.TransferOwnership.Output = try await caller.unary(Share.TransferOwnership.descriptor, request, accessToken: accessToken)
        return response.info
    }
}

// MARK: Response mapping (tested with proto messages)

extension Wiretuner_Docs_V1_InviteResponse {
    var info: ShareMember { ShareMember(member) }
}

extension Wiretuner_Docs_V1_SetRoleResponse {
    var info: ShareMember { ShareMember(member) }
}

extension Wiretuner_Docs_V1_RemoveMemberResponse {
    var info: ShareMember? { hasMember ? ShareMember(member) : nil }
}

extension Wiretuner_Docs_V1_SetTeamAccessResponse {
    var info: TeamAccessInfo { TeamAccessInfo(teamAccess) }
}

extension Wiretuner_Docs_V1_ListLinksResponse {
    var info: [ShareLinkInfo] { links.map(ShareLinkInfo.init) }
}

extension Wiretuner_Docs_V1_CreateLinkResponse {
    var info: CreatedShareLink { CreatedShareLink(link: ShareLinkInfo(link), token: token) }
}

extension Wiretuner_Docs_V1_ListAccessRequestsResponse {
    var page: ([AccessRequestInfo], String) { (requests.map(AccessRequestInfo.init), nextCursor) }
}

extension Wiretuner_Docs_V1_ResolveAccessRequestResponse {
    var info: ShareMember? { hasMember ? ShareMember(member) : nil }
}

extension Wiretuner_Docs_V1_TransferOwnershipResponse {
    var info: (owner: ShareMember, previousOwner: ShareMember) { (ShareMember(owner), ShareMember(previousOwner)) }
}
