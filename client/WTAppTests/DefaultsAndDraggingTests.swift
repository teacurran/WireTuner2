import AppKit
import Testing
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The document defaults in the app -- the tools, the wells, *Changing object changes defaults*
/// (OBJ-037) -- and Option-drag copying and dragging objects between windows (OBJ-013).
@Suite(.serialized) @MainActor struct DefaultsAndDraggingTests {
    static let red = RenderColor(red: 1, green: 0, blue: 0)
    static let redRef = ColorResolver.inline(RenderColor(red: 1, green: 0, blue: 0))
    static let blueRef = ColorResolver.inline(RenderColor(red: 0, green: 0, blue: 1))

    // MARK: OBJ-037

    @Test func theWellsShowTheDocumentDefaultsUntilACurrentColourIsChosen() {
        let palette = ToolPaletteModel()
        #expect(palette.wells == .standard && palette.currentChoices.fill == nil)
        palette.documentWells = WellColors(stroke: .solid(Color(white: 0)), fill: .none)
        palette.documentChoices = (.noColor, .color(ColorResolver.inline(Color(white: 0))))
        #expect(palette.wells.fill == .none)
        palette.swapWells()
        #expect(palette.currentChoices.fill == .color(ColorResolver.inline(Color(white: 0))) && palette.currentChoices.stroke == .noColor)
        #expect(palette.wells.fill == .solid(Color(white: 0)) && palette.wells.stroke == .none)
        palette.restoreDefaultWells()
        #expect(palette.currentChoices.fill == nil && palette.currentChoices.stroke == nil, "Default follows the document again")
        palette.choose(Self.redRef, color: Self.red, for: .fill)
        #expect(palette.currentChoices.fill == .color(Self.redRef) && palette.wells.fill == .solid(Self.red))
        palette.choose(ColorResolver.none, for: .stroke)
        #expect(palette.currentChoices.stroke == .noColor)
        palette.activeWell = .fill
        palette.setActiveWellToNone()
        #expect(palette.currentChoices.fill == .noColor)
        // Without the document's choices a swap takes the colours as shown.
        palette.restoreDefaultWells()
        palette.documentChoices = nil
        palette.documentWells = nil
        palette.swapWells()
        #expect(palette.currentChoices.stroke == .color(ColorResolver.inline(Color(white: 1))))
        #expect(CurrentColor(.none, choice: nil).choice == .noColor)
    }

    @Test func theDocumentDefaultsReadAsWellColours() async {
        let document = DocumentHandle.memory(title: "Defaults")
        #expect(WellColors.defaults(in: document.state).wells == WellColors(stroke: .solid(Color(white: 0)), fill: .none))
        _ = await document.perform(AddAppearance.fill([WellKnown.settings], Appearances.basicFill(red: 1, green: 0, blue: 0))).value
        let defaults = WellColors.defaults(in: document.state)
        #expect(defaults.wells.fill == .solid(Self.red))
        if case .color = defaults.choices.fill {} else { Issue.record("the fill is a colour") }
    }

    @Test func newObjectsGetTheDefaultsWithTheCurrentColours() async throws {
        let environment = TestEnvironment()
        var document = environment.document
        document.currentColors = { (.color(Self.redRef), nil) }
        let handle = DocumentHandle.memory(title: "New objects")
        let controller = DocumentWindowController(document: handle, environment: document)
        defer { controller.close() }
        let appearance = controller.toolManager.context.newObjectAppearance()
        #expect(appearance.fills.map(\.settings.basic.color) == [Self.redRef] && appearance.strokes.count == 1)
        // The plain context reads the defaults alone.
        let plainHost = RecordingHost()
        let plain = ToolContext(document: handle, host: plainHost)
        #expect(plain.newObjectAppearance() == Appearances.standard)
        withExtendedLifetime(plainHost) {}
        // A rectangle drawn by the tool carries them.
        let tool = RectangleTool()
        tool.activate(in: controller.toolManager.context)
        tool.mouseDown(TestEvents.point(10, 10))
        tool.mouseDragged(TestEvents.point(60, 60))
        tool.mouseUp(TestEvents.point(60, 60))
        await handle.settle()
        let rect = try #require(handle.selectableIDs().last)
        #expect(handle.state.props(rect.opID).rect.appearance.fills.map(\.settings.basic.color) == [Self.redRef])
        // The wells follow a change of the defaults.
        var viewChanges = 0
        controller.onViewStateChange = { _ in viewChanges += 1 }
        _ = await handle.perform(AddAppearance.fill([WellKnown.settings])).value
        #expect(viewChanges == 1)
        #expect(controller.documentWells.wells.fill == .solid(Color(white: 0)))
    }

    @Test func everyDrawingToolUsesTheNewObjectAppearance() async throws {
        let handle = DocumentHandle.memory(title: "Tools")
        let host = RecordingHost(viewport: SelectionFixture.viewport)
        var context = ToolContext(document: handle, host: host)
        var look = Appearances.standard
        look.fills = [Appearances.basicFill(red: 0, green: 0, blue: 1)]
        context.newObjectAppearance = { look }
        let sink = RecordingSink()
        context.commandSink = sink
        for tool in [EllipseTool(), LineTool()] as [ShapeDragTool] {
            tool.activate(in: context)
            tool.mouseDown(TestEvents.point(10, 10))
            tool.mouseDragged(TestEvents.point(60, 60))
            tool.mouseUp(TestEvents.point(60, 60))
        }
        let polygon = PolygonTool()
        polygon.activate(in: context)
        #expect(polygon.newObjectAppearance == look)
        let inactive = PolygonTool()
        #expect(inactive.newObjectAppearance == Appearances.standard)
        let appearances = sink.commands.compactMap { ($0 as? CreateShape)?.appearance ?? ($0 as? CreatePath)?.appearance }
        #expect(appearances.count == 2 && appearances.allSatisfy { $0 == look })
    }

    @Test func changingAnObjectChangesTheDefaultsWhenThePreferenceIsOn() async throws {
        let environment = TestEnvironment()
        let fixture = await SelectionFixture.make()
        let controller = DocumentWindowController(document: fixture.document, environment: environment.document)
        defer { controller.close() }
        let document = fixture.document
        _ = await document.perform(AddAppearance.fill([fixture.square.opID])).value
        #expect(document.undoTitle == "Undo Add Fill")
        #expect(DocumentDefaults.appearance(in: document.state) == Appearances.standard)
        environment.preferences.set(true, for: PreferenceCatalog.Object.changeSetsDefaults)
        _ = await document.perform(AddAppearance.fill([fixture.square.opID], Appearances.basicFill(red: 1, green: 0, blue: 0))).value
        #expect(document.undoTitle == "Undo Add Fill (and defaults)")
        #expect(DocumentDefaults.appearance(in: document.state).fills.count == 2)
    }

    // MARK: OBJ-013

    @Test func optionDragShowsThePlusSignAndOptionAfterTheDragBeginsStillCopies() async throws {
        let f = await PointerMoveTests.Fixture.make()
        f.tool.mouseDown(TestEvents.point(30, 30))
        f.tool.mouseDragged(TestEvents.point(50, 40))
        #expect(!f.tool.isCopying && f.tool.cursor == .arrow)
        let before = f.host.cursorChanges
        f.tool.flagsChanged(TestEvents.point(0, 0, .option))
        #expect(f.tool.isCopying && f.tool.cursor == .dragCopy)
        #expect(f.host.cursorChanges == before + 1)
        f.tool.mouseUp(TestEvents.point(50, 40, .option))
        await f.document.settle()
        #expect(f.document.undoTitle == "Undo Copy", "Option pressed after the drag began copies")
        #expect(f.host.cursorChanges == before + 2, "the plus sign goes when the drag ends")
        // Released before the drop: a move.
        f.tool.mouseDown(TestEvents.point(30, 30, .option))
        f.tool.mouseDragged(TestEvents.point(50, 40, .option))
        #expect(f.tool.isCopying)
        f.tool.flagsChanged(TestEvents.point(0, 0))
        #expect(!f.tool.isCopying)
        f.tool.mouseUp(TestEvents.point(50, 40))
        await f.document.settle()
        #expect(f.document.undoTitle == "Undo Move")
        // With *Option-drag copies* off there is no plus sign.
        let off = await PointerMoveTests.Fixture.make(optionCopies: false)
        off.tool.mouseDown(TestEvents.point(30, 30, .option))
        off.tool.mouseDragged(TestEvents.point(50, 40, .option))
        #expect(!off.tool.isCopying)
    }

    @Test func draggingItemsCarryTheObjectsAndAPDFPromise() async throws {
        let fixture = await SelectionFixture.make()
        let editing = ObjectEditing(document: fixture.document, selection: SelectionController(document: fixture.document))
        let dragging = ObjectDragging(editing: editing)
        let frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        #expect(dragging.payload() == nil && dragging.draggingItems(image: nil, frame: frame).isEmpty)
        #expect(dragging.begin(with: NSEvent(), from: NSView()) == nil)
        editing.selection.model.set(Selection([fixture.a]))
        #expect(dragging.draggingItems(image: nil, frame: frame).count == 1, "no PDF without a writer")
        dragging.writePDF = { _ in true }
        let items = dragging.draggingItems(image: nil, frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        #expect(items.count == 2)
        let objects = try #require(items[0].item as? NSPasteboardItem)
        #expect(objects.data(forType: ObjectDragging.type).flatMap { ClipboardPayload(decoding: Array($0)) }?.isEmpty == false)
        let promise = try #require(items[1].item as? PDFPromise)
        #expect(promise.fileType == UTType.pdf.identifier)
        #expect(promise.filePromiseProvider(promise, fileNameForType: UTType.pdf.identifier) == "Selection objects.pdf")
        #expect(ObjectDragging.operation == .copy)
    }

    @Test func thePromiseWritesThroughTheWriterAndReportsFailure() async throws {
        final class Box: @unchecked Sendable {
            var urls: [URL] = []
            var errors: [(any Error)?] = []
        }
        let box = Box()
        let url = URL(fileURLWithPath: "/tmp/objects.pdf")
        let written = PDFPromise(name: "A") { url in
            box.urls.append(url)
            return true
        }
        written.filePromiseProvider(written, writePromiseTo: url) { box.errors.append($0) }
        let failing = PDFPromise(name: "B") { _ in false }
        failing.filePromiseProvider(failing, writePromiseTo: url) { box.errors.append($0) }
        #expect(await eventually { box.errors.count == 2 })
        #expect(box.urls == [url])
        #expect(box.errors.filter { $0 == nil }.count == 1 && box.errors.contains { $0 is PDFPromise.Failed })
    }

    @Test func objectsDroppedOnAWindowArePastedAtTheDropPointAndSelected() async throws {
        let environment = TestEnvironment()
        let source = await SelectionFixture.make()
        let target = DocumentHandle.memory(title: "Target")
        let controller = DocumentWindowController(document: target, environment: environment.document)
        defer { controller.close() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("wiretuner.test.objectdrag.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let canvas = controller.canvas
        #expect(canvas.draggingUpdated(PasteboardDragging(pasteboard, at: .zero)) == [], "nothing on the pasteboard")
        pasteboard.clearContents()
        pasteboard.setData(Data(ClipboardPayload(copying: [source.a.opID], from: source.document.state, document: source.document.id).encoded()),
                           forType: ObjectDragging.type)
        #expect(ObjectDragging.carriesObjects(pasteboard))
        let location = canvas.convert(NSPoint(x: 200, y: canvas.bounds.height - 150), to: nil)
        let drag = PasteboardDragging(pasteboard, at: location)
        #expect(canvas.draggingUpdated(drag) == .copy)
        #expect(canvas.performDragOperation(drag))
        await target.settle()
        #expect(await eventually { controller.selection.model.count == 1 })
        let pasted = try #require(controller.selection.model.ids.first)
        let bounds = try #require(target.object(for: pasted)?.bounds)
        let expected = canvas.viewport.toPasteboard(Point(x: 200, y: 150))
        #expect(abs(bounds.center.x - expected.x) < 1 && abs(bounds.center.y - expected.y) < 1, "centred on the drop point")
        #expect(source.document.selectableIDs().count == 4, "the source is untouched")
        // A canvas without a drop target refuses objects; an empty payload pastes nothing.
        canvas.objectDrop = nil
        #expect(canvas.draggingUpdated(drag) == [] && !canvas.performDragOperation(drag))
        pasteboard.clearContents()
        pasteboard.setData(Data(), forType: ObjectDragging.type)
        #expect(controller.objectDragging.drop(pasteboard, at: .zero) == nil)
    }

    @Test func onlyAMoveThatLeavesTheWindowBecomesADrag() async throws {
        let environment = TestEnvironment()
        SelectionCommands.install(commands: environment.commands, tools: environment.tools)
        let fixture = await SelectionFixture.make()
        let controller = DocumentWindowController(document: fixture.document, environment: environment.document)
        defer { controller.close() }
        let window = try #require(controller.window)
        let outside = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: -50, y: -50), modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let inside = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        #expect(controller.canvas.leftWindow(outside) && !controller.canvas.leftWindow(inside))
        #expect(!CanvasView(document: fixture.document).leftWindow(outside), "a canvas outside a window never leaves it")
        #expect(!controller.beginObjectDrag(outside), "no move in progress")
        #expect(controller.canvas.onDragOut?(outside) == false)
        controller.canvas.mouseDragged(with: outside)
    }
}
