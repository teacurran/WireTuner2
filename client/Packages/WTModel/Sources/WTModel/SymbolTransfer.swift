import Foundation
import WTCRDT
import WTGeometry
import WTProto

// Moving symbols between documents (library.adoc, "Copying symbols between documents" and
// "Client", Import; LIB-013).  A `SymbolPackage` is a set of symbols read from one document with
// everything their artwork references -- swatches, styles, brushes, assets and nested symbols --
// so it is self-contained: what *Import…* reads from another document's state, what a symbol
// library file holds, and what travels beside the objects on the pasteboard when copied objects
// include instances.  `ImportSymbols` and `PasteWithSymbols` copy one into this document with
// fresh ids: swatches, styles and brushes are matched by kind and name and assets by hash, so
// nothing is duplicated needlessly; every reference inside the copies (a `NodeRef` or an `OpId`
// naming a copied node, wherever the schema puts one; `ReferenceRewriting`, shared with the
// library catalog) is rewritten to the copy.  A pasted
// instance's symbol is reused when this document has one of the same name and the same artwork,
// else added under a free name ("Star 2"); an imported symbol is always a new copy.

/// A self-contained set of symbols from one document.
public struct SymbolPackage: Hashable, Sendable {
    /// A node the symbols need, and the collection it lives in (swatches 0:5, styles 0:6,
    /// symbols 0:7, brushes 0:8, assets 0:9).
    public struct Resource: Hashable, Sendable {
        public var collection: OpID
        public var tree: NodeTree

        public init(collection: OpID, tree: NodeTree) {
            self.collection = collection
            self.tree = tree
        }
    }

    /// The chosen symbols, each with its artwork (source ids set).
    public var symbols: [NodeTree]
    /// Everything the symbols reference, nested symbols included, each once.
    public var resources: [Resource]
    /// Asset bytes by lower-case hex sha256, for a symbol library file (a package read from a
    /// document carries none: the assets' blobs are fetched by hash).
    public var blobs: [String: Data]

    /// The collections a reference is followed into.
    static let collections: Set<OpID> = [WellKnown.swatches, .wellKnown(6), WellKnown.symbols, .wellKnown(8), .wellKnown(9)]

    public init(symbols: [NodeTree] = [], resources: [Resource] = [], blobs: [String: Data] = [:]) {
        self.symbols = symbols
        self.resources = resources
        self.blobs = blobs
    }

    /// The live symbols `ids` of `state` with what they reference.
    public init(symbols ids: [OpID], from state: EngineState, blobs: [String: Data] = [:]) {
        let chosen = ids.filter { state.isLive($0) && state.nodeKind($0) == .symbol }
        let trees = chosen.map { NodeTree($0, state: state) }
        self.init(symbols: trees, resources: Self.resources(of: trees, excluding: Set(chosen), in: state), blobs: blobs)
    }

    /// What the copied `trees` reference (the pasteboard's companion to a `ClipboardPayload`):
    /// the symbols of copied instances with their own references, and swatches and styles.
    public init(referencedBy trees: [NodeTree], from state: EngineState) {
        self.init(resources: Self.resources(of: trees, excluding: [], in: state))
    }

    /// The nodes in the collections that `trees` reference, transitively, in first-reference order.
    static func resources(of trees: [NodeTree], excluding: Set<OpID>, in state: EngineState) -> [Resource] {
        var seen = excluding
        var out: [Resource] = []
        var pending = trees
        while !pending.isEmpty {
            let tree = pending.removeFirst()
            for target in ReferenceRewriting.targets(in: tree, schema: state.schema) where !seen.contains(target) {
                seen.insert(target)
                guard state.isLive(target), let collection = state.store.placement(target)?.parent, collections.contains(collection)
                    || (state.nodeKind(target) == .symbol && Symbols.symbols(in: state).contains(target)) else { continue }
                let resource = Resource(collection: state.nodeKind(target) == .symbol ? WellKnown.symbols : collection,
                                        tree: NodeTree(target, state: state))
                out.append(resource)
                pending.append(resource.tree)
            }
        }
        return out
    }

    public var isEmpty: Bool { symbols.isEmpty && resources.isEmpty }

    /// The chosen symbols' names, for the Import Symbols sheet.
    public var names: [String] { symbols.map { $0.props.symbol.common.name } }

    /// The hashes of the assets the package needs (their blobs must reach this document).
    public var assetHashes: [String] {
        resources.compactMap { resource in
            guard case .asset(let asset)? = resource.tree.props.kind, !asset.sha256.isEmpty else { return nil }
            return asset.sha256.map { String(format: "%02x", $0) }.joined()
        }
    }

    // MARK: Encoding

    /// The pasteboard type of the package that accompanies copied instances.
    public static let pasteboardType = "com.villagecompute.wiretuner.symbols"
    /// The first bytes of a symbol library file (`.wtsymbols`).
    public static let fileMagic = Array("WTSYMBOLS1\n".utf8)
    /// The file extension of a symbol library file.
    public static let fileExtension = "wtsymbols"

    /// The package's encoding: symbols 1 and resources 2 (each a `ClipboardPayload` of one node;
    /// a resource's collection in the payload's `source_document` field as `counter:replica`), and
    /// blobs 3 (hash 1, bytes 2).
    public func encoded() -> [UInt8] {
        var out: [UInt8] = []
        for tree in symbols { out += Wire.field(1, ClipboardPayload(nodes: [tree]).encoded()) }
        for resource in resources {
            let collection = "\(resource.collection.counter):\(resource.collection.replica)"
            out += Wire.field(2, ClipboardPayload(nodes: [resource.tree], sourceDocument: collection).encoded())
        }
        for (hash, data) in blobs.sorted(by: { $0.key < $1.key }) {
            out += Wire.field(3, Wire.field(1, Array(hash.utf8)) + Wire.field(2, Array(data)))
        }
        return out
    }

    /// The package `bytes` encode; nil when they are not one.
    public init?(decoding bytes: [UInt8]) {
        guard let fields = WireReader.fields(bytes), fields.allSatisfy({ $0.wireType == 2 }) else { return nil }
        var symbols: [NodeTree] = []
        var resources: [Resource] = []
        var blobs: [String: Data] = [:]
        for field in fields {
            switch field.number {
            case 1:
                guard let payload = ClipboardPayload(decoding: field.payload), payload.nodes.count == 1 else { return nil }
                symbols.append(payload.nodes[0])
            case 2:
                guard let payload = ClipboardPayload(decoding: field.payload), payload.nodes.count == 1 else { return nil }
                let parts = payload.sourceDocument.split(separator: ":").compactMap { UInt64($0) }
                guard parts.count == 2 else { return nil }
                resources.append(Resource(collection: OpID(counter: parts[0], replica: parts[1]), tree: payload.nodes[0]))
            case 3:
                guard let parts = WireReader.fields(field.payload), let hash = parts.first(where: { $0.number == 1 }),
                      let data = parts.first(where: { $0.number == 2 }) else { return nil }
                blobs[String(decoding: hash.payload, as: UTF8.self)] = Data(data.payload)
            default:
                continue
            }
        }
        self.init(symbols: symbols, resources: resources, blobs: blobs)
    }

    /// A symbol library file's bytes.
    public var fileData: Data { Data(Self.fileMagic + encoded()) }

    /// Why a file is not a symbol library.
    public enum FileError: Error, Equatable, Sendable {
        case notASymbolLibrary
    }

    /// The package a symbol library file holds.
    public init(fileData data: Data) throws(FileError) {
        let bytes = [UInt8](data)
        guard bytes.starts(with: Self.fileMagic), let package = SymbolPackage(decoding: Array(bytes.dropFirst(Self.fileMagic.count))) else {
            throw .notASymbolLibrary
        }
        self = package
    }
}

/// *Import…* in the Library panel (LIB-013): copies the package's symbols -- all, or the source
/// ids in `selection` -- into this document's `symbols` collection, with what they reference.
/// One change, "Import Symbol" / "Import N symbols".
public struct ImportSymbols: Command {
    public var package: SymbolPackage
    public var selection: Set<OpID>?

    public init(_ package: SymbolPackage, selection: Set<OpID>? = nil) {
        self.package = package
        self.selection = selection
    }

    var chosen: [NodeTree] { package.symbols.filter { selection?.contains($0.source ?? .zero) ?? true } }

    public var label: String { chosen.count == 1 ? "Import Symbol" : "Import \(chosen.count) symbols" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let chosen = self.chosen
        guard !chosen.isEmpty else { return }
        var importer = SymbolImporter(package: package, state: state)
        try importer.run(extra: chosen.map { SymbolPackage.Resource(collection: WellKnown.symbols, tree: $0) }, alwaysCopy: true,
                         builder: &builder)
    }
}

/// Paste of objects copied in another document with the package of what they reference
/// (library.adoc, "To copy symbols by pasting"): the package is imported first -- an instance's
/// symbol reused when this document has one of the same name and artwork, else added under a free
/// name -- then the objects are pasted with their references pointing at this document's nodes.
/// One change, labelled as `Paste`.
public struct PasteWithSymbols: Command {
    public var paste: Paste
    public var package: SymbolPackage

    public init(_ paste: Paste, package: SymbolPackage) {
        self.paste = paste
        self.package = package
    }

    public var label: String { paste.label }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var importer = SymbolImporter(package: package, state: state)
        try importer.run(extra: [], alwaysCopy: false, builder: &builder)
        var rewritten = paste
        rewritten.payload.nodes = paste.payload.nodes.map { importer.rewrite($0) }
        try rewritten.execute(&builder, state: state)
    }
}

/// Copies package nodes into a document: decides for each resource whether an existing node
/// stands for it, creates the rest in reference order, and keeps the source → copy mapping.
struct SymbolImporter {
    let package: SymbolPackage
    let state: EngineState
    /// Source node → this document's node.
    private(set) var mapping: [OpID: OpID] = [:]
    private var names: [OpID: Set<String>] = [:]
    /// The position of the last node created in each collection, so each goes above the one before.
    private var lastKeys: [OpID: [UInt8]] = [:]

    init(package: SymbolPackage, state: EngineState) {
        self.package = package
        self.state = state
    }

    /// Imports every resource and then `extra` (always copied when `alwaysCopy`).
    mutating func run(extra: [SymbolPackage.Resource], alwaysCopy: Bool, builder: inout ChangeBuilder) throws {
        let items = Self.ordered(package.resources + extra, schema: state.schema)
        let chosen = Set(extra.compactMap(\.tree.source))
        for item in items {
            guard let source = item.tree.source, mapping[source] == nil else { continue }
            let copy = !(alwaysCopy && chosen.contains(source))
            if copy, let existing = match(item) {
                mapping[source] = existing.node
                mapping.merge(existing.inner) { $1 }
                continue
            }
            try create(item, builder: &builder)
        }
    }

    /// `tree` with every reference to a mapped node rewritten.
    func rewrite(_ tree: NodeTree) -> NodeTree {
        ReferenceRewriting.rewrite(tree, schema: state.schema) { mapping[$0] }
    }

    /// Resources before the resources and symbols that reference them (depth first, a cycle cut
    /// where it closes).
    static func ordered(_ items: [SymbolPackage.Resource], schema: Schema) -> [SymbolPackage.Resource] {
        let index = Dictionary(items.compactMap { item in item.tree.source.map { ($0, item) } }) { first, _ in first }
        var done: Set<OpID> = []
        var visiting: Set<OpID> = []
        var out: [SymbolPackage.Resource] = []
        func visit(_ item: SymbolPackage.Resource) {
            guard let source = item.tree.source, !done.contains(source), !visiting.contains(source) else { return }
            visiting.insert(source)
            for target in ReferenceRewriting.targets(in: item.tree, schema: schema) {
                if let dependency = index[target] { visit(dependency) }
            }
            visiting.remove(source)
            done.insert(source)
            out.append(item)
        }
        items.forEach(visit)
        return out
    }

    /// An existing node that stands for `item`: an asset of the same hash, a swatch, style or
    /// brush of the same kind and name, or a symbol of the same name and the same artwork (with
    /// its artwork nodes paired with the item's, for references into it).
    func match(_ item: SymbolPackage.Resource) -> (node: OpID, inner: [OpID: OpID])? {
        let props = item.tree.props
        let candidates = item.collection == WellKnown.symbols ? Symbols.symbols(in: state) : state.liveChildren(item.collection)
        for candidate in candidates where state.props(candidate).kind.map(Self.caseName) == props.kind.map(Self.caseName) {
            let existing = state.props(candidate)
            if case .asset(let asset)? = props.kind {
                if case .asset(let other)? = existing.kind, !asset.sha256.isEmpty, other.sha256 == asset.sha256 { return (candidate, [:]) }
                continue
            }
            let name = Self.name(existing)
            if item.collection != WellKnown.symbols {
                if name == Self.name(props) { return (candidate, [:]) }
                continue
            }
            // A symbol under its own name, or under the numbered name an earlier paste gave it.
            guard Self.isName(name, variantOf: Self.name(props)) else { continue }
            if let pairs = identical(item.tree, NodeTree(candidate, state: state)) { return (candidate, pairs) }
        }
        return nil
    }

    /// The pairing of `source`'s nodes with `existing`'s when the two are the same artwork once
    /// references are mapped (internal ones by position), else nil.
    func identical(_ source: NodeTree, _ existing: NodeTree) -> [OpID: OpID]? {
        let left = source.flattened.compactMap(\.source)
        let right = existing.flattened.compactMap(\.source)
        guard left.count == right.count else { return nil }
        let pairs = Dictionary(zip(left, right)) { first, _ in first }
        let placeholders = Dictionary(right.enumerated().map { ($0.element, OpID(counter: UInt64($0.offset + 1), replica: 0)) }) { first, _ in first }
        func canonical(_ tree: NodeTree, _ map: (OpID) -> OpID?) -> NodeTree {
            var out = ReferenceRewriting.rewrite(tree, schema: state.schema, clearingElements: true, map)
            out.strip()
            return out
        }
        let a = canonical(source) { id in pairs[id].flatMap { placeholders[$0] } ?? mapping[id] }
        var b = canonical(existing) { placeholders[$0] }
        // A symbol's name and library link are not its artwork.
        b.props.symbol.common.name = a.props.symbol.common.name
        var c = a
        c.props.symbol.clearSource()
        c.props.symbol.common.clearLibrary()
        b.props.symbol.clearSource()
        b.props.symbol.common.clearLibrary()
        return c == b ? pairs : nil
    }

    /// Creates `item` in its collection above the collection's last child, under a free name when
    /// it is a symbol whose name is taken.
    mutating func create(_ item: SymbolPackage.Resource, builder: inout ChangeBuilder) throws {
        var tree = item.tree
        if item.collection == WellKnown.symbols {
            tree.props.symbol.common.name = freeName(tree.props.symbol.common.name)
            tree.props.symbol.clearSource()
        }
        let parent = item.collection
        let last = lastKeys[parent] ?? state.store.children(parent).last.flatMap { state.store.placement($0)?.position }
        let key = try FractionalIndex.between(last, nil, suffix: builder.nextCounter)
        lastKeys[parent] = key
        // A dry run learns the ids the copy's nodes will take, so references between them -- and
        // to it -- can be written in the one create.
        var dry = ChangeBuilder(replica: builder.replica, startCounter: builder.nextCounter)
        var inner: [OpID: OpID] = [:]
        _ = try NodeCopier.create(tree, parent: parent, position: key, schema: state.schema, builder: &dry, mapping: &inner)
        mapping.merge(inner) { $1 }
        var created: [OpID: OpID] = [:]
        _ = try NodeCopier.create(rewrite(tree), parent: parent, position: key, schema: state.schema, builder: &builder, mapping: &created)
    }

    /// `name`, or the first of "name 2", "name 3" … no live symbol (nor one created here) has.
    mutating func freeName(_ name: String) -> String {
        if names[WellKnown.symbols] == nil {
            names[WellKnown.symbols] = Set(Symbols.symbols(in: state).map { state.props($0).symbol.common.name })
        }
        var taken = names[WellKnown.symbols]!
        var candidate = name
        var number = 2
        while taken.contains(candidate) {
            candidate = "\(name) \(number)"
            number += 1
        }
        taken.insert(candidate)
        names[WellKnown.symbols] = taken
        return candidate
    }

    /// Whether `name` is `base` or `base` with a number appended ("Star 2").
    static func isName(_ name: String, variantOf base: String) -> Bool {
        guard name != base else { return true }
        guard name.hasPrefix(base + " ") else { return false }
        let suffix = name.dropFirst(base.count + 1)
        return !suffix.isEmpty && suffix.allSatisfy(\.isASCII) && suffix.allSatisfy(\.isNumber)
    }

    /// The kind case's name, for comparing kinds.
    static func caseName(_ kind: Wiretuner_Doc_V1_NodeProps.OneOf_Kind) -> String {
        String(describing: kind).prefix { $0 != "(" }.description
    }

    /// A node's `CommonProps.name` (field 1 of the kind's message, for every kind).
    static func name(_ props: Wiretuner_Doc_V1_NodeProps) -> String {
        let bytes = Wire.bytes { try props.serializedBytes() }
        guard let kind = WireReader.fields(bytes)?.last, kind.wireType == 2, let common = WireFields.payload(of: 1, in: kind.payload),
              let parsed = try? Wiretuner_Doc_V1_CommonProps(serializedBytes: common) else { return "" }
        return parsed.name
    }
}

extension NodeTree {
    /// The tree without its source ids (for comparing content).
    mutating func strip() {
        source = nil
        for index in children.indices { children[index].strip() }
    }
}
