import Foundation

// GEO-005: snap resolution (`moving`, "Snapping"; `grid-guides`, "Snapping to points and
// objects").  The UI gathers candidates (object points, paths, ruler guides, smart guides, the
// grid) within the snap distance and asks the `Snapper` which one takes hold.

/// The kinds of snap target, in priority order: when several are within range, "a point wins
/// over a path, a path over a guide, a guide over a smart guide, and a smart guide over the
/// grid".  Lower raw values win.
public enum SnapKind: Int, CaseIterable, Comparable, Hashable, Sendable {
    /// Anchor points and handles of other objects (*Snap to Point*).
    case point = 0
    /// Any position along another object's path, or a guide object's path (*Snap to Object*).
    case path = 1
    /// Ruler guides on pages (*Snap to Guides*).
    case guide = 2
    /// Alignment lines derived from nearby objects while dragging (*Smart Guides*).
    case smartGuide = 3
    /// Grid intersections (*Snap to Grid*).
    case grid = 4

    @inlinable
    public static func < (lhs: SnapKind, rhs: SnapKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// An infinite line a dragged point can snap onto: a ruler guide or a smart guide.
public enum SnapGuide: Hashable, Sendable {
    /// A horizontal guide at `y`.
    case horizontal(y: Double)
    /// A vertical guide at `x`.
    case vertical(x: Double)
    /// A guide through `through` in `direction` (a smart guide along a rotated edge, or a
    /// ruler guide on a rotated canvas expressed in pasteboard space).
    case angled(through: Point, direction: Vector)

    /// A point on the guide and its direction; nil for an angled guide with a zero direction.
    public var line: (point: Point, direction: Vector)? {
        switch self {
        case .horizontal(let y):
            return (Point(x: 0, y: y), Vector(dx: 1, dy: 0))
        case .vertical(let x):
            return (Point(x: x, y: 0), Vector(dx: 0, dy: 1))
        case .angled(let through, let direction):
            guard direction.lengthSquared > 0, direction.isFinite else {
                return nil
            }
            return (through, direction)
        }
    }

    /// The perpendicular projection of `point` onto the guide.
    public func nearestPoint(to point: Point) -> Point? {
        guard let (origin, direction) = line else {
            return nil
        }
        let along = (point - origin).dot(direction) / direction.lengthSquared
        return origin + direction * along
    }

    /// Where two guides cross; nil when they are parallel (or degenerate).
    public func intersection(with other: SnapGuide) -> Point? {
        guard let (p, d) = line, let (q, e) = other.line else {
            return nil
        }
        let denominator = d.cross(e)
        if abs(denominator) <= 1e-12 * d.length * e.length {
            return nil
        }
        let t = (q - p).cross(e) / denominator
        return p + d * t
    }
}

/// The document grid as a snap target: a lattice of intersections at `origin + (i·spacing.dx,
/// j·spacing.dy)`.  For the *Relative grid* setting, use ``relative(to:)`` with the dragged
/// point's position at the start of the drag: the lattice then passes through that point, so
/// the object keeps its offset within a cell.
public struct SnapGrid: Hashable, Sendable {
    public var origin: Point
    public var spacing: Vector

    public init(origin: Point = .zero, spacing: Vector) {
        self.origin = origin
        self.spacing = spacing
    }

    /// A square grid of `size` from `origin`.
    public init(origin: Point = .zero, size: Double) {
        self.init(origin: origin, spacing: Vector(dx: size, dy: size))
    }

    /// The same lattice shifted so that `point` lies on an intersection.
    public func relative(to point: Point) -> SnapGrid {
        SnapGrid(origin: point, spacing: spacing)
    }

    /// The lattice point nearest `point`.  A non-positive spacing on an axis leaves that
    /// coordinate unsnapped.
    public func nearestIntersection(to point: Point) -> Point {
        func snap(_ value: Double, _ base: Double, _ step: Double) -> Double {
            guard step > 0, step.isFinite else {
                return value
            }
            return base + ((value - base) / step).rounded() * step
        }
        return Point(x: snap(point.x, origin.x, spacing.dx), y: snap(point.y, origin.y, spacing.dy))
    }
}

/// One thing a dragged point may snap to.  The UI builds the list from its R-tree query; each
/// case knows how to find the closest snap position to a point.
public enum SnapCandidate: Hashable, Sendable {
    /// An anchor point or handle.
    case point(Point)
    /// A whole contour: snaps to the nearest position along it.
    case path(Contour)
    /// A single segment of a path.
    case segment(CubicBezier)
    /// A ruler guide.
    case guide(SnapGuide)
    /// A guide object: a path on the Guides layer, which snaps to the nearest point along it
    /// with a guide's priority (`grid-guides`, "Turning paths into guides").
    case guideObject(Contour)
    /// A smart guide.
    case smartGuide(SnapGuide)
    /// The grid.
    case grid(SnapGrid)

    public var kind: SnapKind {
        switch self {
        case .point: return .point
        case .path, .segment: return .path
        case .guide, .guideObject: return .guide
        case .smartGuide: return .smartGuide
        case .grid: return .grid
        }
    }

    /// The guide of a line-like candidate.
    public var guide: SnapGuide? {
        switch self {
        case .guide(let g), .smartGuide(let g): return g
        default: return nil
        }
    }

    /// The position this candidate would snap `point` to; nil for an empty contour or a
    /// degenerate guide.
    public func nearestPoint(to point: Point) -> Point? {
        switch self {
        case .point(let p):
            return p
        case .path(let contour), .guideObject(let contour):
            return contour.nearestPoint(to: point)?.point
        case .segment(let curve):
            return curve.nearestPoint(to: point).point
        case .guide(let g), .smartGuide(let g):
            return g.nearestPoint(to: point)
        case .grid(let grid):
            return grid.nearestIntersection(to: point)
        }
    }
}

/// What a snap resolved to, so the tool can move the point and the overlay can draw the
/// target (point badge, path highlight, guide triangle, smart-guide line).
public struct SnapResult: Hashable, Sendable {
    /// The snapped position in pasteboard coordinates.
    public var point: Point
    /// The winning candidate and its index in the list the snapper was given.
    public var candidate: SnapCandidate
    public var candidateIndex: Int
    public var kind: SnapKind
    /// Pasteboard distance from the query point to the winning candidate's snap position.
    public var distance: Double
    /// When the winner is a guide and another non-parallel guide is also within range, the
    /// point is snapped to their crossing and this is the index of the second guide.
    public var secondaryIndex: Int?

    public init(
        point: Point, candidate: SnapCandidate, candidateIndex: Int, kind: SnapKind, distance: Double,
        secondaryIndex: Int? = nil
    ) {
        self.point = point
        self.candidate = candidate
        self.candidateIndex = candidateIndex
        self.kind = kind
        self.distance = distance
        self.secondaryIndex = secondaryIndex
    }
}

/// Resolves a point against snap candidates.
///
/// Rules, from `moving` and `grid-guides`:
/// * A candidate is in range when its snap position is within the *Snap distance* of the point.
///   The preference is in view pixels (default 3); it is divided by `zoom` to get pasteboard
///   units, so the reach on the canvas stays the same at every magnification.
/// * Among candidates in range the ranking is priority first (``SnapKind``: point > path >
///   guide > smart guide > grid), then distance, then position in the candidate list, so the
///   outcome is deterministic when two candidates are equally close.
/// * Kinds absent from `enabledKinds` are ignored (the View menu toggles); kbd:[Control]
///   suspends snapping altogether, which the tool expresses by not asking.
/// * A guide winner combines with the nearest other non-parallel guide in range: the point
///   snaps to their crossing when that crossing is itself within range.
public struct Snapper: Hashable, Sendable {
    /// The *Snap distance* preference, in view pixels.
    public var snapDistance: Double
    /// View pixels per pasteboard point.
    public var zoom: Double
    public var enabledKinds: Set<SnapKind>

    public init(snapDistance: Double = 3, zoom: Double = 1, enabledKinds: Set<SnapKind> = Set(SnapKind.allCases)) {
        self.snapDistance = snapDistance
        self.zoom = zoom
        self.enabledKinds = enabledKinds
    }

    /// The snap distance in pasteboard units.  A non-positive or non-finite zoom counts as 1.
    public var pasteboardSnapDistance: Double {
        zoom > 0 && zoom.isFinite ? snapDistance / zoom : snapDistance
    }

    /// The winning snap for `point`, or nil when nothing enabled is in range.
    public func resolve(_ point: Point, candidates: [SnapCandidate]) -> SnapResult? {
        guard point.isFinite else {
            return nil
        }
        let reach = pasteboardSnapDistance
        var best: SnapResult?
        for (index, candidate) in candidates.enumerated() {
            let kind = candidate.kind
            guard enabledKinds.contains(kind), let target = candidate.nearestPoint(to: point), target.isFinite else {
                continue
            }
            let distance = target.distance(to: point)
            guard distance <= reach else {
                continue
            }
            if let current = best {
                if kind > current.kind {
                    continue
                }
                if kind == current.kind && distance >= current.distance {
                    continue
                }
            }
            best = SnapResult(point: target, candidate: candidate, candidateIndex: index, kind: kind, distance: distance)
        }
        guard var result = best else {
            return nil
        }
        if let guide = result.candidate.guide {
            combine(&result, guide: guide, point: point, candidates: candidates, reach: reach)
        }
        return result
    }

    /// Snaps `point + delta` and returns the delta that lands the point there, so a drag of a
    /// whole selection moves by the snapped amount.
    public func resolveDrag(of point: Point, by delta: Vector, candidates: [SnapCandidate]) -> (delta: Vector, snap: SnapResult?) {
        let moved = point + delta
        guard let snap = resolve(moved, candidates: candidates) else {
            return (delta, nil)
        }
        return (snap.point - point, snap)
    }

    private func combine(_ result: inout SnapResult, guide: SnapGuide, point: Point, candidates: [SnapCandidate], reach: Double) {
        var bestIndex: Int?
        var bestCrossing = Point.zero
        var bestDistance = Double.infinity
        for (index, candidate) in candidates.enumerated() where index != result.candidateIndex {
            guard enabledKinds.contains(candidate.kind), let other = candidate.guide,
                let onOther = other.nearestPoint(to: point), onOther.distance(to: point) <= reach,
                let crossing = guide.intersection(with: other), crossing.isFinite
            else {
                continue
            }
            let distance = crossing.distance(to: point)
            if distance <= reach && distance < bestDistance {
                bestDistance = distance
                bestCrossing = crossing
                bestIndex = index
            }
        }
        if let index = bestIndex {
            result.point = bestCrossing
            result.secondaryIndex = index
        }
    }
}
