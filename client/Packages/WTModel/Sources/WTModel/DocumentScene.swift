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
    /// The layer the object is shown on (a deleted layer's objects show on its merge target or
    /// the default layer, `LayerOrder`).
    public var layer: OpID?
    /// Whether the object itself is locked (`CommonProps.locked`).
    public var isLocked = false
    /// Whether the object cannot be edited from the canvas: it, an enclosing group or its layer
    /// is locked (arranging.adoc, "Locking"; layers.adoc, "Locking and unlocking layers").
    public var isEffectivelyLocked = false

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
    /// The layer list the scene was built from.
    public var layers: LayerOrder?
    private var byItemPath: [[Int]: NodeID]

    public init(displayList: DisplayList, objects: [NodeID: SceneObject] = [:], topLevel: [NodeID] = [], layers: LayerOrder? = nil) {
        self.displayList = displayList
        self.objects = objects
        self.topLevel = topLevel
        self.layers = layers
        byItemPath = Dictionary(uniqueKeysWithValues: objects.map { ($0.value.itemPath, $0.key) })
    }

    /// The object whose item sits at `itemPath` (a top-level index, then group children).
    public func object(atItemPath itemPath: [Int]) -> SceneObject? {
        byItemPath[itemPath].flatMap { objects[$0] }
    }

    public func object(_ id: OpID) -> SceneObject? { objects[NodeID(id)] }
}

/// Builds the display list of the main pasteboard from the merged state (client.adoc, "The
/// display list"): layers bottom first in `LayerOrder` through WTRender's `LayerScene` (each
/// layer's run of items with its rendering rules: locked, background, keyline, highlight, Guides;
/// hidden layers contribute nothing), deleted nodes skipped, each object a top-level item tagged
/// with its node id (group members nested), transforms flattened, attribute stacks resolved.
/// Symbol instances draw their symbol's artwork through `SymbolRenderer` (LIB-010/026), charts
/// their `ChartLayout` (DRAW-032), barcodes their bars (DATA-018); colours from spot swatches
/// carry their ink (PRINT-007).  Items for nodes a change did not touch are reused; a change's
/// touched nodes are expanded through the `DependencyIndex` (an edited symbol or master node
/// reaches every instance of it, a pictograph's nodes their chart), and every change yields a
/// `ChangeSummary` for the invalidation pipeline.  Background items (the page furniture the window
/// draws until pages are nodes) come first and carry no node id.
///
/// Named `DocumentDisplayListBuilder` rather than `DisplayListBuilder`, which is WTRender's
/// low-level builder and would be ambiguous in every file importing both modules.
public struct DocumentDisplayListBuilder: Sendable {
    public let canvas: CanvasID
    public private(set) var background: [DisplayItem]
    public private(set) var scene: DocumentScene
    /// *Guide color* (preferences.adoc, cyan by default): objects on the Guides layer draw in it.
    public var guideColor = Color(red: 0, green: 1, blue: 1)
    /// Node → the nodes drawn from it, as of the last build: a symbol from its master nodes and
    /// nested symbols, an instance from its symbol, a chart from its pictograph nodes.
    public private(set) var dependencies = DependencyIndex()
    /// The document's symbols as of the last build.
    public private(set) var library = SymbolLibrary([])
    private var cache: [OpID: Built] = [:]
    private let symbolRenderer = SymbolRenderer()
    private let labels = CoreTextLabels()

    /// A node's item before enclosing transforms, and what the scene records about it.
    private struct Built: Sendable {
        var item: DisplayItem?
        var kind: NodeKind
        var path: VectorPath?
        var transform: AffineTransform
        var elementPoints: [[Int]: [PointRef?]]
        var leafContours: [[Int]: [OpID]]
        var locked = false
        /// An instance's own drawing input (its item is made when it is placed on a layer).
        var instance: SymbolInstance?
        /// The nodes the item is drawn from besides its own registers.
        var sources: [OpID] = []
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

    /// Rebuilds everything from `state` after the document's state was replaced wholesale
    /// (`Document.reload`): no cached item survives, and the summary is structural and names every
    /// object drawn before or after with its bounds, so every tile they touch repaints.
    public mutating func reload(_ state: EngineState, origin: ChangeOrigin = .remote) -> (DocumentScene, ChangeSummary) {
        let before = scene
        cache = [:]
        scene = build(state)
        var summary = ChangeSummary(origin: origin, isStructural: true)
        for id in Set(before.objects.keys).union(scene.objects.keys) {
            summary.record(id, old: before.objects[id]?.bounds.map { NodeBounds(canvas: canvas, rect: $0) },
                           new: scene.objects[id]?.bounds.map { NodeBounds(canvas: canvas, rect: $0) })
        }
        return (scene, summary)
    }

    /// Replaces the background items (pages added or removed) and rebuilds the list around the
    /// cached objects; the summary names no node, only the structural change.
    public mutating func setBackground(_ items: [DisplayItem], state: EngineState) -> (DocumentScene, ChangeSummary) {
        background = items
        scene = build(state)
        return (scene, ChangeSummary(origin: .local, isStructural: true))
    }

    /// Brings the scene up to `state` after `change` was applied, rebuilding the nodes it touched
    /// and every node drawn from them (`dependencies`), and returns the scene with the change's
    /// summary (touched nodes and their dependents with fields and painted bounds before and
    /// after, structural when items were added, removed or reordered).  A change to a swatch
    /// rebuilds every item and names each object whose drawing changed.
    public mutating func apply(_ change: Wiretuner_Doc_V1_Change, state: EngineState, origin: ChangeOrigin) -> (DocumentScene, ChangeSummary) {
        let before = scene
        var touched: [OpID: [FieldPath]] = [:]
        for op in change.ops {
            for (node, fields) in Self.targets(op) { touched[node, default: []] += fields }
        }
        for (op, id) in zip(change.ops, change.opIDs) {
            if case .create = op.op { touched[id, default: []] += [] }
        }
        let dependents = dependencies.dependents(of: touched.keys.map(NodeID.init))
        for node in touched.keys { cache[node] = nil }
        for node in dependents { cache[OpID(node)] = nil }
        let swatches = touched.keys.contains { $0 == WellKnown.swatches || state.store.kind($0) == Self.swatchKind }
        if swatches { cache = [:] }
        scene = build(state)
        var summary = ChangeSummary(origin: origin, isStructural: before.displayList.nodeIDs != scene.displayList.nodeIDs
            || before.objects.mapValues(\.itemPath) != scene.objects.mapValues(\.itemPath))
        var affected = Set(touched.keys.map(NodeID.init)).union(dependents).union(dependencies.dependents(of: touched.keys.map(NodeID.init)))
        let all = before.objects.merging(scene.objects, uniquingKeysWith: { $1 })
        // A touched group moves its members; a touched layer everything on it.
        for (id, object) in all {
            if let parent = object.parent, affected.contains(NodeID(parent)) { affected.insert(id) }
            if swatches, before.objects[id]?.item != scene.objects[id]?.item { affected.insert(id) }
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

    /// `NodeProps.swatch`.
    static let swatchKind: UInt32 = 70

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

    // MARK: Output

    /// The list print and export draw (layers.adoc, "Printing"): printing, non-Guides layers
    /// only, hidden ones only with `includeHidden`, no dimming or keyline.  Built from the same
    /// cached items as the canvas; the scene is not changed.
    public mutating func outputDisplayList(_ state: EngineState, includeHidden: Bool = false) -> DisplayList {
        SpotInks.$current.withValue(SpotInks(state)) {
            var scratch: [NodeID: SceneObject] = [:]
            let order = LayerOrder(state)
            let contents = layerContents(state, order: order, includeHidden: includeHidden, objects: &scratch).contents
            return LayerScene.build(canvas: canvas, layers: contents, purpose: .output(includeHidden: includeHidden), background: [])
        }
    }

    // MARK: Building

    private mutating func build(_ state: EngineState) -> DocumentScene {
        SpotInks.$current.withValue(SpotInks(state)) { buildScene(state) }
    }

    private mutating func buildScene(_ state: EngineState) -> DocumentScene {
        var index = DependencyIndex()
        library = buildLibrary(state, dependencies: &index)
        var objects: [NodeID: SceneObject] = [:]
        let order = LayerOrder(state)
        let (contents, topLevel) = layerContents(state, order: order, includeHidden: false, objects: &objects)
        for (node, built) in cache where objects[NodeID(node)] != nil {
            for source in built.sources { index.add(NodeID(node), dependsOn: NodeID(source)) }
        }
        dependencies = index
        let list = LayerScene.build(canvas: canvas, layers: contents, purpose: .screen(guideColor: guideColor), background: background)
        return DocumentScene(displayList: list, objects: objects, topLevel: topLevel, layers: order)
    }

    /// Every layer's content in `order`, placing the objects of the visible ones (and of hidden
    /// ones with `includeHidden`) and recording them in `objects`.
    private mutating func layerContents(_ state: EngineState, order: LayerOrder, includeHidden: Bool,
                                        objects: inout [NodeID: SceneObject]) -> (contents: [LayerContent], topLevel: [NodeID]) {
        var contents: [LayerContent] = []
        var topLevel: [NodeID] = []
        var next = background.count
        for layer in order.layers {
            let rendering = LayerRendering(
                id: NodeID(layer.id), locked: layer.locked, printing: layer.printing, keyline: layer.keyline,
                highlight: layer.highlight.map(Appearances.color) ?? .black, isGuides: layer.role == .guides
            )
            var items: [(item: DisplayItem, node: NodeID?)] = []
            if layer.visible || includeHidden {
                let layerTransform = PathEditing.transform(state.props(layer.id).layer.common.transform)
                let context = Placing(layer: layer.id, locked: layer.locked)
                for child in order.objects(on: layer.id, in: state) {
                    guard let item = place(child, state: state, parentTransform: layerTransform, itemPath: [next], parent: nil, context: context,
                                           objects: &objects) else { continue }
                    items.append((item, NodeID(child)))
                    topLevel.append(NodeID(child))
                    next += 1
                }
            }
            contents.append(LayerContent(layer: rendering, visible: layer.visible, items: items))
        }
        return (contents, topLevel)
    }

    /// The symbols' artwork in symbol space (library.adoc, "Rendering"), recording each symbol's
    /// dependency on its master nodes and nested symbols, and each nested instance's on its
    /// symbol.  The version is the artwork's hash, so any edit under a symbol changes it.
    private mutating func buildLibrary(_ state: EngineState, dependencies: inout DependencyIndex) -> SymbolLibrary {
        var artworks: [SymbolArtwork] = []
        var nested: [(instance: OpID, symbol: OpID)] = []
        for symbol in Symbols.symbols(in: state) {
            let props = state.props(symbol).symbol
            let nodes = state.liveChildren(symbol).compactMap { symbolNode($0, state: state, parentTransform: .identity, nested: &nested) }
            var hasher = Hasher()
            hasher.combine(nodes)
            artworks.append(SymbolArtwork(symbol: NodeID(symbol), name: props.common.name, version: UInt64(bitPattern: Int64(hasher.finalize())),
                                          origin: Point(x: props.origin.x, y: props.origin.y), nodes: nodes))
        }
        let library = SymbolLibrary(artworks)
        for symbol in library.symbols.keys {
            library.addDependencies(of: symbol, on: symbol, to: &dependencies)
        }
        for (instance, symbol) in nested {
            dependencies.add(NodeID(instance), dependsOn: NodeID(symbol))
        }
        return library
    }

    /// One node of a symbol's artwork with the enclosing groups' transforms flattened into it.
    private mutating func symbolNode(_ node: OpID, state: EngineState, parentTransform: AffineTransform,
                                     nested: inout [(instance: OpID, symbol: OpID)]) -> SymbolNode? {
        guard let built = built(node, state: state) else { return nil }
        if var instance = built.instance {
            instance.transform = instance.transform.concatenating(parentTransform)
            nested += built.sources.map { (node, $0) }
            return SymbolNode(id: NodeID(node), content: .instance(instance))
        }
        if built.kind == .group {
            let transform = built.transform.concatenating(parentTransform)
            let members = state.liveChildren(node).compactMap { symbolNode($0, state: state, parentTransform: transform, nested: &nested) }
            return SymbolNode(id: NodeID(node), content: .group(GroupItem(children: []), members: members))
        }
        return built.item.map { SymbolNode(id: NodeID(node), content: .item($0.transformed(by: parentTransform))) }
    }

    /// What enclosing nodes pass down while placing.
    private struct Placing {
        var layer: OpID
        var locked: Bool
    }

    /// The item of `node` under `parentTransform`, recording it (and its members) in `objects`.
    private mutating func place(_ node: OpID, state: EngineState, parentTransform: AffineTransform, itemPath: [Int], parent: OpID?,
                                context: Placing, objects: inout [NodeID: SceneObject]) -> DisplayItem? {
        guard var built = built(node, state: state) else { return nil }
        let transform = built.transform.concatenating(parentTransform)
        let locked = context.locked || built.locked
        let item: DisplayItem
        if built.kind == .group {
            var children: [DisplayItem] = []
            let inner = Placing(layer: context.layer, locked: locked)
            for child in state.liveChildren(node) {
                if let placed = place(child, state: state, parentTransform: transform, itemPath: itemPath + [children.count], parent: node,
                                      context: inner, objects: &objects) {
                    children.append(placed)
                }
            }
            guard !children.isEmpty else { return nil }
            item = .group(GroupItem(children: children))
        } else {
            if built.item == nil, let instance = built.instance {
                built.item = symbolRenderer.item(for: instance, in: library)
                cache[node] = built
            }
            guard let own = built.item else { return nil }
            item = parentTransform.isIdentity ? own : own.transformed(by: parentTransform)
        }
        objects[NodeID(node)] = SceneObject(
            id: node, kind: built.kind, path: built.path, transform: transform, itemPath: itemPath, parent: parent,
            bounds: item.bounds, elementPoints: built.elementPoints, leafContours: built.leafContours, item: item,
            layer: context.layer, isLocked: built.locked, isEffectivelyLocked: locked
        )
        return item
    }

    /// `node`'s subtree drawn in its parent's space without recording scene objects (a chart's
    /// pictograph source).
    private mutating func detachedItem(_ node: OpID, state: EngineState) -> DisplayItem? {
        var scratch: [NodeID: SceneObject] = [:]
        return place(node, state: state, parentTransform: .identity, itemPath: [], parent: nil, context: Placing(layer: node, locked: false),
                     objects: &scratch)
    }

    private mutating func built(_ node: OpID, state: EngineState) -> Built? {
        if let cached = cache[node] { return cached }
        guard let kind = state.nodeKind(node), kind != .layer, kind != .symbol else { return nil }
        let props = state.props(node)
        guard let common = NodeValues.common(props), !common.hasCanvas else { return nil }
        let transform = PathEditing.transform(common.transform)
        var built = Built(item: nil, kind: kind, path: nil, transform: transform, elementPoints: [:], leafContours: [:], locked: common.locked)
        let order = AppearanceEditing.stack(node, in: state)
        switch props.kind {
        case .path(let path)?:
            let model = VectorPath(path, node: node, state: state)
            built.path = model
            Self.render(model, appearance: path.appearance, order: order, transform: transform, into: &built)
        case .rect(let rect)?:
            let model = ShapeGeometry.path(rect)
            built.path = model
            Self.render(model, appearance: rect.appearance, order: order, transform: transform, into: &built)
        case .ellipse(let ellipse)?:
            let model = ShapeGeometry.path(ellipse)
            built.path = model
            Self.render(model, appearance: ellipse.appearance, order: order, transform: transform, into: &built)
        case .polygon(let polygon)?:
            let model = ShapeGeometry.path(polygon)
            built.path = model
            Self.render(model, appearance: polygon.appearance, order: order, transform: transform, into: &built)
        case .instance(let instance)?:
            built.instance = Symbols.instanceSpec(node, transform: transform, in: state)
            built.sources = instance.hasSymbol ? [OpID(instance.symbol.id)] : []
        case .chart(let chart)?:
            // Pictograph sources are the chart's children: any node under it redraws it.
            built.sources = Array(Symbols.artworkNodes(of: node, in: state))
            let spec = Chart(chart).spec(node: node) { source in
                guard state.liveChildren(node).contains(source), let item = self.detachedItem(source, state: state) else { return nil }
                return [item]
            }
            built.item = spec.map { ChartLayout(spec: $0, typesetter: labels).displayItem(transform: transform) }
        case .barcode(let barcode)?:
            var spec = Barcodes.spec(barcode, appearance: Appearances.resolve(barcode.appearance, order: order))
            spec.transform = transform
            built.item = BarcodeRendering.item(spec)
        default:
            break
        }
        cache[node] = built
        return built
    }

    /// A path's display item: one `PathItem`, or -- when open contours must not show the fills
    /// that closed ones do -- a group of one item per attribute (the fills over the closed
    /// contours only), keeping the stack's order.
    private static func render(_ path: VectorPath, appearance: Wiretuner_Doc_V1_AppearanceProps, order: [AppearanceRow], transform: AffineTransform,
                               into built: inout Built) {
        guard path.isRenderable else { return }
        let all = display(path) { _ in true }
        let hasOpen = path.contours.contains { $0.isRenderable && !$0.closed }
        let hasClosed = path.contours.contains { $0.isRenderable && $0.closed }
        let resolved = Appearances.resolve(appearance, order: order, evenOdd: path.evenOdd)
        let hasFill = resolved.items.contains { if case .fill = $0 { return true } else { return false } }
        guard hasOpen, !path.fillWhenOpen, hasFill else {
            built.item = .path(PathItem(path: all.path, appearance: resolved, transform: transform))
            built.elementPoints = [[]: all.points]
            built.leafContours = [[]: all.contours]
            return
        }
        guard hasClosed else {
            built.item = .path(PathItem(path: all.path, appearance: Appearances.resolve(appearance, order: order, evenOdd: path.evenOdd, paintsFill: false), transform: transform))
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
