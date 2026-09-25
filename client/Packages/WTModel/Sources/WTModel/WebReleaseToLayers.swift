import WTCRDT
import WTGeometry
import WTInterchange
import WTProto
import WTRender

// WEB-015: menu:Extensions[Animate > Release to Layers…] (web/animation.adoc, "Releasing objects to
// layers", "Data model", "Merge semantics").  It writes ordinary nodes in one change: `CreateNode`
// for new frame layers (above the current layer), `MoveNode` for the released pieces, `CreateNode`
// for the copies Build, Drop and Trail make, and `SetDeleted` for a taken-apart container.  Every
// original piece is moved, never copied, so two replicas releasing the same group concurrently
// split the originals between their layer sets (LWW per piece) and each original exists once.

/// How the pieces are spread over the frame layers.
public enum ReleaseMode: Hashable, Sendable {
    /// Piece i alone on layer i.
    case sequence
    /// Pieces 0...i on layer i.
    case build
    /// Every piece but piece i on layer i.
    case drop
    /// Piece i on layer i and on the `n` layers after it.
    case trail(Int)

    /// The pieces frame layer `layer` holds, for `count` pieces, bottom first.
    public func pieces(onLayer layer: Int, count: Int) -> [Int] {
        switch self {
        case .sequence: return [layer]
        case .build: return Array(0...layer)
        case .drop: return (0..<count).filter { $0 != layer }
        case .trail(let n): return (max(0, layer - max(0, n))...layer).map { $0 }
        }
    }

    /// How many frame layers `count` pieces need.
    public func layerCount(_ count: Int) -> Int { count }
}

/// Why Release to Layers refused.
public enum ReleaseError: Error, Hashable, Sendable {
    /// Nothing selected can be released (no editable object, or a container with fewer than two
    /// pieces).
    case nothingToRelease
    case invalidTrail
}

/// One piece of a release: an existing object that moves (its transform re-expressed when its
/// container is taken apart) or new artwork baked from a blend step or a character.
enum ReleasePiece {
    case node(OpID, transform: AffineTransform?)
    case baked([NodeTree])
}

/// Release to Layers: the pieces of the selection, each on its own frame layer by `mode`.
/// "Release to Layers".
public struct ReleaseToLayers: Command {
    public var nodes: [OpID]
    public var mode: ReleaseMode
    public var reverse: Bool
    public var useExistingLayers: Bool
    public var sendToBack: Bool
    /// The current layer: frame layers are created above it, or with *Use existing layers*
    /// filled from it upward (the drawing layer when nil).
    public var currentLayer: OpID?
    /// The window's text layout (`DocumentFontIndex.layoutEngine`): a text block releases its
    /// characters only when given one; without it a text block is one piece.
    public var textLayout: TextSceneLayout?
    public var label: String { "Release to Layers" }

    public init(_ nodes: [OpID], mode: ReleaseMode, reverse: Bool = false, useExistingLayers: Bool = false, sendToBack: Bool = false,
                currentLayer: OpID? = nil, textLayout: TextSceneLayout? = nil) {
        self.textLayout = textLayout
        self.nodes = nodes
        self.mode = mode
        self.reverse = reverse
        self.useExistingLayers = useExistingLayers
        self.sendToBack = sendToBack
        self.currentLayer = currentLayer
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        if case .trail(let n) = mode, n < 1 { throw ReleaseError.invalidTrail }
        let selection = Objects.editable(nodes, in: state)
        guard !selection.isEmpty else { throw ReleaseError.nothingToRelease }
        var (pieces, containers) = try Self.pieces(selection, mode: mode, textLayout: textLayout, state: state, builder: &builder)
        guard !pieces.isEmpty, pieces.count >= 2 || containers.isEmpty else { throw ReleaseError.nothingToRelease }
        if reverse { pieces.reverse() }
        let order = LayerOrder(state)
        let current = currentLayer.flatMap { order.isLive($0) ? $0 : nil } ?? order.drawingLayer ?? order.defaultLayer
        let layers = try frameLayers(count: mode.layerCount(pieces.count), current: current, order: order, state: state, builder: &builder)
        // The first layer holding each piece receives the original; later layers get copies.
        var placed = Set<Int>()
        for (index, layer) in layers.enumerated() {
            let onLayer = mode.pieces(onLayer: index, count: pieces.count)
            let keys = try layer.keys(count: onLayer.count, sendToBack: sendToBack && useExistingLayers, state: state)
            for (piece, key) in zip(onLayer, keys) {
                let original = placed.insert(piece).inserted
                try Self.place(pieces[piece], original: original, layer: layer.id, key: key, state: state, builder: &builder)
            }
        }
        for container in containers { builder.append(Ops.setDeleted(container)) }
    }

    /// The frame layers: existing ones from `current` upward (with *Use existing layers*), then
    /// new ones named "Frame N", continuing from the highest existing "Frame N", stacked above
    /// the current layer (or above the last existing one used).
    func frameLayers(count: Int, current: OpID?, order: LayerOrder, state: EngineState, builder: inout ChangeBuilder) throws -> [FrameLayer] {
        var result: [FrameLayer] = []
        var above = current
        if useExistingLayers, let current, let start = order.index(of: current) {
            for layer in order.layers[start...] where layer.role == .ordinary && result.count < count {
                result.append(FrameLayer(id: layer.id, created: false))
                above = layer.id
            }
        }
        let missing = count - result.count
        guard missing > 0 else { return result }
        let keys: [[UInt8]] = if let above {
            try Arranging.keys(next: above, above: true, count: missing, in: state)
        } else {
            try PathEditing.keys(between: state.store.children(WellKnown.layers).last.flatMap { state.store.placement($0)?.position }, and: nil, count: missing)
        }
        var number = Self.highestFrameNumber(order)
        let printing = above.flatMap { order.layer($0)?.printing } ?? true
        for key in keys {
            number += 1
            let props = Layers.values { layer in
                layer.common.name = "Frame \(number)"
                layer.visible = true
                layer.printing = printing
            }
            let id = builder.append(Ops.create(parent: WellKnown.layers, position: key, props: props))
            result.append(FrameLayer(id: id, created: true))
        }
        return result
    }

    /// The highest N of the live layers named "Frame N" (0 when none).
    static func highestFrameNumber(_ order: LayerOrder) -> Int {
        order.layers.compactMap { layer -> Int? in
            guard layer.name.hasPrefix("Frame ") else { return nil }
            return Int(layer.name.dropFirst(6))
        }.max() ?? 0
    }

    /// A frame layer and whether this change creates it.
    struct FrameLayer {
        var id: OpID
        var created: Bool

        /// `count` position keys for pieces on the layer: in front of what it holds, or behind
        /// with `sendToBack`.
        func keys(count: Int, sendToBack: Bool, state: EngineState) throws -> [[UInt8]] {
            guard !created else { return try PathEditing.keys(between: nil, and: nil, count: count) }
            let children = state.store.children(id)
            if sendToBack {
                let first = children.first.flatMap { state.store.placement($0)?.position }
                return try PathEditing.keys(between: nil, and: first, count: count)
            }
            let last = children.last.flatMap { state.store.placement($0)?.position }
            return try PathEditing.keys(between: last, and: nil, count: count)
        }
    }

    // MARK: Pieces

    /// The pieces of the selection, bottom first, and the containers the release deletes.  A
    /// single selected group, blend or text block is taken apart; with several objects selected
    /// each is a piece, except that *Sequence* takes selected groups apart (a nested group is
    /// always one piece).  Blend ends stay where the blend was.
    static func pieces(_ selection: [OpID], mode: ReleaseMode, textLayout: TextSceneLayout?, state: EngineState, builder: inout ChangeBuilder) throws -> ([ReleasePiece], [OpID]) {
        let sorted = selection.sorted { a, b in
            let (ka, kb) = (stackingKey(a, state), stackingKey(b, state))
            return ka == kb ? a < b : ka.lexicographicallyPrecedes(kb) { $0.lexicographicallyPrecedes($1) }
        }
        var pieces: [ReleasePiece] = []
        var containers: [OpID] = []
        var built: DocumentScene?
        func scene() -> DocumentScene {
            if let built { return built }
            var builder = DocumentDisplayListBuilder(canvas: "release")
            builder.textLayout = textLayout
            let scene = builder.rebuild(state)
            built = scene
            return scene
        }
        let single = sorted.count == 1
        for node in sorted {
            switch state.nodeKind(node) {
            case .group? where single || mode == .sequence:
                let outer = Objects.transform(of: node, in: state)
                for member in state.liveChildren(node) where state.store.kind(member) != LayerFields.kind {
                    pieces.append(.node(member, transform: Objects.transform(of: member, in: state).concatenating(outer)))
                }
                containers.append(node)
            case .blend? where single:
                let steps = try blendSteps(node, scene: scene(), state: state, builder: &builder)
                pieces += steps.map(ReleasePiece.baked)
                containers.append(node)
            case .text? where single && textLayout != nil:
                pieces += characters(node, scene: scene()).map(ReleasePiece.baked)
                try detachPaths(of: node, state: state, builder: &builder)
                containers.append(node)
            default:
                pieces.append(.node(node, transform: nil))
            }
        }
        return (pieces, containers)
    }

    /// The stacking order of `node` among the selection: its layer's index, then its ancestors'
    /// sibling positions.
    static func stackingKey(_ node: OpID, _ state: EngineState) -> [[UInt8]] {
        var chain: [[UInt8]] = []
        var current: OpID? = node
        while let id = current, id.replica != 0 {
            chain.insert(state.store.placement(id)?.position ?? [], at: 0)
            current = state.store.placement(id)?.parent
        }
        return chain
    }

    /// The steps of a blend, one baked piece each, bottom first; its key objects (and joined path)
    /// move out to the blend's slot, where they stay.
    static func blendSteps(_ blend: OpID, scene: DocumentScene, state: EngineState, builder: inout ChangeBuilder) throws -> [[NodeTree]] {
        guard let parent = Objects.parent(of: blend, in: state) else { return [] }
        let children = state.liveChildren(blend)
        let path = BlendReading.path(state.props(blend).blend, children: children, in: state)
        let keys = children.filter { $0 != path }
        let steps = scene.object(blend).map { ReleaseBlendSteps.steps(of: $0, keys: keys, path: path, built: scene) } ?? []
        let outer = WrapperEditing.transform(blend, in: state)
        let ends = keys + (path.map { [$0] } ?? [])
        let positions = try Arranging.keys(next: blend, above: true, count: ends.count, in: state)
        for (child, position) in zip(ends, positions) {
            if !outer.isIdentity, let op = WrapperEditing.setTransform(child, Objects.transform(of: child, in: state).concatenating(outer), in: state) {
                builder.append(op)
            }
            builder.append(Ops.move(child, parent: parent, position: position))
        }
        return steps
    }

    /// The characters of a text block as outlines, one piece per glyph with ink, in layout
    /// order (menu:Text[Convert to Paths] per character).
    static func characters(_ node: OpID, scene: DocumentScene) -> [[NodeTree]] {
        guard let object = scene.object(node) else { return [] }
        var runs: [TextRunItem] = []
        func collect(_ item: DisplayItem) {
            switch item {
            case .text(let run): runs.append(run)
            case .group(let group): group.children.forEach(collect)
            default: break
            }
        }
        collect(object.item)
        var result: [[NodeTree]] = []
        for run in runs {
            guard let glyphs = run.glyphRun else { continue }
            for glyph in glyphs.glyphs {
                var one = run
                one.glyphRun = GlyphRun(font: glyphs.font, glyphs: [glyph])
                guard let ink = one.glyphRun?.inkBounds else { continue }
                one.bounds = ink
                let trees = Baking.trees([.text(one)])
                if !trees.isEmpty { result.append(trees) }
            }
        }
        return result
    }

    /// Moves (the original) or copies a piece onto `layer` at `key`.
    static func place(_ piece: ReleasePiece, original: Bool, layer: OpID, key: [UInt8], state: EngineState, builder: inout ChangeBuilder) throws {
        switch piece {
        case .node(let node, let transform):
            if original {
                if let transform, let kind = state.nodeKind(node) { builder.append(Objects.setTransform(node, kind: kind, transform)) }
                builder.append(Ops.move(node, parent: layer, position: key))
            } else {
                let copy = try NodeCopier.create(NodeTree(node, state: state), parent: layer, position: key, schema: state.schema, builder: &builder)
                if let transform, let kind = state.nodeKind(node) { builder.append(Objects.setTransform(copy, kind: kind, transform)) }
            }
        case .baked(let trees):
            if trees.count == 1 {
                try NodeCopier.create(trees[0], parent: layer, position: key, schema: state.schema, builder: &builder)
            } else {
                try Baking.createGroup(trees, parent: layer, position: key, state: state, builder: &builder)
            }
        }
    }
}

/// A blend's steps separated one per step (BlendBaking separates them per span): the whole
/// blend is expanded, each key object's share measured by expanding it alone and each span's
/// step size by expanding a one-step blend of its two ends.
enum ReleaseBlendSteps {
    static func steps(of blend: SceneObject, keys: [OpID], path: OpID?, built: DocumentScene) -> [[NodeTree]] {
        guard case .group(let group) = blend.item, case .blend(let spec) = group.live else { return [] }
        func child(_ id: OpID?) -> (index: Int, item: DisplayItem)? {
            guard let id, let object = built.object(id), Array(object.itemPath.dropLast()) == blend.itemPath, let index = object.itemPath.last,
                  group.children.indices.contains(index) else { return nil }
            return (index, group.children[index])
        }
        let placed = keys.compactMap(child)
        guard placed.count >= 2 else { return [] }
        let all = BlendBaking.flat([blend.item])
        let keyCounts = placed.map { BlendBaking.flat([$0.item]).count }
        let pathCount = child(path).flatMap { spec.showPath ? BlendBaking.flat([$0.item]).count : nil } ?? 0
        var perStep: [Int] = []
        for index in 1..<placed.count {
            let (a, b) = (placed[index - 1], placed[index])
            let points = spec.blendPoints.compactMap { point -> BlendPoint? in
                if point.child == a.index { return BlendPoint(child: 0, contour: point.contour, anchor: point.anchor) }
                if point.child == b.index { return BlendPoint(child: 1, contour: point.contour, anchor: point.anchor) }
                return nil
            }
            let one = BlendSpec(steps: 1, rangeFirst: 0, rangeLast: 100, type: spec.type, order: spec.order, blendPoints: points)
            perStep.append(BlendBaking.flat([.group(GroupItem(children: [a.item, b.item], live: .blend(one)))]).count - keyCounts[index - 1] - keyCounts[index])
        }
        let stepNodes = all.count - pathCount - keyCounts.reduce(0, +)
        let unit = perStep.reduce(0, +)
        guard unit > 0, stepNodes > 0, stepNodes % unit == 0 else { return [] }
        let count = stepNodes / unit
        var index = pathCount + keyCounts[0]
        var steps: [[NodeTree]] = []
        for (span, size) in perStep.enumerated() {
            for _ in 0..<count {
                let trees = all[index..<(index + size)].flatMap(Baking.tree)
                if !trees.isEmpty { steps.append(trees) }
                index += size
            }
            index += keyCounts[span + 1]
        }
        return steps
    }
}
