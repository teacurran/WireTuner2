import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTRender
@testable import WireTuner

/// OBJ-039's remainder: size badges on transform-handle drags and the Option-hover measurements.
@Suite(.serialized) @MainActor struct MeasurementTests {
    @Test func aCornerResizeSnapsToANeighboursWidthAndShowsTheBadge() async throws {
        let world = EditWorld()
        defer { world.close() }
        let center = world.setup.page.rect.center
        let ids = await world.document.addRectangles([Rect(x: center.x - 120, y: center.y, width: 50, height: 50),
                                                      Rect(x: center.x + 20, y: center.y, width: 40, height: 40)])
        world.select([ids[1]])
        let manager = world.window.toolManager!
        manager.select(.pointer)
        let tool = try #require(manager.activeTool as? PointerTool)
        tool.showHandles()
        let corner = Point(x: center.x + 60, y: center.y + 40)
        let changes = world.document.changeCount
        manager.mouseDown(world.setup.event(corner))
        manager.mouseDragged(world.setup.event(Point(x: corner.x + 2, y: corner.y)))
        manager.mouseDragged(world.setup.event(Point(x: corner.x + 4.5, y: corner.y)))
        manager.drawOverlay(in: PrintWorld.context(), viewport: world.window.viewport)
        let session = try #require(SizeGuideLink.shared.sessions[world.document.id])
        #expect(session.match.width == 50 && session.match.height == nil)
        #expect(SizeGuideLink.badge(session.match, units: world.document.unitConverter) == "W 50 pt")
        manager.drawOverlay(in: PrintWorld.context(), viewport: world.window.viewport)
        manager.mouseUp(world.setup.event(Point(x: corner.x + 4.5, y: corner.y)))
        await world.document.settle()
        #expect(SizeGuideLink.shared.sessions[world.document.id] == nil)
        let resized = try #require(Objects.bounds(of: ids[1].opID, in: world.state))
        #expect(abs(resized.width - 50) < 1e-6 && abs(resized.height - 40) < 1e-6)
        #expect(world.document.changeCount == changes + 1)

        // Shift keeps proportions (no size snap); Control suspends; smart guides off: none.
        tool.showHandles()
        let far = Point(x: resized.maxX, y: resized.maxY)
        manager.mouseDown(world.setup.event(far))
        manager.mouseDragged(world.setup.event(Point(x: far.x + 3, y: far.y + 3), .shift))
        manager.drawOverlay(in: PrintWorld.context(), viewport: world.window.viewport)
        #expect(SizeGuideLink.shared.sessions[world.document.id] == nil)
        manager.cancel()
        world.setup.environment.preferences.set(false, for: PreferenceCatalog.General.smartGuides)
        manager.mouseDown(world.setup.event(far))
        manager.mouseDragged(world.setup.event(Point(x: far.x + 3, y: far.y)))
        manager.drawOverlay(in: PrintWorld.context(), viewport: world.window.viewport)
        #expect(SizeGuideLink.shared.sessions[world.document.id] == nil)
        manager.cancel()
    }

    @Test func theSizeLinkSnapsEachMatchedDimension() {
        let link = SizeGuideLink()
        link.engine = { _, _ in nil }
        #expect(link.resizing("doc", size: Size(width: 1, height: 1), pointer: .zero, start: .zero, tolerance: 1) == nil)
        link.engine = { _, _ in SmartGuideEngine(candidates: [.init(node: nil, bounds: Rect(x: 0, y: 0, width: 30, height: 20))]) }
        let match = link.resizing("doc", size: Size(width: 29, height: 21), pointer: Point(x: 5, y: 5), start: .zero, tolerance: 2)
        #expect(match?.width == 30 && match?.height == 20)
        let outset = link.resizing("doc", size: Size(width: 28, height: 19), outset: Size(width: 1, height: 1), pointer: .zero, start: .zero, tolerance: 2)
        #expect(outset?.width == 29 && outset?.height == 19)
        link.draw("doc", units: Units(), in: PrintWorld.context(), viewport: Viewport(size: Size(width: 100, height: 100)), color: CGColor(gray: 0, alpha: 1))
        link.draw("other", units: Units(), in: PrintWorld.context(), viewport: Viewport(size: Size(width: 100, height: 100)), color: CGColor(gray: 0, alpha: 1))
        let bounds = Rect(x: 0, y: 0, width: 10, height: 10)
        let both = SmartGuideSizeMatch(width: 30, height: 20)
        #expect(SizeGuideLink.snapped(.scale(x: 2.9, y: -2.1), anchor: .bottomRight, bounds: bounds, match: both) == .scale(x: 3, y: -2))
        #expect(SizeGuideLink.snapped(.scale(x: -2.9, y: 1), anchor: .right, bounds: bounds, match: both) == .scale(x: -3, y: 1))
        #expect(SizeGuideLink.snapped(.scale(x: 1, y: 1), anchor: .top, bounds: Rect(x: 0, y: 0, width: 10, height: 0), match: both) == .scale(x: 1, y: 1))
        #expect(SizeGuideLink.badge(SmartGuideSizeMatch(), units: Units()) == nil)
        #expect(SizeGuideLink.badge(SmartGuideSizeMatch(height: 12), units: Units()) == "H 12 pt")
        link.end("doc")
        #expect(link.sessions.isEmpty)
    }

    @Test func optionHoverMeasuresToAnObjectOrThePageEdges() async throws {
        let world = EditWorld()
        defer { world.close() }
        let page = world.setup.page.rect
        let center = page.center
        let ids = await world.document.addRectangles([Rect(x: center.x - 100, y: center.y, width: 50, height: 50),
                                                      Rect(x: center.x + 50, y: center.y + 10, width: 50, height: 50)])
        world.select([ids[0]])
        let manager = world.window.toolManager!
        manager.select(.pointer)
        let link = MeasurementLink.shared
        let doc = world.document.id
        let changes = world.document.changeCount
        // Without Option: nothing.
        manager.pointerMoved(world.setup.event(Point(x: center.x + 75, y: center.y + 30)))
        #expect(link.lines[doc]?.isEmpty != false)
        // Option down over the other object: the facing gap (100 pt) and the vertical overlap's edges.
        manager.flagsChanged(.option)
        let lines = try #require(link.lines[doc])
        #expect(lines.contains { abs($0.length - 100) < 1e-9 && $0.from.x == center.x - 50 })
        #expect(lines.count == 3)
        manager.drawOverlay(in: PrintWorld.context(), viewport: world.window.viewport)
        // Over empty page: the four page-edge distances.
        manager.pointerMoved(world.setup.event(Point(x: page.minX + 5, y: page.minY + 5), .option))
        let edges = try #require(link.lines[doc])
        #expect(edges.count == 4 && abs(edges[0].length - (center.x - 100 - page.minX)) < 1e-9)
        // Off the page: none; Option up clears; a press clears.
        manager.pointerMoved(world.setup.event(Point(x: page.minX - 50, y: page.minY - 50), .option))
        #expect(link.lines[doc]?.isEmpty == true)
        manager.pointerMoved(world.setup.event(Point(x: page.minX + 5, y: page.minY + 5), .option))
        manager.flagsChanged([])
        #expect(link.lines[doc]?.isEmpty == true)
        manager.flagsChanged(.option)
        #expect(link.lines[doc]?.count == 4)
        manager.mouseDown(world.setup.event(Point(x: page.minX + 5, y: page.minY + 5), .option))
        #expect(link.lines[doc] == nil)
        manager.mouseUp(world.setup.event(Point(x: page.minX + 5, y: page.minY + 5), .option))
        // The preference off: nothing; no selection: nothing.
        link.enabled = { false }
        manager.pointerMoved(world.setup.event(Point(x: page.minX + 5, y: page.minY + 5), .option))
        #expect(link.lines[doc]?.isEmpty == true)
        link.enabled = { true }
        world.select([])
        manager.pointerMoved(world.setup.event(Point(x: page.minX + 6, y: page.minY + 5), .option))
        #expect(link.lines[doc]?.isEmpty == true)
        await world.document.settle()
        #expect(world.document.changeCount == changes, "measuring writes nothing")
    }

    @Test func theLinesFaceEachSide() {
        let s = Rect(x: 0, y: 0, width: 10, height: 10)
        // Left of, above, below.
        #expect(MeasurementLink.lines(from: s, to: Rect(x: -20, y: 2, width: 5, height: 5)).map(\.length).sorted() == [2, 3, 15])
        #expect(MeasurementLink.lines(from: s, to: Rect(x: 20, y: 20, width: 5, height: 5)).map(\.length) == [10, 10])
        #expect(MeasurementLink.lines(from: s, to: Rect(x: 20, y: -20, width: 5, height: 5)).map(\.length) == [10, 15])
        #expect(MeasurementLink.overlapMiddle(0...1, 2...3) == nil)
        #expect(MeasurementLink.lines(from: s, toEdgesOf: Rect(x: -10, y: -10, width: 40, height: 40)).map(\.length) == [10, 20, 10, 20])
    }
}
