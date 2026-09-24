import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTSync
@testable import WireTuner

/// DATA-010's WTApp half and DATA-017's source sheets: the file, script and Web API sheets, the
/// credentials sheet (admins only for a team, D-062; secrets cleared as soon as the call returns),
/// *Show Hosts*, the consent alert and the scope of a document.
@Suite(.serialized) @MainActor struct DataSourceSheetTests {
    // MARK: File and script sheets

    @Test func theFileSheetShowsWhatWasDetectedAndConnectsWithABookmark() async throws {
        let world = DataWorld()
        defer { world.close() }
        let json = try DataFileReaderFixtures.file("orders.json", #"{"data":[{"id":1,"customer":{"name":"Ann"}},{"id":2,"customer":{"name":"Bo"}}]}"#)
        let model = try #require(world.features.presentFileSheet(json, json: true))
        #expect(model.isJSON && model.format == .json && model.preview?.records.count == 1, "the root object is one record")
        #expect(world.window.window?.attachedSheet?.identifier?.rawValue == "sheet.fileSource")
        world.window.window?.attachedSheet.map { world.window.window?.endSheet($0) }
        model.recordsPath = "$.data"
        model.reread()
        #expect(model.preview?.columns == ["id", "customer"] && model.preview?.records.count == 2)
        Render.view(FileSourceSheet(model: model, connect: {}, close: {}))
        model.recordsPath = "$[?(@.id)]"
        model.reread()
        #expect(model.preview == nil && model.error?.contains("filter") == true)
        Render.view(FileSourceSheet(model: model, connect: {}, close: {}))
        model.recordsPath = "$.data"
        let source = try model.source()
        #expect(source.spec.kind == .file && source.spec.file.format == .json && source.spec.file.fileName == "orders.json" && !source.spec.file.bookmark.isEmpty)
        #expect(source.name == "orders" && source.spec.file.recordsPath == "$.data")
        _ = await world.features.connect(model)?.value
        await world.document.settle()
        #expect(world.session.model.activeSource?.kind == .file && world.document.undoTitle == "Undo Connect source")
        // A TSV file detects the tab; a corrected setting reads again.
        let tsv = try DataFileReaderFixtures.file("people.tsv", "a\tb\n1\t2\n")
        let delimited = FileSourceModel(url: tsv, json: false)
        #expect(delimited.format == .tsv && delimited.delimiter == "\t" && delimited.options.delimiter == "\t")
        delimited.headerRow = false
        delimited.reread()
        #expect(delimited.preview?.columns == ["column_1", "column_2"])
        Render.view(FileSourceSheet(model: delimited, connect: {}, close: {}))
        var ran = 0
        FileSourceSheet.run({ ran += 1 }, { ran += 10 })()
        #expect(ran == 11)
        // A file that goes away before Connect cannot be bookmarked.
        let gone = try DataFileReaderFixtures.file("gone.csv", "a\n1\n")
        let lost = FileSourceModel(url: gone, json: false)
        try FileManager.default.removeItem(at: gone)
        #expect(world.features.connect(lost) == nil)
        world.window.window?.attachedSheet.map { world.window.window?.endSheet($0) }
        // The script sheet lists the document's scripts.
        #expect(world.features.presentScriptSource()?.scripts.isEmpty == true)
        world.window.window?.attachedSheet.map { world.window.window?.endSheet($0) }
        let empty = ScriptSourceModel(scripts: [])
        #expect(empty.chosen == nil && empty.source == nil)
        Render.view(ScriptSourceSheet(model: empty, connect: {}, close: {}))
        _ = await world.document.perform(SaveScript(name: "", source: "export function records() { return []; }")).value
        let scripts = ScriptSourceModel(scripts: DocumentScript.list(world.document.state))
        Render.view(ScriptSourceSheet(model: scripts, connect: {}, close: {}))
        #expect(scripts.source?.name == "")
    }

    // MARK: Web API

    @Test func theWebSheetValidatesTestsAndConnectsInOneChange() async throws {
        let world = DataWorld(pages: [[["$.customer.name": "Ann", "id": "7"]]])
        defer { world.close() }
        let ids = await world.fields(["name", "id"])
        let model = try #require(world.features.presentWebSource(editing: nil))
        world.window.window?.attachedSheet.map { world.window.window?.endSheet($0) }
        #expect(model.title == "Web API Source" && model.method == .get && model.timeout == 30 && model.maxPages == 1000 && model.pagination == .none)
        #expect(model.problem == "Enter the API’s address.")
        #expect(model.command() == nil && !model.connect() && model.message == "Enter the API’s address.")
        model.url = "http://api.example.com/orders"
        #expect(model.problem?.contains("not an https address") == true)
        await model.test()
        #expect(model.message?.contains("not an https address") == true)
        model.url = "https://api.example.com/orders?since={{since}}"
        model.addHeader()
        model.headers[0].name = "Authorization"
        model.headers[0].value = "Bearer x"
        #expect(model.problem == "The Authorization header cannot be stored in a source: add a credential instead.")
        model.headers[0].name = "Accept"
        model.headers[0].value = "application/json"
        model.addHeader()
        model.removeHeader(model.headers[1].id)
        model.addParam()
        model.params[0].name = "since"
        model.params[0].value = "2026"
        model.addParam()
        model.removeParam(model.params[1].id)
        model.method = .post
        model.body = "{\"since\":\"{{since}}\"}"
        model.pagination = .nextURL
        model.nextURLPath = "$.next"
        model.recordsPath = "$.data[*]"
        model.credential = "orders-api"
        model.mapping[ids[0]] = "$.customer.name"
        #expect(model.problem == nil)
        let http = model.http
        #expect(http.headers.map(\.name) == ["Accept"] && http.params.map(\.name) == ["since"] && http.bodyTemplate.contains("since"))
        #expect(http.pagination.nextURLPath == "$.next" && http.pagination.pageParam.isEmpty && http.timeoutS == 30)
        world.session.params["since"] = "2027"
        #expect(model.request.params["since"] == "2027" && model.request.paths == ["$.customer.name", "id"] && model.request.source.url.hasPrefix("https://"))
        // Credentials for the pop-up, then Test: the first page through the service.
        world.transport.update { $0.credentials = [.with { $0.name = "orders-api" }] }
        await model.loadCredentials()
        #expect(model.credentials == ["orders-api"])
        await model.test()
        #expect(model.testRecords?.count == 1 && model.message == "The first page has 1 record." && !model.isTesting)
        world.transport.update { $0.pages = [[["id": "1"], ["id": "2"]]] }
        await model.test()
        #expect(model.message == "The first page has 2 records.")
        world.transport.update { $0.pages = [] }
        await model.test()
        #expect(model.testRecords?.isEmpty == true)
        world.transport.update { $0.failure = DataServiceError.upstream("502") }
        await model.test()
        #expect(model.testRecords == nil && model.message == "The web API failed: 502")
        Render.view(WebSourceSheet(model: model, close: {}))
        model.pagination = .pageParam
        model.pageParam = "page"
        Render.view(WebSourceSheet(model: model, close: {}))
        WebSourceSheet.maxPages(model)(5)
        WebSourceSheet.timeout(model)(500)
        #expect(model.maxPages == 5 && model.http.timeoutS == 120)
        WebSourceSheet.mapping(ids[1], model).wrappedValue = "$.id"
        #expect(WebSourceSheet.mapping(ids[1], model).wrappedValue == "$.id")
        WebSourceSheet.removeHeader(model.headers[0].id, model)()
        WebSourceSheet.removeParam(model.params[0].id, model)()
        WebSourceSheet.test(model)()
        // Connect: one change.
        var closed = 0
        WebSourceSheet.connect(model, { closed += 1 })()
        await world.document.settle()
        #expect(closed == 1 && world.document.undoTitle == "Undo Connect source")
        let source = try #require(world.session.model.activeSource)
        #expect(source.kind == .http && source.mapping.count == 2 && source.spec.http.pagination.pageParam == "page")
        // Editing it writes the registers, headers, parameters and mapping as one change.
        let edit = WebSourceModel(session: world.session, source: source)
        #expect(edit.title == "Edit Web API Source" && edit.editing == source.id && edit.mapping[ids[0]] == "$.customer.name")
        edit.name = "Orders"
        edit.addHeader()
        edit.headers[0].name = "Accept"
        edit.mapping[ids[0]] = ""
        #expect(edit.connect())
        await world.document.settle()
        let edited = try #require(world.session.model.activeSource)
        #expect(edited.name == "Orders" && edited.spec.http.headers.map(\.name) == ["Accept"] && world.document.undoTitle == "Undo Change source")
        #expect(!edited.mapping.contains { $0.field == ids[0] })
        // An edited source that is not connected is connected again.
        _ = await world.document.perform(SetActiveSource(nil)).value
        await world.document.settle()
        let reconnect = WebSourceModel(session: world.session, source: world.session.model.source(source.id))
        #expect(reconnect.connect())
        await world.document.settle()
        #expect(world.session.model.activeSource?.id == source.id)
        // Signed out: no credentials, and Test says so.
        world.session.services.client = { nil }
        await edit.loadCredentials()
        await edit.test()
        #expect(edit.message == DataServiceMessages.signedOut)
    }

    // MARK: Credentials

    @Test func credentialsAreManagedOnlyByAdminsAndSecretsAreClearedAtOnce() async throws {
        let transport = FakeDataTransport()
        transport.update { $0.credentials = [.with { $0.name = "orders"; $0.kind = .bearer; $0.host = "api.example.com"; $0.createdByName = "Ann" }] }
        let client = DataSourceClient(transport: transport, directory: TestEnvironment.temporaryDirectory()) { "token" }
        let team = DataScope(kind: .team(id: "t1", name: "Marketing"), canManage: false)
        let member = CredentialsModel(documentID: "doc", client: client) { team }
        await member.load()
        #expect(member.items.map(\.name) == ["orders"] && !member.canManage && member.message == "Only admins of Marketing can add, replace or remove its credentials.")
        member.add()
        member.replace(member.items[0])
        let saved = await member.save()
        let removed = await member.remove("orders")
        #expect(member.draft == nil && !saved && !removed)
        Render.view(CredentialsSheet(model: member, close: {}))
        // An admin adds one; the secret leaves with the request and is gone from the draft.
        let admin = CredentialsModel(documentID: "doc", client: client) { DataScope(kind: .team(id: "t1", name: "Marketing"), canManage: true) }
        await admin.load()
        #expect(admin.canManage && admin.message == nil)
        admin.add()
        #expect(admin.draft == CredentialsModel.Draft())
        admin.draft?.name = "bad name"
        #expect(!(await admin.save()) && admin.message?.hasPrefix("Names use") == true)
        admin.draft?.name = "tickets"
        #expect(!(await admin.save()) && admin.message == "Enter the host the credential may be sent to.")
        admin.draft?.host = " API.Tickets.com "
        #expect(!(await admin.save()) && admin.message == "Enter the secret.")
        admin.draft?.token = "s3cret"
        Render.view(CredentialsSheet(model: await Self.shown(admin), close: {}))
        #expect(await admin.save())
        #expect(admin.draft == nil && admin.items.map(\.name) == ["orders", "tickets"])
        let put = try #require(transport.snapshot.puts.last)
        #expect(put.token == "s3cret" && put.host == "api.tickets.com" && put.scope.teamID == "t1")
        // A failed save still clears the secret fields.
        admin.replace(admin.items[1])
        #expect(admin.draft?.replacing == true && admin.draft?.name == "tickets")
        admin.draft?.kind = .basic
        admin.draft?.username = "ann"
        admin.draft?.password = "pw"
        transport.update { $0.failure = DataServiceError.offline }
        #expect(!(await admin.save()))
        #expect(admin.draft?.password == "" && admin.draft?.username == "ann" && admin.message == "Credentials need a connection to the WireTuner service.")
        Render.view(CredentialsSheet(model: await Self.shown(admin), close: {}))
        admin.cancel()
        #expect(admin.draft == nil)
        // Remove asks first.
        admin.confirmRemove = { _ in false }
        #expect(!(await admin.remove("orders")))
        admin.confirmRemove = { _ in true }
        #expect(await admin.remove("orders"))
        #expect(admin.items.map(\.name) == ["tickets"])
        transport.update { $0.failure = DataServiceError.rejected(code: 7, message: "ROLE_INSUFFICIENT") }
        #expect(!(await admin.remove("tickets")) && admin.message == "ROLE_INSUFFICIENT")
        CredentialsSheet.replace(Wiretuner_Data_V1_Credential.with { $0.name = "tickets" }, admin)()
        CredentialsSheet.draft(admin).wrappedValue.host = "h"
        #expect(admin.draft?.host == "h")
        CredentialsSheet.save(admin)()
        CredentialsSheet.remove("none", admin)()
        admin.cancel()
        #expect(CredentialsSheet.draft(admin).wrappedValue == CredentialsModel.Draft())
        // Each kind carries its own secret.
        var draft = CredentialsModel.Draft(name: "n", kind: .header, host: "h", headerName: "X-Key", headerValue: "v")
        #expect(draft.problem == nil && draft.request(scope: team.proto).headerValue == "v" && draft.request(scope: team.proto).token.isEmpty)
        draft.kind = .oauth2Client
        #expect(draft.problem == "Enter the secret.")
        draft.clientSecret = "c"
        draft.clientID = "id"
        draft.tokenURL = "https://auth.example.com/token"
        draft.oauthScope = "read"
        let oauth = draft.request(scope: team.proto)
        #expect(oauth.clientSecret == "c" && oauth.clientID == "id" && oauth.oauthScope == "read")
        draft.kind = .basic
        #expect(draft.problem == "Enter the secret.")
        draft.clearSecrets()
        #expect(draft.clientSecret.isEmpty && draft.headerValue.isEmpty)
        for kind in [Wiretuner_Data_V1_CredentialKind.bearer, .basic, .header, .oauth2Client] {
            var shown = CredentialsModel.Draft()
            shown.kind = kind
            Render.view(CredentialEditor(draft: .constant(shown)))
        }
        #expect(CredentialsModel.title(.basic) == "User name and password" && CredentialsModel.title(.unspecified) == "Unknown")
        // Signed out; a listing that fails.
        let signedOut = CredentialsModel(documentID: "doc", client: nil) { nil }
        await signedOut.load()
        #expect(signedOut.message?.contains("Sign in") == true && !signedOut.canManage)
        transport.update { $0.failure = DataServiceError.upstream("x") }
        let failing = CredentialsModel(documentID: "doc", client: client) { team }
        await failing.load()
        #expect(failing.message == "The web API failed: x")
    }

    /// A copy of `model`'s items and draft to render (a rendered sheet loads its model again).
    static func shown(_ model: CredentialsModel) async -> CredentialsModel {
        let transport = FakeDataTransport()
        transport.update { $0.credentials = model.items }
        let client = DataSourceClient(transport: transport, directory: TestEnvironment.temporaryDirectory()) { "token" }
        let copy = CredentialsModel(documentID: model.documentID, client: client) { DataScope(kind: .personal(account: "a"), canManage: true) }
        await copy.load()
        copy.draft = model.draft ?? CredentialsModel.Draft()
        return copy
    }

    // MARK: Hosts

    @Test func showHostsListsWhatTheSourcesReachAndLetsTheOwnerRevoke() async throws {
        let world = DataWorld()
        defer { world.close() }
        world.transport.update { $0.allowed = ["api.example.com", "old.example.com"] }
        var source = Wiretuner_Doc_V1_DataSource()
        source.name = "Orders"
        source.spec.kind = .http
        source.spec.http.url = "https://API.example.com:443/orders"
        _ = await world.document.perform(AddSource(source)).value
        var other = Wiretuner_Doc_V1_DataSource()
        other.spec.kind = .http
        other.spec.http.url = "https://new.example.com:8443/{{path}}"
        _ = await world.document.perform(AddSource(other)).value
        await world.document.settle()
        let model = try #require(world.features.presentHosts())
        world.window.window?.attachedSheet.map { world.window.window?.endSheet($0) }
        #expect(model.rows.map(\.host) == ["api.example.com", "new.example.com:8443"] && model.rows.allSatisfy { !$0.permitted })
        await model.load()
        #expect(model.rows.map(\.host) == ["api.example.com", "new.example.com:8443", "old.example.com"])
        #expect(model.rows[0].permitted && model.rows[0].usedBy == ["Orders"] && model.rows[1].usedBy == ["Web API"] && model.rows[2].usedBy.isEmpty)
        #expect(model.canRevoke)
        #expect(await model.revoke("old.example.com"))
        #expect(model.rows.map(\.host) == ["api.example.com", "new.example.com:8443"])
        HostsSheet.revoke("api.example.com", model)()
        // The button's revoke runs in its own task; let it land before going offline, or its
        // success can clear the offline message the checks below expect.
        func revoked() -> Bool { model.rows.first { $0.host == "api.example.com" }?.permitted == false }
        for _ in 0..<2_000 where !revoked() { await Task.yield() }
        #expect(revoked())
        world.transport.update { $0.failure = DataServiceError.offline }
        #expect(!(await model.revoke("api.example.com")) && model.message == "Credentials need a connection to the WireTuner service.")
        world.transport.update { $0.failure = DataServiceError.offline }
        await model.load()
        #expect(model.message == "Credentials need a connection to the WireTuner service.")
        #expect(HostsModel.host(of: "http://plain.example.com") == nil && HostsModel.host(of: "not a url") == nil && HostsModel.host(of: "https://") == nil)
        #expect(HostsModel.rows(referenced: [("a", "x"), ("a", "x"), ("a", "y")], allowed: []).first?.usedBy == ["x", "y"])
        // A team document's hosts are kept in the team settings; signed out, nothing loads.
        world.features.services.scope = { _ in DataScope(kind: .team(id: "t", name: "T"), canManage: true) }
        world.session.services = world.features.services
        let team = HostsModel(session: world.session)
        await team.load()
        let revoked = await team.revoke("api.example.com")
        #expect(!team.canRevoke && !revoked)
        world.session.services.client = { nil }
        let signedOut = HostsModel(session: world.session)
        await signedOut.load()
        #expect(signedOut.message?.contains("Sign in") == true)
        Render.view(HostsSheet(model: HostsModel(session: DataSession(document: .memory(title: "Empty"))), close: {}))
        Render.view(HostsSheet(model: model, close: {}))
    }

    // MARK: Consent, messages and scopes

    @Test func theConsentAlertNamesTheDocumentAndTheHost() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        var shown: [String] = []
        let allowed = await DataConsent.ask(host: "api.example.com", window: setup.window) { alert, window in
            shown.append(alert.messageText)
            #expect(window === setup.window.window && alert.buttons.map(\.title) == ["Allow", "Don’t Allow"])
            return .alertFirstButtonReturn
        }
        #expect(allowed && shown == ["Allow “Setup” to fetch data from api.example.com?"])
        let denied = await DataConsent.ask(host: "x", window: nil) { _, _ in .alertSecondButtonReturn }
        #expect(!denied)
        #expect(DataConsent.message(host: "h", document: "D").1.contains("every Mac"))
        let errors: [any Error] = [
            DataServiceError.credentialMissing, DataServiceError.responseTooLarge, DataServiceError.rateLimited(retryAfter: .seconds(30)),
            DataServiceError.rateLimited(retryAfter: nil), DataServiceError.hostNotAllowed(host: "h", admins: ""), DataConsentDenied(host: "h"),
            DataEditError.noPlaceholder, ScriptError.timeout, CocoaError(.fileNoSuchFile),
        ]
        #expect(errors.map(DataServiceMessages.text).allSatisfy { !$0.isEmpty })
        #expect(DataServiceMessages.text(DataServiceError.rateLimited(retryAfter: .seconds(30))).contains("30 s"))
        let edits: [DataEditError] = [.invalidName("1"), .duplicateName("a"), .unknownField(.zero), .unknownSource(.zero), .bindingNotAllowed(.zero),
                                      .secretHeader("Cookie"), .invalidURL("x"), .noPlaceholder, .invalidValue("Size")]
        #expect(Set(edits.map(DataEditMessages.text)).count == edits.count)
        let personal = DataScope(kind: .personal(account: "a1"), canManage: true)
        #expect(personal.isPersonal && personal.proto.accountID == "a1" && personal.managerNote.contains("owner"))
        let team = DataScope(kind: .team(id: "t1", name: "Design"), canManage: false)
        #expect(!team.isPersonal && team.proto.teamID == "t1")
    }

    @Test func aDocumentsScopeComesFromTheLibraryAndTheTeamRole() async throws {
        let server = FakeLibraryServer()
        server.setTeams([LibrarySpace(id: FakeCollaborationServer.teamID, name: "Marketing", kind: .team)])
        server.put(LibraryDocument(id: "team-doc", spaceID: FakeCollaborationServer.teamID, name: "Labels", role: .editor))
        let library = LibraryModel(services: server.services(), store: nil, thumbnails: ThumbnailCache(directory: nil))
        let collaboration = FakeCollaborationServer()
        library.collaboration = collaboration.services()
        await library.refresh()
        await library.switchSpace(to: FakeCollaborationServer.teamID)
        let services = collaboration.services()
        #expect(await DataScopes.scope(of: "x", library: library, account: nil, collaboration: services) == nil)
        let personal = await DataScopes.scope(of: "mine", library: library, account: "acct", collaboration: services)
        #expect(personal?.isPersonal == true && personal?.canManage == true)
        let team = await DataScopes.scope(of: "team-doc", library: library, account: "acct", collaboration: services)
        #expect(team == DataScope(kind: .team(id: FakeCollaborationServer.teamID, name: "Marketing"), canManage: true), "the fake's caller is the owner")
        collaboration.team.callerRole = .member
        #expect(await DataScopes.scope(of: "team-doc", library: library, account: "acct", collaboration: services)?.canManage == false)
        collaboration.teamUnavailable = true
        #expect(await DataScopes.scope(of: "team-doc", library: library, account: "acct", collaboration: services)?.canManage == false)
        // The app's client is none in a test launch.
        let suite = TestDefaults()
        let account = LaunchEnvironment().makeAccountModel(infoDictionary: nil, defaults: suite.defaults)
        #expect(LaunchEnvironment().makeDataSourceClient(account: account, infoDictionary: nil, defaults: suite.defaults) == nil)
    }
}
