import AppKit
import Foundation
import GRPCCore
import GRPCProtobuf
import SwiftProtobuf
import Testing
import WTProto
@testable import WireTuner

/// COLLAB-013's rest: opening share links (the password page, the request page after a failed
/// open), invitations by name with team-member suggestions, editing a link, the Actions menu
/// (*Transfer Ownership*, *Move to*), btn:[Share]'s request badge and the offline popover.
@Suite @MainActor struct ShareLinkTypeTests {
    @Test func failuresReadTheirReasonAndDocument() {
        let named = ["document_id": "d1", "document_name": "Poster", "can_request_access": "true"]
        #expect(ShareLinkFailure(reason: "LINK_PASSWORD_REQUIRED", metadata: [:]) == .passwordRequired)
        #expect(ShareLinkFailure(reason: "LINK_INVALID", metadata: named) == .invalid(ShareLinkDocument(id: "d1", name: "Poster")))
        #expect(ShareLinkFailure(reason: "LINK_INVALID", metadata: [:]) == .invalid(nil))
        #expect(ShareLinkFailure(reason: "ROLE_INSUFFICIENT", metadata: named)?.requestable?.id == "d1")
        #expect(ShareLinkFailure(reason: "LINK_INVALID", metadata: ["document_id": "d1", "can_request_access": "false"])?.requestable == nil)
        #expect(ShareLinkFailure(reason: "LINK_INVALID", metadata: ["document_id": "", "can_request_access": "true"])?.requestable == nil)
        #expect(ShareLinkFailure(reason: "LINK_INVALID", metadata: ["document_id": "d1", "can_request_access": "true"])?.requestable?.name == "")
        #expect(ShareLinkFailure(reason: "DOCUMENT_NOT_FOUND", metadata: [:]) == nil)
        #expect(ShareLinkFailure.passwordRequired.requestable == nil)

        let status = GoogleRPCStatus(code: .notFound, message: "dead", details: [.errorInfo(reason: "LINK_INVALID", domain: "wiretuner.app", metadata: named)])
        #expect(ShareRequests.linkFailure(RPCError(status)) as? ShareLinkFailure == .invalid(ShareLinkDocument(id: "d1", name: "Poster")))
        #expect(ShareRequests.linkFailure(RPCError(code: .internalError, message: "boom")) is RPCError)
        #expect(ShareRequests.linkFailure(CocoaError(.fileNoSuchFile)) is CocoaError)
    }

    @Test func requestsForAccountsLinkChangesAndOpening() {
        let invite = ShareRequests.invite(documentID: "d", accountID: "a9", role: .viewer, message: "hi")
        #expect(invite.accountID == "a9" && invite.email.isEmpty && invite.role == .viewer && invite.message == "hi")
        let none = ShareRequests.updateLink(linkID: "l", changes: ShareLinkChanges())
        #expect(none.linkID == "l" && !none.hasRole && !none.hasExpiresAt && !none.hasRevokeOnExpiry && !none.hasPassword && !none.hasTeamMembersOnly)
        let never = ShareRequests.updateLink(linkID: "l", changes: ShareLinkChanges(expiresAt: .some(nil), password: ""))
        #expect(never.hasExpiresAt && never.expiresAt.seconds == 0 && never.hasPassword && never.password.isEmpty)
        let all = ShareRequests.updateLink(
            linkID: "l", changes: ShareLinkChanges(role: .editor, expiresAt: Date(timeIntervalSince1970: 90), revokeOnExpiry: true, password: "pw", teamMembersOnly: true)
        )
        #expect(all.role == .editor && all.expiresAt.seconds == 90 && all.revokeOnExpiry && all.password == "pw" && all.teamMembersOnly)
        #expect(ShareLinkChanges().isEmpty && !ShareLinkChanges(role: .viewer).isEmpty)
        let open = ShareRequests.openLink(token: "t", password: "p")
        #expect(open.token == "t" && open.password == "p")
        let opened = Wiretuner_Docs_V1_OpenLinkResponse.with {
            $0.documentID = "d"
            $0.documentName = "Poster"
            $0.effectiveRole = .commenter
        }.info
        #expect(opened == OpenedShareLink(documentID: "d", documentName: "Poster", role: .commenter))
        #expect(Wiretuner_Docs_V1_UpdateLinkResponse.with { $0.link.id = "l" }.info.id == "l")
        #expect(ShareInvitee.email("a@x.com").title == "a@x.com" && ShareInvitee.account(id: "a", name: "Kim").title == "Kim")
    }

    @Test func suggestionsMatchNamesWordsAndAddresses() {
        let kim = InviteSuggestion(accountID: "a", displayName: "Kim Nováková", email: "kim@x.com", teamName: "Marketing")
        #expect(kim.matches("kim") && kim.matches("NOVA") && kim.matches("kim@") && kim.matches(" Kim "))
        #expect(!kim.matches("") && !kim.matches("ova") && !kim.matches("x.com"))
        #expect(kim.name == "Kim Nováková" && kim.id == "a")
        #expect(InviteSuggestion(accountID: "b", displayName: "", email: "lee@x.com", teamName: "M").name == "lee@x.com")
    }

    @Test func linkTokensComeFromWebAndAppLinks() {
        let token = "AbCdEf0123456789-_xyz"
        #expect(ShareLinkOpener.token(in: URL(string: "https://wiretuner.app/l/\(token)")!) == token)
        #expect(ShareLinkOpener.token(in: URL(string: "http://localhost:8080/l/\(token)")!) == token)
        #expect(ShareLinkOpener.token(in: URL(string: "wiretuner://link/\(token)")!) == token)
        #expect(ShareLinkOpener.token(in: URL(string: "https://wiretuner.app/d/\(token)")!) == nil)
        #expect(ShareLinkOpener.token(in: URL(string: "https://wiretuner.app/l/short")!) == nil)
        #expect(ShareLinkOpener.token(in: URL(string: "https://wiretuner.app/l/\(token)/more")!) == nil)
        #expect(ShareLinkOpener.token(in: URL(string: "https://wiretuner.app/l/bad%20token%20here%20!!")!) == nil)
        #expect(ShareLinkOpener.token(in: URL(string: "wiretuner://doc/\(token)")!) == nil)
        #expect(ShareLinkOpener.token(in: URL(string: "mailto:\(token)")!) == nil)
        #expect(ShareLinkOpener.token(in: URL(string: "l/\(token)")!) == nil)
    }

    @Test func theGRPCClientInvitesByAccountUpdatesAndOpensLinks() async throws {
        typealias Share = Wiretuner_Docs_V1_ShareService.Method
        let caller = FakeUnaryCaller([
            route(Share.Invite.descriptor) { (request: Wiretuner_Docs_V1_InviteRequest) -> Wiretuner_Docs_V1_InviteResponse in
                .with { $0.member = .with { $0.accountID = request.accountID; $0.role = request.role } }
            },
            route(Share.UpdateLink.descriptor) { (request: Wiretuner_Docs_V1_UpdateLinkRequest) -> Wiretuner_Docs_V1_UpdateLinkResponse in
                .with { $0.link = .with { $0.id = request.linkID; $0.role = request.role } }
            },
            route(Share.OpenLink.descriptor) { (request: Wiretuner_Docs_V1_OpenLinkRequest) -> Wiretuner_Docs_V1_OpenLinkResponse in
                switch request.token {
                case "open-token-0000001":
                    return .with { $0.documentID = "d"; $0.documentName = "Poster"; $0.effectiveRole = .viewer }
                case "pass-token-0000001":
                    throw RPCError(GoogleRPCStatus(code: .permissionDenied, message: "pw", details: [.errorInfo(reason: "LINK_PASSWORD_REQUIRED", domain: "wiretuner.app")]))
                default:
                    throw RPCError(code: .internalError, message: "boom")
                }
            },
        ])
        let client = GRPCShareClient(caller: caller)
        #expect(try await client.invite(documentID: "d", accountID: "a9", role: .editor, message: "", accessToken: "t").accountID == "a9")
        #expect(try await client.updateLink(linkID: "l", changes: ShareLinkChanges(role: .editor), accessToken: "t").role == .editor)
        #expect(try await client.openLink(token: "open-token-0000001", password: "", accessToken: "t").documentName == "Poster")
        await #expect(throws: ShareLinkFailure.passwordRequired) { _ = try await client.openLink(token: "pass-token-0000001", password: "", accessToken: "t") }
        await #expect(throws: RPCError.self) { _ = try await client.openLink(token: "else-token-0000001", password: "", accessToken: "t") }
    }
}

/// What the opener did, for the assertions.
@MainActor
final class ShareLinkWorld {
    let server = FakeCollaborationServer()
    let opener: ShareLinkOpener
    var opened: [String] = []
    var library: [String] = []
    var refreshed = 0
    var requested: [(String, String)] = []
    var pages: [ShareLinkPasswordModel] = []
    var requests: [RequestAccessModel] = []
    var online = true

    init(signedIn: Bool = true) {
        opener = ShareLinkOpener(services: server.services(signedIn: signedIn))
        opener.isOnline = { [unowned self] in online }
        opener.refreshLibrary = { [unowned self] in refreshed += 1 }
        opener.open = { [unowned self] id, name in opened.append("\(id):\(name)") }
        opener.showLibrary = { [unowned self] in library.append($0) }
        opener.requestAccess = { [unowned self] id, message in requested.append((id, message)) }
        opener.presentPassword = { [unowned self] in pages.append($0) }
        opener.presentRequest = { [unowned self] in requests.append($0) }
    }
}

@Suite @MainActor struct ShareLinkOpenerTests {
    static let token = "tok-0123456789abcdef"
    static let poster = OpenedShareLink(documentID: "d1", documentName: "Poster", role: .editor)

    @Test func aLinkOpensItsDocumentThroughTheLibrary() async throws {
        let world = ShareLinkWorld()
        world.server.addLink(token: Self.token, opens: Self.poster)
        #expect(world.opener.opens(URL(string: "https://example.com/d/doc")!) == nil)
        let outcome = try #require(world.opener.opens(URL(string: "https://wiretuner.app/l/\(Self.token)")!))
        #expect(await outcome.value == .opened(Self.poster))
        #expect(world.opened == ["d1:Poster"] && world.refreshed == 1 && world.server.calls.contains("openLink:\(Self.token):"))
    }

    @Test func aPasswordIsAskedForUntilItIsRight() async throws {
        let world = ShareLinkWorld()
        world.server.addLink(token: Self.token, opens: Self.poster, password: "sesame")
        #expect(await world.opener.open(token: Self.token) == .password(wrong: false))
        let page = try #require(world.pages.first)
        #expect(world.opener.passwordPage === page && !page.isWrong && !page.canSubmit)
        Render.view(ShareLinkPasswordView(model: page))
        await page.submit()
        #expect(world.server.calls.filter { $0.hasPrefix("openLink") }.count == 1, "nothing to send without a password")
        page.password = "guess"
        await page.submit()
        #expect(page.isWrong && page.password.isEmpty && world.pages.count == 1, "the same page, told it was wrong")
        Render.view(ShareLinkPasswordView(model: page))
        var closed = 0
        page.close = { closed += 1 }
        page.password = "sesame"
        #expect(page.canSubmit)
        await page.submit()
        #expect(world.opened == ["d1:Poster"] && closed == 1 && world.opener.passwordPage == nil && !page.isSending)
    }

    @Test func aDeadLinkOffersTheRequestPageWhenItNamesTheDocument() async throws {
        let world = ShareLinkWorld()
        world.server.refuseLink(token: Self.token, .invalid(ShareLinkDocument(id: "d1", name: "Poster")))
        #expect(await world.opener.open(token: Self.token) == .requestAccess(ShareLinkDocument(id: "d1", name: "Poster")))
        let request = try #require(world.requests.first)
        #expect(request.documentID == "d1" && request.documentName == "Poster" && world.opener.request === request)
        Render.view(RequestAccessView(model: request))
        request.message = "May I?"
        await request.submit()
        #expect(request.phase == .sent && world.requested.first?.0 == "d1" && world.requested.first?.1 == "May I?")

        world.server.refuseLink(token: Self.token, .teamOnly(ShareLinkDocument(id: "d2", name: "Deck")))
        #expect(await world.opener.open(token: Self.token) == .requestAccess(ShareLinkDocument(id: "d2", name: "Deck")))
        world.server.refuseLink(token: Self.token, .invalid(nil))
        #expect(await world.opener.open(token: Self.token) == .library(ShareLinkOpener.deadMessage))
        #expect(await world.opener.open(token: "unknown-token-00001") == .library(ShareLinkOpener.deadMessage))
        #expect(world.library == [ShareLinkOpener.deadMessage, ShareLinkOpener.deadMessage] && world.opened.isEmpty)
    }

    @Test func aPasswordPageClosesWhenTheLinkTurnsOutDead() async throws {
        let world = ShareLinkWorld()
        world.server.addLink(token: Self.token, opens: Self.poster, password: "pw")
        _ = await world.opener.open(token: Self.token)
        var closed = 0
        world.pages.first?.close = { closed += 1 }
        world.server.refuseLink(token: Self.token, .invalid(nil))
        #expect(await world.opener.open(token: Self.token, password: "pw") == .library(ShareLinkOpener.deadMessage))
        #expect(closed == 1 && world.opener.passwordPage == nil)
    }

    @Test func thePasswordPageIsAWindowItsModelCloses() throws {
        let model = ShareLinkPasswordModel(token: Self.token) { _, _ in }
        ShareLinkOpener.presentWindow(model)
        let window = try #require(NSApp.windows.first { $0.identifier?.rawValue == ShareLinkOpener.windowIdentifier && $0.isVisible })
        #expect(window.title == "Open Share Link")
        model.close()
        #expect(!window.isVisible)
    }

    @Test func offlineSignedOutAndOtherErrorsSayWhy() async {
        let world = ShareLinkWorld()
        world.online = false
        #expect(await world.opener.open(token: Self.token) == .library(ShareLinkOpener.offlineMessage))
        world.online = true
        world.server.offline = true
        #expect(await world.opener.open(token: Self.token) == .library(ShareLinkOpener.offlineMessage))
        world.server.offline = false
        world.server.failNext(with: RPCError(code: .internalError, message: "boom"))
        #expect(await world.opener.open(token: Self.token) == .library("boom"))
        let signedOut = ShareLinkWorld(signedIn: false)
        #expect(await signedOut.opener.open(token: Self.token) == .library(ShareLinkOpener.signedOutMessage))
    }

    @Test func theAppHandsShareLinksToTheOpener() async {
        let suite = TestDefaults()
        let library = LibraryModel(services: FakeLibraryServer().services(), store: nil, thumbnails: ThumbnailCache(directory: nil))
        let server = FakeCollaborationServer()
        server.addLink(token: Self.token, opens: Self.poster)
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults, library: library, collaboration: server.services())
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        // The library window comes forward with the message.
        delegate.shareLinks.showLibrary("A message")
        #expect(library.errorMessage == "A message")
        var shown: [String] = []
        delegate.shareLinks.showLibrary = { shown.append($0) }
        delegate.shareLinks.presentPassword = { _ in }
        #expect(delegate.open(URL(string: "wiretuner://link/\(Self.token)")!))
        #expect(await eventually { delegate.documents.documents.contains { $0.id == "d1" } })
        #expect(delegate.shareLinks.requestAccess != nil)
        for id in delegate.documents.documents.map(\.id) { delegate.documents.close(id) }
        suite.remove()
    }
}

@Suite @MainActor struct ShareSheetRestTests {
    static let me = FakeCollaborationServer.me
    static let owner = ShareSheetModelTests.owner
    static let editor = ShareSheetModelTests.editor
    static let personal = LibrarySpace.personal(id: FakeCollaborationServer.me)
    static let marketing = LibrarySpace(id: FakeCollaborationServer.teamID, name: "Marketing", kind: .team)
    static let design = LibrarySpace(id: "t-design", name: "Design", kind: .team)

    func server() -> FakeCollaborationServer {
        let server = FakeCollaborationServer()
        server.roster = ShareRoster(members: [Self.owner, Self.editor], teamAccess: nil)
        server.members = [
            TeamMemberInfo(accountID: "a-kim", displayName: "Kim Lee", email: "kim@x.com", role: .member),
            TeamMemberInfo(accountID: "a-editor", displayName: "Eve", email: "eve@x.com", role: .member),
            TeamMemberInfo(accountID: Self.me, displayName: "Priya", email: "p@x.com", role: .owner),
            TeamMemberInfo(accountID: "a-kip", displayName: "Kip", email: "kip@x.com", role: .guest),
        ]
        server.links = [ShareLinkInfo(id: "l1", role: .viewer, hasPassword: true, uses: 2)]
        return server
    }

    func model(_ server: FakeCollaborationServer, role: DocumentRole = .owner) -> ShareSheetModel {
        let document = ShareDocument(id: "d1", name: "Poster", isUploaded: true, libraryRole: role, spaceID: Self.personal.id)
        let model = ShareSheetModel(document: document, services: server.services(), accountID: Self.me, now: Date(timeIntervalSince1970: 0))
        model.teams = [Self.personal, Self.marketing, Self.design]
        model.spaces = [Self.personal, Self.marketing, Self.design]
        return model
    }

    @Test func inviteSuggestsTeamPeopleAndInvitesThemByAccount() async throws {
        let server = server()
        let model = model(server)
        await model.load()
        #expect(server.calls.filter { $0 == "listTeamMembers" }.count == 2, "both teams, once each")
        #expect(model.suggestionPool.map(\.accountID) == ["a-kim", "a-editor", Self.me, "a-kip"], "the second team's copies are left out")
        #expect(model.suggestions.isEmpty && model.invitee == nil && !model.canInvite)
        model.inviteEmail = "k"
        #expect(model.suggestions.map(\.accountID) == ["a-kim", "a-kip"])
        model.inviteEmail = "e"
        #expect(model.suggestions.isEmpty, "Eve already has a role")
        model.inviteEmail = "pri"
        #expect(model.suggestions.isEmpty, "not yourself")
        model.inviteEmail = "kip"
        #expect(model.invitee == .account(id: "a-kip", name: "Kip") && model.canInvite, "an exact name")
        model.inviteEmail = "lee"
        let kim = try #require(model.suggestions.first)
        Render.view(ShareSheetView(model: model))
        await model.perform(.pick(kim))
        #expect(model.inviteEmail == "Kim Lee" && model.suggestions.isEmpty && model.invitee == .account(id: "a-kim", name: "Kim Lee"))
        model.inviteRole = .commenter
        await model.perform(.invite)
        #expect(server.calls.contains("inviteAccount:a-kim:commenter:") && model.notice == "Invited Kim Lee.")
        #expect(model.inviteEmail.isEmpty && model.invitePick == nil && model.roster.members.contains { $0.accountID == "a-kim" })
        model.inviteEmail = "new@x.com"
        #expect(model.invitee == .email("new@x.com"))
        await model.perform(.invite)
        #expect(server.calls.contains("invite:new@x.com:commenter:"))
        model.inviteEmail = "nobody"
        await model.perform(.invite)
        #expect(!server.calls.contains { $0.contains("nobody") })
    }

    @Test func aTeamThatCannotBeListedSuggestsNobodyAndAViewerLoadsNone() async {
        let server = server()
        server.offline = false
        let viewer = model(server, role: .viewer)
        server.roster = ShareRoster(members: [ShareMember(accountID: Self.me, displayName: "Priya", role: .viewer, effectiveRole: .viewer)], teamAccess: nil)
        await viewer.load()
        #expect(!viewer.mayInvite && viewer.suggestionPool.isEmpty && !server.calls.contains("listTeamMembers"))
        #expect(!viewer.hasActions && viewer.moveTargets.isEmpty)
        let failing = FailingTeamMembers(base: self.server())
        let model = ShareSheetModel(document: ShareDocument(id: "d1", name: "P", isUploaded: true, libraryRole: .owner), services: failing.services(), accountID: Self.me)
        model.teams = [Self.marketing]
        await model.load()
        #expect(model.suggestionPool.isEmpty && model.errorMessage == nil)
    }

    @Test func aLinkIsEditedAndOnlyItsChangesAreSent() async throws {
        let server = server()
        let model = model(server)
        await model.load()
        let link = try #require(model.links.first)
        #expect(!model.canSaveLink && model.linkChanges.isEmpty)
        await model.perform(.editLink(link))
        #expect(model.editingLink == link && model.editRole == .viewer && !model.editExpires && model.linkChanges.isEmpty && !model.canSaveLink)
        Render.view(ShareSheetView(model: model))
        await model.perform(.saveLink)
        #expect(model.editingLink == nil && !server.calls.contains { $0.hasPrefix("updateLink") }, "nothing changed: nothing sent")

        await model.perform(.editLink(link))
        model.editRole = .editor
        model.editExpires = true
        model.editExpiry = Date(timeIntervalSince1970: 1_000)
        model.editRevokeOnExpiry = true
        model.editClearPassword = true
        #expect(model.canSaveLink)
        await model.perform(.saveLink)
        #expect(server.calls.contains("updateLink:l1:editor:expires=date:revoke=true:password=clear:team=same"))
        #expect(model.links.first?.role == .editor && model.links.first?.hasPassword == false && model.notice == ShareSheetModel.linkUpdated && model.editingLink == nil)

        let edited = try #require(model.links.first)
        await model.perform(.editLink(edited))
        model.editExpires = false
        model.editPassword = "new"
        await model.perform(.saveLink)
        #expect(server.calls.contains("updateLink:l1:same:expires=never:revoke=false:password=set:team=same"))
        await model.perform(.editLink(try #require(model.links.first)))
        model.editTeamMembersOnly = true
        await model.perform(.cancelEdit)
        #expect(model.editingLink == nil)
        await model.perform(.editLink(try #require(model.links.first)))
        model.editTeamMembersOnly = true
        server.failNext(with: RPCError(code: .permissionDenied, message: "ROLE_INSUFFICIENT"))
        await model.perform(.saveLink)
        #expect(model.editingLink != nil && model.errorMessage == "ROLE_INSUFFICIENT", "a refusal keeps the edit open")
        await model.perform(.saveLink)
        #expect(server.calls.contains("updateLink:l1:same:expires=same:revoke=same:password=same:team=true"))
    }

    @Test func theActionsMenuTransfersAndMoves() async throws {
        let server = server()
        let model = model(server)
        let moves = Box<[String]>([])
        let succeeds = Box(false)
        model.moveToSpace = { space in
            moves.value.append(space)
            return succeeds.value
        }
        await model.load()
        #expect(model.hasActions && model.transferCandidates.map(\.accountID) == ["a-editor"])
        #expect(model.moveTargets == [Self.marketing, Self.design] && model.canMove)
        Render.view(ShareSheetView(model: model))
        Render.view(ShareActionsMenu(model: model))
        Render.view(ShareActionItems(model: model))
        Render.view(ShareTransferItems(model: model))
        Render.view(ShareMoveItems(model: model))
        await model.perform(.confirm(.move(Self.marketing)))
        #expect(ShareSheetModel.prompt(.move(Self.marketing)).message.contains("Marketing") && ShareSheetModel.prompt(.move(Self.personal)).message.contains("Personal"))
        await model.perform(.move(Self.marketing))
        #expect(moves.value == [Self.marketing.id] && model.errorMessage == "The document could not be moved to Marketing." && model.confirming == nil)
        succeeds.value = true
        await model.perform(.move(Self.design))
        #expect(model.notice == "Moved to Design." && model.errorMessage == nil && model.moveTargets == [Self.personal, Self.marketing])
        model.moveToSpace = nil
        #expect(model.moveTargets.isEmpty)
        await model.perform(.move(Self.personal))
        #expect(moves.value.count == 2)
        await model.perform(.confirm(.transfer(Self.editor)))
        await model.perform(.transfer(Self.editor))
        #expect(model.notice == "Eve is now the owner. You are an editor.")
    }

    @Test func aTeamLinkIsEditedWithItsRestriction() async throws {
        let server = server()
        let access = TeamAccessInfo(teamID: FakeCollaborationServer.teamID, teamName: "Marketing", teamDefault: .viewer, override: nil)
        server.roster = ShareRoster(members: [Self.owner, Self.editor], teamAccess: access)
        let model = model(server)
        await model.load()
        await model.perform(.editLink(try #require(model.links.first)))
        #expect(model.isTeamDocument && model.editingLink != nil)
        Render.view(ShareLinkEditor(model: model))
        Render.view(ShareSheetView(model: model))
    }

    @Test func theRequestCountFollowsTheSheet() async {
        let server = server()
        server.requests = [AccessRequestInfo(id: "r1", accountID: "a-req", displayName: "Kim", email: "kim@x.com")]
        let model = model(server)
        var counts: [Int] = []
        model.requestsDidChange = { id, count in
            #expect(id == "d1")
            counts.append(count)
        }
        await model.load()
        await model.perform(.resolve(model.requests[0], .viewer))
        #expect(counts == [1, 0])
        await model.perform(.confirm(.transfer(Self.editor)))
        await model.perform(.transfer(Self.editor))
        #expect(counts == [1, 0, 0])
    }
}

/// A collaboration server whose `ListMembers` of a team always fails.
final class FailingTeamMembers: TeamClient, @unchecked Sendable {
    let base: FakeCollaborationServer
    init(base: FakeCollaborationServer) { self.base = base }

    func services() -> CollaborationServices {
        var services = base.services()
        services.teams = self
        return services
    }

    func getTeam(teamID: String, accessToken: String) async throws -> TeamDetail { try await base.getTeam(teamID: teamID, accessToken: accessToken) }
    func setDefaultDocumentRole(teamID: String, role: DocumentRole, accessToken: String) async throws -> TeamDetail {
        try await base.setDefaultDocumentRole(teamID: teamID, role: role, accessToken: accessToken)
    }
    func listMembers(teamID: String, accessToken: String) async throws -> [TeamMemberInfo] { throw RPCError(code: .notFound, message: "TEAM_NOT_FOUND") }
    func listInvites(teamID: String, accessToken: String) async throws -> [TeamInviteInfo] { [] }
    func invite(teamID: String, email: String, role: TeamRole, accessToken: String) async throws -> TeamInviteInfo {
        try await base.invite(teamID: teamID, email: email, role: role, accessToken: accessToken)
    }
    func revokeInvite(teamID: String, inviteID: String, accessToken: String) async throws {}
    func setMemberRole(teamID: String, accountID: String, role: TeamRole, accessToken: String) async throws -> TeamMemberInfo {
        try await base.setMemberRole(teamID: teamID, accountID: accountID, role: role, accessToken: accessToken)
    }
    func removeMember(teamID: String, accountID: String, accessToken: String) async throws {}
    func addDomain(teamID: String, domain: String, accessToken: String) async throws -> WorkspaceDomainInfo {
        try await base.addDomain(teamID: teamID, domain: domain, accessToken: accessToken)
    }
    func verifyDomain(teamID: String, domain: String, accessToken: String) async throws -> WorkspaceDomainInfo {
        try await base.verifyDomain(teamID: teamID, domain: domain, accessToken: accessToken)
    }
    func removeDomain(teamID: String, domain: String, accessToken: String) async throws {}
    func setWorkspaceSettings(teamID: String, settings: WorkspaceSettingsValue, accessToken: String) async throws -> WorkspaceInfo {
        try await base.setWorkspaceSettings(teamID: teamID, settings: settings, accessToken: accessToken)
    }
    func acceptInvite(token: String, accessToken: String) async throws -> TeamDetail { try await base.acceptInvite(token: token, accessToken: accessToken) }
    func setHistoryRetention(teamID: String, days: Int, accessToken: String) async throws -> TeamDetail {
        try await base.setHistoryRetention(teamID: teamID, days: days, accessToken: accessToken)
    }
}

@Suite(.serialized) @MainActor struct ShareBadgeAndPopoverTests {
    @Test func theShareButtonCountsPendingRequestsForItsOwner() async throws {
        let server = FakeCollaborationServer()
        server.requests = [AccessRequestInfo(id: "r1", accountID: "a", displayName: "Kim", email: "k@x.com")]
        let owner = Box(true)
        let online = Box(true)
        let badges = ShareRequestBadges(services: server.services(), isOwner: { _ in owner.value }, isOnline: { online.value })
        let environment = TestEnvironment()
        let window = DocumentWindowController(document: DocumentHandle.memory(title: "Poster"), environment: environment.document)
        defer { window.close() }
        let id = window.documentHandle.id
        let toolbar = try #require(window.mainToolbar)
        await badges.attach(window)?.value
        #expect(badges.badge(for: id) == 1 && toolbar.badgeProviders[ShareCommands.id]?() == 1)
        let item = toolbar.item(for: ShareCommands.id)
        if #available(macOS 26.0, *) { #expect(item.badge != nil) } else { #expect(item.label == "Share (1)") }
        #expect(badges.attach(window) != nil, "attaching again only counts again")

        // A MembersChanged on the session counts again; other notices do not.
        server.requests.append(AccessRequestInfo(id: "r2", accountID: "b", displayName: "Lee", email: "l@x.com"))
        var event = Wiretuner_Sync_V1_DocumentEvent()
        event.membersChanged = Wiretuner_Sync_V1_MembersChanged()
        await badges.handle(.document(event), for: id)?.value
        #expect(badges.badge(for: id) == 2)
        #expect(badges.handle(.message("hi"), for: id) == nil)
        #expect(badges.handle(.document(Wiretuner_Sync_V1_DocumentEvent()), for: id) == nil)

        // The sheet resolved them; offline or not the owner, no badge.
        badges.set(id, count: 0)
        #expect(badges.badge(for: id) == nil)
        badges.set(id, count: 0)
        owner.value = false
        badges.set(id, count: 3)
        #expect(badges.refresh(id) == nil && badges.badge(for: id) == nil)
        owner.value = true
        online.value = false
        #expect(badges.refresh(id) == nil)
        online.value = true
        server.offline = true
        await badges.refresh(id)?.value
        #expect(badges.badge(for: id) == nil, "a failed count leaves the last one")
        badges.detach(window)
        #expect(toolbar.badgeProviders[ShareCommands.id] == nil)
        badges.detach(window)
    }

    @Test func offlineTheButtonExplainsInAPopover() async throws {
        let server = FakeCollaborationServer()
        let presenter = SharePresenter(services: server.services(), accountID: { FakeCollaborationServer.me }, isOnline: { false })
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 600, height: 400))
        defer { window.close() }
        #expect(SharePresenter.toolbarItem(in: window) == nil, "no toolbar")
        let item = NSToolbarItem(itemIdentifier: MainToolbarController.itemIdentifier(for: ShareCommands.id))
        var shown: [NSToolbarItem] = []
        presenter.shareItem = { _ in item }
        presenter.showPopover = { _, anchor in shown.append(anchor) }
        #expect(presenter.present(ShareSheetModelTests.document, on: window) == nil && presenter.sheet == nil)
        #expect(shown == [item] && presenter.offlinePopover?.contentViewController != nil)
        presenter.showOffline(from: item)
        #expect(shown.count == 2)
        Render.view(ShareOfflineNotice())

        // Online, the sheet opens and the app fills in its teams and spaces first.
        var configured = 0
        let online = SharePresenter(services: server.services(), accountID: { nil }, isOnline: { true })
        online.configure = { model in
            configured += 1
            model.spaces = [.personal(id: "p")]
        }
        let model = online.present(ShareSheetModelTests.document, on: window)
        #expect(configured == 1 && model?.spaces.count == 1)
        online.dismiss()
    }

    @Test func theToolbarItemIsFoundInAShownToolbar() {
        let environment = TestEnvironment()
        let window = DocumentWindowController(document: DocumentHandle.memory(title: "Poster"), environment: environment.document)
        defer { window.close() }
        let ns = window.window!
        ns.orderFront(nil)
        let found = SharePresenter.toolbarItem(in: ns)
        #expect(found == nil || found?.itemIdentifier == MainToolbarController.itemIdentifier(for: ShareCommands.id))
        ns.orderOut(nil)
        #expect(SharePresenter.toolbarItem(in: ns) == nil)
    }
}

@Suite(.serialized) @MainActor struct LibraryMoveToSpaceTests {
    @Test func theOwnerMovesADocumentToAnotherSpace() async throws {
        let server = FakeLibraryServer()
        let team = LibrarySpace(id: "t1", name: "Marketing", kind: .team)
        server.setTeams([team])
        server.put(LibraryDocument(id: "d1", spaceID: server.accountID, name: "Poster", role: .owner))
        server.put(LibraryDocument(id: "d2", spaceID: server.accountID, name: "Shared", role: .editor))
        let library = LibraryModel(services: server.services(), store: nil, thumbnails: ThumbnailCache(directory: nil))
        await library.refresh()
        let poster = try #require(library.cache.documents["d1"])
        let shared = try #require(library.cache.documents["d2"])
        #expect(library.moveTargets(for: poster) == [team] && library.moveTargets(for: shared).isEmpty)
        Render.view(LibraryView(model: library))
        #expect(await library.move("d1", toSpace: "t1") && library.cache.documents["d1"]?.spaceID == "t1")
        #expect(await !library.move("d1", toSpace: "t1"), "already there")
        #expect(await !library.move("nope", toSpace: "t1"))
        server.failNext(with: RPCError(code: .permissionDenied, message: "ROLE_INSUFFICIENT"))
        #expect(await !library.move("d1", toSpace: server.accountID))
        var pending = poster
        pending.isPendingUpload = true
        #expect(library.moveTargets(for: pending).isEmpty)
        // A drop on a space moves only what the caller owns there.
        #expect(!library.drop(["d2", "nope"], onSpace: team))
        #expect(library.drop(["d1"], onSpace: .personal(id: server.accountID)))
        #expect(await eventually { library.cache.documents["d1"]?.spaceID == server.accountID })
    }
}
