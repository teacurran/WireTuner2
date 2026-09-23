import Foundation
import GRPCCore
import SwiftProtobuf
import Testing
import WTProto
@testable import WireTuner

/// The team, device and share clients end to end over an in-memory caller (`FakeUnaryCaller`):
/// every call's request arrives as built, through the wire encoding, and every response maps
/// back, paging included.  The live caller is checked against a closed port.
@Suite struct CollaborationGRPCTests {
    typealias Team = Wiretuner_Account_V1_TeamService.Method
    typealias Account = Wiretuner_Account_V1_AccountService.Method
    typealias Share = Wiretuner_Docs_V1_ShareService.Method

    static let team = Wiretuner_Account_V1_Team.with {
        $0.id = "t1"
        $0.name = "Acme"
        $0.callerRole = .admin
        $0.defaultDocumentRole = .editor
    }

    static func teamRoutes(_ log: RequestLog) -> [any FakeRoute] {
        var routes: [any FakeRoute] = []
        routes.append(route(Team.GetTeam.descriptor) { (request: Wiretuner_Account_V1_GetTeamRequest) -> Wiretuner_Account_V1_GetTeamResponse in
            log.append("get:\(request.teamID)")
            return .with { $0.team = team }
        })
        routes.append(route(Team.UpdateTeam.descriptor) { (request: Wiretuner_Account_V1_UpdateTeamRequest) -> Wiretuner_Account_V1_UpdateTeamResponse in
            log.append("update:\(request.defaultDocumentRole)")
            return .with {
                $0.team = team
                $0.team.defaultDocumentRole = request.defaultDocumentRole
            }
        })
        routes.append(route(Team.ListMembers.descriptor) { (request: Wiretuner_Account_V1_ListMembersRequest) -> Wiretuner_Account_V1_ListMembersResponse in
            log.append("members:\(request.cursor)")
            return .with {
                $0.members = [.with {
                    $0.accountID = request.cursor.isEmpty ? "a1" : "a2"
                    $0.role = .member
                }]
                $0.nextCursor = request.cursor.isEmpty ? "page2" : ""
            }
        })
        routes.append(route(Team.ListInvites.descriptor) { (_: Wiretuner_Account_V1_ListInvitesRequest) -> Wiretuner_Account_V1_ListInvitesResponse in
            .with { $0.invites = [.with { $0.id = "i1"; $0.email = "new@acme.com"; $0.role = .guest }] }
        })
        routes.append(route(Team.InviteMember.descriptor) { (request: Wiretuner_Account_V1_InviteMemberRequest) -> Wiretuner_Account_V1_InviteMemberResponse in
            .with { $0.invite = .with { $0.id = "i2"; $0.email = request.email; $0.role = request.role } }
        })
        routes.append(route(Team.RevokeInvite.descriptor) { (request: Wiretuner_Account_V1_RevokeInviteRequest) -> Wiretuner_Account_V1_RevokeInviteResponse in
            log.append("revoke:\(request.inviteID)")
            return Wiretuner_Account_V1_RevokeInviteResponse()
        })
        routes.append(route(Team.SetMemberRole.descriptor) { (request: Wiretuner_Account_V1_SetMemberRoleRequest) -> Wiretuner_Account_V1_SetMemberRoleResponse in
            .with { $0.member = .with { $0.accountID = request.accountID; $0.role = request.role } }
        })
        routes.append(route(Team.RemoveMember.descriptor) { (request: Wiretuner_Account_V1_RemoveMemberRequest) -> Wiretuner_Account_V1_RemoveMemberResponse in
            log.append("remove:\(request.accountID)")
            return Wiretuner_Account_V1_RemoveMemberResponse()
        })
        routes.append(route(Team.AddWorkspaceDomain.descriptor) { (request: Wiretuner_Account_V1_AddWorkspaceDomainRequest) -> Wiretuner_Account_V1_AddWorkspaceDomainResponse in
            .with { $0.domain = .with { $0.domain = request.domain; $0.verificationToken = "tok" } }
        })
        routes.append(route(Team.VerifyWorkspaceDomain.descriptor) { (request: Wiretuner_Account_V1_VerifyWorkspaceDomainRequest) -> Wiretuner_Account_V1_VerifyWorkspaceDomainResponse in
            .with {
                $0.verified = true
                $0.domain = .with { $0.domain = request.domain; $0.verifiedAt = Google_Protobuf_Timestamp(seconds: 7) }
            }
        })
        routes.append(route(Team.RemoveWorkspaceDomain.descriptor) { (request: Wiretuner_Account_V1_RemoveWorkspaceDomainRequest) -> Wiretuner_Account_V1_RemoveWorkspaceDomainResponse in
            log.append("dropDomain:\(request.domain)")
            return Wiretuner_Account_V1_RemoveWorkspaceDomainResponse()
        })
        routes.append(route(Team.SetWorkspaceSettings.descriptor) { (request: Wiretuner_Account_V1_SetWorkspaceSettingsRequest) -> Wiretuner_Account_V1_SetWorkspaceSettingsResponse in
            .with { $0.workspace.settings = request.settings }
        })
        routes.append(route(Team.AcceptInvite.descriptor) { (request: Wiretuner_Account_V1_AcceptInviteRequest) -> Wiretuner_Account_V1_AcceptInviteResponse in
            guard request.token.count >= 16 else { throw RPCError(code: .notFound, message: "INVITE_INVALID") }
            return .with { $0.team = team }
        })
        routes.append(route(Account.ListDevices.descriptor) { (_: Wiretuner_Account_V1_ListDevicesRequest) -> Wiretuner_Account_V1_ListDevicesResponse in
            .with { $0.devices = [.with { $0.id = "d1"; $0.authMethod = "passkey"; $0.current = true }] }
        })
        routes.append(route(Account.RevokeDevice.descriptor) { (request: Wiretuner_Account_V1_RevokeDeviceRequest) -> Wiretuner_Account_V1_RevokeDeviceResponse in
            .with { $0.device = .with { $0.id = request.deviceID; $0.revokedAt = Google_Protobuf_Timestamp(seconds: 9) } }
        })
        return routes
    }

    @Test func everyTeamAndDeviceCallRoundTrips() async throws {
        let log = RequestLog()
        let caller = FakeUnaryCaller(Self.teamRoutes(log))
        do {
            let client = GRPCTeamClient(caller: caller)
            let t = "token"
            #expect(try await client.getTeam(teamID: "t1", accessToken: t).callerRole == .admin)
            #expect(try await client.setDefaultDocumentRole(teamID: "t1", role: .viewer, accessToken: t).defaultDocumentRole == .viewer)
            #expect(try await client.listMembers(teamID: "t1", accessToken: t).map(\.accountID) == ["a1", "a2"])
            #expect(try await client.listInvites(teamID: "t1", accessToken: t).map(\.role) == [.guest])
            #expect(try await client.invite(teamID: "t1", email: "kim@acme.com", role: .admin, accessToken: t) == TeamInviteInfo(id: "i2", email: "kim@acme.com", role: .admin, expiresAt: nil))
            try await client.revokeInvite(teamID: "t1", inviteID: "i1", accessToken: t)
            #expect(try await client.setMemberRole(teamID: "t1", accountID: "a1", role: .guest, accessToken: t).role == .guest)
            try await client.removeMember(teamID: "t1", accountID: "a1", accessToken: t)
            #expect(try await client.addDomain(teamID: "t1", domain: "acme.com", accessToken: t).txtRecord == "wiretuner-verification=tok")
            #expect(try await client.verifyDomain(teamID: "t1", domain: "acme.com", accessToken: t).isVerified)
            try await client.removeDomain(teamID: "t1", domain: "acme.com", accessToken: t)
            #expect(try await client.setWorkspaceSettings(teamID: "t1", settings: WorkspaceSettingsValue(ssoAlias: "acme", requireSSO: true), accessToken: t).settings.requireSSO)
            #expect(try await client.acceptInvite(token: "0123456789abcdef0123", accessToken: t).name == "Acme")
            await #expect(throws: RPCError.self) { try await client.acceptInvite(token: "short", accessToken: t) }
            #expect(try await client.listDevices(accessToken: t).map(\.methodTitle) == ["Passkey"])
            #expect(try await client.revokeDevice(deviceID: "d2", accessToken: t).revokedAt == Date(timeIntervalSince1970: 9))
        }
        #expect(log.all == ["get:t1", "update:viewer", "members:", "members:page2", "revoke:i1", "remove:a1", "dropDomain:acme.com"])
    }

    static func shareRoutes(_ log: RequestLog) -> [any FakeRoute] {
        var routes: [any FakeRoute] = []
        routes.append(route(Share.ListMembers.descriptor) { (request: Wiretuner_Docs_V1_ListMembersRequest) -> Wiretuner_Docs_V1_ListMembersResponse in
            log.append("members:\(request.documentID):\(request.cursor)")
            return .with {
                $0.members = [.with { $0.accountID = request.cursor.isEmpty ? "a1" : "a2"; $0.role = .owner; $0.effectiveRole = .owner }]
                if request.cursor.isEmpty {
                    $0.teamAccess = .with { $0.teamID = "t1"; $0.teamName = "Acme"; $0.teamDefault = .viewer }
                    $0.nextCursor = "page2"
                }
            }
        })
        routes.append(route(Share.Invite.descriptor) { (request: Wiretuner_Docs_V1_InviteRequest) -> Wiretuner_Docs_V1_InviteResponse in
            log.append("invite:\(request.email):\(request.message)")
            return .with { $0.member = .with { $0.email = request.email; $0.role = request.role; $0.pending = true } }
        })
        routes.append(route(Share.SetRole.descriptor) { (request: Wiretuner_Docs_V1_SetRoleRequest) -> Wiretuner_Docs_V1_SetRoleResponse in
            .with { $0.member = .with { $0.accountID = request.accountID; $0.role = request.role } }
        })
        routes.append(route(Share.RemoveMember.descriptor) { (request: Wiretuner_Docs_V1_RemoveMemberRequest) -> Wiretuner_Docs_V1_RemoveMemberResponse in
            request.accountID == "keeps" ? .with { $0.member = .with { $0.accountID = "keeps"; $0.sources = [.link] } } : Wiretuner_Docs_V1_RemoveMemberResponse()
        })
        routes.append(route(Share.SetTeamAccess.descriptor) { (request: Wiretuner_Docs_V1_SetTeamAccessRequest) -> Wiretuner_Docs_V1_SetTeamAccessResponse in
            .with { $0.teamAccess = .with { $0.teamID = "t1"; $0.override = request.override } }
        })
        routes.append(route(Share.ListLinks.descriptor) { (_: Wiretuner_Docs_V1_ListLinksRequest) -> Wiretuner_Docs_V1_ListLinksResponse in
            .with { $0.links = [.with { $0.id = "l1"; $0.role = .viewer; $0.hasPassword_p = true }] }
        })
        routes.append(route(Share.CreateLink.descriptor) { (request: Wiretuner_Docs_V1_CreateLinkRequest) -> Wiretuner_Docs_V1_CreateLinkResponse in
            log.append("createLink:\(request.role):\(request.hasExpiresAt):\(request.password)")
            return .with {
                $0.link = .with { $0.id = "l2"; $0.role = request.role; $0.teamMembersOnly = request.teamMembersOnly }
                $0.token = "tok"
            }
        })
        routes.append(route(Share.RevokeLink.descriptor) { (request: Wiretuner_Docs_V1_RevokeLinkRequest) -> Wiretuner_Docs_V1_RevokeLinkResponse in
            log.append("revokeLink:\(request.linkID)")
            return Wiretuner_Docs_V1_RevokeLinkResponse()
        })
        routes.append(route(Share.ListAccessRequests.descriptor) { (_: Wiretuner_Docs_V1_ListAccessRequestsRequest) -> Wiretuner_Docs_V1_ListAccessRequestsResponse in
            .with { $0.requests = [.with { $0.id = "r1"; $0.displayName = "Kim" }] }
        })
        routes.append(route(Share.ResolveAccessRequest.descriptor) { (request: Wiretuner_Docs_V1_ResolveAccessRequestRequest) -> Wiretuner_Docs_V1_ResolveAccessRequestResponse in
            request.grant == .unspecified ? Wiretuner_Docs_V1_ResolveAccessRequestResponse() : .with { $0.member = .with { $0.accountID = "kim"; $0.role = request.grant } }
        })
        routes.append(route(Share.TransferOwnership.descriptor) { (request: Wiretuner_Docs_V1_TransferOwnershipRequest) -> Wiretuner_Docs_V1_TransferOwnershipResponse in
            .with {
                $0.owner = .with { $0.accountID = request.newOwnerAccountID; $0.role = .owner }
                $0.previousOwner = .with { $0.accountID = "me"; $0.role = .editor }
            }
        })
        return routes
    }

    @Test func everyShareCallRoundTrips() async throws {
        let log = RequestLog()
        let caller = FakeUnaryCaller(Self.shareRoutes(log))
        do {
            let client = GRPCShareClient(caller: caller)
            let t = "token"
            let roster = try await client.listMembers(documentID: "doc", accessToken: t)
            #expect(roster.members.map(\.accountID) == ["a1", "a2"] && roster.teamAccess?.teamDefault == .viewer)
            let invited = try await client.invite(documentID: "doc", email: "kim@x.com", role: .commenter, message: "hi", accessToken: t)
            #expect(invited.isPending && invited.role == .commenter)
            #expect(try await client.setRole(documentID: "doc", accountID: "a2", role: .viewer, accessToken: t).role == .viewer)
            #expect(try await client.removeMember(documentID: "doc", accountID: "gone", accessToken: t) == nil)
            #expect(try await client.removeMember(documentID: "doc", accountID: "keeps", accessToken: t)?.sources == [.link])
            #expect(try await client.setTeamAccess(documentID: "doc", override: .editor, accessToken: t).override == .editor)
            #expect(try await client.setTeamAccess(documentID: "doc", override: nil, accessToken: t).override == nil)
            #expect(try await client.listLinks(documentID: "doc", accessToken: t).map(\.hasPassword) == [true])
            let created = try await client.createLink(
                documentID: "doc", options: ShareLinkOptions(role: .editor, expiresAt: Date(timeIntervalSince1970: 60), password: "pw", teamMembersOnly: true), accessToken: t
            )
            #expect(created.token == "tok" && created.link.teamMembersOnly && created.link.role == .editor)
            try await client.revokeLink(linkID: "l2", accessToken: t)
            #expect(try await client.listAccessRequests(documentID: "doc", accessToken: t).map(\.name) == ["Kim"])
            #expect(try await client.resolveAccessRequest(requestID: "r1", grant: .viewer, accessToken: t)?.role == .viewer)
            #expect(try await client.resolveAccessRequest(requestID: "r1", grant: nil, accessToken: t) == nil)
            let transfer = try await client.transferOwnership(documentID: "doc", newOwnerID: "a2", accessToken: t)
            #expect(transfer.owner.role == .owner && transfer.previousOwner.role == .editor)
        }
        #expect(caller.tokens.all.allSatisfy { $0 == "token" } && caller.tokens.all.count == 15)
        #expect(log.all == ["members:doc:", "members:doc:page2", "invite:kim@x.com:hi", "createLink:editor:true:pw", "revokeLink:l2"])
    }

    @Test func unknownMethodsAreUnimplementedAndResponsesUnwrap() async throws {
        let client = GRPCTeamClient(caller: FakeUnaryCaller([]))
        await #expect(throws: RPCError.self) { try await client.getTeam(teamID: "t", accessToken: "token") }
        #expect(GRPCTeamClient(caller: FakeUnaryCaller([])).clientVersion == nil)
        #expect(GRPCShareClient(caller: FakeUnaryCaller([])).clientVersion == nil)
        let response = ClientResponse(message: Wiretuner_Account_V1_GetTeamResponse.with { $0.team.id = "t" })
        #expect(try GRPCUnaryCaller.message(response).team.id == "t")
        let refused = ClientResponse<Wiretuner_Account_V1_GetTeamResponse>(of: Wiretuner_Account_V1_GetTeamResponse.self, error: RPCError(code: .permissionDenied, message: "ROLE_INSUFFICIENT"))
        #expect(throws: RPCError.self) { try GRPCUnaryCaller.message(refused) }
    }
}
