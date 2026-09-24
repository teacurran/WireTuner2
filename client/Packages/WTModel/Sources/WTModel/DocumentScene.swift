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
/// their `ChartLayout` (DRAW-032), barcodes their bars (DATA-018).  Colours resolve through one
/// `ColorResolver` per build (`ColorResolver.current`): a swatch reference shows the swatch's
/// colour as it is now, and colours from spot swatches carry their ink (PRINT-007).  Items for
/// nodes a change did not touch are reused; a change's touched nodes are expanded through the
/// `DependencyIndex` (an edited symbol or master node reaches every instance of it, a
/// pictograph's nodes their chart) and a touched swatch through the `SwatchIndex` (every object
/// using it or a tint of it, COLOR-006), and every change yields a `ChangeSummary` for the
/// invalidation pipeline.  Background items (the page furniture the window
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
    /// How text nodes are laid out and drawn (`TextSceneLayout`); nil draws no text.
    public var textLayout: TextSceneLayout?
    /// Node → the nodes drawn from it, as of the last build: a symbol from its master nodes and
    /// nested symbols, an instance from its symbol, a chart from its pictograph nodes.
    public private(set) var dependencies = DependencyIndex()
    /// The document's symbols as of the last build.
    public private(set) var library = SymbolLibrary([])
    /// Swatch → the objects using it, kept from the changes `apply` sees (read in full by
    /// `rebuild` and `reload`, or on the first `apply`).
    public private(set) var swatchIndex: SwatchIndex?
    private var cache: [OpID: Built] = [:]
    private let symbolRenderer = SymbolRenderer()
    private let labels = CoreTextLabels()
    /// While building: the layer list, each connector end's attachment bounds so far, and the
    /// connectors being routed (a connector inside a group it is attached to is left out of that
    /// group's bounds while it is routed).
    private var building: LayerOrder?
    private var attachments: [OpID: Rect?] = [:]
    private var routing: Set<OpID> = []
    /// While building: each layer's transform, read once.
    private var layerTransforms: [OpID: AffineTransform] = [:]
    /// Each connector as stored (`Connectors.storedSpec`) with its own `locked`, kept until the
    /// connector itself is touched: a connector rerouted because an object it joins changed
    /// re-checks its ends against the document and is routed again without reading its registers.
    private var connectors: [OpID: StoredConnector] = [:]

    private struct StoredConnector: Sendable {
        var spec: ConnectorSpec
        var locked: Bool
    }

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
        /// A leaf's item as last placed and its bounds, with the enclosing transform it was placed
        /// under: reused while that transform is the same.
        var placed: Placed?
        /// A group's own attribute stack (its effects apply to the group as one shape, FX-002).
        var groupAppearance = Appearance()
        /// A blend or extrusion, drawn as a group with a live drawing (FX-024, FX-017).
        var wrapper: WrapperKind?

        /// A group, blend or extrusion: its item is made of its children's.
        var drawsChildren: Bool { kind == .group || wrapper != nil }
    }

    private struct Placed: Sendable {
        var parentTransform: AffineTransform
        var item: DisplayItem
        var bounds: Rect?
        /// Where a connector end attaches to the item (`Connectors.attachmentBounds`), once asked.
        var attachment: Rect??
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
        connectors = [:]
        swatchIndex = SwatchIndex(state)
        scene = build(state)
        return scene
    }

    /// Rebuilds everything from `state` after the document's state was replaced wholesale
    /// (`Document.reload`): no cached item survives, and the summary is structural and names every
    /// object drawn before or after with its bounds, so every tile they touch repaints.
    public mutating func reload(_ state: EngineState, origin: ChangeOrigin = .remote) -> (DocumentScene, ChangeSummary) {
        let before = scene
        cache = [:]
        connectors = [:]
        swatchIndex = SwatchIndex(state)
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
    /// rebuilds and names the objects using it, directly or through a tint of it
    /// (`recoloured(by:)`); every other item is reused.
    public mutating func apply(_ change: Wiretuner_Doc_V1_Change, state: EngineState, origin: ChangeOrigin) -> (DocumentScene, ChangeSummary) {
        var touched: [OpID: [FieldPath]] = [:]
        for op in change.ops {
            for (node, fields) in Self.targets(op) { touched[node, default: []] += fields }
        }
        for (op, id) in zip(change.ops, change.opIDs) {
            if case .create = op.op { touched[id, default: []] += [] }
        }
        let recoloured = recoloured(by: change, state: state)
        return update(touched: touched, also: recoloured, state: state, origin: origin)
    }

    /// Rebuilds `nodes` and everything drawn from them without a change to the document: text
    /// whose fonts now resolve differently (`DocumentFontIndex.fontsChanged`), a placed file whose
    /// preview arrived.  The summary names them with their bounds before and after.
    public mutating func invalidate(_ nodes: Set<OpID>, state: EngineState, origin: ChangeOrigin = .local) -> (DocumentScene, ChangeSummary) {
        update(touched: Dictionary(uniqueKeysWithValues: nodes.map { ($0, []) }), also: [], state: state, origin: origin)
    }

    private mutating func update(touched: [OpID: [FieldPath]], also recoloured: Set<OpID>, state: EngineState,
                                 origin: ChangeOrigin) -> (DocumentScene, ChangeSummary) {
        let before = scene
        // The document's raster effect resolution reaches every object (FX-007).
        if touched[WellKnown.settings]?.contains(where: { FieldPath(fields: 2, 90).contains($0) }) == true {
            cache = [:]
        }
        let seeds = Set(touched.keys).union(recoloured)
        let dependents = dependencies.dependents(of: seeds.map(NodeID.init))
        for node in seeds {
            cache[node] = nil
            connectors[node] = nil
        }
        for node in dependents { cache[OpID(node)] = nil }
        scene = build(state)
        var summary = ChangeSummary(origin: origin, isStructural: before.displayList.nodeIDs != scene.displayList.nodeIDs
            || before.objects.mapValues(\.itemPath) != scene.objects.mapValues(\.itemPath))
        var affected = Set(seeds.map(NodeID.init)).union(dependents).union(dependencies.dependents(of: seeds.map(NodeID.init)))
        let all = before.objects.merging(scene.objects, uniquingKeysWith: { $1 })
        // A touched group moves its members; a touched layer everything on it.
        for (id, object) in all {
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

    /// The nodes whose colours `change` altered by touching a swatch: every node using a touched
    /// swatch -- directly, as an unnamed tint's base, or through a chain of tint swatches -- read
    /// from `swatchIndex` after it takes the change.  Tint swatches themselves are not drawn and
    /// are left out.
    private mutating func recoloured(by change: Wiretuner_Doc_V1_Change, state: EngineState) -> Set<OpID> {
        var index = swatchIndex ?? SwatchIndex(state)
        if swatchIndex != nil { index.refresh(ColorUses.touched(by: change), in: state) }
        swatchIndex = index
        var pending = ColorUses.touched(by: change).filter { state.store.kind($0) == SwatchFields.kind }
        var seen = Set(pending)
        var result: Set<OpID> = []
        while let swatch = pending.popFirst() {
            for use in index.dependents(of: swatch) {
                if use.location == .tintBase {
                    if seen.insert(use.node).inserted { pending.insert(use.node) }
                } else {
                    result.insert(use.node)
                }
            }
        }
        return result
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

    // MARK: Output

    /// The list print and export draw (layers.adoc, "Printing"): printing, non-Guides layers
    /// only, hidden ones only with `includeHidden`, no dimming or keyline.  Built from the same
    /// cached items as the canvas; the scene is not changed.
    public mutating func outputDisplayList(_ state: EngineState, includeHidden: Bool = false) -> DisplayList {
        begin(state)
        defer { end() }
        return ColorResolver.$current.withValue(ColorResolver(state)) {
            var scratch: [NodeID: SceneObject] = [:]
            let order = LayerOrder(state)
            let context = sceneContext(state)
            let contents = SceneContext.$current.withValue(context) {
                layerContents(state, order: order, includeHidden: includeHidden, objects: &scratch).contents
            }
            return LayerScene.build(canvas: canvas, layers: contents, purpose: .output(includeHidden: includeHidden), background: [])
        }
    }

    // MARK: Building

    private mutating func build(_ state: EngineState) -> DocumentScene {
        begin(state)
        defer { end() }
        return ColorResolver.$current.withValue(ColorResolver(state)) { buildScene(state) }
    }

    private mutating func begin(_ state: EngineState) {
        building = LayerOrder(state)
        attachments = [:]
        layerTransforms = [:]
    }

    private mutating func end() {
        building = nil
        attachments = [:]
        layerTransforms = [:]
    }

    /// `layer`'s own transform, read once per build.
    private mutating func layerTransform(_ layer: OpID, state: EngineState) -> AffineTransform {
        if let known = layerTransforms[layer] { return known }
        let transform = PathEditing.transform(state.props(layer).layer.common.transform)
        layerTransforms[layer] = transform
        return transform
    }

    private mutating func buildScene(_ state: EngineState) -> DocumentScene {
        var index = DependencyIndex()
        library = buildLibrary(state, dependencies: &index)
        var objects: [NodeID: SceneObject] = [:]
        let order = LayerOrder(state)
        let context = sceneContext(state)
        let (contents, topLevel) = SceneContext.$current.withValue(context) {
            layerContents(state, order: order, includeHidden: false, objects: &objects)
        }
        for (node, built) in cache where objects[NodeID(node)] != nil {
            for source in built.sources { index.add(NodeID(node), dependsOn: NodeID(source)) }
        }
        // A brush redraws its strokes when one of its symbols changes (ATTR-008).
        for entry in Brushes.list(state) {
            for symbol in entry.symbols { library.addDependencies(of: NodeID(entry.id), on: NodeID(symbol), to: &index) }
        }
        dependencies = index
        let list = LayerScene.build(canvas: canvas, layers: contents, purpose: .screen(guideColor: guideColor), background: background)
        return DocumentScene(displayList: list, objects: objects, topLevel: topLevel, layers: order)
    }

    /// What the build resolves once for every object: the document's raster settings and its
    /// brushes with their symbols' artwork (`library` must be current).
    private func sceneContext(_ state: EngineState) -> SceneContext {
        SceneContext(raster: SceneContext.raster(state), brushes: Brushes.resolve(state, library: library, renderer: symbolRenderer))
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
                let layerTransform = layerTransform(layer.id, state: state)
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
        if built.drawsChildren {
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
        let bounds: Rect?
        if built.drawsChildren {
            var children: [DisplayItem] = []
            var placedIDs: [OpID] = []
            let inner = Placing(layer: context.layer, locked: locked)
            for child in built.wrapper.map({ Wrappers.drawOrder(node, $0, in: state) }) ?? state.liveChildren(node) {
                if let placed = place(child, state: state, parentTransform: transform, itemPath: itemPath + [children.count], parent: node,
                                      context: inner, objects: &objects) {
                    children.append(placed)
                    placedIDs.append(child)
                }
            }
            guard !children.isEmpty else { return nil }
            let live = built.wrapper.map { Wrappers.live($0, node: node, children: placedIDs, in: state) { self.cache[$0]?.path } }
            item = .group(GroupItem(children: children, appearance: built.groupAppearance, live: live))
            bounds = item.bounds
        } else if let placed = built.placed, placed.parentTransform == parentTransform {
            item = placed.item
            bounds = placed.bounds
        } else {
            if built.item == nil, let instance = built.instance {
                built.item = symbolRenderer.item(for: instance, in: library)
                cache[node] = built
            }
            guard let own = built.item else { return nil }
            // A connector is routed in pasteboard space: enclosing transforms do not apply.
            item = parentTransform.isIdentity || built.kind == .connector ? own : own.transformed(by: parentTransform)
            bounds = item.bounds
            // Not kept for a connector left out of a group while it is routed (not cached).
            if cache[node] != nil {
                built.placed = Placed(parentTransform: parentTransform, item: item, bounds: bounds)
                cache[node] = built
            }
        }
        objects[NodeID(node)] = SceneObject(
            id: node, kind: built.kind, path: built.path, transform: built.kind == .connector ? .identity : transform, itemPath: itemPath, parent: parent,
            bounds: bounds, elementPoints: built.elementPoints, leafContours: built.leafContours, item: item,
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
        // A connector reached again while it is being routed (it is inside a group it is
        // attached to) draws nothing in that group's bounds.
        if routing.contains(node) { return Built(item: nil, kind: .connector, path: nil, transform: .identity, elementPoints: [:], leafContours: [:]) }
        if let stored = connectors[node] {
            let built = routed(node, stored, state: state)
            cache[node] = built
            return built
        }
        if let wrapper = WrapperKind.of(node, in: state) {
            let props = state.props(node)
            guard let common = NodeValues.common(props), !common.hasCanvas else { return nil }
            let built = Built(item: nil, kind: wrapper.nodeKind, path: nil, transform: PathEditing.transform(common.transform), elementPoints: [:],
                              leafContours: [:], locked: common.locked, wrapper: wrapper)
            cache[node] = built
            return built
        }
        guard let kind = state.nodeKind(node), kind != .layer, kind != .symbol else { return nil }
        let props = EffectReading.completingSets(state.props(node), node: node, in: state)
        guard let common = NodeValues.common(props), !common.hasCanvas else { return nil }
        let transform = PathEditing.transform(common.transform)
        var built = Built(item: nil, kind: kind, path: nil, transform: transform, elementPoints: [:], leafContours: [:], locked: common.locked)
        let order = AppearanceEditing.stack(node, in: state)
        switch props.kind {
        case .path(let path)?:
            let model = VectorPath(path, node: node, state: state)
            built.path = model
            Self.render(model, appearance: path.appearance, order: order, transform: transform, into: &built)
        case .rect(var rect)?:
            // A Corners effect takes precedence over the rectangle's own radii (FX-046).
            if EffectLowering.hasCorners(rect.appearance) { rect.clearCorners() }
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
        case .connector(let connector)?:
            let stored = StoredConnector(spec: Connectors.storedSpec(node, connector, appearance: Appearances.resolve(connector.appearance, order: order)),
                                         locked: common.locked)
            connectors[node] = stored
            built = routed(node, stored, state: state)
        case .text?:
            built.item = textLayout?.item(node, state: state)
        case .placedFile(let placed)?:
            built.item = PlacedFileDrawing.item(PlacedFiles.placedFile(placed, transform: transform))
        case .group(let group)?:
            built.groupAppearance = Appearances.resolve(group.appearance, order: order)
        default:
            break
        }
        built.sources += Brushes.referenced(NodeValues.appearance(props))
        cache[node] = built
        return built
    }

    /// Connector `node` routed from its stored form: `common.transform` is ignored, the route is
    /// derived in pasteboard space from the ends and the rendered bounds of the objects they are
    /// attached to (DRAW-035/037); its sources are the nodes the stored ends name, their ancestors
    /// and their descendants (`Connectors.dependencySources`).
    private mutating func routed(_ node: OpID, _ stored: StoredConnector, state: EngineState) -> Built {
        var built = Built(item: nil, kind: .connector, path: nil, transform: .identity, elementPoints: [:], leafContours: [:], locked: stored.locked)
        built.sources = Connectors.dependencySources(of: node, targets: [stored.spec.start.node, stored.spec.end.node].compactMap { $0.map(OpID.init) },
                                                     in: state)
        let layers = building ?? LayerOrder(state)
        let spec = Connectors.attached(stored.spec, in: state, layers: layers)
        routing.insert(node)
        var bounds: [NodeID: Rect] = [:]
        for target in [spec.start.node, spec.end.node].compactMap({ $0 }) {
            bounds[target] = attachmentBounds(OpID(target), state: state, layers: layers)
        }
        routing.remove(node)
        built.item = ConnectorRendering.item(spec, route: ConnectorRouter.route(spec) { bounds[$0] })
        return built
    }

    /// The rendered bounds of `target` as the scene places it (enclosing groups and its layer's
    /// transform applied), grown by half its widest stroke: where a connector end attaches.  Nil
    /// when it draws nothing.  Memoized for the build.
    private mutating func attachmentBounds(_ target: OpID, state: EngineState, layers: LayerOrder) -> Rect? {
        if let known = attachments[target] { return known }
        var parentTransform = AffineTransform.identity
        var current = state.store.placement(target)?.parent
        while let id = current {
            if layers.all[id] != nil {
                let shown = layers.displayLayer(for: id) ?? id
                parentTransform = parentTransform.concatenating(layerTransform(shown, state: state))
                break
            }
            parentTransform = parentTransform.concatenating(Objects.transform(of: id, in: state))
            current = state.store.placement(id)?.parent
        }
        var scratch: [NodeID: SceneObject] = [:]
        let item = place(target, state: state, parentTransform: parentTransform, itemPath: [], parent: nil,
                         context: Placing(layer: target, locked: false), objects: &scratch)
        // A leaf placed under the same transform as before attaches where it did.
        let placed = cache[target]?.placed.flatMap { $0.parentTransform == parentTransform ? $0 : nil }
        if let known = placed?.attachment {
            attachments[target] = known
            return known
        }
        let rect = item.flatMap(Connectors.attachmentBounds(of:))
        if placed != nil { cache[target]?.placed?.attachment = .some(rect) }
        // Not memoized while a connector inside it is left out.
        if !routing.contains(where: { scratch[NodeID($0)] == nil && Self.isInside($0, target, state: state) }) {
            attachments[target] = rect
        }
        return rect
    }

    /// Whether `node` is `ancestor` or below it.
    private static func isInside(_ node: OpID, _ ancestor: OpID, state: EngineState) -> Bool {
        var current: OpID? = node
        while let id = current {
            if id == ancestor { return true }
            current = state.store.placement(id)?.parent
        }
        return false
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
        let corners = EffectLowering.cornerPoints(path)
        let resolved = Appearances.resolve(appearance, order: order, evenOdd: path.evenOdd, corners: corners)
        let hasFill = resolved.items.contains { if case .fill = $0 { return true } else { return false } }
        guard hasOpen, !path.fillWhenOpen, hasFill else {
            built.item = .path(PathItem(path: all.path, appearance: resolved, transform: transform))
            built.elementPoints = [[]: all.points]
            built.leafContours = [[]: all.contours]
            return
        }
        guard hasClosed else {
            built.item = .path(PathItem(path: all.path, appearance: Appearances.resolve(appearance, order: order, evenOdd: path.evenOdd, paintsFill: false,
                                                                                    corners: corners), transform: transform))
            built.elementPoints = [[]: all.points]
            built.leafContours = [[]: all.contours]
            return
        }
        let closed = display(path) { $0.closed }
        var children: [DisplayItem] = []
        for (index, element) in resolved.items.enumerated() {
            let source: (path: DisplayPath, points: [PointRef?], contours: [OpID])
            if case .fill = element { source = closed } else { source = all }
            built.elementPoints[[children.count]] = source.points
            built.leafContours[[children.count]] = source.contours
            // Each element keeps the effects attached to it; the object's own apply to the group.
            let attached = resolved.effects.filter { $0.target == .element(index) }.map { EffectElement($0.effect, target: .element(0), hidden: $0.hidden) }
            children.append(.path(PathItem(path: source.path, appearance: Appearance([element], effects: attached, raster: resolved.raster), transform: transform)))
        }
        let objectLevel = resolved.effects.filter { $0.target == .object }
        built.item = .group(GroupItem(children: children, appearance: Appearance(effects: objectLevel, raster: resolved.raster)))
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
