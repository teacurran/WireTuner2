import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// DRAW-023's remainder: closing by dragging one end onto the other with the Pointer or Subselect
/// tool, and the context menu's *Path > Close / Open*.
@Suite(.serialized) @MainActor struct PathClosingTests {
    typealias Fixture = PointerMoveTests.Fixture

    static func select(_ f: Fixture, _ path: SelectionID, points: [Int]) {
        let contour = f.document.path(path)!.contours[0]
        let chosen = Set(points.map { PointReference(node: path.node, contour: contour.id, point: contour.drawn[$0].id) })
        f.controller.model.set(Selection([path]).applying([path], sub: [path: .points(chosen)], mode: .add))
    }

    @Test func draggingAnEndOntoTheOtherClosesTheContourInOneChange() async throws {
        for subselect in [false, true] {
            let f = await Fixture.make(subselect: subselect)
            let path = try #require(await f.document.addPath([Point(x: 100, y: 200), Point(x: 150, y: 250), Point(x: 200, y: 200)]))
            Self.select(f, path, points: [2])
            let changes = f.document.changeCount
            // The Pointer drags points with Option (it subselects); the Subselect tool without.
            f.drag(Point(x: 200, y: 200), Point(x: 101, y: 201), subselect ? [] : .option)
            await f.document.settle()
            let contour = try #require(f.document.path(path)?.contours.first)
            #expect(contour.closed && contour.drawn.map(\.anchor) == [Point(x: 100, y: 200), Point(x: 150, y: 250)])
            #expect(f.document.changeCount == changes + 1 && f.document.undoTitle == "Undo Close Path")
            _ = await f.document.undo().value
            #expect(f.document.path(path)?.contours.first.map { !$0.closed && $0.drawn.count == 3 } == true)
        }
    }

    @Test func otherMovesStayMoves() async throws {
        let f = await Fixture.make()
        let path = try #require(await f.document.addPath([Point(x: 100, y: 200), Point(x: 150, y: 250), Point(x: 200, y: 200)]))
        let document = f.document
        // The start point dragged onto the end closes it too.
        Self.select(f, path, points: [0])
        let selection = f.controller.selection
        #expect(PathClosing.dragClose(Vector(dx: 100, dy: 0), selection: selection, document: document, tolerance: 2) != nil)
        // Short of the other end, a middle point, two points, a two-point contour: no close.
        #expect(PathClosing.dragClose(Vector(dx: 50, dy: 0), selection: selection, document: document, tolerance: 2) == nil)
        Self.select(f, path, points: [1])
        #expect(PathClosing.dragClose(Vector(dx: 50, dy: -50), selection: f.controller.selection, document: document, tolerance: 2) == nil)
        Self.select(f, path, points: [0, 2])
        #expect(PathClosing.dragClose(Vector(dx: 100, dy: 0), selection: f.controller.selection, document: document, tolerance: 2) == nil)
        let short = try #require(await document.addPath([Point(x: 10, y: 250), Point(x: 60, y: 250)]))
        Self.select(f, short, points: [1])
        #expect(PathClosing.dragClose(Vector(dx: -50, dy: 0), selection: f.controller.selection, document: document, tolerance: 2) == nil)
        // A closed contour and a rectangle have no ends.
        let closed = try #require(await document.addPath([Point(x: 10, y: 100), Point(x: 60, y: 100), Point(x: 30, y: 140)], closed: true))
        Self.select(f, closed, points: [2])
        #expect(PathClosing.dragClose(Vector(dx: -20, dy: -40), selection: f.controller.selection, document: document, tolerance: 2) == nil)
        f.controller.model.set(Selection([f.selection.a]))
        #expect(PathClosing.dragClose(.zero, selection: f.controller.selection, document: document, tolerance: 2) == nil)
    }

    @Test func theMenuItemClosesAndOpensTheSelectedPaths() async throws {
        let selection = await SelectionFixture.make()
        let document = selection.document
        let controller = SelectionController(document: document)
        let editing = ObjectEditing(document: document, selection: controller)
        let target = TestBox<ObjectEditing?>(editing)
        let registry = CommandRegistry()
        registry.replace(PathClosing.command { target.value })
        let id = ContextMenuCatalog.ID.closePath
        #expect(registry.validate(id)?.isEnabled == false && registry.validate(id)?.reason == PathClosing.noPaths)
        let a = try #require(await document.addPath([Point(x: 100, y: 200), Point(x: 150, y: 250), Point(x: 200, y: 200)]))
        let b = try #require(await document.addPath([Point(x: 100, y: 100), Point(x: 150, y: 150), Point(x: 200, y: 100)], closed: true))
        controller.model.set(Selection([a, b]))
        #expect(registry.validate(id)?.title == "Close Path")
        #expect(registry.perform(id))
        await document.settle()
        #expect(document.path(a)?.contours[0].closed == true && document.undoTitle == "Undo Close Path")
        #expect(registry.validate(id)?.title == "Open Path")
        #expect(registry.perform(id))
        await document.settle()
        #expect(document.path(a)?.contours[0].closed == false && document.path(b)?.contours[0].closed == false)
        // Without a window nothing happens.
        target.value = nil
        #expect(registry.validate(id)?.isEnabled == false)
        _ = registry.perform(id)
        #expect(PathClosing.toggle(Selection([selection.a]), document: document) == nil)
        #expect(PathClosing.title(Selection([selection.a]), document: document) == "Close Path")
    }
}
