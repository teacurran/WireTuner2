import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// COLLAB-038 in the app (inspect.adoc, "Links to an object"): *Copy Link to Object*, and opening a
/// link -- the document's window, catch-up, the page, the selection, Inspect mode for viewers, the
/// notices, the request page and the offline message.  App-hosted rather than UI tests: they drive
/// the same `DeepLinkFeatures.open` the URL handler calls.
@Suite(.serialized) @MainActor struct DeepLinkFeatureTests {
    /// A document controller with the features wired to it as `installDeepLinks` does, over fakes.
    @MainActor
    final class World {
        let environment = TestEnvironment()
        let documents: DocumentController
        let features = DeepLinkFeatures()
        let entries = Box<[String: LibraryDocument]>([:])
        let messages = Box<[String]>([])
        let panels = Box<[PanelID]>([])
        let threads = Box<[OpID]>([])
        let requests = Box<[RequestAccessModel]>([])
        let online = Box(true)
        var roles: [String: DocumentRole] = [:]
        /// Answers of `caughtUp`, in order (then true).
        var catchUp: [Bool] = []
        /// Runs at each `caughtUp` question.
        var onCatchUp: (@MainActor (DocumentWindowController) async -> Void)?

        init() {
            documents = DocumentController(environment: environment.document)
            let documents = documents
            let environment = environment
            features.pasteboard = NSPasteboard(name: NSPasteboard.Name("DeepLinks-\(UUID().uuidString)"))
            features.pollInterval = .milliseconds(1)
            features.windowFor = { documents.views(of: $0).first }
            features.entry = { [entries] in entries.value[$0] }
            features.hasLocalCopy = { $0 == "local" }
            features.isOnline = { [online] in online.value }
            features.open = { id, name in documents.open(environment.document.makeDocument(id: id, title: name), show: false) }
            features.showLibrary = { [messages] in messages.value.append($0) }
            features.role = { [unowned self] in roles[$0] ?? .owner }
            features.showPanel = { [panels] in panels.value.append($0) }
            features.showThread = { [threads] _, thread in threads.value.append(thread) }
            features.presentRequest = { [requests] in requests.value.append($0) }
            features.caughtUp = { [unowned self] window in
                await onCatchUp?(window)
                return catchUp.isEmpty ? true : catchUp.removeFirst()
            }
            features.install(commands: environment.commands) { documents.activeWindowController }
        }

        func close() {
            for id in documents.documents.map(\.id) { documents.close(id) }
        }

        /// A rectangle in the window's document at `rect`.
        func rectangle(in window: DocumentWindowController, _ rect: Rect = Rect(x: 400, y: 300, width: 50, height: 40)) async -> OpID {
            await window.documentHandle.addRectangles([rect])[0].opID
        }
    }

    @Test func copyLinkToObjectPutsTheFirstSelectedObjectsLinkOnThePasteboard() async throws {
        let world = World()
        defer { world.close() }
        let registry = world.environment.commands
        #expect(registry.command(DeepLinkFeatures.ID.copyLinkToObject)?.validation() == .disabled(DeepLinkFeatures.noDocument))
        let window = try #require(world.features.open("doc-a", "A"))
        world.features.window = { window }
        #expect(registry.command(DeepLinkFeatures.ID.copyLinkToObject)?.validation() == .disabled(DeepLinkFeatures.noSelection))
        #expect(world.features.copyLink() == nil)
        let node = await world.rectangle(in: window)
        window.selection.model.set(Selection([SelectionID(node)]))
        #expect(registry.command(DeepLinkFeatures.ID.copyLinkToObject)?.validation() == .enabled)
        registry.perform(DeepLinkFeatures.ID.copyLinkToObject)
        let expected = "wiretuner://doc/doc-a/node/\(node.counter)-\(node.replica)"
        #expect(world.features.pasteboard.string(forType: .string) == expected)
        #expect(NSURL(from: world.features.pasteboard)?.absoluteString == expected)
        // The context menu names it too, as *Copy Link*.
        #expect(ContextMenuCatalog.commonEntries(multiple: false).contains(.command(DeepLinkFeatures.ID.copyLinkToObject, title: "Copy Link")))
    }

    @Test func aLinkOpensAClosedDocumentAndSelectsTheNodeOnlyAfterCatchUp() async throws {
        let world = World()
        defer { world.close() }
        world.entries.value["doc-b"] = LibraryDocument(id: "doc-b", spaceID: "s", name: "Poster")
        // The node arrives with the changes the Mac is behind by: made on another replica, received
        // while the session catches up.
        var remote = DocumentCore(state: EngineState(), replica: 0x5151)
        let outcome = try #require(try remote.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 30, height: 30), transform: .translation(x: 5000, y: 5000)),
                                                      recording: DocumentCore.Recording(limit: 1, now: Date())))
        let change = try #require(outcome.change)
        let node = try #require(change.createdObjects.first { remote.state.store.kind($0) == NodeKind.rect.rawValue })
        world.catchUp = [false, false, false]
        let seen = Box<[Bool]>([])
        world.onCatchUp = { window in
            if seen.value.isEmpty { _ = await window.documentHandle.receive(change, serverSeq: 1).value }
            seen.value.append(window.selection.selection.isEmpty)
        }
        let link = DeepLink(documentID: "doc-b", target: .node(node))
        #expect(await world.features.opens(link.url)?.value == .landed(.select(node)))
        #expect(seen.value.count == 4 && seen.value.allSatisfy { $0 }, "nothing is selected before the catch-up")
        let window = try #require(world.documents.views(of: "doc-b").first)
        #expect(window.documentHandle.title == "Poster")
        #expect(window.selection.selection.ids.map(\.opID) == [node])
        // Scrolled to the object (centred in the part the dock leaves visible).
        let center = window.canvas.visibleCenter
        #expect(abs(center.x - 5015) < 1 && abs(center.y - 5015) < 1)
        // Open already: it comes forward and lands again.
        window.selection.model.set(Selection())
        #expect(await world.features.open(link) == .landed(.select(node)))
        #expect(!window.selection.selection.isEmpty)
        // A web link and the document alone.
        #expect(await world.features.opens(try #require(DeepLink(documentID: "doc-b").webURL(host: "wiretuner.app")))?.value == .landed(.document))
        #expect(world.features.opens(URL(string: "wiretuner://invite/abc")!) == nil)
    }

    @Test func aDeletedNodePostsTheNoticeAndAMissingOneSaysSo() async throws {
        let world = World()
        defer { world.close() }
        let window = try #require(world.features.open("local", "Local"))
        let node = await world.rectangle(in: window)
        _ = await window.documentHandle.perform(CutObjects([node])).value
        #expect(await world.features.open(DeepLink(documentID: "local", target: .node(node))) == .landed(.deleted(node)))
        #expect(window.statusBar.message.stringValue == DeepLinkFeatures.deletedNotice)
        let unknown = OpID(counter: 999_999, replica: 42)
        #expect(await world.features.open(DeepLink(documentID: "local", target: .node(unknown))) == .landed(.notReceived(unknown)))
        #expect(window.statusBar.message.stringValue == DeepLinkFeatures.notReceivedNotice)
    }

    @Test func aViewerLandsInInspectModeWithTheNodeInThePanel() async throws {
        let world = World()
        defer { world.close() }
        let window = try #require(world.features.open("local", "Local"))
        let inspect = InspectModeController(window: window)
        world.features.inspect = { _ in inspect }
        defer { inspect.leave() }
        let second = try #require(window.documentHandle.pageList.pages.first)
        let node = await world.rectangle(in: window, Rect(x: second.rect.minX + 10, y: second.rect.minY + 10, width: 20, height: 20))
        world.roles["local"] = .viewer
        #expect(await world.features.open(DeepLink(documentID: "local", target: .node(node))) == .landed(.select(node)))
        #expect(inspect.isOn && world.panels.value == [InspectPanel.id])
        #expect(window.selection.selection.ids.map(\.opID) == [node])
        // An editor stays in the ordinary mode.
        inspect.leave()
        world.roles["local"] = .editor
        _ = await world.features.open(DeepLink(documentID: "local", target: .node(node)))
        #expect(!inspect.isOn)
    }

    @Test func aThreadLinkOpensTheThread() async throws {
        let world = World()
        defer { world.close() }
        let window = try #require(world.features.open("local", "Local"))
        let change = await window.documentHandle.perform(CreateThread(at: Point(x: 10, y: 10), author: "a", body: CommentBody("Look"), in: window.documentHandle.state)).value
        let thread = try #require(change?.createdNodes.first)
        #expect(await world.features.open(DeepLink(documentID: "local", target: .thread(thread))) == .landed(.openThread(thread)))
        #expect(world.threads.value == [thread])
    }

    @Test func noAccessShowsTheRequestPageAndOfflineTheLibraryMessage() async throws {
        let world = World()
        defer { world.close() }
        let sent = Box<[(String, String)]>([])
        world.features.requestAccess = { id, message in sent.value.append((id, message)) }
        #expect(await world.features.open(DeepLink(documentID: "secret")) == .requestAccess("secret"))
        let model = try #require(world.requests.value.first)
        #expect(world.features.request === model && model.documentID == "secret" && model.canSend)
        model.message = "Please"
        await model.submit()
        #expect(model.phase == .sent && !model.canSend && sent.value.first?.0 == "secret" && sent.value.first?.1 == "Please")
        // Signed out, or refused.
        let signedOut = RequestAccessModel(documentID: "x", send: nil)
        await signedOut.submit()
        #expect(signedOut.phase == .failed(RequestAccessModel.signedOut) && signedOut.canSend)
        let refused = RequestAccessModel(documentID: "x") { _, _ in throw URLError(.notConnectedToInternet) }
        await refused.submit()
        if case .failed = refused.phase {} else { Issue.record("a refusal is shown") }
        // The page's view and its button.
        let view = RequestAccessView(model: signedOut)
        _ = view.body
        RequestAccessView.submit(signedOut)()
        // Offline without a copy on this Mac; trashed; a window that cannot be made.
        world.online.value = false
        #expect(await world.features.open(DeepLink(documentID: "secret")) == .library(DeepLinkFeatures.offlineMessage("secret")))
        world.entries.value["gone"] = LibraryDocument(id: "gone", spaceID: "s", name: "Gone", isTrashed: true)
        #expect(await world.features.open(DeepLink(documentID: "gone")) == .library(ContinuityOpener.trashedMessage("Gone")))
        world.features.open = { _, _ in nil }
        #expect(await world.features.open(DeepLink(documentID: "local")) == .library(ContinuityOpener.unavailableMessage()))
        #expect(world.messages.value.count == 3)
        // The request page's window.
        DeepLinkFeatures.presentWindow(signedOut)
        let page = try #require(NSApp.windows.first { $0.identifier?.rawValue == DeepLinkFeatures.requestWindow })
        page.close()
    }

    @Test func catchingUpReadsTheSessionAndDefaultsAreInert() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        // A window without a session has nothing to catch up on.
        #expect(await DeepLinkFeatures.caughtUp(setup.window))
        let defaults = DeepLinkFeatures()
        #expect(defaults.window() == nil && defaults.windowFor("x") == nil && defaults.open("x", "y") == nil && defaults.isOnline())
        let entry = await defaults.entry("x")
        let caught = await defaults.caughtUp(setup.window)
        #expect(entry == nil && !defaults.hasLocalCopy(UUID().uuidString) && defaults.role("x") == .owner)
        #expect(defaults.inspect(setup.window) == nil && caught)
        defaults.showLibrary("x")
        defaults.showPanel(InspectPanel.id)
        defaults.showThread(setup.window, OpID(counter: 1, replica: 1))
        // A window closed while waiting stops waiting.
        let world = World()
        defer { world.close() }
        let window = try #require(world.features.open("local", "Local"))
        world.features.caughtUp = { _ in false }
        world.documents.close("local")
        #expect(await world.features.land(DeepLink(documentID: "local", target: .node(OpID(counter: 1, replica: 1))), in: window) == .wait)
    }

    @Test func theAppOpensDeepLinks() async throws {
        let suite = TestDefaults()
        defer { suite.remove() }
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let window = try #require(delegate.activeDocumentWindow)
        defer {
            for controller in delegate.documents.windowControllers.values { controller.close() }
        }
        let links = delegate.deepLinks
        #expect(delegate.commands.command(DeepLinkFeatures.ID.copyLinkToObject) != nil)
        #expect(links.windowFor(window.documentHandle.id) === window && links.role("unknown") == .owner)
        #expect(links.inspect(window) != nil)
        links.showPanel(InspectPanel.id)
        links.showThread(window, OpID(counter: 1, replica: 1))
        _ = await links.entry("unknown")
        _ = links.isOnline()
        await #expect(throws: (any Error).self) { try await links.requestAccess?("doc", "hi") }
        links.showLibrary("A message")
        delegate.libraryWindowController?.close()
        let before = delegate.documents.documents.count
        #expect(links.open(UUID().uuidString, "Linked") != nil && delegate.documents.documents.count == before + 1)
        // The URL handler takes deep links; the link lands in the open window.
        #expect(delegate.open(DeepLink(documentID: window.documentHandle.id).url))
        // It lands before the windows close: the launch document is in the library (D-079), so a
        // link landing after them would open it again.
        let landing = try #require(links.opens(DeepLink(documentID: window.documentHandle.id).url))
        if case .landed = await landing.value {} else { Issue.record("the link did not land in the open window") }
    }
}
