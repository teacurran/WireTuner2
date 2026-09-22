import AppKit
import Foundation
import Testing
@testable import WireTuner

@Suite @MainActor struct PanelLayoutControllerTests {
    private func temporaryStore() -> PanelLayoutStore {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WireTunerTests-\(UUID().uuidString)")
        return PanelLayoutStore(url: directory.appending(path: "nested").appending(path: PanelLayoutStore.fileName))
    }

    private func registry() -> PanelRegistry {
        let registry = PanelRegistry()
        PlaceholderPanels.register(into: registry)
        return registry
    }

    @Test func storeRoundTripsAndReportsMissingFiles() throws {
        let store = temporaryStore()
        #expect(try store.load() == nil)
        var layout = PanelLayout.standard(for: PlaceholderPanels.all)
        layout.setCollapsed(true, group: "layers")
        try store.save(layout)
        #expect(try store.load() == layout)
        #expect(PanelLayoutStore.defaultURL.pathComponents.suffix(3) == ["Application Support", "WireTuner", "PanelLayout.json"])

        try Data("{\"version\": 9}".utf8).write(to: store.url)
        #expect(throws: PanelLayoutStore.Failure.unsupportedVersion(9)) { try store.load() }
        try Data("garbage".utf8).write(to: store.url)
        #expect(throws: DecodingError.self) { try store.load() }
    }

    @Test func loadsDefaultWhenNothingIsSaved() {
        let panels = registry()
        let controller = PanelLayoutController(registry: panels, store: temporaryStore(), debounce: .milliseconds(1))
        controller.load()
        #expect(controller.loadError == nil)
        #expect(controller.layout == controller.defaultLayout)
        #expect(controller.layout.docks[.right]?.map(\.id) == ["properties", "layers"])
    }

    @Test func loadsSavedLayoutAndReconcilesPanels() throws {
        let store = temporaryStore()
        var saved = PanelLayout.standard(for: PlaceholderPanels.all)
        saved.movePanel("layers", toGroup: "properties")
        saved.add(panels: [PanelDescriptor(id: "ghost", title: "Ghost", defaultGroup: "Old") { NSView() }])
        try store.save(saved)

        let controller = PanelLayoutController(registry: registry(), store: store, debounce: .milliseconds(1))
        controller.load()
        #expect(controller.layout.group("properties")?.panels == ["object", "layers"])
        #expect(!controller.layout.contains("ghost"))
        #expect(controller.layout.docks[.right]?.map(\.id) == ["properties"])
    }

    @Test func fallsBackToDefaultOnCorruptFile() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: store.url)
        let controller = PanelLayoutController(registry: registry(), store: store)
        controller.load()
        #expect(controller.loadError != nil)
        #expect(controller.layout == controller.defaultLayout)
    }

    @Test func savesAfterDebounceAndNotifiesObservers() async throws {
        let store = temporaryStore()
        let controller = PanelLayoutController(registry: registry(), store: store, debounce: .milliseconds(5))
        controller.load()
        let counter = Counter()
        let token = controller.observe { _ in counter.bump() }
        controller.update { $0.setCollapsed(true, group: "layers") }
        controller.update { $0.setCollapsed(true, group: "layers") }
        #expect(counter.count == 1)
        #expect(controller.pendingSave != nil)
        await controller.flushPendingSave()
        #expect(controller.lastSaveError == nil)
        #expect(try store.load() == controller.layout)

        controller.stopObserving(token)
        controller.update { $0.setCollapsed(false, group: "layers") }
        #expect(counter.count == 1)
        controller.update { $0.setCollapsed(true, group: "layers") }
        await controller.flushPendingSave()
        #expect(try store.load()?.group("layers")?.collapsed == true)

        let reloaded = PanelLayoutController(registry: registry(), store: store)
        reloaded.load()
        #expect(reloaded.layout == controller.layout)
    }

    @Test func savesNowAndDropsPendingSaves() async throws {
        let store = temporaryStore()
        let controller = PanelLayoutController(registry: registry(), store: store, debounce: .seconds(30))
        controller.update { $0.setDockWidth(333, edge: .right) }
        #expect(controller.pendingSave != nil)
        try controller.saveNow()
        #expect(controller.pendingSave == nil)
        #expect(try store.load()?.dockWidth[.right] == 333)
        await controller.flushPendingSave()

        let storeless = PanelLayoutController(registry: registry())
        storeless.update { $0.setDockWidth(100, edge: .right) }
        #expect(storeless.pendingSave == nil)
        try storeless.saveNow()
        await storeless.flushPendingSave()
    }

    @Test func recordsSaveErrors() async {
        let unwritable = PanelLayoutStore(url: URL(fileURLWithPath: "/dev/null/cannot/PanelLayout.json"))
        let controller = PanelLayoutController(registry: registry(), store: unwritable, debounce: .milliseconds(1))
        controller.update { $0.setDockWidth(200, edge: .right) }
        await controller.flushPendingSave()
        #expect(controller.lastSaveError != nil)
        #expect(throws: (any Error).self) { try controller.saveNow() }
    }

    @Test func togglesPanelsFromTheWindowMenu() {
        let panels = registry()
        let controller = PanelLayoutController(registry: panels)
        controller.load()
        #expect(controller.isVisible("object"))
        controller.togglePanel("object")
        #expect(!controller.isVisible("object"))
        #expect(controller.layout.group("properties")?.collapsed == true)
        controller.togglePanel("object")
        #expect(controller.isVisible("object"))

        controller.update { $0.float(group: "layers", frame: LayoutRect(x: 0, y: 0, width: 200, height: 200)) }
        #expect(controller.isVisible("layers"))
        controller.togglePanel("layers")
        #expect(!controller.layout.contains("layers"))
        controller.togglePanel("layers")
        #expect(controller.layout.group("layers")?.panels == ["layers"])
        #expect(controller.layout.location(of: "layers") == .docked(.right, 1))
        #expect(controller.isVisible("layers"))

        controller.showPanel("unknown")
        #expect(!controller.layout.contains("unknown"))
        controller.update { $0.removePanel("layers") }
        controller.update { $0.setCollapsed(true, group: "properties") }
        controller.togglePanel("layers")
        #expect(controller.isVisible("layers"))
    }

    @Test func hidesAndShowsAllPanelsAndResets() {
        let panels = registry()
        let controller = PanelLayoutController(registry: panels)
        controller.load()
        #expect(!controller.panelsHidden)
        controller.toggleAllPanels()
        #expect(controller.panelsHidden)
        #expect(controller.layout.hiddenDocks == Set(DockEdge.allCases))
        controller.toggleAllPanels()
        #expect(!controller.panelsHidden)

        controller.update { $0.movePanel("layers", toGroup: "properties") }
        controller.update { $0.setDockWidth(500, edge: .right) }
        controller.resetToDefault()
        #expect(controller.layout == controller.defaultLayout)
    }

    @Test func addsPanelsRegisteredLater() throws {
        let panels = registry()
        let controller = PanelLayoutController(registry: panels)
        controller.load()
        controller.addRegisteredPanels()
        try panels.register(PanelDescriptor(id: "swatches", title: "Swatches", defaultGroup: "Assets", menuOrder: 5) { NSView() })
        #expect(!controller.layout.contains("swatches"))
        controller.addRegisteredPanels()
        #expect(controller.layout.group("assets")?.panels == ["swatches"])
        #expect(controller.defaultLayout.docks[.right]?.map(\.id) == ["assets", "properties", "layers"])
    }
}
