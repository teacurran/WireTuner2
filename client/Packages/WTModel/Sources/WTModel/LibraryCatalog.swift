import WTCRDT
import WTGeometry
import WTProto

// COLLAB-015: team libraries inside a document (sharing.adoc, "Team libraries", "Merge semantics"
// and "Client").  A library is another document of the team; what the panels offer from it is
// read from its cached store (opened read-only by WTSync, which hands the merged states in), and
// what the user takes is *copied* into this document with fresh ids, remembering where it came
// from in `CommonProps.library` (ATOMIC: document, source node and the library's head when
// copied).  Two people copying the same item make two nodes; nothing deduplicates them.

/// One cached team library as the catalog reads it.
public struct LibrarySource: Sendable {
    /// The library document's id (`LibraryProvenance.library_document_id`).
    public var documentID: String
    public var name: String
    /// The library's head server seq as cached (`source_server_seq` of what is copied now).
    public var headSeq: UInt64
    /// The library document's merged state.
    public var state: EngineState

    public init(documentID: String, name: String, headSeq: UInt64, state: EngineState) {
        self.documentID = documentID
        self.name = name
        self.headSeq = headSeq
        self.state = state
    }
}

/// Opens the cached library stores of this Mac read-only (WTSync's store cache): what the catalog
/// is loaded from.  A library never opened here is not cached, so it is not listed offline.
public protocol LibraryStoreOpening: Sendable {
    func cachedLibraries() async throws -> [LibrarySource]
}

/// The team libraries the panels list (*Team libraries* in the Swatches, Styles and Library
/// panels): each library's live swatches, styles and symbols, read from its cached state.
public struct LibraryCatalog: Sendable {
    /// What a panel lists.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case swatch, style, symbol
    }

    /// One item of one library.
    public struct Item: Hashable, Sendable, Identifiable {
        public var library: String
        public var node: OpID
        public var kind: Kind
        public var name: String
        public var id: String { "\(library)/\(node.counter):\(node.replica)" }
    }

    /// One library's items of one kind, for a panel section.
    public struct Section: Hashable, Sendable {
        public var library: String
        public var name: String
        public var items: [Item]
    }

    public let libraries: [LibrarySource]

    public init(_ libraries: [LibrarySource]) {
        self.libraries = libraries.sorted { ($0.name.lowercased(), $0.documentID) < ($1.name.lowercased(), $1.documentID) }
    }

    /// The catalog of every library `opener` has cached.
    public static func load(from opener: some LibraryStoreOpening) async throws -> LibraryCatalog {
        LibraryCatalog(try await opener.cachedLibraries())
    }

    /// The library `documentID`, when cached.
    public func library(_ documentID: String) -> LibrarySource? {
        libraries.first { $0.documentID == documentID }
    }

    /// The *Team libraries* sections of one panel: one per library with items of `kind`, by
    /// library name.
    public func sections(_ kind: Kind) -> [Section] {
        libraries.compactMap { library in
            let items = Self.items(kind, in: library)
            return items.isEmpty ? nil : Section(library: library.documentID, name: library.name, items: items)
        }
    }

    /// The live items of `kind` in `library`, in its panel order.
    static func items(_ kind: Kind, in library: LibrarySource) -> [Item] {
        let state = library.state
        switch kind {
        case .swatch:
            return SwatchList(state).swatches.filter { !$0.isProtected }.map { Item(library: library.documentID, node: $0.id, kind: .swatch, name: $0.name) }
        case .style:
            return state.liveChildren(LibraryCopying.styles).filter { state.store.kind($0) == LibraryCopying.styleKind }.map {
                Item(library: library.documentID, node: $0, kind: .style, name: state.props($0).style.common.name)
            }
        case .symbol:
            return Symbols.symbols(in: state).map { Item(library: library.documentID, node: $0, kind: .symbol, name: state.props($0).symbol.common.name) }
        }
    }
}

/// The library badge the panels and the Object panel draw on a copied node.
public struct LibraryBadge: Hashable, Sendable {
    public var documentID: String
    public var sourceNode: OpID
    public var copiedSeq: UInt64
    /// The library's name, or nil when this user cannot see it ("from a library you can't
    /// access": the badge still renders).
    public var libraryName: String?
    /// The library's head is past the copied version (*Update from Library* has something to do).
    public var updateAvailable: Bool

    /// The hover text.
    public var tooltip: String {
        guard let libraryName else { return "From a library you can't access" }
        return updateAvailable ? "From \(libraryName) (a newer version is available)" : "From \(libraryName)"
    }

    /// The badge of `node`, or nil when it was not copied from a library.  `catalog` names the
    /// libraries this user can see (and their heads).
    public static func of(_ node: OpID, in state: EngineState, catalog: LibraryCatalog) -> LibraryBadge? {
        guard let provenance = LibraryCopying.provenance(of: node, in: state) else { return nil }
        let library = catalog.library(provenance.libraryDocumentID)
        return LibraryBadge(documentID: provenance.libraryDocumentID, sourceNode: OpID(provenance.sourceNode), copiedSeq: provenance.sourceServerSeq,
                            libraryName: library?.name, updateAvailable: library.map { $0.headSeq > provenance.sourceServerSeq } ?? false)
    }
}

/// Why a library command could not build its change.
public enum LibraryCopyError: Error, Equatable, Sendable {
    /// The item is not a live swatch, style or symbol of the library.
    case notInLibrary(OpID)
    /// The node was not copied from this library (or is not live).
    case notFromLibrary(OpID)
}

/// Double-clicking (or dropping) a team-library swatch, style or symbol: a copy under this
/// document's `swatches`, `styles` or `symbols` with fresh ids and `library` set, one change "Add
/// swatch "Brand red" from Marketing library".  Everything the item references in the library --
/// the base of a tint, a style's swatches, a symbol's swatches, styles, brushes, assets and nested
/// symbols -- comes along, each with its own provenance, unless this document already holds a live
/// copy of it from the same library (or, for an asset, one with the same hash), which is reused;
/// every reference inside the copies names the local node.
public struct CopyFromLibrary: Command {
    public var item: OpID
    public var library: LibrarySource

    public init(_ item: OpID, from library: LibrarySource) {
        self.item = item
        self.library = library
    }

    public var label: String {
        let state = library.state
        let noun: String
        switch state.store.kind(item) {
        case NodeKind.symbol.rawValue: noun = "symbol"
        case LibraryCopying.styleKind: noun = "style"
        default: noun = "swatch"
        }
        let name = LibraryCopying.common(state.props(item))?.name ?? ""
        return "Add \(noun) \(Swatches.quoted(name)) from \(library.name) library"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard LibraryCopying.isItem(item, in: library.state) else { throw LibraryCopyError.notInLibrary(item) }
        var copier = LibraryCopying(library: library, state: state)
        _ = try copier.copy(item, builder: &builder)
    }
}

/// menu:Actions[Update from Library] on a copied swatch, style or symbol: the library's current
/// version is written over the copy -- only the registers that differ (a style's attribute stack
/// replaced when it differs; a symbol's artwork deleted and copied again) -- and
/// `library.source_server_seq` moves to the library's head.  Concurrent local edits of the same
/// registers resolve by OpId like any edit.  "Update from Library".
public struct UpdateFromLibrary: Command {
    public var nodes: [OpID]
    public var library: LibrarySource
    public var label: String { "Update from Library" }

    public init(_ nodes: [OpID], from library: LibrarySource) {
        self.nodes = nodes
        self.library = library
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var copier = LibraryCopying(library: library, state: state)
        for node in nodes {
            guard state.isLive(node), let provenance = LibraryCopying.provenance(of: node, in: state),
                  provenance.libraryDocumentID == library.documentID else { throw LibraryCopyError.notFromLibrary(node) }
            let source = OpID(provenance.sourceNode)
            guard LibraryCopying.isItem(source, in: library.state) else { throw LibraryCopyError.notInLibrary(source) }
            try copier.update(node, from: source, builder: &builder)
        }
    }
}

/// menu:Actions[Detach from Library]: `library` written unset on each copied node, so it is an
/// ordinary node of this document.  "Detach from Library".
public struct DetachFromLibrary: Command {
    public var nodes: [OpID]
    public var label: String { "Detach from Library" }

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in nodes where state.isLive(node) && LibraryCopying.provenance(of: node, in: state) != nil {
            builder.append(Ops.set(node, [LibraryCopying.provenancePath(state.store.kind(node))], values: Wiretuner_Doc_V1_NodeProps()))
        }
    }
}

/// The copying machinery of the library commands.
struct LibraryCopying {
    /// The well-known `styles` collection (0:6), `brushes` (0:8) and `assets` (0:9).
    static let styles = OpID.wellKnown(6)
    static let brushes = OpID.wellKnown(8)
    static let assets = OpID.wellKnown(9)
    /// The collections references are followed into.
    static let collections: Set<OpID> = [WellKnown.swatches, styles, brushes, assets]
    /// The raw kinds of swatches (70) and styles (154).
    static let swatchKind: UInt32 = 70
    static let styleKind: UInt32 = 154

    /// The common props of a swatch, style, symbol, brush or asset (and of the objects
    /// `NodeValues` reads).
    static func common(_ props: Wiretuner_Doc_V1_NodeProps) -> Wiretuner_Doc_V1_CommonProps? {
        switch props.kind {
        case .swatch(let swatch)?: swatch.common
        case .style(let style)?: style.common
        case .asset(let asset)?: asset.common
        default: NodeValues.common(props)
        }
    }

    let library: LibrarySource
    let state: EngineState
    /// Library node → the local node standing for it (an existing copy, or one made here).
    var copies: [OpID: OpID] = [:]
    /// The next key under each collection, so several copies in one change do not collide.
    var lastKey: [OpID: [UInt8]] = [:]

    init(library: LibrarySource, state: EngineState) {
        self.library = library
        self.state = state
        // Live copies from this library, and assets by hash.
        var byHash: [[UInt8]: OpID] = [:]
        for asset in state.liveChildren(Self.assets) {
            if case .asset(let props)? = state.props(asset).kind, !props.sha256.isEmpty { byHash[Array(props.sha256)] = asset }
        }
        let roots = state.liveChildren(WellKnown.swatches) + state.liveChildren(Self.styles) + Symbols.symbols(in: state) + state.liveChildren(Self.brushes)
        for node in roots {
            if let provenance = Self.provenance(of: node, in: state), provenance.libraryDocumentID == library.documentID {
                copies[OpID(provenance.sourceNode)] = node
            }
        }
        for asset in library.state.liveChildren(Self.assets) {
            if case .asset(let props)? = library.state.props(asset).kind, let local = byHash[Array(props.sha256)] { copies[asset] = local }
        }
    }

    /// Whether `node` is a live swatch, style or symbol of `state`.
    static func isItem(_ node: OpID, in state: EngineState) -> Bool {
        guard state.isLive(node) else { return false }
        switch state.store.kind(node) {
        case swatchKind: return state.store.placement(node)?.parent == WellKnown.swatches
        case styleKind: return state.store.placement(node)?.parent == styles
        case NodeKind.symbol.rawValue: return Symbols.symbols(in: state).contains(node)
        default: return false
        }
    }

    /// `CommonProps.library` of a node, when set.
    static func provenance(of node: OpID, in state: EngineState) -> Wiretuner_Doc_V1_LibraryProvenance? {
        guard let common = common(state.props(node)), common.hasLibrary else { return nil }
        return common.library
    }

    /// The register path of `CommonProps.library` on a node of raw kind `kind`.
    static func provenancePath(_ kind: UInt32) -> RegisterPath { RegisterPath([kind, 1, 20]) }

    /// `props` (a swatch, style, symbol, brush or asset) with `library` set.
    static func withProvenance(_ props: Wiretuner_Doc_V1_NodeProps, _ provenance: Wiretuner_Doc_V1_LibraryProvenance) -> Wiretuner_Doc_V1_NodeProps {
        var props = props
        switch props.kind {
        case .swatch?: props.swatch.common.library = provenance
        case .style?: props.style.common.library = provenance
        case .symbol?: props.symbol.common.library = provenance
        case .brush?: props.brush.common.library = provenance
        case .asset?: props.asset.common.library = provenance
        default: break
        }
        return props
    }

    /// `props` of any kind with `CommonProps.library` set (field 1 of every kind is its common props).
    static func withObjectProvenance(_ props: Wiretuner_Doc_V1_NodeProps, _ provenance: Wiretuner_Doc_V1_LibraryProvenance) -> Wiretuner_Doc_V1_NodeProps {
        guard let field = WireReader.fields(Wire.bytes { try props.serializedBytes() })?.last, let kind = NodeKind(rawValue: UInt32(field.number)) else { return props }
        var out = props
        let sparse = NodeValues.common(kind: kind) { $0.library = provenance }
        try? out.merge(serializedBytes: Wire.bytes { try sparse.serializedBytes() })
        return out
    }

    func provenance(_ source: OpID) -> Wiretuner_Doc_V1_LibraryProvenance {
        var provenance = Wiretuner_Doc_V1_LibraryProvenance()
        provenance.libraryDocumentID = library.documentID
        provenance.sourceNode = source.proto
        provenance.sourceServerSeq = library.headSeq
        return provenance
    }

    /// The collection a library node is copied into.
    func collection(of node: OpID) -> OpID? {
        if library.state.nodeKind(node) == .symbol { return Symbols.symbols(in: library.state).contains(node) ? WellKnown.symbols : nil }
        guard let parent = library.state.store.placement(node)?.parent, Self.collections.contains(parent) else { return nil }
        return parent
    }

    /// A fresh key at the end of `parent`, after any made earlier in this change.
    mutating func nextKey(under parent: OpID) throws -> [UInt8] {
        let last = lastKey[parent] ?? state.store.children(parent).last.flatMap { state.store.placement($0)?.position }
        let key = try PathEditing.keys(between: last, and: nil, count: 1)[0]
        lastKey[parent] = key
        return key
    }

    /// `node`'s tree from the library with every reference to a copied node rewritten.
    func tree(_ node: OpID) -> NodeTree {
        ReferenceRewriting.rewrite(NodeTree(node, state: library.state), schema: state.schema) { copies[$0] }
    }

    /// Copies `node` (and first what it references) unless a copy exists; returns the local node.
    mutating func copy(_ node: OpID, builder: inout ChangeBuilder, visiting: Set<OpID> = []) throws -> OpID? {
        if let existing = copies[node] { return existing }
        guard let parent = collection(of: node), !visiting.contains(node) else { return nil }
        try copyReferences(of: node, builder: &builder, visiting: visiting.union([node]))
        var tree = self.tree(node)
        tree.props = Self.withProvenance(tree.props, provenance(node))
        let key = try nextKey(under: parent)
        let copy = try NodeCopier.create(tree, parent: parent, position: key, schema: state.schema, builder: &builder)
        copies[node] = copy
        return copy
    }

    /// Copies what `node`'s subtree references in the library's collections.
    mutating func copyReferences(of node: OpID, builder: inout ChangeBuilder, visiting: Set<OpID>) throws {
        let subtree = Set(NodeTree(node, state: library.state).flattened.compactMap(\.source))
        for target in ReferenceRewriting.targets(in: NodeTree(node, state: library.state), schema: library.state.schema)
        where !subtree.contains(target) && library.state.isLive(target) {
            _ = try copy(target, builder: &builder, visiting: visiting)
        }
    }

    /// Writes the library's current `source` over the local copy `node`.
    mutating func update(_ node: OpID, from source: OpID, builder: inout ChangeBuilder) throws {
        copies[source] = node
        try copyReferences(of: source, builder: &builder, visiting: [source])
        let kind = state.store.kind(node)
        if state.nodeKind(node) == .symbol {
            for child in state.liveChildren(node) { builder.append(Ops.setDeleted(child)) }
            let children = library.state.liveChildren(source)
            let keys = try PathEditing.keys(between: state.store.children(node).last.flatMap { state.store.placement($0)?.position }, and: nil,
                                            count: children.count)
            for (child, key) in zip(children, keys) {
                // Each copied child remembers the library child and version it came from, so two
                // concurrent updates read as one artwork set (`Symbols.artwork(of:in:)`).
                var copy = tree(child)
                copy.props = Self.withObjectProvenance(copy.props, provenance(child))
                try NodeCopier.create(copy, parent: node, position: key, schema: state.schema, builder: &builder)
            }
        }
        var tree = self.tree(source)
        tree.children = []
        try Self.writeDifferences(of: tree, over: node, kind: kind, in: state, builder: &builder)
        builder.append(Ops.set(node, [Self.provenancePath(kind)], values: Self.withProvenance(Wiretuner_Doc_V1_NodeProps.with { $0.kind = tree.props.kind },
                                                                                               provenance(source))))
    }

    /// The registers of `node` that differ from `tree`'s (outside sequences and `library`), in
    /// one `SetFields`; a style's attribute stack deleted and inserted again when it differs.
    static func writeDifferences(of tree: NodeTree, over node: OpID, kind: UInt32, in state: EngineState, builder: inout ChangeBuilder) throws {
        // The library's values as registers: the tree created in a scratch state.
        var scratchBuilder = ChangeBuilder(replica: 1, startCounter: 1)
        let scratchNode = try NodeCopier.create(tree, parent: state.store.placement(node)?.parent ?? WellKnown.swatches, position: [0x80],
                                                schema: state.schema, builder: &scratchBuilder)
        var scratch = EngineState(schema: state.schema)
        var change = Wiretuner_Doc_V1_Change()
        change.replica = 1
        change.seq = 1
        change.startCounter = 1
        change.ops = scratchBuilder.ops
        scratch.apply(change)
        let wanted = RestoreDiff.values(scratch, scratchNode)
        let now = RestoreDiff.values(state, node)
        let library = provenancePath(kind)
        let paths = Set(wanted.keys).union(now.keys).filter { path in
            !path.segments.contains { if case .element = $0 { true } else { false } } && !path.segments.starts(with: library.segments)
                && RestoreDiff.value(wanted, path) != RestoreDiff.value(now, path)
        }.sorted()
        if !paths.isEmpty {
            let values = RestoreValues.encode(paths.compactMap { path in RestoreDiff.value(wanted, path).map { (path, $0) } }) { _ in false }
            builder.append(Ops.set(node, paths, values: values))
        }
        // A style's stack: compared with element ids cleared, replaced whole when it differs.
        guard case .style(let wantedStyle)? = tree.props.kind, case .style(let current)? = state.props(node).kind else { return }
        func bare(_ appearance: Wiretuner_Doc_V1_AppearanceProps) -> [[UInt8]] {
            let clean = ReferenceRewriting.rewrite(NodeTree(props: .with { $0.style.appearance = appearance }), schema: state.schema, clearingElements: true) { _ in nil }
            return [Wire.bytes { try clean.props.serializedBytes() }]
        }
        guard bare(wantedStyle.appearance) != bare(current.appearance) else { return }
        for list: UInt32 in [1, 2, 3] {
            let path = RegisterPath([kind, 6, list])
            let live = state.liveElements(node, path)
            if !live.isEmpty { builder.append(Ops.elementDelete(node, live.map { path.element($0) })) }
        }
        var lists = wantedStyle.appearance
        lists.rasterDpi = 0
        let payload = Wire.bytes { try lists.serializedBytes() }
        try NodeCopier.copySequences("wiretuner.doc.v1.AppearanceProps", payload: payload, prefix: RegisterPath([kind, 6]), node: node, schema: state.schema,
                                     wrap: { Wire.field(kind, Wire.field(6, $0)) }, builder: &builder)
    }
}

/// Following and rewriting the node references inside node props, wherever the schema puts an
/// `OpId` (a `NodeRef`'s id, a colour's swatch, a style's `based_on`, an instance's symbol...).
enum ReferenceRewriting {
    static let opID = "wiretuner.doc.v1.OpId"
    static let elementID = "wiretuner.doc.v1.ElementId"

    /// Every id `tree`'s nodes reference, in first-reference order.
    static func targets(in tree: NodeTree, schema: Schema) -> [OpID] {
        var out: [OpID] = []
        var seen: Set<OpID> = []
        for node in tree.flattened {
            _ = walk(Schema.root, Wire.bytes { try node.props.serializedBytes() }, schema: schema, clearingElements: false) { id in
                if seen.insert(id).inserted { out.append(id) }
                return nil
            }
        }
        return out
    }

    /// `tree` with each referenced id `map` answers replaced (and, with `clearingElements`, every
    /// sequence element id left out, for comparing content).
    static func rewrite(_ tree: NodeTree, schema: Schema, clearingElements: Bool = false, _ map: (OpID) -> OpID?) -> NodeTree {
        var out = tree
        let bytes = Wire.bytes { try tree.props.serializedBytes() }
        if let props = try? Wiretuner_Doc_V1_NodeProps(serializedBytes: walk(Schema.root, bytes, schema: schema, clearingElements: clearingElements, map)) {
            out.props = props
        }
        out.children = tree.children.map { rewrite($0, schema: schema, clearingElements: clearingElements, map) }
        return out
    }

    static func walk(_ message: String, _ bytes: [UInt8], schema: Schema, clearingElements: Bool, _ visit: (OpID) -> OpID?) -> [UInt8] {
        guard let fields = WireReader.fields(bytes) else { return bytes }
        var out: [UInt8] = []
        for field in fields {
            guard field.wireType == 2, let type = schema.field(message, Int(field.number))?.typeName else {
                out += field.record
                continue
            }
            if type == opID, let id = try? Wiretuner_Doc_V1_OpId(serializedBytes: field.payload) {
                let original = OpID(id)
                out += Wire.field(field.number, Wire.bytes { try (visit(original) ?? original).proto.serializedBytes() })
            } else if type == elementID, clearingElements {
                continue
            } else if !schema.fields(type).isEmpty {
                out += Wire.field(field.number, walk(type, field.payload, schema: schema, clearingElements: clearingElements, visit))
            } else {
                out += field.record
            }
        }
        return out
    }
}
