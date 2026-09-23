// Change-driven invalidation (REND-004; docs/spec/client.adoc, "The display list": the
// invalidation pipeline is `ChangeSummary` -> dirty rects -> dirty tile keys, shared by both
// renderers).  A change repaints the tiles under each touched node's painted bounds before and
// after it (effects included) and nothing else; remote bursts are coalesced into one repaint
// per frame.

import WTGeometry
import Foundation

/// Dirty pasteboard rectangles per canvas, kept few by merging.
public struct DirtyRegion: Hashable, Sendable {
    /// Beyond this many rectangles on one canvas, pairs are merged (smallest growth first).
    public let maxRectsPerCanvas: Int
    /// Beyond this many rectangles on one canvas before merging, the canvas collapses to one
    /// bounding rectangle: pairwise merging is quadratic, and a burst that touches that many
    /// places repaints most of the view anyway.
    public static let collapseThreshold = 512

    private var rectsByCanvas: [CanvasID: [Rect]] = [:]

    public init(maxRectsPerCanvas: Int = 32) {
        self.maxRectsPerCanvas = max(maxRectsPerCanvas, 1)
    }

    public var isEmpty: Bool { rectsByCanvas.isEmpty }

    /// The canvases with anything dirty.
    public var canvases: Set<CanvasID> { Set(rectsByCanvas.keys) }

    /// The dirty rectangles of `canvas`, merged: no two intersect.
    public func rects(for canvas: CanvasID) -> [Rect] {
        rectsByCanvas[canvas] ?? []
    }

    /// Adds `rect` on `canvas`.  Null and non-finite rectangles are ignored; zero-area ones are
    /// kept (a horizontal hairline paints).
    public mutating func add(_ rect: Rect, canvas: CanvasID) {
        guard !rect.isNull, rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else {
            return
        }
        var rects = rectsByCanvas[canvas] ?? []
        rects.append(rect)
        rectsByCanvas[canvas] = DirtyRegion.coalesce(rects, limit: maxRectsPerCanvas)
    }

    /// Adds every rectangle of `other`.
    public mutating func formUnion(_ other: DirtyRegion) {
        for (canvas, rects) in other.rectsByCanvas {
            for rect in rects {
                add(rect, canvas: canvas)
            }
        }
    }

    /// Every tile of `geometry` on `canvas` that a dirty rectangle touches.
    public func tiles(for canvas: CanvasID, geometry: TileGeometry) -> Set<TileKey> {
        var keys: Set<TileKey> = []
        for rect in rects(for: canvas) {
            keys.formUnion(geometry.tiles(coveringPasteboardRect: rect, canvas: canvas))
        }
        return keys
    }

    /// Merges intersecting rectangles until none intersect, then merges the pair whose union
    /// grows least while more than `limit` remain.
    static func coalesce(_ input: [Rect], limit: Int) -> [Rect] {
        if input.count > collapseThreshold {
            return [input.dropFirst().reduce(input[0]) { $0.union($1) }]
        }
        var rects = input
        var merged = true
        while merged {
            merged = false
            outer: for i in rects.indices {
                for j in rects.indices where j > i && rects[i].intersects(rects[j]) {
                    rects[i] = rects[i].union(rects[j])
                    rects.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
        while rects.count > limit {
            var best = (i: 0, j: 1, growth: Double.infinity)
            for i in rects.indices {
                for j in rects.indices where j > i {
                    let union = rects[i].union(rects[j])
                    let growth = area(union) - area(rects[i]) - area(rects[j])
                    if growth < best.growth {
                        best = (i, j, growth)
                    }
                }
            }
            rects[best.i] = rects[best.i].union(rects[best.j])
            rects.remove(at: best.j)
            // A merged rectangle can now overlap others.
            rects = coalesce(rects, limit: .max)
        }
        return rects
    }

    private static func area(_ rect: Rect) -> Double {
        rect.width * rect.height
    }
}

/// Maps change summaries to dirty regions.
public struct InvalidationMapper: Hashable, Sendable {
    public var maxRectsPerCanvas: Int

    public init(maxRectsPerCanvas: Int = 32) {
        self.maxRectsPerCanvas = maxRectsPerCanvas
    }

    /// The pasteboard rectangles `summary` makes dirty: each recorded node's painted bounds
    /// (effect-expanded) before and after, on the canvases they were and are on.  A touched node
    /// without recorded bounds is looked up in `before` and `after` (the display lists either
    /// side of the change) by node id; one found in neither painted nothing.
    public func dirtyRegion(for summary: ChangeSummary, before: [DisplayList] = [], after: [DisplayList] = []) -> DirtyRegion {
        var region = DirtyRegion(maxRectsPerCanvas: maxRectsPerCanvas)
        for node in summary.touchedNodes.sorted() {
            if let change = summary.bounds[node] {
                for bounds in [change.old, change.new].compactMap({ $0 }) {
                    region.add(bounds.paintedRect, canvas: bounds.canvas)
                }
                continue
            }
            for list in before + after {
                if let rect = list.bounds(of: node) ?? list.bounds(ofLayer: node) {
                    region.add(rect, canvas: list.canvas)
                }
            }
        }
        InvalidationMapper.addLenses(over: &region, lists: before + after)
        return region
    }

    /// A lens shows what is beneath it anywhere in its bounds (magnified, from its centerpoint),
    /// so a change under any part of a lens repaints all of it, and so on up a stack of lenses
    /// (ATTR-019).
    static func addLenses(over region: inout DirtyRegion, lists: [DisplayList]) {
        for list in lists where !list.lensIndices.isEmpty {
            var pending = list.lensIndices.compactMap { index in list.itemBounds[index] }
            var grew = true
            while grew {
                grew = false
                let dirty = region.rects(for: list.canvas)
                for (position, bounds) in pending.enumerated() where dirty.contains(where: { $0.intersects(bounds) }) {
                    region.add(bounds, canvas: list.canvas)
                    pending.remove(at: position)
                    grew = true
                    break
                }
            }
        }
    }
}

/// Something that shows a display list in tiles and repaints only what changed: the Core
/// Graphics tile canvas and the Metal tile canvas.
@MainActor
public protocol InvalidationTarget: AnyObject {
    /// The canvas shown, if any.
    var displayedCanvas: CanvasID? { get }

    /// Shows `displayList` (when given: the list after the changes) without dropping every
    /// tile, and repaints the tiles under `rects` (pasteboard space).
    func apply(displayList: DisplayList?, invalidating rects: [Rect])
}

/// Coalesces change summaries and delivers them to invalidation targets: local changes at once,
/// remote ones once per frame, so a burst of remote changes repaints each tile once.
@MainActor
public final class InvalidationBatcher {
    /// Runs its argument later, on the main actor: the next frame.
    public typealias Scheduler = @MainActor (@escaping @MainActor () -> Void) -> Void

    /// One frame at the canvas's maximum refresh (120 Hz).
    public static let frameInterval = 1.0 / 120

    /// The default scheduler: after one frame interval on the main queue.
    public static let nextFrame: Scheduler = { work in
        DispatchQueue.main.asyncAfter(deadline: .now() + frameInterval) {
            MainActor.assumeIsolated { work() }
        }
    }

    public let mapper: InvalidationMapper
    private let scheduler: Scheduler
    private var targets: [WeakTarget] = []
    private var pending: ChangeSummary?
    private var pendingBefore: [CanvasID: DisplayList] = [:]
    private var pendingAfter: [CanvasID: DisplayList] = [:]
    private var scheduled = false
    /// Deliveries so far (a counter for tests and the frame-time harness).
    public private(set) var flushCount = 0
    /// Called with every delivered summary and its region, after the targets.
    public var onFlush: (@MainActor (ChangeSummary, DirtyRegion) -> Void)?

    public init(mapper: InvalidationMapper = InvalidationMapper(), scheduler: @escaping Scheduler = InvalidationBatcher.nextFrame) {
        self.mapper = mapper
        self.scheduler = scheduler
    }

    /// Delivers to `target` from now on (held weakly).
    public func add(_ target: any InvalidationTarget) {
        targets.removeAll { $0.target == nil || $0.target === target }
        targets.append(WeakTarget(target: target))
    }

    /// Stops delivering to `target`.
    public func remove(_ target: any InvalidationTarget) {
        targets.removeAll { $0.target == nil || $0.target === target }
    }

    public var targetCount: Int { targets.filter { $0.target != nil }.count }

    /// Whether a summary is waiting for the next frame.
    public var hasPending: Bool { pending != nil }

    /// Takes an applied change with the display lists before and after it (those of the
    /// canvases it touched).  Local changes flush at once, carrying any pending remote burst
    /// with them; remote ones wait for the next frame.
    public func submit(_ summary: ChangeSummary, before: [DisplayList] = [], after: [DisplayList] = []) {
        if var current = pending {
            current.merge(summary)
            pending = current
        } else {
            pending = summary
        }
        for list in before where pendingBefore[list.canvas] == nil {
            pendingBefore[list.canvas] = list
        }
        for list in after {
            pendingAfter[list.canvas] = list
        }
        if summary.origin == .local {
            flush()
        } else if !scheduled {
            scheduled = true
            scheduler { [weak self] in
                self?.scheduledFlush()
            }
        }
    }

    private func scheduledFlush() {
        scheduled = false
        flush()
    }

    /// Delivers whatever is pending now.
    public func flush() {
        guard let summary = pending else {
            return
        }
        let before = Array(pendingBefore.values)
        let after = pendingAfter
        pending = nil
        pendingBefore = [:]
        pendingAfter = [:]
        let region = mapper.dirtyRegion(for: summary, before: before, after: Array(after.values))
        flushCount += 1
        targets.removeAll { $0.target == nil }
        for entry in targets {
            guard let target = entry.target, let canvas = target.displayedCanvas else {
                continue
            }
            let rects = region.rects(for: canvas)
            let list = after[canvas]
            if list != nil || !rects.isEmpty {
                target.apply(displayList: list, invalidating: rects)
            }
        }
        onFlush?(summary, region)
    }

    private struct WeakTarget {
        weak var target: (any InvalidationTarget)?
    }
}

// MARK: - Colour invalidation (COLOR-006, CMS-006)

extension InvalidationMapper {
    /// The region a swatch recolor dirties: the painted bounds of every dependent node
    /// (`SwatchDependents`, resolved by WTModel) in each display list, batched -- past
    /// `DirtyRegion.collapseThreshold` dependents on a canvas the canvas collapses to their
    /// union at once instead of merging rectangle by rectangle, so a swatch used by 50,000
    /// objects costs one pass over their bounds.  Lenses over any of them repaint too.
    public func dirtyRegion(recoloring nodes: some Sequence<NodeID>, in lists: [DisplayList]) -> DirtyRegion {
        var region = DirtyRegion(maxRectsPerCanvas: maxRectsPerCanvas)
        let dependents = Array(nodes)
        for list in lists {
            let rects = dependents.compactMap { list.bounds(of: $0) }
            if rects.count > DirtyRegion.collapseThreshold, let union = DisplayList.union(of: rects) {
                region.add(union, canvas: list.canvas)
            } else {
                for rect in rects {
                    region.add(rect, canvas: list.canvas)
                }
            }
        }
        InvalidationMapper.addLenses(over: &region, lists: lists)
        return region
    }

    /// Everything each list paints: the whole-document repaint for a change to the document's
    /// colour settings (`SettingsProps.color`) or a new colour pipeline (CMS-006).
    public func wholeDocument(_ lists: [DisplayList]) -> DirtyRegion {
        var region = DirtyRegion(maxRectsPerCanvas: maxRectsPerCanvas)
        for list in lists {
            if let bounds = list.bounds {
                region.add(bounds, canvas: list.canvas)
            }
        }
        return region
    }

    /// The frames of the placed images of blob `assetID`: what `ImageStore.onReady` repaints.
    public func dirtyRegion(imageAsset assetID: String, in lists: [DisplayList]) -> DirtyRegion {
        var region = DirtyRegion(maxRectsPerCanvas: maxRectsPerCanvas)
        for list in lists {
            for rect in list.bounds(ofImageAsset: assetID) {
                region.add(rect, canvas: list.canvas)
            }
        }
        InvalidationMapper.addLenses(over: &region, lists: lists)
        return region
    }
}
