import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// LIB-012: the symbol editing window.
@Suite(.serialized) @MainActor struct SymbolEditingWindowTests {
    static func rect(x: Double, y: Double = 0) -> CreateShape {
        CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10), transform: .translation(x: x, y: y), appearance: TestAppearance.filled)
    }

    /// Two rectangles converted to a symbol in `world`; returns (symbol, instance, masters).
    static func symbol(_ world: GlueWorld) async throws -> (symbol: OpID, instance: OpID, masters: [OpID]) {
        let first = try #require(await world.document.perform(rect(x: 100, y: 100)).value?.createdObjects.first)
        let second = try #require(await world.document.perform(rect(x: 120, y: 100)).value?.createdObjects.first)
        let change = try #require(await world.document.perform(ConvertToSymbol([first, second])).value)
        await world.document.settle()
        return (change.createdNodes[0], change.createdNodes[1], [first, second])
    }

    /// A handle layer that takes every press and records what it saw.
    final class RecordingHandles: CanvasHandleLayer {
        var released: [Point] = []
        func press(_ e: CanvasEvent, context: ToolContext) -> Bool { true }
        func drag(_ e: CanvasEvent, context: ToolContext) {}
        func release(_ e: CanvasEvent, context: ToolContext) { released.append(e.pasteboardPoint) }
        func cancel(context: ToolContext) {}
        func draw(in ctx: CGContext, viewport: Viewport, context: ToolContext) {}
    }

    @Test func editSymbolOpensAWindowOnTheSymbolWhoseDrawingReachesTheInstances() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let (symbol, instance, masters) = try await Self.symbol(world)
        let windows = SymbolEditingWindows()
        let command = windows.command { [weak window = world.window] in window }
        #expect(command.validation() == .disabled(SymbolEditingWindows.noSymbol))
        world.select(masters)
        #expect(SymbolEditingWindows.editableSymbol(in: world.window) == nil, "not instances")
        world.select([instance])
        #expect(command.validation() == .enabled)
        guard case .perform(let run) = command.action else { Issue.record("not a perform command"); return }
        world.select([])
        run()
        #expect(windows.windows.isEmpty, "nothing selected: nothing opens")
        world.select([instance])
        run()
        let window = try #require(windows.windows.values.first)
        defer { window.window?.close() }
        let handle = window.documentHandle
        #expect(handle.symbolCanvasNode == symbol && handle.canvasNode == symbol)
        #expect(handle.glyphCanvasNode == nil && handle.masterCanvasNode == nil && world.document.symbolCanvasNode == nil)
        #expect(handle.id == SymbolWindowCanvas.handleID(document: world.document.id, symbol: symbol) && SymbolWindowCanvas.isSymbolWindow(handle.id))
        #expect(GlyphCanvas.documentID(ofTab: handle.id) == world.document.id)
        #expect(window.window?.title == "Symbol: Symbol 1" && window.statusBar.pageField.isHidden && window.statusBar.addPage.isHidden)
        #expect(window.window?.tabbingMode == .disallowed && window.window?.titlebarAccessoryViewControllers.count ?? 0 >= 1)
        #expect(!window.isPrimaryView && windows.documentWindow(of: window) === window, "outside the app its own window is the document's")
        #expect(window.environment.makePresence(handle) === world.window.presence, "the document's presence")
        #expect(handle.scene.topLevel == masters.map(NodeID.init))
        #expect(!handle.displayList.items.isEmpty && handle.state.stateHash == world.state.stateHash)
        #expect(windows.open(symbol, from: world.window) === window && windows.open(symbol, from: window) === window, "one window per symbol")
        // Drawing in the window: into the symbol, and the main window's instance repaints in the same change.
        let seen = TestBox<[ContentChange]>([])
        let token = world.document.observe { seen.value.append($0) }
        defer { world.document.stopObserving(token) }
        let before = try #require(world.document.object(for: SelectionID(instance))?.bounds)
        let created = try #require(await window.objectEditing.perform(Self.rect(x: 140, y: 100)).value?.createdObjects.first)
        await world.document.settle()
        #expect(world.state.liveChildren(symbol) == masters + [created])
        #expect(seen.value.contains { $0.summary.touchedNodes.contains(NodeID(instance)) })
        #expect((world.document.object(for: SelectionID(instance))?.bounds?.width ?? 0) > before.width)
        #expect(handle.scene.topLevel.last == NodeID(created))
        #expect(handle.undoTitle == "Undo Rectangle", "the document's undo")
        // Renamed: the title follows; removed: the window closes.
        _ = await world.document.perform(RenameLibraryEntry(node: symbol, name: "Badge")).value
        await world.document.settle()
        #expect(handle.title == "Symbol: Badge" && window.window?.title == "Symbol: Badge")
        _ = await world.document.perform(RemoveSymbols([symbol], instances: .release, in: world.state)).value
        await world.document.settle()
        #expect(windows.windows.isEmpty)
        windows.forget(window)
        #expect(windows.open(symbol, from: world.window) == nil, "gone")
        #expect(windows.open(instance, from: world.window) == nil, "not a symbol")
    }

    @Test func thePanelsEditAndDoubleClicksOpenTheSelectedSymbol() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let (symbol, _, _) = try await Self.symbol(world)
        let selection = ActiveSelection(model: world.window.selection.model, document: world.document, editing: world.editing)
        let model = SymbolLibraryModel(selection: selection)
        let asked = TestBox<[OpID]>([])
        model.edit = { asked.value.append($0) }
        #expect(!model.editSelected(), "nothing selected")
        #expect(model.optionsMenu().first { $0.title == "Edit" }?.isEnabled == false)
        model.editRow(symbol)
        #expect(asked.value == [symbol] && model.selectedSymbol == symbol)
        #expect(model.optionsMenu().first { $0.title == "Edit" }?.isEnabled == true)
        model.optionsMenu().first { $0.title == "Edit" }?.action()
        SymbolLibraryPanelBody.editing(model)()
        SymbolLibraryPanelBody.editing(symbol, model)()
        #expect(asked.value.count == 4)
        _ = await world.document.perform(CreateSymbolFolder(in: nil)).value
        await world.document.settle()
        let folder = try #require(model.rows.first { $0.kind == .folder }?.id)
        model.editRow(folder)
        #expect(asked.value.count == 4, "a folder has no window")
        Render.view(SymbolLibraryPanelBody(model: model))
        Render.view(SymbolWindowDoneButton {})
    }

    @Test func closingTheWindowMidDragKeepsTheChange() async throws {
        let world = GlueWorld()
        defer { world.close() }
        DrawingTools.install(into: world.setup.environment.tools)
        let (symbol, _, masters) = try await Self.symbol(world)
        let windows = SymbolEditingWindows()
        let window = try #require(windows.open(symbol, from: world.window))
        window.toolManager.finishDrag()
        await world.document.settle()
        #expect(world.state.liveChildren(symbol) == masters, "nothing between drags")
        window.toolManager.select(.rectangle)
        func event(_ point: Point) -> CanvasEvent { CanvasEvent(pasteboardPoint: point, viewPoint: window.viewport.toView(point), modifiers: []) }
        window.toolManager.mouseDown(event(Point(x: 100, y: 130)))
        window.toolManager.mouseDragged(event(Point(x: 120, y: 140)))
        window.toolManager.mouseDragged(event(Point(x: 130, y: 150)))
        window.window?.close()
        await window.documentHandle.settle()
        await world.document.settle()
        #expect(windows.windows.isEmpty)
        let drawn = try #require(world.state.liveChildren(symbol).last)
        #expect(world.state.liveChildren(symbol).count == 3 && world.state.props(drawn).rect.size.width == 30)
        // A handle drag is released where it was.
        let handles = RecordingHandles()
        let second = try #require(windows.open(symbol, from: world.window))
        second.toolManager.handleLayers = [handles]
        second.toolManager.select(.pointer)
        second.toolManager.mouseDown(event(Point(x: 1, y: 1)))
        second.toolManager.mouseDragged(event(Point(x: 5, y: 6)))
        second.window?.close()
        #expect(handles.released == [Point(x: 5, y: 6)] && second.toolManager.handleDrag == nil)
        // Through the app's documents: its own window; btn:[Done] closes it.
        let documents = DocumentController(environment: world.setup.environment.document)
        windows.documents = documents
        let third = try #require(windows.open(symbol, from: world.window))
        #expect(documents.windowControllers[third.documentHandle.id] === third && windows.documentWindow(of: third) === third)
        let done = try #require(third.window?.titlebarAccessoryViewControllers.compactMap { $0.view as? NSHostingView<SymbolWindowDoneButton> }.first)
        done.rootView.action()
        #expect(windows.windows.isEmpty && documents.windowControllers[third.documentHandle.id] == nil)
    }

    @Test func aRemoteEditOfTheSymbolAppearsLiveInItsWindow() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let (symbol, instance, masters) = try await Self.symbol(world)
        let windows = SymbolEditingWindows()
        let window = try #require(windows.open(symbol, from: world.window))
        defer { window.window?.close() }
        let before = try #require(window.documentHandle.object(for: SelectionID(masters[0]))?.bounds)
        // Someone else draws into the symbol and moves one of its objects; this person draws too.
        let remote = try #require(await world.document.receiveRemote(SymbolPlacedCommand(base: Self.rect(x: 160, y: 100), symbol: symbol)))
        _ = await world.document.receiveRemote(MoveObjects([masters[0]], by: Vector(dx: 0, dy: 20)))
        let mine = try #require(await window.documentHandle.perform(Self.rect(x: 100, y: 140)).value?.createdObjects.first)
        await world.document.settle()
        let theirs = try #require(remote.createdObjects.first)
        #expect(Set(window.documentHandle.scene.topLevel) == Set((masters + [theirs, mine]).map(NodeID.init)))
        #expect(window.documentHandle.object(for: SelectionID(masters[0]))?.bounds?.minY == before.minY + 20)
        #expect(world.document.object(for: SelectionID(instance)) != nil)
        // Without an open model nothing opens.
        let failing = DocumentHandle(title: "Pending") { () async throws -> WTModel.Document in throw CancellationError() }
        let pending = DocumentWindowController(document: failing, environment: world.setup.environment.document)
        defer { pending.close() }
        #expect(windows.open(symbol, from: pending) == nil)
    }
}
