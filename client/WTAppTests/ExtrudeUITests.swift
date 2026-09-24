import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// FX-020 and FX-021: the Extrude tool's drag, handles and rotate mode, the menu:Modify[Extrude]
/// commands, and the Object panel's Extrude, Surface and Profile pages.
@Suite @MainActor struct ExtrudeUITests {
    static let viewport = Viewport(size: Size(width: 400, height: 300))

    static func context() -> CGContext {
        CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    @MainActor
    final class Fixture {
        let document = DocumentHandle.memory(title: "Extrusions")
        let host = RecordingHost(viewport: ExtrudeUITests.viewport)
        let controller: SelectionController
        let editing: ObjectEditing
        let tool = ExtrudeTool()
        var squares: [SelectionID] = []

        init() {
            controller = SelectionController(document: document)
            editing = ObjectEditing(document: document, selection: controller)
            tool.activate(in: ToolContext(document: document, host: host, selection: controller))
        }

        /// Two 40 pt squares at (40, 100) and (240, 100).
        static func make() async -> Fixture {
            let fixture = Fixture()
            fixture.document.pages = [Rect(x: 0, y: 0, width: 400, height: 300)]
            fixture.squares = await fixture.document.addRectangles([Rect(x: 40, y: 100, width: 40, height: 40), Rect(x: 240, y: 100, width: 40, height: 40)])
            return fixture
        }

        func drag(_ from: Point, _ to: Point, _ modifiers: KeyModifiers = [], clicks: Int = 1) async {
            tool.mouseDown(CanvasEvent(pasteboardPoint: from, viewPoint: from, modifiers: modifiers, clickCount: clicks))
            tool.mouseDragged(TestEvents.point((from.x + to.x) / 2, (from.y + to.y) / 2, modifiers))
            tool.mouseDragged(TestEvents.point(to.x, to.y, modifiers))
            tool.drawOverlay(in: ExtrudeUITests.context(), viewport: ExtrudeUITests.viewport)
            tool.mouseUp(TestEvents.point(to.x, to.y, modifiers))
            await document.settle()
        }

        func click(_ at: Point, clicks: Int = 1) async {
            tool.mouseDown(CanvasEvent(pasteboardPoint: at, viewPoint: at, clickCount: clicks))
            tool.mouseUp(CanvasEvent(pasteboardPoint: at, viewPoint: at, clickCount: clicks))
            await document.settle()
        }

        func extrusion(of square: SelectionID) -> OpID? {
            ExtrudeTool.extrusion(of: square.opID, in: document.state)
        }

        func props(_ wrapper: OpID) -> Wiretuner_Doc_V1_ExtrudeProps { document.state.props(wrapper).extrude }

        func waitForSelection(_ kind: NodeKind) async -> OpID? {
            for _ in 0..<200 {
                if let id = controller.selection.ids.first, document.state.nodeKind(id.opID) == kind { return id.opID }
                await Task.yield()
            }
            return nil
        }
    }

    @Test func dragExtrudesThenTheHandlesEditIt() async throws {
        let fixture = await Fixture.make()
        #expect(ExtrudeTool.descriptor.id == ExtrudeTool.id && fixture.host.messages.last == ExtrudeTool.statusMessage)
        await fixture.drag(Point(x: 60, y: 120), Point(x: 200, y: 20))
        let wrapper = try #require(await fixture.waitForSelection(.extrude))
        #expect(fixture.document.undoTitle == "Undo Extrude" && fixture.props(wrapper).vanishingPoint.x == 200 && fixture.props(wrapper).length == 36)
        let handles = try #require(fixture.tool.selectedHandles.first)
        #expect(handles.center.distance(to: Point(x: 60, y: 120)) < 2)
        // The vanishing point, with Shift kept level with the centre.
        await fixture.drag(handles.vanishing, Point(x: 300, y: 30), [.shift])
        #expect(fixture.props(wrapper).vanishingPoint.y == handles.center.y && fixture.document.undoTitle == "Undo Move vanishing point")
        // The depth control along the axis.
        let moved = try #require(fixture.tool.selectedHandles.first)
        await fixture.drag(moved.depth, moved.center + Vector(dx: 60, dy: 0))
        #expect(abs(fixture.props(wrapper).length - 60) < 1e-6 && fixture.document.undoTitle == "Undo Change depth")
        // The centre moves the object; the vanishing point stays.
        await fixture.drag(moved.center, moved.center + Vector(dx: 0, dy: 20))
        #expect(fixture.props(wrapper).vanishingPoint.y == handles.center.y && fixture.document.undoTitle == "Undo Move")
        #expect(abs((fixture.tool.selectedHandles.first?.center.y ?? 0) - handles.center.y - 20) < 1)
        // A click on the extruded shape selects the extrusion; clicking off a click selects as usual.
        await fixture.click(Point(x: 10, y: 10))
        #expect(fixture.controller.selection.isEmpty)
        await fixture.click(Point(x: 60, y: 140))
        #expect(fixture.controller.selection.ids == [SelectionID(wrapper)])
        // Extruding an extrusion is not offered: the drag selects it.
        await fixture.drag(Point(x: 60, y: 140), Point(x: 100, y: 200))
        #expect(fixture.document.undoTitle == "Undo Move")
        // A click on a flat object without a drag selects it.
        await fixture.click(Point(x: 260, y: 120))
        #expect(fixture.controller.selection.ids == [fixture.squares[1]])
        #expect(ExtrudeTool.vanishing(handles, at: Point(x: 61, y: 300), constrained: true).x == handles.center.x)
        #expect(ExtrudeTool.extrusion(of: fixture.squares[1].opID, in: fixture.document.state) == nil)
    }

    @Test func rotateModeTumblesSpinsAndExits() async throws {
        let fixture = await Fixture.make()
        await fixture.drag(Point(x: 60, y: 120), Point(x: 200, y: 20))
        let wrapper = try #require(await fixture.waitForSelection(.extrude))
        // A double-click enters rotate mode.
        await fixture.click(Point(x: 60, y: 120), clicks: 2)
        #expect(fixture.tool.rotating == wrapper && fixture.tool.hasSomethingToCancel)
        fixture.tool.drawOverlay(in: Self.context(), viewport: Self.viewport)
        // Inside the circle: x and y.
        await fixture.drag(Point(x: 60, y: 120), Point(x: 80, y: 110))
        var rotation = fixture.props(wrapper).rotation
        #expect(abs(rotation.y - 10) < 1e-6 && abs(rotation.x - 5) < 1e-6 && fixture.document.undoTitle == "Undo Rotate extrusion")
        // Outside: z, snapped with Shift.
        await fixture.drag(Point(x: 160, y: 120), Point(x: 60, y: 20), [.shift])
        rotation = fixture.props(wrapper).rotation
        #expect(rotation.z.truncatingRemainder(dividingBy: 15) == 0 && rotation.z != 0 && rotation.x.truncatingRemainder(dividingBy: 15) == 0)
        // Tab leaves; a double-click on the object again leaves; Esc with nothing dragged leaves.
        #expect(fixture.tool.keyDown(TestEvents.key("\t", keyCode: ExtrudeTool.tabKeyCode)) && fixture.tool.rotating == nil)
        #expect(!fixture.tool.keyDown(TestEvents.key("\t", keyCode: ExtrudeTool.tabKeyCode)))
        await fixture.click(Point(x: 60, y: 120), clicks: 2)
        await fixture.click(Point(x: 60, y: 120), clicks: 2)
        #expect(fixture.tool.rotating == nil)
        await fixture.click(Point(x: 60, y: 120), clicks: 2)
        fixture.tool.cancel()
        #expect(fixture.tool.rotating == nil)
        await fixture.click(Point(x: 60, y: 120), clicks: 2)
        fixture.tool.deactivate()
        #expect(fixture.tool.rotating == nil && fixture.tool.selectedHandles.isEmpty && fixture.tool.command(releasedAt: TestEvents.point(0, 0)) == nil)
        fixture.tool.flagsChanged(TestEvents.point(0, 0))
        #expect(fixture.tool.cursor == .crosshair)
    }

    @Test func theModifyExtrudeCommands() async throws {
        let fixture = await Fixture.make()
        let editing = fixture.editing
        let registry = ToolRegistry()
        registry.registerBuiltIn()
        let manager = ToolManager(registry: registry, context: ToolContext(document: fixture.document, host: fixture.host, selection: fixture.controller), focus: InspectorFocus())
        let commands = ExtrudeMenu.commands(target: { editing }, tools: { manager })
        func run(_ id: CommandID) {
            if case .perform(let action) = commands.first(where: { $0.id == id })!.action { action() }
        }
        func validation(_ id: CommandID) -> CommandValidation { commands.first { $0.id == id }!.validation() }
        #expect(validation(ExtrudeMenu.ID.extrude).reason == ObjectMenuCommands.noSelection && validation(ExtrudeMenu.ID.remove).reason == ExtrudeMenu.noExtrusion)
        fixture.controller.model.set(Selection(fixture.squares))
        run(ExtrudeMenu.ID.extrude)
        let wrapper = try #require(await fixture.waitForSelection(.extrude))
        #expect(fixture.props(wrapper).vanishingPoint.x == 200 && fixture.props(wrapper).vanishingPoint.y == 150, "toward the page's centre")
        let wrappers = fixture.squares.compactMap(fixture.extrusion(of:))
        #expect(wrappers.count == 2)
        fixture.controller.model.set(Selection(fixture.squares))
        #expect(validation(ExtrudeMenu.ID.extrude).reason == ExtrudeMenu.nested && ExtrudeMenu.extrusions(editing).count == 2)
        // Share Vanishing Points: the next click places the shared point.
        run(ExtrudeMenu.ID.share)
        #expect(manager.pushedTool is VanishingPointPicker && manager.activeTool.cursor == .crosshair)
        manager.mouseDown(TestEvents.point(10, 20))
        manager.mouseUp(TestEvents.point(10, 20))
        await fixture.document.settle()
        #expect(manager.pushedTool == nil && wrappers.allSatisfy { fixture.props($0).vanishingPoint.x == 10 && fixture.props($0).vanishingPoint.y == 20 })
        run(ExtrudeMenu.ID.share)
        manager.cancel()
        #expect(manager.pushedTool == nil)
        // Reset, Release and Remove.
        _ = await fixture.document.perform(EditExtrusion(wrappers, label: "Tilt", fields: [ExtrudeFields.rotation]) { $0.rotation.x = 30 }).value
        run(ExtrudeMenu.ID.reset)
        await fixture.document.settle()
        #expect(wrappers.allSatisfy { fixture.props($0).rotation.x == 0 })
        fixture.controller.model.set(Selection([fixture.squares[0]]))
        #expect(validation(ExtrudeMenu.ID.share).reason == ExtrudeMenu.twoExtrusions)
        run(ExtrudeMenu.ID.remove)
        await fixture.document.settle()
        #expect(fixture.extrusion(of: fixture.squares[0]) == nil && fixture.document.undoTitle == "Undo Remove extrusion")
        fixture.controller.model.set(Selection([SelectionID(wrappers[1])]))
        run(ExtrudeMenu.ID.release)
        await fixture.document.settle()
        #expect(!fixture.document.state.isLive(wrappers[1]) && fixture.document.undoTitle == "Undo Release extrusion")
        let none = ExtrudeMenu.commands(target: { nil }, tools: { nil })
        #expect(none.allSatisfy { $0.validation().reason == BlendMenu.noDocument })
        ExtrudeMenu.share(editing, tools: nil)
        let picker = VanishingPointPicker(nodes: [], sink: RecordingSink(), tools: nil)
        picker.mouseDown(TestEvents.point(0, 0))
        picker.mouseDragged(TestEvents.point(0, 0))
        picker.flagsChanged(TestEvents.point(0, 0))
        picker.deactivate()
        picker.drawOverlay(in: Self.context(), viewport: Self.viewport)
        #expect(!picker.keyDown(TestEvents.escape))
    }

    @Test func theExtrudePagesWriteEveryOption() async throws {
        let fixture = await Fixture.make()
        fixture.controller.model.set(Selection([fixture.squares[0]]))
        _ = await ExtrudeMenu.extrude(fixture.editing)?.value
        let wrapper = try #require(fixture.extrusion(of: fixture.squares[0]))
        let pasteboard = SystemObjectPasteboard(NSPasteboard(name: NSPasteboard.Name("WireTunerTests.extrude.\(UUID().uuidString)")))
        let panel = ObjectPanelModel(document: fixture.document, selection: Selection([SelectionID(wrapper)]))
        var model = try #require(ExtrudeSectionModel(panel, pasteboard: pasteboard))
        #expect(ExtrudeSectionModel(ObjectPanelModel(document: fixture.document, selection: Selection([fixture.squares[1]]))) == nil)
        #expect(model.length == 36 && model.surface == .shaded && model.lightsApply && model.ambient == 30 && model.direction(false) == .topLeft)
        #expect(model.direction(true) == Wiretuner_Doc_V1_LightDirection.none && model.profile == Wiretuner_Doc_V1_ProfileKind.none && !model.angleApplies)
        #expect(model.surfaceSteps == 10 && model.profileSteps == 1 && model.positionX == 60 && model.positionY == 120)
        // Each field commits in turn (the vanishing point and the rotation are ATOMIC values).
        let edits: [(ExtrudeSectionModel) -> any WTModel.Command] = [
            { $0.setLength(40_000) }, { $0.setVanishingX(50) }, { $0.setVanishingY(60) }, { $0.setZ(12) }, { $0.setRotationX(10) }, { $0.setRotationY(20) },
            { $0.setRotationZ(30) }, { $0.setSurface(.wireframe) }, { $0.setSurfaceSteps(0) }, { $0.setAmbient(150) }, { $0.setDirection(.front, second: true) },
            { $0.setIntensity(70, second: true) }, { $0.setIntensity(20, second: false) }, { $0.setProfile(.static) }, { $0.setProfileAngle(15) },
            { $0.setProfileSteps(500) }, { $0.setTwist(90) },
        ]
        for edit in edits {
            _ = await fixture.document.perform(edit(try #require(ExtrudeSectionModel(panel, pasteboard: pasteboard)))).value
        }
        model.committing { model.setPosition(x: $0) }(100)
        await fixture.document.settle()
        model = try #require(ExtrudeSectionModel(panel, pasteboard: pasteboard))
        #expect(model.length == 32000 && model.vanishingX == 50 && model.vanishingY == 60 && model.z == 12)
        #expect(model.rotationX == 10 && model.rotationY == 20 && model.rotationZ == 30 && model.surface == .wireframe && !model.lightsApply)
        #expect(model.surfaceSteps == 1 && model.ambient == 100 && model.direction(true) == .front && model.intensity(true) == 70 && model.intensity(false) == 20)
        #expect(model.profile == .static && model.angleApplies && model.profileAngle == 15 && model.profileSteps == 100 && model.twist == 90)
        #expect(abs((model.positionX ?? 0) - 100) < 1e-6 && model.setPosition(y: 10) != nil)
        // Paste In: refused without one open path, then the profile.
        #expect(ExtrudeSectionView.paste(model) == ExtrudeSectionModel.pasteRefusal && model.profilePreview == nil)
        let square = fixture.squares[1].opID
        pasteboard.write(ClipboardPayload(copying: [square], from: fixture.document.state, document: fixture.document.id).encoded())
        #expect(ExtrudeSectionView.paste(model) == ExtrudeSectionModel.pasteRefusal, "a closed shape is refused")
        let line = try #require(await fixture.document.addPath([Point(x: 0, y: 0), Point(x: 10, y: 10), Point(x: 20, y: 0)]))
        pasteboard.write(ClipboardPayload(copying: [line.opID], from: fixture.document.state, document: fixture.document.id).encoded())
        #expect(ExtrudeSectionView.paste(model) == nil)
        await fixture.document.settle()
        model = try #require(ExtrudeSectionModel(panel, pasteboard: pasteboard))
        #expect(model.profilePreview != nil && fixture.document.undoTitle == "Undo Paste profile")
        for page in ExtrudeSectionModel.Page.allCases { #expect(page.id == page.rawValue) }
        AttributeFixture.render(ExtrudeSectionView(model: model))
        AttributeFixture.render(Form { ExtrudeSectionView.extrude(model) })
        AttributeFixture.render(Form { ExtrudeSectionView.surface(model) })
        #expect(InspectorRegistry.standard.views(for: panel).map(\.id).contains("extrude"))
        #expect(AttributesListModel(document: fixture.document, selection: Selection([SelectionID(wrapper)])).rootTitle == "Extrusion")
        #expect(PropertiesTree.members(AttributesListModel(document: fixture.document, selection: Selection([SelectionID(wrapper)]))) == [fixture.squares[0].opID])
    }
}
