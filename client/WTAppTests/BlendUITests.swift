import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// FX-027 and FX-028: the Blend tool's gestures, the blend commands of the Modify and Extensions
/// menus, and the Object panel's blend section.
@Suite @MainActor struct BlendUITests {
    static let viewport = Viewport(size: Size(width: 400, height: 300))

    static func context() -> CGContext {
        CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    @MainActor
    final class Fixture {
        let document = DocumentHandle.memory(title: "Blends")
        let host = RecordingHost(viewport: BlendUITests.viewport)
        let controller: SelectionController
        let editing: ObjectEditing
        let tool = BlendTool()
        var squares: [SelectionID] = []

        init() {
            controller = SelectionController(document: document)
            editing = ObjectEditing(document: document, selection: controller)
            var context = ToolContext(document: document, host: host, selection: controller)
            context.objectEditing = editing
            tool.activate(in: context)
        }

        /// Three 40 pt square paths at x = 20, 120 and 220 (paths: their points can be blend points).
        static func make() async -> Fixture {
            let fixture = Fixture()
            for x in [20.0, 120, 220] {
                let corners = [Point(x: x, y: 100), Point(x: x + 40, y: 100), Point(x: x + 40, y: 140), Point(x: x, y: 140)]
                if let id = await fixture.document.addPath(corners, closed: true, filled: true) { fixture.squares.append(id) }
            }
            return fixture
        }

        /// A composite path (a square with a square hole) at (300, 180): it blends only with
        /// composite paths.
        func addComposite() async -> OpID? {
            func square(_ x: Double, _ y: Double, _ side: Double) -> NewContour {
                NewContour(closed: true, points: [Point(x: x, y: y), Point(x: x + side, y: y), Point(x: x + side, y: y + side), Point(x: x, y: y + side)]
                    .map { VectorPoint(anchor: $0) })
            }
            let node = await document.perform(CreatePath(contours: [square(300, 180, 60), square(320, 200, 20)], appearance: TestAppearance.filled)).value?
                .createdObjects.first
            await document.settle()
            return node
        }

        func drag(_ from: Point, _ to: Point, _ modifiers: KeyModifiers = []) async {
            tool.mouseDown(TestEvents.point(from.x, from.y, modifiers))
            tool.mouseDragged(TestEvents.point((from.x + to.x) / 2, (from.y + to.y) / 2, modifiers))
            tool.mouseDragged(TestEvents.point(to.x, to.y, modifiers))
            tool.drawOverlay(in: BlendUITests.context(), viewport: BlendUITests.viewport)
            tool.mouseUp(TestEvents.point(to.x, to.y, modifiers))
            await document.settle()
        }

        var blends: [OpID] {
            let state = document.state
            return state.store.nodes.filter { state.nodeKind($0) == .blend && state.isLive($0) }.sorted()
        }

        /// Waits for the selection a creation sets.
        func selected(_ kind: NodeKind) async -> OpID? {
            await document.settle()
            for _ in 0..<200 {
                if let id = controller.selection.ids.first, document.state.nodeKind(id.opID) == kind { return id.opID }
                await Task.yield()
            }
            return nil
        }
    }

    @Test func dragFromOneObjectToAnotherBlendsThem() async throws {
        let fixture = await Fixture.make()
        #expect(BlendTool.descriptor.id == BlendTool.id && fixture.host.messages.last == BlendTool.statusMessage)
        await fixture.drag(Point(x: 40, y: 120), Point(x: 140, y: 120))
        let blend = try #require(await fixture.selected(.blend))
        #expect(BlendReading.keyObjects(blend, in: fixture.document.state) == [fixture.squares[0].opID, fixture.squares[1].opID])
        #expect(fixture.document.undoTitle == "Undo Blend" && fixture.document.object(for: SelectionID(blend))?.kind == .blend)
        // From the blend to the third square: added as the last key object.
        await fixture.drag(Point(x: 40, y: 120), Point(x: 240, y: 120))
        #expect(BlendReading.keyObjects(blend, in: fixture.document.state).count == 3 && fixture.document.undoTitle == "Undo Add to blend")
        // The blend points of the selected blend: drag one to another point of its object.
        fixture.controller.model.set(Selection([SelectionID(blend)]))
        let points = fixture.tool.blendPoints
        #expect(points.count == 3)
        await fixture.drag(points[0].position, Point(x: 60, y: 140))
        #expect(fixture.document.undoTitle == "Undo Move blend point")
        #expect(BlendReading.points(fixture.document.state.props(blend).blend).count == 1)
        // A click selects as the Pointer does; a drag to nothing writes nothing.
        let undo = fixture.document.undoTitle
        await fixture.drag(Point(x: 240, y: 120), Point(x: 241, y: 120))
        await fixture.drag(Point(x: 300, y: 20), Point(x: 350, y: 20))
        await fixture.drag(Point(x: 40, y: 120), Point(x: 60, y: 125))
        #expect(fixture.document.undoTitle == undo)
        fixture.tool.flagsChanged(TestEvents.point(0, 0, [.shift]))
        #expect(!fixture.tool.hasSomethingToCancel && !fixture.tool.keyDown(TestEvents.escape) && fixture.tool.cursor == .crosshair)
        fixture.tool.deactivate()
        #expect(fixture.tool.blendPoints.isEmpty && fixture.tool.object(at: TestEvents.point(40, 120)) == nil)
        fixture.tool.mouseDown(TestEvents.point(40, 120))
        #expect(fixture.tool.refusal(for: .create(from: fixture.squares[0].opID), target: fixture.squares[1].opID) == nil)
        #expect(BlendTool.nearestPoint(of: OpID(counter: 9, replica: 9), to: .zero, in: fixture.document) == nil)
    }

    @Test func aTargetThatCannotBlendRefusesAndOptionDragJoinsAPath() async throws {
        let fixture = await Fixture.make()
        let text = try #require(await fixture.document.perform(CreateTextBlock(.point(Point(x: 300, y: 20)), text: "Hi")).value?.createdObjects.first)
        _ = try #require(await fixture.addComposite())
        // Over an object it cannot blend with the cursor refuses and nothing is created.
        fixture.tool.mouseDown(TestEvents.point(40, 120))
        #expect(fixture.tool.refusal(for: .create(from: fixture.squares[0].opID), target: text) == BlendEligibility.text)
        fixture.tool.mouseDragged(TestEvents.point(305, 185))
        #expect(fixture.tool.refusal == BlendEligibility.composites && fixture.tool.cursor == .operationNotAllowed && fixture.tool.hasSomethingToCancel)
        #expect(fixture.tool.preview() == nil)
        fixture.tool.drawOverlay(in: Self.context(), viewport: Self.viewport)
        fixture.tool.mouseUp(TestEvents.point(305, 185))
        await fixture.document.settle()
        #expect(fixture.blends.isEmpty && fixture.host.messages.last == BlendEligibility.composites)
        // Blend two squares, then Option-drag from the blend onto a path.
        await fixture.drag(Point(x: 40, y: 120), Point(x: 140, y: 120))
        let blend = try #require(fixture.blends.first)
        // Adding the composite path to the blend refuses.
        fixture.tool.mouseDown(TestEvents.point(40, 120))
        fixture.tool.mouseDragged(TestEvents.point(305, 185))
        #expect(fixture.tool.refusal == BlendEligibility.composites)
        fixture.tool.cancel()
        let path = try #require(await fixture.document.addPath([Point(x: 20, y: 250), Point(x: 380, y: 250)]))
        let rectangle = await fixture.document.addRectangles([Rect(x: 330, y: 20, width: 30, height: 30)])
        #expect(rectangle.count == 1)
        fixture.tool.mouseDown(TestEvents.point(40, 120, [.option]))
        fixture.tool.mouseDragged(TestEvents.point(345, 35, [.option]))
        #expect(fixture.tool.refusal != nil, "a rectangle is not a path")
        fixture.tool.cancel()
        await fixture.drag(Point(x: 40, y: 120), Point(x: 200, y: 250), [.option])
        #expect(BlendReading.path(fixture.document.state.props(blend).blend, children: fixture.document.state.liveChildren(blend), in: fixture.document.state) == path.opID)
        #expect(fixture.document.undoTitle == "Undo Join blend to path")
        #expect(fixture.tool.refusal(for: .point(BlendTool.BlendPointHandle(blend: blend, object: blend, position: .zero)), target: blend) == nil)
        #expect(fixture.tool.refusal(for: .join(blend: blend), target: blend) == nil && fixture.tool.refusal(for: .add(blend: blend), target: blend) == nil)
    }

    @Test func theMenusBlendJoinSplitAndRelease() async throws {
        let fixture = await Fixture.make()
        let editing = fixture.editing
        var stepsAsked: [[OpID]] = []
        let commands = BlendMenu.commands(target: { editing }) { stepsAsked.append($0) }
        func command(_ id: CommandID) -> WireTuner.Command { commands.first { $0.id == id }! }
        let ids = ContextMenuCatalog.ID.self
        #expect(command(ids.combineBlend).defaultKey == BlendMenu.key)
        #expect(command(ids.combineBlend).validation().reason == BlendEligibility.tooFew)
        fixture.controller.model.set(Selection([fixture.squares[0], fixture.squares[1]]))
        #expect(command(ids.combineBlend).validation().isEnabled)
        // Point to point: one selected point on each object.
        var selection = Selection([fixture.squares[0], fixture.squares[1]])
        for square in fixture.squares.prefix(2) {
            let contour = try #require(fixture.document.path(square)?.contours.first)
            selection.setSubSelection(.points([PointReference(node: square.node, contour: contour.id, point: contour.points[1].id)]), for: square)
        }
        fixture.controller.model.set(selection)
        #expect(BlendMenu.points(editing).count == 2)
        guard case .perform(let blendAction) = command(ids.combineBlend).action else { return }
        blendAction()
        let blend = try #require(await fixture.selected(.blend))
        #expect(BlendReading.points(fixture.document.state.props(blend).blend).count == 2)
        // Join needs a blend and a path.
        #expect(command(BlendMenu.ID.joinBlendToPath).validation().reason == BlendMenu.joinSelection)
        let path = try #require(await fixture.document.addPath([Point(x: 20, y: 250), Point(x: 380, y: 250)]))
        fixture.controller.model.set(Selection([SelectionID(blend), path]))
        #expect(command(BlendMenu.ID.joinBlendToPath).validation().isEnabled && command(ids.split).validation().reason == BlendMenu.notJoined)
        guard case .perform(let join) = command(BlendMenu.ID.joinBlendToPath).action else { return }
        join()
        await fixture.document.settle()
        fixture.controller.model.set(Selection([SelectionID(blend)]))
        #expect(command(ids.split).validation().isEnabled)
        guard case .perform(let split) = command(ids.split).action else { return }
        split()
        await fixture.document.settle()
        #expect(fixture.document.undoTitle == "Undo Split" && BlendMenu.joinedBlends(editing).isEmpty)
        // Blend Steps… asks for the selected blends; Release ungroups.
        guard case .perform(let steps) = command(ids.blendSteps).action, case .perform(let release) = command(ids.blendRelease).action else { return }
        steps()
        #expect(stepsAsked == [[blend]])
        release()
        await fixture.document.settle()
        #expect(fixture.blends.isEmpty && fixture.document.undoTitle == "Undo Ungroup")
        #expect(command(ids.blendRelease).validation().reason == BlendMenu.noBlend && command(ids.blendSteps).validation().reason == BlendMenu.noBlend)
        split()
        steps()
        release()
        join()
        #expect(stepsAsked.count == 1)
        // Modify > Ungroup on a blend releases it too, beside an ordinary group.
        fixture.controller.model.set(Selection([fixture.squares[0], fixture.squares[1]]))
        blendAction()
        let second = try #require(await fixture.selected(.blend))
        let group = try #require(await fixture.document.perform(GroupObjects([fixture.squares[2].opID])).value?.createdObjects.first)
        await fixture.document.settle()
        fixture.controller.model.set(Selection([SelectionID(second), SelectionID(group)]))
        #expect(editing.canUngroup)
        await editing.ungroup()?.value
        #expect(fixture.blends.isEmpty && !fixture.document.state.isLive(group))
        let none = BlendMenu.commands(target: { nil }) { _ in }
        #expect(none.allSatisfy { $0.validation().reason == BlendMenu.noDocument })
        // The Extensions menu's Create > Blend and the Operations toolbar button.
        let registry = ExtensionRegistry()
        let made = BlendMenu.extensionDescriptor(existing: registry, target: { editing })
        let descriptor = try #require(made)
        fixture.controller.model.set(Selection([fixture.squares[0], fixture.squares[1]]))
        #expect(descriptor.validate?().isEnabled == true)
        _ = descriptor.run?(nil)
        #expect(try #require(await fixture.selected(.blend)) != second)
        #expect(BlendMenu.extensionDescriptor(existing: ExtensionRegistry(descriptors: []), target: { editing }) == nil)
        // The context menu names a blend's kind.
        let resolver = ContextMenuResolver()
        let blendID = try #require(fixture.blends.first)
        let target = resolver.target(at: Point(x: 40, y: 120), viewport: Self.viewport, document: fixture.document, selection: fixture.controller)
        #expect(target == .objects([.blend]) && fixture.controller.selection.ids == [SelectionID(blendID)])
    }

    @Test func theBlendSectionWritesEveryOption() async throws {
        let fixture = await Fixture.make()
        fixture.controller.model.set(Selection([fixture.squares[0], fixture.squares[1]]))
        _ = await BlendMenu.blend(fixture.editing)?.value
        let blend = try #require(fixture.blends.first)
        let panel = ObjectPanelModel(document: fixture.document, selection: Selection([SelectionID(blend)]))
        var model = try #require(BlendSectionModel(panel))
        #expect(BlendSectionModel(ObjectPanelModel(document: fixture.document, selection: Selection([fixture.squares[2]]))) == nil)
        #expect(model.steps == 0 && model.rangeFirst == 0 && model.rangeLast == 100 && model.type == .normal && model.order == .positional)
        #expect(!model.isJoined && !model.isComposite && model.showPath == .off && model.rotateOnPath == .on)
        for command in [model.setSteps(12), model.setRangeFirst(-5), model.setRangeLast(80), model.setType(.vertical), model.setOrder(.stacking)] {
            _ = await fixture.document.perform(command).value
        }
        model.committing(model.setShowPath)(true)
        model.binding(model.rotateOnPath, model.setRotateOnPath).wrappedValue = false
        await fixture.document.settle()
        model = try #require(BlendSectionModel(panel))
        #expect(model.steps == 12 && model.rangeFirst == 0 && model.rangeLast == 80 && model.type == .vertical && model.order == .stacking)
        #expect(model.showPath == .on && model.rotateOnPath == .off && model.binding(model.showPath, model.setShowPath).wrappedValue)
        AttributeFixture.render(BlendSectionView(model: model))
        AttributeFixture.render(VStack { ForEach(InspectorRegistry.standard.views(for: panel), id: \.id) { $0.view } })
        #expect(InspectorRegistry.standard.views(for: panel).map(\.id).contains("blend"))
        // The Blend Steps sheet.
        let presenter = SheetPresenter()
        presenter.present = { _ in }
        let features = EffectFeatures(target: { fixture.editing }, sheets: presenter)
        features.showBlendSteps([blend])
        #expect(presenter.sheets[EffectFeatures.blendSteps] != nil)
        var value: Double? = nil
        let text = BlendStepsSheet.text(Binding(get: { value }, set: { value = $0 }), steps: 12)
        #expect(text.wrappedValue == "12")
        text.wrappedValue = "30"
        #expect(value == 30)
        AttributeFixture.render(BlendStepsSheet(steps: 12) { _ in })
    }
}
