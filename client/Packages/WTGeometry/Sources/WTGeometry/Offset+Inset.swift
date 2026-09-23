import Foundation

// GEO-003: Inset Path (`inset-path`).

/// How the distances of a multi-step inset are spread (`inset-path`, "Spacing").
public enum InsetSpacing: Hashable, Sendable, CaseIterable {
    /// Equal gaps: step `k` of `n` at `d·k/n`.
    case uniform
    /// Wider gaps near the original, narrower toward the center: `d·(k/n)^0.5`.
    case farther
    /// Narrower gaps near the original, wider toward the center: `d·(k/n)^2`.
    case nearer

    /// The distance of step `step` (1-based) of `steps`, for a total inset of `distance`.
    public func distance(step: Int, of steps: Int, total distance: Double) -> Double {
        guard steps > 0 else {
            return 0
        }
        let fraction = Double(min(max(step, 0), steps)) / Double(steps)
        switch self {
        case .uniform: return distance * fraction
        case .farther: return distance * fraction.squareRoot()
        case .nearer: return distance * fraction * fraction
        }
    }
}

extension Offset {
    /// The region of `path` shrunk by `distance` (grown, for a negative distance): the points at
    /// least `distance` inside it (or within `−distance` of it), normalized.
    ///
    /// Open contours count as closed by their chord, as their fill paints (the Inset Path command
    /// refuses them).  `join` shapes the corners that turn away from the offset -- the reflex
    /// corners of an inset, the convex corners of an outset -- and the others stay sharp, with
    /// `miterLimit` in multiples of twice the distance, as for a stroke of that width.  An inset
    /// that collapses the region (a distance at least its narrowest half-width) returns
    /// ``FilledPath/empty``, and so do the slivers thinner than `tolerance` that rounding leaves
    /// where the region barely survives: a piece is kept only while its signed area exceeds half
    /// its perimeter times `tolerance`.
    ///
    /// Also ``FilledPath/empty`` when the offset cannot be computed (see
    /// ``checkedInset(_:by:join:miterLimit:tolerance:)``, which says so): never the input
    /// unchanged.
    public static func inset(
        _ path: FilledPath, by distance: Double, join: LineJoin = .miter, miterLimit: Double = 4,
        tolerance: Double = defaultTolerance
    ) -> FilledPath {
        (try? checkedInset(path, by: distance, join: join, miterLimit: miterLimit, tolerance: tolerance)) ?? .empty
    }

    /// ``inset(_:by:join:miterLimit:tolerance:)``, throwing instead of returning an empty path
    /// when the offset cannot be computed: ``OffsetError/unresolvedOutline`` when the boolean
    /// work left part of the band or of the result unresolved, ``OffsetError/unchanged`` when a
    /// distance larger than the tolerance changed the area by less than a hundredth of what the
    /// band along the boundary adds or removes (about perimeter × distance).  A collapse is a
    /// result, not an error: it returns ``FilledPath/empty``.
    public static func checkedInset(
        _ path: FilledPath, by distance: Double, join: LineJoin = .miter, miterLimit: Double = 4,
        tolerance: Double = defaultTolerance
    ) throws(OffsetError) -> FilledPath {
        guard distance.isFinite else {
            return .empty
        }
        let options = booleanOptions(tolerance)
        let normalized = Arrangement(operands: [path], options: options).extractReporting { $0[0] }
        guard normalized.unclosed == 0 else {
            throw .unresolvedOutline
        }
        let region = normalized.path
        guard !region.isEmpty else {
            return .empty
        }
        if distance == 0 {
            return region
        }
        let bounds = region.bounds
        if distance > 0 && 2 * distance >= min(bounds.width, bounds.height) {
            return .empty  // no disc of that radius fits inside
        }
        let band = try checkedStrokeOutline(
            region.contours,
            style: StrokeStyle(width: 2 * abs(distance), cap: .butt, join: join, miterLimit: miterLimit),
            tolerance: tolerance)
        let combined = Arrangement(operands: [region, band], options: options)
            .extractReporting { distance > 0 ? $0[0] && !$0[1] : $0[0] || $0[1] }
        guard combined.unclosed == 0 else {
            throw .unresolvedOutline
        }
        let tol = effectiveTolerance(tolerance, extent: max(abs(bounds.minX), abs(bounds.maxX), abs(bounds.minY), abs(bounds.maxY)))
        let kept = combined.path.pieces().filter { piece in
            let perimeter = piece.contours.reduce(0) { $0 + $1.length(tolerance: tol) }
            return piece.signedArea() > perimeter * tol / 2
        }
        let result = FilledPath(contours: kept.flatMap(\.contours), fillRule: .nonZero)
        if abs(distance) > tol && !result.isEmpty {
            let perimeter = region.contours.reduce(0) { $0 + $1.length(tolerance: tol) }
            let change = abs(result.signedArea() - region.signedArea())
            if change < 0.01 * abs(distance) * perimeter {
                throw .unchanged
            }
        }
        return result
    }

    /// The paths of a multi-step inset: step `k` of `steps` (1-based, in order) inset by
    /// `spacing.distance(step: k, of: steps, total: distance)`.  A collapsed step is an empty
    /// path, so the array always has `steps` elements (none for `steps < 1`); the command skips
    /// the empty ones.
    public static func insetSteps(
        _ path: FilledPath, distance: Double, steps: Int, spacing: InsetSpacing = .uniform,
        join: LineJoin = .miter, miterLimit: Double = 4, tolerance: Double = defaultTolerance
    ) -> [FilledPath] {
        guard steps > 0 else {
            return []
        }
        return (1...steps).map { k in
            inset(path, by: spacing.distance(step: k, of: steps, total: distance), join: join, miterLimit: miterLimit, tolerance: tolerance)
        }
    }
}
