import AppKit
import Foundation
import SwiftUI
import Testing
import WTGeometry
import WTModel
import WTRender
import WTSync
@testable import WireTuner

/// Local mode (D-079; saving.adoc, "Using WireTuner without an account"): which builds run it, what
/// a launch in it shows -- no sign-in, no cloud state, no quit sheet -- and the server features it
/// disables with the reason.
@Suite(.serialized) @MainActor struct LocalModeTests {
    let server = FakeLibraryServer()
    let suite = TestDefaults()

    func delegate(localMode: LocalMode, connector: FakeSyncConnector? = FakeSyncConnector(), stores: URL = TestStores.directory()) -> AppDelegate {
        let library = LibraryModel(services: server.services(signedIn: false), store: nil, thumbnails: ThumbnailCache(directory: nil),
                                   debounce: .milliseconds(1))
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults, library: library, syncConnector: connector,
                                   storesDirectory: { stores }, localMode: localMode)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        return delegate
    }

    func tearDown(_ delegate: AppDelegate) {
        delegate.accountWindowController?.window?.close()
        for id in delegate.documents.documents.map(\.id) { delegate.documents.close(id) }
        delegate.activeSelection.presence = nil
        suite.remove()
    }

    // MARK: Which builds

    @Test func theBuildDecidesAndTheChoiceIsKept() {
        let server = [AuthConfiguration.apiInfoKey: "http://localhost:8080", AuthConfiguration.issuerInfoKey: "http://localhost:8180/realms/wiretuner"]
        #expect(!LocalMode.isLocalBuild(server))
        #expect(!LocalMode.isLocalBuild(server.merging([LocalMode.infoKey: "NO"]) { $1 }))
        #expect(LocalMode.isLocalBuild(server.merging([LocalMode.infoKey: "YES"]) { $1 }))
        #expect(LocalMode.isLocalBuild((server as [String: Any]).merging([LocalMode.infoKey: true]) { $1 }))
        #expect(!LocalMode.isLocalBuild((server as [String: Any]).merging([LocalMode.infoKey: false]) { $1 }))
        #expect(LocalMode.isLocalBuild(server.merging([AuthConfiguration.apiInfoKey: ""]) { $1 }), "an empty endpoint")
        #expect(LocalMode.isLocalBuild(server.merging([AuthConfiguration.issuerInfoKey: "$(WT_AUTH_ISSUER)"]) { $1 }), "unexpanded")
        #expect(LocalMode.isLocalBuild([AuthConfiguration.issuerInfoKey: "http://localhost:8180"]), "no API")
        #expect(LocalMode.isLocalBuild(nil))
        // The app under test is a Debug build: it has a server.
        #expect(!LocalMode.isLocalBuild(Bundle.main.infoDictionary))

        let build = LocalMode(isLocalBuild: true)
        #expect(build.isActive && !build.offersSignIn)
        build.isSignedIn = { true }
        #expect(build.isActive, "a Local mode build stays local whatever the account")

        let signedIn = TestBox(false)
        let chosen = LocalMode(infoDictionary: server, defaults: suite.defaults)
        chosen.isSignedIn = { signedIn.value }
        #expect(!chosen.isActive && chosen.offersSignIn)
        var heard: [Bool] = []
        let token = chosen.observe { heard.append($0) }
        chosen.useWithoutAccount()
        chosen.useWithoutAccount()
        #expect(chosen.isActive && heard == [true])
        #expect(LocalMode(isLocalBuild: false, defaults: suite.defaults).usesWithoutAccount, "remembered across launches")
        signedIn.value = true
        chosen.accountDidChange()
        chosen.accountDidChange()
        #expect(!chosen.isActive && heard == [true, false])
        signedIn.value = false
        chosen.accountDidChange()
        #expect(heard == [true, false, true])
        chosen.stopObserving(token)
        signedIn.value = true
        chosen.accountDidChange()
        #expect(heard.count == 3)
    }

    @Test func theGateDisablesServerCommandsWithTheReason() throws {
        let mode = LocalMode(isLocalBuild: false)
        #expect(mode.gate("file.share") == nil, "not in Local mode")
        mode.useWithoutAccount()
        for id in ServerFeatures.commands { #expect(mode.gate(id) == .disabled(LocalMode.needsAccount)) }
        #expect(mode.gate(LocalCopyRemoval.id) == .disabled(LocalMode.onlyCopy))
        #expect(mode.gate(StandardCommands.ID.saveVersion) == nil && mode.gate(ImportCommands.ID.saveCopy) == nil)

        let registry = CommandRegistry()
        try registry.register(Command(id: "file.share", title: "Share…", action: .perform {}))
        registry.replace(Command(id: "file.branch.new", title: "New Branch…", validation: { .disabled("own") }, action: .perform {}))
        _ = registry.registerIfAbsent(Command(id: "edit.other", title: "Other", action: .perform {}))
        #expect(registry.validate("file.share") == .enabled && registry.validate("file.branch.new") == .disabled("own"))
        registry.gate = { mode.gate($0) }
        #expect(registry.validate("file.share") == .disabled(LocalMode.needsAccount))
        #expect(registry.validate("file.branch.new") == .disabled(LocalMode.needsAccount))
        #expect(registry.validate("edit.other") == .enabled)
        #expect(!registry.perform("file.share"))
    }

    // MARK: A launch in Local mode

    @Test func aLocalLaunchShowsNoSignInSyncOrQuitSheet() async throws {
        // A store with a change waiting, as an earlier launch could leave: nothing uploads it.
        let stores = TestStores.directory()
        let waiting = try await LocalStore.open(documentID: "waiting", at: stores.appending(components: "waiting", "store.sqlite"))
        let model = await WTModel.Document(backend: waiting)
        _ = try await model.perform(CreateShape(.ellipse, size: Size(width: 5, height: 5), transform: .identity, appearance: Appearances.standard))
        await model.settle()
        try await waiting.close()

        let connector = FakeSyncConnector()
        let delegate = delegate(localMode: LocalMode(isLocalBuild: true), connector: connector, stores: stores)
        defer { tearDown(delegate) }
        #expect(await eventually { delegate.activeDocumentWindow != nil })
        let window = try #require(delegate.activeDocumentWindow)
        let session = try #require(window.session)
        #expect(await eventually { session.status.state == .localOnly })
        #expect(window.window?.subtitle == "On this Mac")
        #expect(window.collaboration.sync.state == .localOnly && !SyncState.localOnly.needsAttention)
        #expect(window.collaboration.sync.explanation == SyncIndicatorModel.localExplanation)
        #expect(window.collaboration.sync.lastSyncedText() == SyncIndicatorModel.localText)
        #expect(SyncState.localOnly.symbolName == "internaldrive" && SyncState.localOnly.actions.isEmpty)
        #expect(connector.connections == 0 && delegate.sessions.headless.isEmpty)

        // No sign-in anywhere; nothing waits at quit.
        #expect(!delegate.commands.contains(AccountCommands.ID.signIn) && !delegate.commands.contains(AccountCommands.ID.showAccount))
        #expect(!delegate.sessions.waitingDocuments.contains { $0.state == .needsSignIn })
        await window.documentHandle.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        #expect(delegate.sessions.waitingDocuments.isEmpty)
        #expect(delegate.quit.shouldTerminate() == .terminateNow && delegate.quit.window == nil)

        // The library reads On this Mac and asks the server for nothing.
        await delegate.library.refresh()
        #expect(delegate.library.connectionNote?.title == LibraryModel.onThisMac && delegate.library.isOnline)
        #expect(server.calls.isEmpty)

        // Server features say why; the rest of the File menu works.
        for id: CommandID in ["file.share", "file.branch.new", "file.reviewMerge", "file.restoreVersion", "object.addComment", "file.makeTeamColorLibrary"] {
            if delegate.commands.contains(id) { #expect(delegate.commands.validate(id) == .disabled(LocalMode.needsAccount), "\(id)") }
        }
        #expect(delegate.commands.contains("file.share"))
        #expect(delegate.commands.validate(ImportCommands.ID.saveCopy) == .enabled)
        #expect(delegate.commands.validate(StandardCommands.ID.saveVersion) == .enabled)
        #expect(delegate.commands.validate(LocalCopyRemoval.id)?.isEnabled == false)
        #expect(delegate.commands.command(ImportCommands.ID.saveCopy)?.menuPath?.menu == StandardCommands.Menu.file)
        #expect(delegate.commands.command(ImportCommands.ID.exportPackage)?.menuPath == nil, "the old name stays in the palette only")
        // The Comment tool is refused from the Tools panel with the reason; others select.
        delegate.toolPalette.select(CommentTool.id)
        #expect(window.toolManager.activeToolID != CommentTool.id)
        delegate.toolPalette.select(.pointer)
        #expect(window.toolManager.activeToolID == .pointer)
        // A version saved on this Mac says so.
        let pending = PendingVersion(id: "v", name: "V", note: "", createdAt: Date(), serverSeq: 0)
        #expect(VersionFeatures.message(for: .pending(pending), name: "V", isLocal: true) == "Saved version “V” on this Mac")
        #expect(delegate.versions.isLocal() && delegate.dataMerge.isLocal())
        // The popover's Save a Copy As… reaches the command (the save panel is not run).
        delegate.packages.runSavePanel = { _, _ in nil }
        delegate.sessions.onExportPackage()
    }

    @Test func theLaunchDocumentIsInTheLibrary() async throws {
        for local in [true, false] {
            let delegate = delegate(localMode: LocalMode(isLocalBuild: local), connector: nil)
            #expect(await eventually { delegate.activeDocumentWindow != nil })
            let handle = try #require(delegate.activeDocumentWindow?.documentHandle)
            let entry = try #require(delegate.library.cache.documents[handle.id], "local: \(local)")
            #expect(entry.name == LibraryModel.untitled && entry.isPendingUpload)
            #expect(delegate.library.cache.recents.first?.documentID == handle.id)
            #expect(handle.id.count == 36 && Array(handle.id)[14] == "7", "a UUIDv7")
            // Renamed and trashed like any other.
            await delegate.library.rename(handle.id, to: "Launch")
            #expect(delegate.library.cache.documents[handle.id]?.name == "Launch")
            if local {
                await delegate.library.trash(handle.id)
                #expect(delegate.library.cache.documents[handle.id]?.isTrashed == true)
            }
            tearDown(delegate)
        }
    }

    @Test func aBuildWithAServerTurnsLocalAndBack() async throws {
        let mode = LocalMode(isLocalBuild: false, defaults: suite.defaults)
        let connector = FakeSyncConnector()
        let delegate = delegate(localMode: mode, connector: connector)
        defer { tearDown(delegate) }
        #expect(delegate.commands.contains(AccountCommands.ID.signIn), "sign-in is offered")
        #expect(delegate.commands.validate("file.share") != .disabled(LocalMode.needsAccount))
        #expect(await eventually { delegate.activeDocumentWindow?.session != nil })
        let session = try #require(delegate.activeDocumentWindow?.session)
        #expect(await eventually { session.status.state == .saved })

        // *Use Without an Account* from the popover of *Sign in to sync*.
        #expect(SyncState.needsSignIn.actions == [.signIn, .useWithoutAccount])
        session.perform(.useWithoutAccount)
        #expect(mode.isActive)
        #expect(await eventually { session.status.state == .localOnly })
        #expect(delegate.commands.validate("file.share") == .disabled(LocalMode.needsAccount))
        #expect(delegate.library.isLocal())

        // Signing in ends it: the session is back to its client.
        delegate.account.apply(.signedIn(TokenClaims(subject: "s", email: "p@example.com")))
        #expect(!mode.isActive)
        #expect(await eventually { session.status.state == .saved })
        await delegate.localModeChange?.value
        // Signing out returns to it.
        delegate.account.apply(.signedOut)
        #expect(mode.isActive)
        #expect(await eventually { session.status.state == .localOnly })
    }

    @Test func theAccountWindowOffersLocalMode() {
        let mode = LocalMode(isLocalBuild: false, defaults: suite.defaults)
        let model = AccountModel(auth: AuthService(configuration: AuthConfiguration(), store: InMemoryTokenStore(), authenticator: WebAuthenticationSession()),
                                 client: server)
        let offer = NSHostingView(rootView: AccountView(model: model, localMode: mode))
        offer.frame = NSRect(x: 0, y: 0, width: 420, height: 460)
        offer.layoutSubtreeIfNeeded()
        mode.useWithoutAccount()
        let note = NSHostingView(rootView: AccountView(model: model, localMode: mode))
        note.frame = offer.frame
        note.layoutSubtreeIfNeeded()
        #expect(mode.usesWithoutAccount && !AccountView.localOffer.isEmpty && !AccountView.localNote.isEmpty)
        let controller = AccountWindowController(model: model, localMode: mode)
        #expect(controller.window?.contentView != nil)
        controller.window?.close()
    }

    @Test func webLinksAndWebSourcesSayAnAccountIsNeeded() async throws {
        let services = AppWebLinkServices(sessions: DocumentSessions(connector: nil), isReachable: { false }, token: { "t" },
                                          makeTransport: { throw SyncCallError(code: SyncCallError.unavailable, message: "none") })
        #expect(services.unavailableReason == WebLinks.needsConnection)
        services.isLocal = { true }
        #expect(services.unavailableReason == LocalMode.needsAccount)

        let world = DataWorld()
        defer { world.close() }
        world.features.isLocal = { true }
        let model = DataPanelModel(features: world.features, window: world.window, session: world.session)
        #expect(model.refusal(.web) == LocalMode.needsAccount && model.refusal(.pasted) == nil)
        #expect(model.title(.web) == "Web API… (Needs a WireTuner account)" && model.title(.json) == "JSON File…")
        model.connect(.web)
        #expect(world.window.window?.attachedSheet == nil, "nothing opens")
    }
}
