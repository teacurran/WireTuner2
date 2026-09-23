import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// A path point named by its contour and element (a derived shape point's ids are synthetic).
public struct PointRef: Hashable, Sendable {
    public var contour: OpID
    public var point: OpID

    public init(contour: OpID, point: OpID) {
        self.contour = contour
        self.point = point
    }
}

/// One object drawn in a scene: what the canvas overlay, hit results and the panels need beyond
/// the display item itself.
public struct SceneObject: Hashable, Sendable {
    public var id: OpID
    public var kind: NodeKind
    /// The geometry in local space (a shape's derived path); nil for a group.
    public var path: VectorPath?
    /// Local → pasteboard, flattened through enclosing groups.
    public var transform: AffineTransform
    /// Where the item is: `DisplayList.items` index, then group children downward.
    public var itemPath: [Int]
    /// The enclosing group, if any.
    public var parent: OpID?
    /// Painted bounds, pasteboard space; nil when it paints nothing.
    public var bounds: Rect?
    /// Per leaf of the item (its path below `itemPath`; empty for the item itself), the point
    /// each `DisplayPath` element ends at (nil for `close`).
    public var elementPoints: [[Int]: [PointRef?]]
    /// Per leaf, the contour id of each contour of its `DisplayPath`, in order.
    public var leafContours: [[Int]: [OpID]]
    /// The object's display item as placed (transforms flattened; a group with its members).
    public var item: DisplayItem

    /// The point a hit on element `element` of the leaf at `leafPath` (a full index path) names.
    public func point(leafPath: [Int], element: Int) -> PointRef? {
        guard leafPath.starts(with: itemPath), let elements = elementPoints[Array(leafPath.dropFirst(itemPath.count))],
              elements.indices.contains(element) else { return nil }
        return elements[element]
    }

    /// The contour a hit on contour `index` of the leaf at `leafPath` names.
    public func contour(leafPath: [Int], index: Int) -> OpID? {
        guard leafPath.starts(with: itemPath), let contours = leafContours[Array(leafPath.dropFirst(itemPath.count))],
              contours.indices.contains(index) else { return nil }
        return contours[index]
    }
}

/// The document as drawn on one canvas: the display list (tagged with node ids) and its objects.
public struct DocumentScene: Hashable, Sendable {
    public var displayList: DisplayList
    /// Every drawn object, groups and group members included.
    public var objects: [NodeID: SceneObject]
    /// The top-level objects in draw order (bottom first).
    public var topLevel: [NodeID]
    private var byItemPath: [[Int]: NodeID]

    public init(displayList: DisplayList, objects: [NodeID: SceneObject] = [:], topLevel: [NodeID] = []) {
        self.displayList = displayList
        self.objects = objects
        self.topLevel = topLevel
        byItemPath = Dictionary(uniqueKeysWithValues: objects.map { ($0.value.itemPath, $0.key) })
    }

    /// The object whose item sits at `itemPath` (a top-level index, then group children).
    public func object(atItemPath itemPath: [Int]) -> SceneObject? {
        byItemPath[itemPath].flatMap { objects[$0] }
    }

    public func object(_ id: OpID) -> SceneObject? { objects[NodeID(id)] }
}

/// Builds the display list of the main pasteboard from the merged state (client.adoc, "The
/// display list"): layers bottom first, invisible layers and deleted nodes skipped, each object a
/// top-level item tagged with its node id (group members nested), transforms flattened, attribute
/// stacks resolved.  Items for nodes a change did not touch are reused, and every change yields a
/// `ChangeSummary` for the invalidation pipeline.  Background items (the page furniture the window
/// draws until pages are nodes) come first and carry no node id.
///
/// Named `DocumentDisplayListBuilder` rather than `DisplayListBuilder`, which is WTRender's
/// low-level builder and would be ambiguous in every file importing both modules.
public struct DocumentDisplayListBuilder: Sendable {
    public let canvas: CanvasID
    public private(set) var background: [DisplayItem]
    public private(set) var scene: DocumentScene
    private var cache: [OpID: Built] = [:]

    /// A node's item before enclosing transforms, and what the scene records about it.
    private struct Built: Sendable {
        var item: DisplayItem?
        var kind: NodeKind
        var path: VectorPath?
        var transform: AffineTransform
        var elementPoints: [[Int]: [PointRef?]]
        var leafContours: [[Int]: [OpID]]
    }

    public init(canvas: CanvasID, background: [DisplayItem] = []) {
        self.canvas = canvas
        self.background = background
        scene = DocumentScene(displayList: DisplayList(canvas: canvas, items: background, nodeIDs: background.map { _ in nil }))
    }

    /// Rebuilds everything from `state`.
    @discardableResult
    public mutating func rebuild(_ state: EngineState) -> DocumentScene {
        cache = [:]
        scene = build(state)
        return scene
    }

    /// Replaces the background items (pages added or removed) and rebuilds the list around the
    /// cached objects; the summary names no node, only the structural change.
    public mutating func setBackground(_ items: [DisplayItem], state: EngineState) -> (DocumentScene, ChangeSummary) {
        background = items
        scene = build(state)
        return (scene, ChangeSummary(origin: .local, isStructural: true))
    }

    /// Brings the scene up to `state` after `change` was applied, rebuilding the nodes it touched,
    /// and returns the scene with the change's summary (touched nodes and fields, painted bounds
    /// before and after, structural when items were added, removed or reordered).
    public mutating func apply(_ change: Wiretuner_Doc_V1_Change, state: EngineState, origin: ChangeOrigin) -> (DocumentScene, ChangeSummary) {
        let before = scene
        var touched: [OpID: [FieldPath]] = [:]
        for op in change.ops {
            for (node, fields) in Self.targets(op) { touched[node, default: []] += fields }
        }
        for (op, id) in zip(change.ops, change.opIDs) {
            if case .create = op.op { touched[id, default: []] += [] }
        }
        for node in touched.keys {
            cache[node] = nil
        }
        scene = build(state)
        var summary = ChangeSummary(origin: origin, isStructural: before.displayList.nodeIDs != scene.displayList.nodeIDs
            || before.objects.mapValues(\.itemPath) != scene.objects.mapValues(\.itemPath))
        var affected = Set(touched.keys.map(NodeID.init))
        // A touched group moves its members; a touched layer everything on it.
        for (id, object) in before.objects.merging(scene.objects, uniquingKeysWith: { $1 }) {
            if let parent = object.parent, affected.contains(NodeID(parent)) { affected.insert(id) }
        }
        for node in touched.keys where state.nodeKind(node) == .layer {
            for child in state.store.children(node) { affected.insert(NodeID(child)) }
        }
        for id in affected {
            let fields = touched[OpID(id)] ?? []
            let old = before.objects[id]?.bounds.map { NodeBounds(canvas: canvas, rect: $0) }
            let new = scene.objects[id]?.bounds.map { NodeBounds(canvas: canvas, rect: $0) }
            if old != nil || new != nil {
                summary.record(id, old: old, new: new, fields: fields)
            } else {
                summary.touch(id, fields: fields)
            }
        }
        return (scene, summary)
    }

    /// The nodes an op writes, with the field paths it writes.
    static func targets(_ op: Wiretuner_Doc_V1_Op) -> [(OpID, [FieldPath])] {
        func paths(_ list: [Wiretuner_Doc_V1_FieldPath]) -> [FieldPath] { list.compactMap(RegisterPath.init).map(FieldPath.init) }
        switch op.op {
        case .create(let create)?: return [(OpID(create.parent), [])]
        case .set(let set)?: return [(OpID(set.node), paths(set.paths))]
        case .move(let move)?: return [(OpID(move.node), []), (OpID(move.parent), [])]
        case .setDeleted(let delete)?: return [(OpID(delete.node), [])]
        case .elementInsert(let insert)?: return [(OpID(insert.node), paths([insert.sequence]))]
        case .elementMove(let move)?: return [(OpID(move.node), paths([move.element]))]
        case .elementDelete(let delete)?: return [(OpID(delete.node), paths(delete.elements))]
        case .setAdd(let add)?: return [(OpID(add.node), paths([add.set]))]
        case .setRemove(let remove)?: return [(OpID(remove.node), paths([remove.set]))]
        case .textInsert(let insert)?: return [(OpID(insert.node), paths([insert.text]))]
        case .textDelete(let delete)?: return [(OpID(delete.node), paths([delete.text]))]
        case .textMark(let mark)?: return [(OpID(mark.node), paths([mark.text]))]
        default: return []
        }
    }

    // MARK: Building

    private mutating func build(_ state: EngineState) -> DocumentScene {
        var items = background
        var nodeIDs: [NodeID?] = background.map { _ in nil }
        var objects: [NodeID: SceneObject] = [:]
        var topLevel: [NodeID] = []
        for layer in state.liveChildren(WellKnown.layers) where state.nodeKind(layer) == .layer {
            let props = state.props(layer).layer
            guard props.visible else { continue }
            let layerTransform = PathEditing.transform(props.common.transform)
            for child in state.liveChildren(layer) {
                let index = items.count
                guard let item = place(child, state: state, parentTransform: layerTransform, itemPath: [index], parent: nil, objects: &objects) else { continue }
                items.append(item)
                nodeIDs.append(NodeID(child))
                topLevel.append(NodeID(child))
            }
        }
        return DocumentScene(displayList: DisplayList(canvas: canvas, items: items, nodeIDs: nodeIDs), objects: objects, topLevel: topLevel)
    }

    /// The item of `node` under `parentTransform`, recording it (and its members) in `objects`.
    private mutating func place(_ node: OpID, state: EngineState, parentTransform: AffineTransform, itemPath: [Int], parent: OpID?,
                                objects: inout [NodeID: SceneObject]) -> DisplayItem? {
        guard let built = built(node, state: state) else { return nil }
        let transform = built.transform.concatenating(parentTransform)
        let item: DisplayItem
        if built.kind == .group {
            var children: [DisplayItem] = []
            for child in state.liveChildren(node) {
                if let placed = place(child, state: state, parentTransform: transform, itemPath: itemPath + [children.count], parent: node, objects: &objects) {
                    children.append(placed)
                }
            }
            guard !children.isEmpty else { return nil }
            item = .group(GroupItem(children: children))
        } else {
            guard let own = built.item else { return nil }
            item = parentTransform.isIdentity ? own : Self.transformed(own, by: parentTransform)
        }
        objects[NodeID(node)] = SceneObject(
            id: node, kind: built.kind, path: built.path, transform: transform, itemPath: itemPath, parent: parent,
            bounds: item.bounds, elementPoints: built.elementPoints, leafContours: built.leafContours, item: item
        )
        return item
    }

    private mutating func built(_ node: OpID, state: EngineState) -> Built? {
        if let cached = cache[node] { return cached }
        guard let kind = state.nodeKind(node), kind != .layer else { return nil }
        let props = state.props(node)
        guard let common = NodeValues.common(props), !common.hasCanvas else { return nil }
        let transform = PathEditing.transform(common.transform)
        var built = Built(item: nil, kind: kind, path: nil, transform: transform, elementPoints: [:], leafContours: [:])
        switch props.kind {
        case .path(let path)?:
            let model = VectorPath(path, node: node, state: state)
            built.path = model
            Self.render(model, appearance: path.appearance, transform: transform, into: &built)
        case .rect(let rect)?:
            let model = ShapeGeometry.path(rect)
            built.path = model
            Self.render(model, appearance: rect.appearance, transform: transform, into: &built)
        case .ellipse(let ellipse)?:
            let model = ShapeGeometry.path(ellipse)
            built.path = model
            Self.render(model, appearance: ellipse.appearance, transform: transform, into: &built)
        default:
            break
        }
        cache[node] = built
        return built
    }

    /// A path's display item: one `PathItem`, or -- when open contours must not show the fills
    /// that closed ones do -- a group of one item per attribute (the fills over the closed
    /// contours only), keeping the stack's order.
    private static func render(_ path: VectorPath, appearance: Wiretuner_Doc_V1_AppearanceProps, transform: AffineTransform, into built: inout Built) {
        guard path.isRenderable else { return }
        let all = display(path) { _ in true }
        let hasOpen = path.contours.contains { $0.isRenderable && !$0.closed }
        let hasClosed = path.contours.contains { $0.isRenderable && $0.closed }
        let resolved = Appearances.resolve(appearance, evenOdd: path.evenOdd)
        let hasFill = resolved.items.contains { if case .fill = $0 { return true } else { return false } }
        guard hasOpen, !path.fillWhenOpen, hasFill else {
            built.item = .path(PathItem(path: all.path, appearance: resolved, transform: transform))
            built.elementPoints = [[]: all.points]
            built.leafContours = [[]: all.contours]
            return
        }
        guard hasClosed else {
            built.item = .path(PathItem(path: all.path, appearance: Appearances.resolve(appearance, evenOdd: path.evenOdd, paintsFill: false), transform: transform))
            built.elementPoints = [[]: all.points]
            built.leafContours = [[]: all.contours]
            return
        }
        let closed = display(path) { $0.closed }
        var children: [DisplayItem] = []
        for element in resolved.items {
            let source: (path: DisplayPath, points: [PointRef?], contours: [OpID])
            if case .fill = element { source = closed } else { source = all }
            built.elementPoints[[children.count]] = source.points
            built.leafContours[[children.count]] = source.contours
            children.append(.path(PathItem(path: source.path, appearance: Appearance([element]), transform: transform)))
        }
        built.item = .group(GroupItem(children: children))
    }

    /// The `DisplayPath` of the renderable contours `include` accepts, with the point each element
    /// ends at and the contour of each subpath.
    public static func display(_ path: VectorPath, include: (VectorContour) -> Bool) -> (path: DisplayPath, points: [PointRef?], contours: [OpID]) {
        var result = DisplayPath()
        var points: [PointRef?] = []
        var contours: [OpID] = []
        for contour in path.contours where contour.isRenderable && include(contour) {
            let drawn = contour.drawn
            contours.append(contour.id)
            result.move(to: drawn[0].anchor)
            points.append(PointRef(contour: contour.id, point: drawn[0].id))
            for segment in contour.segments {
                if segment.isStraight {
                    result.addLine(to: segment.to.anchor)
                } else {
                    result.addCubicCurve(control1: segment.from.outControl, control2: segment.to.inControl, to: segment.to.anchor)
                }
                points.append(PointRef(contour: contour.id, point: segment.to.id))
            }
            if contour.closed {
                result.close()
                points.append(nil)
            }
        }
        return (result, points, contours)
    }

    /// `item` with `transform` applied after its own.
    static func transformed(_ item: DisplayItem, by transform: AffineTransform) -> DisplayItem {
        switch item {
        case .path(var path):
            path.transform = path.transform.concatenating(transform)
            return .path(path)
        case .group(var group):
            group.children = group.children.map { transformed($0, by: transform) }
            group.transform = group.transform.concatenating(transform)
            return .group(group)
        default:
            return item
        }
    }
}

extension FieldPath {
    /// The render-side mirror of a register path.
    public init(_ path: RegisterPath) {
        self.init(path.segments.map { segment -> FieldPath.Segment in
            switch segment {
            case .field(let number): .field(number)
            case .element(let id): .element(NodeID(id))
            }
        })
    }
}
