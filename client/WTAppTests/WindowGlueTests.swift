import AppKit
import Foundation
import GRPCCore
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
@testable import WireTuner

extension FakeCollaborationServer {
    /// `UpdateTeam.history_retention_days` on the in-memory team.
    func setHistoryRetention(teamID: String, days: Int, accessToken: String) async throws -> TeamDetail {
        if offline { throw RPCError(code: .unavailable, message: "offline") }
        team.historyRetentionDays = days
        return team
    }
}

/// The smaller features of this build: the print, edit and glue installs in the app; Document
/// Info; the team's history window; linked identities; the storage messaging; Preview in
/// Browser's exporter; the Guides layer's hooks; the Links window's badge and the Object panel's
/// btn:[Links…].
@Suite(.serialized) @MainActor struct WindowGlueTests {
    // MARK: The app

    @Test func theFeaturesAreWiredIntoTheApp() async throws {
        let suite = TestDefaults()
        defer { suite.remove() }
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let window = try #require(delegate.activeDocumentWindow)
        defer { window.close() }
        #expect(!(delegate.tools.makeTool(OutputAreaTool.id) is UnimplementedTool))
        #expect(delegate.commands.command(StandardCommands.ID.print)?.validation() == .enabled)
        #expect(delegate.commands.command(EditFeatures.ID.copyAttributes) != nil && delegate.commands.command(DocumentInfoFeatures.id) != nil)
        #expect(delegate.panels.descriptor(for: "halftones")?.helpSlug == "halftones")
        #expect(InspectorRegistry.standard.sections.contains { $0.id == "links" } && InspectorRegistry.standard.sections.contains { $0.id == "group" })
        #expect(window.objectEditing.pasteboard is FormatsPasteboard)
        #expect(delegate.browserPreview.exporter is WebPreviewExporter)
        #expect(delegate.exports.outputArea(window) == nil)
        _ = await window.documentHandle.perform(SetOutputArea(Rect(x: 0, y: 0, width: 10, height: 10))).value
        #expect(delegate.exports.outputArea(window) == Rect(x: 0, y: 0, width: 10, height: 10))
        #expect(GuidesLayer.window() === window && LinkUploads.pending(window).isEmpty)
        LinkUploads.showLinks(OpID(counter: 1, replica: 1))
        #expect(delegate.documentSetup.links != nil)
        delegate.documentSetup.links?.close()
        #expect(delegate.documentInfo.userName().isEmpty)
        #expect(await delegate.storage.refresh() == false, "not signed in: nothing read")
        #expect(delegate.storage.windows().contains { $0 === window } && delegate.storage.space(window.documentHandle) == nil)
        // Paste reads plain text through the clipboard reader.
        let pasteImport = try #require(window.environment.pasteImport)
        let general = NSPasteboard.general
        let saved = general.string(forType: .string)
        general.clearContents()
        general.setString("from another app", forType: .string)
        #expect(pasteImport.canPaste())
        pasteImport.paste(window)
        try await Task.sleep(for: .milliseconds(200))
        await window.documentHandle.settle()
        general.clearContents()
        pasteImport.paste(window)
        if let saved { general.setString(saved, forType: .string) }
        try await delegate.editMenu.storeBlobs(ImportedScene(kind: .vector, name: "x", bounds: .zero, nodes: []), window.documentHandle)
    }

    // MARK: Document Info

    @Test func documentInfoCommitsFieldsKeywordsAndTheCreator() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let features = DocumentInfoFeatures()
        var sheets: [NSWindow] = []
        features.presentSheet = { sheet, _ in sheets.append(sheet) }
        features.userName = { "Priya" }
        let registry = CommandRegistry()
        let window = setup.window
        features.install(into: registry) { window }
        #expect(registry.command(DocumentInfoFeatures.id)?.defaultKey == KeyEquivalent("i", [.command, .option]))
        #expect(registry.command(DocumentInfoFeatures.id)?.validation() == .enabled)
        registry.perform(DocumentInfoFeatures.id)
        await setup.document.settle()
        #expect(sheets.last?.identifier?.rawValue == DocumentInfoFeatures.sheetID)
        let model = try #require(features.present())
        await setup.document.settle()
        #expect(model.values.info.creators == ["Priya"] && model.text(.creators) == "Priya")
        model.prefillCreator("Someone else")
        model.commit(.title, "  Poster  ")
        await setup.document.settle()
        model.commit(.title, "Poster")
        model.commit(.supplementalCategories, "SPO, ART")
        model.commit(.headline, String(repeating: "h", count: 300))
        #expect(model.message == "Headline is too long.")
        model.setCopyrightStatus(.copyrighted)
        await setup.document.settle()
        model.setCopyrightStatus(.copyrighted)
        model.addKeywords("blue, poster, ")
        model.addKeywords(" ")
        await setup.document.settle()
        #expect(model.message == nil && model.text(.title) == "Poster" && model.text(.supplementalCategories) == "SPO, ART")
        #expect(model.copyrightStatus == .copyrighted && model.keywords == ["blue", "poster"] && model.counter(.headline, draft: "abc") == "3/256")
        model.removeKeyword("BLUE")
        await setup.document.settle()
        #expect(model.keywords == ["poster"])
        #expect(DocumentInfoModel.describe(DocumentInfoError.tooMany(.creators)) == "Creator has too many entries.")
        #expect(DocumentInfoModel.describe(DocumentInfoError.invalidURL) == "The web statement must be a URL.")
        #expect(DocumentInfoModel.describe(DocumentInfoError.keywords).hasPrefix("Keywords"))
        #expect(DocumentInfoModel.describe(CocoaError(.fileNoSuchFile)) == "The change could not be made.")
        // The sheet and its fields render; a field commits its draft.
        Render.view(DocumentInfoSheet(model: model), size: CGSize(width: 520, height: 640))
        Render.view(FlowTokens(tokens: ["a"]) { _ in })
        Render.view(InfoTextField(field: .description, model: model))
        var draft: String? = nil
        let binding = InfoTextField.binding(Binding(get: { draft }, set: { draft = $0 }), value: "Poster")
        #expect(binding.wrappedValue == "Poster")
        binding.wrappedValue = "Big poster"
        InfoTextField.commit(model, .title, draft: draft)
        InfoTextField.commit(model, .title, draft: nil)
        await setup.document.settle()
        var typed: String? = "Bigger poster"
        let typing = Binding(get: { typed }, set: { typed = $0 })
        InfoTextField.focusChanged(model, .title, draft: typing, focused: true)
        #expect(typed == "Bigger poster")
        InfoTextField.focusChanged(model, .title, draft: typing, focused: false)
        #expect(typed == nil)
        await setup.document.settle()
        var keyword = "red"
        DocumentInfoSheet.addKeyword(model, Binding(get: { keyword }, set: { keyword = $0 }))()
        #expect(keyword.isEmpty)
        await setup.document.settle()
        var removed: [String] = []
        FlowTokens.remove("red") { removed.append($0) }()
        #expect(removed == ["red"] && model.keywords.contains("red"))
        #expect(model.text(.title) == "Bigger poster")
        model.commit(.title, "Big poster")
        DocumentInfoSheet.status(model).wrappedValue = 2
        await setup.document.settle()
        #expect(model.text(.title) == "Big poster" && DocumentInfoSheet.status(model).wrappedValue == 2)
        #expect(DocumentInfoModel.sections.flatMap(\.fields).count == 18)
        model.onClose()
        #expect(features.sheet == nil)
        features.dismiss()
        // The default presentation: a sheet on the window, ended by Done.
        let shown = DocumentInfoFeatures()
        shown.window = { window }
        let onWindow = try #require(shown.present())
        onWindow.onClose()
        shown.presentSheet(TestWindow.make(), nil)
        features.window = { nil }
        #expect(features.present() == nil && registry.command(DocumentInfoFeatures.id)?.validation() == .disabled("No document is open"))
    }

    // MARK: Teams and account

    @Test func theTeamsHistoryWindowIsReadAndSetByAdmins() async throws {
        let server = FakeCollaborationServer()
        let model = TeamSettingsModel(teamID: FakeCollaborationServer.teamID, services: server.services(), accountID: FakeCollaborationServer.me)
        await model.load()
        #expect(model.historyDays == 30)
        model.historyDaysBinding.wrappedValue = 365
        await model.lastTask?.value
        #expect(model.historyDays == 365 && model.historyDaysBinding.wrappedValue == 365 && model.notice == "History is now kept for 1 year.")
        await model.perform(.setHistoryDays(365))
        await model.perform(.setHistoryDays(10))
        #expect(server.team.historyRetentionDays == 365)
        Render.view(TeamSettingsView(model: model))
        Render.view(TeamHistorySection(model: model))
        server.offline = true
        await model.perform(.setHistoryDays(730))
        #expect(!model.isOnline && model.historyDays == 365)
        #expect(TeamHistory.title(400) == "400 days" && TeamHistory.days(0) == 30)
        #expect(TeamHistorySection.choices(including: 400).map(\.days) == [30, 90, 180, 365, 400, 730, 1825, 3650])
        #expect(TeamHistorySection.choices(including: 90).count == 7)
        #expect(TeamHistory.request(teamID: "t", days: 5).historyRetentionDays == 30)
        var team = Wiretuner_Account_V1_Team()
        team.historyRetentionDays = 90
        #expect(TeamDetail(team).historyRetentionDays == 90)
        // A client without the call refuses.
        struct Bare: TeamClient {
            func getTeam(teamID: String, accessToken: String) async throws -> TeamDetail { throw TeamHistoryError.unsupported }
            func setDefaultDocumentRole(teamID: String, role: DocumentRole, accessToken: String) async throws -> TeamDetail { throw TeamHistoryError.unsupported }
            func listMembers(teamID: String, accessToken: String) async throws -> [TeamMemberInfo] { [] }
            func listInvites(teamID: String, accessToken: String) async throws -> [TeamInviteInfo] { [] }
            func invite(teamID: String, email: String, role: TeamRole, accessToken: String) async throws -> TeamInviteInfo { throw TeamHistoryError.unsupported }
            func revokeInvite(teamID: String, inviteID: String, accessToken: String) async throws {}
            func setMemberRole(teamID: String, accountID: String, role: TeamRole, accessToken: String) async throws -> TeamMemberInfo { throw TeamHistoryError.unsupported }
            func removeMember(teamID: String, accountID: String, accessToken: String) async throws {}
            func addDomain(teamID: String, domain: String, accessToken: String) async throws -> WorkspaceDomainInfo { throw TeamHistoryError.unsupported }
            func verifyDomain(teamID: String, domain: String, accessToken: String) async throws -> WorkspaceDomainInfo { throw TeamHistoryError.unsupported }
            func removeDomain(teamID: String, domain: String, accessToken: String) async throws {}
            func setWorkspaceSettings(teamID: String, settings: WorkspaceSettingsValue, accessToken: String) async throws -> WorkspaceInfo { WorkspaceInfo() }
            func acceptInvite(token: String, accessToken: String) async throws -> TeamDetail { throw TeamHistoryError.unsupported }
        }
        await #expect(throws: TeamHistoryError.unsupported) { try await Bare().setHistoryRetention(teamID: "t", days: 90, accessToken: "x") }
        // The gRPC client sends UpdateTeam with the days.
        let caller = FakeUnaryCaller([route(Wiretuner_Account_V1_TeamService.Method.UpdateTeam.descriptor) { (request: Wiretuner_Account_V1_UpdateTeamRequest) in
            var response = Wiretuner_Account_V1_UpdateTeamResponse()
            response.team.historyRetentionDays = request.historyRetentionDays
            return response
        }])
        let detail = try await GRPCTeamClient(caller: caller).setHistoryRetention(teamID: "t", days: 180, accessToken: "x")
        #expect(detail.historyRetentionDays == 180)
    }

    @Test func linkedIdentitiesAreManagedInTheRealmsConsole() async throws {
        #expect(LinkedIdentities.consoleURL(issuer: URL(string: "https://id.example.com/realms/wt")!).absoluteString
                == "https://id.example.com/realms/wt/account#/account-security/linked-accounts")
        #expect(LinkedIdentities.title("sso:Acme") == "Acme SSO" && LinkedIdentities.title("apple") == "Apple")
        var opened: [URL] = []
        let previous = LinkedIdentities.open
        LinkedIdentities.open = { opened.append($0) }
        defer { LinkedIdentities.open = previous }
        let model = AccountModelTests().model()
        LinkedIdentities.manage(model)
        #expect(opened.first?.fragment == "/account-security/linked-accounts")
        Render.view(LinkedIdentitiesView(identities: AccountModelTests.profile.identities) {})
        Render.view(LinkedIdentitiesView(identities: [AccountModelTests.profile.identities[0]]) {})
        await model.signIn(.standard)
        await model.loadProfile()
        Render.view(AccountView(model: model))
        // `Me`'s storage comes with the profile.
        var me = Wiretuner_Account_V1_MeResponse()
        var usage = Wiretuner_Account_V1_StorageUsage()
        usage.spaceID = "s"
        usage.usedBytes = 95
        usage.limitBytes = 100
        me.storage = [usage]
        #expect(AccountProfile(me).storage == [StorageUsage(spaceID: "s", usedBytes: 95, limitBytes: 100)])
    }

    // MARK: Storage

    @Test func storageAlmostFullShowsAndAFullWindowRetriesWhenSpaceFrees() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let window = setup.window
        let monitor = StorageMonitor()
        let usage = TestBox([StorageUsage(spaceID: "space", usedBytes: 95, limitBytes: 100)])
        monitor.fetch = { usage.value }
        monitor.windows = { [window] }
        monitor.space = { _ in "space" }
        #expect(await monitor.refresh())
        #expect(window.collaboration.sync.storageNote?.hasPrefix("Storage almost full") == true)
        Render.view(SyncPopoverView(model: window.collaboration.sync))
        let status = try #require(window.syncStatus as? StubSyncStatus)
        status.state = .storageFull(2)
        monitor.windowDidChange(window)
        #expect(monitor.anyWindowFull)
        usage.value = [StorageUsage(spaceID: "space", usedBytes: 50, limitBytes: 100)]
        #expect(await monitor.refresh())
        #expect(status.performed == [.retryNow] && window.collaboration.sync.storageNote == nil)
        // Polling reads again while a window is full and stops when none is.
        monitor.stopPolling()
        monitor.startPolling(interval: .milliseconds(10))
        monitor.startPolling(interval: .milliseconds(10))
        for _ in 0..<200 where status.performed.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        status.state = .saved
        try await Task.sleep(for: .milliseconds(60))
        monitor.stopPolling()
        #expect(status.performed.count >= 2)
        monitor.fetch = { throw CancellationError() }
        #expect(await monitor.refresh() == false)
        monitor.space = { _ in nil }
        #expect(monitor.usage(for: window) == nil)
        #expect(StorageMonitor.note(nil) == nil && StorageMonitor.note(StorageUsage(spaceID: "", usedBytes: 1, limitBytes: 0)) == nil)
        #expect(StorageUsage(spaceID: "", usedBytes: 100, limitBytes: 100).isFull && !StorageUsage(spaceID: "", usedBytes: 1, limitBytes: 0).isFull)
    }

    /// IO-009's rest: the library window's *Storage almost full* banner for the space it shows.
    @Test func theLibraryWindowShowsStorageAlmostFull() async throws {
        let library = LibraryModel(services: FakeLibraryServer().services(), store: nil, thumbnails: ThumbnailCache(directory: nil))
        let monitor = StorageMonitor()
        let space = library.currentSpace.id
        monitor.fetch = { [StorageUsage(spaceID: space, usedBytes: 95, limitBytes: 100), StorageUsage(spaceID: "other", usedBytes: 1, limitBytes: 100)] }
        var read: [StorageUsage] = []
        monitor.onUsage = { read = $0 }
        #expect(await monitor.refresh() && read.count == 2)
        #expect(library.storageBanner == nil)
        library.storageNotes = Dictionary(read.compactMap { item in StorageMonitor.note(item).map { (item.spaceID, $0) } }, uniquingKeysWith: { a, _ in a })
        #expect(library.storageBanner?.hasPrefix("Storage almost full") == true && library.storageNotes["other"] == nil)
        Render.view(LibraryView(model: library))
        library.refreshStorage()
    }

    // MARK: Preview in Browser

    @Test func previewInBrowserPublishesThePageOrTheLinkedDocument() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let document = setup.document
        await document.addRectangles([Rect(x: setup.page.rect.minX + 10, y: setup.page.rect.minY + 10, width: 50, height: 50)])
        let folder = TestStores.directory()
        let exporter = WebPreviewExporter()
        #expect(!WebPreviewExporter.hasInteractions(document))
        let page = try exporter.exportPreview(of: document, pageIndex: 7, into: folder)
        #expect(page.lastPathComponent == "index.html" && FileManager.default.fileExists(atPath: page.path))
        // With a second page and a link, every page goes and the current page's file opens.
        await document.addPage().value
        await document.settle()
        let ids = await document.addRectangles([Rect(x: setup.page.rect.minX + 100, y: setup.page.rect.minY + 10, width: 20, height: 20)])
        _ = await document.perform(SetLink(ids.map(\.opID), url: "https://example.com")).value
        await document.settle()
        #expect(WebPreviewExporter.hasInteractions(document))
        let second = try exporter.exportPreview(of: document, pageIndex: 1, into: folder.appending(path: "two"))
        #expect(["page-2.html", "index.html"].contains(second.lastPathComponent))
        // Through BrowserPreview, the command is enabled and opens the file.
        let preview = BrowserPreview(exporter: exporter, root: folder.appending(path: "preview"))
        var opened: [URL] = []
        preview.open = { url, _ in opened.append(url) }
        #expect(preview.validation(hasDocument: true) == .enabled)
        _ = try preview.preview(document, pageIndex: 0)
        #expect(opened.count == 1)
        preview.cleanUp()
    }

    // MARK: Guides layer and links

    @Test func theGuidesLayerDrivesTheGuidesAndGuideDragsAutoscrollByPreference() async throws {
        let setup = SetupWindow(tools: [PointerTool.descriptor])
        defer { setup.close() }
        let window = setup.window
        GuidesLayer.window = { window }
        defer { GuidesLayer.window = { nil } }
        let layer = try #require(await setup.document.perform(CreateLayer(name: "Guides")).value?.createdNodes.first)
        var role = Wiretuner_Doc_V1_NodeProps()
        role.layer.role = .guides
        _ = await setup.document.perform(OpsCommand("Guides", ops: [Ops.set(layer, [RegisterPath([NodeKind.layer.rawValue, 2])], values: role)])).value
        _ = await setup.document.perform(CreateLayer(name: "Art")).value
        let order = LayerOrder(setup.document.state)
        let guides = try #require(order.layers.first { $0.role == .guides })
        let hide = try #require(GuidesLayer.toggle(.visible, layer: guides))
        #expect(!window.showsGuides)
        _ = await setup.document.perform(hide).value
        let lock = try #require(GuidesLayer.toggle(.locked, layer: guides))
        #expect(lock.label == "Lock guides")
        _ = await setup.document.perform(lock).value
        #expect(setup.document.settings.guidesLocked)
        let locked = try #require(LayerOrder(setup.document.state).layers.first { $0.role == .guides })
        #expect(locked.locked && GuidesLayer.toggle(.locked, layer: locked)?.label == "Unlock guides")
        #expect(GuidesLayer.toggle(.printing, layer: guides) == nil && GuidesLayer.toggle(.keyline, layer: guides) == nil)
        let ordinary = try #require(order.layers.first { $0.role == .ordinary })
        #expect(GuidesLayer.toggle(.visible, layer: ordinary) == nil)
        GuidesLayer.window = { nil }
        #expect(GuidesLayer.toggle(.visible, layer: locked) != nil)
        // The Layers panel's column click goes through the hook.
        let state = LayersPanelState()
        let model = LayersPanelModel(document: setup.document, editing: window.objectEditing, state: state)
        LayerRow.column(model, .locked, locked, 0)(0)
        LayerRow.column(model, .visible, ordinary, 1)(0)
        await setup.document.settle()
        #expect(!setup.document.settings.guidesLocked)
        // Guide drags scroll only with the preference.
        let preferences = setup.environment.preferences
        GuidesLayer.install(on: window, preferences: preferences)
        #expect(window.canvas.autoscrolls())
        #expect(!GuidesLayer.autoscrolls(nil, previous: false, preferences: preferences))
        #expect(GuidesLayer.autoscrolls(window.toolManager, previous: true, preferences: preferences))
        _ = await setup.document.perform(SetGuidesLocked(false)).value
        _ = await setup.document.perform(AddGuides(on: [setup.page.id], axis: .horizontal, at: [100])).value
        await setup.document.settle()
        window.showsGuides = true
        let guidePoint = Point(x: setup.page.rect.midX, y: setup.page.origin.y + 100)
        window.toolManager.mouseDown(setup.event(guidePoint))
        preferences.set(false, for: PreferenceCatalog.General.guideDragScrolls)
        #expect(window.toolManager.handleDrag is GuideHandles && !window.canvas.autoscrolls())
        preferences.set(true, for: PreferenceCatalog.General.guideDragScrolls)
        #expect(window.canvas.autoscrolls())
        window.toolManager.cancel()
    }

    @Test func theLinksBadgeAndTheObjectPanelsLinksButton() async throws {
        let world = try await LinksTests.World.make()
        defer { world.close() }
        let setup = world.setup
        let window = setup.window
        #expect(LinkUploads.status("Embedded", uploading: true) == "Embedded · Uploading" && LinkUploads.status("Linked", uploading: false) == "Linked")
        let previous = (LinkUploads.pending, LinkUploads.showLinks)
        defer { (LinkUploads.pending, LinkUploads.showLinks) = previous }
        let sha = Data(repeating: 7, count: 32)
        LinkUploads.pending = { _ in [ImportedBlob.hex(sha)] }
        #expect(LinkUploads.isUploading(sha, in: window) && !LinkUploads.isUploading(Data(repeating: 1, count: 32), in: window))
        var shown: [OpID] = []
        LinkUploads.showLinks = { shown.append($0) }
        // A placed image names its asset; the section offers Links… for it.
        let asset = world.asset
        #expect(LinkUploads.asset(of: [], in: setup.document.state) == nil)
        #expect(LinkUploads.asset(of: [world.image], in: setup.document.state) == asset)
        let ids = await setup.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        #expect(LinkUploads.asset(of: ids.map(\.opID), in: setup.document.state) == nil)
        #expect(LinkUploads.asset(of: [world.image, ids[0].opID], in: setup.document.state) == nil)
        var file = Wiretuner_Doc_V1_NodeProps()
        file.placedFile.source.id = asset.proto
        let layer = try #require(LayerOrder(setup.document.state).drawingLayer)
        let placed = await setup.document.perform(OpsCommand("Place", ops: [Ops.create(parent: layer, position: [0xA0], props: file)])).value
        let placedFile = try #require(placed?.opIDs.first)
        #expect(LinkUploads.asset(of: [world.image, placedFile], in: setup.document.state) == asset)
        file.placedFile.clearSource()
        let bare = await setup.document.perform(OpsCommand("Place", ops: [Ops.create(parent: layer, position: [0xB0], props: file)])).value
        #expect(LinkUploads.asset(of: [try #require(bare?.opIDs.first)], in: setup.document.state) == nil)
        await setup.document.settle()
        let panel = ObjectPanelModel(document: setup.document, selection: Selection(ids))
        #expect(LinkUploads.section.make(panel) == nil)
        let placedPanel = ObjectPanelModel(document: setup.document, selection: Selection([SelectionID(placedFile)]))
        if !placedPanel.objects.isEmpty { #expect(LinkUploads.section.make(placedPanel) != nil) }
        LinksSectionView.open(asset)()
        #expect(shown == [asset])
        Render.view(LinksSectionView(asset: asset))
        // The Links window's rows carry the badge.
        world.model.isUploading = { _ in true }
        #expect(world.model.rows.first?.status.hasSuffix("Uploading") == true)
    }
}
