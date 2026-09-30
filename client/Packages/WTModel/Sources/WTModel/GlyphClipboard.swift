import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

// FONT-008's clipboard (glyph-grid.adoc, "Acting on several glyphs" and "Adding glyphs"; glyph-editing.adoc,
// "Components"): menu:Edit[Copy] in the grid copies the selected glyphs -- artwork, metrics, components,
// anchors -- as a `GlyphClipboardPayload`; menu:Edit[Paste] replaces the artwork and metrics of a selection of
// the same count (`PasteGlyphs.replace`) or adds new glyphs (`PasteGlyphs.add`, a taken name gets `.1` and no
// codepoints); menu:Edit[Paste as Component] adds each copied glyph as a component of each target glyph at the
// origin (`PasteAsComponents`).

/// One copied glyph.
public struct CopiedGlyph: Hashable, Sendable {
    /// A copied component: its source by id (in the source document) and by name, its placement and the source's
    /// flattened outline (a component the destination cannot resolve is pasted as that outline, drawn).
    public struct Component: Hashable, Sendable {
        public var source: OpID?
        public var sourceName: String
        public var transform: WTGeometry.AffineTransform
        public var outline: Data

        public init(source: OpID?, sourceName: String, transform: WTGeometry.AffineTransform = .identity, outline: Data = Data()) {
            self.source = source
            self.sourceName = sourceName
            self.transform = transform
            self.outline = outline
        }
    }

    public struct Anchor: Hashable, Sendable {
        public var name: String
        /// Glyph-canvas space.
        public var position: Point
        public var role: GlyphAnchorRole

        public init(name: String, position: Point, role: GlyphAnchorRole) {
            self.name = name
            self.position = position
            self.role = role
        }
    }

    /// The glyph in the source document.
    public var source: OpID
    public var name: String
    public var codepoints: [UInt32]
    public var kind: GlyphKind
    public var advanceWidth: Double
    public var markColor: Int
    public var skipExport: Bool
    public var note: String
    public var components: [Component]
    public var anchors: [Anchor]
    /// The glyph's artwork, glyph space (one unit per point).
    public var objects: ClipboardPayload

    public init(source: OpID, name: String, codepoints: [UInt32] = [], kind: GlyphKind = .base, advanceWidth: Double = 0, markColor: Int = 0,
                skipExport: Bool = false, note: String = "", components: [Component] = [], anchors: [Anchor] = [],
                objects: ClipboardPayload = ClipboardPayload(nodes: [])) {
        self.source = source
        self.name = name
        self.codepoints = codepoints
        self.kind = kind
        self.advanceWidth = advanceWidth
        self.markColor = markColor
        self.skipExport = skipExport
        self.note = note
        self.components = components
        self.anchors = anchors
        self.objects = objects
    }
}

/// The glyph pasteboard payload: the copied glyphs in grid order and the source document.  Never stored in a
/// document.  Encoded by hand like `ClipboardPayload`: glyph 1 (repeated) holding source 1 (`OpId`), props 2
/// (`GlyphProps`: name, codepoints, advance width, kind, components with their cached outlines, anchors, export,
/// mark colour, note), objects 3 (a `ClipboardPayload`) and component names 4 (one per component, in order);
/// source_document 2.
public struct GlyphClipboardPayload: Hashable, Sendable {
    /// The pasteboard type.
    public static let pasteboardType = "com.villagecompute.wiretuner.glyphs"

    public var glyphs: [CopiedGlyph]
    public var sourceDocument: String

    public init(glyphs: [CopiedGlyph], sourceDocument: String = "") {
        self.glyphs = glyphs
        self.sourceDocument = sourceDocument
    }

    /// A copy of the live glyphs among `glyphs` of `state`, in grid order.
    public init(copying glyphs: [OpID], from state: EngineState, document: String = "") {
        let index = GlyphIndex(state)
        let wanted = Set(glyphs)
        let sources = GlyphOutlines.sources(in: state, index: index)
        let copied = index.glyphs.filter { wanted.contains($0.id) }.map { glyph in
            CopiedGlyph(
                source: glyph.id, name: glyph.name, codepoints: glyph.codepoints, kind: glyph.kind, advanceWidth: glyph.advanceWidth,
                markColor: glyph.markColor, skipExport: glyph.skipExport, note: glyph.note,
                components: glyph.components.map { component in
                    let resolved = component.status == .resolved ? component.source : nil
                    let outline = resolved.map { GlyphOutlines.encode(GlyphFlattener.outline(of: NodeID($0), sources: sources).path) } ?? component.cached
                    return CopiedGlyph.Component(source: component.source, sourceName: component.source.flatMap { index[$0]?.name } ?? "",
                                                 transform: component.transform, outline: outline)
                },
                anchors: glyph.anchors.map { CopiedGlyph.Anchor(name: $0.name, position: $0.position, role: $0.role) },
                objects: ClipboardPayload(copying: GlyphArtwork.objectIDs(on: glyph.id, in: state), from: state, document: document)
            )
        }
        self.init(glyphs: copied, sourceDocument: document)
    }

    public var isEmpty: Bool { glyphs.isEmpty }

    /// Every copied glyph's artwork as one objects payload (what menu:Edit[Paste] on a canvas pastes).
    public var artwork: ClipboardPayload {
        var bounds = Rect.null
        for glyph in glyphs { if let rect = glyph.objects.bounds { bounds = bounds.union(rect) } }
        return ClipboardPayload(nodes: glyphs.flatMap(\.objects.nodes), layerNames: glyphs.flatMap(\.objects.layerNames),
                                bounds: bounds.isNull ? nil : bounds, sourceDocument: sourceDocument, colors: Self.unique(glyphs.flatMap(\.objects.colors)))
    }

    static func unique(_ colors: [Wiretuner_Lib_V1_LibraryColor]) -> [Wiretuner_Lib_V1_LibraryColor] {
        var seen: Set<Wiretuner_Lib_V1_LibraryColor> = []
        return colors.filter { seen.insert($0).inserted }
    }

    // MARK: Encoding

    public func encoded() -> [UInt8] {
        var out: [UInt8] = []
        for glyph in glyphs { out += Wire.field(1, Self.encode(glyph)) }
        if !sourceDocument.isEmpty { out += Wire.field(2, Array(sourceDocument.utf8)) }
        return out
    }

    static func encode(_ glyph: CopiedGlyph) -> [UInt8] {
        var props = Wiretuner_Doc_V1_GlyphProps()
        props.name = glyph.name
        props.codepoints = glyph.codepoints
        props.advanceWidth = glyph.advanceWidth
        props.kind = glyph.kind.stored
        props.markColor = UInt32(max(glyph.markColor, 0))
        props.skipExport = glyph.skipExport
        if !glyph.note.isEmpty { props.common.note = glyph.note }
        props.components = glyph.components.map { component in
            var value = Wiretuner_Doc_V1_Component()
            if let source = component.source { value.glyph.id = source.proto }
            value.glyph.cached = component.outline
            if !component.transform.isIdentity { value.transform = PathEditing.proto(component.transform) }
            return value
        }
        props.anchors = glyph.anchors.map { anchor in
            var value = Wiretuner_Doc_V1_GlyphAnchor()
            value.name = anchor.name
            value.position = PathEditing.proto(anchor.position)
            value.role = anchor.role.stored
            return value
        }
        var out = Wire.field(1, Wire.bytes { try glyph.source.proto.serializedBytes() })
        out += Wire.field(2, Wire.bytes { try props.serializedBytes() })
        out += Wire.field(3, glyph.objects.encoded())
        for component in glyph.components { out += Wire.field(4, Array(component.sourceName.utf8)) }
        return out
    }

    /// The payload `bytes` encode; nil when they are not one.
    public init?(decoding bytes: [UInt8]) {
        guard let fields = WireReader.fields(bytes), fields.allSatisfy({ $0.wireType == 2 }) else { return nil }
        var glyphs: [CopiedGlyph] = []
        var source = ""
        for field in fields {
            switch field.number {
            case 1:
                guard let glyph = Self.decode(field.payload) else { return nil }
                glyphs.append(glyph)
            case 2:
                source = String(decoding: field.payload, as: UTF8.self)
            default:
                continue
            }
        }
        self.init(glyphs: glyphs, sourceDocument: source)
    }

    static func decode(_ bytes: [UInt8]) -> CopiedGlyph? {
        guard let fields = WireReader.fields(bytes) else { return nil }
        var id: OpID?
        var props: Wiretuner_Doc_V1_GlyphProps?
        var objects = ClipboardPayload(nodes: [])
        var names: [String] = []
        for field in fields where field.wireType == 2 {
            switch field.number {
            case 1: id = (try? Wiretuner_Doc_V1_OpId(serializedBytes: field.payload)).map(OpID.init)
            case 2: props = try? Wiretuner_Doc_V1_GlyphProps(serializedBytes: field.payload)
            case 3:
                guard let decoded = ClipboardPayload(decoding: field.payload) else { return nil }
                objects = decoded
            case 4: names.append(String(decoding: field.payload, as: UTF8.self))
            default: continue
            }
        }
        guard let id, let props else { return nil }
        let components = props.components.enumerated().map { offset, value in
            CopiedGlyph.Component(source: value.glyph.hasID ? OpID(value.glyph.id) : nil, sourceName: offset < names.count ? names[offset] : "",
                                  transform: value.hasTransform ? PathEditing.transform(value.transform) : .identity, outline: value.glyph.cached)
        }
        let anchors = props.anchors.map { value in
            CopiedGlyph.Anchor(name: value.name, position: Point(x: value.position.x, y: value.position.y),
                               role: value.role == .mark ? .mark : value.role == .base ? .base : .conventional(value.name))
        }
        return CopiedGlyph(source: id, name: props.name, codepoints: props.codepoints, kind: GlyphKind(stored: props.kind),
                           advanceWidth: props.advanceWidth.isFinite ? props.advanceWidth : 0, markColor: Int(min(props.markColor, 12)),
                           skipExport: props.skipExport, note: props.common.note, components: components, anchors: anchors, objects: objects)
    }
}

/// menu:Edit[Paste] of copied glyphs in the grid, one change:
///
/// * `.replace(targets)` -- a selection of the same count: each target's artwork, components and anchors are
///   deleted and the copy's written in their place with its advance width; names, codepoints, kind and colour
///   stay.  "Paste into glyph" / "Paste into N glyphs".
/// * `.add(after:)` -- new glyphs after `after` (at the end when nil) with the copies' names, codepoints, kind,
///   width, colour, export and note; a name or codepoint already live gets the name `<name>.1` (`.2`, …) and no
///   codepoints, so nothing is overwritten.  "Paste glyph" / "Paste N glyphs".
///
/// A component resolves to its source glyph when the paste is into the copy's own document (`document`) and the
/// glyph is live, else to the glyph pasted with it from that source, else to the glyph of the same name; one that resolves to nothing
/// (or would make a loop) is pasted as its outline, drawn.
public struct PasteGlyphs: Command {
    public enum Mode: Hashable, Sendable {
        case replace([OpID])
        case add(after: OpID?)
    }

    public var payload: GlyphClipboardPayload
    public var mode: Mode
    /// The destination document's id (components by id only within it).
    public var document: String

    public init(_ payload: GlyphClipboardPayload, _ mode: Mode, into document: String = "") {
        self.payload = payload
        self.mode = mode
        self.document = document
    }

    public var label: String {
        let count = payload.glyphs.count
        switch mode {
        case .replace: return count == 1 ? "Paste into glyph" : "Paste into \(count) glyphs"
        case .add: return count == 1 ? "Paste glyph" : "Paste \(count) glyphs"
        }
    }

    /// The name a pasted-new glyph gets when `name` (or one of its codepoints) is taken: `name.1`, `name.2`, …
    static func uniqueName(_ name: String, taken: Set<String>) -> String {
        var counter = 1
        while taken.contains("\(name).\(counter)") { counter += 1 }
        return "\(name).\(counter)"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !payload.isEmpty else { return }
        let index = GlyphIndex(state)
        var placement = GlyphArtworkPlacement(state: state)
        // Copied glyph (by source id) → the glyph it lands on, for components between pasted glyphs.
        var landed: [OpID: OpID] = [:]
        var targets: [(copy: CopiedGlyph, glyph: OpID)] = []
        switch mode {
        case .replace(let glyphs):
            guard glyphs.count == payload.glyphs.count else { throw GlyphEditError.invalidValue("selection") }
            for (copy, id) in zip(payload.glyphs, glyphs) {
                let glyph = try GlyphEditing.glyph(id, in: index)
                for object in GlyphArtwork.objectIDs(on: id, in: state) { builder.append(Ops.setDeleted(object)) }
                if !glyph.components.isEmpty { builder.append(Ops.elementDelete(id, glyph.components.map { GlyphFields.component($0.id) })) }
                if !glyph.anchors.isEmpty { builder.append(Ops.elementDelete(id, glyph.anchors.map { GlyphFields.anchor($0.id) })) }
                try GlyphEditing.validate(width: copy.advanceWidth)
                if glyph.advanceWidth != copy.advanceWidth { builder.append(GlyphEditing.setWidth(id, copy.advanceWidth)) }
                landed[copy.source] = id
                targets.append((copy, id))
            }
        case .add(let after):
            var names = Set(index.glyphs.flatMap { [$0.name, $0.storedName] })
            var codepoints = Set(index.glyphs.flatMap(\.storedCodepoints))
            let keys = try GlyphEditing.keys(after: after, count: payload.glyphs.count, state: state)
            for (copy, key) in zip(payload.glyphs, keys) {
                try GlyphEditing.validate(width: copy.advanceWidth)
                let clash = names.contains(copy.name) || copy.codepoints.contains(where: codepoints.contains)
                let name = clash ? Self.uniqueName(copy.name, taken: names) : copy.name
                guard GlyphNaming.isValid(name) else { throw GlyphEditError.invalidName(name) }
                let scalars = clash ? [] : copy.codepoints
                try scalars.forEach(GlyphEditing.validate(codepoint:))
                names.insert(name)
                codepoints.formUnion(scalars)
                let id = builder.append(Ops.create(parent: WellKnown.glyphs, position: key, props: GlyphFields.values {
                    $0.name = name
                    $0.advanceWidth = copy.advanceWidth
                    $0.kind = copy.kind.stored
                    if copy.markColor > 0 { $0.markColor = UInt32(copy.markColor) }
                    $0.skipExport = copy.skipExport
                    if !copy.note.isEmpty { $0.common.note = copy.note }
                }))
                if !scalars.isEmpty { builder.append(Ops.setAdd(id, GlyphFields.codepoints, values: GlyphFields.codepointValues(scalars))) }
                landed[copy.source] = id
                targets.append((copy, id))
            }
        }
        let sameDocument = !document.isEmpty && document == payload.sourceDocument
        for (copy, glyph) in targets {
            var inserted: [(source: OpID, transform: WTGeometry.AffineTransform, cached: Data)] = []
            for component in copy.components {
                let source = GlyphClipboardResolution.source(of: component, sameDocument: sameDocument, landed: landed, index: index)
                if let source, source != glyph, !GlyphEditing.reaches(source, glyph, in: index) {
                    inserted.append((source, component.transform, component.outline))
                } else {
                    try placement.drawOutline(component.outline, transform: component.transform, on: glyph, builder: &builder)
                }
            }
            if !inserted.isEmpty {
                let keys = try PathEditing.keys(between: nil, and: nil, count: inserted.count)
                builder.append(Ops.elementInsert(glyph, GlyphFields.components, positions: keys, values: GlyphFields.values { props in
                    props.components = inserted.map { component in
                        var value = Wiretuner_Doc_V1_Component()
                        value.glyph.id = component.source.proto
                        value.glyph.cached = component.cached
                        if !component.transform.isIdentity { value.transform = PathEditing.proto(component.transform) }
                        return value
                    }
                }))
            }
            if !copy.anchors.isEmpty {
                let keys = try PathEditing.keys(between: nil, and: nil, count: copy.anchors.count)
                builder.append(Ops.elementInsert(glyph, GlyphFields.anchors, positions: keys, values: GlyphFields.values { props in
                    props.anchors = copy.anchors.map { anchor in
                        var value = Wiretuner_Doc_V1_GlyphAnchor()
                        value.name = anchor.name
                        value.position = PathEditing.proto(anchor.position.isFinite ? anchor.position : .zero)
                        value.role = anchor.role.stored
                        return value
                    }
                }))
            }
            try placement.paste(copy.objects, on: glyph, builder: &builder)
        }
        placement.finish(&builder)
    }
}

/// menu:Edit[Paste as Component]: each copied glyph as a component of each of `glyphs`, at the origin (an
/// identity transform).  A copied glyph resolves as `PasteGlyphs` resolves a component's source; one that
/// resolves to nothing, or would make a loop, is left out -- and when nothing is left the command throws.
/// "Paste as component" / "Paste N components".
public struct PasteAsComponents: Command {
    public var payload: GlyphClipboardPayload
    public var glyphs: [OpID]
    public var document: String

    public init(_ payload: GlyphClipboardPayload, into glyphs: [OpID], document: String = "") {
        self.payload = payload
        self.glyphs = glyphs
        self.document = document
    }

    public var label: String {
        let count = payload.glyphs.count * glyphs.count
        return count == 1 ? "Paste as component" : "Paste \(count) components"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = GlyphIndex(state)
        let sameDocument = !document.isEmpty && document == payload.sourceDocument
        let sourceOutlines = GlyphOutlines.sources(in: state, index: index)
        var wrote = false
        for id in glyphs {
            _ = try GlyphEditing.glyph(id, in: index)
            var components: [(source: OpID, transform: WTGeometry.AffineTransform, cached: Data)] = []
            for copy in payload.glyphs {
                let reference = CopiedGlyph.Component(source: copy.source, sourceName: copy.name)
                guard let source = GlyphClipboardResolution.source(of: reference, sameDocument: sameDocument, landed: [:], index: index),
                      source != id, !GlyphEditing.reaches(source, id, in: index) else { continue }
                let cached = GlyphOutlines.encode(GlyphFlattener.outline(of: NodeID(source), sources: sourceOutlines).path)
                components.append((source, .identity, cached))
            }
            try GlyphEditing.insertComponents(into: id, components, state: state, builder: &builder)
            wrote = wrote || !components.isEmpty
        }
        guard wrote else { throw GlyphEditError.componentLoop }
    }
}

/// Resolving a copied component's source in the destination.
enum GlyphClipboardResolution {
    static func source(of component: CopiedGlyph.Component, sameDocument: Bool, landed: [OpID: OpID], index: GlyphIndex) -> OpID? {
        if sameDocument, let source = component.source, index[source] != nil { return source }
        if let source = component.source, let pasted = landed[source] { return pasted }
        guard !component.sourceName.isEmpty else { return nil }
        return index.glyph(named: component.sourceName)?.id
    }
}

/// Writing copied artwork onto glyph canvases within one change: the objects go to the layer of their copied
/// layer's name when an unlocked ordinary layer has it, else to the drawing layer (made once when there is
/// none), on top, with `canvas` = the glyph; named colours resolve by the clash rule (COLOR-019).
struct GlyphArtworkPlacement {
    let state: EngineState
    private var drawingLayer: OpID?
    private var placed: [NodeTree] = []
    private var mapping: [OpID: OpID] = [:]
    private var tops: [OpID: [UInt8]] = [:]

    init(state: EngineState) {
        self.state = state
    }

    private mutating func layer(named name: String, builder: inout ChangeBuilder) throws -> OpID {
        if !name.isEmpty, let layer = LayerOrder(state).layers.first(where: { $0.name == name && $0.role == .ordinary && !$0.locked }) {
            return layer.id
        }
        if let drawingLayer { return drawingLayer }
        let layer = try PathEditing.ensureLayer(&builder, state: state)
        drawingLayer = layer
        return layer
    }

    /// A position above everything under `parent`, and above what this paste put there.
    private mutating func topKey(in parent: OpID) throws -> [UInt8] {
        let top = tops[parent] ?? state.store.children(parent).last.flatMap { state.store.placement($0)?.position }
        let key = try PathEditing.keys(between: top, and: nil, count: 1)[0]
        tops[parent] = key
        return key
    }

    mutating func paste(_ objects: ClipboardPayload, on glyph: OpID, builder: inout ChangeBuilder) throws {
        guard !objects.isEmpty else { return }
        let colors = try PastedColors.resolve(objects.colors, state: state, builder: &builder)
        let nodes = PastedColors.rewrite(objects.nodes, mapping: colors, schema: state.schema)
        for (offset, tree) in nodes.enumerated() {
            let parent = try layer(named: offset < objects.layerNames.count ? objects.layerNames[offset] : "", builder: &builder)
            var copy = tree
            copy.transform = tree.transform.concatenating(Objects.pasteboardTransform(ofSpace: parent, in: state).inverse)
            let root = try NodeCopier.create(copy, parent: parent, position: try topKey(in: parent), schema: state.schema, builder: &builder, mapping: &mapping)
            if let kind = copy.kind {
                builder.append(Ops.set(root, [CommonFields.canvas(kind)], values: NodeValues.common(kind: kind) { $0.canvas.id = glyph.proto }))
            }
            placed.append(copy)
        }
    }

    /// `outline` (an encoded flattened outline) placed by `transform` as one black path on `glyph`.
    mutating func drawOutline(_ outline: Data, transform: WTGeometry.AffineTransform, on glyph: OpID, builder: inout ChangeBuilder) throws {
        let placement = GlyphComponentPlacement(source: .placeholder(GlyphOutlines.decode(outline)), transform: transform)
        let contours = GlyphFlattener.outline(of: GlyphSource(components: [placement]), sources: [:]).path.contours.filter { !$0.isEmpty }
        guard !contours.isEmpty else { return }
        let parent = try layer(named: "", builder: &builder)
        try GlyphPaths.create(contours, parent: parent, position: try topKey(in: parent), canvas: glyph, builder: &builder)
    }

    /// References between pasted objects point at the copies.
    func finish(_ builder: inout ChangeBuilder) {
        NodeCopier.rewriteReferences(in: placed, mapping: mapping, builder: &builder)
    }
}

/// Drag-to-reorder of several cells in Custom order: the glyphs, in grid order, moved together to grid position
/// `order` (1-based, counted without them, clamped) -- one `MoveNode` each.  "Move glyph" / "Move N glyphs".
public struct ReorderGlyphs: Command {
    public var glyphs: [OpID]
    public var order: Int

    public init(_ glyphs: [OpID], to order: Int) {
        self.glyphs = glyphs
        self.order = order
    }

    public var label: String { glyphs.count == 1 ? "Move glyph" : "Move \(glyphs.count) glyphs" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !glyphs.isEmpty else { return }
        let index = GlyphIndex(state)
        for id in glyphs { _ = try GlyphEditing.glyph(id, in: index) }
        let moving = Set(glyphs)
        let ordered = index.glyphs.map(\.id).filter(moving.contains)
        let others = index.glyphs.map(\.id).filter { !moving.contains($0) }
        let target = min(max(order - 1, 0), others.count)
        // Already there: the glyphs sit together at that place.
        let current = index.glyphs.map(\.id)
        if let first = current.firstIndex(of: ordered[0]), current[first..<min(first + ordered.count, current.count)].elementsEqual(ordered),
           first == target { return }
        let key: (OpID) -> [UInt8]? = { state.store.placement($0)?.position }
        let keys = try PathEditing.keys(between: target > 0 ? key(others[target - 1]) : nil, and: target < others.count ? key(others[target]) : nil,
                                        count: ordered.count)
        for (glyph, position) in zip(ordered, keys) {
            builder.append(Ops.move(glyph, parent: WellKnown.glyphs, position: position))
        }
    }
}
