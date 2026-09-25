import WTCRDT
import WTGeometry
import WTProto

// DRAW-030 and FX-031: menu:Modify[Alter Path > Simplify], menu:Modify[Alter Path > Correct
// Direction] (Reverse Direction is `ReverseContours`) and menu:Extensions[Distort > Fractalize]
// (Add Points is `AddPoints`).  Each is one change over every selected path; the rewrites keep the
// identity of what survives through `RewritePath.rewrite` (editing-paths.adoc, "Merge semantics";
// path-effects.adoc, "Kernels").

/// The kernels behind Simplify, Correct Direction and Fractalize, on contours in drawing order.
public enum PathAlterKernels {
    /// The fit tolerance, in points of the path's own space, that Simplify's *Amount* (0 ... 100)
    /// allows: `amount / 20`, so 100 lets the outline move by up to 5 points and 0 changes
    /// nothing.
    public static func simplifyTolerance(amount: Double) -> Double {
        guard amount.isFinite else { return 0 }
        return min(max(amount, 0), 100) / 20
    }

    /// The contour's drawn segments as cubic Béziers (a closed contour's closing segment
    /// included).
    static func cubics(_ contour: VectorContour) -> [CubicBezier] {
        contour.segments.map(\.cubic)
    }

    /// `contour` refitted within `tolerance` (WTGeometry's `Contour.simplified`), as new points in
    /// drawing order; nil when the refit keeps every segment (nothing to write).
    static func simplified(_ contour: VectorContour, tolerance: Double) -> [VectorPoint]? {
        let segments = cubics(contour)
        guard tolerance > 0, contour.isRenderable, !segments.isEmpty else { return nil }
        let result = Contour(segments: segments, closed: contour.closed).simplified(tolerance: tolerance)
        guard result.segments.count < segments.count else { return nil }
        return points(result.segments, closed: contour.closed)
    }

    /// Points in drawing order for a run of joined segments: a closed run's last segment returns
    /// to its first point, which is not repeated.
    static func points(_ segments: [CubicBezier], closed: Bool) -> [VectorPoint] {
        var points: [VectorPoint] = []
        for (index, segment) in segments.enumerated() {
            let inHandle = index > 0 ? segments[index - 1].p2 - segment.p0 : (closed ? segments[segments.count - 1].p2 - segment.p0 : .zero)
            points.append(VectorPoint(anchor: segment.p0, inHandle: inHandle, outHandle: segment.p1 - segment.p0))
        }
        if !closed, let last = segments.last {
            points.append(VectorPoint(anchor: last.p3, inHandle: last.p2 - last.p3))
        }
        for index in points.indices {
            points[index].kind = smooth(points[index]) ? .curve : .corner
        }
        return points
    }

    /// Whether both handles are out and point in opposite directions (a smooth point).
    static func smooth(_ point: VectorPoint) -> Bool {
        guard point.inHandle != .zero, point.outHandle != .zero else { return false }
        let a = point.inHandle.normalized
        let b = point.outHandle.normalized
        return abs(a.cross(b)) < 1e-6 && a.dot(b) < 0
    }

    /// A polygon through the contour's drawn outline, `steps` samples per segment.
    static func polygon(_ contour: VectorContour, steps: Int = 8) -> [Point] {
        var result: [Point] = []
        for cubic in cubics(contour) {
            for step in 0..<steps { result.append(cubic.evaluate(Double(step) / Double(steps))) }
        }
        if !contour.closed, let last = contour.drawn.last { result.append(last.anchor) }
        return result
    }

    /// Twice the signed area of `polygon` (shoelace): positive for one winding, negative for the
    /// other.
    static func signedArea(_ polygon: [Point]) -> Double {
        guard polygon.count > 2 else { return 0 }
        var sum = 0.0
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum
    }

    /// Whether `point` lies inside `polygon` (non-zero winding).
    static func contains(_ polygon: [Point], _ point: Point) -> Bool {
        var winding = 0
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let side = (b.x - a.x) * (point.y - a.y) - (point.x - a.x) * (b.y - a.y)
            if a.y <= point.y {
                if b.y > point.y, side > 0 { winding += 1 }
            } else if b.y <= point.y, side < 0 {
                winding -= 1
            }
        }
        return winding != 0
    }

    /// For each renderable contour of `path`, whether its `reversed` flag must flip so that
    /// nested contours alternate direction: a contour inside an even number of the others runs
    /// with positive signed area, one inside an odd number with negative (Correct Direction).
    /// Open contours are left alone.
    static func corrections(_ path: VectorPath) -> [OpID] {
        let closed = path.contours.filter { $0.isRenderable && $0.closed }
        let polygons = closed.map { polygon($0) }
        var flips: [OpID] = []
        for (index, contour) in closed.enumerated() {
            let probe = contour.drawn[0].anchor
            let depth = polygons.indices.filter { $0 != index && contains(polygons[$0], probe) }.count
            let area = signedArea(polygons[index])
            guard area != 0 else { continue }
            if (area > 0) != depth.isMultiple(of: 2) { flips.append(contour.id) }
        }
        return flips
    }

    /// Fractalize: every drawn segment replaced by four -- its first and last thirds kept as they
    /// were, the middle third raised into a spike of two straight segments whose apex stands off
    /// the segment's midpoint by `√3/6` of its chord, on the outward side (the side away from the
    /// enclosed area for a closed contour, the right-hand side of travel for an open one).  The
    /// contour's own points keep their ids; three new points go into each segment.
    static func fractalized(_ contour: VectorContour) -> [VectorPoint] {
        let drawn = contour.drawn
        guard drawn.count >= 2 else { return drawn }
        let outward: Double = contour.closed && signedArea(polygon(contour)) < 0 ? -1 : 1
        var result = drawn.map { point -> VectorPoint in
            var copy = point
            copy.automatic = false
            return copy
        }
        var inserted: [[VectorPoint]] = Array(repeating: [], count: drawn.count)
        for index in 0..<(contour.closed ? drawn.count : drawn.count - 1) {
            let next = (index + 1) % drawn.count
            let cubic = CubicBezier(drawn[index].anchor, drawn[index].outControl, drawn[next].inControl, drawn[next].anchor)
            let (first, rest) = cubic.split(at: 1.0 / 3.0)
            let (_, last) = rest.split(at: 0.5)
            let chord = cubic.p3 - cubic.p0
            let length = (chord.dx * chord.dx + chord.dy * chord.dy).squareRoot()
            let normal = length > 0 ? Vector(dx: chord.dy / length, dy: -chord.dx / length) * outward : .zero
            let apex = cubic.evaluate(0.5) + normal * (length * 3.0.squareRoot() / 6)
            result[index].outHandle = first.p1 - first.p0
            result[next].inHandle = last.p2 - last.p3
            inserted[index] = [
                VectorPoint(anchor: first.p3, inHandle: first.p2 - first.p3),
                VectorPoint(anchor: apex),
                VectorPoint(anchor: last.p0, outHandle: last.p1 - last.p0),
            ]
        }
        for index in result.indices {
            result[index].kind = smooth(result[index]) ? .curve : .corner
        }
        return result.indices.flatMap { [result[$0]] + inserted[$0] }
    }
}

/// menu:Modify[Alter Path > Simplify] on btn:[OK] (editing-paths.adoc, "Simplifying and cleaning
/// up"): each renderable contour of each selected path refitted within
/// `PathAlterKernels.simplifyTolerance(amount:)` and written as new points -- every old point
/// deleted, the refit inserted -- so a concurrent edit of an old point is *edit vs delete*.  A
/// contour the refit cannot shorten is left alone; at amount 0 nothing is written.  Labelled
/// "Simplify".
public struct SimplifyPaths: Command {
    public var nodes: [OpID]
    public var amount: Double

    public init(_ nodes: [OpID], amount: Double) {
        self.nodes = nodes
        self.amount = amount
    }

    public var label: String { "Simplify" }

    /// What btn:[Apply] previews: the selected paths as Simplify would leave them (paths it would
    /// not change as they are), by node, in each path's own space.
    public static func preview(_ nodes: [OpID], amount: Double, in state: EngineState) -> [OpID: VectorPath] {
        var result: [OpID: VectorPath] = [:]
        let tolerance = PathAlterKernels.simplifyTolerance(amount: amount)
        for node in Objects.editable(nodes, in: state) where state.nodeKind(node) == .path {
            var path = VectorPath(state.props(node).path, node: node, state: state)
            path.contours = path.contours.map { contour in
                guard let points = PathAlterKernels.simplified(contour, tolerance: tolerance) else { return contour }
                return VectorContour(id: contour.id, closed: contour.closed, points: points)
            }
            result[node] = path
        }
        return result
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let tolerance = PathAlterKernels.simplifyTolerance(amount: amount)
        guard tolerance > 0 else { return }
        for node in Objects.editable(nodes, in: state) where state.nodeKind(node) == .path {
            let (_, path) = try PathEditing.path(node, in: state)
            for contour in path.contours {
                guard let points = PathAlterKernels.simplified(contour, tolerance: tolerance) else { continue }
                try RewritePath.rewrite(contour, of: node, to: points, closed: contour.closed, state: state, builder: &builder)
            }
        }
    }
}

/// menu:Modify[Alter Path > Correct Direction] (also menu:Extensions[Cleanup]): each selected
/// path's closed contours set to alternate direction by nesting -- one write of `reversed` per
/// contour that must turn, nothing else -- so overlaps of opposite-running contours are hollow.
/// Labelled "Correct Direction".
public struct CorrectDirection: Command {
    public var nodes: [OpID]

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public var label: String { "Correct Direction" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in Objects.editable(nodes, in: state) where state.nodeKind(node) == .path {
            let (_, path) = try PathEditing.path(node, in: state)
            let flips = Set(PathAlterKernels.corrections(path))
            for contour in path.contours where flips.contains(contour.id) {
                var value = Wiretuner_Doc_V1_Contour()
                value.reversed = !contour.reversed
                builder.append(Ops.set(node, [PathFields.reversed(contour.id)], values: PathEditing.contourValues(value)))
            }
        }
    }
}

/// menu:Extensions[Distort > Fractalize] (path-effects.adoc, "Fractalize"): every segment of each
/// selected path replaced by a four-segment spike (`PathAlterKernels.fractalized`).  The path's
/// existing points stay (their handles are shortened to the kept thirds), so a concurrent drag of
/// one of them survives.  Labelled "Fractalize".
public struct Fractalize: Command {
    public var nodes: [OpID]

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public var label: String { "Fractalize" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in Objects.editable(nodes, in: state) where state.nodeKind(node) == .path {
            let (_, path) = try PathEditing.path(node, in: state)
            for contour in path.contours where contour.isRenderable {
                try RewritePath.rewrite(contour, of: node, to: PathAlterKernels.fractalized(contour), closed: contour.closed, state: state, builder: &builder)
            }
        }
    }
}
