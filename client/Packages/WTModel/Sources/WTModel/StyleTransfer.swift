import Foundation
import WTCRDT
import WTGeometry
import WTProto

// Moving graphic styles between documents (styles.adoc, "Copying styles between documents",
// "Cross-document paste" and "Import with Replace styles with the same name"; LIB-022).
//
// * A `StylePackage` is a set of chosen styles with everything they reference -- their parents
//   (through `based_on`), swatches, assets -- read from one document: what *Import…* reads from
//   another document or a team library, and what a style library file (`.wtstyles`) holds.
//   `ImportStyles` copies one into this document: each chosen style and each parent it needs,
//   once, under a free name ("Name 2") or -- with *Replace styles with the same name* -- as a
//   redefinition of the style of that name; swatches match by name and assets by hash as in a
//   symbol import.
// * A copy of objects carries a `ClipboardLibrary` in its payload: the `SymbolPackage` of what the
//   objects reference (swatches, styles with their parents, symbols) and each styled object's
//   resolved look.  `PasteFromDocument` imports the package the way a paste of instances does (a
//   same-named style is left alone; a missing one is created, parents first) and then writes, on
//   each pasted object, overrides for every category whose look in this document differs from the
//   look it had -- so it looks identical and shows the plus sign.
// * Styles are unique by name on read: two live graphic styles with one name (two people
//   importing the same style at once) read as "Name" -- the smaller node id -- and "Name 2"
//   (`GraphicStyleFields.displayNames`).  Nothing is rewritten.

/// An object's resolved look as it travels with a copy: the canonical stack (each element's id its
/// place in the stack) and the halftone screen.
public struct StyleLook: Hashable, Sendable {
    var look: StyleStacks.Look

    init(_ look: StyleStacks.Look) {
        self.look = look
    }

    /// The look held in a style's `appearance` and `common.halftone`, elements in id order.
    init(props: Wiretuner_Doc_V1_NodeProps) {
        let appearance = props.style.appearance
        let elements: [(UInt64, AttributePayload.Element)] = appearance.fills.map { ($0.id.counter, .fill($0)) }
            + appearance.strokes.map { ($0.id.counter, .stroke($0)) } + appearance.effects.map { ($0.id.counter, .effect($0)) }
        look = StyleStacks.Look(stack: elements.sorted { $0.0 < $1.0 }.map(\.1), halftone: props.style.common.hasHalftone ? props.style.common.halftone : nil)
    }

    /// The look as a style's properties.
    var props: Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.style = Wiretuner_Doc_V1_StyleProps()
        for element in look.stack {
            switch element {
            case .fill(let fill): props.style.appearance.fills.append(fill)
            case .stroke(let stroke): props.style.appearance.strokes.append(stroke)
            case .effect(let effect): props.style.appearance.effects.append(effect)
            }
        }
        if let halftone = look.halftone { props.style.common.halftone = halftone }
        return props
    }

    /// The look with every node reference `map` answers (a swatch, an asset) replaced.
    func rewritten(schema: Schema, _ map: (OpID) -> OpID?) -> StyleLook {
        StyleLook(props: ReferenceRewriting.rewrite(NodeTree(props: props), schema: schema, map).props)
    }
}

/// What copied objects need from their document to paste into another: the package of the
/// swatches, styles and symbols they reference, and the resolved look of each styled object (by
/// source node id).
public struct ClipboardLibrary: Hashable, Sendable {
    public var package: SymbolPackage
    public var looks: [OpID: StyleLook]

    public init(package: SymbolPackage = SymbolPackage(), looks: [OpID: StyleLook] = [:]) {
        self.package = package
        self.looks = looks
    }

    /// The library `trees` (copied from `state`) need.
    public init(referencedBy trees: [NodeTree], from state: EngineState) {
        let resolver = GraphicStyleResolver(state)
        var looks: [OpID: StyleLook] = [:]
        for node in trees.flatMap(\.flattened) {
            guard let source = node.source, state.store.exists(source), resolver.style(of: source, in: state) != nil,
                  case .object? = StackHost.of(source, in: state) else { continue }
            looks[source] = StyleLook(StyleStacks.look(of: source, styles: resolver, state: state))
        }
        self.init(package: SymbolPackage(referencedBy: trees, from: state), looks: looks)
    }

    public var isEmpty: Bool { package.isEmpty && looks.isEmpty }

    /// The encoding: the package 1, each look 2 (the object's id 1, the look as `NodeProps` 2).
    public func encoded() -> [UInt8] {
        var out: [UInt8] = []
        if !package.isEmpty { out += Wire.field(1, package.encoded()) }
        for (id, look) in looks.sorted(by: { $0.key < $1.key }) {
            out += Wire.field(2, Wire.field(1, Wire.bytes { try id.proto.serializedBytes() }) + Wire.field(2, Wire.bytes { try look.props.serializedBytes() }))
        }
        return out
    }

    /// The library `bytes` encode; nil when they are not one.
    public init?(decoding bytes: [UInt8]) {
        guard let fields = WireReader.fields(bytes), fields.allSatisfy({ $0.wireType == 2 }) else { return nil }
        var package = SymbolPackage()
        var looks: [OpID: StyleLook] = [:]
        for field in fields {
            switch field.number {
            case 1:
                guard let decoded = SymbolPackage(decoding: field.payload) else { return nil }
                package = decoded
            case 2:
                guard let parts = WireReader.fields(field.payload),
                      let id = parts.first(where: { $0.number == 1 }).flatMap({ try? Wiretuner_Doc_V1_OpId(serializedBytes: $0.payload) }),
                      let props = parts.first(where: { $0.number == 2 }).flatMap({ try? Wiretuner_Doc_V1_NodeProps(serializedBytes: $0.payload) })
                else { return nil }
                looks[OpID(id)] = StyleLook(props: props)
            default:
                continue
            }
        }
        self.init(package: package, looks: looks)
    }
}

/// menu:Edit[Paste] of objects copied in another document: the library they carry is imported
/// first -- swatches and styles matched by name, a missing style created with its parents,
/// symbols as a paste of instances takes them (`PasteWithSymbols`) -- then the objects are pasted
/// with their references pointing at this document's nodes, and each styled object gets overrides
/// for every category whose look here differs from the look it was copied with.  One change,
/// labelled as `Paste`.  Without a library it is a plain `Paste`.
public struct PasteFromDocument: Command {
    public var paste: Paste

    public init(_ paste: Paste) {
        self.paste = paste
    }

    public var label: String { paste.label }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard let library = paste.payload.library else { return try paste.execute(&builder, state: state) }
        var importer = SymbolImporter(package: Self.needed(library.package, by: paste.payload.nodes, in: state), state: state)
        try importer.run(extra: [], alwaysCopy: false, builder: &builder)
        var rewritten = paste
        rewritten.payload.nodes = paste.payload.nodes.map { importer.rewrite($0) }
        rewritten.payload.library = nil
        var mapping: [OpID: OpID] = [:]
        try rewritten.execute(&builder, state: state, mapping: &mapping)
        let looks = library.looks.mapValues { $0.rewritten(schema: state.schema) { importer.mapping[$0] } }
        try StyleBaking.bake(looks, onto: mapping, state: state, builder: &builder)
    }

    /// The part of `package` that pasting `nodes` needs: what they reference, and what an item
    /// this document has no match for references in turn -- a same-named style left alone here
    /// brings none of its parents.
    static func needed(_ package: SymbolPackage, by nodes: [NodeTree], in state: EngineState) -> SymbolPackage {
        let matcher = SymbolImporter(package: package, state: state)
        let index = Dictionary(package.resources.compactMap { item in item.tree.source.map { ($0, item) } }) { first, _ in first }
        var needed: Set<OpID> = []
        var pending = nodes.flatMap { ReferenceRewriting.targets(in: $0, schema: state.schema) }
        while let next = pending.popLast() {
            guard let item = index[next], needed.insert(next).inserted, matcher.match(item) == nil else { continue }
            pending += ReferenceRewriting.targets(in: item.tree, schema: state.schema)
        }
        var out = package
        out.resources = package.resources.filter { $0.tree.source.map(needed.contains) ?? false }
        return out
    }
}

/// Writing looks onto objects created earlier in the same change.
enum StyleBaking {
    /// For each object `mapping` created from a source with a look in `looks`: overrides in every
    /// category where its look -- read from `state` with the change so far applied -- differs.
    static func bake(_ looks: [OpID: StyleLook], onto mapping: [OpID: OpID], state: EngineState, builder: inout ChangeBuilder) throws {
        let targets = looks.keys.sorted().compactMap { source in mapping[source].map { (source, $0) } }
        guard !targets.isEmpty else { return }
        var scratch = state
        var change = Wiretuner_Doc_V1_Change()
        change.replica = builder.replica
        change.seq = 1
        change.startCounter = builder.startCounter
        change.ops = builder.ops
        scratch.apply(change)
        let resolver = GraphicStyleResolver(scratch)
        for (source, created) in targets {
            guard let host = StackHost.of(created, in: scratch), case .object = host else { continue }
            let wanted = looks[source]!.look
            let differing = GraphicStyleFields.differences(wanted, StyleStacks.look(of: created, styles: resolver, state: scratch))
            guard !differing.isEmpty else { continue }
            try GraphicStyleFields.write(wanted, categories: differing, into: host, state: scratch, builder: &builder)
        }
    }
}

/// A self-contained set of graphic styles from one document (a `SymbolPackage` whose chosen
/// entries are styles).
public struct StylePackage: Hashable, Sendable {
    var content: SymbolPackage

    /// The chosen styles (source ids set).
    public var styles: [NodeTree] { content.symbols }
    /// What they reference: parent styles, swatches, assets.
    public var resources: [SymbolPackage.Resource] { content.resources }
    /// Asset bytes by lower-case hex sha256, for a style library file.
    public var blobs: [String: Data] {
        get { content.blobs }
        set { content.blobs = newValue }
    }

    init(content: SymbolPackage) {
        self.content = content
    }

    /// The live graphic styles `ids` of `state` with what they reference.
    public init(styles ids: [OpID], from state: EngineState, blobs: [String: Data] = [:]) {
        let resolver = GraphicStyleResolver(state)
        let chosen = ids.filter { resolver.isGraphic($0) && state.isLive($0) }
        let trees = chosen.map { NodeTree($0, state: state) }
        content = SymbolPackage(symbols: trees, resources: SymbolPackage.resources(of: trees, excluding: Set(chosen), in: state), blobs: blobs)
    }

    /// Every live graphic style of `state`.
    public init(allStylesOf state: EngineState) {
        self.init(styles: GraphicStyleFields.styles(in: state, GraphicStyleResolver(state)), from: state)
    }

    public var isEmpty: Bool { styles.isEmpty }

    /// The chosen styles' names, for the Import Styles sheet.
    public var names: [String] { styles.map { $0.props.style.common.name } }

    /// The hashes of the assets the package needs.
    public var assetHashes: [String] { content.assetHashes }

    // MARK: Files

    /// The first bytes of a style library file.
    public static let fileMagic = Array("WTSTYLES1\n".utf8)
    /// The file extension of a style library file.
    public static let fileExtension = "wtstyles"

    /// A style library file's bytes.
    public var fileData: Data { Data(Self.fileMagic + content.encoded()) }

    /// Why a file is not a style library.
    public enum FileError: Error, Equatable, Sendable {
        case notAStyleLibrary
    }

    /// The package a style library file holds.
    public init(fileData data: Data) throws(FileError) {
        let bytes = [UInt8](data)
        guard bytes.starts(with: Self.fileMagic), let package = SymbolPackage(decoding: Array(bytes.dropFirst(Self.fileMagic.count))),
              package.symbols.allSatisfy({ if case .style? = $0.props.kind { true } else { false } }) else {
            throw .notAStyleLibrary
        }
        content = package
    }
}

/// *Import…* in the Styles panel (LIB-022): the package's styles -- all, or the source ids in
/// `selection` -- and each parent they need, once, parents first.  A style whose name is taken is
/// added under a free name ("Name 2"), or with `replacingSameName` redefines the style of that
/// name (the registers that differ written in place, its stack replaced when it differs, its role
/// kept).  One change, "Import Style" / "Import N styles".
public struct ImportStyles: Command {
    public var package: StylePackage
    public var selection: Set<OpID>?
    public var replacingSameName: Bool

    public init(_ package: StylePackage, selection: Set<OpID>? = nil, replacingSameName: Bool = false) {
        self.package = package
        self.selection = selection
        self.replacingSameName = replacingSameName
    }

    var chosen: [NodeTree] { package.styles.filter { selection?.contains($0.source ?? .zero) ?? true } }

    public var label: String { chosen.count == 1 ? "Import Style" : "Import \(chosen.count) styles" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let chosen = self.chosen
        guard !chosen.isEmpty else { return }
        let collection = GraphicStyleFields.collection
        let styleResources = Dictionary(package.resources.filter { $0.collection == collection }.compactMap { resource in
            resource.tree.source.map { ($0, resource.tree) }
        }) { first, _ in first }
        // Swatches, assets and anything else the styles reference, matched as a symbol import matches them.
        var importer = SymbolImporter(package: SymbolPackage(resources: package.resources.filter { $0.collection != collection }), state: state)
        try importer.run(extra: [], alwaysCopy: false, builder: &builder)

        // The chosen styles and the parents they need, parents first, each once.
        var ordered: [NodeTree] = []
        var seen: Set<OpID> = []
        func visit(_ tree: NodeTree, depth: Int) {
            guard let source = tree.source, !seen.contains(source), depth < 64 else { return }
            seen.insert(source)
            let props = tree.props.style
            if props.hasBasedOn, let parent = styleResources[OpID(props.basedOn.id)] ?? chosen.first(where: { $0.source == OpID(props.basedOn.id) }) {
                visit(parent, depth: depth + 1)
            }
            ordered.append(tree)
        }
        chosen.forEach { visit($0, depth: 0) }

        let resolver = GraphicStyleResolver(state)
        let live = GraphicStyleFields.styles(in: state, resolver)
        var byName: [String: OpID] = [:]
        for style in live.sorted() where byName[state.props(style).style.common.name] == nil {
            byName[state.props(style).style.common.name] = style
        }
        var taken = Set(byName.keys).union(GraphicStyleFields.displayNames(in: state, resolver).values)
        var mapping = importer.mapping
        var last = state.store.children(collection).last.flatMap { state.store.placement($0)?.position }
        for tree in ordered {
            var copy = ReferenceRewriting.rewrite(tree, schema: state.schema) { mapping[$0] }
            copy.children = []
            let name = copy.props.style.common.name
            if replacingSameName, let existing = byName[name] {
                copy.props.style.role = state.props(existing).style.role
                try LibraryCopying.writeDifferences(of: copy, over: existing, kind: GraphicStyleResolver.styleKind, in: state, builder: &builder)
                mapping[tree.source!] = existing
                continue
            }
            copy.props.style.role = .unspecified
            var free = name
            var number = 2
            while taken.contains(free) {
                free = "\(name) \(number)"
                number += 1
            }
            taken.insert(free)
            copy.props.style.common.name = free
            let key = try FractionalIndex.between(last, nil, suffix: builder.nextCounter)
            last = key
            mapping[tree.source!] = try NodeCopier.create(copy, parent: collection, position: key, schema: state.schema, builder: &builder)
        }
    }
}

extension GraphicStyleFields {
    /// The names the Styles panel shows: every live graphic style's own name, except that of several
    /// with one name the smallest node id keeps it and the others read "Name 2", "Name 3" … (the
    /// first numbers no style is named), in node id order.  Read-time only: two people importing
    /// the same style at once see "Name" and "Name 2" and nothing is rewritten.
    public static func displayNames(in state: EngineState, _ resolver: GraphicStyleResolver) -> [OpID: String] {
        let live = styles(in: state, resolver).sorted()
        var used = Set(live.map { state.props($0).style.common.name })
        var holders: Set<String> = []
        var out: [OpID: String] = [:]
        for style in live {
            let name = state.props(style).style.common.name
            if holders.insert(name).inserted {
                out[style] = name
                continue
            }
            var number = 2
            while used.contains("\(name) \(number)") { number += 1 }
            let shown = "\(name) \(number)"
            used.insert(shown)
            out[style] = shown
        }
        return out
    }
}
