import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// A document with a selection and a tool context whose view shows the pasteboard at 100% from
/// the origin (view point = pasteboard point), for the canvas handles.
@MainActor
final class HandleWorld {
    let document = DocumentHandle.memory(title: "Handles")
    let host = RecordingHost(viewport: Viewport(size: Size(width: 800, height: 600)))
    let selection: SelectionController
    let context: ToolContext

    init() {
        selection = SelectionController(document: document)
        context = ToolContext(document: document, host: host, selection: selection)
    }

    var state: EngineState { document.state }

    func select(_ ids: [OpID]) { selection.model.set(Selection(ids.map { SelectionID($0) })) }

    func event(_ x: Double, _ y: Double, _ modifiers: KeyModifiers = [], clicks: Int = 1) -> CanvasEvent {
        CanvasEvent(pasteboardPoint: Point(x: x, y: y), viewPoint: Point(x: x, y: y), modifiers: modifiers, clickCount: clicks)
    }

    func bitmap() -> CGContext {
        CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    func settle() async {
        await document.settle()
        for _ in 0..<20 { await Task.yield() }
        await document.settle()
    }

    /// A 40 × 20 pixel image at 72 ppi.
    func placeImage() async throws -> OpID {
        try await Self.place(in: document)
    }

    static func place(in document: DocumentHandle) async throws -> OpID {
        var pixels = Wiretuner_Doc_V1_PixelSource()
        pixels.blobSha256 = Data(repeating: 0xAB, count: 32)
        pixels.format = "public.png"
        pixels.pixelWidth = 40
        pixels.pixelHeight = 20
        pixels.mode = .rgb
        pixels.bitsPerChannel = 8
        let node = try #require(await document.perform(PlaceImage(pixels, name: "photo.png", dpiX: 72, dpiY: 72)).value?.createdObjects.first)
        await document.settle()
        return node
    }

    /// A clip group: a 40 pt square at (10, 10) clipping a 60 pt square at the origin.  Returns the
    /// group and its content.
    func clipGroup() async throws -> (group: OpID, content: OpID) {
        let clip = try #require(await document.addRectangles([Rect(x: 10, y: 10, width: 40, height: 40)]).first).opID
        let content = try #require(await document.addRectangles([Rect(x: 0, y: 0, width: 60, height: 60)]).first).opID
        let payload = ClipboardPayload(copying: [content], from: state)
        _ = await document.perform(CutObjects([content])).value
        let group = try #require(await document.perform(PasteContents(payload, into: clip)).value?.createdObjects.first)
        await settle()
        return (group, ClipGroups.contents(of: group, in: state)[0])
    }
}

/// OBJ-028's contents handle, DRAW-010's polygon handles, IMG-004's Option-drag resizing,
/// OBJ-042's Select Similar and OBJ-025's Combine.
@Suite(.serialized) @MainActor struct ObjectGlueTests {
    // MARK: Contents handle

    @Test func theContentsHandleSlidesTheContentsInOneChange() async throws {
        let world = HandleWorld()
        let (group, content) = try await world.clipGroup()
        let layer = ClipContentsHandle()
        #expect(ClipContentsHandle.handle(world.context) == nil, "nothing selected")
        world.select([group])
        #expect(ClipContentsHandle.handle(world.context) == nil, "the Contents row is not selected")
        world.selection.model.selectContentsRow(group)
        let handle = try #require(ClipContentsHandle.handle(world.context))
        #expect(handle.group == group && handle.position == Point(x: 30, y: 30), "the centre of the contents")
        layer.draw(in: world.bitmap(), viewport: world.host.viewport, context: world.context)
        #expect(!layer.press(world.event(100, 100), context: world.context), "away from the handle")
        #expect(layer.press(world.event(30, 30), context: world.context))
        layer.drag(world.event(40, 35), context: world.context)
        layer.draw(in: world.bitmap(), viewport: world.host.viewport, context: world.context)
        layer.release(world.event(40, 35), context: world.context)
        await world.settle()
        #expect(Objects.bounds(of: content, in: world.state) == Rect(x: 10, y: 5, width: 60, height: 60))
        #expect(world.document.undoTitle == "Undo Move contents")
        // A release where it started, or a cancelled drag, writes nothing.
        #expect(layer.press(world.event(40, 35), context: world.context))
        layer.release(world.event(40, 35), context: world.context)
        #expect(layer.press(world.event(40, 35), context: world.context))
        layer.cancel(context: world.context)
        layer.release(world.event(90, 90), context: world.context)
        await world.settle()
        #expect(world.document.undoTitle == "Undo Move contents")
        // A double-click subselects everything inside.
        #expect(layer.press(world.event(40, 35, clicks: 2), context: world.context))
        #expect(world.selection.selection.ids.map(\.opID) == [content])
        #expect(ClipContentsHandle.handle(world.context) == nil, "a member selected: no handle")
        #expect(world.selection.model.contentsRow == nil, "another selection deselects the row")
        world.selection.model.selectContentsRow(group)
        #expect(world.selection.model.contentsRow == nil, "only the selected group's row can be selected")
    }

    // MARK: Polygon handles

    @Test func thePolygonHandlesDragTheRadiusAndTheInnerPoints() async throws {
        let world = HandleWorld()
        let star = PolygonShape(sides: 5, star: true, radius: 50, innerRadius: 20)
        let node = try #require(await world.document.perform(CreatePolygon(star, center: Point(x: 100, y: 100))).value?.createdObjects.first)
        await world.settle()
        world.select([node])
        let layer = PolygonShapeHandles()
        #expect(layer.polygons(world.context).isEmpty, "no tool: no handles")
        layer.draw(in: world.bitmap(), viewport: world.host.viewport, context: world.context)
        #expect(!layer.press(world.event(150, 100), context: world.context))
        let tool = TestBox<ToolID>(PointerTool.subselectID)
        layer.activeTool = { tool.value }
        #expect(layer.polygons(world.context).isEmpty, "the Subselect tool: the points, no handles (D-078)")
        tool.value = PolygonShapeHandles.tool
        #expect(layer.polygons(world.context) == [node])
        layer.draw(in: world.bitmap(), viewport: world.host.viewport, context: world.context)
        let positions = try #require(PolygonHandles.positions(of: node, in: world.state))
        #expect(positions.peak == Point(x: 150, y: 100))
        // The diamond, with Shift keeping the angle: only the radius.
        #expect(layer.press(world.event(150, 100), context: world.context))
        layer.drag(world.event(170, 100, [.shift]), context: world.context)
        layer.release(world.event(180, 100, [.shift]), context: world.context)
        await world.settle()
        #expect(world.state.props(node).polygon.radius == 80)
        #expect(world.document.undoTitle.hasPrefix("Undo"))
        _ = await world.document.undo().value
        #expect(world.state.props(node).polygon.radius == 50, "the drag is one undo step")
        // The circle: the inner radius.
        let valley = try #require(positions.valley)
        #expect(layer.press(world.event(valley.x, valley.y), context: world.context))
        layer.release(world.event(valley.x * 0.5 + 50, valley.y * 0.5 + 50), context: world.context)
        await world.settle()
        #expect(world.state.props(node).polygon.innerRadius < 20 && !world.state.props(node).polygon.autoInner)
        // Esc during a drag undoes what it wrote.
        #expect(layer.press(world.event(150, 100), context: world.context))
        layer.drag(world.event(200, 100), context: world.context)
        await world.settle()
        layer.cancel(context: world.context)
        await world.settle()
        #expect(world.state.props(node).polygon.radius == 50)
        layer.cancel(context: world.context)
        layer.drag(world.event(0, 0), context: world.context)
    }

    // MARK: Option-drag resizing

    @Test func optionDraggingAnImageCornerSnapsToPrinterResolutionSteps() async throws {
        let world = HandleWorld()
        let node = try await world.placeImage()
        let layer = ImageResolutionHandles()
        #expect(ImageResolutionHandles.image(world.context) == nil)
        world.select([node])
        let corners = try #require(ImageResolutionHandles.corners(of: node, in: world.state))
        let far = corners[2], near = corners[0]
        #expect(!layer.press(world.event(far.x, far.y), context: world.context), "without Option the Pointer's")
        #expect(!layer.press(world.event(far.x + 50, far.y + 50, [.option]), context: world.context), "away from a corner")
        layer.draw(in: world.bitmap(), viewport: world.host.viewport, context: world.context)
        #expect(layer.press(world.event(far.x, far.y, [.option]), context: world.context))
        // 72 ppi on a 300 dpi document: the steps are 96%, 48%, 32% ... and 192%, 288% ....
        let doubled = Point(x: near.x + (far.x - near.x) * 2, y: near.y + (far.y - near.y) * 2)
        layer.drag(world.event(doubled.x, doubled.y, [.option]), context: world.context)
        #expect(abs((layer.dragging?.factor ?? 0) - 1.92) < 1e-9)
        layer.draw(in: world.bitmap(), viewport: world.host.viewport, context: world.context)
        layer.release(world.event(doubled.x, doubled.y, [.option]), context: world.context)
        await world.settle()
        #expect(abs((ImageResolution.scale(of: node, in: world.state) ?? 0) - 1.92) < 1e-9)
        let moved = try #require(ImageResolutionHandles.corners(of: node, in: world.state))
        #expect(moved[0].distance(to: near) < 1e-6, "scaled about the opposite corner")
        // Dragged back onto the corner where it started: no change; Esc abandons.
        let grown = moved[2]
        #expect(layer.press(world.event(grown.x, grown.y, [.option]), context: world.context))
        layer.release(world.event(grown.x, grown.y, [.option]), context: world.context)
        #expect(layer.press(world.event(grown.x, grown.y, [.option]), context: world.context))
        layer.cancel(context: world.context)
        layer.release(world.event(0, 0), context: world.context)
        layer.drag(world.event(0, 0), context: world.context)
        await world.settle()
        #expect(abs((ImageResolution.scale(of: node, in: world.state) ?? 0) - 1.92) < 1e-9)
        #expect(ImageResolutionHandles.factor(.init(node: node, corner: near, anchor: near, scale: 1), to: far, in: world.state) == 1)
        #expect(ImageResolutionHandles.corners(of: OpID(counter: 9, replica: 9), in: world.state) == nil)
    }

    // MARK: Select Similar

    struct Squares: ShapeClassifying {
        func shapeClass(of node: OpID, in state: EngineState) -> String? { "square" }
    }

    @Test func selectSimilarSelectsLikeObjectsOnThePageAndCountsThem() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let features = SelectSimilarCommands(window: { [weak window = world.window] in window })
        features.install(commands: world.commands)
        let origin = world.document.activePage.origin
        let filled = await world.document.addRectangles((0..<3).map { Rect(x: origin.x + Double($0) * 50, y: origin.y + 20, width: 20, height: 20) })
        let plain = try #require(await world.document.addRectangles([Rect(x: origin.x + 200, y: origin.y + 20, width: 20, height: 20)], filled: false).first)
        let fill = SelectSimilarCommands.id(.fill)
        #expect(world.commands.validate(fill) == .disabled(SelectSimilarCommands.needsOne))
        world.select([filled[0].opID])
        #expect(world.commands.validate(fill) == .enabled)
        features.shiftDown = { false }
        #expect(world.commands.perform(fill))
        #expect(Set(world.window.selection.model.ids) == Set(filled))
        #expect(world.window.statusBar.message.stringValue == "3 objects selected")
        // Shift adds to the selection.
        world.select([plain.opID])
        features.shiftDown = { true }
        let outcome = try #require(features.run(.stroke, in: world.window, adding: true))
        #expect(outcome.selection.first == plain.opID && outcome.found == 4)
        world.select([filled[1].opID])
        #expect(world.commands.perform(SelectSimilarCommands.id(.fillAndStroke)))
        #expect(world.window.selection.model.ids.count == 3, "Shift held: the filled squares added")
        #expect(world.commands.command(SelectSimilarCommands.id(.shape)) == nil, "no classifier: no Shape item")
        // Two selected: disabled, and running does nothing.
        world.select(filled.map(\.opID))
        #expect(features.run(.fill, in: world.window, adding: false) == nil)
        #expect(SelectSimilarCommands.page(of: world.document) == world.document.activePage.id)
        let pageless = DocumentHandle(title: "None", model: WTModel.Document(memory: DocumentTemplate.core(replica: 4)))
        #expect(SelectSimilarCommands.page(of: pageless) == nil)
        let classified = SelectSimilarCommands(window: { nil })
        classified.classifier = Squares()
        #expect(classified.commands().count == 4 && classified.commands().allSatisfy { !$0.validation().isEnabled })
        if case .perform(let run) = classified.commands()[0].action { run() }
    }

    // MARK: Combine

    @Test func combineBuildsFromTheSelectedPathsAndShiftKeepsTheOriginals() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let features = CombineCommands(target: world.target, store: world.preferences)
        let extensions = ExtensionRegistry()
        world.commands.replace(Command(id: ContextMenuCatalog.ID.union, title: "Union", contexts: [.path], action: .perform(Command.noop)))
        features.install(commands: world.commands, extensions: extensions)
        #expect(world.commands.command(ContextMenuCatalog.ID.union)?.contexts == [.path], "the catalog's context menus stay")
        let union = ContextMenuCatalog.ID.union
        features.shiftDown = { false }
        #expect(world.commands.validate(union) == CommandValidation(isEnabled: false, reason: CombineCommands.needsClosed, title: "Union"))
        #expect(world.commands.validate(ContextMenuCatalog.ID.divide)?.reason == CombineCommands.needsTwo)
        let squares = await world.document.addRectangles([Rect(x: 0, y: 0, width: 40, height: 40), Rect(x: 20, y: 20, width: 40, height: 40)])
        world.select(squares.map(\.opID))
        #expect(world.commands.validate(union) == CommandValidation(title: "Union"))
        features.shiftDown = { true }
        #expect(world.commands.validate(union)?.title == "Union (keep originals)")
        _ = await features.perform(.union)?.value
        await world.document.settle()
        #expect(squares.allSatisfy { world.state.isLive($0.opID) }, "Shift kept the originals")
        #expect(world.document.undoTitle == "Undo Union 2 paths")
        // The toolbar's button: consumed this time.
        world.select(squares.map(\.opID))
        features.shiftDown = { false }
        let button = try #require(extensions.descriptor(for: "intersect"))
        #expect(button.validate?() == CommandValidation(title: "Intersect"))
        #expect(button.run?(nil) == nil)
        await world.document.settle()
        for _ in 0..<20 { await Task.yield() }
        #expect(squares.allSatisfy { !world.state.isLive($0.opID) })
        #expect(world.window.selection.model.ids.count == 1, "the result is selected")
        // Nothing to combine, no window.
        #expect(features.perform(.crop) == nil)
        let orphan = CombineCommands(target: { nil }, store: world.preferences)
        #expect(orphan.validation(.punch).reason == ViewCommands.noDocument && orphan.perform(.punch) == nil)
        _ = world.commands.perform(ContextMenuCatalog.ID.crop)
    }
}
