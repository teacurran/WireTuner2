import AppKit
import SwiftUI
import Testing
@testable import WireTuner

@Suite @MainActor struct FuzzyMatcherTests {
    private func score(_ query: String, _ title: String) -> Double? {
        FuzzyMatcher.score(FuzzyMatcher.prepare(query), FuzzyCandidate(title))
    }

    @Test func subsequencesMatchAndOthersDoNot() {
        #expect(score("rot cw", "Rotate Clockwise") != nil)
        #expect(score("lay bg", "Select Layer Background") != nil)
        #expect(score("swat", "Show Swatches") != nil)
        #expect(score("zoom in", "Zoom Out") == nil)
        #expect(score("abc", "ab") == nil)
        #expect(score("", "Anything") == 0)
        #expect(score("CAFE", "Café Menu") != nil, "diacritic- and case-insensitive")
    }

    @Test func wordStartsRunsAndShortTitlesRankHigher() throws {
        let start = try #require(score("sw", "Show Swatches"))
        let inner = try #require(score("sw", "Answer"))
        #expect(start > inner)
        let run = try #require(score("zoom", "Zoom In"))
        let spread = try #require(score("zoom", "Zxoxoxmx"))
        #expect(run > spread)
        let short = try #require(score("rot", "Rotate"))
        let long = try #require(score("rot", "Rotate Clockwise"))
        #expect(short > long)
        #expect(FuzzyCandidate("fitPage").wordStarts == [true, false, false, true, false, false, false])
        #expect(FuzzyMatcher.score(FuzzyMatcher.prepare("xy"), title: FuzzyCandidate("Zoom"), combined: FuzzyCandidate("Zoom xy")) != nil)
        #expect(FuzzyMatcher.score(FuzzyMatcher.prepare("q"), title: FuzzyCandidate("Zoom"), combined: FuzzyCandidate("Zoom Tool")) == nil)
    }
}

@Suite @MainActor struct CommandPaletteModelTests {
    private func item(_ id: String, _ title: String, subtitle: String = "", enabled: Bool = true, run: @escaping @MainActor @Sendable () -> Void = {}) -> PaletteItem {
        PaletteItem(id: id, title: title, subtitle: subtitle, kind: .command, isEnabled: enabled, reason: enabled ? nil : "Nothing is selected", run: run)
    }

    @Test func zoomInAndReturnPerformsTheRegistryEntry() {
        let registry = CommandRegistry()
        StandardCommands.register(into: registry)
        var zoomed = 0
        registry.replace(Command(id: StandardCommands.ID.zoomIn, title: "Zoom In", key: WireTuner.KeyEquivalent("=", .command), menu: MenuPath("View"), action: .perform { zoomed += 1 }))
        let model = CommandPaletteModel(history: PaletteHistory(url: nil))
        var performed: [CommandID] = []
        model.register(CommandPaletteSource(registry: registry, shortcuts: { ShortcutSet.builtInDefault(commands: registry.commands) }, perform: { id in
            performed.append(id)
            registry.perform(id)
        }), id: "commands")
        var closed = 0
        model.onRun = { closed += 1 }
        model.query = "zoom in"
        let first = model.results.first?.item
        #expect(first?.id == StandardCommands.ID.zoomIn.rawValue)
        #expect(first?.subtitle == "View" && first?.shortcut == WireTuner.KeyEquivalent("=", .command) && first?.kind == .command)
        #expect(first?.accessibilityLabel == "Zoom In, ⌘=, enabled")
        #expect(model.handle(.run))
        #expect(performed == [StandardCommands.ID.zoomIn] && zoomed == 1 && closed == 1)

        // A disabled command is listed greyed with its reason; Return does nothing.
        model.query = "export"
        let export = model.results.first?.item
        #expect(export?.isEnabled == false && export?.detail == Command.placeholderReason)
        #expect(export?.accessibilityLabel.contains("dimmed, \(Command.placeholderReason)") == true)
        #expect(!model.runSelected() && performed.count == 1)
        #expect(model.results.contains { $0.item.id == StandardCommands.ID.commandPalette.rawValue } == false)
    }

    @Test func panelsPagesAndStubSourcesAreSearched() {
        let panels = PanelRegistry()
        PanelCatalog.register(into: panels, selection: ActiveSelection(), help: HelpPanelModel())
        let model = CommandPaletteModel(history: PaletteHistory(url: nil))
        var shown: [PanelID] = []
        model.register(PanelPaletteSource(panels: panels, show: { shown.append($0) }), id: "panels")
        model.query = "swat"
        #expect(model.results.first?.item.title == "Show Swatches" && model.results.first?.item.kind == .panel)
        model.runSelected()
        #expect(shown == ["swatches"])

        model.register(id: "layers") { [self] in [item("layer.bg", "Select Layer Background", subtitle: "Poster"), item("layer.fg", "Select Layer Foreground")] }
        model.query = "lay bg"
        #expect(model.results.first?.item.id == "layer.bg")

        let document = DocumentHandle.memory(title: "Poster")
        document.addPage()
        var pages: [Int] = []
        model.register(PagePaletteSource(document: { document }, goToPage: { pages.append($0) }), id: "pages")
        model.query = "page 2"
        #expect(model.results.first?.item.title == "Go to Page 2")
        model.run(at: 0)
        #expect(pages == [1])
        #expect(!model.run(at: 99))
        model.register(PagePaletteSource(document: { nil }, goToPage: { _ in }), id: "pages")
        model.unregister(id: "layers")
        model.query = "zzqq"
        #expect(model.results.isEmpty && model.sources.map(\.id) == ["panels", "pages"])
        #expect(!model.runSelected())
    }

    @Test func recentChoicesRankFirstAndSurviveReload() {
        let url = TestEnvironment.temporaryDirectory().appending(path: PaletteHistory.fileName)
        let items = [item("tool.rotate", "Rotate"), item("view.rotateClockwise", "Rotate Clockwise"), item("view.rotateReset", "Reset Rotation")]
        func model() -> CommandPaletteModel {
            let model = CommandPaletteModel(history: PaletteHistory(url: url))
            model.register(id: "stub") { items }
            return model
        }
        let first = model()
        first.query = "rot"
        #expect(first.results.first?.item.id == "tool.rotate", "the shorter title wins without history")
        for _ in 0..<2 {
            first.query = "rot"
            first.moveSelection(by: first.results.firstIndex { $0.item.id == "view.rotateClockwise" } ?? 0)
            #expect(first.selectedResult?.item.id == "view.rotateClockwise")
            first.handle(.run)
        }
        let reloaded = model()
        reloaded.query = "rot"
        #expect(reloaded.results.first?.item.id == "view.rotateClockwise")
        reloaded.query = "rota"
        #expect(reloaded.results.first?.item.id == "view.rotateClockwise", "a longer query keeps the prefix's history")
        reloaded.query = "reset"
        #expect(reloaded.results.first?.item.id == "view.rotateReset")
    }

    @Test func theHistoryIsCappedAndDecays() {
        let history = PaletteHistory(url: nil)
        for index in 0..<(PaletteHistory.capacity + 20) {
            history.record(query: "q\(index)", itemID: "item\(index)", now: Int64(index))
        }
        #expect(history.entries.count == PaletteHistory.capacity)
        #expect(!history.entries.contains { $0.itemID == "item0" }, "the least recently used go first")
        history.record(query: "Abc  Def", itemID: "x", now: 1000)
        history.record(query: "abc def", itemID: "x", now: 1000)
        #expect(history.entries.contains(PaletteHistoryEntry(queryPrefix: "abc def", itemID: "x", count: 2, lastUsedMs: 1000)))
        let fresh = history.scores(for: "abc def ghi", now: 1000)["x"] ?? 0
        let old = history.scores(for: "abc def", now: 1000 + Int64(PaletteHistory.msPerDay * PaletteHistory.halfLifeDays))["x"] ?? 0
        #expect(abs(fresh - 2) < 1e-9 && abs(old - 1) < 1e-9)
        #expect(history.scores(for: "ab", now: 1000)["x"] == nil)
        let broken = PaletteHistory(url: URL(fileURLWithPath: "/dev/null/recents.json"))
        broken.record(query: "a", itemID: "b")
        #expect(broken.lastSaveError != nil)
        #expect(PaletteHistory.defaultURL.lastPathComponent == PaletteHistory.fileName)
    }

    @Test func keyboardNavigationAndDisabledLast() {
        let model = CommandPaletteModel(history: PaletteHistory(url: nil))
        model.register(id: "stub") { [self] in [item("a", "Alpha Zero", enabled: false), item("b", "Alpha One"), item("c", "Alpha Two")] }
        model.query = "alpha"
        #expect(model.results.map(\.item.id) == ["b", "c", "a"])
        model.handle(.down)
        model.handle(.down)
        model.handle(.down)
        #expect(model.selection == 2)
        model.handle(.up)
        #expect(model.selection == 1)
        var dismissed = 0
        model.onDismiss = { dismissed += 1 }
        model.handle(.dismiss)
        #expect(dismissed == 1)
        model.query = "zzz"
        model.moveSelection(by: 1)
        #expect(model.selection == 0 && model.selectedResult == nil)
        model.reset()
        #expect(model.query.isEmpty && model.results.count == 3)
    }

    @Test func fiveThousandItemsRankWithinAFrame() {
        let words = ["Align", "Blend", "Color", "Document", "Export", "Fill", "Guide", "Hide", "Insert", "Join", "Keyline", "Layer", "Mirror", "Node"]
        let items = (0..<5000).map { index in
            item("i\(index)", "\(words[index % words.count]) \(words[(index / 14) % words.count]) Command \(index)", subtitle: "Menu > Submenu")
        }
        let model = CommandPaletteModel(history: PaletteHistory(url: nil))
        model.register(id: "big") { items }
        model.query = "l"
        model.query = ""
        let clock = ContinuousClock()
        var worst = Duration.zero
        // The best of three runs per keystroke, so a busy machine's scheduling does not count.
        for query in ["z", "zo", "zoo", "lay", "lay bg", "keyline mirror"] {
            let elapsed = (0..<3).map { _ in clock.measure { model.query = query } }.min()!
            worst = max(worst, elapsed)
        }
        #expect(worst < .milliseconds(16), "worst keystroke \(worst)")
    }
}

@Suite @MainActor struct CommandPaletteControllerTests {
    @Test func thePanelOpensOverTheWindowAndFocusReturns() throws {
        let model = CommandPaletteModel(history: PaletteHistory(url: nil))
        var ran = 0
        model.register(id: "stub") { [PaletteItem(id: "x", title: "Run Me", kind: .command, symbolName: "star", run: { ran += 1 })] }
        let controller = CommandPaletteController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let field = NSTextField()
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        model.query = "stale"
        controller.toggle(over: window)
        #expect(controller.isShown && model.query.isEmpty && model.results.count == 1)
        #expect(controller.previousWindow === window)
        let expected = CommandPaletteController.frame(over: window.frame, size: controller.panel.frame.size)
        #expect(abs(controller.panel.frame.minX - expected.minX) < 1 && abs(controller.panel.frame.minY - expected.minY) < 1)
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(model.handle(.run) && ran == 1 && !controller.isShown)
        controller.show(over: nil)
        controller.panel.cancelOperation(nil)
        #expect(!controller.isShown)
        controller.show(over: window)
        controller.toggle(over: window)
        #expect(!controller.isShown)
        controller.close()
        #expect(controller.panel.canBecomeKey && !controller.panel.canBecomeMain)
        window.close()

        let view = CommandPaletteView(model: model)
        #expect(view.press(.upArrow) == .handled && view.press(.downArrow) == .handled && view.press(.escape) == .handled)
        #expect(view.press("a") == .ignored)
        #expect(view.press(.return) == .handled)
        #expect(PaletteKey(SwiftUI.KeyEquivalent.tab) == nil)
        let row = NSHostingView(rootView: PaletteRow(item: PaletteItem(id: "d", title: "Off", kind: .tool, shortcut: WireTuner.KeyEquivalent("p"), isEnabled: false, reason: "No", run: {}), isSelected: true))
        row.layoutSubtreeIfNeeded()
        #expect(row.fittingSize.height > 0)
        let bare = PaletteItem(id: "e", title: "Bare", subtitle: "Menu", kind: .command, isEnabled: false, run: {})
        #expect(bare.detail == "Menu" && bare.accessibilityLabel == "Bare, dimmed, not available")
    }

    @Test func theAppInstallsThePaletteCommandAndSources() throws {
        let suite = TestDefaults()
        let delegate = launchedDelegate(suite)
        defer { closeAll(delegate) }
        #expect(delegate.commands.validate(StandardCommands.ID.commandPalette)?.isEnabled == true)
        #expect(menuItem(StandardCommands.ID.commandPalette)?.keyEquivalent == "/")
        #expect(delegate.palette.model.sources.map(\.id) == ["commands", "panels", "pages"])
        #expect(delegate.menuTarget?.perform(StandardCommands.ID.commandPalette) == true)
        #expect(delegate.palette.isShown)
        delegate.palette.model.query = "swat"
        #expect(delegate.palette.model.results.first?.item.title == "Show Swatches")
        delegate.palette.model.runSelected()
        #expect(delegate.layout.isVisible("swatches") && !delegate.palette.isShown)
        delegate.palette.model.query = "page 1"
        #expect(delegate.palette.model.results.first?.item.title == "Go to Page 1")
        delegate.palette.model.runSelected()
        delegate.palette.model.query = "fit all"
        let window = try #require(delegate.activeDocumentWindow)
        window.zoom(toPercent: 400)
        delegate.palette.model.runSelected()
        #expect(window.viewport.zoom < 4, "Fit All ran on the front window")
        delegate.palette.model.query = "pointer"
        #expect(delegate.palette.model.results.first?.item.kind == .tool)
    }
}
