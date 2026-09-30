import Foundation
import WTCRDT
import WTGeometry
import WTInterchange
import WTProto
import WTRender
import struct WTGeometry.AffineTransform

// The live parts of an imported scene (import-formats.adoc, "Imported scene to document", the
// rows added for FreeHand; IO-041, D-083): named colours become references to document swatches,
// symbols become symbol nodes with instances, and tiled, lens and pattern fills, pattern strokes
// and arrowheads become the fills and strokes of those kinds.  Swatches and symbols are written
// first in the import's change, so the nodes that use them can point at them.

/// What the nodes of one import refer to, created (or found) before them in the same change.
struct ImportReferences: Sendable {
    /// The colour reference of each named colour.
    var swatches: [ImportedSwatch: Wiretuner_Doc_V1_ColorRef] = [:]
    /// The symbol node of each imported symbol, by `ImportedSymbol.key`, with its origin.
    var symbols: [String: (id: OpID, origin: Point)] = [:]

    /// The colour reference of `paint`'s named colour, else of its colour.
    func colorRef(_ paint: ImportedPaint) -> Wiretuner_Doc_V1_ColorRef? {
        if case .swatch(let swatch) = paint, let ref = swatches[swatch] { return ref }
        return paint.representativeColor.map(ImportMapping.colorRef)
    }

    /// FreeHand writes its Registration colour as "[Registration]".
    static func swatchName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "[Registration]" ? "Registration" : String(trimmed.prefix(SwatchFields.maxName))
    }
}

extension ImportWriter {
    /// Writes the swatches and symbols `scene` needs, before its nodes.
    mutating func prepare(_ scene: ImportedScene, builder: inout ChangeBuilder) throws {
        try prepareSwatches(scene.swatches, builder: &builder)
        try prepareSymbols(scene.symbols, builder: &builder)
    }

    /// A named colour reuses the document's swatch of that name when it is one of the protected
    /// White, Black and Registration or holds the same colour and spot choice; otherwise a
    /// swatch is added at the end of the list, `-N` suffixed when the name is taken.
    mutating func prepareSwatches(_ swatches: [ImportedSwatch], builder: inout ChangeBuilder) throws {
        let list = SwatchList(state)
        var pending: [(swatch: ImportedSwatch, name: String)] = []
        for swatch in swatches where references.swatches[swatch] == nil {
            let name = ImportReferences.swatchName(swatch.name)
            if let existing = list.named(name),
               existing.isProtected || (!existing.isTint && existing.isSpot == swatch.spot && ColorValues.stored(existing.value) == ColorValues.stored(swatch.color)) {
                references.swatches[swatch] = ImportWriter.ref(existing.id, existing.color)
                continue
            }
            let unique = ColorText.unique(name.isEmpty ? ColorText.defaultName(swatch.color) : name) { candidate in
                list.isTaken(candidate) || pending.contains { $0.name == candidate }
            }
            pending.append((swatch, unique))
        }
        guard !pending.isEmpty else { return }
        let lower = state.store.children(SwatchFields.collection).last.flatMap { state.store.placement($0)?.position }
        let keys = try PathEditing.keys(between: lower, and: nil, count: pending.count)
        for (entry, key) in zip(pending, keys) {
            let id = builder.append(Swatches.create({ swatch in
                swatch.common.name = entry.name
                swatch.value = ColorValues.stored(entry.swatch.color)
                swatch.spot = entry.swatch.spot
            }, at: key))
            references.swatches[entry.swatch] = ImportWriter.ref(id, entry.swatch.color)
        }
    }

    /// A reference to swatch `id`, caching `color`.
    static func ref(_ id: OpID, _ color: Color) -> Wiretuner_Doc_V1_ColorRef {
        var ref = Wiretuner_Doc_V1_ColorRef()
        ref.swatch.id = id.proto
        ref.swatch.cached = ColorValues.cached(color)
        return ref
    }

    /// Each symbol as a symbol node after the document's, its artwork as children in symbol
    /// space and its origin the artwork's centre (as *Convert to Symbol* sets it).  Symbols used
    /// inside other symbols come first in `symbols`, so their instances find them.
    mutating func prepareSymbols(_ symbols: [ImportedSymbol], builder: inout ChangeBuilder) throws {
        guard !symbols.isEmpty else { return }
        let lower = state.store.children(WellKnown.symbols).last.flatMap { state.store.placement($0)?.position }
        let keys = try PathEditing.keys(between: lower, and: nil, count: symbols.count)
        for (symbol, key) in zip(symbols, keys) {
            let bounds = symbol.nodes.reduce(Rect.null) { $0.union($1.controlBounds()) }
            let origin = bounds.isNull ? Point.zero : bounds.center
            var props = Wiretuner_Doc_V1_NodeProps()
            props.symbol.common.name = String(symbol.name.prefix(256))
            props.symbol.origin = PathEditing.proto(origin)
            let id = builder.append(Ops.create(parent: WellKnown.symbols, position: key, props: props))
            references.symbols[symbol.key] = (id, origin)
            let childKeys = try PathEditing.keys(between: nil, and: nil, count: symbol.nodes.count)
            for (node, childKey) in zip(symbol.nodes, childKeys) {
                try create(node, parent: id, position: childKey, builder: &builder)
            }
        }
    }

    /// An instance of the symbol `key` placed by `transform` (symbol space to the parent's),
    /// or nil when the scene has no such symbol.
    func instance(_ key: String, name: String?, transform: AffineTransform, builder: inout ChangeBuilder, parent: OpID, position: [UInt8]) -> OpID? {
        guard let symbol = references.symbols[key] else { return nil }
        // The instance draws the artwork moved by -origin, then its own transform.
        let placement = AffineTransform.translation(x: symbol.origin.x, y: symbol.origin.y).concatenating(transform)
        var props = SymbolEditing.instanceProps(symbol.id, transform: placement)
        if let name, !name.isEmpty { props.instance.common.name = String(name.prefix(256)) }
        return builder.append(Ops.create(parent: parent, position: position, props: props))
    }
}

extension ImportMapping {
    // MARK: Live fills

    /// A Tiled fill of `tile`: its artwork as the tile subtree (paths and groups; text, images
    /// and placed files have no tile drawing), moved so its bounds start at the origin.
    static func tiled(_ tile: ImportedTile, references: ImportReferences) -> Wiretuner_Doc_V1_TiledFill? {
        let trees = tile.nodes.compactMap { tree($0, references: references) }
        let bounds = tile.nodes.reduce(Rect.null) { $0.union($1.controlBounds()) }
        guard !trees.isEmpty, !bounds.isNull, let subtree = try? Subtrees.tile(from: ClipboardPayload(nodes: trees, bounds: bounds)) else { return nil }
        var value = Wiretuner_Doc_V1_TiledFill()
        value.tile = subtree
        value.angle = tile.angle.isFinite ? tile.angle : 0
        value.scaleX = tile.scaleX.isFinite && tile.scaleX > 0 ? tile.scaleX : 100
        value.scaleY = tile.scaleY.isFinite && tile.scaleY > 0 ? tile.scaleY : 100
        if tile.offset != .zero { value.offset = PathEditing.proto(tile.offset) }
        return value
    }

    /// `node` as a node tree for a tile: groups and paths.
    static func tree(_ node: ImportedNode, references: ImportReferences) -> NodeTree? {
        switch node {
        case .path(let path):
            return NodeTree(props: self.path(path, placement: .identity, references: references))
        case .group(let group):
            var children = group.children.compactMap { tree($0, references: references) }
            if var clip = group.clip {
                if !group.clipAppearance {
                    clip.fill = .none
                    clip.stroke = nil
                }
                children.insert(NodeTree(props: self.path(clip, placement: .identity, references: references)), at: 0)
            }
            // A tile keeps no clip reference (ids are stripped): the group draws plain.
            var props = self.group(group, placement: .identity)
            props.group.kind = .group
            return NodeTree(props: props, children: children)
        case .text, .image, .placed:
            return nil
        }
    }

    static func lens(_ lens: LensFill) -> Wiretuner_Doc_V1_LensFill {
        var value = Wiretuner_Doc_V1_LensFill()
        value.type = switch lens.type {
        case .transparency: .transparency
        case .magnify: .magnify
        case .invert: .invert
        case .lighten: .lighten
        case .darken: .darken
        case .monochrome: .monochrome
        }
        value.color = colorRef(lens.color)
        value.amount = min(max(lens.amount.isFinite ? lens.amount : 50, 0), 100)
        value.magnification = min(max(lens.magnification.isFinite ? lens.magnification : 1, 1), 20)
        if let center = lens.centerpoint { value.centerpoint = PathEditing.proto(center) }
        value.objectsOnly = lens.objectsOnly
        return value
    }

    static func patternBitmap(_ bitmap: PatternBitmap) -> Wiretuner_Doc_V1_PatternBitmap {
        var value = Wiretuner_Doc_V1_PatternBitmap()
        value.rows = Data(bitmap.rows)
        return value
    }

    // MARK: Arrowheads

    /// An arrowhead's outline as stored (at most 64 contours).
    static func arrowhead(_ arrowhead: ImportedArrowhead) -> Wiretuner_Doc_V1_Arrowhead {
        var value = Wiretuner_Doc_V1_Arrowhead()
        value.name = String(arrowhead.name.prefix(64))
        value.contours = arrowhead.contours.prefix(64).map(contour)
        value.filled = arrowhead.filled
        return value
    }
}
