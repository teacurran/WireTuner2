import WTCRDT
import WTGeometry
import WTProto

/// Live shapes edited as paths (D-078; rectangles-ellipses-lines.adoc "Editing a shape's points",
/// polygons-stars.adoc "Editing a polygon's points"): a rectangle, ellipse or polygon keeps its live
/// fields until something edits its points or asks for a path -- a point or handle drag, a point
/// added or deleted, a path command such as Simplify or Remove Overlap.  That edit first replaces
/// the shape with an ordinary path drawing exactly the same (`convert`), then runs against the path,
/// all in one change, so one undo brings the live shape back.
public enum ShapeConversion {
    /// The node kinds that are live shapes.
    public static let kinds: Set<NodeKind> = [.rect, .ellipse, .polygon]

    /// The label of a point edit that converted a shape.
    public static let editPointsLabel = "Edit Points"

    /// Whether `node` is a rectangle, ellipse or polygon (live or deleted).
    public static func isShape(_ node: OpID, in state: EngineState) -> Bool {
        guard let kind = state.nodeKind(node) else { return false }
        return kinds.contains(kind)
    }

    /// The editable live shapes among `nodes`, each once, in the order given.
    public static func shapes(_ nodes: [OpID], in state: EngineState) -> [OpID] {
        Objects.editable(nodes, in: state).filter { isShape($0, in: state) }
    }

    /// The path `shape` draws as, local space: what the canvas shows and a selection's points name
    /// (a rectangle with a live Corners effect reads with square corners, the effect rounding them,
    /// as `DocumentScene` draws it).  Nil when `shape` is not a shape.
    public static func path(of shape: OpID, in state: EngineState) -> VectorPath? {
        switch state.props(shape).kind {
        case .rect(var rect)?:
            if EffectLowering.hasCorners(rect.appearance) { rect.clearCorners() }
            return ShapeGeometry.path(rect)
        case .ellipse(let ellipse)?:
            return ShapeGeometry.path(ellipse)
        case .polygon(let polygon)?:
            return ShapeGeometry.path(polygon)
        default:
            return nil
        }
    }

    /// The user-facing name of `shape`'s kind: "Rectangle", "Ellipse", "Polygon" or "Star".
    public static func name(of shape: OpID, in state: EngineState) -> String {
        switch state.props(shape).kind {
        case .rect?: "Rectangle"
        case .ellipse?: "Ellipse"
        case .polygon(let polygon)?: polygon.star ? "Star" : "Polygon"
        default: "Shape"
        }
    }

    /// Appends the ops that replace `shape` with an ordinary path drawing the same: a `path` node
    /// directly above it under the same parent, holding the outline as drawn (a rounded corner's
    /// two points and quarter-circle handles, an arc's pieces, a star's points), the shape's common
    /// properties (transform, name, note, lock, links) and its attribute stack in the same order;
    /// the clip group that clips with the shape and every connector end attached to it then name
    /// the path; the shape is deleted.  Returns the path's id; nil when `shape` is not a live shape.
    @discardableResult
    public static func convert(_ shape: OpID, state: EngineState, builder: inout ChangeBuilder) throws -> OpID? {
        guard state.isLive(shape), isShape(shape, in: state), let parent = Objects.parent(of: shape, in: state),
              let outline = path(of: shape, in: state) else { return nil }
        let source = NodeTree(shape, state: state)
        var props = Wiretuner_Doc_V1_NodeProps()
        // A shape always has both (`NodeValues` answers nil only for kinds without them).
        props.path.common = NodeValues.common(source.props)!
        props.path.appearance = NodeValues.appearance(source.props)!
        props.path.contours = stored(outline)
        let key = try Arranging.keys(next: shape, above: true, count: 1, in: state)[0]
        let node = try NodeCopier.create(NodeTree(props: props, stackOrder: source.stackOrder), parent: parent, position: key, schema: state.schema,
                                         builder: &builder)
        retarget(shape, to: node, parent: parent, state: state, builder: &builder)
        builder.append(Ops.setDeleted(shape))
        return node
    }

    /// Points what named `shape` at `path`: the clip group whose clip path it is, and every live
    /// connector end attached to it.
    static func retarget(_ shape: OpID, to path: OpID, parent: OpID, state: EngineState, builder: inout ChangeBuilder) {
        if ClipGroups.clipPath(of: parent, in: state) == shape {
            var value = Wiretuner_Doc_V1_NodeProps()
            value.group.clipPath.id = path.proto
            builder.append(Ops.set(parent, [ClipGroups.clipPathField], values: value))
        }
        for node in DataBindings.liveNodes(in: state) where state.nodeKind(node) == .connector {
            let connector = state.props(node).connector
            for (end, field) in [(connector.start, ConnectorFields.start), (connector.end, ConnectorFields.end)]
            where Connectors.storedEnd(end).node == shape {
                var value = end
                value.node.id = path.proto
                var props = Wiretuner_Doc_V1_NodeProps()
                if field == ConnectorFields.start { props.connector.start = value } else { props.connector.end = value }
                builder.append(Ops.set(node, [field], values: props))
            }
        }
    }

    /// One shape converted: the path that replaced it and, for each contour and point of the shape's
    /// derived path (`path(of:in:)`, whose ids are synthetic), the ones of the path.
    public struct Converted: Hashable, Sendable {
        public var shape: OpID
        public var path: OpID
        public var contours: [OpID: OpID]
        public var points: [PointRef: PointRef]

        public init(shape: OpID, path: OpID, contours: [OpID: OpID], points: [PointRef: PointRef]) {
            self.shape = shape
            self.path = path
            self.contours = contours
            self.points = points
        }
    }

    /// `shape`'s conversion to `path`, read from `state`: the contours and points the conversion
    /// created (ids in `created`, the counters of the conversion's ops, tombstones included, so a
    /// point deleted later in the same change keeps its place) pair up in order with `derived`'s,
    /// the path the shape drew.  Nil when they do not match one for one.
    public static func converted(_ shape: OpID, derived: VectorPath, to path: OpID, created: Range<UInt64>, in state: EngineState) -> Converted? {
        func made(_ id: OpID) -> Bool { id.replica == path.replica && created.contains(id.counter) }
        let contourIDs = state.store.elementOrder(path, PathFields.contours).filter(made)
        guard contourIDs.count == derived.contours.count else { return nil }
        var contours: [OpID: OpID] = [:]
        var points: [PointRef: PointRef] = [:]
        for (from, to) in zip(derived.contours, contourIDs) {
            let pointIDs = state.store.elementOrder(path, PathFields.points(to)).filter(made)
            guard pointIDs.count == from.points.count else { return nil }
            contours[from.id] = to
            for (a, b) in zip(from.points, pointIDs) {
                points[PointRef(contour: from.id, point: a.id)] = PointRef(contour: to, point: b)
            }
        }
        return Converted(shape: shape, path: path, contours: contours, points: points)
    }

    /// The shapes `change` converted, read back from `state` with the change applied: each shape
    /// node the change deletes that a `path` node created earlier in it under the same parent
    /// replaces, created with exactly the outline the shape drew (the order and form `convert`
    /// writes; a Combine's path, whose outline differs, is not one).  Selections follow a
    /// conversion with it.
    public static func conversions(in change: Wiretuner_Doc_V1_Change, state: EngineState) -> [OpID: Converted] {
        var created: [OpID: (id: OpID, contours: [Wiretuner_Doc_V1_Contour])] = [:]
        var result: [OpID: Converted] = [:]
        for (op, id) in zip(change.ops, change.opIDs) {
            switch op.op {
            case .create(let create)?:
                if case .path(let path)? = create.props.kind { created[OpID(create.parent)] = (id, path.contours) }
            case .setDeleted(let deleted)? where deleted.deleted:
                let shape = OpID(deleted.node)
                guard isShape(shape, in: state), let parent = state.store.placement(shape)?.parent, let path = created[parent],
                      state.isLive(path.id), let derived = self.path(of: shape, in: state), stored(derived) == path.contours,
                      let conversion = converted(shape, derived: derived, to: path.id, created: path.id.counter..<id.counter, in: state) else { continue }
                result[shape] = conversion
                created[parent] = nil
            default:
                continue
            }
        }
        return result
    }

    /// `outline`'s contours as a path stores them.
    static func stored(_ outline: VectorPath) -> [Wiretuner_Doc_V1_Contour] {
        outline.contours.map { contour in
            var value = Wiretuner_Doc_V1_Contour()
            value.closed = contour.closed
            value.points = contour.drawn.map { PathEditing.stored($0, reversed: false) }
            return value
        }
    }

    /// `command` aimed at paths: when it edits live shapes (`ShapeRetargetable`), a
    /// `ConvertingShapes` that converts them first; otherwise `command` itself.
    public static func asPaths(_ command: any Command, in state: EngineState) -> any Command {
        guard !(command is ConvertingShapes), let target = command as? any ShapeRetargetable else { return command }
        // Most path commands name no shape: settle that before reading the layers.
        let named = target.editedNodes.filter { isShape($0, in: state) }
        guard !named.isEmpty else { return command }
        let shapes = shapes(named, in: state)
        guard !shapes.isEmpty else { return command }
        return ConvertingShapes(target.convertedLabel, shapes) { _, conversions in target.retargeted(conversions) }
    }
}

/// The ids a set of conversions maps: a converted shape's node, contours and points to its path's;
/// anything else to itself.
public struct ShapeConversions: Hashable, Sendable {
    public var converted: [OpID: ShapeConversion.Converted]

    public init(_ converted: [OpID: ShapeConversion.Converted] = [:]) {
        self.converted = converted
    }

    public var isEmpty: Bool { converted.isEmpty }

    public func node(_ node: OpID) -> OpID { converted[node]?.path ?? node }

    public func nodes(_ nodes: [OpID]) -> [OpID] { nodes.map(node) }

    public func contour(_ contour: OpID, of node: OpID) -> OpID { converted[node]?.contours[contour] ?? contour }

    public func point(_ point: OpID, contour: OpID, of node: OpID) -> OpID {
        converted[node]?.points[PointRef(contour: contour, point: point)]?.point ?? point
    }

    public func points(_ points: [(contour: OpID, point: OpID)], of node: OpID) -> [(contour: OpID, point: OpID)] {
        points.map { (contour($0.contour, of: node), point($0.point, contour: $0.contour, of: node)) }
    }

    /// `points` of `contour` with the ids of the shape's points replaced (new points, id zero, stay).
    public func vectorPoints(_ points: [VectorPoint], contour: OpID, of node: OpID) -> [VectorPoint] {
        guard converted[node] != nil else { return points }
        return points.map { point in
            var copy = point
            if point.id != .zero { copy.id = self.point(point.id, contour: contour, of: node) }
            return copy
        }
    }
}

/// A path command that can run on live shapes: `ShapeConversion.asPaths` converts the shapes among
/// `editedNodes` and runs `retargeted` against the paths that replaced them.
public protocol ShapeRetargetable: Command {
    /// The nodes the command edits.
    var editedNodes: [OpID] { get }
    /// The command aimed at the converted paths (their node, contour and point ids).
    func retargeted(_ conversions: ShapeConversions) -> any Command
    /// The change's label when it converts a shape (`label` unless said otherwise).
    var convertedLabel: String { get }
}

extension ShapeRetargetable {
    public var convertedLabel: String { label }
}

/// Converts live shapes to paths and then runs a path edit against them, as one change (D-078).
/// Each shape is converted only when the edit then writes to its path: a Remove Overlap or Correct
/// Direction that changes nothing on a rectangle leaves the rectangle live.
public struct ConvertingShapes: Command {
    public var label: String
    public var shapes: [OpID]
    public var edit: @Sendable (EngineState, ShapeConversions) throws -> (any Command)?

    public init(_ label: String, _ shapes: [OpID], edit: @escaping @Sendable (EngineState, ShapeConversions) throws -> (any Command)?) {
        self.label = label
        self.shapes = shapes
        self.edit = edit
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var candidates = ShapeConversion.shapes(shapes, in: state)
        while true {
            var attempt = ChangeBuilder(replica: builder.replica, startCounter: builder.nextCounter)
            let (conversions, touched) = try run(candidates, state: state, builder: &attempt)
            let idle = conversions.converted.values.filter { !touched.contains($0.path) }.map(\.shape)
            guard !idle.isEmpty else {
                for op in attempt.ops { builder.append(op) }
                return
            }
            candidates.removeAll { idle.contains($0) }
        }
    }

    /// Converts `candidates` and runs the edit; answers the conversions and the nodes the edit wrote.
    private func run(_ candidates: [OpID], state: EngineState, builder: inout ChangeBuilder) throws -> (ShapeConversions, Set<OpID>) {
        var scratch = state
        var converted: [OpID: ShapeConversion.Converted] = [:]
        for shape in candidates {
            var part = ChangeBuilder(replica: builder.replica, startCounter: builder.nextCounter)
            // `candidates` are editable live shapes, so both answer.
            if let derived = ShapeConversion.path(of: shape, in: state), let path = try ShapeConversion.convert(shape, state: scratch, builder: &part) {
                for op in part.ops { builder.append(op) }
                var change = Wiretuner_Doc_V1_Change()
                change.replica = part.replica
                change.startCounter = part.startCounter
                change.ops = part.ops
                scratch.apply(change)
                converted[shape] = ShapeConversion.converted(shape, derived: derived, to: path, created: path.counter..<part.nextCounter, in: scratch)
            }
        }
        let conversions = ShapeConversions(converted)
        var touched: Set<OpID> = []
        guard let command = try edit(scratch, conversions) else { return (conversions, touched) }
        var part = ChangeBuilder(replica: builder.replica, startCounter: builder.nextCounter)
        try command.execute(&part, state: scratch)
        for op in part.ops {
            for (node, _) in DocumentDisplayListBuilder.targets(op) { touched.insert(node) }
            builder.append(op)
        }
        return (conversions, touched)
    }
}

// MARK: The path commands that run on shapes

extension MovePoints: ShapeRetargetable {
    public var editedNodes: [OpID] { [node] }
    public var convertedLabel: String { ShapeConversion.editPointsLabel }
    public func retargeted(_ c: ShapeConversions) -> any Command {
        MovePoints(node: c.node(node), moves: moves.map {
            Move(contour: c.contour($0.contour, of: node), point: c.point($0.point, contour: $0.contour, of: node), anchor: $0.anchor)
        })
    }
}

extension SetHandles: ShapeRetargetable {
    public var editedNodes: [OpID] { [node] }
    public var convertedLabel: String { ShapeConversion.editPointsLabel }
    public func retargeted(_ c: ShapeConversions) -> any Command {
        SetHandles(node: c.node(node), contour: c.contour(contour, of: node), point: c.point(point, contour: contour, of: node), in: inHandle, out: outHandle,
                   linked: linked)
    }
}

extension SetPointKind: ShapeRetargetable {
    public var editedNodes: [OpID] { [node] }
    public var convertedLabel: String { ShapeConversion.editPointsLabel }
    public func retargeted(_ c: ShapeConversions) -> any Command {
        SetPointKind(node: c.node(node), points: c.points(points, of: node), kind: kind)
    }
}

extension RetractHandles: ShapeRetargetable {
    public var editedNodes: [OpID] { [node] }
    public var convertedLabel: String { ShapeConversion.editPointsLabel }
    public func retargeted(_ c: ShapeConversions) -> any Command {
        RetractHandles(node: c.node(node), points: c.points(points, of: node))
    }
}

extension SetAutomatic: ShapeRetargetable {
    public var editedNodes: [OpID] { [node] }
    public var convertedLabel: String { ShapeConversion.editPointsLabel }
    public func retargeted(_ c: ShapeConversions) -> any Command {
        SetAutomatic(node: c.node(node), points: c.points(points, of: node), automatic: automatic)
    }
}

extension DeletePoints: ShapeRetargetable {
    public var editedNodes: [OpID] { [node] }
    public var convertedLabel: String { ShapeConversion.editPointsLabel }
    public func retargeted(_ c: ShapeConversions) -> any Command {
        DeletePoints(node: c.node(node), points: c.points(points, of: node))
    }
}

extension DeleteSegment: ShapeRetargetable {
    public var editedNodes: [OpID] { [node] }
    public var convertedLabel: String { ShapeConversion.editPointsLabel }
    public func retargeted(_ c: ShapeConversions) -> any Command {
        DeleteSegment(node: c.node(node), contour: c.contour(contour, of: node), from: c.point(from, contour: contour, of: node))
    }
}

extension InsertPointOnSegment: ShapeRetargetable {
    public var editedNodes: [OpID] { [node] }
    public var convertedLabel: String { ShapeConversion.editPointsLabel }
    public func retargeted(_ c: ShapeConversions) -> any Command {
        InsertPointOnSegment(node: c.node(node), contour: c.contour(contour, of: node), from: c.point(from, contour: contour, of: node), t: t)
    }
}

extension SetClosed: ShapeRetargetable {
    public var editedNodes: [OpID] { [node] }
    public func retargeted(_ c: ShapeConversions) -> any Command {
        SetClosed(node: c.node(node), closed: closed, contours: contours?.map { c.contour($0, of: node) })
    }
}

extension ReverseContours: ShapeRetargetable {
    public var editedNodes: [OpID] { [node] }
    public func retargeted(_ c: ShapeConversions) -> any Command {
        ReverseContours(node: c.node(node), contours: contours?.map { c.contour($0, of: node) })
    }
}

extension RewritePath: ShapeRetargetable {
    public var editedNodes: [OpID] { [node] }
    public func retargeted(_ c: ShapeConversions) -> any Command {
        RewritePath(node: c.node(node), edits: edits.map {
            ContourEdit(contour: c.contour($0.contour, of: node), points: c.vectorPoints($0.points, contour: $0.contour, of: node), closed: $0.closed)
        }, removed: removed.map { c.contour($0, of: node) }, added: added, pieces: pieces, label: label)
    }
}

extension AddPoints: ShapeRetargetable {
    public var editedNodes: [OpID] { nodes }
    public func retargeted(_ c: ShapeConversions) -> any Command { AddPoints(c.nodes(nodes)) }
}

extension SimplifyPaths: ShapeRetargetable {
    public var editedNodes: [OpID] { nodes }
    public func retargeted(_ c: ShapeConversions) -> any Command { SimplifyPaths(c.nodes(nodes), amount: amount) }
}

extension CorrectDirection: ShapeRetargetable {
    public var editedNodes: [OpID] { nodes }
    public func retargeted(_ c: ShapeConversions) -> any Command { CorrectDirection(c.nodes(nodes)) }
}

extension RemoveOverlap: ShapeRetargetable {
    public var editedNodes: [OpID] { nodes }
    public func retargeted(_ c: ShapeConversions) -> any Command { RemoveOverlap(c.nodes(nodes)) }
}

extension Fractalize: ShapeRetargetable {
    public var editedNodes: [OpID] { nodes }
    public func retargeted(_ c: ShapeConversions) -> any Command { Fractalize(c.nodes(nodes)) }
}

extension CompositeCommand: ShapeRetargetable {
    public var editedNodes: [OpID] { commands.flatMap { ($0 as? any ShapeRetargetable)?.editedNodes ?? [] } }

    public func retargeted(_ c: ShapeConversions) -> any Command {
        CompositeCommand(label, commands.map { ($0 as? any ShapeRetargetable)?.retargeted(c) ?? $0 })
    }

    /// "Edit Points" when every part that converts is a point edit.
    public var convertedLabel: String {
        let labels = Set(commands.compactMap { ($0 as? any ShapeRetargetable)?.convertedLabel })
        return labels == [ShapeConversion.editPointsLabel] ? ShapeConversion.editPointsLabel : label
    }
}
