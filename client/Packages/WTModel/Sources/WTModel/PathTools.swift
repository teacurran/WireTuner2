import WTCRDT
import WTGeometry
import WTProto

/// The Pencil's fitting (DRAW-016, freeform.adoc "Client"): freehand runs of samples fitted with
/// GEO-004 at a precision (tolerance `12 / precision` pt divided by the zoom), and kbd:[Option]
/// spans kept straight between corner points.
public enum StrokeFit {
    /// One run of a stroke.
    public enum Span: Hashable, Sendable {
        /// Pointer samples, pasteboard space.
        case freehand([Point])
        /// A straight segment (kbd:[Option] held), start to end.
        case straight(Point, Point)
    }

    /// The points of the stroke, in drawing order: curve points along fitted runs (corner points
    /// where the fit found a corner, at the ends of straight spans and at the stroke's ends).
    /// Consecutive spans share their meeting point.  Fewer than two distinct points give none.
    public static func points(_ spans: [Span], precision: PrecisionSetting, zoom: Double = 1) -> [VectorPoint] {
        var points: [VectorPoint] = []
        func append(_ run: [VectorPoint]) {
            guard var first = run.first else { return }
            if let last = points.last, last.anchor.distance(to: first.anchor) < 1e-9 {
                first.inHandle = last.inHandle
                first.kind = .corner
                points[points.count - 1] = first
                points += run.dropFirst()
            } else {
                points += run
            }
        }
        for span in spans {
            switch span {
            case .straight(let start, let end):
                guard start.distance(to: end) > 1e-9 else { continue }
                append([VectorPoint(anchor: start), VectorPoint(anchor: end)])
            case .freehand(let samples):
                append(fitted(precision.fit(stroke: samples, zoom: zoom)))
            }
        }
        guard points.count >= 2 else { return [] }
        points[0].kind = .corner
        points[points.count - 1].kind = .corner
        return points
    }

    /// The points of a fitted contour: one per segment end, handles from the cubic controls; a
    /// junction whose handles are not collinear is a corner.
    static func fitted(_ contour: Contour) -> [VectorPoint] {
        guard let first = contour.segments.first else { return [] }
        var points = [VectorPoint(anchor: first.p0, outHandle: first.p1 - first.p0, kind: .corner)]
        for (index, segment) in contour.segments.enumerated() {
            var point = VectorPoint(anchor: segment.p3, inHandle: segment.p2 - segment.p3, kind: .corner)
            if index + 1 < contour.segments.count {
                let next = contour.segments[index + 1]
                point.outHandle = next.p1 - next.p0
                point.kind = smooth(point.inHandle, point.outHandle) ? .curve : .corner
            }
            points.append(point)
        }
        return points
    }

    /// Whether two handles leave the anchor in opposite directions (within about a degree).
    static func smooth(_ inHandle: Vector, _ outHandle: Vector) -> Bool {
        guard inHandle.lengthSquared > 0, outHandle.lengthSquared > 0 else { return false }
        return inHandle.normalized.dot(outHandle.normalized) < -0.9998
    }
}

/// Continues an open path from one end (DRAW-016's continuation, DRAW-023's Pen continuation):
/// `points` (drawing order, local space) start at the end point being extended; the first is that
/// point itself, whose leaving handle is taken from it to smooth the join, and the rest are
/// inserted after the end (or before the start, reversed).  Concurrent edits to other points are
/// untouched; a concurrently deleted end point leaves the new points after its tombstone.
public struct ContinuePath: Command {
    public var node: OpID
    public var contour: OpID
    public var end: ContourEnd
    public var points: [VectorPoint]
    public var label: String

    public init(node: OpID, contour: OpID, end: ContourEnd, points: [VectorPoint], label: String = "Pencil") {
        self.node = node
        self.contour = contour
        self.end = end
        self.points = points
        self.label = label
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let (_, path) = try PathEditing.path(node, in: state)
        let contour = try PathEditing.contour(self.contour, of: path)
        guard !contour.closed, let ends = contour.ends, points.count >= 2 else { throw PathEditError.invalidValue("continuation") }
        let joined = end == .end ? ends.last : ends.first
        let added = Array(points.dropFirst())
        if end == .end {
            try PathEditing.insert(added, into: contour, of: node, at: .after(joined.id), state: state, builder: &builder)
            if let op = PathEditing.setHandles(node, contour, joined.id, in: nil, out: points[0].outHandle) { builder.append(op) }
        } else {
            let reversed = added.reversed().map(\.swapped)
            try PathEditing.insert(reversed, into: contour, of: node, at: .before(joined.id), state: state, builder: &builder)
            if let op = PathEditing.setHandles(node, contour, joined.id, in: points[0].outHandle, out: nil) { builder.append(op) }
        }
    }
}

/// menu:Extensions[Distort > Add Points] (DRAW-026): a point in the middle of every segment of the
/// paths, splitting each curve by de Casteljau so the outline does not change; the points around
/// each split get the split's handles (and stop being automatic).  One change.
public struct AddPoints: Command {
    public var nodes: [OpID]
    public var label: String { "Add Points" }

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in Objects.editable(nodes, in: state) where state.nodeKind(node) == .path {
            let (_, path) = try PathEditing.path(node, in: state)
            for contour in path.contours where contour.isRenderable {
                var handles: [OpID: (in: Vector?, out: Vector?)] = [:]
                let automatic = Set(contour.points.filter(\.automatic).map(\.id))
                for segment in contour.segments {
                    if segment.isStraight {
                        let middle = VectorPoint(anchor: Point.lerp(segment.from.anchor, segment.to.anchor, 0.5))
                        builder.append(try PathEditing.insert([middle], into: contour, of: node, at: .after(segment.from.id), state: state))
                        continue
                    }
                    let (left, right) = segment.cubic.split(at: 0.5)
                    let middle = VectorPoint(anchor: left.p3, inHandle: left.p2 - left.p3, outHandle: right.p1 - left.p3, kind: .curve)
                    builder.append(try PathEditing.insert([middle], into: contour, of: node, at: .after(segment.from.id), state: state))
                    handles[segment.from.id, default: (nil, nil)].out = left.p1 - left.p0
                    handles[segment.to.id, default: (nil, nil)].in = right.p2 - right.p3
                }
                for point in contour.drawn where handles[point.id] != nil {
                    let pair = handles[point.id]!
                    if let op = PathEditing.setHandles(node, contour, point.id, in: pair.in, out: pair.out) { builder.append(op) }
                    if automatic.contains(point.id) {
                        builder.append(Ops.set(node, [PathFields.automatic(contour.id, point.id)], values: PathEditing.pointValues(Wiretuner_Doc_V1_PathPoint())))
                    }
                }
            }
        }
    }
}
