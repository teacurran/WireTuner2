// Snapping to the grid, guides, points and objects (DOC-016; docs/_includes/document/
// grid-guides.adoc, "Snapping to guides", "Snapping to points and objects" and "Client").
// WTGeometry's `Snapper` (GEO-005) ranks candidates -- point > path > guide > smart guide > grid
// -- within the snap distance; this file gathers the candidates a drag can snap to from the
// canvas's display list and the document's guides and grid, applies the View menu toggles and
// kbd:[Control] suspension, and reports which kind won so the pointer can show the triangle,
// point badge or smart-guide line.

import WTGeometry

/// The View menu's snapping toggles (local view state, never in the document).
public struct SnapToggles: Hashable, Sendable {
    /// View > Grid > Snap to Grid.
    public var grid: Bool
    /// View > Guides > Snap to Guides (on by default).
    public var guides: Bool
    /// View > Snap to Point: anchor points and handles of other objects.
    public var points: Bool
    /// View > Snap to Object: the nearest point along other objects' paths.
    public var objects: Bool
    /// View > Smart Guides.
    public var smartGuides: Bool

    public init(grid: Bool = false, guides: Bool = true, points: Bool = true, objects: Bool = true, smartGuides: Bool = true) {
        self.grid = grid
        self.guides = guides
        self.points = points
        self.objects = objects
        self.smartGuides = smartGuides
    }

    /// The snap kinds these toggles enable.
    public var enabledKinds: Set<SnapKind> {
        var kinds: Set<SnapKind> = []
        if points { kinds.insert(.point) }
        if objects { kinds.insert(.path) }
        if guides { kinds.insert(.guide) }
        if smartGuides { kinds.insert(.smartGuide) }
        if grid { kinds.insert(.grid) }
        return kinds
    }
}

/// What a drag can snap to, gathered once when the drag starts: the grid, every page's guides in
/// pasteboard space, the guide objects, the canvas's drawn objects (with those being dragged
/// left out) and the smart guides of the moment.
public struct SnapSources: Sendable {
    public var grid: GridSpec?
    /// Ruler guides of every page (and of child pages' masters), pasteboard space.
    public var guides: [SnapGuide]
    /// Paths on the Guides layer: they snap along their outline at guide priority.
    public var guideObjects: [Contour]
    /// The canvas's display list and its R-tree of top-level item bounds (the hit tester's).
    public var displayList: DisplayList?
    public var index: RTree<Int>?
    /// Top-level items not to snap to: the objects being dragged.
    public var excludedItems: Set<Int>
    /// Smart guides (OBJ-038), recomputed by the tool as the drag goes.
    public var smartGuides: [SnapGuide]
    /// Lines of the perspective grid shown (perspective.adoc, "With Snap to Grid on, objects moved
    /// with the Pointer tool snap to the perspective grid lines"; FX-043): snapped along with
    /// *Snap to Grid*, at guide priority.
    public var gridLines: [Contour]

    public init(grid: GridSpec? = nil, guides: [SnapGuide] = [], guideObjects: [Contour] = [], displayList: DisplayList? = nil,
                index: RTree<Int>? = nil, excludedItems: Set<Int> = [], smartGuides: [SnapGuide] = [], gridLines: [Contour] = []) {
        self.gridLines = gridLines
        self.grid = grid
        self.guides = guides
        self.guideObjects = guideObjects
        self.displayList = displayList
        self.index = index
        self.excludedItems = excludedItems
        self.smartGuides = smartGuides
    }

    /// The contours of the items on the Guides layer of `list`: its guide objects.
    public static func guideObjects(in list: DisplayList) -> [Contour] {
        list.layers.filter(\.layer.isGuides).flatMap { span in
            span.range.flatMap { SnapSources.geometry(of: list.items[$0]).flatMap { $0.path.applying($0.transform).contours } }
        }
    }

    /// The paths an item draws, with their local → pasteboard transforms (groups flattened;
    /// images and text runs have no snap geometry).
    static func geometry(of item: DisplayItem) -> [(path: DisplayPath, transform: AffineTransform)] {
        switch item {
        case .fill(let fill): return [(fill.path, fill.transform)]
        case .stroke(let stroke): return [(stroke.path, stroke.transform)]
        case .path(let path): return [(path.path, path.transform)]
        case .group(let group): return group.children.flatMap(geometry)
        case .image, .text: return []
        }
    }
}

/// Resolves dragged points against `SnapSources` (DOC-016).
public struct SnapEngine: Hashable, Sendable {
    /// The *Snap distance* preference, view pixels (default 3).
    public var snapDistance: Double
    /// View pixels per pasteboard point.
    public var zoom: Double
    public var toggles: SnapToggles

    public init(snapDistance: Double = 3, zoom: Double = 1, toggles: SnapToggles = SnapToggles()) {
        self.snapDistance = snapDistance
        self.zoom = zoom
        self.toggles = toggles
    }

    var snapper: Snapper {
        Snapper(snapDistance: snapDistance, zoom: zoom, enabledKinds: toggles.enabledKinds)
    }

    /// The candidates within reach of `point`.  `dragOrigin` is the dragged point where the drag
    /// started: with *Relative grid* the lattice passes through it, so the point keeps its offset
    /// within a cell (grid-guides.adoc, "The grid").
    public func candidates(near point: Point, sources: SnapSources, dragOrigin: Point? = nil) -> [SnapCandidate] {
        let reach = snapper.pasteboardSnapDistance
        var result: [SnapCandidate] = []
        if toggles.points || toggles.objects, let list = sources.displayList, let index = sources.index {
            let area = Rect(x: point.x - reach, y: point.y - reach, width: 2 * reach, height: 2 * reach)
            let guideItems = sources.guideItems(list)
            for item in index.query(area).sorted() where !sources.excludedItems.contains(item) && !guideItems.contains(item)
                && list.items.indices.contains(item) {
                for (path, transform) in SnapSources.geometry(of: list.items[item]) {
                    let placed = path.applying(transform)
                    if toggles.points {
                        result += Self.points(of: placed).filter { abs($0.x - point.x) <= reach && abs($0.y - point.y) <= reach }.map(SnapCandidate.point)
                    }
                    if toggles.objects {
                        result += placed.contours.filter { !$0.segments.isEmpty }.map(SnapCandidate.path)
                    }
                }
            }
        }
        if toggles.guides {
            result += sources.guides.map(SnapCandidate.guide)
            result += sources.guideObjects.filter { !$0.segments.isEmpty }.map(SnapCandidate.guideObject)
        }
        if toggles.smartGuides {
            result += sources.smartGuides.map(SnapCandidate.smartGuide)
        }
        if toggles.grid {
            result += sources.gridLines.filter { !$0.segments.isEmpty }.map(SnapCandidate.guideObject)
        }
        if toggles.grid, let grid = sources.grid, grid.isValid {
            let lattice = grid.relative ? grid.snapGrid.relative(to: dragOrigin ?? point) : grid.snapGrid
            result.append(.grid(lattice))
        }
        return result
    }

    /// Where `point` snaps, or nil (nothing in reach, or kbd:[Control] held: `suspended`).
    public func resolve(_ point: Point, sources: SnapSources, dragOrigin: Point? = nil, suspended: Bool = false) -> SnapResult? {
        guard !suspended else { return nil }
        return snapper.resolve(point, candidates: candidates(near: point, sources: sources, dragOrigin: dragOrigin))
    }

    /// Snaps `point + delta` (a drag of the selection by its snapping point) and returns the
    /// delta that lands it there, with what it snapped to.  With *Relative grid*, `point` is the
    /// drag origin, so a grid snap moves by whole cells.
    public func resolveDrag(of point: Point, by delta: Vector, sources: SnapSources, suspended: Bool = false) -> (delta: Vector, snap: SnapResult?) {
        guard let snap = resolve(point + delta, sources: sources, dragOrigin: point, suspended: suspended) else { return (delta, nil) }
        return (snap.point - point, snap)
    }

    /// The anchors and control points of `path` (pasteboard): *Snap to Point* targets.
    static func points(of path: DisplayPath) -> [Point] {
        var result: [Point] = []
        for element in path.elements {
            switch element {
            case .move(let p), .line(let p): result.append(p)
            case .quadCurve(let c, let p): result += [c, p]
            case .cubicCurve(let c1, let c2, let p): result += [c1, c2, p]
            case .close: break
            }
        }
        return result
    }
}

extension SnapSources {
    /// The top-level items on the Guides layer (they snap as guide objects, not as objects).
    func guideItems(_ list: DisplayList) -> Set<Int> {
        Set(list.layers.filter(\.layer.isGuides).flatMap(\.range))
    }
}

/// What the pointer shows for a snap (grid-guides.adoc, "Client"): the triangle for a grid or
/// guide, the point badge for a point, a highlight for a path, the line for a smart guide.
public enum SnapFeedback: Hashable, Sendable {
    case point(Point)
    case path(Point)
    case guide(SnapGuide, crossing: SnapGuide?)
    case guideObject(Point)
    case smartGuide(SnapGuide)
    case grid(Point)

    /// The feedback of `result`; `candidates` is the list the result was resolved from (for the
    /// second guide of a crossing).
    public init(_ result: SnapResult, candidates: [SnapCandidate] = []) {
        switch result.candidate {
        case .point: self = .point(result.point)
        case .path, .segment: self = .path(result.point)
        case .guide(let guide):
            let crossing = result.secondaryIndex.flatMap { candidates.indices.contains($0) ? candidates[$0].guide : nil }
            self = .guide(guide, crossing: crossing)
        case .guideObject: self = .guideObject(result.point)
        case .smartGuide(let guide): self = .smartGuide(guide)
        case .grid: self = .grid(result.point)
        }
    }
}
