import AppKit
import Observation
import PDFKit
import SwiftUI
import Synchronization
import Testing
@testable import WireTuner

@Suite @MainActor struct KeyboardShortcutsModelTests {
    private func makeModel() -> (KeyboardShortcutsModel, ShortcutSetStore, CommandRegistry) {
        let registry = CommandRegistry()
        StandardCommands.register(into: registry)
        registry.registerIfAbsent(Command(id: "tool.pen", title: "Pen", key: WireTuner.KeyEquivalent("p"), action: .perform(Command.noop)))
        let store = ShortcutSetStore(url: nil, presets: BuiltInShortcutSets.bundledPresets())
        store.commands = { registry.commands }
        let model = KeyboardShortcutsModel(store: store, registry: registry)
        model.beginSession()
        return (model, store, registry)
    }

    @Test func theListIsGroupedByMenuAndSearchable() {
        let (model, _, _) = makeModel()
        let titles = model.categories.map(\.id)
        #expect(titles.first == "WireTuner" && titles.last == ShortcutCategories.menuless)
        #expect(titles.contains("View") && titles.firstIndex(of: "File")! < titles.firstIndex(of: "View")!)
        let magnification = model.categories.first { $0.id == "View" }!.rows.first { $0.id == StandardCommands.ID.magnification(100) }!
        #expect(magnification.title == "Magnification > 100%" && magnification.shortcut == "⌘1")
        model.searchText = "zoom in"
        #expect(model.categories.flatMap(\.rows).map(\.id) == [StandardCommands.ID.zoomIn])
        model.searchText = "⇧⌘Z"
        #expect(model.categories.flatMap(\.rows).map(\.id) == [StandardCommands.ID.redo])
        #expect(model.isExpanded("View"))
        model.searchText = ""
        model.expansion(for: "View").wrappedValue = false
        #expect(!model.isExpanded("View") && !model.expansion(for: "View").wrappedValue)
        model.setExpanded(true, "View")
        #expect(model.isExpanded("View"))
        #expect(model.commandDescription.hasPrefix("Select a command"))
    }

    @Test func assigningOnABuiltInSetCopiesItFirstAndResolvesConflicts() {
        let (model, store, _) = makeModel()
        var prompts: [String] = []
        model.confirm = { prompts.append($0); return true }
        model.selectedCommandID = StandardCommands.ID.open
        #expect(model.commandDescription == "File — Open…")
        #expect(model.currentShortcuts == [WireTuner.KeyEquivalent("o", .command)])
        model.capture(WireTuner.KeyEquivalent("n", .command))
        #expect(model.conflictOwners == [StandardCommands.ID.new])
        #expect(model.conflictText == "Currently assigned to: New")
        #expect(model.canAssign && model.refusal == nil)
        model.goToConflictOnAssign = true
        #expect(model.assign())
        #expect(prompts == [KeyboardShortcutsModel.copyPrompt])
        #expect(!store.isActiveSetBuiltIn && model.isEditable)
        #expect(store.activeSet.keys(for: StandardCommands.ID.open) == [WireTuner.KeyEquivalent("o", .command), WireTuner.KeyEquivalent("n", .command)])
        #expect(store.activeSet.keys(for: StandardCommands.ID.new).isEmpty, "the key was taken away")
        #expect(model.selectedCommandID == StandardCommands.ID.new, "Go to conflict selects the loser")
        #expect(model.capturedKey == nil)

        // Without Go to conflict the selection stays.
        model.goToConflictOnAssign = false
        model.selectedCommandID = StandardCommands.ID.close
        model.capture(WireTuner.KeyEquivalent("o", .command))
        #expect(model.assign() && model.selectedCommandID == StandardCommands.ID.close)
        #expect(prompts.count == 1, "an editable set is not copied again")
    }

    @Test func reservedKeysAreRefusedAndCopyingCanBeDeclined() {
        let (model, store, _) = makeModel()
        model.selectedCommandID = StandardCommands.ID.new
        model.capture(WireTuner.KeyEquivalent("tab", .command))
        #expect(model.refusal == KeyboardShortcutsModel.reservedReason && !model.canAssign && !model.assign())
        model.selectedCommandID = StandardCommands.ID.quit
        model.capture(WireTuner.KeyEquivalent("q", .command))
        #expect(model.refusal == nil, "Quit owns Command-Q")
        model.confirm = { _ in false }
        model.selectedCommandID = StandardCommands.ID.new
        model.capture(WireTuner.KeyEquivalent("n", [.command, .option]))
        #expect(!model.assign() && store.isActiveSetBuiltIn)
        model.selectedKey = WireTuner.KeyEquivalent("n", .command)
        #expect(!model.remove())
    }

    @Test func removeAndRevert() {
        let (model, store, _) = makeModel()
        model.selectedCommandID = StandardCommands.ID.new
        model.selectedKey = WireTuner.KeyEquivalent("x", .command)
        #expect(!model.remove(), "not one of the command's keys")
        model.selectedKey = WireTuner.KeyEquivalent("n", .command)
        model.handle(.remove)
        model.capture(WireTuner.KeyEquivalent("n", [.command, .control]))
        model.handle(.assign)
        #expect(store.activeSet.keys(for: StandardCommands.ID.new) == [WireTuner.KeyEquivalent("n", [.command, .control])])
        model.selectedKey = WireTuner.KeyEquivalent("n", [.command, .control])
        model.handle(.remove)
        #expect(store.activeSet.keys(for: StandardCommands.ID.new).isEmpty && model.selectedKey == nil)
        #expect(store.userSets.count == 1)
        model.handle(.revert)
        #expect(store.userSets.isEmpty && store.activeSetID == ShortcutSet.defaultID)
        #expect(store.activeSet.keys(for: StandardCommands.ID.new) == [WireTuner.KeyEquivalent("n", .command)])
        model.selectedCommandID = nil
        #expect(!model.remove() && !model.assign())
        // Revert before any session is a no-op; a conflict with an unregistered command shows its id.
        let fresh = KeyboardShortcutsModel(store: store, registry: CommandRegistry())
        fresh.revert()
        var set = store.activeSet
        set.bind(WireTuner.KeyEquivalent("j", .command), to: "ghost.command")
        fresh.capture(WireTuner.KeyEquivalent("j", .command))
        #expect(fresh.conflictOwners.isEmpty, "the default set has no ghost")
        #expect(set.commandIDs(for: WireTuner.KeyEquivalent("j", .command)) == ["ghost.command"])
        _ = try? store.makeCopy(of: ShortcutSet.defaultID, name: "Ghostly")
        try? store.update({ var copy = store.activeSet; copy.bind(WireTuner.KeyEquivalent("j", .command), to: "ghost.command"); return copy }())
        #expect(fresh.conflictText == "Currently assigned to: ghost.command")
    }

    @Test func setMenuActions() {
        let (model, store, _) = makeModel()
        var names = ["Mine"]
        model.askName = { _, _ in names.isEmpty ? nil : names.removeFirst() }
        model.handle(.newSet)
        #expect(model.summaries.last?.name == "Mine" && model.activeSetID == store.userSets[0].id)
        names = ["Renamed"]
        model.handle(.rename)
        #expect(store.userSets[0].name == "Renamed")
        names = [" "]
        model.handle(.rename)
        #expect(model.message != nil, "an empty name is reported")
        names = ["Dup"]
        model.handle(.duplicate)
        #expect(store.userSets.map(\.name) == ["Renamed", "Dup"])
        model.handle(.delete)
        #expect(store.userSets.map(\.name) == ["Renamed"] && model.activeSetID == ShortcutSet.defaultID)
        model.handle(.delete)
        #expect(model.message != nil, "a built-in set cannot be deleted")
        names = []
        model.handle(.newSet)
        model.handle(.rename)
        #expect(store.userSets.count == 1)
        model.activeSetID = BuiltInShortcutSets.photoshopID
        #expect(store.activeSetID == BuiltInShortcutSets.photoshopID)
        model.activeSetID = "missing"
        #expect(model.message != nil && store.activeSetID == BuiltInShortcutSets.photoshopID)
    }

    @Test func exportImportAndCSVFiles() throws {
        let (model, store, registry) = makeModel()
        let directory = TestEnvironment.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var suggested: [String] = []
        model.chooseSaveURL = { name in
            suggested.append(name)
            return directory.appending(path: name)
        }
        model.handle(.exportSet)
        #expect(suggested == ["WireTuner.wtkeys"])
        model.chooseOpenURL = { directory.appending(path: "WireTuner.wtkeys") }
        model.handle(.importSet)
        #expect(model.message == "Imported WireTuner." && store.userSets.count == 1)
        var withBadKey = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "WireTuner.wtkeys"))) as! [String: Any]
        withBadKey["bindings"] = [["command_id": "file.new", "keys": ["hyper+n"]]]
        try JSONSerialization.data(withJSONObject: withBadKey).write(to: directory.appending(path: "bad.wtkeys"))
        model.chooseOpenURL = { directory.appending(path: "bad.wtkeys") }
        model.handle(.importSet)
        #expect(model.message?.contains("Skipped: file.new") == true)
        model.chooseOpenURL = { directory.appending(path: "missing.wtkeys") }
        model.handle(.importSet)
        #expect(model.message?.hasPrefix("Imported") == false)
        model.chooseOpenURL = { nil }
        model.handle(.importSet)

        model.handle(.exportText)
        let csv = try String(contentsOf: directory.appending(path: "WireTuner Shortcuts.csv"), encoding: .utf8)
        let rows = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(rows.count == store.activeSet.bindings.count + 1, "one row per binding")
        #expect(rows[0] == "command,shortcut,description")
        #expect(rows.contains("Magnification > 100%,cmd+1,View > Magnification"))
        #expect(ShortcutCSV.field("a,\"b\"") == "\"a,\"\"b\"\"\"")
        #expect(ShortcutCSV.export(set: ShortcutSet(id: "x", name: "X", bindings: [ShortcutBinding(commandID: "gone", keys: [])]), commands: registry.commands)
            .hasSuffix("gone,,\r\n"))

        model.handle(.saveCardPDF)
        #expect(PDFDocument(url: directory.appending(path: "WireTuner Shortcuts.pdf"))?.pageCount ?? 0 >= 1)
        model.chooseSaveURL = { _ in URL(fileURLWithPath: "/dev/null/x.csv") }
        model.handle(.exportText)
        #expect(model.message != nil)
        model.chooseSaveURL = { _ in nil }
        model.handle(.exportText)
    }

    @Test func cardPreviewAndPrint() {
        let (model, _, _) = makeModel()
        model.handle(.showCard)
        #expect(model.showingCardPreview)
        var printed: [NSPrintOperation] = []
        model.runPrint = { printed.append($0) }
        model.handle(.printCard)
        #expect(printed.count == 1 && printed[0].jobTitle == "Keyboard Shortcuts")
        model.handle(.closeCard)
        #expect(!model.showingCardPreview)
        let without = model.cardView().layout.lines.count
        model.includeUnboundOnCard = true
        #expect(model.cardView().layout.lines.count > without)
    }
}

@Suite @MainActor struct ShortcutCardTests {
    @Test func theDefaultCardMatchesItsGolden() throws {
        let commands = StandardCommands.commands()
        let set = ShortcutSet.builtInDefault(commands: commands)
        let sections = ShortcutCardSection.sections(commands: commands, set: set, includeUnbound: false)
        #expect(sections.map(\.title) == ["WireTuner", "File", "Edit", "View", "Window", "Help"])
        #expect(sections.flatMap(\.entries).allSatisfy { !$0.shortcut.isEmpty })
        let view = ShortcutCardView(title: "WireTuner Keyboard Shortcuts — WireTuner", commands: commands, set: set, includeUnbound: false)
        let data = view.pdfData()
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == view.layout.pageCount)
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        for line in ["WireTuner Keyboard Shortcuts", "File", "Edit", "View", "Magnification > 100%", "Zoom In", "Quit WireTuner", "Command Palette…"] {
            #expect(text.contains(line), "\(line) is on the card")
        }
        let page = try #require(pdf.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        #expect(abs(bounds.width - 612) < 1 && abs(bounds.height - 792) < 1)
    }

    @Test func longCardsPaginateWithoutOrphanHeaders() throws {
        let entries = (0..<200).map { ShortcutCardSection.Entry(title: "Command \($0)", shortcut: "⌘\($0 % 10)") }
        let sections = (0..<4).map { ShortcutCardSection(title: "Menu \($0)", entries: Array(entries[($0 * 50)..<($0 * 50 + 50)])) }
        let layout = ShortcutCardLayout(title: "Card", sections: sections)
        #expect(layout.pageCount >= 2)
        #expect(!layout.lines(onPage: 1).isEmpty)
        let bottom = ShortcutCardLayout.pageSize.height - ShortcutCardLayout.margin
        for (index, line) in layout.lines.enumerated() where line.kind == .header {
            let next = layout.lines[index + 1]
            #expect(next.page == line.page && next.origin.x == line.origin.x, "a header keeps its first entry")
        }
        #expect(layout.lines.allSatisfy { $0.origin.y + ShortcutCardLayout.entryHeight <= bottom + ShortcutCardLayout.headerHeight })
        let view = ShortcutCardView(layout: layout)
        var range = NSRange()
        #expect(view.knowsPageRange(&range) && range == NSRange(location: 1, length: layout.pageCount))
        #expect(view.rectForPage(2).minY == ShortcutCardLayout.pageSize.height)
        let pdf = try #require(PDFDocument(data: view.pdfData()))
        #expect(pdf.pageCount == layout.pageCount)
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 612, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        view.cacheDisplay(in: NSRect(x: 0, y: 700, width: 612, height: 200), to: image)
        #expect(view.isFlipped)
    }
}

@Suite @MainActor struct KeyboardShortcutsWindowTests {
    @Test func theWindowHostsTheFormAndCapturesKeys() throws {
        let registry = CommandRegistry()
        StandardCommands.register(into: registry)
        let store = ShortcutSetStore(url: nil)
        store.commands = { registry.commands }
        let model = KeyboardShortcutsModel(store: store, registry: registry)
        let controller = KeyboardShortcutsWindowController(model: model)
        controller.show()
        #expect(controller.window?.identifier == KeyboardShortcutsWindowController.identifier)
        model.selectedCommandID = StandardCommands.ID.new
        model.capture(WireTuner.KeyEquivalent("tab", .command))
        model.message = "Hello"
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        model.capture(WireTuner.KeyEquivalent("o", .command))
        #expect(model.conflictText != nil && model.refusal == nil)
        NSHostingView(rootView: KeyboardShortcutsView(model: model)).layoutSubtreeIfNeeded()
        let view = KeyboardShortcutsView(model: model)
        view.act(.showCard)()
        #expect(model.showingCardPreview)
        let preview = NSHostingView(rootView: ShortcutCardPreview(model: model, act: view.act))
        preview.layoutSubtreeIfNeeded()
        #expect(preview.fittingSize.width > 0)
        model.showingCardPreview = false
        controller.close()

        let capture = KeyCaptureView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        var captured: [WireTuner.KeyEquivalent] = []
        capture.onCapture = { captured.append($0) }
        capture.keyDown(with: TestEvents.key("k", keyCode: 40, flags: .command))
        #expect(captured == [WireTuner.KeyEquivalent("k", .command)] && capture.label.stringValue == "⌘K")
        #expect(!capture.performKeyEquivalent(with: TestEvents.key("j", keyCode: 38, flags: .command)), "not first responder")
        #expect(!capture.capture(TestEvents.key("", keyCode: 0)))
        capture.show(nil)
        #expect(capture.label.stringValue == KeyCaptureView.prompt && capture.acceptsFirstResponder)
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 200, height: 50))
        window.contentView?.addSubview(capture)
        window.makeFirstResponder(capture)
        #expect(capture.performKeyEquivalent(with: TestEvents.key("j", keyCode: 38, flags: .command)))
        capture.keyDown(with: TestEvents.key("", keyCode: 0))
        #expect(captured.count == 2)
    }

    @Test func alertsAndPanelsGoThroughTheModalRunner() {
        let original = KeyboardShortcutsWindowController.runModal
        defer { KeyboardShortcutsWindowController.runModal = original }
        var shown: [String] = []
        KeyboardShortcutsWindowController.runModal = { modal in
            switch modal {
            case let .alert(alert):
                shown.append(alert.messageText)
                return .alertFirstButtonReturn
            case .panel:
                shown.append("panel")
                return .cancel
            }
        }
        #expect(KeyboardShortcutsWindowController.confirm("Copy?", in: nil))
        #expect(KeyboardShortcutsWindowController.askName(title: "Name", suggested: "Mine") == "Mine")
        #expect(KeyboardShortcutsWindowController.chooseSaveURL(suggestedName: "a.csv") == nil)
        #expect(KeyboardShortcutsWindowController.chooseOpenURL() == nil)
        #expect(shown == ["Copy?", "Name", "panel", "panel"])
        KeyboardShortcutsWindowController.runModal = { modal in
            if case .alert = modal { return .alertSecondButtonReturn }
            return .OK
        }
        #expect(KeyboardShortcutsWindowController.askName(title: "Name", suggested: "Mine") == nil)
        _ = KeyboardShortcutsWindowController.chooseSaveURL(suggestedName: "b.csv")
        _ = KeyboardShortcutsWindowController.chooseOpenURL()

        // The window controller hands the model these runners.
        let registry = CommandRegistry()
        StandardCommands.register(into: registry)
        let model = KeyboardShortcutsModel(store: ShortcutSetStore(url: nil), registry: registry)
        let controller = KeyboardShortcutsWindowController(model: model)
        #expect(!model.confirm("Again?") && model.askName("T", "S") == nil)
        // What a save panel confirmed without being shown answers depends on the file
        // entitlement (read-write since IO-005 names a default location); the runner is used.
        _ = model.chooseSaveURL("x")
        #expect(model.chooseOpenURL() == nil)
        // A print job saved to a file rather than sent to a printer.
        let url = TestEnvironment.temporaryDirectory().appending(path: "card.pdf")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info = ShortcutCardView.printInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = NSPrintOperation(view: model.cardView(), printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        model.runPrint(operation)
        #expect(FileManager.default.fileExists(atPath: url.path) && controller.window != nil)
    }

    @Test func clickingTheCaptureFieldFocusesIt() {
        let capture = KeyCaptureView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 200, height: 50))
        window.contentView?.addSubview(capture)
        let click = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        capture.mouseDown(with: click)
        #expect(window.firstResponder === capture)
    }

    @Test func theCommandReplacesThePlaceholder() {
        let registry = CommandRegistry()
        StandardCommands.register(into: registry)
        #expect(registry.validate(StandardCommands.ID.keyboardShortcuts)?.isEnabled == false)
        var shown = 0
        KeyboardShortcutsCommands.install(into: registry) { shown += 1 }
        #expect(registry.perform(StandardCommands.ID.keyboardShortcuts) && shown == 1)
        #expect(registry[StandardCommands.ID.keyboardShortcuts]?.menuPath == MenuPath("Edit", section: 2))
    }

    /// The list's outline view writes the sections' expansion and its selection from inside its
    /// delegate callbacks while it lays out; a write that changes nothing must not invalidate the
    /// model, or SwiftUI reloads the table from within its own delegate ("reentrant operation in
    /// NSTableView delegate", seen once in `theAppOpensOneEditorWindow`).
    @Test func unchangedWritesFromTheListInvalidateNothing() {
        let registry = CommandRegistry()
        StandardCommands.register(into: registry)
        let model = KeyboardShortcutsModel(store: ShortcutSetStore(url: nil), registry: registry)
        let category = model.categories[0].id
        let count = Mutex(0)
        var invalidations: Int { count.withLock { $0 } }
        func track(_ read: @escaping () -> Void) {
            withObservationTracking(read) { count.withLock { $0 += 1 } }
        }
        track { _ = model.isExpanded(category) }
        model.expansion(for: category).wrappedValue = true
        #expect(invalidations == 0, "already expanded: nothing changed")
        model.expansion(for: category).wrappedValue = false
        #expect(invalidations == 1 && !model.isExpanded(category))
        track { _ = model.isExpanded(category) }
        model.setExpanded(false, category)
        #expect(invalidations == 1, "already collapsed")
        model.setExpanded(true, category)
        #expect(invalidations == 2 && model.isExpanded(category))
        let id = model.categories[0].rows[0].id
        model.selection.wrappedValue = id
        track { _ = model.selectedCommandID }
        model.selection.wrappedValue = id
        #expect(invalidations == 2 && model.selection.wrappedValue == id)
        model.selection.wrappedValue = nil
        #expect(invalidations == 3 && model.selectedCommandID == nil)
    }

    /// The editor window opened twice in one turn with its list laid out between: the second show
    /// writes nothing the list reads back into its delegate.
    @Test func showingTheEditorAgainWhileItLaysOutIsSafe() {
        let registry = CommandRegistry()
        StandardCommands.register(into: registry)
        let controller = KeyboardShortcutsWindowController(model: KeyboardShortcutsModel(store: ShortcutSetStore(url: nil), registry: registry))
        defer { controller.close() }
        controller.show()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
        controller.show()
        controller.window?.displayIfNeeded()
        #expect(controller.window?.isVisible == true)
    }

    @Test func theAppOpensOneEditorWindow() {
        let suite = TestDefaults()
        let delegate = launchedDelegate(suite)
        defer { closeAll(delegate) }
        #expect(delegate.menuTarget?.perform(StandardCommands.ID.keyboardShortcuts) == true)
        let first = delegate.keyboardShortcutsWindowController
        delegate.showKeyboardShortcuts()
        #expect(first != nil && delegate.keyboardShortcutsWindowController === first)
        first?.close()
    }
}
