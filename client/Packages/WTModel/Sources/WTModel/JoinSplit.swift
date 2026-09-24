import WTCRDT
import WTGeometry
import WTProto

/// menu:Modify[Join] (OBJ-024, combining-paths.adoc "Join"): fuses two or more paths -- paths,
/// rectangles, ellipses and polygons -- into one fresh path node.  Every closed contour becomes a
/// sub-path of the composite; open contours whose ends touch (or, with *Join non-touching paths*
/// on, lie within `snapDistance` of each other, pasteboard units) are joined end to end into one
/// open contour, repeatedly, and the rest stay separate sub-paths.
///
/// The result takes the backmost input's attributes (its stack copied under fresh element ids,
/// with its *Even/odd fill* and *Show fill for open paths*) and transform, so the backmost input
/// does not move; every other input's geometry is re-expressed in that space through its transform
/// chain.  It is created at the frontmost input's slot under its parent, and the inputs are
/// deleted: one change "Join N paths" (combining-paths.adoc, "Merge semantics").  Fewer than two
/// joinable, unlocked inputs: no change.
public struct JoinObjects: Command {
    /// Ends closer than this (pasteboard units) touch.
    public static let touching = 1e-6

    public var nodes: [OpID]
    /// *Join non-touching paths*: the *Snap distance* in pasteboard units; nil when the preference
    /// is off (ends must touch).
    public var snapDistance: Double?

    public init(_ nodes: [OpID], snapDistance: Double? = nil) {
        self.nodes = nodes
        self.snapDistance = snapDistance
    }

    public var label: String { "Join \(nodes.count) paths" }

    /// The kinds Join takes.
    public static let kinds: Set<NodeKind> = [.path, .rect, .ellipse, .polygon]

    /// The inputs of `nodes` Join would use, bottom first; empty when there are fewer than two.
    public static func inputs(_ nodes: [OpID], in state: EngineState) -> [OpID] {
        let inputs = Objects.stackingOrder(Objects.editable(nodes, in: state).filter { node in
            state.nodeKind(node).map(kinds.contains) == true && Objects.localPath(node, in: state) != nil
        }, in: state)
        return inputs.count >= 2 ? inputs : []
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let inputs = Self.inputs(nodes, in: state)
        guard let backmost = inputs.first, let frontmost = inputs.last, let parent = Objects.parent(of: frontmost, in: state) else { return }
        // Everything is joined in pasteboard space, then expressed in the result's space.
        let parentSpace = Objects.pasteboardTransform(ofSpace: parent, in: state)
        var resultSpace = Objects.pasteboardTransform(of: backmost, in: state)
        if abs(resultSpace.determinant) < 1e-12 { resultSpace = parentSpace }
        let toResult = resultSpace.inverse
        var closed: [[VectorPoint]] = []
        var open: [[VectorPoint]] = []
        for input in inputs {
            let toPasteboard = Objects.pasteboardTransform(of: input, in: state)
            for contour in Objects.localPath(input, in: state)!.contours where contour.isRenderable {
                let points = contour.drawn.map { Self.map($0, toPasteboard) }
                if contour.closed { closed.append(points) } else { open.append(points) }
            }
        }
        let ends = Self.joinEnds(open, within: max(snapDistance ?? 0, Self.touching))
        let backProps = state.props(backmost)
        var props = Wiretuner_Doc_V1_NodeProps()
        if case .path(let path)? = backProps.kind {
            props.path.evenOdd = path.evenOdd
            props.path.fillWhenOpen = path.fillWhenOpen
        }
        props.path.contours = (closed.map { ($0, true) } + ends.map { ($0, false) }).map { points, isClosed in
            var contour = Wiretuner_Doc_V1_Contour()
            contour.closed = isClosed
            contour.points = points.map { PathEditing.stored(Self.map($0, toResult), reversed: false) }
            return contour
        }
        var tree = NodeTree(props: props)
        tree.transform = resultSpace.concatenating(parentSpace.inverse)
        let key = try Arranging.keys(next: frontmost, above: true, count: 1, in: state)[0]
        let joined = try NodeCopier.create(tree, parent: parent, position: key, schema: state.schema, builder: &builder)
        try PasteAttributes.insert(AttributePayload(copying: backmost, from: state)!.stack!, into: joined, kind: .path, schema: state.schema,
                                   builder: &builder)
        for input in inputs {
            builder.append(Ops.setDeleted(input))
        }
    }

    /// `point` mapped by `matrix` (handles as vectors).
    static func map(_ point: VectorPoint, _ matrix: AffineTransform) -> VectorPoint {
        var mapped = point
        mapped.id = .zero
        mapped.anchor = matrix.apply(point.anchor)
        mapped.inHandle = matrix.apply(point.inHandle)
        mapped.outHandle = matrix.apply(point.outHandle)
        return mapped
    }

    /// Open contours (drawn points) joined end to end wherever two ends lie within `distance`:
    /// the first such pair in input order is joined, then the search starts again.  The joint is
    /// one point at the ends' midpoint keeping the arriving contour's in handle and the leaving
    /// one's out handle.
    static func joinEnds(_ contours: [[VectorPoint]], within distance: Double) -> [[VectorPoint]] {
        var contours = contours
        func near(_ a: VectorPoint, _ b: VectorPoint) -> Bool {
            let dx = a.anchor.x - b.anchor.x, dy = a.anchor.y - b.anchor.y
            return (dx * dx + dy * dy).squareRoot() <= distance
        }
        func reversed(_ points: [VectorPoint]) -> [VectorPoint] { points.reversed().map(\.swapped) }
        func joined(_ head: [VectorPoint], _ tail: [VectorPoint]) -> [VectorPoint] {
            var joint = head.last!
            let next = tail.first!
            joint.anchor = Point(x: (joint.anchor.x + next.anchor.x) / 2, y: (joint.anchor.y + next.anchor.y) / 2)
            joint.outHandle = next.outHandle
            return head.dropLast() + [joint] + tail.dropFirst()
        }
        search: while contours.count >= 2 {
            for i in contours.indices {
                for j in contours.indices where j > i {
                    let a = contours[i], b = contours[j]
                    let merged: [VectorPoint]?
                    if near(a.last!, b.first!) {
                        merged = joined(a, b)
                    } else if near(a.last!, b.last!) {
                        merged = joined(a, reversed(b))
                    } else if near(a.first!, b.last!) {
                        merged = joined(b, a)
                    } else if near(a.first!, b.first!) {
                        merged = joined(reversed(a), b)
                    } else {
                        merged = nil
                    }
                    if let merged {
                        contours[i] = merged
                        contours.remove(at: j)
                        continue search
                    }
                }
            }
            break
        }
        return contours
    }
}

/// menu:Modify[Split] (OBJ-024, combining-paths.adoc "Join"): takes each composite path (a path of
/// two or more contours) apart into one fresh path node per contour, bottom first at the
/// composite's slot, each with the composite's transform, attributes and settings; the composite
/// is deleted.  One change "Split"; paths of one contour and locked objects are left alone.
public struct SplitObjects: Command {
    public var nodes: [OpID]
    public var label: String { "Split" }

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    /// Whether Split would take `node` apart.
    public static func splits(_ node: OpID, in state: EngineState) -> Bool {
        state.nodeKind(node) == .path && state.liveElements(node, PathFields.contours).count >= 2
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in Objects.editable(nodes, in: state) where Self.splits(node, in: state) {
            let parent = Objects.parent(of: node, in: state)!
            let stored = state.props(node).path
            let contours = VectorPath(stored, node: node, state: state).contours
            let keys = try Arranging.keys(next: node, above: true, count: contours.count, in: state)
            let stack = AttributePayload(copying: node, from: state)!.stack!
            for (contour, key) in zip(contours, keys) {
                var props = Wiretuner_Doc_V1_NodeProps()
                props.path = stored
                props.path.clearAppearance()
                var value = Wiretuner_Doc_V1_Contour()
                value.closed = contour.closed
                value.points = contour.drawn.map { PathEditing.stored($0, reversed: false) }
                props.path.contours = [value]
                let piece = try NodeCopier.create(NodeTree(props: props), parent: parent, position: key, schema: state.schema, builder: &builder)
                try PasteAttributes.insert(stack, into: piece, kind: .path, schema: state.schema, builder: &builder)
            }
            builder.append(Ops.setDeleted(node))
        }
    }
}
