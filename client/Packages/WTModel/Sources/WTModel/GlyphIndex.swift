import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

// FONT-002 / FONT-008 / FONT-012 / FONT-013: typed glyphs and the glyph index with every read-time
// normalization of glyph-grid.adoc and glyph-editing.adoc: name and codepoint collisions (the
// smaller node id keeps the claim), invalid names, kind and advance defaults, component loops (cut
// at the smallest element id along the cycle), dangling components, anchor name collisions (the
// smaller element id keeps the name), anchor roles from the underscore convention, non-finite
// anchor positions.  Nothing here writes.

/// A glyph's role in the font (`GlyphKind`; unset reads as base).
public enum GlyphKind: Hashable, Sendable, CaseIterable {
    case base, mark, ligature, component

    public init(stored: Wiretuner_Doc_V1_GlyphKind) {
        switch stored {
        case .mark: self = .mark
        case .ligature: self = .ligature
        case .component: self = .component
        default: self = .base
        }
    }

    public var stored: Wiretuner_Doc_V1_GlyphKind {
        switch self {
        case .base: .base
        case .mark: .mark
        case .ligature: .ligature
        case .component: .component
        }
    }
}

/// A component as read.
public struct GlyphComponent: Hashable, Sendable, Identifiable {
    /// How the component reads.
    public enum Status: Hashable, Sendable {
        /// Its source glyph is live: it draws the source's outline.
        case resolved
        /// Its source is deleted, unknown or not a glyph: a placeholder from `cached`.
        case dangling
        /// It closes a component loop and was cut there: a placeholder labelled "loop".
        case loop
    }

    public var id: OpID
    /// The source glyph as stored (nil when unset).
    public var source: OpID?
    /// Placement in glyph-canvas space.
    public var transform: WTGeometry.AffineTransform
    public var status: Status
    /// The source's outline at add time (`NodeRef.cached`), for placeholders and Decompose.
    public var cached: Data
}

/// Where a mark attaches (`AnchorRole`).
public enum GlyphAnchorRole: Hashable, Sendable {
    /// Marks attach to this glyph here ("top").
    case base
    /// This mark attaches to a base here ("_top").
    case mark

    /// The role the underscore convention gives `name`.
    public static func conventional(_ name: String) -> GlyphAnchorRole {
        name.hasPrefix("_") ? .mark : .base
    }

    var stored: Wiretuner_Doc_V1_AnchorRole {
        self == .base ? .base : .mark
    }
}

/// An anchor as read.
public struct GlyphAnchorValue: Hashable, Sendable, Identifiable {
    public var id: OpID
    /// The effective name: the stored one, or `<name>.dup<n>` for all but the smallest element
    /// id among anchors of one glyph sharing a name.
    public var name: String
    public var storedName: String
    /// Glyph-canvas space; a non-finite stored position reads as (0, 0).
    public var position: Point
    /// The explicit role, else the underscore convention.
    public var role: GlyphAnchorRole
    public var isDuplicate: Bool

    /// The attachment name: "top" for both "top" and "_top".
    public var attachmentName: String {
        name.hasPrefix("_") ? String(name.dropFirst()) : name
    }
}

/// A glyph as read, with every normalization applied.
public struct Glyph: Hashable, Sendable, Identifiable {
    /// Why the effective name differs from the stored one.
    public enum NameStatus: Hashable, Sendable {
        case stored
        /// Another live glyph with a smaller node id holds the name: reads `<name>.dup…`.
        case duplicate
        /// Empty or invalid (an older client): reads `glyph<counter>_<replica>`.
        case invalid
    }

    public var id: OpID
    /// 1-based index among the live glyphs in sibling order (the Custom grid order).
    public var order: Int
    public var name: String
    public var storedName: String
    public var nameStatus: NameStatus
    /// The codepoints this glyph holds after the collision rule, ascending.
    public var codepoints: [UInt32]
    /// Every codepoint in the SET, ascending, including those another glyph keeps.
    public var storedCodepoints: [UInt32]
    /// Font units; a non-finite value reads as 0.
    public var advanceWidth: Double
    public var kind: GlyphKind
    public var components: [GlyphComponent]
    public var anchors: [GlyphAnchorValue]
    public var skipExport: Bool
    public var guides: [PageGuide]
    /// 0 ... 12; 0 = none.
    public var markColor: Int
    public var note: String

    /// The codepoints another glyph keeps.
    public var lostCodepoints: [UInt32] {
        storedCodepoints.filter { !codepoints.contains($0) }
    }

    /// Whether any read-time rule changed what the grid shows (the cell's badge).
    public var hasCollision: Bool {
        nameStatus != .stored || !lostCodepoints.isEmpty
    }

    /// The anchor named `name` (effective names).
    public func anchor(named name: String) -> GlyphAnchorValue? {
        anchors.first { $0.name == name }
    }

    /// The characters a ligature stands for by its name (`f_i` → f, i), when every part is a
    /// glyph name in `index`.
    public func ligatureParts(in index: GlyphIndex) -> [OpID]? {
        let parts = GlyphNaming.ligatureParts(name)
        guard kind == .ligature, parts.count > 1 else { return nil }
        let ids = parts.compactMap { index.glyph(named: $0)?.id }
        return ids.count == parts.count ? ids : nil
    }
}

/// The document's glyphs in grid order, with name → glyph and codepoint → glyph maps built after
/// the collision rules.  Built from the whole state in one pass (a 3,000-glyph font reads in a few
/// milliseconds), so every replica derives the same maps from the same state.
public struct GlyphIndex: Hashable, Sendable {
    /// The live glyphs in grid order.
    public let glyphs: [Glyph]
    private let byID: [OpID: Int]
    private let byName: [String: Int]
    private let byCodepoint: [UInt32: Int]
    /// Stored names held by more than one live glyph, with the glyphs smallest id first.
    public let nameCollisions: [String: [OpID]]
    /// Codepoints claimed by more than one live glyph, with the glyphs smallest id first.
    public let codepointCollisions: [UInt32: [OpID]]

    public init(_ state: EngineState) {
        let nodes = state.liveChildren(WellKnown.glyphs).filter { state.store.kind($0) == GlyphFields.kind }
        let props = nodes.map { state.props($0).glyph }
        // Names: the smaller node id keeps a stored name.
        var claims: [String: [OpID]] = [:]
        for (node, glyph) in zip(nodes, props) where GlyphNaming.isValid(glyph.name) {
            claims[glyph.name, default: []].append(node)
        }
        for key in claims.keys { claims[key]!.sort() }
        // Codepoints: the smaller node id keeps a claimed scalar.
        let stored = nodes.map { Self.codepoints(of: $0, in: state) }
        var holders: [UInt32: [OpID]] = [:]
        for (node, scalars) in zip(nodes, stored) {
            for scalar in scalars { holders[scalar, default: []].append(node) }
        }
        for key in holders.keys { holders[key]!.sort() }
        let loops = Self.componentLoops(nodes: nodes, props: props, state: state)
        var glyphs: [Glyph] = []
        for (offset, node) in nodes.enumerated() {
            let glyph = props[offset]
            let name: String
            let status: Glyph.NameStatus
            if !GlyphNaming.isValid(glyph.name) {
                name = "glyph\(node.counter)_\(String(node.replica, radix: 16))"
                status = .invalid
            } else if claims[glyph.name]?.first != node {
                name = "\(glyph.name).dup\(node.counter)_\(String(node.replica, radix: 16))"
                status = .duplicate
            } else {
                name = glyph.name
                status = .stored
            }
            glyphs.append(Glyph(
                id: node, order: offset + 1, name: name, storedName: glyph.name, nameStatus: status,
                codepoints: stored[offset].filter { holders[$0]?.first == node }, storedCodepoints: stored[offset],
                advanceWidth: glyph.advanceWidth.isFinite ? glyph.advanceWidth : 0, kind: GlyphKind(stored: glyph.kind),
                components: Self.components(glyph.components, loops: loops, state: state), anchors: Self.anchors(glyph.anchors),
                skipExport: glyph.skipExport, guides: PageGuide.read(glyph.guides), markColor: Int(min(glyph.markColor, 12)),
                note: glyph.common.note
            ))
        }
        self.glyphs = glyphs
        byID = Dictionary(uniqueKeysWithValues: glyphs.enumerated().map { ($1.id, $0) })
        byName = Dictionary(glyphs.enumerated().map { ($1.name, $0) }) { first, _ in first }
        var codepoints: [UInt32: Int] = [:]
        for (index, glyph) in glyphs.enumerated() {
            for scalar in glyph.codepoints { codepoints[scalar] = index }
        }
        byCodepoint = codepoints
        nameCollisions = claims.filter { $0.value.count > 1 }
        codepointCollisions = holders.filter { $0.value.count > 1 }
    }

    public var isEmpty: Bool { glyphs.isEmpty }
    public var count: Int { glyphs.count }

    public subscript(id: OpID) -> Glyph? {
        byID[id].map { glyphs[$0] }
    }

    /// The glyph whose effective name is `name`.
    public func glyph(named name: String) -> Glyph? {
        byName[name].map { glyphs[$0] }
    }

    /// The glyph that keeps `scalar`.
    public func glyph(for scalar: UInt32) -> Glyph? {
        byCodepoint[scalar].map { glyphs[$0] }
    }

    /// Every effective name.
    public var names: Set<String> {
        Set(byName.keys)
    }

    /// Whether `name` is held by a live glyph other than `except` (by stored name, so a `.dup`
    /// glyph still holds the name it claimed).
    public func isNameTaken(_ name: String, except: OpID? = nil) -> Bool {
        glyphs.contains { $0.id != except && ($0.storedName == name || $0.name == name) }
    }

    /// The glyph other than `except` whose SET holds `scalar`.
    public func holder(of scalar: UInt32, except: OpID? = nil) -> Glyph? {
        glyphs.first { $0.id != except && $0.storedCodepoints.contains(scalar) }
    }

    /// The live glyphs another glyph uses as a component (resolved components).
    public func users(of glyph: OpID) -> [Glyph] {
        glyphs.filter { user in user.components.contains { $0.status == .resolved && $0.source == glyph } }
    }

    // MARK: Reading

    /// The members of the `codepoints` SET of `node`, ascending: big-endian uint64 values, those
    /// above U+10FFFF left out.
    static func codepoints(of node: OpID, in state: EngineState) -> [UInt32] {
        state.store.members(node, GlyphFields.codepoints).compactMap { member in
            guard member.count == 8 else { return nil }
            let value = member.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return value <= 0x10FFFF ? UInt32(value) : nil
        }
    }

    /// Whether `node` is a live glyph under 0:11.
    static func isLiveGlyph(_ node: OpID, in state: EngineState) -> Bool {
        state.store.kind(node) == GlyphFields.kind && state.isLive(node) && state.store.placement(node)?.parent == WellKnown.glyphs
    }

    static func components(_ stored: [Wiretuner_Doc_V1_Component], loops: Set<OpID>, state: EngineState) -> [GlyphComponent] {
        stored.map { component in
            let id = OpID(sequenceElement: component.id)
            let source = component.hasGlyph && component.glyph.hasID ? OpID(component.glyph.id) : nil
            let status: GlyphComponent.Status
            if loops.contains(id) {
                status = .loop
            } else if let source, isLiveGlyph(source, in: state) {
                status = .resolved
            } else {
                status = .dangling
            }
            let transform = component.hasTransform ? PathEditing.transform(component.transform) : .identity
            return GlyphComponent(id: id, source: source, transform: transform.isFiniteTransform ? transform : .identity, status: status,
                                  cached: component.glyph.cached)
        }
    }

    static func anchors(_ stored: [Wiretuner_Doc_V1_GlyphAnchor]) -> [GlyphAnchorValue] {
        var values: [GlyphAnchorValue] = stored.map { anchor in
            let id = OpID(sequenceElement: anchor.id)
            let position = anchor.position.x.isFinite && anchor.position.y.isFinite ? Point(x: anchor.position.x, y: anchor.position.y) : .zero
            let role: GlyphAnchorRole
            switch anchor.role {
            case .base: role = .base
            case .mark: role = .mark
            default: role = .conventional(anchor.name)
            }
            return GlyphAnchorValue(id: id, name: anchor.name, storedName: anchor.name, position: position, role: role, isDuplicate: false)
        }
        // The smallest element id keeps a shared name; the others read `<name>.dup<n>`.
        let groups = Dictionary(grouping: values.indices, by: { values[$0].storedName })
        for (_, indices) in groups where indices.count > 1 {
            let ordered = indices.sorted { values[$0].id < values[$1].id }
            for (rank, index) in ordered.dropFirst().enumerated() {
                values[index].name = "\(values[index].storedName).dup\(rank + 1)"
                values[index].isDuplicate = true
            }
        }
        return values
    }

    /// The component elements cut to break loops: while the resolved component graph has a
    /// cycle, the element with the smallest element id along it is cut.  Cycles are searched in
    /// node-id order so every replica cuts the same elements.
    static func componentLoops(nodes: [OpID], props: [Wiretuner_Doc_V1_GlyphProps], state: EngineState) -> Set<OpID> {
        var edges: [OpID: [(element: OpID, target: OpID)]] = [:]
        for (node, glyph) in zip(nodes, props) {
            edges[node] = glyph.components.compactMap { component in
                guard component.hasGlyph, component.glyph.hasID else { return nil }
                let target = OpID(component.glyph.id)
                return isLiveGlyph(target, in: state) ? (OpID(sequenceElement: component.id), target) : nil
            }.sorted { $0.element < $1.element }
        }
        var cut: Set<OpID> = []
        while let cycle = findCycle(edges: edges, cut: cut, order: nodes.sorted()) {
            cut.insert(cycle.min()!)
        }
        return cut
    }

    /// The element ids of one cycle of the graph without `cut` edges, or nil.
    static func findCycle(edges: [OpID: [(element: OpID, target: OpID)]], cut: Set<OpID>, order: [OpID]) -> [OpID]? {
        var state: [OpID: Int] = [:]   // 1: on the stack, 2: done
        var stack: [(node: OpID, via: OpID?)] = []
        func visit(_ node: OpID, via: OpID?) -> [OpID]? {
            state[node] = 1
            stack.append((node, via))
            for edge in edges[node, default: []] where !cut.contains(edge.element) {
                switch state[edge.target] {
                case 1:
                    // The cycle: from the target's stack entry to here, plus this edge.
                    let start = stack.firstIndex { $0.node == edge.target }!
                    return stack[(start + 1)...].compactMap(\.via) + [edge.element]
                case nil:
                    if let found = visit(edge.target, via: edge.element) { return found }
                default:
                    break
                }
            }
            stack.removeLast()
            state[node] = 2
            return nil
        }
        for node in order where state[node] == nil {
            if let found = visit(node, via: nil) { return found }
        }
        return nil
    }
}

/// The objects-on-glyph query (typeface-documents.adoc, "Derived, never stored"): the live
/// top-level objects on live layers whose `canvas` is the glyph -- the query master pages use.
public enum GlyphArtwork {
    /// The objects on `glyph`, by layer in layer order, each layer's in stacking order.
    public static func objects(on glyph: OpID, in state: EngineState) -> [(layer: OpID, objects: [OpID])] {
        MasterContent.objects(of: glyph, in: state)
    }

    /// The objects on `glyph`, flattened in layer then stacking order.
    public static func objectIDs(on glyph: OpID, in state: EngineState) -> [OpID] {
        objects(on: glyph, in: state).flatMap(\.objects)
    }

    /// Every live glyph's objects in one pass over the layers.
    public static func objectsByGlyph(in state: EngineState) -> [OpID: [(layer: OpID, objects: [OpID])]] {
        var result: [OpID: [(layer: OpID, objects: [OpID])]] = [:]
        for layer in state.liveChildren(WellKnown.layers) where state.nodeKind(layer) == .layer {
            var onLayer: [OpID: [OpID]] = [:]
            var order: [OpID] = []
            for node in state.liveChildren(layer) {
                guard let common = NodeValues.common(state.props(node)), common.hasCanvas else { continue }
                let canvas = OpID(common.canvas.id)
                guard state.store.kind(canvas) == GlyphFields.kind else { continue }
                if onLayer[canvas] == nil { order.append(canvas) }
                onLayer[canvas, default: []].append(node)
            }
            for glyph in order { result[glyph, default: []].append((layer, onLayer[glyph]!)) }
        }
        return result
    }
}

extension WTGeometry.AffineTransform {
    /// Whether every coefficient is finite.
    var isFiniteTransform: Bool {
        [a, b, c, d, tx, ty].allSatisfy(\.isFinite)
    }
}
