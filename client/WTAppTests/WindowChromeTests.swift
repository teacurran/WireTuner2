import AppKit
import SwiftUI
import Testing
import WTGeometry
import WTRender
@testable import WireTuner

@Suite @MainActor struct TitleAndPasteboardTests {
    @Test func theTitleCarriesTheSyncState() {
        #expect(DocumentTitle.format(name: "Poster", state: .synced) == "Poster")
        #expect(DocumentTitle.format(name: "Poster", state: .syncing) == "Poster — Syncing")
        #expect(DocumentTitle.format(name: "Poster", state: .offline(waiting: 12)) == "Poster — Offline (12 changes waiting)")
        #expect(DocumentTitle.format(name: "Poster", state: .offline(waiting: 1)) == "Poster — Offline (1 change waiting)")
        #expect(DocumentTitle.format(name: "Poster", state: .reviewNeeded) == "Poster — Review needed")
        for state in [SyncState.synced, .syncing, .offline(waiting: 2), .reviewNeeded] {
            #expect(NSImage(systemSymbolName: state.symbolName, accessibilityDescription: nil) != nil)
            #expect(!state.label.isEmpty)
        }

        let environment = TestEnvironment()
        let status = StubSyncStatus()
        var document = environment.document
        document.makeSyncStatus = { _ in status }
        let controller = DocumentWindowController(document: .memory(title: "Poster"), environment: document)
        defer { controller.close() }
        #expect(controller.window?.title == "Poster")
        status.state = .syncing
        #expect(controller.window?.title == "Poster — Syncing")
        status.state = .offline(waiting: 12)
        #expect(controller.window?.title == "Poster — Offline (12 changes waiting)")
        #expect(controller.statusBar.model.syncState == .offline(waiting: 12))
        status.state = .reviewNeeded
        #expect(controller.window?.title == "Poster — Review needed")
        controller.documentHandle.title = "Flyer"
        #expect(controller.window?.title == "Flyer — Review needed")
        let token = status.observe {}
        status.stopObserving(token)
    }

    @Test func pagesStayOnThePasteboard() {
        let side = Pasteboard.side
        #expect(Pasteboard.clamp(Rect(x: -50, y: side, width: 100, height: 100)) == Rect(x: 0, y: side - 100, width: 100, height: 100))
        #expect(Pasteboard.clamp(Rect(x: 10, y: 10, width: side * 2, height: 10)).minX == 0)
        let first = Pasteboard.letterPage
        let second = Pasteboard.placement(after: first, among: [first])
        #expect(second.minX == first.maxX + Pasteboard.pageGap && second.minY == first.minY && second.width == first.width && second.height == first.height)
        let edge = Rect(x: side - 700, y: 100, width: 612, height: 792)
        let wrapped = Pasteboard.placement(after: edge, among: [edge])
        #expect(wrapped.minY == edge.maxY + Pasteboard.pageGap && wrapped.minX == edge.minX)
        #expect(Pasteboard.placement(after: first, among: []).minX == first.maxX + Pasteboard.pageGap)
    }
}

@Suite @MainActor struct StatusBarTests {
    private func window(_ environment: TestEnvironment = TestEnvironment()) -> DocumentWindowController {
        DocumentWindowController(document: .memory(title: "Pages"), environment: environment.document)
    }

    @Test func addPageAndThePageSelector() {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        let bar = controller.statusBar
        let document = controller.documentHandle
        #expect(bar.pageField.stringValue == "1" && !bar.previousPage.isEnabled && !bar.nextPage.isEnabled)
        var beeps = 0
        controller.beep = { beeps += 1 }

        bar.addPageClicked(nil)
        #expect(document.pages.count == 2 && document.currentPageIndex == 1)
        #expect(bar.pageField.stringValue == "2" && bar.previousPage.isEnabled && !bar.nextPage.isEnabled)
        #expect(document.changeCount == 1)
        #expect(bar.pageField.numberOfItems == 2 && bar.pageField.itemObjectValue(at: 1) as? String == "Page 2")
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

        #expect(PageSelection.parse("0", pageCount: 2) == nil)
        #expect(PageSelection.parse("x", pageCount: 2) == nil)
        #expect(PageSelection.name(of: 4) == "Page 5")
    }

    @Test func aRemotelyDeletedCurrentPageMovesToTheNearest() {
        let controller = window()
        defer { controller.close() }
        let document = controller.documentHandle
        document.addPage()
        document.addPage()
        #expect(document.pages.count == 3 && document.currentPageIndex == 2)
        document.removePage(at: 2)
        #expect(document.currentPageIndex == 1 && controller.statusBar.pageField.stringValue == "2")
        document.selectPage(0)
        document.removePage(at: 0)
        #expect(document.currentPageIndex == 0 && document.pages.count == 1)
        document.addPage()
        document.selectPage(1)
        document.removePage(at: 0)
        #expect(document.currentPageIndex == 0)
        document.removePage(at: 5)
        document.selectPage(0)
        // Page changes count as content changes of any document.
        let custom = DocumentHandle.memory(title: "C")
        custom.addPage()
        custom.removePage(at: 0)
        #expect(custom.changeCount == 2 && custom.pages.count == 1)
        custom.pages = []
        #expect(custom.currentPage == nil)
        custom.addPage()
        #expect(custom.pages.count == 1)
    }

    @Test func unitsWriteOneChangeAndMergeLastWriterWins() {
        let controller = window()
        defer { controller.close() }
        let document = controller.documentHandle
        let bar = controller.statusBar
        #expect(bar.units.titleOfSelectedItem == "Points")
        bar.units.selectItem(withTitle: "Millimeters")
        bar.unitsChosen(bar.units)
        #expect(document.units == .millimeters)
        document.setUnits(.millimeters)
        #expect(document.changeCount == 1)

        // A remote change updates the pop-up without taking focus from a field being edited.
        controller.window?.makeFirstResponder(bar.magnification)
        let focused = controller.window?.firstResponder
        document.mergeUnits(UnitsRegister(value: .picas, counter: 9, replica: "zz"))
        #expect(bar.units.titleOfSelectedItem == "Picas")
        #expect(controller.window?.firstResponder === focused)
        document.mergeUnits(UnitsRegister(value: .inches, counter: 1, replica: "zz"))
        #expect(document.units == .picas, "an older write loses")
        #expect(DocumentUnits.allCases.map(\.title).count == 7)
    }

    @Test func twoClientsSettingUnitsConverge() {
        let a = DocumentHandle.memory(title: "A")
        let b = DocumentHandle.memory(title: "B")
        a.setUnits(.inches)
        b.setUnits(.centimeters)
        let fromA = a.unitsRegister, fromB = b.unitsRegister
        a.mergeUnits(fromB)
        b.mergeUnits(fromA)
        #expect(a.units == b.units)
        #expect(a.unitsRegister == b.unitsRegister)
        let tie = UnitsRegister(value: .pixels, counter: 1, replica: "b")
        #expect(UnitsRegister(value: .points, counter: 1, replica: "a").merged(with: tie) == tie)
        #expect(tie.merged(with: UnitsRegister(value: .points, counter: 1, replica: "a")) == tie)
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
        #expect(controller.statusBar.model.participants.map(\.id) == ["p1", "p2"])
        #expect(AvatarStripView.initials("Priya Shah") == "PS" && AvatarStripView.initials("sam") == "S")
        var jumped: [String] = []
        controller.statusBar.model.onParticipant = { jumped.append($0.id) }
        controller.statusBar.model.onParticipant(presence.participants[0])
        #expect(jumped == ["p1"])
        for view in [NSHostingView(rootView: AvatarStripView(model: controller.statusBar.model)) as NSView, NSHostingView(rootView: SyncIndicatorView(model: controller.statusBar.model))] {
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.width > 0)
        }
        controller.statusBar.show(sync: .reviewNeeded)
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
