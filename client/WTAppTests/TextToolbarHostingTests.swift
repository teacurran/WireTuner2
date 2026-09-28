import AppKit
import Testing
import WTModel
import WTText
@testable import WireTuner

/// The Text toolbar's own controls change the document of the window that hosts them -- docked
/// alone, docked as a tab among panels, or floating over it -- for a selected block and for a
/// Text-tool range, each as one change.  The controls get no window of their own (the closure
/// answers nil), so only the hosting can find the document.
@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor struct TextToolbarHostingTests {
    enum Hosting: CaseIterable {
        case dockedAlone, tabAmongPanels, floating
    }

    /// A document window whose panel registry has the toolbars, and its floating panels.
    @MainActor
    final class World {
        let type = TypeWorld()
        let controller: ToolbarController
        let floating: FloatingPanelsController
        let recents = FontControlTests.recents()

        init() {
            let environment = type.setup.environment
            controller = ToolbarController(commands: environment.commands, layout: environment.layout,
                                           extensions: ExtensionRegistry(defaults: nil), tools: environment.tools)
            for placeholder in ToolbarCatalog.placeholders { environment.commands.registerIfAbsent(placeholder) }
            ToolbarPanels.register(into: environment.panels, controller: controller)
            controller.controls = FontToolbarControls.makers(window: { nil }, recents: recents)
            floating = FloatingPanelsController(panels: environment.panels, layout: environment.layout)
            let window = type.window
            floating.parentWindow = { [weak window] in window?.window }
        }

        var layout: PanelLayoutController { type.setup.environment.layout }
        var panel: PanelID { ToolbarID.text.panelID }

        /// Shows the Text toolbar as `hosting` asks and returns its view.
        func host(_ hosting: Hosting) throws -> ToolbarView {
            switch hosting {
            case .dockedAlone:
                layout.update { _ = $0.movePanel(panel, toNewGroupAt: .right) }
                return try #require(type.window.dock.body(for: panel) as? ToolbarView)
            case .tabAmongPanels:
                let properties = try #require(layout.layout.group(containing: "object"))
                layout.update { layout in
                    layout.movePanel(panel, toGroup: properties.id)
                    layout.activate(panel)
                }
                #expect(layout.layout.group(containing: panel)?.panels.count ?? 0 > 1)
                return try #require(type.window.dock.body(for: panel) as? ToolbarView)
            case .floating:
                layout.update { _ = $0.floatPanel(panel, frame: LayoutRect(x: 100, y: 100, width: 260, height: 320)) }
                return try #require(floating.body(for: panel) as? ToolbarView)
            }
        }

        func close() {
            layout.update { $0.removePanel(panel) }
            type.close()
        }
    }

    static func controls(_ view: ToolbarView) throws -> (FontFamilyPicker, StylePopUp, SizeComboBox) {
        (try #require(view.arranged.compactMap { $0 as? FontFamilyPicker }.first),
         try #require(view.arranged.compactMap { $0 as? StylePopUp }.first),
         try #require(view.arranged.compactMap { $0 as? SizeComboBox }.first))
    }

    @Test(arguments: Hosting.allCases)
    func theControlsChangeTheHostingWindowsDocument(_ hosting: Hosting) async throws {
        let watchdog = MainThreadWatchdog(name: "Text toolbar \(hosting)")
        defer { watchdog.stop() }
        let world = World()
        defer { world.close() }
        let type = world.type
        let node = try await type.block("Hosted text")
        let view = try world.host(hosting)
        #expect(view.hostedDocumentWindow === type.window, "hosted by the document window")
        let (family, style, size) = try Self.controls(view)
        view.refreshStates()
        #expect(family.isEnabled && size.isEnabled && style.isEnabled)

        // A family picked from the list: one change, "Font", shown at once.
        var before = type.document.changeCount
        let list = try #require(family.openList(nil))
        list.filter("Georgia")
        list.handle(#selector(NSResponder.insertNewline(_:)))
        await type.settle()
        #expect(FontControlTests.families(type, node) == ["Georgia"])
        #expect(type.document.changeCount == before + 1 && type.document.undoTitle == "Undo Font")
        view.refreshStates()
        #expect(family.title == "Georgia")

        // A face picked from the pop-up: "Font Style".
        before = type.document.changeCount
        let face = try #require(style.itemTitles.first { $0 != style.titleOfSelectedItem })
        style.selectItem(withTitle: face)
        style.choose(nil)
        await type.settle()
        #expect(TextFixtureReading.style(type, node) == face && type.document.changeCount == before + 1)

        // A preset picked from the size list applies at once: "Size", shown afterwards.
        before = type.document.changeCount
        let index = try #require(TypeSizes.presets.firstIndex(of: 24))
        size.selectItem(at: index)
        size.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: size))
        size.commit(nil)
        await type.settle()
        #expect(TextFixtureReading.sizes(type, node) == [24])
        #expect(type.document.changeCount == before + 1 && type.document.undoTitle == "Undo Size")
        view.refreshStates()
        #expect(size.stringValue == "24")

        // A typed size on Return, sent twice: one change.
        before = type.document.changeCount
        size.stringValue = "30"
        size.commit(nil)
        size.commit(nil)
        await type.settle()
        #expect(TextFixtureReading.sizes(type, node) == [30] && type.document.changeCount == before + 1)

        // A Text-tool range: only the range changes.
        await type.edit(node, select: 0..<3)
        view.refreshStates()
        before = type.document.changeCount
        let rangeList = try #require(family.openList(nil))
        rangeList.filter("Menlo")
        rangeList.choose()
        size.stringValue = "18"
        size.commit(nil)
        await type.settle()
        #expect(Set(FontControlTests.families(type, node)) == ["Menlo", "Georgia"])
        #expect(Set(TextFixtureReading.sizes(type, node)) == [18, 30])
        #expect(type.document.changeCount == before + 2)
    }

    /// What the user does in the window: pick from the open family list, type a size and press
    /// Return, type one and click elsewhere, and change quickly many times while the window keeps
    /// revalidating the toolbar.  A hang trips the watchdog and fails the run rather than stalling.
    @Test(arguments: Hosting.allCases)
    func realEditingInTheWindowNeitherHangsNorLosesAChange(_ hosting: Hosting) async throws {
        let watchdog = MainThreadWatchdog(name: "Text toolbar editing \(hosting)")
        defer { watchdog.stop() }
        let world = World()
        defer { world.close() }
        let type = world.type
        let node = try await type.block("Edited text")
        let view = try world.host(hosting)
        let (family, _, size) = try Self.controls(view)
        let window = try #require(view.window)
        view.refreshStates()

        // Picking from the open list (a popover when the toolbar is in a window).
        let list = try #require(family.openList(nil))
        list.typeAhead("Georgia")
        let returnKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                      context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        list.table.keyDown(with: returnKey)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        await type.settle()
        #expect(FontControlTests.families(type, node) == ["Georgia"] && family.popover == nil)

        // Typing a size, then Return: the field editor ends editing and sends the action.
        var before = type.document.changeCount
        #expect(window.makeFirstResponder(size))
        let editor = try #require(size.currentEditor() as? NSTextView)
        editor.string = "33"
        view.refreshStates()
        #expect(size.stringValue == "33" || editor.string == "33", "a refresh leaves the typing alone")
        editor.insertNewline(nil)
        await type.settle()
        #expect(TextFixtureReading.sizes(type, node) == [33] && type.document.changeCount == before + 1)

        // Typing a size, then clicking elsewhere (the canvas takes the keyboard).
        before = type.document.changeCount
        #expect(window.makeFirstResponder(size))
        (size.currentEditor() as? NSTextView)?.string = "44"
        window.makeFirstResponder(nil)
        await type.settle()
        #expect(TextFixtureReading.sizes(type, node) == [44] && type.document.changeCount == before + 1)

        // Quick changes while the window revalidates after each.
        before = type.document.changeCount
        for step in 0..<20 {
            family.choose(step.isMultiple(of: 2) ? "Menlo" : "Georgia")
            size.stringValue = "\(20 + step)"
            size.commit(nil)
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        }
        await type.settle()
        view.refreshStates()
        #expect(FontControlTests.families(type, node) == ["Georgia"] && TextFixtureReading.sizes(type, node) == [39])
        #expect(family.title == "Georgia" && size.stringValue == "39")
        #expect(type.document.changeCount > before && type.document.changeCount <= before + 40)
    }

    @Test func aTypedSizeThatIsNotASizeIsRefused() async throws {
        let world = World()
        defer { world.close() }
        let node = try await world.type.block("Refused")
        let view = try world.host(.dockedAlone)
        let (_, _, size) = try Self.controls(view)
        view.refreshStates()
        let before = world.type.document.changeCount
        size.stringValue = "huge"
        size.commit(nil)
        if size.indexOfSelectedItem >= 0 { size.deselectItem(at: size.indexOfSelectedItem) }
        size.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: size))
        await world.type.settle()
        #expect(world.type.document.changeCount == before && size.stringValue == "12" && TextFixtureReading.sizes(world.type, node) == [12])
        world.type.window.selection.model.clear()
        size.apply(20)
        #expect(world.type.document.changeCount == before)
    }
}

/// Fails the run when the main thread stops answering for `limit` seconds (a hang in a control's
/// action or a layout loop), rather than stalling the suite.
final class MainThreadWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var lastAnswer = Date()
    private var running = true
    let name: String
    let limit: TimeInterval

    init(name: String, limit: TimeInterval = 30) {
        self.name = name
        self.limit = limit
        let thread = Thread { [weak self] in self?.watch() }
        thread.start()
    }

    private func watch() {
        while true {
            Thread.sleep(forTimeInterval: 0.25)
            lock.lock()
            let stillRunning = running
            let silent = Date().timeIntervalSince(lastAnswer)
            lock.unlock()
            guard stillRunning else { return }
            if silent > limit { fatalError("\(name): the main thread did not answer for \(Int(silent)) s") }
            DispatchQueue.main.async { [weak self] in self?.answer() }
        }
    }

    private func answer() {
        lock.lock()
        lastAnswer = Date()
        lock.unlock()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }
}
