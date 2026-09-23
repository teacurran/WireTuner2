import WTGeometry
import Foundation
import QuartzCore
import Testing
@testable import WTRender

/// REND-004's scene: a 768 × 512 view at 100% on a 1× display is 3 × 2 tiles of 256 points,
/// with one small square in the middle of each tile, every square its own node.
enum InvalidationScene {
    static let canvas: CanvasID = "invalidation"
    static let size = Size(width: 768, height: 512)
    static let viewport = Viewport(size: size)

    static func node(_ index: Int) -> NodeID {
        NodeID(counter: UInt64(index + 1), replica: 7)
    }

    /// The square of tile `index` (row-major), offset by `offset`.
    static func square(_ index: Int, offset: Vector = .zero) -> Rect {
        let column = Double(index % 3)
        let row = Double(index / 3)
        return Rect(x: column * 256 + 113, y: row * 256 + 113, width: 30, height: 30).offset(by: offset)
    }

    static func list(offsets: [Int: Vector] = [:], colors: [Int: Color] = [:]) -> DisplayList {
        let items = (0..<6).map { index in
            DisplayItem.fill(FillItem(path: DisplayPath(rect: square(index, offset: offsets[index] ?? .zero)), paint: .solid(colors[index] ?? blue)))
        }
        return DisplayList(canvas: canvas, items: items, nodeIDs: (0..<6).map(node))
    }

    static func bounds(_ rect: Rect, effect: Rect? = nil) -> NodeBounds {
        NodeBounds(canvas: canvas, rect: rect, effectRect: effect)
    }

    /// The summary of moving square `index` by `offset` (and giving its effects `effect`).
    static func move(_ index: Int, by offset: Vector, origin: ChangeOrigin = .remote, effect: Rect? = nil) -> ChangeSummary {
        var summary = ChangeSummary(origin: origin)
        summary.record(node(index), old: bounds(square(index)), new: bounds(square(index, offset: offset), effect: effect), fields: [FieldPath(fields: 3, 1)])
        return summary
    }
}

@Suite struct ChangeSummaryTests {
    @Test func nodeIDsOrderByCounterThenReplica() {
        #expect(NodeID(counter: 1, replica: 9) < NodeID(counter: 2, replica: 0))
        #expect(NodeID(counter: 2, replica: 0) < NodeID(counter: 2, replica: 1))
        #expect(NodeID(counter: 4, replica: 5).description == "4:5")
    }

    @Test func fieldPathsContainTheirDescendants() {
        let appearance = FieldPath(fields: 3)
        let fill = FieldPath([.field(3), .element(NodeID(counter: 9, replica: 1)), .field(2)])
        #expect(appearance.contains(fill))
        #expect(!fill.contains(appearance))
        #expect(appearance.contains(appearance))
        #expect(!FieldPath(fields: 4).contains(fill))
        #expect(fill.description == "3.<9:1>.2")
    }

    @Test func paintedBoundsIncludeEffects() {
        let plain = NodeBounds(canvas: "c", rect: Rect(x: 0, y: 0, width: 10, height: 10))
        #expect(plain.paintedRect == plain.rect)
        let shadowed = NodeBounds(canvas: "c", rect: Rect(x: 0, y: 0, width: 10, height: 10), effectRect: Rect(x: 4, y: 4, width: 20, height: 20))
        #expect(shadowed.paintedRect == Rect(x: 0, y: 0, width: 24, height: 24))
    }

    @Test func touchingAndRecordingAccumulate() {
        var summary = ChangeSummary()
        #expect(summary.isEmpty)
        #expect(summary.origin == .local)
        let a = NodeID(counter: 1, replica: 1)
        let b = NodeID(counter: 2, replica: 1)
        summary.touch(a)
        #expect(!summary.isEmpty)
        #expect(summary.touchedFields[a] == nil)
        summary.touch(a, fields: [FieldPath(fields: 1)])
        #expect(summary.touched(a, field: FieldPath(fields: 1)))
        #expect(summary.touched(a, field: FieldPath(fields: 1, 2)), "a write to a message covers its fields")
        #expect(!summary.touched(a, field: FieldPath(fields: 2)))
        #expect(!summary.touched(b, field: FieldPath(fields: 1)))

        let first = NodeBounds(canvas: "c", rect: Rect(x: 0, y: 0, width: 1, height: 1))
        let second = NodeBounds(canvas: "c", rect: Rect(x: 5, y: 0, width: 1, height: 1))
        let third = NodeBounds(canvas: "c", rect: Rect(x: 9, y: 0, width: 1, height: 1))
        summary.record(b, old: first, new: second)
        summary.record(b, old: second, new: third)
        #expect(summary.bounds[b] == BoundsChange(old: first, new: third), "a node recorded twice keeps the earliest old and the latest new")
        #expect(summary.touchedNodes == [a, b])
        #expect(ChangeSummary(isStructural: true).isEmpty == false)
    }

    @Test func mergingCoalescesABurst() {
        let a = NodeID(counter: 1, replica: 1)
        let b = NodeID(counter: 2, replica: 1)
        let c0 = NodeBounds(canvas: "c", rect: Rect(x: 0, y: 0, width: 1, height: 1))
        let c1 = NodeBounds(canvas: "c", rect: Rect(x: 1, y: 0, width: 1, height: 1))
        let c2 = NodeBounds(canvas: "c", rect: Rect(x: 2, y: 0, width: 1, height: 1))
        var remote = ChangeSummary(origin: .remote)
        remote.record(a, old: c0, new: c1, fields: [FieldPath(fields: 1)])
        var later = ChangeSummary(origin: .remote, isStructural: true)
        later.record(a, old: c1, new: c2, fields: [FieldPath(fields: 2)])
        later.record(b, old: nil, new: c0)
        let merged = remote.merging(later)
        #expect(merged.origin == .remote)
        #expect(merged.isStructural)
        #expect(merged.touchedNodes == [a, b])
        #expect(merged.touchedFields[a] == [FieldPath(fields: 1), FieldPath(fields: 2)])
        #expect(merged.bounds[a] == BoundsChange(old: c0, new: c2))
        #expect(merged.bounds[b] == BoundsChange(old: nil, new: c0))
        #expect(remote.merging(ChangeSummary(origin: .local)).origin == .local, "a local change in the burst makes it local")
    }
}

@Suite struct DirtyRegionTests {
    let canvas: CanvasID = "c"

    @Test func ignoresNullAndNonFiniteButKeepsZeroArea() {
        var region = DirtyRegion()
        #expect(region.isEmpty)
        region.add(.null, canvas: canvas)
        region.add(Rect(minX: 0, minY: 0, maxX: .infinity, maxY: 1), canvas: canvas)
        region.add(Rect(minX: .nan, minY: 0, maxX: 1, maxY: 1), canvas: canvas)
        region.add(Rect(minX: 0, minY: -.infinity, maxX: 1, maxY: 1), canvas: canvas)
        region.add(Rect(minX: 0, minY: 0, maxX: 1, maxY: .nan), canvas: canvas)
        #expect(region.isEmpty)
        let hairline = Rect(x: 0, y: 5, width: 40, height: 0)
        region.add(hairline, canvas: canvas)
        #expect(region.rects(for: canvas) == [hairline])
        #expect(region.canvases == [canvas])
        #expect(region.rects(for: "other").isEmpty)
    }

    @Test func overlappingRectsMerge() {
        var region = DirtyRegion()
        region.add(Rect(x: 0, y: 0, width: 10, height: 10), canvas: canvas)
        region.add(Rect(x: 100, y: 100, width: 10, height: 10), canvas: canvas)
        #expect(region.rects(for: canvas).count == 2)
        // Bridges both: all three become one.
        region.add(Rect(x: 5, y: 5, width: 100, height: 100), canvas: canvas)
        #expect(region.rects(for: canvas) == [Rect(x: 0, y: 0, width: 110, height: 110)])
    }

    @Test func manyRectsMergeByLeastGrowth() {
        var region = DirtyRegion(maxRectsPerCanvas: 2)
        #expect(region.maxRectsPerCanvas == 2)
        region.add(Rect(x: 0, y: 0, width: 10, height: 10), canvas: canvas)
        region.add(Rect(x: 20, y: 0, width: 10, height: 10), canvas: canvas)
        region.add(Rect(x: 1000, y: 1000, width: 10, height: 10), canvas: canvas)
        let rects = region.rects(for: canvas)
        #expect(rects.count == 2)
        #expect(rects.contains(Rect(x: 0, y: 0, width: 30, height: 10)), "the two neighbours merge, not the far one")
        #expect(rects.contains(Rect(x: 1000, y: 1000, width: 10, height: 10)))
        #expect(DirtyRegion(maxRectsPerCanvas: 0).maxRectsPerCanvas == 1)
    }

    @Test func aMergeThatCreatesAnOverlapMergesAgain() {
        // Merging the closest pair (a, b) yields a rect that overlaps c.
        let a = Rect(x: 0, y: 0, width: 10, height: 10)
        let b = Rect(x: 0, y: 11, width: 10, height: 10)
        let c = Rect(x: -20, y: 10.3, width: 50, height: 0.4)
        let d = Rect(x: 500, y: 500, width: 1, height: 1)
        let merged = DirtyRegion.coalesce([a, b, c, d], limit: 3)
        #expect(merged.count == 2)
        #expect(merged.contains(a.union(b).union(c)))
        for (i, first) in merged.enumerated() {
            for second in merged[(i + 1)...] {
                #expect(!first.intersects(second))
            }
        }
    }

    @Test func hugeBurstsCollapseToOneRect() {
        let rects = (0...DirtyRegion.collapseThreshold).map { Rect(x: Double($0) * 20, y: 0, width: 1, height: 1) }
        let collapsed = DirtyRegion.coalesce(rects, limit: 32)
        #expect(collapsed == [Rect(x: 0, y: 0, width: Double(DirtyRegion.collapseThreshold) * 20 + 1, height: 1)])
    }

    @Test func unionAndTiles() {
        var first = DirtyRegion()
        first.add(Rect(x: 10, y: 10, width: 10, height: 10), canvas: canvas)
        var second = DirtyRegion()
        second.add(Rect(x: 300, y: 10, width: 10, height: 10), canvas: canvas)
        second.add(Rect(x: 0, y: 0, width: 5, height: 5), canvas: "other")
        first.formUnion(second)
        #expect(first.canvases == [canvas, "other"])
        let geometry = TileGeometry(zoomStep: ZoomStep(nearest: 1), rotationDegrees: 0)
        let tiles = first.tiles(for: canvas, geometry: geometry)
        #expect(tiles.map(\.column).sorted() == [0, 1])
        #expect(tiles.allSatisfy { $0.row == 0 && $0.canvas == canvas })
    }
}

@Suite struct InvalidationMapperTests {
    @Test func recordedBoundsBeforeAndAfterIncludingEffects() {
        let summary = InvalidationScene.move(0, by: Vector(dx: 300, dy: 0), effect: Rect(x: 400, y: 100, width: 50, height: 50))
        let region = InvalidationMapper().dirtyRegion(for: summary)
        let rects = region.rects(for: InvalidationScene.canvas)
        #expect(rects.count == 2)
        #expect(rects.contains(InvalidationScene.square(0)))
        #expect(rects.contains(InvalidationScene.square(0, offset: Vector(dx: 300, dy: 0)).union(Rect(x: 400, y: 100, width: 50, height: 50))))
        #expect(InvalidationMapper(maxRectsPerCanvas: 1).dirtyRegion(for: summary).rects(for: InvalidationScene.canvas).count == 1)
    }

    @Test func aNodeMovedToAnotherCanvasDirtiesBoth() {
        var summary = ChangeSummary()
        summary.record(InvalidationScene.node(0), old: NodeBounds(canvas: "a", rect: Rect(x: 0, y: 0, width: 1, height: 1)), new: NodeBounds(canvas: "b", rect: Rect(x: 5, y: 5, width: 1, height: 1)))
        let region = InvalidationMapper().dirtyRegion(for: summary)
        #expect(region.canvases == ["a", "b"])
    }

    @Test func touchedNodesWithoutBoundsAreLookedUpInTheLists() {
        let before = InvalidationScene.list()
        let after = InvalidationScene.list(offsets: [2: Vector(dx: 0, dy: 256)])
        var summary = ChangeSummary()
        summary.touch(InvalidationScene.node(2), fields: [FieldPath(fields: 3)])
        summary.touch(NodeID(counter: 999, replica: 1))  // in neither list: painted nothing
        let region = InvalidationMapper().dirtyRegion(for: summary, before: [before], after: [after])
        let rects = region.rects(for: InvalidationScene.canvas)
        #expect(Set(rects) == [InvalidationScene.square(2), InvalidationScene.square(2, offset: Vector(dx: 0, dy: 256))])
        #expect(InvalidationMapper().dirtyRegion(for: summary).isEmpty)
    }
}

@Suite struct DisplayListNodeTests {
    @Test func nodeIDsAreNormalizedToTheItemCount() {
        let items = InvalidationScene.list().items
        let short = DisplayList(canvas: "c", items: items, nodeIDs: [InvalidationScene.node(0)])
        #expect(short.nodeIDs.count == 6)
        #expect(short.index(of: InvalidationScene.node(0)) == 0)
        #expect(short.nodeIDs[5] == nil)
        let long = DisplayList(canvas: "c", items: Array(items.prefix(2)), nodeIDs: (0..<4).map(InvalidationScene.node))
        #expect(long.nodeIDs.count == 2)
        #expect(long.index(of: InvalidationScene.node(3)) == nil)
        let none = DisplayList(canvas: "c", items: items)
        #expect(none.nodeIDs.isEmpty)
        #expect(none.index(of: InvalidationScene.node(0)) == nil)
        #expect(none.bounds(of: InvalidationScene.node(0)) == nil)
    }

    @Test func boundsByNodeAndEquality() {
        let list = InvalidationScene.list()
        #expect(list.bounds(of: InvalidationScene.node(4)) == InvalidationScene.square(4))
        let unnamed = DisplayList(canvas: InvalidationScene.canvas, items: list.items)
        #expect(list != unnamed, "node ids are part of the list's value")
        #expect(list == InvalidationScene.list())
        #expect(Set([list, InvalidationScene.list(), unnamed]).count == 2)
    }

    @Test func builderCarriesNodes() {
        var builder = DisplayListBuilder(canvas: "c")
        builder.add(.fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), paint: .solid(red))), z: 2, node: InvalidationScene.node(1))
        builder.add(.fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 2, height: 2)), paint: .solid(red))), z: 1)
        let list = builder.build()
        #expect(list.nodeIDs == [nil, InvalidationScene.node(1)])
        #expect(list.index(of: InvalidationScene.node(1)) == 1)
        var plain = DisplayListBuilder(canvas: "c")
        plain.add(.fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), paint: .solid(red))))
        #expect(plain.build().nodeIDs.isEmpty)
    }
}

@Suite struct HitTesterChangeTests {
    @Test func aNonStructuralChangeUpdatesTheIndexInPlace() {
        var tester = HitTester(displayList: InvalidationScene.list(), viewport: InvalidationScene.viewport)
        let moved = InvalidationScene.list(offsets: [0: Vector(dx: 40, dy: 0)])
        let summary = InvalidationScene.move(0, by: Vector(dx: 40, dy: 0))
        tester.update(displayList: moved, changes: summary)
        #expect(tester.displayList == moved)
        #expect(tester.index.bounds(of: 0) == InvalidationScene.square(0, offset: Vector(dx: 40, dy: 0)))
        #expect(tester.hitTest(viewPoint: Point(x: 128, y: 128)).isEmpty, "the square left the point")
        #expect(tester.hitTest(viewPoint: Point(x: 168, y: 128)).first?.itemPath == [0])
    }

    @Test func structuralOrUnmappableChangesRebuild() {
        let list = InvalidationScene.list()
        var tester = HitTester(displayList: list, viewport: InvalidationScene.viewport)

        // Structural: z order changed.
        let reversed = DisplayList(canvas: list.canvas, items: list.items.reversed(), nodeIDs: list.nodeIDs.reversed())
        tester.update(displayList: reversed, changes: ChangeSummary(isStructural: true))
        #expect(tester.hitTest(viewPoint: Point(x: 128, y: 128)).first?.itemPath == [5])

        // A node whose index moved, without the structural flag, is still caught.
        var touched = ChangeSummary()
        touched.touch(InvalidationScene.node(0))
        tester.update(displayList: list, changes: touched)
        #expect(tester.hitTest(viewPoint: Point(x: 128, y: 128)).first?.itemPath == [0])

        // A list without node ids, or of another length, rebuilds.
        let unnamed = DisplayList(canvas: list.canvas, items: list.items)
        tester.update(displayList: unnamed, changes: touched)
        #expect(tester.displayList == unnamed)
        let shorter = DisplayList(canvas: list.canvas, items: Array(list.items.prefix(3)), nodeIDs: Array(list.nodeIDs.prefix(3)))
        tester.update(displayList: shorter, changes: touched)
        #expect(tester.index.count == 3)
    }
}

/// A target that records deliveries.
@MainActor
final class RecordingTarget: InvalidationTarget {
    var displayedCanvas: CanvasID?
    var deliveries: [(list: DisplayList?, rects: [Rect])] = []

    init(canvas: CanvasID?) {
        displayedCanvas = canvas
    }

    func apply(displayList: DisplayList?, invalidating rects: [Rect]) {
        deliveries.append((displayList, rects))
    }
}

/// A scheduler the test fires by hand: one frame.
@MainActor
final class ManualFrames {
    var queued: [@MainActor () -> Void] = []

    var scheduler: InvalidationBatcher.Scheduler {
        { [weak self] work in self?.queued.append(work) }
    }

    func fire() {
        let work = queued
        queued = []
        for item in work {
            item()
        }
    }
}

@MainActor
@Suite struct InvalidationBatcherTests {
    @Test func localChangesFlushAtOnce() {
        let frames = ManualFrames()
        let batcher = InvalidationBatcher(scheduler: frames.scheduler)
        let target = RecordingTarget(canvas: InvalidationScene.canvas)
        batcher.add(target)
        batcher.add(target)
        #expect(batcher.targetCount == 1)
        let after = InvalidationScene.list(offsets: [1: Vector(dx: 5, dy: 0)])
        batcher.submit(InvalidationScene.move(1, by: Vector(dx: 5, dy: 0), origin: .local), before: [InvalidationScene.list()], after: [after])
        #expect(frames.queued.isEmpty)
        #expect(!batcher.hasPending)
        #expect(batcher.flushCount == 1)
        #expect(target.deliveries.count == 1)
        #expect(target.deliveries[0].list == after)
        #expect(target.deliveries[0].rects == [InvalidationScene.square(1).union(InvalidationScene.square(1, offset: Vector(dx: 5, dy: 0)))])
    }

    @Test func remoteBurstsCoalesceIntoOneFrame() {
        let frames = ManualFrames()
        let batcher = InvalidationBatcher(scheduler: frames.scheduler)
        let target = RecordingTarget(canvas: InvalidationScene.canvas)
        let elsewhere = RecordingTarget(canvas: "elsewhere")
        let blank = RecordingTarget(canvas: nil)
        batcher.add(target)
        batcher.add(elsewhere)
        batcher.add(blank)
        var flushed: [DirtyRegion] = []
        batcher.onFlush = { _, region in flushed.append(region) }

        let first = InvalidationScene.list(offsets: [0: Vector(dx: 5, dy: 0)])
        let second = InvalidationScene.list(offsets: [0: Vector(dx: 10, dy: 0)])
        batcher.submit(InvalidationScene.move(0, by: Vector(dx: 5, dy: 0)), before: [InvalidationScene.list()], after: [first])
        batcher.submit(InvalidationScene.move(0, by: Vector(dx: 10, dy: 0)), before: [first], after: [second])
        #expect(batcher.hasPending)
        #expect(frames.queued.count == 1, "one frame is scheduled for the whole burst")
        #expect(target.deliveries.isEmpty)
        frames.fire()
        #expect(!batcher.hasPending)
        #expect(batcher.flushCount == 1)
        #expect(target.deliveries.count == 1)
        #expect(target.deliveries[0].list == second)
        #expect(elsewhere.deliveries.isEmpty, "nothing changed on its canvas")
        #expect(blank.deliveries.isEmpty)
        #expect(flushed.count == 1)

        // A later local change carries a pending remote burst with it.
        batcher.submit(InvalidationScene.move(3, by: Vector(dx: 1, dy: 0)))
        batcher.submit(InvalidationScene.move(4, by: Vector(dx: 1, dy: 0), origin: .local))
        #expect(batcher.flushCount == 2)
        #expect(target.deliveries[1].rects.count == 2)
        frames.fire()
        #expect(batcher.flushCount == 2, "the scheduled frame finds nothing pending")
        batcher.flush()
        #expect(batcher.flushCount == 2)
    }

    @Test func targetsAreHeldWeaklyAndRemovable() {
        let batcher = InvalidationBatcher(scheduler: ManualFrames().scheduler)
        var target: RecordingTarget? = RecordingTarget(canvas: InvalidationScene.canvas)
        batcher.add(target!)
        #expect(batcher.targetCount == 1)
        target = nil
        #expect(batcher.targetCount == 0)
        let kept = RecordingTarget(canvas: InvalidationScene.canvas)
        batcher.add(kept)
        batcher.submit(InvalidationScene.move(0, by: Vector(dx: 1, dy: 0), origin: .local))
        #expect(kept.deliveries.count == 1)
        batcher.remove(kept)
        #expect(batcher.targetCount == 0)
    }

    @Test func theDefaultSchedulerFlushesOnTheNextFrame() async {
        let batcher = InvalidationBatcher()
        let target = RecordingTarget(canvas: InvalidationScene.canvas)
        batcher.add(target)
        batcher.submit(InvalidationScene.move(0, by: Vector(dx: 1, dy: 0)))
        #expect(target.deliveries.isEmpty)
        let deadline = Date().addingTimeInterval(5)
        while target.deliveries.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(target.deliveries.count == 1)
        #expect(InvalidationBatcher.frameInterval < 0.01)
    }
}

/// REND-004 "Done when": a remote change to one object repaints only its tiles.
@MainActor
@Suite struct ChangeDrivenRepaintTests {
    private func makeCanvas() async -> TiledCanvasLayer {
        let canvas = TiledCanvasLayer(cache: TileCache(renderer: CoreGraphicsRenderer(), capacity: 64), backingScale: 1)
        let layout = canvas.update(displayList: InvalidationScene.list(), viewport: InvalidationScene.viewport)
        #expect(layout.placements.count == 6)
        await canvas.settle()
        #expect(await canvas.cache.renders == 6)
        return canvas
    }

    @Test func aChangeToOneObjectRepaintsOnlyItsTile() async {
        let canvas = await makeCanvas()
        let moved = InvalidationScene.list(offsets: [4: Vector(dx: 20, dy: -10)])
        canvas.update(displayList: moved, viewport: InvalidationScene.viewport, changes: InvalidationScene.move(4, by: Vector(dx: 20, dy: -10)))
        await canvas.settle()
        #expect(await canvas.cache.renders == 7, "only the square's own tile re-rendered")
        #expect(canvas.displayList == moved)

        // A recolour touches the node without moving it (bounds looked up by id).
        let recoloured = InvalidationScene.list(offsets: [4: Vector(dx: 20, dy: -10)], colors: [4: red])
        var recolour = ChangeSummary(origin: .remote)
        recolour.touch(InvalidationScene.node(4), fields: [FieldPath(fields: 3, 1)])
        canvas.update(displayList: recoloured, viewport: InvalidationScene.viewport, changes: recolour)
        await canvas.settle()
        #expect(await canvas.cache.renders == 8)

        // Moving across a tile boundary repaints where it was and where it is.
        let crossed = InvalidationScene.list(offsets: [4: Vector(dx: 20, dy: -10), 0: Vector(dx: 256, dy: 0)], colors: [4: red])
        canvas.update(displayList: crossed, viewport: InvalidationScene.viewport, changes: InvalidationScene.move(0, by: Vector(dx: 256, dy: 0)))
        await canvas.settle()
        #expect(await canvas.cache.renders == 10)
    }

    @Test func effectExpandedBoundsRepaintTheirNeighbours() async {
        let canvas = await makeCanvas()
        // A shadow reaching into the tile to the right and the one below.
        let shadow = InvalidationScene.square(0).offset(by: Vector(dx: 150, dy: 150))
        canvas.update(displayList: InvalidationScene.list(colors: [0: red]), viewport: InvalidationScene.viewport, changes: InvalidationScene.move(0, by: .zero, effect: shadow))
        await canvas.settle()
        #expect(await canvas.cache.renders == 6 + 4, "tile 0, its right and lower neighbours and the diagonal one")
    }

    @Test func withoutASummaryAChangedListRepaintsEverything() async {
        let canvas = await makeCanvas()
        canvas.update(displayList: InvalidationScene.list(offsets: [4: Vector(dx: 1, dy: 0)]), viewport: InvalidationScene.viewport)
        await canvas.settle()
        #expect(await canvas.cache.renders == 12)
        // A summary for a list of another canvas cannot be trusted either.
        let other = DisplayList(canvas: "other", items: InvalidationScene.list().items)
        canvas.update(displayList: other, viewport: InvalidationScene.viewport, changes: InvalidationScene.move(4, by: .zero))
        await canvas.settle()
        #expect(await canvas.cache.renders == 18)
    }

    @Test func aRemoteBurstRepaintsEachTileOnce() async {
        let canvas = await makeCanvas()
        let frames = ManualFrames()
        let batcher = InvalidationBatcher(scheduler: frames.scheduler)
        batcher.add(canvas)
        #expect(canvas.displayedCanvas == InvalidationScene.canvas)
        var list = InvalidationScene.list()
        for step in 1...10 {
            let next = InvalidationScene.list(offsets: [1: Vector(dx: Double(step), dy: 0)])
            var summary = ChangeSummary(origin: .remote)
            summary.record(InvalidationScene.node(1), old: InvalidationScene.bounds(InvalidationScene.square(1, offset: Vector(dx: Double(step - 1), dy: 0))), new: InvalidationScene.bounds(InvalidationScene.square(1, offset: Vector(dx: Double(step), dy: 0))))
            batcher.submit(summary, before: [list], after: [next])
            list = next
        }
        frames.fire()
        await canvas.settle()
        #expect(canvas.displayList == list)
        #expect(await canvas.cache.renders == 7, "ten remote changes, one frame, one tile")

        // An empty delivery (a list that changed nowhere visible) re-requests nothing.
        canvas.apply(displayList: nil, invalidating: [])
        await canvas.settle()
        #expect(await canvas.cache.renders == 7)
    }

    @Test func theCacheDropsTilesAtEveryZoomStepWithHalfAPixelOfSlack() async {
        let cache = TileCache(renderer: CoreGraphicsRenderer(), capacity: 64)
        let list = InvalidationScene.list()
        let one = TileGeometry(zoomStep: ZoomStep(nearest: 1), rotationDegrees: 0)
        let two = TileGeometry(zoomStep: ZoomStep(nearest: 2), rotationDegrees: 0)
        for key in one.tiles(coveringPasteboardRect: Rect(x: 0, y: 0, width: 767, height: 511), canvas: list.canvas) {
            _ = await cache.tile(for: key, in: list, geometry: one)
        }
        for key in two.tiles(coveringPasteboardRect: Rect(x: 0, y: 0, width: 255, height: 255), canvas: list.canvas) {
            _ = await cache.tile(for: key, in: list, geometry: two)
        }
        #expect(await cache.count == 6 + 4)
        #expect(await cache.invalidate(pasteboardRects: [], canvas: list.canvas).isEmpty)
        // Just inside tile (0, 0) at 1× (a quarter pixel from the edge at 256): also the
        // neighbour, within slack.
        let dropped = await cache.invalidate(pasteboardRects: [Rect(x: 250, y: 10, width: 5.9, height: 5)], canvas: list.canvas)
        #expect(dropped.filter { $0.zoomStep == one.zoomStep }.count == 2)
        #expect(dropped.filter { $0.zoomStep == two.zoomStep }.count == 1)
        #expect(await cache.invalidate(pasteboardRects: [Rect(x: 10, y: 10, width: 1, height: 1)], canvas: "other").isEmpty)
    }
}

/// The same "Done when" on the Metal tile canvas, counting rasterized tiles.
@MainActor
@Suite(.enabled(if: MetalAvailability.isAvailable, "no Metal device: Metal canvas run incomplete"))
struct MetalChangeDrivenRepaintTests {
    @Test func aRemoteChangeToOneObjectRasterizesOnlyItsTile() async {
        let canvas = MetalTileCanvas(context: MetalAvailability.context, backingScale: 1, atlasCapacity: 64)
        #expect(canvas.displayedCanvas == nil)
        canvas.update(displayList: InvalidationScene.list(), viewport: InvalidationScene.viewport)
        await canvas.settle()
        #expect(canvas.rasterizedTileCount == 6)
        #expect(canvas.displayedCanvas == InvalidationScene.canvas)

        canvas.update(displayList: InvalidationScene.list(offsets: [2: Vector(dx: 0, dy: 20)]), viewport: InvalidationScene.viewport, changes: InvalidationScene.move(2, by: Vector(dx: 0, dy: 20)))
        await canvas.settle()
        #expect(canvas.rasterizedTileCount == 7)

        let frames = ManualFrames()
        let batcher = InvalidationBatcher(scheduler: frames.scheduler)
        batcher.add(canvas)
        let next = InvalidationScene.list(offsets: [2: Vector(dx: 0, dy: 20), 5: Vector(dx: -3, dy: 0)])
        batcher.submit(InvalidationScene.move(5, by: Vector(dx: -3, dy: 0)), before: [canvas.displayList!], after: [next])
        frames.fire()
        await canvas.settle()
        #expect(canvas.displayList == next)
        #expect(canvas.rasterizedTileCount == 8)

        // Without a summary: everything.
        canvas.update(displayList: InvalidationScene.list(), viewport: InvalidationScene.viewport)
        await canvas.settle()
        #expect(canvas.rasterizedTileCount == 14)
        canvas.invalidate(pasteboardRects: [])
        await canvas.settle()
        #expect(canvas.rasterizedTileCount == 14)
    }

    @Test func theFallbackCanvasTakesSummariesToo() async {
        let canvas = MetalTileCanvas(context: nil, backingScale: 1)
        let fallback = try? #require(canvas.fallbackCanvas)
        canvas.update(displayList: InvalidationScene.list(), viewport: InvalidationScene.viewport)
        await canvas.settle()
        #expect(await fallback?.cache.renders == 6)
        canvas.update(displayList: InvalidationScene.list(offsets: [0: Vector(dx: 1, dy: 0)]), viewport: InvalidationScene.viewport, changes: InvalidationScene.move(0, by: Vector(dx: 1, dy: 0)))
        await canvas.settle()
        #expect(await fallback?.cache.renders == 7)
        let next = InvalidationScene.list(offsets: [0: Vector(dx: 1, dy: 0), 1: Vector(dx: 1, dy: 0)])
        canvas.apply(displayList: next, invalidating: [InvalidationScene.square(1).union(InvalidationScene.square(1, offset: Vector(dx: 1, dy: 0)))])
        await canvas.settle()
        #expect(fallback?.displayList == next)
        #expect(await fallback?.cache.renders == 8)
    }
}
