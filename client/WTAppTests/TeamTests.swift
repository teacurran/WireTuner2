import AppKit
import Foundation
import GRPCCore
import SwiftProtobuf
import SwiftUI
import Testing
import WTProto
@testable import WireTuner

@Suite struct TeamTypeTests {
    @Test func rolesRankMapAndLimitWhatTheyGrant() {
        #expect(DocumentRole.allRanks == [1, 2, 3, 4])
        #expect(DocumentRole.owner.grantableRoles == [.editor, .commenter, .viewer])
        #expect(DocumentRole.editor.grantableRoles == [.editor, .commenter, .viewer])
        #expect(DocumentRole.commenter.grantableRoles == [.commenter, .viewer])
        #expect(DocumentRole.viewer.grantableRoles == [.viewer])
        for role in [DocumentRole.owner, .editor, .commenter, .viewer] { #expect(DocumentRole(role.proto) == role) }

        #expect(TeamRole.allCases.map(\.title) == ["Owner", "Admin", "Member", "Guest"])
        #expect(TeamRole.allCases.map(\.rank) == [3, 2, 1, 0])
        for role in TeamRole.allCases { #expect(TeamRole(role.proto) == role) }
        #expect(TeamRole(.unspecified) == nil)
        #expect(TeamRole.owner.assignableRoles == [.admin, .member, .guest])
        #expect(TeamRole.admin.assignableRoles == [.member, .guest])
        #expect(TeamRole.member.assignableRoles.isEmpty && TeamRole.guest.assignableRoles.isEmpty)
        #expect(TeamRole.admin.administers && TeamRole.owner.administers && !TeamRole.member.administers)
    }

    @Test func teamsMapFromTheirProtos() {
        var settings = Wiretuner_Account_V1_WorkspaceSettings()
        settings.ssoIdpAlias = "acme"
        settings.requireSso = true
        settings.autoAdmit = true
        settings.restrictSharing = true
        settings.restrictPackageExport = true
        var verified = Wiretuner_Account_V1_WorkspaceDomain()
        verified.domain = "acme.com"
        verified.verificationToken = "abc"
        verified.verifiedAt = Google_Protobuf_Timestamp(seconds: 100)
        var pending = Wiretuner_Account_V1_WorkspaceDomain()
        pending.domain = "acme.io"
        pending.verificationToken = "def"
        var team = Wiretuner_Account_V1_Team()
        team.id = "t1"
        team.name = "Acme"
        team.slug = "acme"
        team.memberCount = 4
        team.defaultDocumentRole = .commenter
        team.callerRole = .admin
        team.workspace.settings = settings
        team.workspace.domains = [verified, pending]
        let detail = TeamDetail(team)
        #expect(detail.id == "t1" && detail.name == "Acme" && detail.slug == "acme" && detail.memberCount == 4)
        #expect(detail.defaultDocumentRole == .commenter && detail.callerRole == .admin)
        #expect(detail.workspace.settings == WorkspaceSettingsValue(ssoAlias: "acme", requireSSO: true, autoAdmit: true, restrictSharing: true, restrictPackageExport: true))
        #expect(WorkspaceSettingsValue(detail.workspace.settings.proto) == detail.workspace.settings)
        #expect(detail.workspace.domains.map(\.isVerified) == [true, false])
        #expect(detail.workspace.domains[1].txtRecord == "wiretuner-verification=def")
        #expect(detail.workspace.domains[0].id == "acme.com")

        var member = Wiretuner_Account_V1_TeamMember()
        member.accountID = "a1"
        member.displayName = "Priya"
        member.email = "p@acme.com"
        member.role = .guest
        member.joinedAt = Google_Protobuf_Timestamp(seconds: 5)
        #expect(TeamMemberInfo(member) == TeamMemberInfo(accountID: "a1", displayName: "Priya", email: "p@acme.com", role: .guest, joinedAt: Date(timeIntervalSince1970: 5)))
        member.role = .unspecified
        member.clearJoinedAt()
        #expect(TeamMemberInfo(member).role == .member && TeamMemberInfo(member).joinedAt == nil && TeamMemberInfo(member).id == "a1")

        var invite = Wiretuner_Account_V1_TeamInvite()
        invite.id = "i1"
        invite.email = "x@acme.com"
        invite.role = .admin
        invite.expiresAt = Google_Protobuf_Timestamp(seconds: 9)
        #expect(TeamInviteInfo(invite) == TeamInviteInfo(id: "i1", email: "x@acme.com", role: .admin, expiresAt: Date(timeIntervalSince1970: 9)))
        invite.role = .unspecified
        invite.clearExpiresAt()
        #expect(TeamInviteInfo(invite).role == .member && TeamInviteInfo(invite).expiresAt == nil)
    }

    @Test func responsesMapThemselves() {
        var team = Wiretuner_Account_V1_Team()
        team.id = "t"
        #expect(Wiretuner_Account_V1_GetTeamResponse.with { $0.team = team }.detail.id == "t")
        #expect(Wiretuner_Account_V1_UpdateTeamResponse.with { $0.team = team }.detail.id == "t")
        #expect(Wiretuner_Account_V1_AcceptInviteResponse.with { $0.team = team }.detail.id == "t")
        let members = Wiretuner_Account_V1_ListMembersResponse.with {
            $0.members = [.with { $0.accountID = "a" }]
            $0.nextCursor = "c"
        }.page
        #expect(members.0.map(\.accountID) == ["a"] && members.1 == "c")
        let invites = Wiretuner_Account_V1_ListInvitesResponse.with { $0.invites = [.with { $0.id = "i" }] }.page
        #expect(invites.0.map(\.id) == ["i"] && invites.1.isEmpty)
        #expect(Wiretuner_Account_V1_InviteMemberResponse.with { $0.invite.id = "i" }.info.id == "i")
        #expect(Wiretuner_Account_V1_SetMemberRoleResponse.with { $0.member.accountID = "a" }.info.accountID == "a")
        #expect(Wiretuner_Account_V1_AddWorkspaceDomainResponse.with { $0.domain.domain = "a.com" }.info.domain == "a.com")
        #expect(Wiretuner_Account_V1_VerifyWorkspaceDomainResponse.with { $0.domain.domain = "b.com" }.info.domain == "b.com")
        #expect(Wiretuner_Account_V1_SetWorkspaceSettingsResponse.with { $0.workspace.settings.requireSso = true }.info.settings.requireSSO)
        let devices = Wiretuner_Account_V1_ListDevicesResponse.with {
            $0.devices = [.with {
                $0.id = "d"
                $0.revokedAt = Google_Protobuf_Timestamp(seconds: 3)
            }]
        }.page
        #expect(devices.0.first?.revokedAt == Date(timeIntervalSince1970: 3) && devices.1.isEmpty)
        #expect(Wiretuner_Account_V1_RevokeDeviceResponse.with { $0.device.id = "d" }.info.revokedAt == nil)
    }

    @Test func requestsCarryWhatTheSheetChose() async throws {
        #expect(TeamRequests.updateDefaultRole(teamID: "t", role: .viewer).defaultDocumentRole == .viewer)
        #expect(TeamRequests.updateDefaultRole(teamID: "t", role: .viewer).hasDefaultDocumentRole)
        let members = TeamRequests.listMembers(teamID: "t", cursor: "c")
        #expect(members.teamID == "t" && members.cursor == "c" && members.pageSize == 50)
        let invites = TeamRequests.listInvites(teamID: "t", cursor: "")
        #expect(invites.teamID == "t" && invites.pageSize == 50)
        let invite = TeamRequests.invite(teamID: "t", email: "e@x.com", role: .guest)
        #expect(invite.email == "e@x.com" && invite.role == .guest)
        let revoke = TeamRequests.revokeInvite(teamID: "t", inviteID: "i")
        #expect(revoke.inviteID == "i" && revoke.teamID == "t")
        let role = TeamRequests.setMemberRole(teamID: "t", accountID: "a", role: .admin)
        #expect(role.accountID == "a" && role.role == .admin)
        #expect(TeamRequests.removeMember(teamID: "t", accountID: "a").accountID == "a")
        let settings = TeamRequests.setWorkspaceSettings(teamID: "t", settings: WorkspaceSettingsValue(ssoAlias: "acme", requireSSO: true))
        #expect(settings.settings.ssoIdpAlias == "acme" && settings.settings.requireSso)
        #expect(TeamRequests.listDevices(cursor: "c").cursor == "c")

        var cursors: [String] = []
        let all = try await TeamRequests.allPages { cursor -> ([Int], String) in
            cursors.append(cursor)
            return cursor.isEmpty ? ([1, 2], "next") : ([3], "")
        }
        #expect(all == [1, 2, 3] && cursors == ["", "next"])
    }

    @Test func invitationLinksYieldTheirToken() {
        let token = "AbCdEfGhIjKlMnOpQrStUv-_0123456789"
        #expect(InviteLink.token(in: "wiretuner://invite/\(token)") == token)
        #expect(InviteLink.token(in: "  https://wiretuner.app/invite/\(token)\n") == token)
        #expect(InviteLink.token(in: token) == token)
        #expect(InviteLink.token(in: "https://wiretuner.app/l/\(token)") == nil)
        #expect(InviteLink.token(in: "wiretuner://invite/short") == nil)
        #expect(InviteLink.token(in: "wiretuner://invite") == nil)
        #expect(InviteLink.token(in: "not a token!") == nil)
        #expect(InviteLink.token(in: "") == nil)
        #expect(InviteLink.token(in: URL(string: "wiretuner://auth/callback?code=c")!) == nil)
    }

    @Test func linksPointAtTheLinksHost() {
        #expect(LinkConfiguration.base(infoDictionary: nil) == LinkConfiguration.defaultBase)
        #expect(LinkConfiguration.base(infoDictionary: ["WTLinksURL": ""]) == LinkConfiguration.defaultBase)
        #expect(LinkConfiguration.base(infoDictionary: ["WTLinksURL": "no scheme"]) == LinkConfiguration.defaultBase)
        #expect(LinkConfiguration.base(infoDictionary: ["WTLinksURL": "https://share.example"]).absoluteString == "https://share.example")
        #expect(LinkConfiguration.shareURL(base: URL(string: "https://share.example")!, token: "tok").absoluteString == "https://share.example/l/tok")
        let tokens = ShareLinkTokens()
        tokens["l"] = "t"
        #expect(tokens["l"] == "t" && tokens["m"] == nil)
        #expect(CollaborationErrors.isOffline(LibraryClientError.offline) && !CollaborationErrors.isOffline(CocoaError(.fileNoSuchFile)))
    }

    @Test func theGRPCClientReachesTheConfiguredAPIAndFailsFastWithoutAServer() async {
        let client = GRPCTeamClient(api: URL(string: "http://127.0.0.1:1")!, clientVersion: "v", deviceID: "d")
        let endpoint = (client.caller as? GRPCUnaryCaller)?.endpoint
        #expect(endpoint?.host == "127.0.0.1" && endpoint?.port == 1 && endpoint?.tls == false && client.clientVersion == "v")
        let t = "token"
        await #expect(throws: (any Error).self) { try await client.getTeam(teamID: "t", accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.setDefaultDocumentRole(teamID: "t", role: .viewer, accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.listMembers(teamID: "t", accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.listInvites(teamID: "t", accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.invite(teamID: "t", email: "e@x.com", role: .member, accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.revokeInvite(teamID: "t", inviteID: "i", accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.setMemberRole(teamID: "t", accountID: "a", role: .guest, accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.removeMember(teamID: "t", accountID: "a", accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.addDomain(teamID: "t", domain: "a.com", accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.verifyDomain(teamID: "t", domain: "a.com", accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.removeDomain(teamID: "t", domain: "a.com", accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.setWorkspaceSettings(teamID: "t", settings: WorkspaceSettingsValue(), accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.acceptInvite(token: "0123456789abcdef", accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.listDevices(accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.revokeDevice(deviceID: "d", accessToken: t) }
        let tls = GRPCTeamClient(api: URL(string: "https://127.0.0.1:1")!, clientVersion: "v", deviceID: "d")
        await #expect(throws: (any Error).self) { try await tls.getTeam(teamID: "t", accessToken: t) }
    }

    @Test @MainActor func theLaunchEnvironmentBuildsGRPCCollaborationClients() async {
        let suite = TestDefaults()
        let account = LaunchEnvironment().makeAccountModel(infoDictionary: nil, defaults: suite.defaults)
        #expect(account.deviceClient is GRPCTeamClient)
        let services = LaunchEnvironment().makeCollaborationServices(
            account: account, infoDictionary: ["CFBundleShortVersionString": "1.2", "CFBundleVersion": "3", "WTLinksURL": "https://l.example"],
            defaults: suite.defaults
        )
        #expect((services.teams as? GRPCTeamClient)?.clientVersion == "1.2/3")
        #expect((services.shares as? GRPCShareClient)?.clientVersion == "1.2/3")
        #expect(services.links.absoluteString == "https://l.example")
        let fallback = LaunchEnvironment().makeCollaborationServices(account: account, infoDictionary: nil, defaults: suite.defaults)
        #expect((fallback.teams as? GRPCTeamClient)?.clientVersion == "0/0")
        await #expect(throws: AuthError.notSignedIn) { try await services.accessToken() }
        suite.remove()
    }
}

extension DocumentRole {
    static var allRanks: [Int] { [DocumentRole.viewer, .commenter, .editor, .owner].map(\.rank) }
}

@Suite @MainActor struct TeamSettingsModelTests {
    static let owner = TeamMemberInfo(accountID: FakeCollaborationServer.me, displayName: "Priya", email: "p@acme.com", role: .owner)
    static let admin = TeamMemberInfo(accountID: "a-admin", displayName: "Ada", email: "ada@acme.com", role: .admin)
    static let member = TeamMemberInfo(accountID: "a-member", displayName: "Sam", email: "sam@acme.com", role: .member)
    static let guest = TeamMemberInfo(accountID: "a-guest", displayName: "Gil", email: "gil@x.com", role: .guest)

    func server(callerRole: TeamRole = .owner, alias: String = "") -> FakeCollaborationServer {
        let server = FakeCollaborationServer()
        server.team = TeamDetail(
            id: FakeCollaborationServer.teamID, name: "Marketing", memberCount: 4, defaultDocumentRole: .editor, callerRole: callerRole,
            workspace: WorkspaceInfo(settings: WorkspaceSettingsValue(ssoAlias: alias), domains: [WorkspaceDomainInfo(domain: "acme.com", verificationToken: "tok", verifiedAt: nil)])
        )
        server.members = [Self.owner, Self.admin, Self.member, Self.guest]
        server.invites = [TeamInviteInfo(id: "i1", email: "new@acme.com", role: .member, expiresAt: Date(timeIntervalSince1970: 2_000_000_000))]
        return server
    }

    func model(_ server: FakeCollaborationServer, signedIn: Bool = true) -> TeamSettingsModel {
        TeamSettingsModel(teamID: FakeCollaborationServer.teamID, services: server.services(signedIn: signedIn), accountID: FakeCollaborationServer.me)
    }

    @Test func theOwnerSeesEverythingAndManagesAdmins() async {
        let server = server()
        let model = model(server)
        #expect(!model.canAdminister && !model.canSeeMembers && model.inviteRoles.isEmpty && model.domains.isEmpty)
        await model.load()
        #expect(model.team?.name == "Marketing" && model.members.count == 4 && model.invites.count == 1)
        #expect(model.isOnline && !model.isLoading && model.canAdminister && model.canEdit)
        #expect(model.inviteRoles == [.admin, .member, .guest])
        #expect(!model.canChange(Self.owner), "nobody changes the owner here, least of all themselves")
        #expect(model.canChange(Self.admin) && model.canChange(Self.member) && model.canChange(Self.guest))
        #expect(model.roleOptions(for: Self.member) == [.admin, .member, .guest])
        #expect(model.roleOptions(for: Self.owner) == [.owner, .admin, .member, .guest])
        Render.view(TeamSettingsView(model: model))
    }

    @Test func anAdminLeavesAdminsToTheOwner() async {
        let model = model(server(callerRole: .admin))
        await model.load()
        #expect(model.inviteRoles == [.member, .guest])
        #expect(!model.canChange(Self.admin) && model.canChange(Self.member))
        #expect(model.roleOptions(for: Self.admin) == [.admin, .member, .guest])
        Render.view(TeamSettingsView(model: model))
    }

    @Test func membersSeeTheListAndGuestsSeeOnlyTheTeam() async {
        let server = server(callerRole: .member)
        let member = model(server)
        await member.load()
        #expect(member.members.count == 4 && member.invites.isEmpty && !member.canEdit && !member.canChange(Self.guest))
        #expect(!server.calls.contains("listInvites"))
        Render.view(TeamSettingsView(model: member))

        let guestServer = self.server(callerRole: .guest)
        let guest = model(guestServer)
        await guest.load()
        #expect(guest.members.isEmpty && !guest.canSeeMembers)
        #expect(!guestServer.calls.contains("listTeamMembers"))
        Render.view(TeamSettingsView(model: guest))
    }

    @Test func invitationsAreSentResentAndRevoked() async {
        let server = server()
        let model = model(server)
        await model.load()
        #expect(!model.canInvite)
        model.inviteEmail = " kim@acme.com "
        model.inviteRole = .guest
        #expect(model.canInvite)
        await model.perform(.invite)
        #expect(model.inviteEmail.isEmpty && model.notice == "Invitation sent to kim@acme.com.")
        #expect(model.invites.map(\.email) == ["new@acme.com", "kim@acme.com"] && model.invites.last?.role == .guest)
        let pending = model.invites[0]
        await model.perform(.resend(pending))
        #expect(model.notice == "Invitation sent again to new@acme.com." && model.invites.count == 2)
        #expect(model.invites.last?.email == "new@acme.com")
        let resent = model.invites.last!
        await model.perform(.revoke(resent))
        #expect(model.invites.map(\.email) == ["kim@acme.com"] && model.notice == "Invitation to new@acme.com withdrawn.")
        #expect(TeamInvitesSection.caption(model.invites[0]).hasPrefix("Guest · expires "))
        #expect(TeamInvitesSection.caption(TeamInviteInfo(id: "x", email: "e", role: .member, expiresAt: nil)) == "Member")

        server.failNext(with: RPCError(code: .alreadyExists, message: "ALREADY_MEMBER"))
        model.inviteEmail = "sam@acme.com"
        await model.perform(.invite)
        #expect(model.errorMessage == "ALREADY_MEMBER" && model.inviteEmail == "sam@acme.com" && model.notice == nil)
        server.failNext(with: RPCError(code: .notFound, message: "INVITE_INVALID"))
        await model.perform(.revoke(model.invites[0]))
        #expect(model.invites.count == 1)
    }

    @Test func rolesChangeAndRemovalsAreConfirmed() async {
        let server = server()
        let model = model(server)
        await model.load()
        await model.perform(.setRole(Self.member, .member))
        #expect(!server.calls.contains("setMemberRole"), "choosing the same role sends nothing")
        model.roleBinding(for: Self.member).wrappedValue = .admin
        await model.lastTask?.value
        #expect(model.members.first { $0.accountID == Self.member.accountID }?.role == .admin)
        #expect(model.roleBinding(for: Self.guest).wrappedValue == .guest)

        await model.perform(.confirmRemove(Self.guest))
        #expect(model.confirmingRemoval == Self.guest)
        Render.view(TeamSettingsView(model: model))
        await model.perform(.cancelConfirmation)
        #expect(model.confirmingRemoval == nil)
        model.handler(.confirmRemove(Self.guest))()
        await model.lastTask?.value
        await model.perform(.remove(Self.guest))
        #expect(model.confirmingRemoval == nil && !model.members.contains(Self.guest) && model.notice == "Gil was removed from the team.")
        server.failNext(with: RPCError(code: .permissionDenied, message: "ROLE_INSUFFICIENT"))
        await model.perform(.remove(Self.admin))
        #expect(model.members.contains(Self.admin) && model.errorMessage == "ROLE_INSUFFICIENT")
    }

    @Test func domainsAreAddedVerifiedAndRemoved() async {
        let server = server()
        let model = model(server)
        await model.load()
        #expect(!model.canAddDomain)
        model.newDomain = " Acme.IO "
        #expect(model.canAddDomain)
        await model.perform(.addDomain)
        #expect(model.newDomain.isEmpty && model.domains.map(\.domain) == ["acme.com", "acme.io"])
        let domain = model.domains[1]
        await model.perform(.verify(domain))
        #expect(!model.domains[1].isVerified && model.notice == "acme.io is not verified yet. Add the TXT record and try again.")
        server.verifies = true
        await model.perform(.verify(domain))
        #expect(model.domains[1].isVerified && model.notice == "acme.io is verified.")
        Render.view(TeamSettingsView(model: model))
        await model.perform(.removeDomain(domain))
        #expect(model.domains.map(\.domain) == ["acme.com"])
        server.failNext(with: RPCError(code: .alreadyExists, message: "DOMAIN_TAKEN"))
        model.newDomain = "taken.com"
        await model.perform(.addDomain)
        #expect(model.newDomain == "taken.com" && model.errorMessage == "DOMAIN_TAKEN")
        server.failNext(with: RPCError(code: .notFound, message: "DOMAIN_NOT_FOUND"))
        await model.perform(.removeDomain(model.domains[0]))
        #expect(model.domains.count == 1)
    }

    @Test func theWorkspaceSwitchesAndDefaultAccessChange() async {
        let server = server(alias: "acme")
        let model = model(server)
        #expect(!model.switchBinding(.requireSSO).wrappedValue && model.defaultRoleBinding.wrappedValue == .viewer)
        await model.load()
        #expect(model.allSwitches.allSatisfy(model.isEnabled))
        model.switchBinding(.requireSSO).wrappedValue = true
        await model.lastTask?.value
        model.switchBinding(.restrictSharing).wrappedValue = true
        await model.lastTask?.value
        model.switchBinding(.autoAdmit).wrappedValue = true
        await model.lastTask?.value
        #expect(model.settings.requireSSO && model.settings.restrictSharing && model.settings.autoAdmit)
        #expect(server.team.workspace.settings.requireSSO)
        await model.perform(.setSwitch(.autoAdmit, true))
        #expect(server.calls.filter { $0 == "setWorkspaceSettings" }.count == 3, "an unchanged switch sends nothing")
        await model.perform(.setSwitch(.autoAdmit, false))
        #expect(!model.settings.autoAdmit)
        #expect(TeamSettingsModel.WorkspaceSwitch.allCases.map(\.title).count == 3)

        model.defaultRoleBinding.wrappedValue = .viewer
        await model.lastTask?.value
        #expect(model.team?.defaultDocumentRole == .viewer && model.defaultRoleBinding.wrappedValue == .viewer)
        await model.perform(.setDefaultRole(.viewer))
        #expect(server.calls.filter { $0 == "setDefaultDocumentRole" }.count == 1)
        Render.view(TeamSettingsView(model: model))

        let noAlias = self.model(self.server())
        await noAlias.load()
        #expect(!noAlias.isEnabled(.requireSSO) && noAlias.isEnabled(.restrictSharing))
    }

    @Test func offlineNothingChangesAndTheSheetSaysWhy() async {
        let server = server()
        server.offline = true
        let model = model(server)
        await model.load()
        #expect(!model.isOnline && model.errorMessage == nil && model.team == nil)
        Render.view(TeamSettingsView(model: model))
        server.offline = false
        await model.perform(.reload)
        #expect(model.isOnline && model.canEdit)
        server.offline = true
        model.inviteEmail = "kim@acme.com"
        await model.perform(.invite)
        #expect(!model.isOnline && !model.canEdit && !model.canInvite && model.inviteEmail == "kim@acme.com")
        Render.view(TeamSettingsView(model: model))

        let signedOut = self.model(self.server(), signedIn: false)
        await signedOut.load()
        #expect(!signedOut.isOnline)
    }

    @Test func doneClosesTheSheet() async {
        let model = model(server())
        var closed = 0
        model.onDone = { closed += 1 }
        model.handler(.done)()
        await model.lastTask?.value
        #expect(closed == 1)
        await model.send(.reload).value
        #expect(model.team != nil)
    }
}

extension TeamSettingsModel {
    var allSwitches: [WorkspaceSwitch] { WorkspaceSwitch.allCases }
}

@Suite @MainActor struct JoinTeamTests {
    static let token = "AbCdEfGhIjKlMnOpQrStUv-_0123456789"

    @Test func aPastedLinkJoinsTheTeam() async {
        let server = FakeCollaborationServer()
        let model = JoinTeamModel(services: server.services())
        #expect(!model.canJoin && model.linkProblem == nil)
        model.link = "hello"
        #expect(model.linkProblem == JoinTeamModel.invalidLink && !model.canJoin)
        Render.view(JoinTeamView(model: model))
        model.link = "https://wiretuner.app/invite/\(Self.token)"
        #expect(model.token == Self.token && model.canJoin && model.linkProblem == nil)
        var joined: [String] = []
        model.onJoined = { joined.append($0.id) }
        await model.join()
        #expect(model.joined?.name == "Design" && joined == ["t-joined"] && !model.canJoin)
        #expect(server.calls == ["acceptInvite:\(Self.token)"])
        Render.view(JoinTeamView(model: model))
        await model.join()
        #expect(server.calls.count == 2, "joining again is harmless: the server keeps the current role")
    }

    @Test func offlineAndRefusalsAreShown() async throws {
        let server = FakeCollaborationServer()
        let model = JoinTeamModel(services: server.services(), link: "wiretuner://invite/\(Self.token)")
        server.offline = true
        await model.join()
        #expect(!model.isOnline && model.joined == nil)
        server.offline = false
        server.failNext(with: RPCError(code: .failedPrecondition, message: "EMAIL_NOT_VERIFIED"))
        await model.join()
        #expect(model.errorMessage == "EMAIL_NOT_VERIFIED")
        Render.view(JoinTeamView(model: model))
        var closed = 0
        model.onDone = { closed += 1 }
        model.doneHandler()()
        #expect(closed == 1)
        model.joinHandler()()
        for _ in 0..<100 where model.joined == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.joined != nil && model.isOnline && model.errorMessage == nil)
        let empty = JoinTeamModel(services: server.services())
        await empty.join()
        #expect(server.calls.count == 3)
    }
}

@Suite(.serialized) @MainActor struct LibraryTeamTests {
    func library(_ server: FakeLibraryServer = FakeLibraryServer(), collaboration: FakeCollaborationServer? = FakeCollaborationServer()) -> LibraryModel {
        let model = LibraryModel(services: server.services(), store: nil, thumbnails: ThumbnailCache(directory: nil))
        model.collaboration = collaboration?.services()
        return model
    }

    @Test func teamSettingsOpenForTeamSpacesOnly() async {
        let server = FakeLibraryServer()
        server.setTeams([LibrarySpace(id: FakeCollaborationServer.teamID, name: "Marketing", kind: .team)])
        let library = library(server)
        await library.refresh()
        #expect(!library.canShowTeamSettings && library.showTeamSettings() == nil)
        await library.switchSpace(to: FakeCollaborationServer.teamID)
        #expect(library.canShowTeamSettings)
        let load = library.showTeamSettings()
        await load?.value
        #expect(library.teamSettings?.team?.name == "Marketing")
        #expect(library.teamSettings?.accountID == server.accountID)
        Render.view(LibraryView(model: library), size: CGSize(width: 900, height: 600))
        library.teamSettings?.onDone()
        #expect(library.teamSettings == nil)
        library.openTeamSettings()
        #expect(library.teamSettings != nil)

        let bare = self.library(collaboration: nil)
        #expect(!bare.canShowTeamSettings && bare.showTeamSettings() == nil && bare.showJoinTeam() == nil)
        Render.view(LibraryView(model: bare), size: CGSize(width: 900, height: 600))
    }

    @Test func joiningATeamShowsItsSpace() async {
        let server = FakeLibraryServer()
        let library = library(server)
        await library.refresh()
        library.openJoinTeam()
        #expect(library.joinTeam?.link == "")
        let join = library.showJoinTeam(link: "wiretuner://invite/\(JoinTeamTests.token)")
        server.setTeams([LibrarySpace(id: "t-joined", name: "Design", kind: .team)])
        await join?.join()
        #expect(library.currentSpaceID == "t-joined" && library.currentSpace.name == "Design")
        join?.onDone()
        #expect(library.joinTeam == nil)

        // Offline after joining: the new team is still in the cached list.
        let offline = FakeLibraryServer()
        offline.offline = true
        let cached = self.library(offline)
        await cached.didJoin(TeamDetail(id: "t-offline", name: "Ops"))
        #expect(cached.spaces.map(\.name) == ["Personal", "Ops"] && cached.currentSpaceID == "t-offline")
        await cached.didJoin(TeamDetail(id: "t-offline", name: "Ops"))
        #expect(cached.spaces.count == 2)
    }

    @Test func theAppOpensInvitationURLsInTheLibrary() async {
        let suite = TestDefaults()
        let server = FakeLibraryServer()
        let library = LibraryModel(services: server.services(), store: nil, thumbnails: ThumbnailCache(directory: nil))
        let collaboration = FakeCollaborationServer()
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults, library: library, collaboration: collaboration.services())
        #expect(library.collaboration != nil)
        #expect(!delegate.open(URL(string: "wiretuner://auth/callback?code=c")!))
        delegate.application(NSApplication.shared, open: [URL(string: "wiretuner://invite/\(JoinTeamTests.token)")!])
        #expect(library.joinTeam?.token == JoinTeamTests.token)
        #expect(delegate.libraryWindowController?.window?.isVisible == true)
        delegate.libraryWindowController?.close()
        suite.remove()
    }
}

@Suite @MainActor struct DeviceListTests {
    static let devices: [AccountProfile.Device] = [
        .init(id: "d1", name: "Studio Mac", platform: "macOS", authMethod: "passkey", lastSeenAt: nil, isCurrent: true),
        .init(id: "d2", name: "Laptop", platform: "macOS", authMethod: "apple", lastSeenAt: nil, isCurrent: false),
        .init(id: "d3", name: "Office", platform: "macOS", authMethod: "sso:acme", lastSeenAt: nil, isCurrent: false),
        .init(id: "d4", name: "Old", platform: "macOS", authMethod: "password", lastSeenAt: nil, isCurrent: false),
    ]

    func model(_ server: FakeCollaborationServer) -> AccountModel {
        let stored = TokenSet(accessToken: makeJWT(["email": "p@example.com"]), refreshToken: "r", idToken: nil, expiresAt: .distantFuture, refreshExpiresAt: nil)
        let base = AccountModelTests().model(stored: stored)
        return AccountModel(auth: base.auth, client: base.client, devices: server)
    }

    @Test func theFullListShowsEachMethodAndRevokesOtherMacs() async {
        let server = FakeCollaborationServer()
        server.devices = Self.devices
        let model = model(server)
        await model.start(autoRefresh: false)
        #expect(model.shownDevices.isEmpty)
        await model.loadProfile()
        #expect(model.shownDevices.map(\.methodTitle) == ["Passkey", "Apple", "acme", "Password"])
        Render.view(AccountView(model: model))
        await model.revokeDevice("d1")
        #expect(!server.calls.contains("revokeDevice:d1"), "this Mac signs out instead")
        await AccountView.perform(.revokeDevice("d2"), model: model)
        #expect(model.shownDevices.map(\.id) == ["d1", "d3", "d4"] && server.calls.contains("revokeDevice:d2"))
        await model.revokeDevice("unknown")
        #expect(!server.calls.contains("revokeDevice:unknown"))
        server.failNext(with: RPCError(code: .notFound, message: "gone"))
        await model.revokeDevice("d3")
        #expect(model.errorMessage != nil && model.shownDevices.count == 3)
        await model.signOut()
        #expect(model.devices == nil && model.shownDevices.isEmpty)
    }

    @Test func withoutADeviceClientTheWindowShowsMesDevice() async {
        let model = AccountModelTests().model()
        #expect(model.deviceClient == nil)
        await model.signIn(.standard, autoRefresh: false)
        await model.loadProfile()
        #expect(model.shownDevices.map(\.id) == ["d1"])
        await model.revokeDevice("d1")
        Render.view(AccountView(model: model))
    }
}

@Suite @MainActor struct TeamSettingsEdgeTests {
    @Test func theSheetShowsLoadingAndErrors() async throws {
        let server = TeamSettingsModelTests().server()
        server.tokenDelay = .milliseconds(300)
        let model = TeamSettingsModel(teamID: FakeCollaborationServer.teamID, services: server.services(), accountID: nil)
        let task = model.send(.reload)
        for _ in 0..<50 where !model.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.isLoading)
        Render.view(TeamSettingsView(model: model))
        await task.value
        server.tokenDelay = .zero
        server.failNext(with: RPCError(code: .permissionDenied, message: "ROLE_INSUFFICIENT"))
        await model.perform(.setSwitch(.restrictSharing, true))
        #expect(model.errorMessage == "ROLE_INSUFFICIENT")
        Render.view(TeamSettingsView(model: model))
        model.onDone()
        JoinTeamModel(services: server.services()).onDone()
        _ = await JoinTeamModel(services: server.services()).onJoined(TeamDetail(id: "t", name: "T"))
    }

    @Test func signedInCollaborationServicesHandOutTheSessionsToken() async throws {
        let server = FakeCollaborationServer()
        let account = DeviceListTests().model(server)
        await account.start(autoRefresh: false)
        let services = LaunchEnvironment().makeCollaborationServices(account: account, infoDictionary: nil, defaults: TestDefaults().defaults)
        #expect(try await services.accessToken().isEmpty == false)
    }
}
