import AppKit
import SwiftUI
import Testing
import WTGeometry
import WTRender
@testable import WireTuner

/// A small canvas: a fixed page background, two filled rectangles, a group of two and an
/// unfilled square, all at zoom 1 so view points equal pasteboard points.
@MainActor
enum SelectionFixture {
    static func rect(_ x: Double, _ y: Double, _ size: Double = 50) -> DisplayItem {
        .path(PathItem(path: DisplayPath(rect: Rect(x: x, y: y, width: size, height: size)), appearance: .fillAndStroke(fill: .white, stroke: .black)))
    }

    static let items: [DisplayItem] = [
        .fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 400, height: 300)), paint: .solid(.white))),
        rect(10, 10),
        rect(100, 10),
        .group(GroupItem(children: [rect(200, 10, 40), rect(250, 10, 40)])),
        .stroke(StrokeItem(path: DisplayPath(rect: Rect(x: 10, y: 100, width: 50, height: 50)), paint: .solid(.black))),
    ]

    static func content() -> PlaceholderDocumentContent {
        PlaceholderDocumentContent(canvas: "selection", items: items, fixedItemCount: 1)
    }

    static func document(_ content: PlaceholderDocumentContent = content()) -> DocumentHandle {
        let handle = DocumentHandle.placeholder(title: "Selection", content: content)
        handle.pages = [Rect(x: 0, y: 0, width: 400, height: 300)]
        return handle
    }

    static let viewport = Viewport(size: Size(width: 400, height: 300))
}

@MainActor
final class SelectionFlag {
    var value = false
}

@Suite struct SelectionValueTests {
    let a = SelectionID.item([1])
    let b = SelectionID.item([2])
    let c = SelectionID.item([3, 0])

    @Test func idsAreIndexPathsThatShiftWhenEarlierItemsGo() {
        #expect(a.indexPath == [1] && a.topLevelIndex == 1)
        #expect(c.description == "3.0")
        #expect(a < b && c > b && SelectionID.item([3]) < c)
        #expect(a.shifted(afterRemoving: [1]) == nil)
        #expect(c.shifted(afterRemoving: [1]) == .item([2, 0]))
        #expect(a.shifted(afterRemoving: [5]) == a)
        #expect(SelectionID.item([]).shifted(afterRemoving: [0]) == nil)
        #expect(SelectionID.item([]).topLevelIndex == nil)
    }

    @Test func referencesOrderByPathThenElement() {
        #expect(PointReference(leafPath: [1], element: 2) < PointReference(leafPath: [1], element: 3))
        #expect(PointReference(leafPath: [1], element: 9) < PointReference(leafPath: [2], element: 0))
        #expect(SegmentReference(leafPath: [1], contour: 0, segment: 2) < SegmentReference(leafPath: [1], contour: 1, segment: 0))
        #expect(SegmentReference(leafPath: [1], contour: 5, segment: 5) < SegmentReference(leafPath: [2], contour: 0, segment: 0))
    }

    @Test func subSelectionsMergeToggleAndShift() {
        let p1 = PointReference(leafPath: [1], element: 1)
        let p2 = PointReference(leafPath: [3, 1], element: 2)
        let s1 = SegmentReference(leafPath: [1], contour: 0, segment: 1)
        let s2 = SegmentReference(leafPath: [4], contour: 0, segment: 0)
        #expect(SubSelection.points([p1]).adding(.points([p2])) == .points([p1, p2]))
        #expect(SubSelection.segments([s1]).adding(.segments([s2])) == .segments([s1, s2]))
        #expect(SubSelection.points([p1]).adding(.textRange(0..<3)) == .textRange(0..<3))
        #expect(SubSelection.points([p1, p2]).toggling(.points([p1])) == .points([p2]))
        #expect(SubSelection.segments([s1]).toggling(.segments([s1, s2])) == .segments([s2]))
        #expect(SubSelection.textRange(0..<1).toggling(.points([p1])) == .points([p1]))
        #expect(SubSelection.points([]).isEmpty && SubSelection.segments([]).isEmpty && SubSelection.textRange(2..<2).isEmpty)
        #expect(!SubSelection.textRange(0..<2).isEmpty)
        #expect(SubSelection.points([p1, p2]).shifted(afterRemoving: [1]) == .points([PointReference(leafPath: [2, 1], element: 2)]))
        #expect(SubSelection.segments([s1, s2]).shifted(afterRemoving: [2]) == .segments([s1, SegmentReference(leafPath: [3], contour: 0, segment: 0)]))
        #expect(SubSelection.textRange(1..<4).shifted(afterRemoving: [0]) == .textRange(1..<4))
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
        let p1 = PointReference(leafPath: [1], element: 1)
        let p2 = PointReference(leafPath: [1], element: 2)
        var selection = Selection().applying([a], sub: [a: .points([p1])], mode: .replace)
        #expect(selection.subSelection(of: a) == .points([p1]))
        selection = selection.applying([a], sub: [a: .points([p2])], mode: .add)
        #expect(selection.subSelection(of: a) == .points([p1, p2]))
        selection = selection.applying([b], sub: [b: .textRange(0..<2)], mode: .add)
        #expect(selection.subSelection(of: b) == .textRange(0..<2))
        // Toggling points inside a selected object flips only those points.
        selection = selection.applying([a], sub: [a: .points([p1])], mode: .toggle)
        #expect(selection.contains(a) && selection.subSelection(of: a) == .points([p2]))
        // Flipping the last point leaves the object selected with no sub-selection.
        selection = selection.applying([a], sub: [a: .points([p2])], mode: .toggle)
        #expect(selection.contains(a) && selection.subSelection(of: a) == nil)
        // A toggle that adds an object brings its sub-selection; one without a sub-selection
        // before gets the new one.
        selection = selection.applying([c], sub: [c: .points([p1])], mode: .toggle)
        #expect(selection.subSelection(of: c) == .points([p1]))
        selection = selection.applying([a], sub: [a: .points([p1])], mode: .toggle)
        #expect(selection.subSelection(of: a) == .points([p1]))
        // Toggling an object off drops its sub-selection.
        selection = selection.applying([b], mode: .toggle)
        #expect(!selection.contains(b) && selection.subSelection(of: b) == nil)
        // Sub-selections of objects not selected are ignored.
        selection.setSubSelection(.points([p1]), for: b)
        #expect(selection.subSelection(of: b) == nil)
        selection.setSubSelection(nil, for: a)
        #expect(selection.subSelection(of: a) == nil)
    }

    @Test func invertsRemapsFiltersAndFollowsDeletions() {
        let universe = [a, b, c]
        let p = PointReference(leafPath: [3, 0], element: 0)
        let selection = Selection([b]).applying([c], sub: [c: .points([p])], mode: .add)
        #expect(selection.inverted(within: universe).ids == [a])
        let removed = selection.removingItems(at: [2])
        #expect(removed.ids == [.item([2, 0])])
        #expect(removed.subSelection(of: .item([2, 0])) == .points([PointReference(leafPath: [2, 0], element: 0)]))
        #expect(selection.filtered { $0 == b }.ids == [b])
        #expect(selection.filtered { _ in true }.subSelection(of: c) == .points([p]))
        #expect(selection.remapped { $0 == b ? c : nil }.ids == [c])
    }
}

@Suite @MainActor struct SelectionModelTests {
    @Test func notifiesOnlyOnChangeAndPublishesToPanels() {
        let model = SelectionModel()
        var heard: [Int] = []
        let token = model.observe { heard.append($0.count) }
        model.apply([.item([1])], mode: .replace)
        model.apply([.item([1])], mode: .add)
        model.set(Selection([.item([1]), .item([2])]))
        #expect(model.ids == [.item([1]), .item([2])] && model.count == 2 && !model.isEmpty)
        model.clear()
        #expect(heard == [1, 2, 0])
        model.stopObserving(token)
        model.apply([.item([3])], mode: .replace)
        #expect(heard == [1, 2, 0])

        let active = ActiveSelection()
        #expect(active.summary == "No document")
        active.model = SelectionModel()
        #expect(active.summary == "Nothing selected")
        active.model?.apply([.item([1])], mode: .replace)
        #expect(active.summary == "1 object selected")
        active.model?.apply([.item([2])], mode: .add)
        #expect(active.summary == "2 objects selected")
    }

    @Test func panelBodiesObserveTheActiveSelection() {
        let active = ActiveSelection(model: SelectionModel(Selection([.item([1])])))
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

    @Test func clicksSelectToggleKeepAndClear() {
        let document = SelectionFixture.document()
        let controller = SelectionController(document: document)
        controller.click(at: Point(x: 30, y: 30), viewport: viewport, modifiers: [], subselect: false)
        #expect(controller.selection.ids == [.item([1])])
        controller.click(at: Point(x: 120, y: 30), viewport: viewport, modifiers: .shift, subselect: false)
        #expect(controller.selection.ids == [.item([1]), .item([2])])
        // A plain click on a selected object keeps the whole selection.
        controller.click(at: Point(x: 30, y: 30), viewport: viewport, modifiers: [], subselect: false)
        #expect(controller.selection.count == 2)
        controller.click(at: Point(x: 30, y: 30), viewport: viewport, modifiers: .shift, subselect: false)
        #expect(controller.selection.ids == [.item([2])])
        // The page background is not an object: clicking it is clicking nothing.
        controller.click(at: Point(x: 380, y: 280), viewport: viewport, modifiers: .shift, subselect: false)
        #expect(controller.selection.ids == [.item([2])])
        controller.click(at: Point(x: 380, y: 280), viewport: viewport, modifiers: [], subselect: false)
        #expect(controller.selection.isEmpty)
        // The unfilled square's interior does not select it; its edge does.
        controller.click(at: Point(x: 35, y: 125), viewport: viewport, modifiers: [], subselect: false)
        #expect(controller.selection.isEmpty)
        controller.click(at: Point(x: 10, y: 125), viewport: viewport, modifiers: [], subselect: false)
        #expect(controller.selection.ids == [.item([4])])
        // A group member selects the group; Option selects the member.
        controller.click(at: Point(x: 220, y: 30), viewport: viewport, modifiers: [], subselect: false)
        #expect(controller.selection.ids == [.item([3])])
        controller.click(at: Point(x: 220, y: 30), viewport: viewport, modifiers: [], subselect: true)
        #expect(controller.selection.ids == [.item([3, 0])])
        #expect(controller.hitTesterBuilds == 1, "the index is built once per content")
    }

    @Test func subselectClicksPickPointsAndSegments() {
        let controller = SelectionController(document: SelectionFixture.document(), pickDistance: { 4 })
        controller.click(at: Point(x: 10, y: 10), viewport: viewport, modifiers: [], subselect: true)
        let id = SelectionID.item([1])
        #expect(controller.selection.ids == [id])
        guard case let .points(points)? = controller.selection.subSelection(of: id) else {
            Issue.record("expected a point sub-selection")
            return
        }
        #expect(points.count == 1 && points.first?.leafPath == [1])
        // A click on the middle of an edge picks the segment.
        controller.click(at: Point(x: 35, y: 10), viewport: viewport, modifiers: [], subselect: true)
        guard case let .segments(segments)? = controller.selection.subSelection(of: id) else {
            Issue.record("expected a segment sub-selection")
            return
        }
        #expect(segments.first?.leafPath == [1])
        #expect(SelectionController.subSelection(for: HitResult(itemPath: [1], leafPath: [1], kind: .fill, distance: 0)) == nil)
        #expect(SelectionController.subSelection(for: HitResult(itemPath: [1], leafPath: [1], kind: .stroke(nil), distance: 0)) == nil)
        #expect(SelectionController.subSelection(for: HitResult(itemPath: [1], leafPath: [1], kind: .handle(element: 2, control: 1), distance: 0))
            == .points([PointReference(leafPath: [1], element: 2)]))
        #expect(SelectionController.subSelection(for: HitResult(itemPath: [1], leafPath: [1], kind: .stroke(PathLocation(contour: 0, segment: 3, t: 0.5)), distance: 0))
            == .segments([SegmentReference(leafPath: [1], contour: 0, segment: 3)]))
    }

    @Test func marqueesAreEnclosedOrContactSensitive() {
        let flag = SelectionFlag()
        let controller = SelectionController(document: SelectionFixture.document(), contactSensitive: { flag.value })
        controller.marquee(Rect(x: 0, y: 0, width: 160, height: 70), viewport: viewport, modifiers: [], subselect: false)
        #expect(controller.selection.ids == [.item([1]), .item([2])], "in draw order, the page excluded")
        controller.marquee(Rect(x: 30, y: 30, width: 90, height: 10), viewport: viewport, modifiers: [], subselect: false)
        #expect(controller.selection.isEmpty, "touching is not enclosing")
        flag.value = true
        controller.marquee(Rect(x: 30, y: 30, width: 90, height: 10), viewport: viewport, modifiers: [], subselect: false)
        #expect(controller.selection.ids == [.item([1]), .item([2])])
        // Shift toggles each picked object.
        controller.marquee(Rect(x: 95, y: 5, width: 60, height: 60), viewport: viewport, modifiers: .shift, subselect: false)
        #expect(controller.selection.ids == [.item([1])])
        // Subselecting, anchors inside the marquee become the sub-selection.
        flag.value = false
        controller.marquee(Rect(x: 5, y: 5, width: 10, height: 10), viewport: viewport, modifiers: [], subselect: true)
        #expect(controller.selection.ids == [.item([1])])
        #expect(controller.selection.subSelection(of: .item([1])) == .points([PointReference(leafPath: [1], element: 0)]))
        // Subselecting a whole group member without anchors inside: enclosed members only.
        controller.marquee(Rect(x: 195, y: 5, width: 50, height: 50), viewport: viewport, modifiers: [], subselect: true)
        #expect(controller.selection.ids.contains(.item([3, 0])))
    }

    @Test func commandsSelectAllNoneAndInvertOnThePage() {
        let document = SelectionFixture.document()
        let controller = SelectionController(document: document)
        #expect(controller.canSelectAll)
        #expect(controller.selectedBounds == nil)
        controller.selectAll()
        #expect(controller.selection.ids == [.item([1]), .item([2]), .item([3]), .item([4])])
        controller.model.apply([.item([2])], mode: .replace)
        controller.invert()
        #expect(controller.selection.ids == [.item([1]), .item([3]), .item([4])])
        #expect(controller.selectedBounds?.minX ?? 0 < 10.5)
        controller.selectNone()
        #expect(controller.selection.isEmpty)
        // Objects off the current page are not "All".
        document.pages = [Rect(x: 1000, y: 1000, width: 10, height: 10)]
        #expect(!controller.canSelectAll)
    }

    @Test func deletedObjectsLeaveTheSelectionAndTheRestFollow() {
        let content = SelectionFixture.content()
        let document = SelectionFixture.document(content)
        let controller = SelectionController(document: document)
        controller.model.set(Selection([.item([1]), .item([3, 1]), .item([4])]))
        content.removeItems(at: [1])
        #expect(controller.selection.ids == [.item([2, 1]), .item([3])], "deleted object gone, later ones shifted")
        #expect(document.changeCount == 1)
        // Fixed items and indices past the end are never removed.
        content.removeItems(at: [0, 99])
        #expect(document.changeCount == 1)
        // A change that leaves an id unresolvable drops it quietly.
        controller.model.set(Selection([.item([2, 1]), .item([2, 9])]))
        content.submit(DocumentEdit(label: "Add", insertedItems: [SelectionFixture.rect(300, 200)]))
        #expect(controller.selection.ids == [.item([2, 1])])
        #expect(document.item(for: .item([0])) == nil, "the page is not an object")
        #expect(document.item(for: .item([1, 0])) == nil, "not a group")
        #expect(document.item(for: .item([99])) == nil)
        #expect(document.item(for: .item([])) == nil)
    }

    @Test func removalObserversCanStop() {
        let content = SelectionFixture.content()
        let document = SelectionFixture.document(content)
        var heard: [IndexSet] = []
        let token = document.observeRemovals { heard.append($0) }
        content.removeItems(at: [2])
        document.stopObserving(token)
        content.removeItems(at: [1])
        #expect(heard == [[2]])
    }
}

@Suite @MainActor struct PointerToolTests {
    @MainActor
    final class Fixture {
        let tool = PointerTool()
        let host = RecordingHost(viewport: SelectionFixture.viewport)
        let document = SelectionFixture.document()
        let selection: SelectionController
        init() {
            selection = SelectionController(document: document)
            tool.activate(in: ToolContext(document: document, host: host, selection: selection))
        }
    }

    @Test func clickAndMarqueeSelectThroughTheController() {
        let fixture = Fixture()
        let tool = fixture.tool
        #expect(fixture.host.messages == [PointerTool.statusMessage])
        #expect(tool.cursor == .arrow)
        tool.mouseDown(TestEvents.point(30, 30))
        tool.mouseDragged(TestEvents.point(31, 31))
        #expect(!tool.isMarquee && tool.marqueeRect == nil)
        tool.mouseUp(TestEvents.point(31, 31))
        #expect(fixture.selection.selection.ids == [.item([1])])
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
        #expect(fixture.selection.selection.ids == [.item([2])], "Shift-marquee toggled both")

        // Option-click subselects a group member.
        tool.mouseDown(TestEvents.point(220, 30, .option))
        tool.mouseUp(TestEvents.point(220, 30, .option))
        #expect(fixture.selection.selection.ids == [.item([3, 0])])
    }

    @Test func strayEventsAndCancelDoNothing() {
        let fixture = Fixture()
        let tool = fixture.tool
        tool.mouseDragged(TestEvents.point(10, 10))
        tool.flagsChanged(TestEvents.point(10, 10, .shift))
        tool.mouseUp(TestEvents.point(10, 10))
        #expect(tool.current == nil && fixture.selection.selection.isEmpty)
        tool.mouseDown(TestEvents.point(30, 30))
        tool.cancel()
        tool.mouseUp(TestEvents.point(30, 30))
        #expect(fixture.selection.selection.isEmpty)
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
        #expect(select?.commandIDs == [SelectionCommands.ID.selectAll, SelectionCommands.ID.selectNone, SelectionCommands.ID.invert])
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

    @Test func localOutlinesCarryAnchorsAndSubSelectedPoints() {
        let document = SelectionFixture.document()
        let overlay = SelectionOverlay(document: document, viewport: viewport)
        let point = PointReference(leafPath: [1], element: 0)
        let selection = Selection([.item([3]), .item([9])]).applying([.item([1])], sub: [.item([1]): .points([point])], mode: .add)
        let outlines = overlay.outlines(for: selection)
        #expect(outlines.map(\.id) == [.item([3]), .item([1])], "unresolvable ids draw nothing")
        #expect(outlines[0].anchors.count == 8, "four anchors per member of the group")
        #expect(outlines[0].anchors.first?.reference.leafPath == [3, 0])
        #expect(outlines[1].anchors.filter(\.isSelected).map(\.reference) == [point])
        #expect(outlines[1].path.boundingBoxOfPath == CGRect(x: 10, y: 10, width: 50, height: 50))
        let segmentSelection = Selection().applying([.item([1])], sub: [.item([1]): .segments([SegmentReference(leafPath: [1], contour: 0, segment: 0)])], mode: .replace)
        #expect(overlay.outlines(for: segmentSelection)[0].anchors.allSatisfy { !$0.isSelected })
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
        #expect(SelectionOverlay.shape(of: .image(ImageItem(assetID: "a", rect: rect))).path == DisplayPath(rect: rect))
        #expect(SelectionOverlay.shape(of: .text(TextRunItem(text: "t", origin: .zero, bounds: rect))).path == DisplayPath(rect: rect))
        #expect(SelectionOverlay.shape(of: .fill(FillItem(path: curve, paint: .solid(.black)))).path == curve)
        #expect(SelectionOverlay.shape(of: .group(GroupItem(children: []))).path.isEmpty)
        #expect(SelectionOverlay.shape(of: .stroke(StrokeItem(path: curve, paint: .solid(.black)))).path == curve)
        #expect(SelectionOverlay.leaves(of: .group(GroupItem(children: [.group(GroupItem(children: [])), SelectionFixture.rect(0, 0)])), path: [7]).map(\.path) == [[7, 1]])
    }

    @Test func remoteMarksNestAndStackTags() {
        let document = SelectionFixture.document()
        let overlay = SelectionOverlay(document: document, viewport: viewport)
        let priya = RemoteParticipant(id: "s1", name: "Priya", colorIndex: 0, selection: [.item([1]), .item([42])])
        let sam = RemoteParticipant(id: "s2", name: "Sam", colorIndex: 13, selection: [.item([1])])
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
        let pointed = Selection().applying([.item([2])], sub: [.item([2]): .points([PointReference(leafPath: [2], element: 0)])], mode: .replace)
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

@Suite @MainActor struct SelectionWindowTests {
    private func window(_ environment: TestEnvironment, presence: StubPresenceModel = StubPresenceModel()) -> DocumentWindowController {
        var document = environment.document
        document.makePresence = { _ in presence }
        return DocumentWindowController(document: SelectionFixture.document(), environment: document)
    }

    @Test func selectCommandsValidateAndActThroughTheResponderChain() {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        var published = 0
        controller.onSelectionChange = { _ in published += 1 }
        #expect(controller.validate(selector: #selector(DocumentWindowController.selectAll(_:))))
        #expect(!controller.validate(selector: #selector(DocumentWindowController.selectNone(_:))), "nothing to deselect")
        #expect(controller.validate(selector: #selector(NSResponder.cancelOperation(_:))))
        controller.selectAll(nil)
        #expect(controller.selection.model.count == 4)
        #expect(controller.canvas.accessibilityValue() as? String == "changes=0 selected=4")
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

    @Test func tabDoesNotDeselectWhileATextFieldEdits() {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        controller.selectAll(nil)
        let field = NSTextField(string: "x")
        controller.window?.contentView?.addSubview(field)
        controller.showWindow(nil)
        controller.window?.makeFirstResponder(field)
        if controller.isEditingText {
            #expect(!controller.validate(selector: #selector(DocumentWindowController.selectNone(_:))))
        }
        field.removeFromSuperview()
    }

    @Test func windowSelectionReadsThePreferences() {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        environment.preferences.set(true, for: SelectionToolOptions.contactSensitive)
        environment.preferences.set(5, for: PreferenceCatalog.General.pickDistance)
        controller.selection.marquee(Rect(x: 30, y: 30, width: 90, height: 10), viewport: SelectionFixture.viewport, modifiers: [], subselect: false)
        #expect(controller.selection.model.count == 2, "contact-sensitive from the tool option")
        #expect(controller.selection.pickDistance() == 5)
    }

    @Test func fitSelectionZoomsToTheSelectedBounds() {
        let environment = TestEnvironment()
        StandardCommands.register(into: environment.commands)
        let controller = window(environment)
        defer { controller.close() }
        ViewCommands.install(into: environment.commands, target: { controller }, newDocument: {})
        var beeps = 0
        controller.beep = { beeps += 1 }
        controller.fitSelection()
        #expect(beeps == 1)
        controller.selection.model.set(Selection([.item([1])]))
        #expect(environment.commands.validate(StandardCommands.ID.fitSelection) == .enabled)
        #expect(environment.commands.perform(StandardCommands.ID.fitSelection))
        #expect(controller.viewport.zoom > 4)
        controller.enterMagnification("100%")
        controller.enterMagnification(StatusBarView.fitSelectionTitle)
        #expect(controller.viewport.zoom > 4)
    }

    @Test func theCanvasDrawsSelectionsAndReportsChanges() {
        let environment = TestEnvironment()
        let presence = StubPresenceModel()
        let controller = window(environment, presence: presence)
        defer { controller.close() }
        let canvas = controller.canvas
        controller.selection.model.set(Selection([.item([1])]))
        presence.participants = [RemoteParticipant(id: "s", name: "Priya", colorIndex: 3, selection: [.item([2])])]
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.drawOverlay(in: context)
        controller.documentHandle.commandSink.submit(DocumentEdit(label: "Rectangle", insertedItems: RectangleSketchTool.items(for: Rect(x: 0, y: 0, width: 5, height: 5))))
        #expect(canvas.accessibilityValue() as? String == CanvasView.accessibilityStatus(changes: 1, selected: 1))
        canvas.presence = nil
        canvas.drawOverlay(in: context)
        canvas.selectionController = nil
        canvas.drawOverlay(in: context)
        #expect(canvas.accessibilityValue() as? String == "changes=1 selected=0")
    }
}
