import WTCRDT
import WTGeometry
import WTProto

/// A point's type (docs/_includes/drawing/vector-basics.adoc, "Point types").
public enum PointKind: Sendable, Hashable, CaseIterable {
    case corner
    case curve
    case connector

    /// The kind a stored `PointKind` reads as: unspecified is a corner.
    public init(_ kind: Wiretuner_Doc_V1_PointKind) {
        switch kind {
        case .curve: self = .curve
        case .connector: self = .connector
        default: self = .corner
        }
    }

    /// The stored value.
    public var proto: Wiretuner_Doc_V1_PointKind {
        switch self {
        case .corner: .corner
        case .curve: .curve
        case .connector: .connector
        }
    }
}

/// One anchor point with its two control handles as offsets from the anchor (vector-basics.adoc,
/// "Data model": a zero offset is a retracted handle).  `inHandle` shapes the segment arriving at
/// the point and `outHandle` the segment leaving it -- in stored order for a stored point, in
/// drawing order for a point of `VectorContour.drawn`.
public struct VectorPoint: Hashable, Sendable {
    /// The element id (synthetic for a shape's derived points).
    public var id: OpID
    public var anchor: Point
    public var inHandle: Vector
    public var outHandle: Vector
    public var kind: PointKind
    public var automatic: Bool

    public init(id: OpID = .zero, anchor: Point, inHandle: Vector = .zero, outHandle: Vector = .zero,
                kind: PointKind = .corner, automatic: Bool = false) {
        self.id = id
        self.anchor = anchor
        self.inHandle = inHandle
        self.outHandle = outHandle
        self.kind = kind
        self.automatic = automatic
    }

    /// A stored point: a NaN or infinite handle offset reads as retracted (read normalization).
    public init(_ point: Wiretuner_Doc_V1_PathPoint) {
        self.init(
            id: OpID(element: point.id) ?? .zero,
            anchor: Point(x: point.anchor.x, y: point.anchor.y),
            inHandle: Self.offset(point.inHandle), outHandle: Self.offset(point.outHandle),
            kind: PointKind(point.kind), automatic: point.automatic
        )
    }

    private static func offset(_ point: Wiretuner_Doc_V1_Point) -> Vector {
        let vector = Vector(dx: point.x, dy: point.y)
        return vector.isFinite ? vector : .zero
    }

    /// The absolute position of the arriving handle.
    public var inControl: Point { anchor + inHandle }
    /// The absolute position of the leaving handle.
    public var outControl: Point { anchor + outHandle }

    /// The point read the other way round: handles swapped.
    public var swapped: VectorPoint {
        var copy = self
        copy.inHandle = outHandle
        copy.outHandle = inHandle
        return copy
    }

    /// Whether the handles of a curve point are not collinear through the anchor (a merge of
    /// two concurrent handle drags; vector-basics.adoc, "Two handles of one curve point").
    public var handlesUnlinked: Bool {
        guard kind == .curve, inHandle != .zero, outHandle != .zero else { return false }
        let cross = inHandle.normalized.cross(outHandle.normalized)
        let dot = inHandle.normalized.dot(outHandle.normalized)
        return abs(cross) > 1e-6 || dot > 0
    }
}

/// One contour of a path as merged: its stored points (live only, stored order) and flags.
public struct VectorContour: Hashable, Sendable {
    /// The most points a contour takes inserts into (vector-basics.adoc, "Size limits").
    public static let maximumPoints = 32_000

    public var id: OpID
    public var closed: Bool
    public var reversed: Bool
    /// The `start` register after the dangling rule (the surviving point following a deleted
    /// start in stored order); nil when unset.
    public var start: OpID?
    /// The live points in stored order.
    public var points: [VectorPoint]

    public init(id: OpID = .zero, closed: Bool = false, reversed: Bool = false, start: OpID? = nil, points: [VectorPoint]) {
        self.id = id
        self.closed = closed
        self.reversed = reversed
        self.start = start
        self.points = points
    }

    /// Whether the contour renders and can be selected: at least two live points.
    public var isRenderable: Bool { points.count >= 2 }

    /// Whether inserts into the contour are refused (more than 32,000 live points).
    public var isFull: Bool { points.count >= Self.maximumPoints }

    /// The points in drawing order with every read-time normalization applied
    /// (vector-basics.adoc, "Read-time normalizations"): read backwards with in and out handles
    /// swapped when `reversed`; an open contour rotated to begin at `start`; automatic points'
    /// handles computed from their neighbours; a connector without exactly one straight side read
    /// as a corner.
    public var drawn: [VectorPoint] {
        var reading = reversed ? points.reversed().map(\.swapped) : points
        if !closed, let start, let index = reading.firstIndex(where: { $0.id == start }), index > 0 {
            reading = Array(reading[index...] + reading[..<index])
        }
        let automatic = reading.indices.map { Self.automaticHandles(reading, $0, closed: closed) }
        for index in reading.indices where reading[index].automatic {
            (reading[index].inHandle, reading[index].outHandle) = automatic[index]
        }
        for index in reading.indices where reading[index].kind == .connector && !Self.hasOneStraightSide(reading, index, closed: closed) {
            reading[index].kind = .corner
        }
        return reading
    }

    /// The index in `drawn` of the point `id`.
    public func drawnIndex(of id: OpID) -> Int? {
        drawn.firstIndex { $0.id == id }
    }

    /// The drawn points at either end of an open contour (first, last); nil when closed or empty.
    public var ends: (first: VectorPoint, last: VectorPoint)? {
        let points = drawn
        guard !closed, let first = points.first, let last = points.last else { return nil }
        return (first, last)
    }

    /// The segments in drawing order, the closing one last for a closed contour: each from one
    /// drawn point to the next.
    public var segments: [VectorSegment] {
        let points = drawn
        guard points.count >= 2 else { return [] }
        var result: [VectorSegment] = []
        for index in 0..<(points.count - 1) {
            result.append(VectorSegment(from: points[index], to: points[index + 1]))
        }
        if closed {
            result.append(VectorSegment(from: points[points.count - 1], to: points[0]))
        }
        return result
    }

    /// Catmull-Rom handles for point `index` of `points` (vector-basics.adoc: automatic handles are
    /// recomputed from the neighbours on read): a sixth of the chord between the neighbours, or a
    /// third of the one neighbour's direction at the end of an open contour.
    static func automaticHandles(_ points: [VectorPoint], _ index: Int, closed: Bool) -> (Vector, Vector) {
        let count = points.count
        guard count >= 2 else { return (.zero, .zero) }
        let hasPrevious = closed || index > 0
        let hasNext = closed || index < count - 1
        let anchor = points[index].anchor
        let previous = points[(index - 1 + count) % count].anchor
        let next = points[(index + 1) % count].anchor
        switch (hasPrevious, hasNext) {
        case (true, true):
            let tangent = (next - previous) / 6
            return (-tangent, tangent)
        case (false, _):
            return (.zero, (next - anchor) / 3)
        case (_, false):
            return ((previous - anchor) / 3, .zero)
        }
    }

    /// Whether exactly one of the two segments meeting at `index` is straight.
    static func hasOneStraightSide(_ points: [VectorPoint], _ index: Int, closed: Bool) -> Bool {
        let count = points.count
        let point = points[index]
        var sides: [Bool] = []
        if closed || index > 0 {
            sides.append(point.inHandle == .zero && points[(index - 1 + count) % count].outHandle == .zero)
        }
        if closed || index < count - 1 {
            sides.append(point.outHandle == .zero && points[(index + 1) % count].inHandle == .zero)
        }
        return sides.count == 2 && sides[0] != sides[1]
    }
}

/// One segment of a drawn contour.
public struct VectorSegment: Hashable, Sendable {
    public var from: VectorPoint
    public var to: VectorPoint

    /// Straight when both facing handles are retracted.
    public var isStraight: Bool { from.outHandle == .zero && to.inHandle == .zero }

    /// The cubic Bézier control points.
    public var cubic: CubicBezier {
        CubicBezier(from.anchor, from.outControl, to.inControl, to.anchor)
    }
}

/// A vector path as merged and normalized (vector-basics.adoc, "Data model"), in the node's local
/// space; `transform` places it on the pasteboard.  Rectangles and ellipses read as paths too
/// (`ShapeGeometry`).
public struct VectorPath: Hashable, Sendable {
    public var contours: [VectorContour]
    public var evenOdd: Bool
    public var flatness: Double
    public var fillWhenOpen: Bool

    public init(contours: [VectorContour], evenOdd: Bool = false, flatness: Double = 0, fillWhenOpen: Bool = false) {
        self.contours = contours
        self.evenOdd = evenOdd
        self.flatness = flatness
        self.fillWhenOpen = fillWhenOpen
    }

    /// The path `props` hold.  `state` and `node` resolve a dangling `start` (the surviving point
    /// following it in stored order); without them a dangling start reads as unset.
    public init(_ props: Wiretuner_Doc_V1_PathProps, node: OpID? = nil, state: EngineState? = nil) {
        let contours = props.contours.map { contour -> VectorContour in
            let id = OpID(element: contour.id) ?? .zero
            let points = contour.points.map(VectorPoint.init)
            var start = OpID(element: contour.start)
            if let wanted = start, !points.contains(where: { $0.id == wanted }) {
                start = Self.survivor(of: wanted, contour: id, points: points, node: node, state: state)
            }
            return VectorContour(id: id, closed: contour.closed, reversed: contour.reversed, start: start, points: points)
        }
        self.init(contours: contours, evenOdd: props.evenOdd, flatness: props.flatness, fillWhenOpen: props.fillWhenOpen)
    }

    /// The live point that follows `start` in stored order (cyclically), or nil.
    private static func survivor(of start: OpID, contour: OpID, points: [VectorPoint], node: OpID?, state: EngineState?) -> OpID? {
        guard let node, let state else { return nil }
        let sequence = PathFields.points(contour)
        let order = state.store.elementOrder(node, sequence)
        guard let index = order.firstIndex(of: start) else { return nil }
        let live = Set(points.map(\.id))
        for offset in 1..<max(order.count, 1) {
            let candidate = order[(index + offset) % order.count]
            if live.contains(candidate) { return candidate }
        }
        return nil
    }

    /// The contour `id`.
    public func contour(_ id: OpID) -> VectorContour? {
        contours.first { $0.id == id }
    }

    /// Every point, stored order, with its contour.
    public var allPoints: [(contour: OpID, point: VectorPoint)] {
        contours.flatMap { contour in contour.points.map { (contour.id, $0) } }
    }

    /// The number of live points (the Object panel's *Points*).
    public var pointCount: Int { contours.reduce(0) { $0 + $1.points.count } }

    /// Whether any contour renders.
    public var isRenderable: Bool { contours.contains(where: \.isRenderable) }

    /// The control-point bounds of the renderable contours, local space.
    public var controlBounds: Rect? {
        var bounds = Rect.null
        for contour in contours where contour.isRenderable {
            for point in contour.drawn {
                bounds.formUnion(point.anchor)
                bounds.formUnion(point.inControl)
                bounds.formUnion(point.outControl)
            }
        }
        return bounds.isNull ? nil : bounds
    }
}

/// Register paths of `PathProps` (kind `path` = 20).
public enum PathFields {
    public static let kind: UInt32 = 20
    public static let common = RegisterPath([kind, 1])
    public static let transform = RegisterPath([kind, 1, 4])
    public static let name = RegisterPath([kind, 1, 1])
    public static let contours = RegisterPath([kind, 2])
    public static let appearance = RegisterPath([kind, 3])
    public static let evenOdd = RegisterPath([kind, 4])
    public static let flatness = RegisterPath([kind, 5])
    public static let fillWhenOpen = RegisterPath([kind, 6])

    public static func contour(_ id: OpID) -> RegisterPath { contours.element(id) }
    public static func closed(_ contour: OpID) -> RegisterPath { self.contour(contour).child(2) }
    public static func points(_ contour: OpID) -> RegisterPath { self.contour(contour).child(3) }
    public static func reversed(_ contour: OpID) -> RegisterPath { self.contour(contour).child(4) }
    public static func start(_ contour: OpID) -> RegisterPath { self.contour(contour).child(5) }
    public static func point(_ contour: OpID, _ point: OpID) -> RegisterPath { points(contour).element(point) }
    public static func anchor(_ contour: OpID, _ point: OpID) -> RegisterPath { self.point(contour, point).child(2) }
    public static func inHandle(_ contour: OpID, _ point: OpID) -> RegisterPath { self.point(contour, point).child(3) }
    public static func outHandle(_ contour: OpID, _ point: OpID) -> RegisterPath { self.point(contour, point).child(4) }
    public static func pointKind(_ contour: OpID, _ point: OpID) -> RegisterPath { self.point(contour, point).child(5) }
    public static func automatic(_ contour: OpID, _ point: OpID) -> RegisterPath { self.point(contour, point).child(6) }
}
