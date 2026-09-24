import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTRender
@testable import WireTuner

@Suite @MainActor struct TitleAndPasteboardTests {
    @Test func theSubtitleCarriesTheSyncState() {
        #expect(DocumentTitle.subtitle(for: .saved) == "Saved to cloud")
        #expect(DocumentTitle.subtitle(for: .syncing(3)) == "Syncing 3 changes")
        #expect(DocumentTitle.subtitle(for: .offline(12)) == "Offline — 12 changes waiting")
        #expect(DocumentTitle.subtitle(for: .needsReview) == "Needs review")
        let states: [SyncState] = [.opening, .saved, .syncing(1), .uploadingBlobs(2), .offline(0), .uploadingBacklog(42), .needsReview,
                                   .readOnly(.role), .needsSignIn, .storageFull(2), .error("x")]
        for state in states {
            #expect(NSImage(systemSymbolName: state.symbolName, accessibilityDescription: nil) != nil)
            #expect(!state.label.isEmpty)
        }

        let environment = TestEnvironment()
        let status = StubSyncStatus()
        var document = environment.document
        document.makeSyncStatus = { _ in status }
        let controller = DocumentWindowController(document: .memory(title: "Poster"), environment: document)
        defer { controller.close() }
        #expect(controller.window?.title == "Poster" && controller.window?.subtitle == "Saved to cloud")
        status.state = .syncing(2)
        #expect(controller.window?.title == "Poster" && controller.window?.subtitle == "Syncing 2 changes")
        status.state = .offline(12)
        #expect(controller.window?.subtitle == "Offline — 12 changes waiting")
        #expect(controller.statusBar.model.syncState == .offline(12))
        #expect(controller.collaboration.sync.state == .offline(12))
        status.state = .needsReview
        controller.documentHandle.title = "Flyer"
        #expect(controller.window?.title == "Flyer" && controller.window?.subtitle == "Needs review")
        status.details = SyncDetails(lastSynced: Date(), collaborators: ["Priya"])
        #expect(controller.collaboration.sync.details.collaborators == ["Priya"])
        let token = status.observe {}
        status.stopObserving(token)
        status.perform(.retryNow)
        #expect(status.performed == [.retryNow])
    }

    @Test func pagesStayOnThePasteboard() {
        let side = Pasteboard.side
        #expect(Pasteboard.clamp(Rect(x: -50, y: side, width: 100, height: 100)) == Rect(x: 0, y: side - 100, width: 100, height: 100))
        #expect(Pasteboard.clamp(Rect(x: 10, y: 10, width: side * 2, height: 10)).minX == 0)
    }
}

@Suite @MainActor struct StatusBarTests {
    private func window(_ environment: TestEnvironment = TestEnvironment()) -> DocumentWindowController {
        DocumentWindowController(document: .memory(title: "Pages"), environment: environment.document)
    }

    @Test func addPageAndThePageSelector() async {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        let bar = controller.statusBar
        let document = controller.documentHandle
        #expect(bar.pageField.stringValue == "1" && !bar.previousPage.isEnabled && !bar.nextPage.isEnabled)
        #expect(document.changeCount == 0, "a new document's page is not content")
        var beeps = 0
        controller.beep = { beeps += 1 }

        await controller.addPage().value
        #expect(document.pages.count == 2 && document.currentPageIndex == 1)
        #expect(bar.pageField.stringValue == "2" && bar.previousPage.isEnabled && !bar.nextPage.isEnabled)
        #expect(document.changeCount == 1 && document.undoTitle == "Undo Add page")
        #expect(bar.pageField.numberOfItems == 2 && bar.pageField.itemObjectValue(at: 1) as? String == "Page 2")
        #expect(document.pages[1].minX == document.pages[0].maxX + AddPages.gap, "to the right of the rightmost page, one inch apart")
        let viewport = controller.viewport
        #expect(viewport.toView(document.pages[1].center).isApproximatelyEqual(to: viewport.viewCenter, tolerance: 1e-6))

        bar.previousPageClicked(nil)
        #expect(document.currentPageIndex == 0)
        bar.nextPageClicked(nil)
        #expect(document.currentPageIndex == 1)
        bar.pageField.stringValue = "1"
        bar.pageEntered(bar.pageField)
        #expect(document.currentPageIndex == 0)
        bar.pageField.stringValue = "page 2"
        bar.pageEntered(bar.pageField)
        #expect(document.currentPageIndex == 1)
        bar.pageField.stringValue = "9"
        bar.pageEntered(bar.pageField)
        #expect(beeps == 1 && document.currentPageIndex == 1 && bar.pageField.stringValue == "2")
        bar.pageField.selectItem(at: 0)
        bar.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: bar.pageField))
        #expect(document.currentPageIndex == 0)
        bar.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification))

        // Option-click on an arrow goes to the last or first page.
        await controller.addPage().value
        document.selectPage(0)
        bar.optionDown = { true }
        bar.nextPageClicked(nil)
        #expect(document.currentPageIndex == 2)
        bar.previousPageClicked(nil)
        #expect(document.currentPageIndex == 0)
        bar.optionDown = { false }

        // A named page is listed and found by its name.
        _ = await document.perform(RenamePage(document.pageList.pages[1].id, to: "Cover")).value
        #expect(bar.pageField.itemObjectValue(at: 1) as? String == "Cover")
        bar.pageField.stringValue = "cover"
        bar.pageEntered(bar.pageField)
        #expect(document.currentPageIndex == 1)

        // The status bar's button adds a page too.
        bar.addPageClicked(nil)
        await document.settle()
        #expect(document.pages.count == 4)

        #expect(PageSelection.parse("0", pageCount: 2) == nil)
        #expect(PageSelection.parse("x", pageCount: 2) == nil)
        #expect(PageSelection.parse("Back", pageCount: 2, names: ["", "Back"]) == 1)
        #expect(PageSelection.name(of: 4) == "Page 5" && PageSelection.name(of: 0, label: "Cover") == "Cover")
    }

    @Test func aRemotelyDeletedCurrentPageMovesToTheNearest() async {
        let controller = window()
        defer { controller.close() }
        let document = controller.documentHandle
        await document.addPage().value
        await document.addPage().value
        #expect(document.pages.count == 3 && document.currentPageIndex == 2)
        await document.receiveRemote(RemovePages([document.pageList.pages[2].id]))
        #expect(document.currentPageIndex == 1 && controller.statusBar.pageField.stringValue == "2")
        document.selectPage(0)
        await document.receiveRemote(RemovePages([document.pageList.pages[0].id]))
        #expect(document.currentPageIndex == 0 && document.pages.count == 1)
        // Every page removed on two sides: the document reads as one Letter page at the origin.
        await document.receiveRemote(OpsCommand("Remove", ops: [Ops.setDeleted(document.pageList.pages[0].id)]))
        #expect(document.pageList.isSynthesized && document.currentPage == Rect(x: 0, y: 0, width: 612, height: 792))
        await document.addPage().value
        #expect(document.pages.count == 2 && !document.pageList.isSynthesized, "the next command writes the page")
        // Replacing the pages keeps their objects where they are.
        document.pages = [Rect(x: 10, y: 10, width: 100, height: 200)]
        await document.settle()
        #expect(document.pages == [Rect(x: 10, y: 10, width: 100, height: 200)])
        document.pages = []
        await document.settle()
        #expect(document.pageList.isSynthesized)
        document.selectPage(id: OpID(counter: 999, replica: 9))
        #expect(document.currentPageIndex == 0)
    }

    @Test func unitsWriteOneChangeAndFollowOthers() async {
        let controller = window()
        defer { controller.close() }
        let document = controller.documentHandle
        let bar = controller.statusBar
        #expect(bar.units.titleOfSelectedItem == "Points")
        bar.units.selectItem(withTitle: "Millimeters")
        bar.unitsChosen(bar.units)
        await document.settle()
        #expect(document.units == .millimeters && document.undoTitle == "Undo Change units")
        #expect(document.setUnits(.millimeters) == nil, "choosing the same unit writes nothing")
        #expect(document.changeCount == 1)

        // A remote change updates the pop-up without taking focus from a field being edited.
        controller.window?.makeFirstResponder(bar.magnification)
        let focused = controller.window?.firstResponder
        await document.receiveRemote(SetUnits(.picas))
        #expect(bar.units.titleOfSelectedItem == "Picas")
        #expect(controller.window?.firstResponder === focused)
        #expect(bar.units.numberOfItems == LengthUnit.standard.count)

        // Custom units join the pop-up by name.
        await document.receiveRemote(AddCustomUnit(name: "ft", amount: 12, base: .inches))
        let feet = document.settings.customUnits[0]
        #expect(bar.units.itemTitles.last == "ft")
        bar.units.selectItem(withTitle: "ft")
        bar.unitsChosen(bar.units)
        await document.settle()
        #expect(document.units == .custom(feet.id) && bar.units.titleOfSelectedItem == "ft")
    }

    @Test func twoClientsSettingUnitsConverge() async {
        let a = DocumentHandle.memory(title: "A")
        let base = a.state
        let fromA = await a.perform(SetUnits(.inches)).value
        var other = DocumentCore(state: base, replica: 0xB)
        let fromB = try? other.perform(SetUnits(.centimeters), recording: DocumentCore.Recording(limit: 1, now: Date()))?.change
        if let fromB { _ = await a.receive(fromB).value }
        await a.settle()
        #expect(fromA != nil && fromB != nil)
        // Later OpId wins: both replicas agree on one of the two.
        var check = DocumentCore(state: base, replica: 0xC)
        if let fromA { check.receive(fromA, serverSeq: 1) }
        if let fromB { check.receive(fromB, serverSeq: 2) }
        #expect(DocumentSettings(check.state).units == a.units)
    }

    @Test func magnificationListsPresetsFitsThenNamedViews() {
        let controller = window()
        defer { controller.close() }
        let bar = controller.statusBar
        bar.show(namedViews: ["Logo", "Detail"])
        let items = bar.magnificationItems
        #expect(Array(items.suffix(5)) == ["Fit Selection", "Fit to Page", "Fit All", "Logo", "Detail"])
        #expect(Array(items.prefix(MagnificationFormat.presetTitles.count)) == MagnificationFormat.presetTitles)
        #expect(bar.magnification.numberOfItems == items.count)
        var beeps = 0
        controller.beep = { beeps += 1 }
        controller.enterMagnification("4x")
        #expect(controller.viewport.zoom == 4)
        controller.enterMagnification("0")
        controller.enterMagnification("99999")
        #expect(beeps == 2 && controller.viewport.zoom == Viewport.zoomRange.upperBound)
    }

    @Test func syncIndicatorAndAvatarsHaveHosts() {
        let environment = TestEnvironment()
        let presence = StubPresenceModel()
        var document = environment.document
        document.makePresence = { _ in presence }
        let controller = DocumentWindowController(document: .memory(title: "Busy"), environment: document)
        defer { controller.close() }
        #expect(controller.window?.tab.accessoryView == nil)
        presence.participants = [RemoteParticipant(id: "p1", name: "Priya Shah", colorIndex: 0), RemoteParticipant(id: "p2", name: "Sam", colorIndex: 3)]
        let dots = controller.window?.tab.accessoryView as? TabPresenceDotsView
        #expect(dots?.colors.count == 2)
        #expect(dots?.intrinsicContentSize.width == 2 * (TabPresenceDotsView.dotSize + 2))
        dots?.display()
        #expect(controller.collaboration.avatars.participants.map(\.id) == ["p1", "p2"])
        #expect(AvatarStripModel.initials("Priya Shah") == "PS" && AvatarStripModel.initials("sam") == "S")
        for view in [NSHostingView(rootView: AvatarStripView(model: controller.collaboration.avatars)) as NSView, NSHostingView(rootView: SyncIndicatorView(model: controller.statusBar.model))] {
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.width > 0)
        }
        controller.statusBar.show(sync: .needsReview)
        let review = NSHostingView(rootView: SyncIndicatorView(model: controller.statusBar.model))
        review.layoutSubtreeIfNeeded()
        presence.participants = []
        #expect(controller.window?.tab.accessoryView == nil)
    }
}

@Suite(.serialized) @MainActor struct WindowTabbingTests {
    @Test func tabCommandsAreTheWindowsOwn() {
        let registry = CommandRegistry()
        WindowTabCommands.install(into: registry)
        #expect(registry.command(WindowTabCommands.ID.nextTab)?.defaultKey == KeyEquivalent("tab", .control))
        #expect(registry.command(WindowTabCommands.ID.previousTab)?.defaultKey == KeyEquivalent("tab", [.control, .shift]))
        #expect(registry.command(WindowTabCommands.ID.showTabBar)?.action.responderSelectorName == "toggleTabBar:")
        #expect(registry.command(WindowTabCommands.ID.mergeAllWindows)?.action.responderSelectorName == "mergeAllWindows:")
        #expect(registry.command(WindowTabCommands.ID.moveTabToNewWindow)?.menuPath?.menu == "Window")
    }

    @Test func threeDocumentsAreThreeTabsAndTheSessionComesBack() throws {
        let environment = TestEnvironment()
        let controller = DocumentController(environment: environment.document)
        let a = controller.open(.memory(id: "a", title: "A"))
        let b = controller.open(.memory(id: "b", title: "B"))
        let c = controller.open(.memory(id: "c", title: "C"))
        #expect(a.window?.tabbedWindows?.count == 3)
        let session = controller.sessionState()
        #expect(session.map(\.documentID) == ["a", "b", "c"])
        #expect(Set(session.map(\.tabGroup)) == [0])
        #expect(session.map(\.tabIndex) == [0, 1, 2])
        #expect(session.filter(\.key).map(\.documentID) == ["c"])

        // A tab dragged out is a window of its own; merging brings the order back.
        c.window?.moveTabToNewWindow(nil)
        let split = controller.sessionState()
        #expect(Set(split.map(\.tabGroup)).count == 2)
        a.window?.mergeAllWindows(nil)
        #expect(a.window?.tabbedWindows?.count == 3)

        let store = SessionStore(url: TestEnvironment.temporaryDirectory().appending(path: SessionStore.fileName))
        #expect(store.load().isEmpty)
        try store.save(split)
        #expect(store.load() == split)
        for id in ["a", "b", "c"] { controller.close(id) }
        _ = b

        let relaunched = DocumentController(environment: environment.document)
        let reopened = relaunched.restore(store.load()) { $0 != "b" }
        #expect(reopened.map(\.documentHandle.id) == ["a", "c"], "a trashed document is skipped")
        #expect(relaunched.activeDocumentID == "c")
        #expect(reopened[0].window?.tabbedWindows == nil || reopened[0].window?.tabbedWindows?.count == 1)
        for id in ["a", "c"] { relaunched.close(id) }
        #expect(SessionStore.defaultURL.lastPathComponent == "Session.json")

        let garbage = SessionStore(url: TestEnvironment.temporaryDirectory().appending(path: "x.json"))
        try FileManager.default.createDirectory(at: garbage.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: garbage.url)
        #expect(garbage.load().isEmpty)
    }

    @Test func theAppRestoresItsSessionWhenAsked() throws {
        let suite = TestDefaults()
        let url = TestEnvironment.temporaryDirectory().appending(path: SessionStore.fileName)
        let store = SessionStore(url: url)
        try store.save([
            WindowState(documentID: "x", title: "X", frame: LayoutRect(x: 100, y: 100, width: 900, height: 700), tabGroup: 0, tabIndex: 0, key: false),
            WindowState(documentID: "y", title: "Y", frame: nil, tabGroup: 0, tabIndex: 1, key: true),
        ])
        let environment = LaunchEnvironment(arguments: [LaunchEnvironment.restoreSessionArgument], environment: ["XCTestConfigurationFilePath": "x"])
        #expect(environment.restoresSession)
        #expect(!LaunchEnvironment(arguments: [], environment: ["XCTestConfigurationFilePath": "x"]).restoresSession)
        #expect(LaunchEnvironment(arguments: [], environment: [:]).restoresSession)
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults, launchEnvironment: environment, sessionStore: store)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(delegate.documents.documents.map(\.id) == ["x", "y"])
        #expect(delegate.documents.activeDocumentID == "y")
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(store.load().map(\.documentID) == ["x", "y"])
        for id in ["x", "y"] { delegate.documents.close(id) }
        suite.remove()
    }
}
