import AppKit
import Foundation
import GRPCCore
import SwiftProtobuf
import SwiftUI
import Testing
import WTProto
@testable import WireTuner

@Suite struct ShareTypeTests {
    @Test func membersLinksAndRequestsMapFromTheirProtos() {
        var member = Wiretuner_Docs_V1_Member()
        member.accountID = "a1"
        member.displayName = "Sam"
        member.email = "sam@x.com"
        member.role = .editor
        member.sources = [.named, .link, .unspecified]
        member.effectiveRole = .editor
        member.colorIndex = 3
        member.isCreator = true
        let mapped = ShareMember(member)
        #expect(mapped == ShareMember(accountID: "a1", displayName: "Sam", email: "sam@x.com", role: .editor, sources: [.named, .link], effectiveRole: .editor, colorIndex: 3, isCreator: true))
        #expect(mapped.id == "a1" && mapped.name == "Sam" && !mapped.isOnlyThroughTeam)
        member.accountID = ""
        member.displayName = ""
        member.role = .unspecified
        member.pending = true
        #expect(ShareMember(member).id == "pending:sam@x.com" && ShareMember(member).name == "sam@x.com" && ShareMember(member).role == nil)
        #expect(ShareMember(accountID: "t", displayName: "T", role: nil, sources: [.teamDefault]).isOnlyThroughTeam)
        #expect(AccessSourceKind(.teamDefault) == .teamDefault && AccessSourceKind(.unspecified) == nil)

        var access = Wiretuner_Docs_V1_TeamAccess()
        access.teamID = "t"
        access.teamName = "Marketing"
        access.teamDefault = .editor
        #expect(TeamAccessInfo(access) == TeamAccessInfo(teamID: "t", teamName: "Marketing", teamDefault: .editor, override: nil))
        #expect(TeamAccessInfo(access).effective == .editor)
        access.override = .viewer
        #expect(TeamAccessInfo(access).effective == .viewer)

        var link = Wiretuner_Docs_V1_ShareLink()
        link.id = "l1"
        link.role = .commenter
        link.expiresAt = Google_Protobuf_Timestamp(seconds: 10)
        link.revokeOnExpiry = true
        link.hasPassword_p = true
        link.teamMembersOnly = true
        link.createdAt = Google_Protobuf_Timestamp(seconds: 1)
        link.uses = 2
        #expect(ShareLinkInfo(link) == ShareLinkInfo(
            id: "l1", role: .commenter, expiresAt: Date(timeIntervalSince1970: 10), revokeOnExpiry: true, hasPassword: true, teamMembersOnly: true,
            createdAt: Date(timeIntervalSince1970: 1), uses: 2
        ))
        link.role = .unspecified
        link.clearExpiresAt()
        link.clearCreatedAt()
        #expect(ShareLinkInfo(link).role == .viewer && ShareLinkInfo(link).expiresAt == nil && ShareLinkInfo(link).createdAt == nil)

        var request = Wiretuner_Docs_V1_AccessRequest()
        request.id = "r1"
        request.accountID = "a2"
        request.email = "kim@x.com"
        request.message = "please"
        request.createdAt = Google_Protobuf_Timestamp(seconds: 4)
        #expect(AccessRequestInfo(request) == AccessRequestInfo(id: "r1", accountID: "a2", displayName: "", email: "kim@x.com", message: "please", createdAt: Date(timeIntervalSince1970: 4)))
        #expect(AccessRequestInfo(request).name == "kim@x.com")
        request.clearCreatedAt()
        request.displayName = "Kim"
        #expect(AccessRequestInfo(request).createdAt == nil && AccessRequestInfo(request).name == "Kim")
    }

    @Test func requestsAndResponsesMapBothWays() async throws {
        #expect(ShareRequests.listMembers(documentID: "d", cursor: "c").cursor == "c")
        let invite = ShareRequests.invite(documentID: "d", email: "e@x.com", role: .commenter, message: "hi")
        #expect(invite.email == "e@x.com" && invite.role == .commenter && invite.message == "hi" && invite.documentID == "d")
        #expect(ShareRequests.setRole(documentID: "d", accountID: "a", role: .viewer).role == .viewer)
        #expect(ShareRequests.removeMember(documentID: "d", accountID: "a").accountID == "a")
        #expect(ShareRequests.setTeamAccess(documentID: "d", override: nil).override == .unspecified)
        #expect(ShareRequests.setTeamAccess(documentID: "d", override: .editor).override == .editor)
        let plain = ShareRequests.createLink(documentID: "d", options: ShareLinkOptions())
        #expect(plain.role == .viewer && !plain.hasExpiresAt && plain.password.isEmpty && !plain.teamMembersOnly)
        let full = ShareRequests.createLink(
            documentID: "d", options: ShareLinkOptions(role: .editor, expiresAt: Date(timeIntervalSince1970: 50), revokeOnExpiry: true, password: "pw", teamMembersOnly: true)
        )
        #expect(full.expiresAt.seconds == 50 && full.revokeOnExpiry && full.password == "pw" && full.teamMembersOnly && full.role == .editor)
        #expect(ShareRequests.listAccessRequests(documentID: "d", cursor: "c").pageSize == 50)
        #expect(ShareRequests.resolve(requestID: "r", grant: nil).grant == .unspecified)
        #expect(ShareRequests.resolve(requestID: "r", grant: .editor).grant == .editor)
        #expect(ShareRequests.transfer(documentID: "d", newOwnerID: "a").newOwnerAccountID == "a")

        let roster = try await ShareRequests.roster { cursor in
            Wiretuner_Docs_V1_ListMembersResponse.with {
                $0.members = [.with { $0.accountID = cursor.isEmpty ? "a" : "b" }]
                if cursor.isEmpty {
                    $0.nextCursor = "2"
                    $0.teamAccess = .with { $0.teamID = "t" }
                }
            }
        }
        #expect(roster.members.map(\.accountID) == ["a", "b"] && roster.teamAccess?.teamID == "t")

        #expect(Wiretuner_Docs_V1_InviteResponse.with { $0.member.accountID = "a" }.info.accountID == "a")
        #expect(Wiretuner_Docs_V1_SetRoleResponse.with { $0.member.accountID = "a" }.info.accountID == "a")
        #expect(Wiretuner_Docs_V1_RemoveMemberResponse().info == nil)
        #expect(Wiretuner_Docs_V1_RemoveMemberResponse.with { $0.member.accountID = "a" }.info?.accountID == "a")
        #expect(Wiretuner_Docs_V1_SetTeamAccessResponse.with { $0.teamAccess.teamID = "t" }.info.teamID == "t")
        #expect(Wiretuner_Docs_V1_ListLinksResponse.with { $0.links = [.with { $0.id = "l" }] }.info.map(\.id) == ["l"])
        let created = Wiretuner_Docs_V1_CreateLinkResponse.with {
            $0.link.id = "l"
            $0.token = "tok"
        }.info
        #expect(created.link.id == "l" && created.token == "tok")
        let page = Wiretuner_Docs_V1_ListAccessRequestsResponse.with {
            $0.requests = [.with { $0.id = "r" }]
            $0.nextCursor = "n"
        }.page
        #expect(page.0.map(\.id) == ["r"] && page.1 == "n")
        #expect(Wiretuner_Docs_V1_ResolveAccessRequestResponse().info == nil)
        #expect(Wiretuner_Docs_V1_ResolveAccessRequestResponse.with { $0.member.accountID = "a" }.info?.accountID == "a")
        let transfer = Wiretuner_Docs_V1_TransferOwnershipResponse.with {
            $0.owner.accountID = "new"
            $0.previousOwner.accountID = "old"
        }.info
        #expect(transfer.owner.accountID == "new" && transfer.previousOwner.accountID == "old")
    }

    @Test func theGRPCClientReachesTheConfiguredAPIAndFailsFastWithoutAServer() async {
        let client = GRPCShareClient(api: URL(string: "http://127.0.0.1:1")!, clientVersion: "v", deviceID: "d")
        let endpoint = (client.caller as? GRPCUnaryCaller)?.endpoint
        #expect(endpoint?.host == "127.0.0.1" && endpoint?.port == 1 && endpoint?.tls == false && client.clientVersion == "v")
        let t = "token"
        await #expect(throws: (any Error).self) { try await client.listMembers(documentID: "d", accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.invite(documentID: "d", email: "e@x.com", role: .viewer, message: "", accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.setRole(documentID: "d", accountID: "a", role: .viewer, accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.removeMember(documentID: "d", accountID: "a", accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.setTeamAccess(documentID: "d", override: nil, accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.listLinks(documentID: "d", accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.createLink(documentID: "d", options: ShareLinkOptions(), accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.revokeLink(linkID: "l", accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.listAccessRequests(documentID: "d", accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.resolveAccessRequest(requestID: "r", grant: nil, accessToken: t) }
        await #expect(throws: (any Error).self) { try await client.transferOwnership(documentID: "d", newOwnerID: "a", accessToken: t) }
        let tls = GRPCShareClient(api: URL(string: "https://127.0.0.1:1")!, clientVersion: "v", deviceID: "d")
        await #expect(throws: (any Error).self) { try await tls.listLinks(documentID: "d", accessToken: t) }
    }
}

@Suite @MainActor struct ShareSheetModelTests {
    static let me = FakeCollaborationServer.me
    static let owner = ShareMember(accountID: me, displayName: "Priya", email: "p@x.com", role: .owner, effectiveRole: .owner, isCreator: true)
    static let editor = ShareMember(accountID: "a-editor", displayName: "Eve", role: .editor, effectiveRole: .editor)
    static let commenter = ShareMember(accountID: "a-commenter", displayName: "Cam", role: .commenter, effectiveRole: .commenter)
    static let viewer = ShareMember(accountID: "a-viewer", displayName: "Val", role: .viewer, effectiveRole: .viewer)
    static let viaLink = ShareMember(accountID: "a-link", displayName: "Lin", role: nil, sources: [.link], effectiveRole: .viewer)
    static let viaTeam = ShareMember(accountID: "a-team", displayName: "Tam", role: nil, sources: [.teamDefault], effectiveRole: .editor)
    static let pending = ShareMember(accountID: "", displayName: "", email: "new@x.com", role: .viewer, effectiveRole: .viewer, isPending: true)
    static let document = ShareDocument(id: "d1", name: "Poster", isUploaded: true, libraryRole: .owner)

    func server(_ members: [ShareMember], team: TeamAccessInfo? = nil) -> FakeCollaborationServer {
        let server = FakeCollaborationServer()
        server.roster = ShareRoster(members: members, teamAccess: team)
        server.links = [ShareLinkInfo(id: "old", role: .viewer, uses: 1)]
        server.requests = [AccessRequestInfo(id: "r1", accountID: "a-req", displayName: "Kim", email: "kim@x.com", message: "May I?")]
        return server
    }

    func model(_ server: FakeCollaborationServer, document: ShareDocument = ShareSheetModelTests.document, me: String? = ShareSheetModelTests.me, online: Bool = true) -> ShareSheetModel {
        let model = ShareSheetModel(document: document, services: server.services(), accountID: me, isOnline: online, now: Date(timeIntervalSince1970: 0))
        model.pasteboard = NSPasteboard(name: NSPasteboard.Name("WireTunerTests-\(UUID().uuidString)"))
        return model
    }

    var everyone: [ShareMember] { [Self.owner, Self.editor, Self.commenter, Self.viewer, Self.viaLink, Self.pending] }

    @Test func theOwnerChangesAnyoneAndSeesLinksAndRequests() async {
        let server = server(everyone)
        let model = model(server)
        #expect(model.linkExpiry == Date(timeIntervalSince1970: ShareSheetModel.defaultExpiry))
        await model.load()
        #expect(model.isOwner && model.isAvailable && model.unavailableNotice == nil && model.me == Self.owner)
        #expect(model.links.map(\.id) == ["old"] && model.requests.map(\.id) == ["r1"])
        #expect(model.inviteRoles == [.editor, .commenter, .viewer] && model.mayInvite)
        #expect(!model.canChangeRole(Self.owner) && !model.canRemove(Self.owner), "the owner's row is a transfer, not a popup")
        #expect(model.canChangeRole(Self.editor) && model.canChangeRole(Self.viewer) && model.canRemove(Self.editor))
        #expect(!model.canChangeRole(Self.viaLink) && !model.canRemove(Self.viaLink), "no named role to change")
        #expect(!model.canChangeRole(Self.pending) && !model.canRemove(Self.pending))
        #expect(model.roleOptions(for: Self.viewer) == [.editor, .commenter, .viewer])
        #expect(model.roleOptions(for: Self.viaLink) == [.editor, .commenter, .viewer])
        #expect(model.canCreateLink && model.canResolveRequests && !model.canManageTeamAccess || !model.isTeamDocument)
        #expect(model.transferCandidates.map(\.accountID) == ["a-editor", "a-commenter", "a-viewer"])
        #expect(model.people.count == 6 && !model.isRestricted && model.restrictionNotice == nil)
        Render.view(ShareSheetView(model: model))
    }

    @Test func invitesRolesAndRemovals() async {
        let server = server(everyone)
        server.removalLeavesAccess = true
        let model = model(server)
        await model.load()
        #expect(!model.canInvite)
        model.inviteEmail = " kim@x.com "
        model.inviteRole = .commenter
        model.inviteMessage = "Have a look"
        #expect(model.canInvite)
        await model.perform(.invite)
        #expect(server.calls.contains("invite:kim@x.com:commenter:Have a look"))
        #expect(model.inviteEmail.isEmpty && model.inviteMessage.isEmpty && model.notice == "Invited kim@x.com.")
        #expect(model.people.contains { $0.email == "kim@x.com" && $0.isPending })

        await model.perform(.setRole(Self.viewer, .viewer))
        #expect(!server.calls.contains { $0.hasPrefix("setRole") })
        model.roleBinding(for: Self.viewer).wrappedValue = .editor
        await model.lastTask?.value
        #expect(model.roster.members.first { $0.accountID == "a-viewer" }?.role == .editor)
        #expect(model.roleBinding(for: Self.viaLink).wrappedValue == .viewer)

        model.handler(.confirm(.remove(Self.commenter)))()
        await model.lastTask?.value
        #expect(model.confirming == .remove(Self.commenter))
        Render.view(ShareSheetView(model: model))
        await model.perform(.cancelConfirmation)
        #expect(model.confirming == nil)
        await model.perform(.remove(Self.commenter))
        let remaining = model.roster.members.first { $0.accountID == "a-commenter" }
        #expect(remaining?.role == nil && remaining?.sources == [.link] && model.notice == "Cam was removed.")
        server.removalLeavesAccess = false
        await model.perform(.remove(Self.editor))
        #expect(!model.roster.members.contains { $0.accountID == "a-editor" })

        server.failNext(with: RPCError(code: .failedPrecondition, message: "this workspace restricts sharing to team members"))
        model.inviteEmail = "out@y.com"
        await model.perform(.invite)
        #expect(model.errorMessage == "this workspace restricts sharing to team members" && model.inviteEmail == "out@y.com")
    }

    @Test func linksAreMadeCopiedAndRevoked() async throws {
        let tokens = ShareLinkTokens()
        let server = server(everyone)
        let model = ShareSheetModel(document: Self.document, services: server.services(tokens: tokens), accountID: Self.me)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("WireTunerTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        model.pasteboard = pasteboard
        await model.load()
        let old = model.links[0]
        #expect(model.linkURL(old) == nil)
        await model.perform(.copyLink(old))
        #expect(model.notice == ShareSheetModel.noTokenHelp)

        model.linkRole = .commenter
        model.linkExpires = true
        model.linkRevokeOnExpiry = true
        model.linkPassword = "secret"
        await model.perform(.createLink)
        #expect(server.calls.contains("createLink:commenter:expires=true:revoke=true:password=true:team=false"))
        let made = try #require(model.links.first)
        #expect(model.linkPassword.isEmpty && model.notice == ShareSheetModel.linkCopied)
        #expect(pasteboard.string(forType: .string) == "https://links.example/l/tok\(made.id)")
        #expect(tokens[made.id] == "tok\(made.id)", "another sheet can copy it again")
        pasteboard.clearContents()
        await model.perform(.copyLink(made))
        #expect(pasteboard.string(forType: .string) == "https://links.example/l/tok\(made.id)")

        model.linkExpires = false
        await model.perform(.createLink)
        #expect(server.calls.contains("createLink:commenter:expires=false:revoke=false:password=false:team=false"))
        Render.view(ShareSheetView(model: model))

        await model.perform(.confirm(.revokeLink(made)))
        await model.perform(.revokeLink(made))
        #expect(!model.links.contains(made) && tokens[made.id] == nil && model.notice == "Link revoked." && model.confirming == nil)
        server.failNext(with: RPCError(code: .permissionDenied, message: "ROLE_INSUFFICIENT"))
        await model.perform(.revokeLink(old))
        #expect(model.links.contains(old))

        #expect(ShareSheetModel.summary(ShareLinkInfo(id: "x", role: .viewer, uses: 1)) == "Viewer · never expires · 1 use")
        let summary = ShareSheetModel.summary(ShareLinkInfo(id: "x", role: .editor, expiresAt: Date(timeIntervalSince1970: 0), hasPassword: true, teamMembersOnly: true, uses: 3))
        #expect(summary.hasPrefix("Editor · expires ") && summary.hasSuffix(" · password · team only · 3 uses"))
    }

    @Test func requestsAreApprovedOrDenied() async {
        let server = server(everyone)
        server.requests = [
            AccessRequestInfo(id: "r1", accountID: "a-req", displayName: "Kim", email: "kim@x.com", message: "May I?"),
            AccessRequestInfo(id: "r2", accountID: "a-req2", displayName: "", email: "lee@x.com"),
        ]
        let model = model(server)
        await model.load()
        model.requestRole = .commenter
        Render.view(ShareSheetView(model: model))
        await model.perform(.resolve(model.requests[0], model.requestRole))
        #expect(model.notice == "Kim can now open this document as commenter." && model.roster.members.contains { $0.accountID == "a-req" })
        await model.perform(.resolve(model.requests[0], nil))
        #expect(model.requests.isEmpty && model.notice == "lee@x.com’s request was declined.")
    }

    @Test func ownershipIsTransferredAfterConfirming() async {
        let server = server(everyone)
        let model = model(server)
        await model.load()
        #expect(!model.canTransfer)
        await model.perform(.confirmTransfer)
        #expect(model.confirming == nil)
        model.transferTargetID = "a-editor"
        #expect(model.canTransfer)
        await model.perform(.confirmTransfer)
        #expect(model.confirming == .transfer(Self.editor))
        Render.view(ShareSheetView(model: model))
        await model.perform(.transfer(Self.editor))
        #expect(model.notice == "Eve is now the owner. You are an editor." && model.confirming == nil)
        #expect(!model.isOwner && model.callerRole == .editor && model.links.isEmpty && model.transferCandidates.isEmpty)
        #expect(model.canRemove(model.me!), "a former owner may leave")
    }

    @Test func confirmationsSayWhatTheyDo() {
        #expect(ShareSheetModel.prompt(.remove(Self.viewer)).action == .remove(Self.viewer))
        #expect(ShareSheetModel.prompt(.remove(Self.viewer)).message == "Remove Val’s access to this document?")
        let link = ShareLinkInfo(id: "l", role: .editor)
        #expect(ShareSheetModel.prompt(.revokeLink(link)).button == "Revoke" && ShareSheetModel.prompt(.revokeLink(link)).action == .revokeLink(link))
        #expect(ShareSheetModel.prompt(.transfer(Self.editor)).button == "Transfer")
        #expect(SharePeopleSection.title(Self.owner, isMe: true) == "Priya (you) · creator")
        #expect(SharePeopleSection.title(Self.pending, isMe: false) == "new@x.com · invited")
        #expect(SharePeopleSection.roleText(Self.editor) == "Editor")
        #expect(SharePeopleSection.roleText(Self.viaLink) == "Viewer via link")
        #expect(SharePeopleSection.roleText(Self.viaTeam) == "Editor")
        #expect(SharePeopleSection.roleText(ShareMember(accountID: "n", displayName: "N", role: nil, sources: [])) == "No access")
    }

    @Test func anEditorInvitesAtEditorAndManagesOnlyViewersAndCommenters() async {
        let me = ShareMember(accountID: Self.me, displayName: "Priya", role: .editor, effectiveRole: .editor)
        let others = [ShareMember(accountID: "a-owner", displayName: "Olga", role: .owner, effectiveRole: .owner), Self.editor, Self.commenter, Self.viewer]
        let server = server([me] + others)
        let model = model(server, document: ShareDocument(id: "d1", name: "Poster", isUploaded: true, libraryRole: .editor))
        await model.load()
        #expect(!model.isOwner && model.callerRole == .editor)
        #expect(!server.calls.contains("listLinks") && !server.calls.contains("listAccessRequests"), "owners-only lists are not even asked for")
        #expect(model.inviteRoles == [.editor, .commenter, .viewer])
        #expect(!model.canChangeRole(Self.editor) && !model.canRemove(Self.editor), "only the owner may lower another editor")
        #expect(model.canChangeRole(Self.commenter) && model.canRemove(Self.viewer))
        #expect(model.canRemove(me) && !model.canChangeRole(me))
        #expect(!model.canCreateLink && !model.canResolveRequests && model.transferCandidates.isEmpty)
        Render.view(ShareSheetView(model: model))
        await model.perform(.remove(me))
        #expect(model.notice == "You removed your access to this document.")
    }

    @Test func aViewerOnlyLooksAndMayLeave() async {
        let me = ShareMember(accountID: Self.me, displayName: "Priya", role: .viewer, effectiveRole: .viewer)
        let server = server([Self.owner.with(accountID: "a-owner"), me])
        let model = model(server, document: ShareDocument(id: "d1", name: "Poster", isUploaded: true, libraryRole: .viewer))
        model.inviteRole = .editor
        await model.load()
        #expect(model.inviteRoles.isEmpty && !model.mayInvite && !model.canInvite && model.inviteRole == .editor)
        #expect(model.canRemove(me))
        Render.view(ShareSheetView(model: model))
        let commenter = self.model(server, document: ShareDocument(id: "d1", name: "Poster", isUploaded: true, libraryRole: .commenter), me: nil)
        #expect(commenter.callerRole == .commenter && commenter.inviteRoles.isEmpty && commenter.me == nil && !commenter.isMe(me))
    }

    @Test func aTeamDocumentHasTheTeamRowAndItsAdminsActAsOwner() async {
        let access = TeamAccessInfo(teamID: FakeCollaborationServer.teamID, teamName: "Marketing", teamDefault: .editor, override: nil)
        let me = ShareMember(accountID: Self.me, displayName: "Priya", role: nil, sources: [.teamDefault], effectiveRole: .editor)
        let server = server([Self.owner.with(accountID: "a-creator"), me, Self.viaTeam, Self.viewer], team: access)
        server.team = TeamDetail(id: FakeCollaborationServer.teamID, name: "Marketing", callerRole: .admin)
        let model = model(server, document: ShareDocument(id: "d1", name: "Poster", isUploaded: true, libraryRole: .editor))
        await model.load()
        #expect(model.isTeamDocument && model.isTeamAdmin && model.isOwner && model.canManageTeamAccess)
        #expect(!model.people.contains(Self.viaTeam) && model.people.contains(me) == false, "team-only access is the one team row")
        #expect(model.transferCandidates.isEmpty, "a team owns its documents: nothing to transfer")
        #expect(model.teamAccessBinding.wrappedValue == nil)
        model.teamAccessBinding.wrappedValue = .viewer
        await model.lastTask?.value
        #expect(model.roster.teamAccess?.override == .viewer && model.roster.teamAccess?.effective == .viewer)
        await model.perform(.setTeamAccess(.viewer))
        #expect(server.calls.filter { $0.hasPrefix("setTeamAccess") }.count == 1)
        await model.perform(.setTeamAccess(nil))
        #expect(server.calls.contains("setTeamAccess:clear") && model.roster.teamAccess?.override == nil)
        Render.view(ShareSheetView(model: model))

        server.team = TeamDetail(id: FakeCollaborationServer.teamID, name: "Marketing", callerRole: .member)
        let member = self.model(server, document: ShareDocument(id: "d1", name: "Poster", isUploaded: true, libraryRole: .editor))
        await member.load()
        #expect(!member.isOwner && !member.canManageTeamAccess && member.callerRole == .editor)
        Render.view(ShareSheetView(model: member))
    }

    @Test func aRestrictedWorkspaceKeepsLinksInsideTheTeam() async {
        let access = TeamAccessInfo(teamID: FakeCollaborationServer.teamID, teamName: "Marketing", teamDefault: nil, override: nil)
        let server = server([Self.owner], team: access)
        server.team = TeamDetail(
            id: FakeCollaborationServer.teamID, name: "Marketing", callerRole: .owner,
            workspace: WorkspaceInfo(settings: WorkspaceSettingsValue(restrictSharing: true))
        )
        let model = model(server)
        await model.load()
        #expect(model.isRestricted && model.linkTeamMembersOnly)
        #expect(model.restrictionNotice == "Marketing’s workspace restricts sharing to team members: only members can be invited, and links open only for them.")
        model.linkTeamMembersOnly = false
        await model.perform(.createLink)
        #expect(server.calls.contains("createLink:viewer:expires=false:revoke=false:password=false:team=true"))
        Render.view(ShareSheetView(model: model))

        #expect(ShareSheetModel(document: Self.document, services: server.services(), accountID: Self.me).restrictionNotice == nil)
    }

    @Test func offlineOrNotUploadedEverythingIsDisabledWithANotice() async {
        let server = server(everyone)
        let offline = model(server, online: false)
        #expect(offline.unavailableNotice == ShareSheetModel.offlineNotice && !offline.isAvailable)
        #expect(!offline.canChangeRole(Self.viewer) && !offline.canRemove(Self.viewer) && !offline.canCreateLink && !offline.canTransfer)
        Render.view(ShareSheetView(model: offline))
        server.offline = true
        await offline.perform(.reload)
        #expect(!offline.isOnline && offline.errorMessage == nil)
        server.offline = false
        await offline.perform(.reload)
        #expect(offline.isOnline && offline.isAvailable)

        let local = model(server, document: ShareDocument(id: "local", name: "Untitled", isUploaded: false, libraryRole: nil))
        let calls = server.calls.count
        await local.load()
        #expect(server.calls.count == calls && local.unavailableNotice == ShareSheetModel.notUploadedNotice && !local.isAvailable)
        Render.view(ShareSheetView(model: local))

        server.failNext(with: RPCError(code: .notFound, message: "DOCUMENT_NOT_FOUND"))
        let missing = model(server)
        await missing.load()
        #expect(missing.errorMessage == "DOCUMENT_NOT_FOUND")
        Render.view(ShareSheetView(model: missing))
        var closed = 0
        missing.onDone = { closed += 1 }
        await missing.send(.done).value
        #expect(closed == 1)
    }
}

extension ShareMember {
    func with(accountID: String) -> ShareMember {
        var copy = self
        copy.accountID = accountID
        return copy
    }
}

@Suite(.serialized) @MainActor struct ShareCommandTests {
    @Test func theCommandReplacesThePlaceholderInPlace() {
        let registry = CommandRegistry()
        ContextMenuCatalog.register(into: registry)
        let placeholder = registry.command(ShareCommands.id)
        let hasDocument = Box(false)
        let shared = Box(0)
        ShareCommands.install(into: registry, canShare: { hasDocument.value }) { shared.value += 1 }
        let command = registry.command(ShareCommands.id)
        #expect(command?.menuPath == placeholder?.menuPath && command?.title == "Share…")
        #expect(registry.validate(ShareCommands.id) == .disabled(ShareCommands.noDocument))
        hasDocument.value = true
        #expect(registry.validate(ShareCommands.id) == .enabled)
        #expect(registry.perform(ShareCommands.id) && shared.value == 1)
        let bare = ShareCommands.command(existing: nil, canShare: { true }) {}
        #expect(bare.menuPath == MenuPath(StandardCommands.Menu.file, section: 1) && bare.contexts.isEmpty)
    }

    @Test func thePresenterShowsOneSheetAndLoadsItWhenOnline() async {
        let server = FakeCollaborationServer()
        server.roster = ShareRoster(members: [ShareSheetModelTests.owner], teamAccess: nil)
        let online = Box(true)
        let presenter = SharePresenter(services: server.services(), accountID: { FakeCollaborationServer.me }, isOnline: { online.value })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.close() }
        let model = presenter.present(ShareSheetModelTests.document, on: window)
        #expect(model != nil && presenter.sheet?.identifier == SharePresenter.identifier)
        #expect(presenter.present(ShareSheetModelTests.document, on: window) == nil, "one sheet at a time")
        await model?.lastTask?.value
        #expect(model?.isOwner == true)
        model?.onDone()
        #expect(presenter.sheet == nil && presenter.model == nil)
        presenter.dismiss()

        online.value = false
        let offline = presenter.present(ShareSheetModelTests.document, on: window)
        #expect(offline?.lastTask == nil && offline?.isOnline == false)
        presenter.dismiss()
    }

    @Test func fileShareOpensTheSheetForTheFrontDocument() async {
        let suite = TestDefaults()
        let libraryServer = FakeLibraryServer()
        let library = LibraryModel(services: libraryServer.services(), store: nil, thumbnails: ThumbnailCache(directory: nil))
        let server = FakeCollaborationServer()
        server.roster = ShareRoster(members: [ShareSheetModelTests.owner], teamAccess: nil)
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults, library: library, collaboration: server.services())
        #expect(delegate.showShare() == nil, "no window yet")
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(delegate.commands.validate(ShareCommands.id) == .enabled)
        #expect(delegate.menuTarget?.perform(ShareCommands.id) == true)
        let untitled = delegate.sharePresenter.model
        #expect(untitled?.document.isUploaded == false && untitled?.unavailableNotice == ShareSheetModel.notUploadedNotice)
        #expect(delegate.activeDocumentWindow?.window?.attachedSheet?.identifier == SharePresenter.identifier)
        delegate.sharePresenter.dismiss()

        library.open([LibraryDocument(id: "lib-1", spaceID: "s", name: "From library", role: .owner)])
        let shared = delegate.showShare()
        #expect(shared?.document == ShareDocument(id: "lib-1", name: "From library", isUploaded: true, libraryRole: .owner))
        delegate.sharePresenter.dismiss()
        for id in delegate.documents.documents.map(\.id) { delegate.documents.close(id) }
        suite.remove()
    }
}

/// A mutable value the command closures can capture.
final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@Suite @MainActor struct ShareSheetEdgeTests {
    @Test func aTeamYouCannotReadGrantsNoAdminPowersAndNoRestriction() async {
        let access = TeamAccessInfo(teamID: FakeCollaborationServer.teamID, teamName: "Marketing", teamDefault: nil, override: nil)
        let me = ShareMember(accountID: FakeCollaborationServer.me, displayName: "Priya", role: .editor, effectiveRole: .editor)
        let server = FakeCollaborationServer()
        server.roster = ShareRoster(members: [me, ShareSheetModelTests.owner.with(accountID: "a-owner")], teamAccess: access)
        server.teamUnavailable = true
        let model = ShareSheetModel(document: ShareSheetModelTests.document, services: server.services(), accountID: FakeCollaborationServer.me)
        await model.load()
        #expect(model.isTeamDocument && model.team == nil && !model.isTeamAdmin && !model.isRestricted && model.restrictionNotice == nil)
        #expect(model.roleOptions(for: ShareSheetModelTests.owner) == [.owner, .editor, .commenter, .viewer])
        Render.view(ShareSheetView(model: model))
        ShareSheetModel(document: ShareSheetModelTests.document, services: server.services(), accountID: nil).onDone()
    }

    @Test func theSheetShowsItIsLoading() async throws {
        let server = FakeCollaborationServer()
        server.tokenDelay = .milliseconds(300)
        let model = ShareSheetModel(document: ShareSheetModelTests.document, services: server.services(), accountID: FakeCollaborationServer.me)
        let task = model.send(.reload)
        for _ in 0..<50 where !model.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.isLoading)
        Render.view(ShareSheetView(model: model))
        await task.value
        #expect(!model.isLoading)
    }
}
