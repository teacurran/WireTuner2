import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// FX-033: the Smudge and Shadow tools, their copies grouped behind the original, the Shadow
/// sheet's Apply preview, and `CopiesBehind` (WTModel).
@Suite(.serialized) @MainActor struct CopyToolTests {
    typealias Fixture = DistortToolTests.Fixture

    /// The group now holding `node`, and its members bottom first.
    static func group(of node: OpID, in document: DocumentHandle) -> (group: OpID, members: [OpID])? {
        guard let group = Objects.parent(of: node, in: document.state), document.state.nodeKind(group) == .group else { return nil }
        return (group, document.state.liveChildren(group))
    }

    /// The first basic fill colour of `node`.
    static func fill(_ node: OpID, in document: DocumentHandle) -> RenderColor? {
        guard let props = NodeValuesProbe.appearance(document.state.props(node)), let fill = props.fills.first else { return nil }
        return ColorResolver(document.state).color(fill.settings.basic.color)
    }

    @Test func smudgeTrailsFadingCopiesBehindTheObjectInOneChange() async throws {
        let f = Fixture()
        let rect = await f.document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20)])[0]
        f.select([rect])
        let tool = SmudgeTool { SmudgeSettings(fill: .black, stroke: nil) }
        tool.activate(in: f.context)
        #expect(tool.command() == nil)
        await f.drag(tool, Point(x: 10, y: 10), Point(x: 30, y: 10))
        #expect(f.document.undoTitle == "Undo Smudge")
        let (_, members) = try #require(Self.group(of: rect.opID, in: f.document))
        #expect(members.count == 11 && members.last == rect.opID, "ten copies below the original")
        // The bottom copy is the farthest and fully the smudge colour; the stroke became None.
        let bottom = members[0]
        #expect(abs(Objects.transform(of: bottom, in: f.document.state).tx - 20) < 1e-9)
        let color = try #require(Self.fill(bottom, in: f.document))
        #expect(color.converted(to: .cmyk).components.w > 0.9)
        #expect(NodeValuesProbe.appearance(f.document.state.props(bottom))?.strokes.first?.settings.basic.color.none == true)
        // Option: grown about the centre instead.
        let other = await f.document.addRectangles([Rect(x: 100, y: 100, width: 20, height: 20)])[0]
        f.select([other])
        tool.mouseDown(TestEvents.point(110, 110))
        tool.mouseDragged(TestEvents.point(114, 110, [.option]))
        let command = try #require(tool.command() as? CopiesBehind)
        #expect(command.copies[0].copies.count == 2 && command.copies[0].copies[0].matrix.a > 1)
        tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.context.viewport)
        tool.flagsChanged(TestEvents.point(0, 0))
        tool.cancel()
        #expect(!tool.keyDown(TestEvents.escape) && tool.cursor == NSCursor.crosshair)
        tool.deactivate()
    }

    @Test func smudgeRefusesMoreThanAThousandObjects() async throws {
        let f = Fixture()
        let rect = await f.document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20)])[0]
        f.select([rect])
        let tool = SmudgeTool { SmudgeSettings() }
        tool.activate(in: f.context)
        await f.drag(tool, Point(x: 10, y: 10), Point(x: 2400, y: 10))
        #expect(f.host.messages.last == CopyGeometry.smudgeRefusal && f.document.undoTitle != "Undo Smudge")
        #expect(CopiesBehind.objectCount(rect.opID, copies: 3, in: f.document.state) == 3)
        #expect(SmudgeSettings(preferences: TestEnvironment().preferences) == SmudgeSettings(fill: .white, stroke: nil))
        // A press with nothing selected does nothing.
        f.select([])
        tool.mouseDown(TestEvents.point(0, 0))
        tool.mouseUp(TestEvents.point(0, 0))
        #expect(!tool.exceedsCap() && !tool.hasSomethingToCancel)
    }

    @Test func eachShadowTypeAndFillBuildsItsCopies() throws {
        let bounds = Rect(x: 0, y: 0, width: 100, height: 50)
        let hard = CopyGeometry.shadow(bounds: bounds, offset: Vector(dx: 5, dy: 5), settings: ShadowSettings(kind: .hard, fill: .tint, percent: 30))
        #expect(hard.count == 1 && hard[0].matrix.tx == 5 && hard[0].fill == .toward(.white, amount: 0.7))
        #expect(ShadowSettings(fill: .shade, percent: 40).paint == .toward(.black, amount: 0.4))
        #expect(ShadowSettings(fill: .color, color: .black).paint == .toward(.black, amount: 1))
        // Soft edge 50: 13 concentric insets, the innermost the shadow colour, the outer faded.
        let soft = CopyGeometry.shadow(bounds: bounds, offset: .init(dx: 0, dy: 0), settings: ShadowSettings(kind: .soft, softEdge: 50))
        #expect(soft.count == 13)
        #expect(soft.last?.fill == .then(ShadowSettings().paint, .toward(.white, amount: 0)))
        #expect(soft.first.map { $0.matrix.a == 1 } == true && (soft.last?.matrix.a ?? 1) < 1)
        #expect(CopyGeometry.shadow(bounds: bounds, offset: .init(dx: 0, dy: 0), settings: ShadowSettings(kind: .soft, softEdge: 0)).count == 1)
        // Zoom: scaled from the shadow's scale back to the object, colours blended from the zoom colours.
        let zoom = CopyGeometry.shadow(bounds: bounds, offset: Vector(dx: 40, dy: 0), settings: ShadowSettings(kind: .zoom, zoomFill: .black, scale: 50))
        #expect(zoom.count == CopyGeometry.zoomSteps && zoom[0].matrix.a == 0.5 && zoom[0].fill == .toward(.black, amount: 1))
        #expect(zoom.last.map { $0.matrix.a > 0.9 && $0.matrix.tx < 40 } == true)
        #expect(ShadowSettings(preferences: TestEnvironment().preferences) == ShadowSettings())
        let flat = CopyGeometry.shadow(bounds: Rect(x: 0, y: 0, width: 0, height: 0), offset: .init(dx: 1, dy: 1), settings: ShadowSettings(kind: .soft))
        #expect(flat.allSatisfy { $0.matrix.a == 1 })
        let still = CopyGeometry.smudge(drag: Vector(dx: 4, dy: 0), center: .zero, size: Size(width: 0, height: 0), outward: true, settings: SmudgeSettings())
        #expect(still.allSatisfy { $0.matrix.a == 1 })
    }

    @Test func theShadowToolGroupsAShadeBehindAndRefusesText() async throws {
        let f = Fixture()
        let rect = await f.document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20)])[0]
        f.select([rect])
        let tool = ShadowTool { ShadowSettings(kind: .hard, fill: .shade, percent: 100, offset: Vector(dx: 6, dy: 8)) }
        tool.activate(in: f.context)
        // A click: the options' offset.
        tool.mouseDown(TestEvents.point(10, 10))
        tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.context.viewport)
        tool.mouseUp(TestEvents.point(10, 10))
        await f.document.settle()
        #expect(f.document.undoTitle == "Undo Add shadow")
        let (group, members) = try #require(Self.group(of: rect.opID, in: f.document))
        #expect(members.count == 2 && members[1] == rect.opID)
        #expect(Objects.transform(of: members[0], in: f.document.state).tx == 6 && Objects.transform(of: members[0], in: f.document.state).ty == 8)
        let shade = try #require(Self.fill(members[0], in: f.document))
        #expect(shade.converted(to: .cmyk).components.w > 0.99, "a 100% shade is black")
        // A drag: its own offset.
        f.select([SelectionID(group)])
        await f.drag(tool, Point(x: 10, y: 10), Point(x: 40, y: 10))
        let outer = try #require(Self.group(of: group, in: f.document))
        #expect(abs(Objects.transform(of: outer.members[0], in: f.document.state).tx - 30) < 1e-9)
        // Text is refused with the reason.
        let document = DocumentHandle.memory(title: "Text")
        let words = try #require(await document.addText("Words"))
        let context = ToolContext(document: document, host: f.host, selection: SelectionController(document: document))
        context.selection.model.set(Selection([SelectionID(words)]))
        let textTool = ShadowTool { ShadowSettings() }
        textTool.activate(in: context)
        textTool.mouseDown(TestEvents.point(0, 0))
        #expect(f.host.messages.last == CopyGeometry.shadowRefusal && !textTool.hasSomethingToCancel)
        #expect(CopyGeometry.shadowCommand([words], offset: .init(dx: 1, dy: 1), settings: ShadowSettings(), document: document) == nil)
        #expect(!CopyGeometry.shadowable(OpID(counter: 99, replica: 99), in: document.state))
    }

    @Test func theShadowSheetAppliesAPreviewItCanTakeBack() async throws {
        let f = Fixture()
        let rect = await f.document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20)])[0]
        f.select([rect])
        let editing = ObjectEditing(document: f.document, selection: f.context.selection)
        let preview = ShadowPreview(target: { editing }) { ShadowSettings() }
        await preview.apply().value
        #expect(preview.previewed != nil && f.document.state.liveChildren(Objects.parent(of: rect.opID, in: f.document.state)!).count == 2)
        // Applying again replaces the preview.
        await preview.apply().value
        let groups = f.document.scene.topLevel.count
        #expect(groups == 1)
        await preview.cancel()?.value
        await f.document.settle()
        #expect(preview.previewed == nil && Objects.parent(of: rect.opID, in: f.document.state).map { f.document.state.nodeKind($0) } != .group)
        #expect(preview.cancel() == nil)
        await preview.apply().value
        preview.keep()
        #expect(preview.previewed == nil && f.document.undoTitle == "Undo Add shadow")
        // Nothing eligible: nothing previewed.
        let empty = ShadowPreview(target: { nil }) { ShadowSettings() }
        await empty.apply().value
        #expect(empty.previewed == nil)
        // The sheet's buttons.
        var dismissed = 0
        let sheet = ShadowOptionsSheet(store: TestEnvironment().preferences, preview: preview) { dismissed += 1 }
        PanelRendering.host(sheet)
        ShadowOptionsSheet.confirming(preview) { dismissed += 1 }()
        ShadowOptionsSheet.cancelling(preview) { dismissed += 1 }()
        #expect(dismissed == 2)
        let controller = DistortFeatures.shadowOptions(store: TestEnvironment().preferences) { editing }
        #expect(controller.title == "Shadow Options")
    }

    @Test func shadowCopiesRemainWhenTheOriginalIsDeletedConcurrently() async throws {
        let f = Fixture()
        let rect = await f.document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20)])[0]
        var remote = DocumentCore(state: f.document.state, replica: 0xBEEF)
        let delete = try #require(try remote.perform(DeleteNodes([rect.opID]), recording: DocumentCore.Recording(limit: 1, now: Date()))?.change)
        let command = try #require(CopyGeometry.shadowCommand([rect.opID], offset: Vector(dx: 5, dy: 5), settings: ShadowSettings(), document: f.document))
        _ = await f.document.perform(command).value
        _ = await f.document.receive(delete).value
        await f.document.settle()
        let group = try #require(Objects.parent(of: rect.opID, in: f.document.state))
        #expect(!f.document.state.isLive(rect.opID) && f.document.state.liveChildren(group).count == 1, "the copy remains, the original is deleted")
    }

    @Test func copiesBehindRecoloursEveryMemberOfAGroup() async throws {
        let f = Fixture()
        let ids = await f.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 20, y: 0, width: 10, height: 10)])
        _ = await f.document.perform(GroupObjects(ids.map(\.opID))).value
        await f.document.settle()
        let group = try #require(Objects.parent(of: ids[0].opID, in: f.document.state))
        let copy = CopiesBehind.Copy(matrix: .translation(Vector(dx: 0, dy: 40)), fill: .toward(.black, amount: 1), stroke: .keep)
        _ = await f.document.perform(CopiesBehind("Add shadow", copies: [(group, [copy]), (OpID(counter: 5, replica: 77), [copy]), (group, [])])).value
        await f.document.settle()
        let outer = try #require(Objects.parent(of: group, in: f.document.state))
        let shadowGroup = f.document.state.liveChildren(outer)[0]
        let members = f.document.state.liveChildren(shadowGroup)
        #expect(members.count == 2 && members.allSatisfy { (Self.fill($0, in: f.document)?.converted(to: .cmyk).components.w ?? 0) > 0.99 })
        #expect(CopiesBehind.mix(.white, .black, amount: 0) == .white && CopiesBehind.mix(.white, .black, amount: 1) == .black)
        let half = CopiesBehind.mix(.white, .black, amount: 0.5)
        #expect(half.space == .cmyk && abs(half.components.w - 0.5) < 0.2)
    }
}

extension CopyToolTests {
    /// A node of `props` created directly under the drawing layer.
    static func node(_ props: Wiretuner_Doc_V1_NodeProps, in document: DocumentHandle, near sibling: OpID) async -> OpID {
        let layer = Objects.parent(of: sibling, in: document.state)!
        let change = await document.perform(OpsCommand("Node", ops: [Ops.create(parent: layer, position: [0x01], props: props)])).value!
        await document.settle()
        return change.createdNodes[0]
    }

    @Test func theToolsRefuseQuietlyWithoutAPressAndReadTheirPreferences() async throws {
        let f = Fixture()
        let rect = await f.document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20)])[0]
        // Before activation, and without a press, nothing happens.
        let smudge = SmudgeTool { SmudgeSettings(fill: nil, stroke: .black) }
        smudge.mouseDown(TestEvents.point(0, 0))
        smudge.flagsChanged(TestEvents.point(0, 0))
        smudge.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.context.viewport)
        #expect(smudge.drag == Vector(dx: 0, dy: 0) && smudge.command() == nil)
        let shadow = ShadowTool { ShadowSettings() }
        shadow.activate(in: f.context)
        #expect(shadow.command() == nil)
        // Fill None, stroke towards black.
        let copies = CopyGeometry.smudge(drag: Vector(dx: 4, dy: 0), center: .zero, size: Size(width: 10, height: 10), outward: false,
                                         settings: SmudgeSettings(fill: nil, stroke: .black))
        #expect(copies.allSatisfy { $0.fill == CopiesBehind.Paint.none } && copies[0].stroke == .toward(.black, amount: 1))
        // An empty group has no bounds: nothing to smudge or shadow; an image is refused.
        var group = Wiretuner_Doc_V1_NodeProps()
        group.group.kind = .group
        let empty = await Self.node(group, in: f.document, near: rect.opID)
        #expect(CopyGeometry.shadowable(empty, in: f.document.state))
        #expect(CopyGeometry.shadowCommand([empty], offset: .init(dx: 1, dy: 1), settings: ShadowSettings(), document: f.document) == nil)
        f.select([SelectionID(empty)])
        smudge.activate(in: f.context)
        smudge.mouseDown(TestEvents.point(0, 0))
        smudge.mouseDragged(TestEvents.point(10, 0))
        #expect(smudge.command() == nil)
        smudge.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.context.viewport)
        smudge.cancel()
        var image = Wiretuner_Doc_V1_NodeProps()
        image.image.common.name = "Photo"
        let bitmap = await Self.node(image, in: f.document, near: rect.opID)
        #expect(!CopyGeometry.shadowable(bitmap, in: f.document.state))
        // A group whose members include one without bounds keeps the others' keylines.
        f.select([rect, SelectionID(empty)])
        smudge.mouseDown(TestEvents.point(10, 10))
        smudge.mouseDragged(TestEvents.point(20, 10))
        smudge.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.context.viewport)
        smudge.cancel()
        // Preferences: None flags, and an unknown type or fill.
        let preferences = TestEnvironment().preferences
        _ = preferences.set(true, for: DistortPreferences.smudgeFillNone)
        _ = preferences.set(false, for: DistortPreferences.smudgeStrokeNone)
        let read = SmudgeSettings(preferences: preferences)
        #expect(read.fill == nil && read.stroke != nil)
        #expect(ShadowSettings.kind("unknown") == .hard && ShadowSettings.fillMode("unknown") == .shade && ShadowSettings.kind("zoom") == .zoom)
        // The sheet's Apply and its dismiss hook.
        let editing = ObjectEditing(document: f.document, selection: f.context.selection)
        f.select([rect])
        let preview = ShadowPreview(target: { editing }) { ShadowSettings() }
        ShadowOptionsSheet.applying(preview)()
        #expect(ShadowOptionsSheet.rows.count == 11)
        let controller = DistortFeatures.shadowOptions(store: preferences) { editing }
        (controller as? NSHostingController<ShadowOptionsSheet>)?.rootView.dismiss()
        #expect((controller as? NSHostingController<ShadowOptionsSheet>)?.rootView.preview.settings() == ShadowSettings(preferences: preferences))
        await preview.cancel()?.value
    }
}

/// `NodeValues` is WTModel-internal; the tests read an attribute stack through the public entries.
enum NodeValuesProbe {
    static func appearance(_ props: Wiretuner_Doc_V1_NodeProps) -> Wiretuner_Doc_V1_AppearanceProps? {
        switch props.kind {
        case .path(let path)?: path.appearance
        case .rect(let rect)?: rect.appearance
        default: nil
        }
    }
}
