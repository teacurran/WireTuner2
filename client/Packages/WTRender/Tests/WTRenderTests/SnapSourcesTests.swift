import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// DOC-016: snapping to the grid, guides, guide objects, points and objects through
/// `SnapEngine` -- the property tests of the task, the toggles, kbd:[Control] suspension and the
/// pointer feedback.
@Suite struct SnapSourcesTests {
    static let query = Point(x: 100, y: 100)

    static func list(_ items: [DisplayItem], layers: [LayerSpan] = []) -> (DisplayList, RTree<Int>) {
        let list = DisplayList(canvas: "snap", items: items, layers: layers)
        let index = RTree(bulkLoading: list.itemBounds.enumerated().compactMap { index, bounds in bounds.map { (index, $0) } })
        return (list, index)
    }

    static func fill(_ path: DisplayPath) -> DisplayItem {
        .fill(FillItem(path: path, paint: .solid(.black)))
    }

    /// A square whose corner is 0.5 pt from the query point.
    static let square = fill(DisplayPath(rect: Rect(x: 100.5, y: 100, width: 20, height: 20)))
    /// A long line 0.8 pt below the query point, its ends far away.
    static let line = DisplayItem.stroke(StrokeItem(path: DisplayPath(polygon: [Point(x: -500, y: 100.8), Point(x: 700, y: 100.8)], closed: false),
                                                    paint: .solid(.black)))

    /// Sources holding exactly the given kinds, each within reach of the query point.
    static func sources(_ kinds: Set<SnapKind>) -> SnapSources {
        var items: [DisplayItem] = []
        if kinds.contains(.point) { items.append(square) }
        if kinds.contains(.path) { items.append(line) }
        let (list, index) = list(items)
        return SnapSources(grid: kinds.contains(.grid) ? GridSpec(size: 7, origin: Point(x: 101.4, y: 101.4)) : nil,
                           guides: kinds.contains(.guide) ? [.vertical(x: 101)] : [], displayList: list, index: index,
                           smartGuides: kinds.contains(.smartGuide) ? [.horizontal(y: 101.2)] : [])
    }

    @Test func priorityHoldsForEveryPair() throws {
        let engine = SnapEngine(snapDistance: 3, zoom: 1, toggles: SnapToggles(grid: true))
        for first in SnapKind.allCases {
            for second in SnapKind.allCases where second > first {
                let result = try #require(engine.resolve(Self.query, sources: Self.sources([first, second])), "\(first) vs \(second)")
                #expect(result.kind == first, "\(first) vs \(second) gave \(result.kind)")
            }
            // Alone, each kind snaps.
            #expect(engine.resolve(Self.query, sources: Self.sources([first]))?.kind == first)
        }
    }

    @Test func relativeGridMovePreservesTheInCellOffset() {
        let engine = SnapEngine(snapDistance: 100, zoom: 1, toggles: SnapToggles(grid: true, guides: false, points: false, objects: false, smartGuides: false))
        var generator = SplitMix64(seed: 7)
        let size = 12.0
        let origin = Point(x: 5, y: -3)
        let sources = SnapSources(grid: GridSpec(size: size, origin: origin, relative: true))
        func offset(_ value: Double, _ base: Double) -> Double {
            let r = (value - base).truncatingRemainder(dividingBy: size)
            return r < 0 ? r + size : r
        }
        for _ in 0..<500 {
            let start = Point(x: Double.random(in: -1000...1000, using: &generator), y: Double.random(in: -1000...1000, using: &generator))
            let delta = Vector(dx: Double.random(in: -300...300, using: &generator), dy: Double.random(in: -300...300, using: &generator))
            let (moved, snap) = engine.resolveDrag(of: start, by: delta, sources: sources)
            #expect(snap?.kind == .grid)
            let end = start + moved
            #expect(abs(offset(end.x, origin.x) - offset(start.x, origin.x)).truncatingRemainder(dividingBy: size) < 1e-6
                || abs(abs(offset(end.x, origin.x) - offset(start.x, origin.x)) - size) < 1e-6)
            #expect(abs(offset(end.y, origin.y) - offset(start.y, origin.y)).truncatingRemainder(dividingBy: size) < 1e-6
                || abs(abs(offset(end.y, origin.y) - offset(start.y, origin.y)) - size) < 1e-6)
            // Whole cells: the move is a multiple of the grid size.
            #expect(abs((moved.dx / size).rounded() * size - moved.dx) < 1e-6 && abs((moved.dy / size).rounded() * size - moved.dy) < 1e-6)
        }
    }

    @Test func absoluteSnapLandsOnAnIntersection() {
        let engine = SnapEngine(snapDistance: 100, zoom: 1, toggles: SnapToggles(grid: true))
        var generator = SplitMix64(seed: 11)
        let grid = GridSpec(size: 9, origin: Point(x: 2, y: 3))
        let sources = SnapSources(grid: grid)
        for _ in 0..<500 {
            let point = Point(x: Double.random(in: -1000...1000, using: &generator), y: Double.random(in: -1000...1000, using: &generator))
            let snap = engine.resolve(point, sources: sources)
            let landed = snap?.point ?? point
            let i = (landed.x - grid.origin.x) / grid.size
            let j = (landed.y - grid.origin.y) / grid.size
            #expect(abs(i - i.rounded()) < 1e-9 && abs(j - j.rounded()) < 1e-9)
            #expect(landed.distance(to: point) <= grid.size * 0.7072)
        }
    }

    @Test func controlSuspendsAndTogglesDisable() {
        let engine = SnapEngine(toggles: SnapToggles(grid: true))
        let all = Self.sources(Set(SnapKind.allCases))
        #expect(engine.resolve(Self.query, sources: all, suspended: true) == nil)
        let (delta, snap) = engine.resolveDrag(of: Self.query, by: Vector(dx: 1, dy: 1), sources: all, suspended: true)
        #expect(delta == Vector(dx: 1, dy: 1) && snap == nil)
        let off = SnapEngine(toggles: SnapToggles(grid: false, guides: false, points: false, objects: false, smartGuides: false))
        #expect(off.resolve(Self.query, sources: all) == nil && off.candidates(near: Self.query, sources: all).isEmpty)
        #expect(SnapToggles().enabledKinds == [.point, .path, .guide, .smartGuide])
        #expect(SnapToggles(grid: true).enabledKinds == Set(SnapKind.allCases))
        // Out of reach at this zoom: the snap distance is in view pixels.
        let far = SnapEngine(snapDistance: 3, zoom: 10)
        #expect(far.resolve(Self.query, sources: Self.sources([.guide])) == nil)
        #expect(SnapEngine(snapDistance: 3, zoom: 1).resolve(Self.query, sources: Self.sources([.guide]))?.point == Point(x: 101, y: 100))
    }

    @Test func draggedObjectsAndGuideLayerItemsAreNotSnappedToAsObjects() throws {
        let guideLine = Self.fill(DisplayPath(polygon: [Point(x: 99, y: -50), Point(x: 99, y: 250)], closed: false))
        let guidesLayer = LayerSpan(layer: LayerRendering(id: NodeID(counter: 9, replica: 1), isGuides: true), range: 1..<2)
        let (list, index) = Self.list([Self.square, guideLine], layers: [guidesLayer])
        let objects = SnapSources.guideObjects(in: list)
        #expect(objects.count == 1)
        let engine = SnapEngine(snapDistance: 3, zoom: 1)
        // The guide object snaps at guide priority; the square's corner (a point) wins over it.
        var sources = SnapSources(guideObjects: objects, displayList: list, index: index)
        #expect(engine.resolve(Self.query, sources: sources)?.kind == .point)
        // Dragging the square: only the guide object is left.
        sources.excludedItems = [0]
        let snap = try #require(engine.resolve(Self.query, sources: sources))
        #expect(snap.kind == .guide && snap.point.x == 99)
        #expect(SnapFeedback(snap) == .guideObject(snap.point))
        // Images and text have no snap geometry; groups are flattened.
        let group = DisplayItem.group(GroupItem(children: [Self.square, .image(ImageItem(assetID: "a", rect: Rect(x: 99, y: 99, width: 2, height: 2)))]))
        #expect(SnapSources.geometry(of: group).count == 1)
        #expect(SnapSources.geometry(of: .text(TextRunItem(text: "t", origin: .zero, bounds: .zero, color: .black))).isEmpty)
        let path = DisplayItem.path(PathItem(path: DisplayPath(rect: .zero), appearance: Appearance()))
        #expect(SnapSources.geometry(of: path).count == 1)
    }

    @Test func pointsIncludeHandlesAndFeedbackNamesTheWinner() throws {
        var curve = DisplayPath()
        curve.move(to: Point(x: 0, y: 0))
        curve.addCubicCurve(control1: Point(x: 100.4, y: 100.4), control2: Point(x: 300, y: 0), to: Point(x: 400, y: 0))
        curve.addQuadCurve(control: Point(x: 450, y: 50), to: Point(x: 500, y: 0))
        curve.close()
        #expect(SnapEngine.points(of: curve).count == 6)
        let (list, index) = Self.list([Self.fill(curve)])
        let engine = SnapEngine()
        let handle = try #require(engine.resolve(Self.query, sources: SnapSources(displayList: list, index: index)))
        #expect(handle.kind == .point && handle.point == Point(x: 100.4, y: 100.4) && SnapFeedback(handle) == .point(handle.point))
        let pathOnly = SnapEngine(toggles: SnapToggles(points: false))
        let along = try #require(pathOnly.resolve(Point(x: 390, y: 1), sources: SnapSources(displayList: list, index: index)))
        #expect(along.kind == .path && SnapFeedback(along) == .path(along.point))
        // Two guides in reach: their crossing, named in the feedback.
        let crossing = SnapSources(guides: [.vertical(x: 101), .horizontal(y: 101)])
        let candidates = engine.candidates(near: Self.query, sources: crossing)
        let snap = try #require(engine.resolve(Self.query, sources: crossing))
        #expect(snap.point == Point(x: 101, y: 101))
        #expect(SnapFeedback(snap, candidates: candidates) == .guide(.vertical(x: 101), crossing: .horizontal(y: 101)))
        #expect(SnapFeedback(snap) == .guide(.vertical(x: 101), crossing: nil))
        let smart = try #require(engine.resolve(Self.query, sources: SnapSources(smartGuides: [.horizontal(y: 101)])))
        #expect(SnapFeedback(smart) == .smartGuide(.horizontal(y: 101)))
        let grid = try #require(SnapEngine(toggles: SnapToggles(grid: true)).resolve(Self.query, sources: SnapSources(grid: GridSpec(size: 10))))
        #expect(SnapFeedback(grid) == .grid(Point(x: 100, y: 100)))
        let segment = SnapResult(point: .zero, candidate: .segment(CubicBezier(p0: .zero, p1: .zero, p2: .zero, p3: .zero)), candidateIndex: 0, kind: .path, distance: 0)
        #expect(SnapFeedback(segment) == .path(.zero))
        // An invalid grid is not a candidate.
        #expect(SnapEngine(toggles: SnapToggles(grid: true)).candidates(near: Self.query, sources: SnapSources(grid: GridSpec(size: 0))).isEmpty)
    }
}
