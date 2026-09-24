import AppKit
import SwiftProtobuf
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// A small document: one 400 × 300 page at the pasteboard origin, two filled rectangles, a group
/// of two and an unfilled square, all at zoom 1 so view points equal pasteboard points.  Draw
/// order (display-list index): page furniture 0, `a` 1, `b` 2, the group 3, the square 4.
@MainActor
final class SelectionFixture {
    static let viewport = Viewport(size: Size(width: 400, height: 300))

    let document: DocumentHandle
    private(set) var a = SelectionID(NodeID(counter: 0, replica: 0))
    private(set) var b = SelectionID(NodeID(counter: 0, replica: 0))
    private(set) var group = SelectionID(NodeID(counter: 0, replica: 0))
    private(set) var member = SelectionID(NodeID(counter: 0, replica: 0))
    private(set) var otherMember = SelectionID(NodeID(counter: 0, replica: 0))
    private(set) var square = SelectionID(NodeID(counter: 0, replica: 0))

    init(document: DocumentHandle = .memory(title: "Selection")) {
        self.document = document
        document.pages = [Rect(x: 0, y: 0, width: 400, height: 300)]
    }

    /// The fixture with its objects drawn.
    static func make(_ document: DocumentHandle = .memory(title: "Selection")) async -> SelectionFixture {
        let fixture = SelectionFixture(document: document)
        await fixture.populate()
        return fixture
    }

    private func populate() async {
        let rects = await document.addRectangles([Rect(x: 10, y: 10, width: 50, height: 50), Rect(x: 100, y: 10, width: 50, height: 50)])
        a = rects[0]
        b = rects[1]
        let change = await document.perform(GroupOfRectangles(rects: [Rect(x: 200, y: 10, width: 40, height: 40), Rect(x: 250, y: 10, width: 40, height: 40)])).value
        let created = change?.createdNodes ?? []
        group = SelectionID(created[0])
        member = SelectionID(created[1])
        otherMember = SelectionID(created[2])
        square = await document.addRectangles([Rect(x: 10, y: 100, width: 50, height: 50)], filled: false)[0]
        await document.settle()
    }

    /// The first point of a rectangle (its top-left corner; derived ids are synthetic).
    func corner(of id: SelectionID) -> PointReference {
        PointReference(node: id.node, contour: .zero, point: OpID(counter: 1, replica: 0))
    }
}

/// A group node holding filled rectangles, on the top layer, in one change.
struct GroupOfRectangles: WTModel.Command {
    let rects: [Rect]
    var label: String { "Group" }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let layer = state.liveChildren(WellKnown.layers).last!
        let top = state.store.children(layer).last.flatMap { state.store.placement($0)?.position }
        var props = Wiretuner_Doc_V1_NodeProps()
        props.group = Wiretuner_Doc_V1_GroupProps()
        let group = builder.append(Ops.create(parent: layer, position: try FractionalIndex.between(top, nil, suffix: 1), props: props))
        var previous: [UInt8]?
        for (index, rect) in rects.enumerated() {
            var member = Wiretuner_Doc_V1_NodeProps()
            member.rect.size.width = rect.width
            member.rect.size.height = rect.height
            member.rect.common.transform = Wiretuner_Doc_V1_Transform.with { $0.a = 1; $0.d = 1; $0.tx = rect.minX; $0.ty = rect.minY }
            let position = try FractionalIndex.between(previous, nil, suffix: UInt64(index + 7))
            previous = position
            let node = builder.append(Ops.create(parent: group, position: position, props: member))
            var fill = Wiretuner_Doc_V1_NodeProps()
            fill.rect.appearance = TestAppearance.filled
            builder.append(Ops.elementInsert(node, RegisterPath([21, 4, 1]), positions: [[0x80]], values: fill))
        }
    }
}

@Suite struct SelectionValueTests {
    let a = SelectionID(NodeID(counter: 5, replica: 1))
    let b = SelectionID(NodeID(counter: 6, replica: 1))
    let c = SelectionID(NodeID(counter: 7, replica: 1))

    @Test func idsAreNodeIDs() {
        #expect(a.opID == OpID(counter: 5, replica: 1))
        #expect(SelectionID(OpID(counter: 5, replica: 1)) == a)
        #expect(a.description == "5:1")
        #expect(a < b && c > b)
    }

    @Test func referencesOrderByNodeContourThenPoint() {
        let node = NodeID(counter: 1, replica: 1)
        let p1 = PointReference(node: node, contour: OpID(counter: 2, replica: 1), point: OpID(counter: 3, replica: 1))
        let p2 = PointReference(node: node, PointRef(contour: OpID(counter: 2, replica: 1), point: OpID(counter: 4, replica: 1)))
        #expect(p1 < p2)
        #expect(PointReference(node: NodeID(counter: 0, replica: 9), contour: .zero, point: .zero) < p1)
        let s1 = SegmentReference(node: node, contour: .zero, from: OpID(counter: 1, replica: 0))
        let s2 = SegmentReference(node: node, contour: .zero, from: OpID(counter: 2, replica: 0))
        #expect(s1 < s2)
    }

    @Test func subSelectionsMergeToggleAndFilter() {
        let node = NodeID(counter: 1, replica: 1)
        let p1 = PointReference(node: node, contour: .zero, point: OpID(counter: 1, replica: 0))
        let p2 = PointReference(node: node, contour: .zero, point: OpID(counter: 2, replica: 0))
        let s1 = SegmentReference(node: node, contour: .zero, from: OpID(counter: 1, replica: 0))
        let s2 = SegmentReference(node: node, contour: .zero, from: OpID(counter: 2, replica: 0))
        #expect(SubSelection.points([p1]).adding(.points([p2])) == .points([p1, p2]))
        #expect(SubSelection.segments([s1]).adding(.segments([s2])) == .segments([s1, s2]))
        #expect(SubSelection.points([p1]).adding(.textRange(0..<3)) == .textRange(0..<3))
        #expect(SubSelection.points([p1, p2]).toggling(.points([p1])) == .points([p2]))
        #expect(SubSelection.segments([s1]).toggling(.segments([s1, s2])) == .segments([s2]))
        #expect(SubSelection.textRange(0..<1).toggling(.points([p1])) == .points([p1]))
        #expect(SubSelection.points([]).isEmpty && SubSelection.segments([]).isEmpty && SubSelection.textRange(2..<2).isEmpty)
        #expect(!SubSelection.textRange(0..<2).isEmpty)
        #expect(SubSelection.points([p1, p2]).filtered(points: { $0 == p2 }, segments: { _ in true }) == .points([p2]))
        #expect(SubSelection.segments([s1, s2]).filtered(points: { _ in true }, segments: { $0 == s1 }) == .segments([s1]))
        #expect(SubSelection.textRange(1..<4).filtered(points: { _ in false }, segments: { _ in false }) == .textRange(1..<4))
    }

    @Test func modesCombineInSelectionOrder() {
        let start = Selection([a, b, a])
        #expect(start.ids == [a, b] && start.count == 2 && !start.isEmpty && Selection.empty.isEmpty)
        #expect(start.applying([c], mode: .replace).ids == [c])
        #expect(start.applying([c, a], mode: .add).ids == [a, b, c])
        #expect(start.applying([a, c], mode: .toggle).ids == [b, c])
        #expect(start.applying([a, c], mode: .subtract).ids == [b])
    }

    @Test func subSelectionsFollowTheirObjects() {
        let p1 = PointReference(node: a.node, contour: .zero, point: OpID(counter: 1, replica: 0))
        let p2 = PointReference(node: a.node, contour: .zero, point: OpID(counter: 2, replica: 0))
        var selection = Selection().applying([a], sub: [a: .points([p1])], mode: .replace)
        #expect(selection.subSelection(of: a) == .points([p1]))
        selection = selection.applying([a], sub: [a: .points([p2])], mode: .add)
        #expect(selection.subSelection(of: a) == .points([p1, p2]))
        selection = selection.applying([b], sub: [b: .textRange(0..<2)], mode: .add)
        #expect(selection.subSelection(of: b) == .textRange(0..<2))
        selection = selection.applying([a], sub: [a: .points([p1])], mode: .toggle)
        #expect(selection.contains(a) && selection.subSelection(of: a) == .points([p2]))
        selection = selection.applying([a], sub: [a: .points([p2])], mode: .toggle)
        #expect(selection.contains(a) && selection.subSelection(of: a) == nil)
        selection = selection.applying([c], sub: [c: .points([p1])], mode: .toggle)
        #expect(selection.subSelection(of: c) == .points([p1]))
        selection = selection.applying([a], sub: [a: .points([p1])], mode: .toggle)
        #expect(selection.subSelection(of: a) == .points([p1]))
        selection = selection.applying([b], mode: .toggle)
        #expect(!selection.contains(b) && selection.subSelection(of: b) == nil)
        selection.setSubSelection(.points([p1]), for: b)
        #expect(selection.subSelection(of: b) == nil)
        selection.setSubSelection(nil, for: a)
        #expect(selection.subSelection(of: a) == nil)
    }

    @Test func invertsRemapsAndFilters() {
        let universe = [a, b, c]
        let p = PointReference(node: c.node, contour: .zero, point: .zero)
        let selection = Selection([b]).applying([c], sub: [c: .points([p])], mode: .add)
        #expect(selection.inverted(within: universe).ids == [a])
        #expect(selection.filtered { $0 == b }.ids == [b])
        #expect(selection.filtered { _ in true }.subSelection(of: c) == .points([p]))
        #expect(selection.filtered({ _ in true }, sub: { _ in .points([]) }).subSelection(of: c) == nil)
        #expect(selection.remapped { $0 == b ? c : nil }.ids == [c])
        #expect(selection.remapped { $0 }.subSelection(of: c) == .points([p]), "sub-selections kept by default")
    }
}

@Suite @MainActor struct SelectionModelTests {
    let one = SelectionID(NodeID(counter: 1, replica: 1))
    let two = SelectionID(NodeID(counter: 2, replica: 1))

    @Test func notifiesOnlyOnChangeAndPublishesToPanels() {
        let model = SelectionModel()
        var heard: [Int] = []
        let token = model.observe { heard.append($0.count) }
        model.apply([one], mode: .replace)
        model.apply([one], mode: .add)
        model.set(Selection([one, two]))
        #expect(model.ids == [one, two] && model.count == 2 && !model.isEmpty)
        model.clear()
        #expect(heard == [1, 2, 0])
        model.stopObserving(token)
        model.apply([SelectionID(NodeID(counter: 3, replica: 1))], mode: .replace)
        #expect(heard == [1, 2, 0])

        let active = ActiveSelection()
        #expect(active.summary == "No document")
        active.model = SelectionModel()
        #expect(active.summary == "Nothing selected")
        active.model?.apply([one], mode: .replace)
        #expect(active.summary == "1 object selected")
        active.model?.apply([two], mode: .add)
        #expect(active.summary == "2 objects selected")
    }

    @Test func panelBodiesObserveTheActiveSelection() {
        let active = ActiveSelection(model: SelectionModel(Selection([one])))
        let registry = PanelRegistry()
        PlaceholderPanels.register(into: registry, selection: active)
        let view = registry.descriptor(for: "object")!.makeView()
        #expect(view.accessibilityIdentifier() == "panel.object")
        let body = SelectionSummaryBody(selection: nil)
        #expect(body.selection == nil)
        _ = NSHostingView(rootView: body).fittingSize
        _ = PlaceholderPanels.object.makeView()
    }
}

@Suite @MainActor struct SelectionControllerTests {
    let viewport = SelectionFixture.viewport

    @Test func clicksSelectToggleKeepAndClear() async {
        let fixture = await SelectionFixture.make()
        let controller = SelectionController(document: fixture.document)
        controller.click(at: Point(x: 30, y: 30), viewport: viewport, modifiers: [], subselect: false)
        #expect(controller.selection.ids == [fixture.a])
        controller.click(at: Point(x: 120, y: 30), viewport: viewport, modifiers: .shift, subselect: false)
        #expect(controller.selection.ids == [fixture.a, fixture.b])
        controller.click(at: Point(x: 30, y: 30), viewport: viewport, modifiers: [], subselect: false)
        #expect(controller.selection.count == 2, "a plain click on a selected object keeps the whole selection")
        controller.click(at: Point(x: 30, y: 30), viewport: viewport, modifiers: .shift, subselect: false)
        #expect(controller.selection.ids == [fixture.b])
        controller.click(at: Point(x: 380, y: 280), viewport: viewport, modifiers: .shift, subselect: false)
        #expect(controller.selection.ids == [fixture.b], "the page is not an object")
        controller.click(at: Point(x: 380, y: 280), viewport: viewport, modifiers: [], subselect: false)
        #expect(controller.selection.isEmpty)
        controller.click(at: Point(x: 35, y: 125), viewport: viewport, modifiers: [], subselect: false)
        #expect(controller.selection.isEmpty, "the unfilled square's interior does not select it")
        controller.click(at: Point(x: 10, y: 125), viewport: viewport, modifiers: [], subselect: false)
        #expect(controller.selection.ids == [fixture.square])
        controller.click(at: Point(x: 220, y: 30), viewport: viewport, modifiers: [], subselect: false)
        #expect(controller.selection.ids == [fixture.group], "a group member selects the group")
        controller.click(at: Point(x: 220, y: 30), viewport: viewport, modifiers: [], subselect: true)
        #expect(controller.selection.ids == [fixture.member], "subselecting selects the member")
        #expect(controller.hitTesterBuilds == 1, "the index is built once per content")
    }

    @Test func subselectClicksPickPointsAndSegments() async {
        let fixture = await SelectionFixture.make()
        let controller = SelectionController(document: fixture.document, pickDistance: { 4 })
        controller.click(at: Point(x: 10, y: 10), viewport: viewport, modifiers: [], subselect: true)
        #expect(controller.selection.ids == [fixture.a])
        #expect(controller.selection.subSelection(of: fixture.a) == .points([fixture.corner(of: fixture.a)]))
        controller.click(at: Point(x: 35, y: 10), viewport: viewport, modifiers: [], subselect: true)
        #expect(controller.selection.subSelection(of: fixture.a)
            == .segments([SegmentReference(node: fixture.a.node, contour: .zero, from: OpID(counter: 1, replica: 0))]))
        let hit = { (kind: HitKind) in HitResult(itemPath: [1], leafPath: [1], kind: kind, distance: 0) }
        #expect(controller.subSelection(for: hit(.fill), in: fixture.a) == nil)
        #expect(controller.subSelection(for: hit(.stroke(nil)), in: fixture.a) == nil)
        #expect(controller.subSelection(for: hit(.handle(element: 2, control: 1)), in: fixture.a)
            == .points([PointReference(node: fixture.a.node, contour: .zero, point: OpID(counter: 3, replica: 0))]))
        #expect(controller.subSelection(for: hit(.stroke(PathLocation(contour: 0, segment: 3, t: 0.5))), in: fixture.a)
            == .segments([SegmentReference(node: fixture.a.node, contour: .zero, from: OpID(counter: 4, replica: 0))]))
        #expect(controller.subSelection(for: hit(.segment(PathLocation(contour: 5, segment: 0, t: 0.5))), in: fixture.a) == nil)
        #expect(controller.subSelection(for: hit(.point(element: 0)), in: SelectionID(NodeID(counter: 99, replica: 9))) == nil)
    }

    @Test func pointsHandlesAndSegmentsHitAtTheLowestAndHighestZoom() async throws {
        let document = DocumentHandle.memory(title: "Zoom")
        let curve = [VectorPoint(anchor: Point(x: 100, y: 100), outHandle: Vector(dx: 20, dy: 0), kind: .curve),
                     VectorPoint(anchor: Point(x: 160, y: 100), inHandle: Vector(dx: -20, dy: 0), kind: .curve)]
        let node = try #require(await document.perform(CreatePath(contours: [NewContour(points: curve)])).value?.createdObjects.first)
        await document.settle()
        let id = SelectionID(node)
        let contour = try #require(document.path(id)?.contours.first)
        for zoom in [1.0, 16.0] {
            let controller = SelectionController(document: document, pickDistance: { 3 })
            let viewport = Viewport(scrollOrigin: Point(x: 100 - 50 / zoom, y: 100 - 50 / zoom), zoom: zoom, size: Size(width: 400, height: 300))
            // Two view pixels off the first anchor: within the pick distance at any zoom.
            let near = viewport.toView(Point(x: 100, y: 100)) + Vector(dx: 2, dy: 0)
            controller.click(at: near, viewport: viewport, modifiers: [], subselect: true)
            #expect(controller.selection.subSelection(of: id) == .points([PointReference(node: id.node, contour: contour.id, point: contour.points[0].id)]), "zoom \(zoom)")
            let onSegment = viewport.toView(Point(x: 130, y: 100)) + Vector(dx: 0, dy: 2)
            controller.click(at: onSegment, viewport: viewport, modifiers: [], subselect: true)
            #expect(controller.selection.subSelection(of: id) == .segments([SegmentReference(node: id.node, contour: contour.id, from: contour.points[0].id)]), "zoom \(zoom)")
            let far = viewport.toView(Point(x: 100, y: 100)) + Vector(dx: 0, dy: 20)
            controller.click(at: far, viewport: viewport, modifiers: [], subselect: true)
            #expect(controller.selection.isEmpty, "zoom \(zoom): 20 view pixels away is nothing")
        }
    }

    @Test func marqueesAreEnclosedOrContactSensitive() async {
        let fixture = await SelectionFixture.make()
        let flag = SelectionFlag()
        let controller = SelectionController(document: fixture.document, contactSensitive: { flag.value })
        controller.marquee(Rect(x: 0, y: 0, width: 160, height: 70), viewport: viewport, modifiers: [], subselect: false)
        #expect(controller.selection.ids == [fixture.a, fixture.b], "in draw order, the page excluded")
        controller.marquee(Rect(x: 30, y: 30, width: 90, height: 10), viewport: viewport, modifiers: [], subselect: false)
        #expect(controller.selection.isEmpty, "touching is not enclosing")
        flag.value = true
        controller.marquee(Rect(x: 30, y: 30, width: 90, height: 10), viewport: viewport, modifiers: [], subselect: false)
        #expect(controller.selection.ids == [fixture.a, fixture.b])
        controller.marquee(Rect(x: 95, y: 5, width: 60, height: 60), viewport: viewport, modifiers: .shift, subselect: false)
        #expect(controller.selection.ids == [fixture.a], "Shift toggles each picked object")
        flag.value = false
        controller.marquee(Rect(x: 5, y: 5, width: 10, height: 10), viewport: viewport, modifiers: [], subselect: true)
        #expect(controller.selection.ids == [fixture.a])
        #expect(controller.selection.subSelection(of: fixture.a) == .points([fixture.corner(of: fixture.a)]))
        controller.marquee(Rect(x: 195, y: 5, width: 50, height: 50), viewport: viewport, modifiers: [], subselect: true)
        #expect(controller.selection.ids.contains(fixture.member))
    }

    @Test func commandsSelectAllNoneAndInvertOnThePage() async {
        let fixture = await SelectionFixture.make()
        let document = fixture.document
        let controller = SelectionController(document: document)
        #expect(controller.canSelectAll)
        #expect(controller.selectedBounds == nil)
        controller.selectAll()
        #expect(controller.selection.ids == [fixture.a, fixture.b, fixture.group, fixture.square])
        controller.model.apply([fixture.b], mode: .replace)
        controller.invert()
        #expect(controller.selection.ids == [fixture.a, fixture.group, fixture.square])
        #expect(controller.selectedBounds?.minX ?? 0 < 10.5)
        controller.selectNone()
        #expect(controller.selection.isEmpty)
        document.pages = [Rect(x: 1000, y: 1000, width: 10, height: 10)]
        await document.settle()
        #expect(!controller.canSelectAll, "objects off the current page are not All")
    }

    @Test func deletedObjectsAndPointsLeaveTheSelection() async {
        let fixture = await SelectionFixture.make()
        let document = fixture.document
        let controller = SelectionController(document: document)
        _ = controller.hitTester(viewport: viewport, subselect: false)
        let line = await document.addPath([Point(x: 300, y: 200), Point(x: 350, y: 200), Point(x: 350, y: 250)])!
        let points = document.path(line)!.contours[0].points
        let first = PointReference(node: line.node, contour: document.path(line)!.contours[0].id, point: points[0].id)
        let second = PointReference(node: line.node, contour: first.contour, point: points[1].id)
        controller.model.set(Selection([fixture.a, fixture.member, fixture.square]).applying([line], sub: [line: .points([first, second])], mode: .add))
        let changes = document.changeCount
        _ = await document.perform(DeleteNodes([fixture.a.opID])).value
        #expect(controller.selection.ids == [fixture.member, fixture.square, line], "the deleted object leaves; the rest keep their ids")
        #expect(document.changeCount == changes + 1)
        _ = await document.perform(DeletePoints(node: line.opID, points: [(first.contour, first.point)])).value
        #expect(controller.selection.subSelection(of: line) == .points([second]), "a deleted point leaves the sub-selection")
        #expect(document.item(for: fixture.a) == nil)
        #expect(document.item(for: SelectionID(NodeID(counter: 99, replica: 9))) == nil)
        #expect(document.item(for: fixture.member) != nil, "a group member resolves inside its group")
        #expect(document.contains(second) && !document.contains(first))
        #expect(!document.contains(SegmentReference(node: line.node, contour: first.contour, from: first.point)))
        #expect(document.contains(SegmentReference(node: line.node, contour: first.contour, from: second.point)))
        #expect(document.selectionID(atItemPath: [0]) == nil, "the page is not an object")
        let unknown = NodeID(counter: 99, replica: 9)
        #expect(!document.contains(PointReference(node: unknown, contour: .zero, point: .zero)))
        #expect(!document.contains(SegmentReference(node: unknown, contour: .zero, from: .zero)))
        // Segments follow the document too.
        let segment = SegmentReference(node: line.node, contour: first.contour, from: second.point)
        controller.model.set(Selection().applying([line], sub: [line: .segments([segment])], mode: .replace))
        _ = await document.perform(DeletePoints(node: line.opID, points: [(second.contour, second.point)])).value
        #expect(controller.selection.subSelection(of: line) == nil, "the segment went with its point")
    }
}

@Suite @MainActor struct PointerToolTests {
    @MainActor
    final class Fixture {
        let tool = PointerTool()
        let host = RecordingHost(viewport: SelectionFixture.viewport)
        let objects: SelectionFixture
        let selection: SelectionController

        private init(_ objects: SelectionFixture) {
            self.objects = objects
            selection = SelectionController(document: objects.document)
            tool.activate(in: ToolContext(document: objects.document, host: host, selection: selection))
        }

        static func make() async -> Fixture {
            Fixture(await SelectionFixture.make())
        }
    }

    @Test func clickAndMarqueeSelectThroughTheController() async {
        let fixture = await Fixture.make()
        let tool = fixture.tool
        #expect(fixture.host.messages == [PointerTool.statusMessage])
        #expect(tool.cursor == .arrow)
        tool.mouseDown(TestEvents.point(30, 30))
        tool.mouseDragged(TestEvents.point(31, 31))
        #expect(!tool.isMarquee && tool.marqueeRect == nil)
        tool.mouseUp(TestEvents.point(31, 31))
        #expect(fixture.selection.selection.ids == [fixture.objects.a])
        #expect(tool.start == nil)

        tool.mouseDown(TestEvents.point(0, 0))
        tool.mouseDragged(TestEvents.point(160, 70))
        #expect(tool.isMarquee)
        #expect(tool.marqueeRect == Rect(x: 0, y: 0, width: 160, height: 70))
        tool.flagsChanged(TestEvents.point(0, 0, .shift))
        #expect(tool.current?.modifiers == .shift)
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        tool.drawOverlay(in: context, viewport: fixture.host.viewport)
        tool.mouseUp(TestEvents.point(160, 70, .shift))
        #expect(fixture.selection.selection.ids == [fixture.objects.b], "Shift-marquee toggled both")

        tool.mouseDown(TestEvents.point(220, 30, .option))
        tool.mouseUp(TestEvents.point(220, 30, .option))
        #expect(fixture.selection.selection.ids == [fixture.objects.member], "Option-click subselects a group member")
    }

    @Test func strayEventsAndCancelDoNothing() async {
        let fixture = await Fixture.make()
        let tool = fixture.tool
        tool.mouseDragged(TestEvents.point(10, 10))
        tool.flagsChanged(TestEvents.point(10, 10, .shift))
        tool.mouseUp(TestEvents.point(10, 10))
        #expect(tool.current == nil && fixture.selection.selection.isEmpty)
        tool.mouseDown(TestEvents.point(30, 30))
        tool.cancel()
        tool.mouseUp(TestEvents.point(30, 30))
        #expect(fixture.selection.selection.ids == [fixture.objects.a], "the press selects (OBJ-005: so a drag can move it); Esc abandons only the drag")
        fixture.selection.model.clear()
        #expect(!tool.keyDown(TestEvents.escape))
        let context = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        tool.drawOverlay(in: context, viewport: fixture.host.viewport)
        tool.deactivate()
        tool.mouseDown(TestEvents.point(30, 30))
        tool.mouseUp(TestEvents.point(30, 30))
        #expect(fixture.selection.selection.isEmpty, "no context after deactivation")
    }

    @Test func installReplacesTheStubAndTheSelectCommands() {
        let commands = CommandRegistry()
        let tools = ToolRegistry()
        StandardCommands.register(into: commands)
        tools.registerBuiltIn()
        #expect(tools.makeTool(.pointer) is UnimplementedTool)
        SelectionCommands.install(commands: commands, tools: tools)
        #expect(tools.makeTool(.pointer) is PointerTool)
        #expect(tools.descriptor(for: .pointer)?.shortcut == KeyEquivalent("v"))
        let all = commands.command(SelectionCommands.ID.selectAll)
        #expect(all?.title == "All" && all?.menuPath?.components == ["Edit", "Select"])
        #expect(all?.action.responderSelectorName == "selectAll:")
        #expect(commands.command(SelectionCommands.ID.selectNone)?.defaultKey == KeyEquivalent("tab"))
        #expect(commands.command(SelectionCommands.ID.invert)?.action.responderSelectorName == "invertSelection:")
        let tree = MenuTreeBuilder.build(registry: commands, shortcuts: ShortcutSet.builtInDefault(commands: commands.commands))
        let select = tree.items(inMenu: "Edit")?.first { $0.title == "Select" }
        #expect(select?.commandIDs == [
            SelectionCommands.ID.selectAll, ContextMenuCatalog.ID.superselect, ContextMenuCatalog.ID.subselect, SelectionCommands.ID.selectNone, SelectionCommands.ID.invert,
        ])
        #expect(ShortcutSet.builtInDefault(commands: commands.commands).conflicts().isEmpty)
        #expect(SelectionToolOptions.contactSensitive.defaultValue == false)
        #expect(SelectionToolOptions.lassoContactSensitive.id == "tools.lasso.contact_sensitive")
    }
}

@Suite @MainActor struct SelectionOverlayTests {
    let viewport = SelectionFixture.viewport

    func bitmap() -> CGContext {
        CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    @Test func localOutlinesCarryGlyphsAndSubSelectedPoints() async {
        let fixture = await SelectionFixture.make()
        let overlay = SelectionOverlay(document: fixture.document, viewport: viewport)
        let point = fixture.corner(of: fixture.a)
        let missing = SelectionID(NodeID(counter: 99, replica: 9))
        let selection = Selection([fixture.group, missing]).applying([fixture.a], sub: [fixture.a: .points([point])], mode: .add)
        let outlines = overlay.outlines(for: selection)
        #expect(outlines.map(\.id) == [fixture.group, fixture.a], "unresolvable ids draw nothing")
        #expect(outlines[0].anchors.isEmpty, "a group is outlined by its members, without points")
        #expect(!outlines[0].path.isEmpty)
        #expect(outlines[1].anchors.count == 4)
        #expect(outlines[1].anchors.filter(\.isSelected).map(\.reference) == [point])
        #expect(outlines[1].anchors.allSatisfy { $0.shape == .square }, "corners are squares")
        #expect(outlines[1].handles.isEmpty, "a corner's handles are retracted")
        #expect(outlines[1].path.boundingBoxOfPath == CGRect(x: 10, y: 10, width: 50, height: 50))
        let segments = Selection().applying([fixture.a], sub: [fixture.a: .segments([SegmentReference(node: fixture.a.node, contour: .zero, from: point.point)])], mode: .replace)
        #expect(overlay.outlines(for: segments)[0].anchors.allSatisfy { !$0.isSelected })
    }

    @Test func curvePointsShowCirclesAndHandlesWhenSelected() async throws {
        let document = DocumentHandle.memory(title: "Glyphs")
        let change = await document.perform(CreateShape(.ellipse, size: Size(width: 40, height: 20), transform: .translation(x: 10, y: 10))).value
        let id = SelectionID(try #require(change?.createdObjects.first))
        let top = PointReference(node: id.node, contour: .zero, point: OpID(counter: 1, replica: 0))
        let overlay = SelectionOverlay(document: document, viewport: viewport, glyphs: .init(smallerHandles: true, solidPoints: false))
        let outline = try #require(overlay.outlines(for: Selection().applying([id], sub: [id: .points([top])], mode: .replace)).first)
        #expect(outline.anchors.map(\.shape) == [.circle, .square, .square, .square], "only the selected curve point is a circle")
        #expect(outline.handles.count == 2)
        #expect(outline.handles[0].anchor == Point(x: 30, y: 10))
        #expect(overlay.glyphs.size == SelectionOverlay.anchorSize / 2)
        #expect(SelectionOverlay.GlyphStyle().size == SelectionOverlay.anchorSize)
        let connector = SelectionOverlay.Anchor(reference: top, viewPoint: Point(x: 5, y: 5), kind: .connector, isSelected: true)
        #expect(connector.shape == .triangle)
        #expect(SelectionOverlay.glyphPath(connector, size: 4).boundingBoxOfPath == CGRect(x: 3, y: 3, width: 4, height: 4))
        #expect(SelectionOverlay.glyphPath(outline.anchors[0], size: 5).boundingBoxOfPath.width == 5)
        let context = bitmap()
        overlay.draw(in: context, selection: Selection().applying([id], sub: [id: .points([top])], mode: .replace), participants: [], showsRemote: true,
                     accent: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        #expect(context.makeImage() != nil)
    }

    @Test func shapesCoverEveryKindAndCurves() {
        var curve = DisplayPath()
        curve.move(to: Point(x: 0, y: 0))
        curve.addQuadCurve(control: Point(x: 5, y: 10), to: Point(x: 10, y: 0))
        curve.addCubicCurve(control1: Point(x: 12, y: 5), control2: Point(x: 15, y: 5), to: Point(x: 20, y: 0))
        curve.close()
        #expect(SelectionOverlay.anchorPoints(of: curve).map(\.element) == [0, 1, 2])
        let path = CGMutablePath()
        SelectionOverlay.add(curve, transform: .identity, to: path)
        #expect(!path.isEmpty)
        let rect = Rect(x: 1, y: 2, width: 3, height: 4)
        let square = DisplayItem.path(PathItem(path: DisplayPath(rect: rect), appearance: .fillAndStroke(fill: .white, stroke: .black)))
        #expect(SelectionOverlay.shape(of: .image(ImageItem(assetID: "a", rect: rect))).path == DisplayPath(rect: rect))
        #expect(SelectionOverlay.shape(of: .text(TextRunItem(text: "t", origin: .zero, bounds: rect))).path == DisplayPath(rect: rect))
        #expect(SelectionOverlay.shape(of: .fill(FillItem(path: curve, paint: .solid(.black)))).path == curve)
        #expect(SelectionOverlay.shape(of: .group(GroupItem(children: []))).path.isEmpty)
        #expect(SelectionOverlay.shape(of: .stroke(StrokeItem(path: curve, paint: .solid(.black)))).path == curve)
        #expect(SelectionOverlay.leaves(of: .group(GroupItem(children: [.group(GroupItem(children: [])), square])), path: [7]).map(\.path) == [[7, 1]])
    }

    @Test func remoteMarksNestAndStackTags() async {
        let fixture = await SelectionFixture.make()
        let overlay = SelectionOverlay(document: fixture.document, viewport: viewport)
        let priya = RemoteParticipant(id: "s1", name: "Priya", colorIndex: 0, selection: [fixture.a, SelectionID(NodeID(counter: 42, replica: 9))])
        let sam = RemoteParticipant(id: "s2", name: "Sam", colorIndex: 13, selection: [fixture.a])
        let marks = overlay.remoteMarks(for: [priya, sam])
        #expect(marks.count == 2, "a node not received yet draws nothing")
        #expect(marks[0].nesting == 0 && marks[1].nesting == 1)
        #expect(marks[1].rect.width - marks[0].rect.width == 2 * SelectionOverlay.nestSpacing)
        #expect(marks[0].rect.minX < 10 - SelectionOverlay.remoteOutset + 0.001)
        #expect(marks[0].tagRect.maxX == marks[0].rect.maxX, "tag at the top-right corner")
        #expect(marks[0].tagRect.maxY == marks[0].rect.minY)
        #expect(marks[1].tagRect.maxY < marks[0].tagRect.minY + 0.001, "stacked above")
        #expect(marks[1].color == PresencePalette.colors[1], "colours wrap after twelve")
        #expect(PresencePalette.color(at: -1) == PresencePalette.colors[11])
        #expect(SelectionOverlay.tagSize(for: "Priya").width > SelectionOverlay.tagSize(for: "P").width)

        let context = bitmap()
        let pointed = Selection().applying([fixture.b], sub: [fixture.b: .points([fixture.corner(of: fixture.b)])], mode: .replace)
        overlay.draw(in: context, selection: pointed, participants: [priya, sam], showsRemote: true, accent: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        overlay.draw(in: context, selection: .empty, participants: [priya], showsRemote: false, accent: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        let image = context.makeImage()!
        #expect(image.width == 400)
    }

    @Test func stubPresenceNotifiesObservers() {
        let presence = StubPresenceModel()
        var count = 0
        let token = presence.observe { count += 1 }
        presence.participants = [RemoteParticipant(id: "a", name: "A", colorIndex: 2)]
        presence.stopObserving(token)
        presence.participants = []
        #expect(count == 1)
        #expect(RemoteParticipant(id: "a", name: "A", colorIndex: 2).selection.isEmpty)
    }
}

@MainActor
final class SelectionFlag {
    var value = false
}

@Suite @MainActor struct SelectionWindowTests {
    private func window(_ environment: TestEnvironment, presence: StubPresenceModel = StubPresenceModel()) async -> (DocumentWindowController, SelectionFixture) {
        var document = environment.document
        document.makePresence = { _ in presence }
        let fixture = await SelectionFixture.make()
        return (DocumentWindowController(document: fixture.document, environment: document), fixture)
    }

    @Test func selectCommandsValidateAndActThroughTheResponderChain() async {
        let environment = TestEnvironment()
        let (controller, _) = await window(environment)
        defer { controller.close() }
        var published = 0
        controller.onSelectionChange = { _ in published += 1 }
        #expect(controller.validate(selector: #selector(DocumentWindowController.selectAll(_:))))
        #expect(!controller.validate(selector: #selector(DocumentWindowController.selectNone(_:))), "nothing to deselect")
        #expect(controller.validate(selector: #selector(NSResponder.cancelOperation(_:))))
        controller.selectAll(nil)
        #expect(controller.selection.model.count == 4)
        let changes = controller.documentHandle.changeCount
        #expect(controller.canvas.accessibilityValue() as? String == "changes=\(changes) selected=4")
        #expect(controller.validate(selector: #selector(DocumentWindowController.selectNone(_:))))
        controller.invertSelection(nil)
        #expect(controller.selection.model.isEmpty)
        controller.selectAll(nil)
        controller.selectNone(nil)
        #expect(controller.selection.model.isEmpty)
        #expect(published == 4)
        let item = NSMenuItem(title: "All", action: #selector(DocumentWindowController.selectAll(_:)), keyEquivalent: "")
        #expect(controller.validateMenuItem(item))
        #expect(controller.validateMenuItem(NSMenuItem(title: "x", action: nil, keyEquivalent: "")))
        #expect(!controller.isEditingText)
    }

    @Test func clearDeletesTheSelectedObjectsOrPoints() async throws {
        let environment = TestEnvironment()
        let (controller, fixture) = await window(environment)
        defer { controller.close() }
        let document = controller.documentHandle
        #expect(!controller.validate(selector: #selector(DocumentWindowController.delete(_:))), "nothing selected")
        #expect(controller.deletionCommand() == nil)
        let before = document.changeCount
        controller.delete(nil)
        await document.settle()
        #expect(document.changeCount == before)
        controller.selection.model.set(Selection([fixture.a, fixture.b]))
        #expect(controller.validate(selector: #selector(DocumentWindowController.delete(_:))))
        controller.delete(nil)
        await document.settle()
        #expect(document.selectableIDs() == [fixture.group, fixture.square])
        #expect(document.undoTitle == "Undo Delete")
        let line = try #require(await document.addPath([Point(x: 300, y: 200), Point(x: 350, y: 200), Point(x: 350, y: 250)]))
        let contour = try #require(document.path(line)?.contours.first)
        let point = PointReference(node: line.node, contour: contour.id, point: contour.points[1].id)
        controller.selection.model.set(Selection().applying([line], sub: [line: .points([point])], mode: .replace))
        #expect(controller.deletionCommand()?.label == "Delete Point")
        controller.delete(nil)
        await document.settle()
        #expect(document.path(line)?.pointCount == 2)
        #expect(document.undoTitle == "Undo Delete Point")
        let other = try #require(await document.addPath([Point(x: 300, y: 260), Point(x: 350, y: 260), Point(x: 350, y: 290)]))
        let otherContour = try #require(document.path(other)?.contours.first)
        let lineContour = try #require(document.path(line)?.contours.first)
        let points: [SelectionID: SubSelection] = [
            line: .points([PointReference(node: line.node, contour: lineContour.id, point: lineContour.points[0].id)]),
            other: .points([PointReference(node: other.node, contour: otherContour.id, point: otherContour.points[0].id)]),
        ]
        controller.selection.model.set(Selection().applying([line, other], sub: points, mode: .replace))
        #expect(controller.deletionCommand()?.label == "Delete Points", "points of two paths are one change")
    }

    @Test func tabDoesNotDeselectWhileATextFieldEdits() async {
        let environment = TestEnvironment()
        let (controller, _) = await window(environment)
        defer { controller.close() }
        controller.selectAll(nil)
        let field = NSTextField(string: "x")
        controller.window?.contentView?.addSubview(field)
        controller.showWindow(nil)
        controller.window?.makeFirstResponder(field)
        if controller.isEditingText {
            #expect(!controller.validate(selector: #selector(DocumentWindowController.selectNone(_:))))
            #expect(!controller.validate(selector: #selector(DocumentWindowController.delete(_:))))
        }
        field.removeFromSuperview()
    }

    @Test func windowSelectionReadsThePreferences() async {
        let environment = TestEnvironment()
        let (controller, _) = await window(environment)
        defer { controller.close() }
        environment.preferences.set(true, for: SelectionToolOptions.contactSensitive)
        environment.preferences.set(5, for: PreferenceCatalog.General.pickDistance)
        controller.selection.marquee(Rect(x: 30, y: 30, width: 90, height: 10), viewport: SelectionFixture.viewport, modifiers: [], subselect: false)
        #expect(controller.selection.model.count == 2, "contact-sensitive from the tool option")
        #expect(controller.selection.pickDistance() == 5)
        environment.preferences.set(true, for: PreferenceCatalog.General.smallerHandles)
        #expect(controller.canvas.glyphStyle().smallerHandles)
    }

    @Test func fitSelectionZoomsToTheSelectedBounds() async {
        let environment = TestEnvironment()
        StandardCommands.register(into: environment.commands)
        let (controller, fixture) = await window(environment)
        defer { controller.close() }
        ViewCommands.install(into: environment.commands, target: { controller }, newDocument: {})
        var beeps = 0
        controller.beep = { beeps += 1 }
        controller.fitSelection()
        #expect(beeps == 1)
        controller.selection.model.set(Selection([fixture.a]))
        #expect(environment.commands.validate(StandardCommands.ID.fitSelection) == .enabled)
        #expect(environment.commands.perform(StandardCommands.ID.fitSelection))
        #expect(controller.viewport.zoom > 4)
        controller.enterMagnification("100%")
        controller.enterMagnification(StatusBarView.fitSelectionTitle)
        #expect(controller.viewport.zoom > 4)
    }

    @Test func theCanvasDrawsSelectionsAndReportsChanges() async {
        let environment = TestEnvironment()
        let presence = StubPresenceModel()
        let (controller, fixture) = await window(environment, presence: presence)
        defer { controller.close() }
        let canvas = controller.canvas
        controller.selection.model.set(Selection([fixture.a]))
        presence.participants = [RemoteParticipant(id: "s", name: "Priya", colorIndex: 3, selection: [fixture.b])]
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.drawOverlay(in: context)
        let before = controller.documentHandle.changeCount
        await controller.documentHandle.addRectangles([Rect(x: 0, y: 0, width: 5, height: 5)])
        #expect(canvas.accessibilityValue() as? String == CanvasView.accessibilityStatus(changes: before + 1, selected: 1))
        canvas.presence = nil
        canvas.drawOverlay(in: context)
        canvas.selectionController = nil
        canvas.drawOverlay(in: context)
        #expect(canvas.accessibilityValue() as? String == "changes=\(before + 1) selected=0")
    }
}
