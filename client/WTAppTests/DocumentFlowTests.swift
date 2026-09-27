import AppKit
import Foundation
import Testing
import WTCRDT
import WTModel
import WTSync
@testable import WireTuner

/// DOC-020's and DOC-029's UI tests, run in the app host against a whole `AppDelegate` (its menu
/// bar, command registry, library, template gallery and quit sheet) instead of through XCUITest,
/// which this build machine does not run: create, open from Recents, switch tabs by shortcut,
/// close, quit with a pending outbox (creating-opening.adoc); the gallery at launch, a document
/// from each starting point and from a library template (templates.adoc).
@Suite(.serialized) @MainActor struct DocumentFlowTests {
    let server = FakeLibraryServer()
    let suite = TestDefaults()

    func delegate(arguments: [String] = [], connector: FakeSyncConnector? = nil) -> AppDelegate {
        let library = LibraryModel(services: server.services(), store: nil, thumbnails: ThumbnailCache(directory: nil), debounce: .milliseconds(1))
        let stores = TestStores.directory()
        let delegate = AppDelegate(
            layoutStore: nil, defaults: suite.defaults, launchEnvironment: LaunchEnvironment(arguments: arguments), library: library,
            syncConnector: connector, storesDirectory: { stores }
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        return delegate
    }

    func tearDown(_ delegate: AppDelegate) {
        delegate.templates.gallery?.window?.close()
        for id in delegate.documents.documents.map(\.id) { delegate.documents.close(id) }
        delegate.activeSelection.presence = nil
        suite.remove()
    }

    /// The main menu's item for `key` with `modifiers`, alternates included.
    static func menuItem(_ key: String, _ modifiers: NSEvent.ModifierFlags, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.keyEquivalent == key, item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == modifiers { return item }
            if let found = menuItem(key, modifiers, in: item.submenu) { return found }
        }
        return nil
    }

    /// New documents open over an empty model, as a new local store is (a test launch's memory
    /// documents come with the built-in template already in them).
    static func emptyStores(_ delegate: AppDelegate) {
        delegate.documents.environment.openModel = { _ in
            WTModel.Document(memory: DocumentCore(state: EngineState(), replica: UInt64.random(in: 1...UInt64.max)))
        }
    }

    // MARK: DOC-020

    @Test func createOpenFromRecentsSwitchTabsByShortcutAndClose() async throws {
        server.put(LibraryDocument(id: "brochure", spaceID: server.accountID, name: "Brochure"))
        let delegate = delegate()
        defer { tearDown(delegate) }
        await delegate.library.refresh()
        #expect(await eventually { delegate.documents.documents.count == 1 }, "an untitled document at launch")

        // menu:File[New] (Cmd+N) records a library document and opens it in a tab.
        let newItem = try #require(Self.menuItem("n", .command, in: NSApp.mainMenu))
        #expect(CommandMenuTarget.commandID(of: newItem) == StandardCommands.ID.new)
        #expect(delegate.commands.perform(StandardCommands.ID.new))
        #expect(await eventually { delegate.documents.documents.count == 2 })
        let created = try #require(delegate.documents.documents.last)
        #expect(delegate.library.cache.documents[created.id] != nil)

        // Open Recent: open, close, reopen from the menu.
        delegate.library.open([try #require(delegate.library.cache.documents["brochure"])])
        #expect(await eventually { delegate.documents.document(id: "brochure") != nil })
        #expect(delegate.documentMenus.recentDocuments.first?.id == "brochure")
        delegate.documents.close("brochure")
        #expect(delegate.documents.document(id: "brochure") == nil)
        #expect(delegate.commands.command(DocumentMenuFeatures.ID.recent(0))?.title == "Brochure")
        #expect(delegate.commands.perform(DocumentMenuFeatures.ID.recent(0)))
        #expect(await eventually { delegate.documents.document(id: "brochure") != nil })

        // Cmd+Shift+] and Cmd+Shift+[ are Show Next Tab and Show Previous Tab.
        let windows = delegate.documents.allWindowControllers.compactMap(\.window)
        #expect(windows.count == 3)
        let first = try #require(windows.first)
        for window in windows.dropFirst() where window.tabGroup !== first.tabGroup { first.addTabbedWindow(window, ordered: .above) }
        let group = try #require(first.tabGroup)
        group.selectedWindow = first
        // The shortcuts are the active set's alternate keys (not menu items); a key runs the
        // command it is bound to, a responder command on the front window.
        let next = KeyEquivalent("]", [.command, .shift])
        let previous = KeyEquivalent("[", [.command, .shift])
        #expect(delegate.shortcuts.commandIDs(for: next).contains(WindowTabCommands.ID.nextTab))
        #expect(delegate.shortcuts.commandIDs(for: previous).contains(WindowTabCommands.ID.previousTab))
        for (key, expected) in [(next, 1), (next, 2), (previous, 1)] {
            let id = try #require(delegate.shortcuts.commandIDs(for: key).first)
            guard case let .responder(selector)? = delegate.commands.command(id)?.action else { Issue.record("\(id) is a responder command"); continue }
            let front = try #require(group.selectedWindow)
            #expect(front.tryToPerform(Selector(selector), with: nil), "the front window handles \(selector)")
            // AppKit moves the selection only while the app is active (a test host often is not).
            if NSApp.isActive { #expect(group.selectedWindow === group.windows[expected], "\(selector) selects tab \(expected)") }
        }

        // Cmd+W closes the front document's window.
        let close = try #require(Self.menuItem("w", .command, in: NSApp.mainMenu))
        #expect(CommandMenuTarget.commandID(of: close) == StandardCommands.ID.close)
        let front = try #require(group.selectedWindow)
        let before = delegate.documents.documents.count
        front.performClose(close)
        #expect(await eventually { delegate.documents.documents.count == before - 1 })
    }

    @Test func quittingWithAPendingOutboxShowsTheInformationalSheet() async throws {
        let connector = FakeSyncConnector()
        let delegate = delegate(connector: connector)
        defer { tearDown(delegate) }
        #expect(await eventually { delegate.activeDocumentWindow?.session != nil })
        let session = try #require(delegate.activeDocumentWindow?.session)
        #expect(await eventually { session.status.state == .saved })
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow, "nothing waiting")

        session.status.update(.offline(3))
        var replies: [Bool] = []
        delegate.quit.reply = { replies.append($0) }
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
        #expect(delegate.quit.window?.identifier == QuitCoordinator.windowIdentifier && delegate.quit.window?.isVisible == true)
        #expect(delegate.quit.model?.headline == "1 document has changes that haven't reached the cloud yet.")
        delegate.quit.model?.choose(.cancel)
        #expect(replies == [false] && delegate.quit.model == nil)
        session.status.update(.saved)
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
    }

    // MARK: DOC-029

    @Test func theGalleryOpensAtLaunchWhenAsked() async throws {
        let delegate = delegate(arguments: [LaunchEnvironment.uiTestingArgument, LaunchEnvironment.showGalleryArgument])
        defer { tearDown(delegate) }
        #expect(await eventually { delegate.templates.gallery?.window?.isVisible == true })
        #expect(delegate.documents.documents.isEmpty, "the gallery replaces the untitled document")

        let plain = self.delegate(arguments: [LaunchEnvironment.uiTestingArgument])
        #expect(await eventually { plain.documents.documents.count == 1 })
        #expect(plain.templates.gallery == nil)
        for id in plain.documents.documents.map(\.id) { plain.documents.close(id) }
        plain.activeSelection.presence = nil
    }

    @Test func eachStartingPointMakesItsDocumentInOneChange() async throws {
        let delegate = delegate()
        defer { tearDown(delegate) }
        Self.emptyStores(delegate)
        for kind in StartingPoints.Kind.allCases {
            let gallery = delegate.templates.showGallery()
            #expect(gallery.window?.isVisible == true)
            gallery.model.choice = .startingPoint(kind)
            let options = gallery.model.options
            let expected = try StartingPoints.state(for: options)
            let document = try #require(await gallery.model.create(), "\(kind)")
            #expect(gallery.window?.isVisible == false, "the gallery closes")
            #expect(await eventually { delegate.documents.document(id: document.id) != nil }, "\(kind) opens")
            let handle = try #require(delegate.documents.document(id: document.id))
            // The creation change lands once the window has opened the model.
            #expect(await eventually { !SwatchList(handle.state).swatches.isEmpty }, "\(kind) created")
            #expect(PageList(handle.state).pages.count == PageList(expected).pages.count, "\(kind) pages")
            #expect(PageList(handle.state).masters.count == PageList(expected).masters.count, "\(kind) masters")
            #expect(DocumentSettings(handle.state).units == DocumentSettings(expected).units, "\(kind) units")
            #expect(SwatchList(handle.state).swatches.count == SwatchList(expected).swatches.count, "\(kind) swatches")
            #expect(handle.undoTitle == "Undo", "the creation change is not an undo step")
        }
    }

    @Test func aLibraryTemplateMakesACopyOfItsContent() async throws {
        var template = LibraryDocument(id: "letterhead", spaceID: server.accountID, name: "Letterhead")
        template.isTemplate = true
        server.put(template)
        let delegate = delegate()
        defer { tearDown(delegate) }
        await delegate.library.refresh()
        await delegate.library.refreshTemplates()
        var core = try DocumentCreation.newDocument(from: .builtIn, replica: 3)
        _ = try core.perform(AddPages(count: 2), recording: DocumentCore.Recording(limit: 1, now: Date()))
        let state = core.state
        Self.emptyStores(delegate)
        delegate.templates.states = TemplateStates(open: { _ in nil }, isCached: { _ in true }, load: { _ in state })
        let gallery = delegate.templates.showGallery()
        #expect(gallery.model.groups.first?.templates.map(\.id) == ["letterhead"])
        gallery.model.choice = .template("letterhead")
        let document = try #require(await gallery.model.create())
        #expect(await eventually { delegate.documents.document(id: document.id) != nil })
        let handle = try #require(delegate.documents.document(id: document.id))
        #expect(await eventually { PageList(handle.state).pages.count == 3 })
        #expect(Set(PageList(handle.state).pages.map(\.id)).isDisjoint(with: PageList(state).pages.map(\.id)), "fresh ids")
    }
}
