import WTCRDT
import WTGeometry
import WTProto

/// Rewrites a path wholesale while keeping the identity of what survives (editing-paths.adoc,
/// "Merge semantics"; DRAW-018, DRAW-027, DRAW-028): each edited contour gets a new point list in
/// drawing order in which a point carrying the id of one of its live points *is* that point --
/// only the registers that differ are written, so a concurrent edit of another register of it
/// survives -- and a point with any other id is inserted in its place; points left out are
/// deleted.  Contours can be removed or added, and further pieces become new path nodes just above
/// the path, with its attributes (the Knife's and Split's pieces that do not keep the original).
/// A point list whose surviving points are out of their stored order is written as all new points.
public struct RewritePath: Command {
    /// One existing contour's new points (drawing order and orientation) and closedness.
    public struct ContourEdit: Hashable, Sendable {
        public var contour: OpID
        public var points: [VectorPoint]
        public var closed: Bool

        public init(contour: OpID, points: [VectorPoint], closed: Bool) {
            self.contour = contour
            self.points = points
            self.closed = closed
        }
    }

    public var node: OpID
    public var edits: [ContourEdit]
    /// Contours deleted from the path.
    public var removed: [OpID]
    /// Contours added to the path (new points).
    public var added: [NewContour]
    /// New path nodes, each with these contours in the path's own space.
    public var pieces: [[NewContour]]
    public var label: String

    public init(node: OpID, edits: [ContourEdit] = [], removed: [OpID] = [], added: [NewContour] = [], pieces: [[NewContour]] = [], label: String) {
        self.node = node
        self.edits = edits
        self.removed = removed
        self.added = added
        self.pieces = pieces
        self.label = label
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let (props, path) = try PathEditing.path(node, in: state)
        for edit in edits {
            let contour = try PathEditing.contour(edit.contour, of: path)
            try Self.rewrite(contour, of: node, to: edit.points, closed: edit.closed, state: state, builder: &builder)
        }
        for id in removed {
            let contour = try PathEditing.contour(id, of: path)
            builder.append(Ops.elementDelete(node, [PathFields.contour(contour.id)]))
        }
        if !added.isEmpty {
            let last = state.store.elementOrder(node, PathFields.contours).last.flatMap { state.position(node, PathFields.contours, $0) }
            try CreatePath.appendContours(added, to: node, after: last, builder: &builder)
        }
        guard !pieces.isEmpty, let parent = state.store.placement(node)?.parent else { return }
        let siblings = state.store.children(parent)
        let above = siblings.firstIndex(of: node).flatMap { $0 + 1 < siblings.count ? siblings[$0 + 1] : nil }
        let keys = try PathEditing.keys(between: state.store.placement(node)?.position, and: above.flatMap { state.store.placement($0)?.position },
                                        count: pieces.count)
        for (piece, key) in zip(pieces, keys) {
            var created = Wiretuner_Doc_V1_NodeProps()
            created.path.common = props.common
            created.path.evenOdd = props.evenOdd
            created.path.flatness = props.flatness
            created.path.fillWhenOpen = props.fillWhenOpen
            let copy = builder.append(Ops.create(parent: parent, position: key, props: created))
            try CreatePath.appendContours(piece, to: copy, builder: &builder)
            for op in try PathEditing.appearanceInserts(copy, kind: .path, appearancePath: PathFields.appearance, props.appearance) {
                builder.append(op)
            }
        }
    }

    /// Whether the surviving points of `points` read in `drawn`'s order (cyclically for a closed
    /// contour).
    static func keepsOrder(_ points: [VectorPoint], drawn: [VectorPoint], closed: Bool) -> Bool {
        let index = Dictionary(drawn.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let order = points.compactMap { index[$0.id] }
        guard order.count > 1 else { return true }
        let descents = zip(order, order.dropFirst()).filter { $0 >= $1 }.count
        if !closed { return descents == 0 }
        // Cyclic: one wrap at most, and the last does not pass the first again.
        return descents == 0 || (descents == 1 && order.last! < order.first!)
    }

    static func rewrite(_ contour: VectorContour, of node: OpID, to points: [VectorPoint], closed: Bool, state: EngineState, builder: inout ChangeBuilder) throws {
        guard points.count <= VectorContour.maximumPoints else { throw PathEditError.contourFull(contour.id) }
        guard points.allSatisfy({ $0.anchor.isFinite && $0.inHandle.isFinite && $0.outHandle.isFinite }) else { throw PathEditError.invalidValue("points") }
        let drawn = contour.drawn
        let live = Dictionary(drawn.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let preserves = keepsOrder(points, drawn: drawn, closed: contour.closed)
        var seen = Set<OpID>()
        // A point is kept when it names a live point of the contour (once) and the order holds.
        let kept = points.map { point -> Bool in
            guard preserves, point.id != .zero, live[point.id] != nil, seen.insert(point.id).inserted else { return false }
            return true
        }
        let keptIDs = Set(zip(points, kept).filter(\.1).map(\.0.id))
        let deleted = drawn.filter { !keptIDs.contains($0.id) }
        if !deleted.isEmpty { builder.append(Ops.elementDelete(node, deleted.map { PathFields.point(contour.id, $0.id) })) }
        for (point, isKept) in zip(points, kept) where isKept {
            try update(live[point.id]!, to: point, in: contour, of: node, builder: &builder)
        }
        // Runs of new points go after the kept point before them, or before the first kept one.
        var firstIDs: [Int: OpID] = [:]
        var index = 0
        while index < points.count {
            guard !kept[index] else { index += 1; continue }
            var end = index
            while end < points.count, !kept[end] { end += 1 }
            let run = Array(points[index..<end]).map { point -> VectorPoint in
                var copy = point
                copy.id = .zero
                return copy
            }
            let placement: PointPlacement
            if let previous = points[..<index].indices.last(where: { kept[$0] }) {
                placement = .after(points[previous].id)
            } else if let next = points[end...].indices.first(where: { kept[$0] }) {
                placement = .before(points[next].id)
            } else {
                placement = .end
            }
            let first = builder.append(try PathEditing.insert(run, into: contour, of: node, at: placement, state: state))
            for offset in 0..<run.count {
                let stored = contour.reversed ? run.count - 1 - offset : offset
                firstIDs[index + offset] = OpID(counter: first.counter + UInt64(stored), replica: first.replica)
            }
            index = end
        }
        var paths: [RegisterPath] = []
        var value = Wiretuner_Doc_V1_Contour()
        if closed != contour.closed {
            paths.append(PathFields.closed(contour.id))
            value.closed = closed
        }
        if !closed, let head = points.first {
            let id = kept[0] ? head.id : firstIDs[0]!
            // An open contour reads from its `start` (or its first stored point): write it only
            // when the head changes.
            if drawn.first?.id != id || contour.closed {
                paths.append(PathFields.start(contour.id))
                value.start = id.elementID
            }
        }
        if !paths.isEmpty { builder.append(Ops.set(node, paths, values: PathEditing.contourValues(value))) }
    }

    /// The registers of kept point `old` that `new` changes.
    static func update(_ old: VectorPoint, to new: VectorPoint, in contour: VectorContour, of node: OpID, builder: inout ChangeBuilder) throws {
        if old.anchor != new.anchor {
            var value = Wiretuner_Doc_V1_PathPoint()
            value.anchor = PathEditing.proto(new.anchor)
            builder.append(Ops.set(node, [PathFields.anchor(contour.id, old.id)], values: PathEditing.pointValues(value)))
        }
        let inHandle = old.inHandle != new.inHandle ? new.inHandle : nil
        let outHandle = old.outHandle != new.outHandle ? new.outHandle : nil
        if let op = PathEditing.setHandles(node, contour, old.id, in: inHandle, out: outHandle) { builder.append(op) }
        if old.kind != new.kind || old.automatic != new.automatic {
            var value = Wiretuner_Doc_V1_PathPoint()
            value.kind = new.kind.proto
            value.automatic = new.automatic
            var paths: [RegisterPath] = []
            if old.kind != new.kind { paths.append(PathFields.pointKind(contour.id, old.id)) }
            if old.automatic != new.automatic { paths.append(PathFields.automatic(contour.id, old.id)) }
            builder.append(Ops.set(node, paths, values: PathEditing.pointValues(value)))
        }
    }
}
