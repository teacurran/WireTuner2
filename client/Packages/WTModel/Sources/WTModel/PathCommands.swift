import WTCRDT
import WTGeometry
import WTProto
import WTRender

// The path commands of DRAW-002 (docs/_includes/drawing/vector-basics.adoc, "Merge semantics").
// Each builds one change against the merged state; `Document.perform` numbers it, applies it and
// records its inverse.  Points are given and named in drawing order and orientation (the order
// after `reversed` and `start`); the commands translate to stored order.

/// A contour to create: its points in drawing order.
public struct NewContour: Hashable, Sendable {
    public var closed: Bool
    public var points: [VectorPoint]

    public init(closed: Bool = false, points: [VectorPoint]) {
        self.closed = closed
        self.points = points
    }
}

/// Creates a path node on top of the drawing layer (a "Foreground" layer is created in the same
/// change when the document has none), with its contours, points and attribute stack.
public struct CreatePath: Command {
    public var label: String
    public var contours: [NewContour]
    public var appearance: Wiretuner_Doc_V1_AppearanceProps
    public var transform: AffineTransform
    public var evenOdd: Bool
    public var fillWhenOpen: Bool
    public var name: String

    public init(label: String = "Path", contours: [NewContour], appearance: Wiretuner_Doc_V1_AppearanceProps = Appearances.standard,
                transform: AffineTransform = .identity, evenOdd: Bool = false, fillWhenOpen: Bool = false, name: String = "") {
        self.label = label
        self.contours = contours
        self.appearance = appearance
        self.transform = transform
        self.evenOdd = evenOdd
        self.fillWhenOpen = fillWhenOpen
        self.name = name
    }

    /// A line: one open contour of two corner points (rectangles-ellipses-lines.adoc).
    public static func line(from start: Point, to end: Point, appearance: Wiretuner_Doc_V1_AppearanceProps = Appearances.standard) -> CreatePath {
        CreatePath(label: "Line", contours: [NewContour(points: [VectorPoint(anchor: start), VectorPoint(anchor: end)])], appearance: appearance)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for contour in contours where contour.points.count > VectorContour.maximumPoints {
            throw PathEditError.contourFull(.zero)
        }
        let layer = try PathEditing.ensureLayer(&builder, state: state)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.path.common.name = name
        if !transform.isIdentity { props.path.common.transform = PathEditing.proto(transform) }
        props.path.evenOdd = evenOdd
        props.path.fillWhenOpen = fillWhenOpen
        let position = try PathEditing.topPosition(in: layer, state: state)
        let node = builder.append(Ops.create(parent: layer, position: position, props: props))
        try Self.appendContours(contours, to: node, builder: &builder)
        for op in try PathEditing.appearanceInserts(node, kind: .path, appearancePath: PathFields.appearance, appearance) {
            builder.append(op)
        }
    }

    /// Inserts `contours` (after any existing ones) into the path `node`.
    static func appendContours(_ contours: [NewContour], to node: OpID, after last: [UInt8]? = nil, builder: inout ChangeBuilder) throws {
        guard !contours.isEmpty else { return }
        let keys = try PathEditing.keys(between: last, and: nil, count: contours.count)
        var values = Wiretuner_Doc_V1_PathProps()
        values.contours = contours.map { contour in
            var value = Wiretuner_Doc_V1_Contour()
            value.closed = contour.closed
            return value
        }
        var props = Wiretuner_Doc_V1_NodeProps()
        props.path = values
        let first = builder.append(Ops.elementInsert(node, PathFields.contours, positions: keys, values: props))
        for (index, contour) in contours.enumerated() where !contour.points.isEmpty {
            let id = OpID(counter: first.counter + UInt64(index), replica: first.replica)
            var value = Wiretuner_Doc_V1_Contour()
            value.points = contour.points.map { PathEditing.stored($0, reversed: false) }
            let pointKeys = try PathEditing.keys(between: nil, and: nil, count: contour.points.count)
            builder.append(Ops.elementInsert(node, PathFields.points(id), positions: pointKeys, values: PathEditing.contourValues(value)))
        }
    }
}

/// Moves anchors (one register each; the handles, being offsets, follow).
public struct MovePoints: Command {
    public struct Move: Hashable, Sendable {
        public var contour: OpID
        public var point: OpID
        public var anchor: Point

        public init(contour: OpID, point: OpID, anchor: Point) {
            self.contour = contour
            self.point = point
            self.anchor = anchor
        }
    }

    public var node: OpID
    public var moves: [Move]
    public var label: String { moves.count == 1 ? "Move Point" : "Move Points" }

    public init(node: OpID, moves: [Move]) {
        self.node = node
        self.moves = moves
    }

    public init(node: OpID, contour: OpID, point: OpID, to anchor: Point) {
        self.init(node: node, moves: [Move(contour: contour, point: point, anchor: anchor)])
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let (_, path) = try PathEditing.path(node, in: state)
        for move in moves {
            let contour = try PathEditing.contour(move.contour, of: path)
            _ = try PathEditing.point(move.point, of: contour)
            guard move.anchor.isFinite else { throw PathEditError.invalidValue("anchor") }
            var value = Wiretuner_Doc_V1_PathPoint()
            value.anchor = PathEditing.proto(move.anchor)
            builder.append(Ops.set(node, [PathFields.anchor(move.contour, move.point)], values: PathEditing.pointValues(value)))
        }
    }
}

/// Sets a point's handles, in drawing orientation.  With `linked`, dragging one handle of a curve
/// point moves the other in tandem (collinear, keeping its length; mirrored when retracted), and
/// the curved-side handle of a connector is constrained to the straight segment's direction.  An
/// automatic point dragged by hand becomes an ordinary point.
public struct SetHandles: Command {
    public var node: OpID
    public var contour: OpID
    public var point: OpID
    public var inHandle: Vector?
    public var outHandle: Vector?
    public var linked: Bool
    public var label: String { "Move Handle" }

    public init(node: OpID, contour: OpID, point: OpID, in inHandle: Vector? = nil, out outHandle: Vector? = nil, linked: Bool = true) {
        self.node = node
        self.contour = contour
        self.point = point
        self.inHandle = inHandle
        self.outHandle = outHandle
        self.linked = linked
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let (_, path) = try PathEditing.path(node, in: state)
        let contour = try PathEditing.contour(self.contour, of: path)
        _ = try PathEditing.point(point, of: contour)
        let drawn = contour.drawn
        let index = drawn.firstIndex { $0.id == point }!
        let current = drawn[index]
        for handle in [inHandle, outHandle].compactMap({ $0 }) where !handle.isFinite {
            throw PathEditError.invalidValue("handle")
        }
        var (newIn, newOut) = (inHandle, outHandle)
        if linked {
            switch current.kind {
            case .curve:
                if let given = newOut, newIn == nil {
                    newIn = Self.opposite(given, length: current.inHandle == .zero ? given.length : current.inHandle.length)
                } else if let given = newIn, newOut == nil {
                    newOut = Self.opposite(given, length: current.outHandle == .zero ? given.length : current.outHandle.length)
                }
            case .connector:
                (newIn, newOut) = Self.constrained(drawn, index, closed: contour.closed, in: newIn, out: newOut)
            case .corner:
                break
            }
        }
        if let op = PathEditing.setHandles(node, contour, point, in: newIn, out: newOut) {
            builder.append(op)
        }
        if current.automatic {
            builder.append(Ops.set(node, [PathFields.automatic(contour.id, point)], values: PathEditing.pointValues(Wiretuner_Doc_V1_PathPoint())))
        }
    }

    /// A handle pointing opposite `handle` with `length`.
    static func opposite(_ handle: Vector, length: Double) -> Vector {
        guard handle.lengthSquared > 0 else { return .zero }
        return -(handle.normalized * length)
    }

    /// A connector's handles: the one on the straight side stays retracted, the other is
    /// projected onto the straight segment's direction (continuing it through the anchor).
    static func constrained(_ drawn: [VectorPoint], _ index: Int, closed: Bool, in inHandle: Vector?, out outHandle: Vector?) -> (Vector?, Vector?) {
        let count = drawn.count
        let anchor = drawn[index].anchor
        let previous = closed || index > 0 ? drawn[(index - 1 + count) % count] : nil
        let next = closed || index < count - 1 ? drawn[(index + 1) % count] : nil
        // The straight side: the side whose neighbour's facing handle is retracted.
        if let previous, previous.outHandle == .zero, drawn[index].inHandle == .zero {
            let direction = (anchor - previous.anchor).normalized
            return (inHandle.map { _ in .zero }, outHandle.map { direction * max(0, $0.dot(direction)) })
        }
        if let next, next.inHandle == .zero, drawn[index].outHandle == .zero {
            let direction = (anchor - next.anchor).normalized
            return (inHandle.map { direction * max(0, $0.dot(direction)) }, outHandle.map { _ in .zero })
        }
        return (inHandle, outHandle)
    }
}

/// Sets points' type.  Making a point a curve point rewrites its handles collinear (the leaving
/// handle's direction wins, each keeping its length), which also relinks handles a merge left
/// unlinked.
public struct SetPointKind: Command {
    public var node: OpID
    public var points: [(contour: OpID, point: OpID)]
    public var kind: PointKind
    public var label: String { "Set Point Type" }

    public init(node: OpID, points: [(contour: OpID, point: OpID)], kind: PointKind) {
        self.node = node
        self.points = points
        self.kind = kind
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let (_, path) = try PathEditing.path(node, in: state)
        for (contourID, pointID) in points {
            let contour = try PathEditing.contour(contourID, of: path)
            _ = try PathEditing.point(pointID, of: contour)
            let current = contour.drawn.first { $0.id == pointID }!
            var value = Wiretuner_Doc_V1_PathPoint()
            value.kind = kind.proto
            builder.append(Ops.set(node, [PathFields.pointKind(contourID, pointID)], values: PathEditing.pointValues(value)))
            var asCurve = current
            asCurve.kind = .curve
            if kind == .curve, asCurve.handlesUnlinked || (current.inHandle == .zero) != (current.outHandle == .zero) {
                let direction = current.outHandle != .zero ? current.outHandle : -current.inHandle
                let inLength = current.inHandle == .zero ? direction.length : current.inHandle.length
                let outLength = current.outHandle == .zero ? direction.length : current.outHandle.length
                let unit = direction.normalized
                if let op = PathEditing.setHandles(node, contour, pointID, in: -(unit * inLength), out: unit * outLength) {
                    builder.append(op)
                }
            }
        }
    }
}

/// Retracts both handles of points (the point editor's *Retract handles*).
public struct RetractHandles: Command {
    public var node: OpID
    public var points: [(contour: OpID, point: OpID)]
    public var label: String { "Retract Handles" }

    public init(node: OpID, points: [(contour: OpID, point: OpID)]) {
        self.node = node
        self.points = points
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let (_, path) = try PathEditing.path(node, in: state)
        for (contourID, pointID) in points {
            let contour = try PathEditing.contour(contourID, of: path)
            _ = try PathEditing.point(pointID, of: contour)
            builder.append(PathEditing.setHandles(node, contour, pointID, in: .zero, out: .zero)!)
        }
    }
}

/// Sets points' *Automatic* flag.  Turning it off stores the handles it computed, so the curve
/// does not jump.
public struct SetAutomatic: Command {
    public var node: OpID
    public var points: [(contour: OpID, point: OpID)]
    public var automatic: Bool
    public var label: String { "Automatic" }

    public init(node: OpID, points: [(contour: OpID, point: OpID)], automatic: Bool) {
        self.node = node
        self.points = points
        self.automatic = automatic
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let (_, path) = try PathEditing.path(node, in: state)
        for (contourID, pointID) in points {
            let contour = try PathEditing.contour(contourID, of: path)
            _ = try PathEditing.point(pointID, of: contour)
            var value = Wiretuner_Doc_V1_PathPoint()
            value.automatic = automatic
            builder.append(Ops.set(node, [PathFields.automatic(contourID, pointID)], values: PathEditing.pointValues(value)))
            if !automatic, let drawn = contour.drawn.first(where: { $0.id == pointID }) {
                builder.append(PathEditing.setHandles(node, contour, pointID, in: drawn.inHandle, out: drawn.outHandle)!)
            }
        }
    }
}

/// Inserts points (drawing order and orientation) into a contour at a placement: the Pen's
/// placed point, Add Points.  Refused when the contour would exceed 32,000 live points.
public struct InsertPoints: Command {
    public var node: OpID
    public var contour: OpID
    public var placement: PointPlacement
    public var points: [VectorPoint]
    public var label: String

    public init(node: OpID, contour: OpID, at placement: PointPlacement, points: [VectorPoint], label: String = "Add Point") {
        self.node = node
        self.contour = contour
        self.placement = placement
        self.points = points
        self.label = label
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let (_, path) = try PathEditing.path(node, in: state)
        let contour = try PathEditing.contour(self.contour, of: path)
        guard !points.isEmpty else { return }
        try PathEditing.insert(points, into: contour, of: node, at: placement, state: state, builder: &builder)
    }
}

/// Inserts a point on a segment at parameter `t`, splitting the curve without changing its shape
/// (de Casteljau): the new point plus the two neighbours' facing handles, in one change.
public struct InsertPointOnSegment: Command {
    public var node: OpID
    public var contour: OpID
    /// The drawn point the segment starts at.
    public var from: OpID
    public var t: Double
    public var label: String { "Add Point" }

    public init(node: OpID, contour: OpID, from: OpID, t: Double) {
        self.node = node
        self.contour = contour
        self.from = from
        self.t = t
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let (_, path) = try PathEditing.path(node, in: state)
        let contour = try PathEditing.contour(self.contour, of: path)
        guard let segment = contour.segments.first(where: { $0.from.id == from }) else { throw PathEditError.unknownPoint(from) }
        guard t > 0, t < 1 else { throw PathEditError.invalidValue("t") }
        if segment.isStraight {
            let point = VectorPoint(anchor: Point.lerp(segment.from.anchor, segment.to.anchor, t))
            builder.append(try PathEditing.insert([point], into: contour, of: node, at: .after(from), state: state))
            return
        }
        let (left, right) = segment.cubic.split(at: t)
        let placed = VectorPoint(anchor: left.p3, inHandle: left.p2 - left.p3, outHandle: right.p1 - left.p3, kind: .curve)
        builder.append(try PathEditing.insert([placed], into: contour, of: node, at: .after(from), state: state))
        builder.append(PathEditing.setHandles(node, contour, segment.from.id, in: nil, out: left.p1 - left.p0)!)
        builder.append(PathEditing.setHandles(node, contour, segment.to.id, in: right.p2 - right.p3, out: nil)!)
    }
}

/// Deletes points; the path heals across the gap.  A contour left with fewer than two points
/// stops rendering (read normalization); nothing else is rewritten.
public struct DeletePoints: Command {
    public var node: OpID
    public var points: [(contour: OpID, point: OpID)]
    public var label: String { points.count == 1 ? "Delete Point" : "Delete Points" }

    public init(node: OpID, points: [(contour: OpID, point: OpID)]) {
        self.node = node
        self.points = points
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let (_, path) = try PathEditing.path(node, in: state)
        var byContour: [OpID: [RegisterPath]] = [:]
        var order: [OpID] = []
        for (contourID, pointID) in points {
            let contour = try PathEditing.contour(contourID, of: path)
            _ = try PathEditing.point(pointID, of: contour)
            if byContour[contourID] == nil { order.append(contourID) }
            byContour[contourID, default: []].append(PathFields.point(contourID, pointID))
        }
        for contourID in order {
            builder.append(Ops.elementDelete(node, byContour[contourID]!))
        }
    }
}

/// Deletes the segment starting at drawn point `from`: a closed contour opens there (`closed =
/// false`, `start` = the point after the segment); on an open contour an end segment removes its
/// end point and a middle segment splits the contour in two (the points after it move to a new
/// contour of the same path as copies).
public struct DeleteSegment: Command {
    public var node: OpID
    public var contour: OpID
    public var from: OpID
    public var label: String { "Delete VectorSegment" }

    public init(node: OpID, contour: OpID, from: OpID) {
        self.node = node
        self.contour = contour
        self.from = from
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let (_, path) = try PathEditing.path(node, in: state)
        let contour = try PathEditing.contour(self.contour, of: path)
        let drawn = contour.drawn
        guard let index = drawn.firstIndex(where: { $0.id == from }), contour.closed || index < drawn.count - 1 else {
            throw PathEditError.unknownPoint(from)
        }
        if contour.closed {
            var value = Wiretuner_Doc_V1_Contour()
            value.closed = false
            value.start = drawn[(index + 1) % drawn.count].id.elementID
            builder.append(Ops.set(node, [PathFields.closed(contour.id), PathFields.start(contour.id)], values: PathEditing.contourValues(value)))
        } else if index == 0 {
            builder.append(Ops.elementDelete(node, [PathFields.point(contour.id, drawn[0].id)]))
        } else if index == drawn.count - 2 {
            builder.append(Ops.elementDelete(node, [PathFields.point(contour.id, drawn[drawn.count - 1].id)]))
        } else {
            let moved = Array(drawn[(index + 1)...])
            builder.append(Ops.elementDelete(node, moved.map { PathFields.point(contour.id, $0.id) }))
            let last = state.store.elementOrder(node, PathFields.contours).last.flatMap { state.position(node, PathFields.contours, $0) }
            try CreatePath.appendContours([NewContour(points: moved)], to: node, after: last, builder: &builder)
        }
    }
}

/// Sets *Closed* on contours (all when `contours` is nil).  Opening leaves `start` alone.
public struct SetClosed: Command {
    public var node: OpID
    public var closed: Bool
    public var contours: [OpID]?
    public var label: String { closed ? "Close Path" : "Open Path" }

    public init(node: OpID, closed: Bool, contours: [OpID]? = nil) {
        self.node = node
        self.closed = closed
        self.contours = contours
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let (_, path) = try PathEditing.path(node, in: state)
        let ids = try contours.map { try $0.map { try PathEditing.contour($0, of: path).id } } ?? path.contours.map(\.id)
        var value = Wiretuner_Doc_V1_Contour()
        value.closed = closed
        for id in ids {
            builder.append(Ops.set(node, [PathFields.closed(id)], values: PathEditing.contourValues(value)))
        }
    }
}

/// Reverses contours' direction (all when `contours` is nil): one write of `reversed` each; the
/// stored order never changes.
public struct ReverseContours: Command {
    public var node: OpID
    public var contours: [OpID]?
    public var label: String { "Reverse Direction" }

    public init(node: OpID, contours: [OpID]? = nil) {
        self.node = node
        self.contours = contours
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let (_, path) = try PathEditing.path(node, in: state)
        let selected = try contours.map { try $0.map { try PathEditing.contour($0, of: path) } } ?? path.contours
        for contour in selected {
            var value = Wiretuner_Doc_V1_Contour()
            value.reversed = !contour.reversed
            builder.append(Ops.set(node, [PathFields.reversed(contour.id)], values: PathEditing.contourValues(value)))
        }
    }
}

/// Joins two open contours of different paths end to end: copies of the source contour's points
/// (new element ids, mapped into the target's space and read in the direction that puts the
/// joined end next to the target's) are inserted at the target's end, and the source node is
/// deleted.  The one path operation that cannot preserve a concurrent edit of the absorbed path.
public struct JoinPaths: Command {
    public var target: OpID
    public var targetContour: OpID
    public var targetEnd: ContourEnd
    public var source: OpID
    public var sourceContour: OpID
    public var sourceEnd: ContourEnd
    public var label: String { "Join" }

    public init(target: OpID, targetContour: OpID, targetEnd: ContourEnd, source: OpID, sourceContour: OpID, sourceEnd: ContourEnd) {
        self.target = target
        self.targetContour = targetContour
        self.targetEnd = targetEnd
        self.source = source
        self.sourceContour = sourceContour
        self.sourceEnd = sourceEnd
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard source != target else { throw PathEditError.invalidValue("join a path to itself") }
        let (targetProps, targetPath) = try PathEditing.path(target, in: state)
        let (sourceProps, sourcePath) = try PathEditing.path(source, in: state)
        let destination = try PathEditing.contour(targetContour, of: targetPath)
        let absorbed = try PathEditing.contour(sourceContour, of: sourcePath)
        guard !destination.closed, !absorbed.closed else { throw PathEditError.invalidValue("closed contour") }
        let toTarget = PathEditing.transform(sourceProps.common.transform)
            .concatenating(PathEditing.transform(targetProps.common.transform).inverted() ?? .identity)
        var points = absorbed.drawn.map { point -> VectorPoint in
            var mapped = point
            mapped.anchor = toTarget.apply(point.anchor)
            mapped.inHandle = toTarget.apply(point.inHandle)
            mapped.outHandle = toTarget.apply(point.outHandle)
            mapped.automatic = false
            return mapped
        }
        // Appending: the source's joined end must come first; prepending: last.
        let reverse = (targetEnd == .end) == (sourceEnd == .end)
        if reverse {
            points = points.reversed().map(\.swapped)
        }
        try PathEditing.insert(points, into: destination, of: target, at: targetEnd == .end ? .end : .start, state: state, builder: &builder)
        builder.append(Ops.setDeleted(source))
    }
}

/// Splits a path at a point.  A closed contour opens there (the point is duplicated so the path
/// still starts and ends on it).  An open contour keeps its points up to and including the split
/// point; copies of the point and the ones after it become a new path node above it with the same
/// attributes.
public struct SplitPath: Command {
    public var node: OpID
    public var contour: OpID
    public var point: OpID
    public var label: String { "Split" }

    public init(node: OpID, contour: OpID, point: OpID) {
        self.node = node
        self.contour = contour
        self.point = point
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let (props, path) = try PathEditing.path(node, in: state)
        let contour = try PathEditing.contour(self.contour, of: path)
        let drawn = contour.drawn
        guard let index = drawn.firstIndex(where: { $0.id == point }) else { throw PathEditError.unknownPoint(point) }
        if contour.closed {
            var value = Wiretuner_Doc_V1_Contour()
            value.closed = false
            value.start = point.elementID
            builder.append(Ops.set(node, [PathFields.closed(contour.id), PathFields.start(contour.id)], values: PathEditing.contourValues(value)))
            var copy = drawn[index]
            copy.outHandle = .zero
            copy.automatic = false
            builder.append(try PathEditing.insert([copy], into: contour, of: node, at: .before(point), state: state))
            return
        }
        guard index > 0, index < drawn.count - 1 else { return }
        let separated = Array(drawn[index...])
        builder.append(Ops.elementDelete(node, drawn[(index + 1)...].map { PathFields.point(contour.id, $0.id) }))
        guard let parent = state.store.placement(node)?.parent else { return }
        var created = Wiretuner_Doc_V1_NodeProps()
        created.path.common = props.common
        created.path.evenOdd = props.evenOdd
        created.path.flatness = props.flatness
        created.path.fillWhenOpen = props.fillWhenOpen
        let position = try PathEditing.topPosition(in: parent, state: state)
        let copy = builder.append(Ops.create(parent: parent, position: position, props: created))
        try CreatePath.appendContours([NewContour(points: separated)], to: copy, builder: &builder)
        for op in try PathEditing.appearanceInserts(copy, kind: .path, appearancePath: PathFields.appearance, props.appearance) {
            builder.append(op)
        }
    }
}

/// Sets *Even/odd fill*.
public struct SetEvenOdd: Command {
    public var node: OpID
    public var evenOdd: Bool
    public var label: String { "Even/Odd Fill" }

    public init(node: OpID, evenOdd: Bool) {
        self.node = node
        self.evenOdd = evenOdd
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try PathEditing.path(node, in: state)
        builder.append(Ops.set(node, [PathFields.evenOdd], values: PathEditing.values { $0.evenOdd = evenOdd }))
    }
}

/// Sets *Flatness* (0 = the device default; negative is refused).
public struct SetFlatness: Command {
    public var node: OpID
    public var flatness: Double
    public var label: String { "Flatness" }

    public init(node: OpID, flatness: Double) {
        self.node = node
        self.flatness = flatness
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try PathEditing.path(node, in: state)
        guard flatness >= 0, flatness.isFinite else { throw PathEditError.invalidValue("flatness") }
        builder.append(Ops.set(node, [PathFields.flatness], values: PathEditing.values { $0.flatness = flatness }))
    }
}
