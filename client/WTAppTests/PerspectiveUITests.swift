import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// FX-043 and FX-044: menu:View[Perspective Grid], the grid overlay, the Define Grids sheet and
/// the Perspective tool (attach by arrow key, slide, flip, resize, the grid's handles).
@Suite(.serialized) @MainActor struct PerspectiveUITests {
    static let page = Rect(x: 0, y: 0, width: 400, height: 300)

    @MainActor
    final class Fixture {
        let document = DocumentHandle.memory(title: "Perspective")
        let host = RecordingHost(viewport: Viewport(size: Size(width: 400, height: 300)))
        let controller: SelectionController
        let tool = PerspectiveTool()
        var rect: OpID?

        init() {
            controller = SelectionController(document: document)
            tool.activate(in: ToolContext(document: document, host: host, selection: controller))
        }

        static func make() async -> Fixture {
            let fixture = Fixture()
            fixture.document.pages = [PerspectiveUITests.page]
            await fixture.document.settle()
            fixture.rect = await fixture.document.addRectangles([Rect(x: 250, y: 160, width: 20, height: 20)]).first?.opID
            return fixture
        }

        var state: EngineState { document.state }

        func down(_ point: Point, _ modifiers: KeyModifiers = [], clicks: Int = 1) {
            tool.mouseDown(CanvasEvent(pasteboardPoint: point, viewPoint: point, modifiers: modifiers, clickCount: clicks))
        }

        func drag(_ point: Point, _ modifiers: KeyModifiers = []) {
            tool.mouseDragged(TestEvents.point(point.x, point.y, modifiers))
            tool.drawOverlay(in: GlueWorld.bitmapContext(), viewport: host.viewport)
        }

        func up(_ point: Point, _ modifiers: KeyModifiers = []) async {
            tool.mouseUp(TestEvents.point(point.x, point.y, modifiers))
            await document.settle()
        }

        /// The wrapper around `rect`, once attached.
        var wrapper: OpID? { rect.flatMap { PerspectiveReading.wrapper(of: $0, in: state) } }

        func center(_ node: OpID) -> Point? { document.object(for: SelectionID(node))?.bounds?.center }

        /// A stored grid for the page, used by it.
        func defineGrid(_ build: ((inout Wiretuner_Doc_V1_PerspectiveGrid) -> Void)? = nil) async -> OpID? {
            let page = document.pageList.pages[0]
            _ = await document.perform(DefineGrid(name: "Grid", page: page.id, usedBy: page.id)).value
            let grid = PerspectiveReading.grids(state).first?.id
            if let grid, let build {
                _ = await document.perform(EditGrid(grid, label: "Edit", fields: PerspectiveFields.GridField.allCases.filter { $0 != .name }) { values in
                    values = PerspectiveReading.grids(self.state)[0].stored
                    build(&values)
                }).value
            }
            return grid
        }
    }

    @Test func anArrowKeyAttachesTheDraggedObjectToThatPlane() async throws {
        let f = await Fixture.make()
        let rect = try #require(f.rect)
        #expect(PerspectiveTool.descriptor.id == PerspectiveTool.id && f.host.messages.last == PerspectiveTool.statusMessage)
        #expect(f.tool.cursor == .crosshair && !f.tool.hasSomethingToCancel)
        // Released without a plane: the object moves flat.
        let start = try #require(f.center(rect))
        f.down(start)
        let bounds = try #require(f.document.object(for: SelectionID(rect))?.bounds)
        #expect(f.tool.gesture == .attach(rect, bounds: bounds, plane: nil) && f.tool.hasSomethingToCancel)
        f.drag(Point(x: start.x + 10, y: start.y))
        await f.up(Point(x: start.x + 10, y: start.y))
        #expect(f.document.undoTitle == "Undo Move" || f.document.undoTitle.hasPrefix("Undo Move"))
        // A press and release without a move writes nothing.
        let moved = try #require(f.center(rect))
        let count = f.document.changeCount
        f.down(moved)
        await f.up(moved)
        #expect(f.document.changeCount == count)
        // Left Arrow mid-drag: the left wall; the release attaches the object with its corner there.
        f.down(moved)
        #expect(f.tool.keyDown(TestEvents.key("", keyCode: 123)))
        let movedBounds = try #require(f.document.object(for: SelectionID(rect))?.bounds)
        #expect(f.tool.gesture == .attach(rect, bounds: movedBounds, plane: .leftWall))
        #expect(!f.tool.keyDown(TestEvents.key("x", keyCode: 7)), "not an arrow")
        f.drag(Point(x: 240, y: 200))
        await f.up(Point(x: 240, y: 200))
        let wrapper = try #require(f.wrapper)
        #expect(f.document.undoTitle == "Undo Attach to perspective grid" && f.state.props(wrapper).perspective.plane == .leftWall)
        // The projection the scene draws is the tool's plane map of the object's cells.
        let spec = PerspectiveReading.spec(wrapper, in: f.state)
        let map = PlaneMap(spec.grid, plane: spec.effectivePlane)
        let cell = spec.grid.effectiveCellSize
        let cells = Rect(x: spec.cellPosition.x, y: spec.cellPosition.y, width: 20 / cell, height: 20 / cell)
        let corners = [cells.minPoint, Point(x: cells.maxX, y: cells.minY), cells.maxPoint, Point(x: cells.minX, y: cells.maxY)].map(map.apply)
        let drawn = try #require(f.document.object(for: SelectionID(wrapper))?.bounds)
        let expected = Rect(boundingPoints: corners)
        #expect(abs(drawn.midX - expected.midX) < 1.5 && abs(drawn.midY - expected.midY) < 1.5, "\(drawn) vs \(expected)")
        let inverse = try #require(map.cell(at: map.apply(Point(x: 1, y: 2))))
        #expect(abs(inverse.x - 1) < 1e-9 && abs(inverse.y - 2) < 1e-9)
        #expect(PlaneMap(m: [0, 0, 0, 0, 0, 0, 0, 0, 1]).inverted == nil)
        #expect(PlaneMap(m: [1, 0, 0, 0, 1, 0, 0, 0, 0]).apply(.zero).x == 0)
        // Every arrow on one- and two-point grids.
        #expect(PerspectiveTool.plane(keyCode: 124, vanishingPoints: 2) == .rightWall && PerspectiveTool.plane(keyCode: 126, vanishingPoints: 2) == .floorRight)
        #expect(PerspectiveTool.plane(keyCode: 125, vanishingPoints: 2) == .floorLeft && PerspectiveTool.plane(keyCode: 123, vanishingPoints: 1) == .wall)
        #expect(PerspectiveTool.plane(keyCode: 126, vanishingPoints: 1) == .floor && PerspectiveTool.plane(keyCode: 1, vanishingPoints: 1) == nil)
        #expect(PerspectiveTool.plane(keyCode: 124, vanishingPoints: 1) == .wall && PerspectiveTool.plane(keyCode: 125, vanishingPoints: 1) == .floor)
        // The size on the plane: its own, else the flat size in cells, else one cell.
        var sized = PerspectiveSpec(grid: PerspectiveGridSpec(cellSize: 10), cellWidth: 3)
        #expect(PerspectiveTool.cells(sized, flat: nil) == Size(width: 3, height: 1))
        sized.cellHeight = 2
        #expect(PerspectiveTool.cells(sized, flat: Rect(x: 0, y: 0, width: 50, height: 40)) == Size(width: 3, height: 2))
        #expect(PerspectiveTool.cells(PerspectiveSpec(grid: PerspectiveGridSpec(cellSize: 10)), flat: Rect(x: 0, y: 0, width: 50, height: 40)) == Size(width: 5, height: 4))
        // Three points with the vertical vanishing point below; a weight a hair under zero.
        let below = PerspectiveGridSpec(vanishingPoints: 3, cellSize: 10, horizonY: 100, leftVP: Point(x: 0, y: 100), rightVP: Point(x: 400, y: 100),
                                        verticalVP: Point(x: 200, y: 900), leftWallX: 200, rightWallX: 200, floorFrontY: 200)
        #expect(PlaneMap(below, plane: .leftWall).apply(Point(x: 0, y: 1)).y < 200, "v runs up, away from a vanishing point below")
        #expect(PlaneMap(m: [1, 0, 0, 0, 1, 0, 0, 0, -1e-13]).apply(Point(x: 1, y: 1)).x < 0)
        for (stored, plane) in [(Wiretuner_Doc_V1_PerspectivePlane.rightWall, PerspectiveSpec.Plane.rightWall), (.floorLeft, .floorLeft), (.floorRight, .floorRight),
                                (.wall, .wall), (.floor, .floor), (.leftWall, .leftWall), (.unspecified, .leftWall)] {
            #expect(PerspectiveTool.plane(stored) == plane)
        }
    }

    @Test func anAttachedObjectSlidesFlipsAndResizesInOneChange() async throws {
        let f = await Fixture.make()
        let rect = try #require(f.rect)
        _ = await f.document.perform(AttachToPerspectiveGrid([rect], plane: .floorRight, at: Point(x: 1, y: 1))).value
        let wrapper = try #require(f.wrapper)
        let center = try #require(f.center(wrapper))
        // Slide with Shift: whole cells.
        f.down(center)
        #expect(f.tool.gesture == .move(wrapper, flip: false, width: 0, height: 0))
        let to = Point(x: center.x + 25, y: center.y + 5)
        f.drag(to, .shift)
        await f.up(to, .shift)
        #expect(f.document.undoTitle == "Undo Move on grid")
        let position = f.state.props(wrapper).perspective.cellPosition
        #expect(position.x == position.x.rounded() && position.y == position.y.rounded())
        // Space and the digits while pressed, then a release without a move: one change.
        let again = try #require(f.center(wrapper))
        f.down(again)
        #expect(f.tool.keyDown(TestEvents.space))
        #expect(f.tool.keyDown(TestEvents.key("2", keyCode: 19)) && f.tool.keyDown(TestEvents.key("3", keyCode: 20)) && f.tool.keyDown(TestEvents.key("6", keyCode: 22)))
        #expect(f.tool.keyDown(TestEvents.key("1", keyCode: 18)) && f.tool.keyDown(TestEvents.key("5", keyCode: 23)) && f.tool.keyDown(TestEvents.key("4", keyCode: 21)))
        #expect(!f.tool.keyDown(TestEvents.key("9", keyCode: 25)) && !f.tool.keyDown(TestEvents.key("a", keyCode: 0)))
        #expect(f.tool.gesture == .move(wrapper, flip: true, width: 0, height: 0))
        #expect(f.tool.keyDown(TestEvents.key("2", keyCode: 19)))
        f.drag(again)
        f.tool.flagsChanged(TestEvents.point(again.x, again.y))
        await f.up(again)
        #expect(f.document.undoTitle == "Undo Flip on grid" && f.state.props(wrapper).perspective.flipped)
        #expect(f.state.props(wrapper).perspective.cellWidth > 0)
        // A flip alone.
        f.down(try #require(f.center(wrapper)))
        _ = f.tool.keyDown(TestEvents.space)
        await f.up(try #require(f.center(wrapper)))
        #expect(!f.state.props(wrapper).perspective.flipped)
        // Resize alone.
        f.down(try #require(f.center(wrapper)))
        _ = f.tool.keyDown(TestEvents.key("4", keyCode: 21))
        await f.up(try #require(f.center(wrapper)))
        #expect(f.document.undoTitle == "Undo Resize on grid")
        // A press on nothing, a key with nothing pressed, and Esc.
        f.down(Point(x: 5, y: 5))
        #expect(f.tool.gesture == nil && !f.tool.keyDown(TestEvents.space))
        f.drag(Point(x: 6, y: 6))
        await f.up(Point(x: 6, y: 6))
        f.down(try #require(f.center(wrapper)))
        f.tool.cancel()
        #expect(f.tool.gesture == nil)
        f.tool.flagsChanged(TestEvents.point(0, 0))
        f.tool.drawOverlay(in: GlueWorld.bitmapContext(), viewport: f.host.viewport)
        // A press and release with nothing changed writes nothing.
        let unchanged = f.document.changeCount
        f.down(try #require(f.center(wrapper)))
        await f.up(try #require(f.center(wrapper)))
        #expect(f.document.changeCount == unchanged)
        // A locked object is left alone.
        _ = await f.document.perform(SetLocked([wrapper], locked: true)).value
        f.down(try #require(f.center(wrapper)))
        #expect(f.tool.gesture == nil)
        f.tool.deactivate()
        f.down(Point(x: 1, y: 1))
        #expect(f.tool.gesture == nil, "not active")
    }

    @Test func theGridsHandlesReshapeTheGridWhenItIsShown() async throws {
        let f = await Fixture.make()
        defer { PerspectiveTool.showsGrid = { _ in false } }
        PerspectiveTool.showsGrid = { _ in true }
        // The built-in grid has nothing to edit: the tool says to define one.
        f.down(Point(x: 0, y: 150))
        #expect(f.host.messages.last == PerspectiveTool.defineFirst && f.tool.gesture == nil)
        // Away from the handles a press takes the object.
        let rect = try #require(f.rect)
        f.down(try #require(f.center(rect)))
        guard case .attach? = f.tool.gesture else { Issue.record("not an attach"); return }
        f.tool.cancel()
        let grid = try #require(await f.defineGrid())
        // Drag the left vanishing point.
        f.down(Point(x: 0, y: 150))
        #expect(f.tool.gesture == .vanishingPoint(grid: grid, page: Self.page, field: .leftVP))
        f.drag(Point(x: 10, y: 140))
        await f.up(Point(x: 10, y: 140))
        #expect(f.document.undoTitle == "Undo Move vanishing point" && PerspectiveReading.grids(f.state)[0].stored.leftVp.x == 10)
        // The right one with Option+Shift clones the attached objects (none here: the grid moves).
        f.down(Point(x: 400, y: 150))
        await f.up(Point(x: 390, y: 150), [.option, .shift])
        #expect(f.document.undoTitle == "Undo Clone on grid")
        // The horizon.
        f.down(Point(x: 300, y: 150))
        #expect(f.tool.gesture == .horizon(grid: grid, page: Self.page))
        f.drag(Point(x: 300, y: 120))
        await f.up(Point(x: 300, y: 120))
        #expect(f.document.undoTitle == "Undo Move horizon" && PerspectiveReading.grids(f.state)[0].stored.horizonY == 180)
        f.down(Point(x: 300, y: 120))
        await f.up(Point(x: 320, y: 120), [.option, .shift])
        f.down(Point(x: 300, y: 120))
        await f.up(Point(x: 300, y: 110), [.option, .shift])
        #expect(f.document.undoTitle == "Undo Clone on grid")
        // Unmoved handles write nothing.
        let count = f.document.changeCount
        f.down(Point(x: 10, y: 140))
        await f.up(Point(x: 10, y: 140))
        f.down(Point(x: 200, y: 110))
        await f.up(Point(x: 250, y: 110))
        #expect(f.document.changeCount == count)
        // Double-clicks hide and show a wall and the floor.
        f.down(Point(x: 10, y: 140), clicks: 2)
        await f.document.settle()
        #expect(f.document.undoTitle == "Undo Hide wall" && PerspectiveReading.grids(f.state)[0].stored.leftHidden)
        f.down(Point(x: 10, y: 140), clicks: 2)
        await f.document.settle()
        #expect(f.document.undoTitle == "Undo Show wall")
        let right = PerspectiveReading.grids(f.state)[0].stored.rightVp
        let rightPoint = Point(x: right.x, y: Self.page.maxY - right.y)
        f.down(rightPoint, clicks: 2)
        await f.document.settle()
        #expect(PerspectiveReading.grids(f.state)[0].stored.rightHidden)
        f.down(Point(x: 200, y: 110), clicks: 2)
        await f.document.settle()
        #expect(f.document.undoTitle == "Undo Hide floor" && PerspectiveReading.grids(f.state)[0].stored.floorHidden)
        f.down(Point(x: 200, y: 110), clicks: 2)
        await f.document.settle()
        #expect(!PerspectiveReading.grids(f.state)[0].stored.floorHidden)
        // The vertical vanishing point hides nothing.
        let drawing = PerspectiveGridDrawing(page: f.document.pageList.pages[0], state: f.state)
        #expect(PerspectiveTool.toggle(.vanishingPoint(grid: grid, page: Self.page, field: .verticalVP), drawing: drawing) == nil)
        // Keys do nothing to a handle drag; the overlay draws its ring.
        f.down(Point(x: 200, y: 110))
        #expect(!f.tool.keyDown(TestEvents.space))
        f.drag(Point(x: 200, y: 100))
        f.tool.cancel()
    }

    @Test func wallAndFloorEdgesDragAndTheArrowBadgeShowsOverLiveLines() async throws {
        let f = await Fixture.make()
        defer { PerspectiveTool.showsGrid = { _ in false } }
        PerspectiveTool.showsGrid = { _ in true }
        // Over a line of the built-in grid the badge shows, though a press says to define one.
        #expect(f.tool.cursor == .crosshair)
        f.tool.pointerMoved(TestEvents.point(200, 200))
        #expect(f.tool.overHandle && f.tool.cursor == PerspectiveTool.badgeCursor)
        f.tool.pointerMoved(TestEvents.point(200, 200))
        f.tool.pointerMoved(TestEvents.point(300, 60))
        #expect(!f.tool.overHandle && f.tool.cursor == .crosshair)
        f.down(Point(x: 200, y: 200))
        #expect(f.host.messages.last == PerspectiveTool.defineFirst && f.tool.gesture == nil)
        let grid = try #require(await f.defineGrid())
        let drawing = PerspectiveGridDrawing(page: f.document.pageList.pages[0], state: f.state)
        #expect(drawing.edges.map(\.field) == [.leftWallX, .rightWallX, .floorFrontY])
        #expect(PerspectiveGridDrawing.distance(Point(x: 5, y: 5), Point(x: 0, y: 0), Point(x: 0, y: 0)) == Point(x: 5, y: 5).distance(to: .zero))
        // The walls meet at the centre: the left edge is picked first; dragging it moves the wall.
        f.down(Point(x: 200, y: 200))
        #expect(f.tool.gesture == .edge(grid: grid, page: Self.page, field: .leftWallX))
        f.drag(Point(x: 180, y: 200))
        await f.up(Point(x: 180, y: 200))
        #expect(f.document.undoTitle == "Undo Move wall" && PerspectiveReading.grids(f.state)[0].stored.leftWallX == 180)
        f.down(Point(x: 200, y: 200))
        #expect(f.tool.gesture == .edge(grid: grid, page: Self.page, field: .rightWallX))
        await f.up(Point(x: 230, y: 200))
        #expect(PerspectiveReading.grids(f.state)[0].stored.rightWallX == 230)
        // The floor's front edge.
        f.down(Point(x: 100, y: 225))
        #expect(f.tool.gesture == .edge(grid: grid, page: Self.page, field: .floorFrontY))
        await f.up(Point(x: 100, y: 250))
        #expect(f.document.undoTitle == "Undo Move floor" && PerspectiveReading.grids(f.state)[0].stored.floorFrontY == 50)
        let count = f.document.changeCount
        f.down(Point(x: 100, y: 250))
        await f.up(Point(x: 100, y: 250))
        #expect(f.document.changeCount == count, "an unmoved edge writes nothing")
        // Hidden planes have no edge to drag.
        _ = await f.document.perform(EditGrid(grid, label: "Edit", fields: [.leftHidden, .rightHidden, .floorHidden]) {
            $0.leftHidden = true; $0.rightHidden = true; $0.floorHidden = true
        }).value
        #expect(PerspectiveGridDrawing(page: f.document.pageList.pages[0], state: f.state).edges.isEmpty)
        _ = await f.document.perform(EditGrid(grid, label: "Edit", fields: [.vanishingPoints, .leftHidden]) { $0.vanishingPoints = 1; $0.leftHidden = false }).value
        #expect(PerspectiveGridDrawing(page: f.document.pageList.pages[0], state: f.state).edges.map(\.field) == [.leftWallX], "one point: the wall's edge")
        f.down(Point(x: 180, y: 200))
        f.drag(Point(x: 170, y: 200))
        f.tool.cancel()
    }

    @Test func anOptionDragMakesACopyOfTheGridThePagesGrid() async throws {
        let f = await Fixture.make()
        defer { PerspectiveTool.showsGrid = { _ in false } }
        PerspectiveTool.showsGrid = { _ in true }
        let grid = try #require(await f.defineGrid())
        let page = f.document.pageList.pages[0]
        f.down(Point(x: 300, y: 150), .option)
        await f.up(Point(x: 300, y: 130), .option)
        #expect(f.document.undoTitle == "Undo Define grid")
        let grids = PerspectiveReading.grids(f.state)
        #expect(grids.map(\.name) == ["Grid", "Grid 2"])
        #expect(grids[0].id == grid && grids[0].stored.horizonY == 150, "the original is kept as it was")
        #expect(grids[1].stored.horizonY == 170 && PerspectiveReading.grid(of: f.document.pageList.pages[0], in: f.state) == grids[1].id)
        // One undo takes the copy and the page's choice back.
        _ = await f.document.undo().value
        await f.document.settle()
        #expect(PerspectiveReading.grids(f.state).count == 1 && PerspectiveReading.grid(of: page, in: f.state) == grid)
        // The command on its own: a name edit is refused; no fields only copies.
        let rename = EditGrid(grid, label: "Rename", fields: [.name]) { $0.name = "x" }
        #expect(await f.document.perform(ForkGrid(rename, page: page.id)).value == nil)
        _ = await f.document.perform(ForkGrid(EditGrid(grid, label: "None", fields: []) { _ in }, page: page.id)).value
        #expect(PerspectiveReading.grids(f.state).count == 2)
    }

    @Test func cmdOptionDoubleClickEditsAttachedTextAndThePointerTakesObjectsOff() async throws {
        let f = await Fixture.make()
        let text = try #require(await f.document.perform(CreateTextBlock(.point(Point(x: 100, y: 100)), text: "Sign")).value?.createdObjects.first)
        await f.document.settle()
        _ = await f.document.perform(AttachToPerspectiveGrid([text], plane: .leftWall, at: Point(x: 1, y: 1))).value
        let wrapper = try #require(PerspectiveReading.wrapper(of: text, in: f.state))
        let center = try #require(f.center(wrapper))
        var edited: [OpID] = []
        let stored = PerspectiveTool.editText
        defer { PerspectiveTool.editText = stored }
        PerspectiveTool.editText = { node, _ in edited.append(node) }
        f.down(center, [.command, .option], clicks: 2)
        #expect(edited == [text] && f.tool.gesture == nil)
        f.down(center, [.command], clicks: 2)
        #expect(edited.count == 1, "Cmd+Option only")
        f.tool.cancel()
        f.down(Point(x: 5, y: 290), [.command, .option], clicks: 2)
        #expect(edited.count == 1, "nothing there")
        f.tool.cancel()
        // A rectangle on the grid is not text.
        let rect = try #require(f.rect)
        _ = await f.document.perform(AttachToPerspectiveGrid([rect], plane: .rightWall, at: Point(x: 1, y: 1))).value
        let rectWrapper = try #require(f.wrapper)
        let context = ToolContext(document: f.document, host: f.host, selection: f.controller)
        #expect(!f.tool.editAttachedText(at: CanvasEvent(pasteboardPoint: try #require(f.center(rectWrapper)), viewPoint: try #require(f.center(rectWrapper)),
                                                         modifiers: [.command, .option], clickCount: 2), context: context))
        // The real route opens nothing without a window.
        stored(text, context)
        // Moving attached objects with the Pointer releases them where they were drawn, moved.
        let release = try #require(await f.document.perform(ReleaseWithPerspective([rectWrapper])).value?.createdRoots.first)
        await f.document.settle()
        let before = try #require(Objects.bounds(of: release, in: f.state))
        _ = await f.document.undo().value
        await f.document.settle()
        let move = MoveOffGrid.command([rectWrapper, rectWrapper], by: Vector(dx: 10, dy: 0), in: f.state)
        #expect(move is MoveOffGrid && MoveOffGrid.command([text], by: .zero, in: EngineState()) is MoveObjects)
        _ = await f.document.perform(move).value
        #expect(f.document.undoTitle == "Undo Move" && !f.state.isLive(rectWrapper) && f.state.isLive(wrapper))
        let layer = try #require(f.state.store.placement(rectWrapper)?.parent)
        let released = try #require(f.state.liveChildren(layer).first { f.state.nodeKind($0) == .group })
        let after = try #require(Objects.bounds(of: released, in: f.state))
        #expect(abs(after.minX - before.minX - 10) < 1 && abs(after.minY - before.minY) < 1)
        // Attached and flat objects together: the flat ones move as MoveObjects moves them.
        let flat = try #require(await f.document.addRectangles([Rect(x: 10, y: 10, width: 5, height: 5)]).first?.opID)
        let flatBefore = try #require(Objects.bounds(of: flat, in: f.state))
        _ = await f.document.perform(MoveOffGrid([wrapper, flat], by: Vector(dx: 0, dy: 5))).value
        #expect(!f.state.isLive(wrapper) && Objects.bounds(of: flat, in: f.state)?.minY == flatBefore.minY + 5)
        // The perspective lines are snap targets while the grid shows.
        #expect(PerspectiveGridDrawing.snapLines(of: f.document).isEmpty)
        defer { PerspectiveTool.showsGrid = { _ in false } }
        PerspectiveTool.showsGrid = { _ in true }
        #expect(!PerspectiveGridDrawing.snapLines(of: f.document).isEmpty)
    }

    @Test func aDegenerateGridPlacesNothing() async throws {
        let f = await Fixture.make()
        let rect = try #require(f.rect)
        // Both vanishing points at one place: the floor has no cells.
        _ = try #require(await f.defineGrid { grid in
            grid.rightVp = grid.leftVp
        })
        let center = try #require(f.center(rect))
        f.down(center)
        #expect(f.tool.keyDown(TestEvents.key("", keyCode: 126)))
        f.drag(Point(x: center.x + 5, y: center.y))
        let count = f.document.changeCount
        await f.up(Point(x: center.x + 5, y: center.y))
        #expect(f.document.changeCount == count && f.wrapper == nil)
        // An object on that floor does not slide.
        _ = await f.document.perform(AttachToPerspectiveGrid([rect], plane: .floorRight, at: .zero, cellWidth: 1, cellHeight: 1)).value
        let wrapper = try #require(f.wrapper)
        let spec = PerspectiveReading.spec(wrapper, in: f.state)
        #expect(f.tool.movedPosition(wrapper, start: TestEvents.point(0, 0), end: TestEvents.point(10, 10), state: f.state) == nil)
        #expect(PlaneMap(spec.grid, plane: spec.effectivePlane).cell(at: .zero) == nil)
    }

    @Test func theOverlayDrawsEachPlaneTheHorizonAndTheVanishingPoints() async throws {
        let f = await Fixture.make()
        let page = f.document.pageList.pages[0]
        let builtIn = PerspectiveGridDrawing(page: page, state: f.state)
        #expect(builtIn.grid == nil && builtIn.planes.map(\.plane) == [.leftWall, .rightWall, .floorRight] && builtIn.vanishingPoints.count == 2)
        #expect(builtIn.planes.allSatisfy { !$0.lines.isEmpty } && builtIn == PerspectiveGridDrawing(page: page, state: f.state))
        PerspectiveFeatures.draw(builtIn, in: GlueWorld.bitmapContext(), viewport: f.host.viewport)
        // One point, a hidden wall and a coloured floor.
        _ = try #require(await f.defineGrid { grid in
            grid.vanishingPoints = 1
            grid.leftHidden = true
            grid.floorColor = ColorResolver.inline(RenderColor(red: 1, green: 0, blue: 0))
        })
        let one = PerspectiveGridDrawing(page: page, state: f.state)
        #expect(one.planes.map(\.plane) == [.floor] && abs(one.planes[0].color.components[0] - 1) < 0.01 && one.vanishingPoints.count == 1)
        _ = await f.document.perform(EditGrid(one.grid!, label: "Edit", fields: [.leftHidden, .floorHidden]) { $0.leftHidden = false; $0.floorHidden = true }).value
        #expect(PerspectiveGridDrawing(page: page, state: f.state).planes.map(\.plane) == [.wall])
        // Three points: the vertical vanishing point is drawn and draggable.
        _ = await f.document.perform(EditGrid(one.grid!, label: "Edit", fields: [.vanishingPoints, .rightHidden, .floorHidden]) {
            $0.vanishingPoints = 3
            $0.rightHidden = true
            $0.floorHidden = false
        }).value
        let three = PerspectiveGridDrawing(page: page, state: f.state)
        #expect(three.vanishingPoints.count == 3 && three.planes.map(\.plane) == [.leftWall, .floorRight])
        PerspectiveFeatures.draw(three, in: GlueWorld.bitmapContext(), viewport: f.host.viewport)
        defer { PerspectiveTool.showsGrid = { _ in false } }
        PerspectiveTool.showsGrid = { _ in true }
        let vertical = three.spec.verticalVP
        f.down(vertical)
        #expect(f.tool.gesture == .vanishingPoint(grid: one.grid!, page: Self.page, field: .verticalVP))
        await f.up(Point(x: vertical.x + 5, y: vertical.y))
        #expect(PerspectiveReading.grids(f.state)[0].stored.verticalVp.x == vertical.x + 5)
        // An axis toward the viewer stops before the horizon.
        #expect(PerspectiveGridDrawing.reach(.direction(Vector(1, 0)), origin: .zero, cell: 36) == Double(PerspectiveGridDrawing.extent))
        #expect(PerspectiveGridDrawing.reach(.vanishing(Point(x: 36, y: 0), sign: -1), origin: .zero, cell: 36) < 1)
        let stored = PerspectivePageCoordinates.stored(Point(x: 10, y: 20), page: Self.page)
        #expect(stored.x == 10 && stored.y == 280 && PerspectivePageCoordinates.horizon(100, page: Self.page) == 200)
    }

    @Test func theViewMenuShowsTheGridAndTakesObjectsOffIt() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let features = PerspectiveFeatures(window: { [weak window = world.window] in window }, sheets: world.sheets())
        features.install(commands: world.commands)
        let ids = StandardCommands.ID.self
        #expect(world.commands.command(ids.perspectiveShow)?.validation() == .checked(false))
        #expect(world.commands.command(PerspectiveFeatures.ID.remove)?.validation().reason == PerspectiveFeatures.notAttached)
        #expect(!features.isShown(document: world.document))
        #expect(world.commands.perform(ids.perspectiveShow))
        #expect(features.isShown(world.window) && features.isShown(document: world.document) && PerspectiveTool.showsGrid(world.document))
        features.attach(world.window)
        features.drawGrids(in: world.bitmap(), window: world.window)
        world.window.canvas.furnitureDrawer?(world.bitmap())
        // Objects on the grid: Remove Perspective and Release with Perspective.
        let rect = try #require(await world.document.addRectangles([Rect(x: 100, y: 100, width: 30, height: 30)]).first?.opID)
        _ = await world.document.perform(AttachToPerspectiveGrid([rect], plane: .leftWall, at: .zero)).value
        world.select([rect])
        #expect(PerspectiveFeatures.attached(world.window) == [rect])
        #expect(world.commands.perform(PerspectiveFeatures.ID.release))
        await world.document.settle()
        #expect(world.document.undoTitle == "Undo Release with perspective")
        _ = await world.document.undo().value
        world.select([rect])
        #expect(world.commands.perform(PerspectiveFeatures.ID.remove))
        await world.document.settle()
        #expect(world.document.undoTitle == "Undo Remove perspective" && PerspectiveReading.wrapper(of: rect, in: world.state) == nil)
        #expect(world.commands.perform(ids.perspectiveShow))
        #expect(!features.isShown(world.window))
        features.drawGrids(in: world.bitmap(), window: world.window)
        // Without a window.
        let none = PerspectiveFeatures(window: { nil })
        #expect(none.commands().allSatisfy { !$0.validation().isEnabled })
        for command in none.commands() { if case .perform(let run) = command.action { run() } }
        // Define Grids… opens the sheet; Cancel closes it.
        #expect(world.commands.perform(ids.perspectiveDefine))
        #expect(world.presented.value.last?.identifier?.rawValue == PerspectiveFeatures.sheet && features.defineGrids != nil)
        let host = try #require(world.presented.value.last?.contentViewController as? NSHostingController<DefineGridsSheet>)
        host.rootView.finish()
        #expect(features.defineGrids == nil)
    }

    @Test func defineGridsCreatesDuplicatesRenamesEditsAndDeletes() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let model = DefineGridsModel(document: world.document)
        #expect(model.grids.isEmpty && model.selected == nil && model.selectedGrid == nil)
        #expect(model.duplicate() == nil && model.delete() == nil && model.rename("X") == nil && model.setVanishingPoints(1) == nil)
        #expect(model.color(.leftColor) == PerspectiveGridDrawing.leftColor && model.confirm() == nil)
        #expect(model.vanishingPoints == 2 && model.cellSize == nil)
        DefineGridsSheet.adding(model)()
        await world.document.settle()
        for _ in 0..<200 where model.selected == nil { await Task.yield() }
        let first = try #require(model.selected)
        #expect(model.cellSize == 36)
        #expect(model.grids.map(\.name) == ["Grid"] && world.document.undoTitle == "Undo Define grid")
        DefineGridsSheet.duplicating(model)()
        await world.document.settle()
        for _ in 0..<200 where model.selected == first { await Task.yield() }
        #expect(model.grids.map(\.name) == ["Grid", "Grid 2"] && model.selected != first)
        // Renaming: unchanged, empty and duplicate names are refused with a message.
        #expect(model.rename("Grid 2") == nil)
        #expect(model.rename("  ") == nil && model.message == "A grid needs a name.")
        #expect(model.rename("Grid") == nil && model.message == "Another grid is named “Grid”.")
        await model.rename("Street")?.value
        #expect(model.message == nil && model.selectedGrid?.name == "Street")
        // Options.
        await model.setVanishingPoints(3)?.value
        #expect(model.setVanishingPoints(4) == nil && model.selectedGrid?.stored.vanishingPoints == 3)
        #expect(model.setCellSize(0) == nil && model.message == "The cell size must be more than zero.")
        DefineGridsSheet.settingCellSize(model)(24)
        await world.document.settle()
        #expect(model.selectedGrid?.stored.cellSize == 24 && model.cellSize == 24 && model.vanishingPoints == 3)
        for field in [PerspectiveFields.GridField.leftColor, .rightColor, .floorColor] {
            await model.setColor(field, RenderColor(red: 0, green: 0.5, blue: 1))?.value
            #expect(model.color(field).components[1] == 0.5)
        }
        #expect(model.setColor(.name, .white) == nil)
        // OK makes the selected grid the page's.
        await model.confirm()?.value
        #expect(PerspectiveReading.grid(of: world.document.activePage, in: world.state) == model.selected)
        #expect(model.confirm() == nil, "already the page's")
        // Delete.
        DefineGridsSheet.deleting(model)()
        await world.document.settle()
        #expect(model.grids.count == 1 && model.selected == nil)
        let red = DefineGridsSheet.renderColor(SwiftUI.Color(.sRGB, red: 1, green: 0, blue: 0))
        #expect(abs(red.components[0] - 1) < 0.01 && abs(red.components[1]) < 0.01)
        // The sheet renders with and without a selection, and its bindings write.
        var finished = 0
        Render.view(DefineGridsSheet(model: model) { finished += 1 }, size: CGSize(width: 520, height: 400))
        model.selected = first
        Render.view(DefineGridsSheet(model: model) { finished += 1 }, size: CGSize(width: 520, height: 400))
        DefineGridsSheet.name(model).wrappedValue = "Plaza"
        await world.document.settle()
        #expect(DefineGridsSheet.name(model).wrappedValue == "Plaza")
        DefineGridsSheet.vanishing(model).wrappedValue = 1
        await world.document.settle()
        #expect(DefineGridsSheet.vanishing(model).wrappedValue == 1)
        DefineGridsSheet.color(model, .rightColor).wrappedValue = SwiftUI.Color(.sRGB, red: 1, green: 0, blue: 0)
        await world.document.settle()
        #expect(abs(model.color(.rightColor).components[0] - 1) < 0.01)
        #expect(DefineGridsSheet.color(model, .rightColor).wrappedValue != SwiftUI.Color.clear)
        DefineGridsSheet.confirming(model) { finished += 1 }()
        #expect(finished == 1)
        await world.document.settle()
    }
}

extension GlueWorld {
    /// A 400 × 300 bitmap context for overlay drawing.
    static func bitmapContext() -> CGContext {
        CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
}
