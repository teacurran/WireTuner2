import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// "Extrude on an ellipse isn't working": a live ellipse centred on the page, extruded from the
/// menu or with the tool released inside it, used to write an extrusion whose vanishing point sat
/// inside the ellipse, so every side hid behind the front face (extrude.adoc, "Extruding").  Through
/// the real ToolManager and menu commands: the sides show (pixels outside the ellipse are
/// painted), the drag's preview is the drawing the release writes, each is one change and one undo.
@Suite(.serialized) @MainActor struct ExtrudeSolidTests {
    static let page = Rect(x: 0, y: 0, width: 400, height: 300)
    static let viewport = Viewport(size: Size(width: 400, height: 300))
    /// The ellipse: 160 × 100 about the page's centre (200, 150).
    static let ellipseRect = Rect(x: 120, y: 100, width: 160, height: 100)

    static var red: Wiretuner_Doc_V1_AppearanceProps {
        var appearance = Appearances.standard
        appearance.fills = [Appearances.basicFill(red: 0.9, green: 0.1, blue: 0.1)]
        return appearance
    }

    @MainActor
    final class World {
        let document = DocumentHandle.memory(title: "Solids")
        let host = RecordingHost(viewport: ExtrudeSolidTests.viewport)
        let controller: SelectionController
        let editing: ObjectEditing
        let manager: ToolManager

        init() {
            document.pages = [ExtrudeSolidTests.page]
            controller = SelectionController(document: document)
            editing = ObjectEditing(document: document, selection: controller)
            let registry = ToolRegistry()
            registry.registerBuiltIn()
            // As EffectFeatures installs it in the app.
            registry.replace(ExtrudeTool.descriptor)
            manager = ToolManager(registry: registry, context: ToolContext(document: document, host: host, selection: controller), focus: InspectorFocus())
        }

        func create(_ command: any WTModel.Command) async throws -> OpID {
            let node = try #require(await document.perform(command).value?.createdObjects.first)
            await document.settle()
            return node
        }

        func ellipse(_ appearance: Wiretuner_Doc_V1_AppearanceProps = ExtrudeSolidTests.red) async throws -> OpID {
            let rect = ExtrudeSolidTests.ellipseRect
            return try await create(CreateShape(.ellipse, size: rect.size, transform: .translation(x: rect.minX, y: rect.minY), appearance: appearance))
        }

        var tool: ExtrudeTool? { manager.activeTool as? ExtrudeTool }

        /// Presses at `from`, drags to `to` and releases, through the tool manager; answers the
        /// preview the tool showed just before the release.
        @discardableResult
        func drag(_ from: Point, _ to: Point) async -> ExtrudeTool.Placement? {
            manager.mouseDown(TestEvents.point(from.x, from.y))
            manager.mouseDragged(TestEvents.point((from.x + to.x) / 2, (from.y + to.y) / 2))
            manager.mouseDragged(TestEvents.point(to.x, to.y))
            let preview = tool?.preview()
            manager.drawOverlay(in: ExtrudeSolidTests.context(), viewport: ExtrudeSolidTests.viewport)
            manager.mouseUp(TestEvents.point(to.x, to.y))
            await document.settle()
            return preview
        }

        func extrusion(of node: OpID) -> OpID? { ExtrudeTool.extrusion(of: node, in: document.state) }

        func waitForSelection(_ kind: NodeKind) async -> OpID? {
            for _ in 0..<200 {
                if let id = controller.selection.ids.first, document.state.nodeKind(id.opID) == kind { return id.opID }
                await Task.yield()
            }
            return nil
        }

        /// What extrusion `wrapper` draws, by its written settings.
        func sides(_ wrapper: OpID) -> ExtrudeFit.Sides? {
            let child = document.state.liveChildren(wrapper).first.flatMap { document.item(for: SelectionID($0)) }
            return child.map { ExtrudeFit.sides(ExtrudeFields.spec(document.state.props(wrapper).extrude), child: $0) }
        }
    }

    static func context() -> CGContext {
        CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 400 * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// `item` rasterized over transparency, RGBA rows.
    static func pixels(_ item: DisplayItem) -> [UInt8] {
        let ctx = context()
        CoreGraphicsRenderer(background: nil).render(DisplayList(canvas: "extrude-solid", items: [item]), viewport: viewport, into: ctx)
        return pixels(ctx)
    }

    static func pixels(_ ctx: CGContext) -> [UInt8] {
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: 400 * 300 * 4))
    }

    /// Painted pixels more than 2 pt outside the ellipse: the sides (the image is symmetric about
    /// the ellipse's centre row, so the bitmap's row order does not matter).
    static func outsidePixels(_ pixels: [UInt8]) -> Int {
        var count = 0
        for y in 0..<300 {
            for x in 0..<400 where pixels[(y * 400 + x) * 4 + 3] > 128 {
                let dx = (Double(x) + 0.5 - 200) / 82, dy = (Double(y) + 0.5 - 150) / 52
                if dx * dx + dy * dy > 1 { count += 1 }
            }
        }
        return count
    }

    @Test func modifyExtrudeOnACentredEllipseShowsTheSides() async throws {
        let world = World()
        let ellipse = try await world.ellipse()
        world.controller.model.set(Selection([SelectionID(ellipse)]))
        let commands = ExtrudeMenu.commands(target: { world.editing }, tools: { world.manager })
        let changes = world.document.changeCount
        if case .perform(let action) = try #require(commands.first { $0.id == ExtrudeMenu.ID.extrude }).action { action() }
        let wrapper = try #require(await world.waitForSelection(.extrude))
        await world.document.settle()
        #expect(world.document.changeCount == changes + 1 && world.document.undoTitle == "Undo Extrude")
        // Not the page's centre (the ellipse's own): just above right of the ellipse.
        let vanishing = world.document.state.props(wrapper).extrude.vanishingPoint
        #expect(vanishing.x > Self.ellipseRect.maxX && vanishing.y < Self.ellipseRect.minY)
        #expect(world.host.messages.last == ExtrudeMenu.movedMessage)
        #expect(world.sides(wrapper) == .visible)
        let item = try #require(world.document.item(for: SelectionID(wrapper)))
        #expect(Self.outsidePixels(Self.pixels(item)) > 300, "the sides are painted beyond the front face")
        #expect(world.document.state.nodeKind(ellipse) == .ellipse, "the ellipse stays a live ellipse")
        #expect(AttributesListModel(document: world.document, selection: Selection([SelectionID(wrapper)])).rootTitle == "Extrusion")
        // One undo: the flat ellipse again.
        _ = await world.document.undo().value
        await world.document.settle()
        #expect(world.extrusion(of: ellipse) == nil && !world.document.state.isLive(wrapper) && world.document.state.isLive(ellipse))
        // Off the page's centre the menu still points at the page's centre, without a word.
        let rect = try await world.create(CreateShape(.rectangle(CornerRadii()), size: Size(width: 40, height: 40), transform: .translation(x: 20, y: 20), appearance: Self.red))
        world.controller.model.set(Selection([SelectionID(rect)]))
        let messages = world.host.messages.count
        _ = await ExtrudeMenu.extrude(world.editing, host: world.host)?.value
        let square = try #require(world.extrusion(of: rect))
        let toward = world.document.state.props(square).extrude.vanishingPoint
        #expect(toward.x == 200 && toward.y == 150 && world.host.messages.count == messages)
    }

    @Test func theToolReleasedInsideACentredEllipseShowsTheSidesItPreviewed() async throws {
        let world = World()
        let ellipse = try await world.ellipse()
        world.manager.select(ExtrudeTool.id)
        #expect(world.tool != nil)
        let changes = world.document.changeCount
        // From the centre, released inside the ellipse to the right and a little up.
        let preview = try #require(await world.drag(Point(x: 200, y: 150), Point(x: 240, y: 140)))
        let wrapper = try #require(await world.waitForSelection(.extrude))
        await world.document.settle()
        #expect(world.document.changeCount == changes + 1 && world.document.undoTitle == "Undo Extrude")
        #expect(preview.moved && preview.sides == .visible && world.host.messages.last == ExtrudeTool.movedMessage)
        // Moved along the drag, off the ellipse.
        let vanishing = world.document.state.props(wrapper).extrude.vanishingPoint
        #expect(Point(x: vanishing.x, y: vanishing.y) == preview.vanishingPoint && vanishing.x > Self.ellipseRect.maxX && vanishing.y < 150)
        #expect(world.sides(wrapper) == .visible)
        // The preview is the drawing the release wrote.
        let committed = Self.pixels(try #require(world.document.item(for: SelectionID(wrapper))))
        let previewed = Self.pixels(preview.preview)
        #expect(Self.outsidePixels(committed) > 300)
        let differing = zip(committed, previewed).filter { abs(Int($0) - Int($1)) > 2 }.count
        #expect(differing == 0, "\(differing) bytes differ")
        _ = await world.document.undo().value
        await world.document.settle()
        #expect(world.extrusion(of: ellipse) == nil && world.document.state.nodeKind(ellipse) == .ellipse)
        // Released well off the ellipse: exactly there, no word.
        world.controller.model.set(Selection([]))
        let messages = world.host.messages.count
        let far = try #require(await world.drag(Point(x: 200, y: 150), Point(x: 380, y: 20)))
        let again = try #require(await world.waitForSelection(.extrude))
        let there = world.document.state.props(again).extrude.vanishingPoint
        #expect(!far.moved && there.x == 380 && there.y == 20)
        #expect(world.host.messages.count == messages)
    }

    @Test func pressesThatMissOrStopShortSaySo() async throws {
        let world = World()
        // Unfilled: only its stroke hits.
        let ellipse = try await world.ellipse(Appearances.standard)
        world.manager.select(ExtrudeTool.id)
        let changes = world.document.changeCount
        // A drag off every object.
        await world.drag(Point(x: 20, y: 20), Point(x: 90, y: 60))
        #expect(world.document.changeCount == changes && world.host.messages.last == ExtrudeTool.missedMessage)
        // A click on the stroke selects and says to drag.
        world.manager.mouseDown(TestEvents.point(120, 150))
        world.manager.mouseUp(TestEvents.point(121, 150))
        await world.document.settle()
        #expect(world.document.changeCount == changes && world.host.messages.last == ExtrudeTool.tooShortMessage)
        #expect(world.controller.selection.ids == [SelectionID(ellipse)])
        // Selected, a press inside the unfilled ellipse extrudes it.
        await world.drag(Point(x: 200, y: 150), Point(x: 380, y: 20))
        let wrapper = try #require(await world.waitForSelection(.extrude))
        #expect(world.document.changeCount == changes + 1 && world.extrusion(of: ellipse) == wrapper && world.sides(wrapper) == .visible)
        // A plain click off everything deselects without a word.
        let messages = world.host.messages.count
        world.manager.mouseDown(TestEvents.point(10, 290))
        world.manager.mouseUp(TestEvents.point(10, 290))
        #expect(world.controller.selection.isEmpty && world.host.messages.count == messages)
    }

    @Test func everyKindOfObjectExtrudesIntoASolid() async throws {
        let world = World()
        world.manager.select(ExtrudeTool.id)
        // Laid out apart, so each press lands on the one it means.
        let rect = try await world.create(CreateShape(.rectangle(CornerRadii()), size: Size(width: 60, height: 40), transform: .translation(x: 20, y: 20), appearance: Self.red))
        let polygon = try await world.create(CreatePolygon(PolygonShape(sides: 6, radius: 30), center: Point(x: 150, y: 50), appearance: Self.red))
        let closed = try #require(await world.document.addPath([Point(x: 220, y: 20), Point(x: 280, y: 20), Point(x: 250, y: 80)], closed: true, filled: true))
        let parts = await world.document.addRectangles([Rect(x: 300, y: 20, width: 30, height: 40), Rect(x: 350, y: 20, width: 30, height: 40)])
        let group = try await world.create(GroupObjects(parts.map(\.opID)))
        let text = try #require(await world.document.addText("Wire", at: Point(x: 40, y: 150)))
        for node in [rect, polygon, closed.opID, group, text] {
            // Each selected and pressed at its centre (inside the selection's bounds), released on it.
            world.controller.model.set(Selection([SelectionID(node)]))
            let center = try #require(world.document.object(for: SelectionID(node))?.bounds).center
            let changes = world.document.changeCount
            await world.drag(center, center + Vector(dx: 4, dy: -3))
            let wrapper = try #require(world.extrusion(of: node), "\(String(describing: world.document.state.nodeKind(node)))")
            #expect(world.document.changeCount == changes + 1 && world.sides(wrapper) == .visible, "\(node)")
            _ = await world.document.undo().value
            await world.document.settle()
            #expect(world.extrusion(of: node) == nil)
        }
        // An open path has nothing closed to extrude: written, and the HUD says it draws flat.
        let line = try #require(await world.document.addPath([Point(x: 200, y: 250), Point(x: 240, y: 230), Point(x: 280, y: 250)]))
        world.controller.model.set(Selection([line]))
        await world.drag(Point(x: 240, y: 245), Point(x: 380, y: 280))
        let flat = try #require(world.extrusion(of: line.opID))
        #expect(world.sides(flat) == ExtrudeFit.Sides.none && world.host.messages.last == ExtrudeTool.flatMessage)
        world.controller.model.set(Selection([SelectionID(flat)]))
        #expect(ExtrudeMenu.message(world.editing, vanishingPoint: Point(x: 200, y: 150)) == ExtrudeTool.flatMessage)
    }
}
