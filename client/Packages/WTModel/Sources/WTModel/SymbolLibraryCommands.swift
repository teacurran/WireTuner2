import WTCRDT
import WTGeometry
import WTProto

// LIB-009 (library.adoc, "Creating symbols", "Removing symbols", "Merge semantics"): the symbol
// commands beyond ConvertToSymbol, PlaceInstance, SwapSymbol, ReleaseInstances and the override
// commands of SymbolCommands.swift, and the Library list with its deleted-folder normalization.

/// Why a Library list command could not build its change.
public enum SymbolLibraryError: Error, Equatable, Sendable {
    /// Not a live symbol folder.
    case notAFolder(OpID)
    /// Not a live symbol or folder.
    case notInLibrary(OpID)
    /// A folder cannot move into itself or one of its own folders.
    case folderIntoItself(OpID)
}

/// What *Remove* does with the instances of the symbols it removes (the removal sheet).
public enum InstanceHandling: Hashable, Sendable {
    /// btn:[Release Instances]: each becomes an ordinary group of the resolved artwork.
    case release
    /// btn:[Delete Instances]: each is deleted.
    case delete
}

/// One row of the Library list: a symbol or a folder with its rows.
public indirect enum SymbolLibraryEntry: Hashable, Sendable {
    case symbol(OpID)
    case folder(OpID, name: String, entries: [SymbolLibraryEntry])
}

extension Symbols {
    /// The Library list in tree order: live folders with their contents, symbols; a symbol or
    /// folder whose parent folder is deleted is listed at the top level (after the rest).
    public static func library(in state: EngineState) -> [SymbolLibraryEntry] {
        var lifted: [SymbolLibraryEntry] = []
        func entries(_ parent: OpID, into top: inout [SymbolLibraryEntry]) -> [SymbolLibraryEntry] {
            var result: [SymbolLibraryEntry] = []
            for child in state.store.children(parent) {
                switch state.props(child).kind {
                case .symbol?:
                    if state.isLive(child) { result.append(.symbol(child)) }
                case .symbolFolder(let folder)?:
                    if state.isLive(child) {
                        result.append(.folder(child, name: folder.common.name, entries: entries(child, into: &top)))
                    } else {
                        top += entries(child, into: &top)
                    }
                default:
                    break
                }
            }
            return result
        }
        let root = entries(WellKnown.symbols, into: &lifted)
        return root + lifted
    }
}

/// menu:Modify[Symbol > Copy to Symbol]: like Convert to Symbol, but the selection stays as it is
/// and deep copies of it (flattened into symbol space) become the new symbol's artwork, with the
/// origin at the selection's bounds centre.  One change "Copy to Symbol".
public struct CopyToSymbol: Command {
    public var nodes: [OpID]
    public var name: String?
    public var label: String { "Copy to Symbol" }

    public init(_ nodes: [OpID], name: String? = nil) {
        self.nodes = nodes
        self.name = name
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let objects = nodes.filter { Objects.isObject($0, in: state) }
        let selected = Set(objects)
        let members = Objects.stackingOrder(objects.filter { !SymbolEditing.hasAncestor(in: selected, $0, state: state) }, in: state)
        guard !members.isEmpty else { return }
        let origin = SymbolLibraryEditing.center(of: members, in: state)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.symbol.common.name = name ?? SymbolEditing.defaultName(for: members, in: state)
        props.symbol.origin = PathEditing.proto(origin)
        let symbol = builder.append(Ops.create(parent: WellKnown.symbols, position: try PathEditing.topPosition(in: WellKnown.symbols, state: state),
                                               props: props))
        var mapping: [OpID: OpID] = [:]
        var copied: [NodeTree] = []
        let keys = try PathEditing.keys(between: nil, and: nil, count: members.count)
        for (member, key) in zip(members, keys) {
            var tree = NodeTree(member, state: state)
            tree.transform = Objects.pasteboardTransform(of: member, in: state)
            copied.append(tree)
            try NodeCopier.create(tree, parent: symbol, position: key, schema: state.schema, builder: &builder, mapping: &mapping)
        }
        NodeCopier.rewriteReferences(in: copied, mapping: mapping, builder: &builder)
    }
}

/// *Duplicate* in the Library panel: per symbol, a new symbol directly above it (in its folder)
/// with its registers, " copy" appended to the name, no library source, and deep copies of its
/// artwork.  Independent of anything concurrent.  "Duplicate Symbol" / "Duplicate N symbols".
public struct DuplicateSymbols: Command {
    public var symbols: [OpID]
    public var label: String { symbols.count == 1 ? "Duplicate Symbol" : "Duplicate \(symbols.count) symbols" }

    public init(_ symbols: [OpID]) {
        self.symbols = symbols
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for symbol in symbols {
            guard state.isLive(symbol), state.nodeKind(symbol) == .symbol, let parent = state.store.placement(symbol)?.parent else {
                throw SymbolError.notASymbol(symbol)
            }
            var tree = NodeTree(symbol, state: state)
            tree.props.symbol.common.name += " copy"
            tree.props.symbol.clearSource()
            tree.props.symbol.common.clearLibrary()
            let key = try Arranging.keys(next: symbol, above: true, count: 1, in: state)[0]
            try NodeCopier.create(tree, parent: parent, position: key, schema: state.schema, builder: &builder)
        }
    }
}

/// Dropping an object on a symbol and clicking btn:[Replace] (library.adoc, "Replace symbol
/// artwork"): one change deleting the symbol's artwork, moving the objects under it flattened into
/// symbol space, moving the origin to their bounds centre, and creating an instance where they
/// were (in place when they share a parent, else on top of `layer`).  A concurrent Replace leaves
/// both new sets live.  "Replace Symbol Artwork".
public struct ReplaceSymbolArtwork: Command {
    public var symbol: OpID
    public var nodes: [OpID]
    public var layer: OpID?
    public var label: String { "Replace Symbol Artwork" }

    public init(_ symbol: OpID, with nodes: [OpID], layer: OpID? = nil) {
        self.symbol = symbol
        self.nodes = nodes
        self.layer = layer
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard state.isLive(symbol), state.nodeKind(symbol) == .symbol else { throw SymbolError.notASymbol(symbol) }
        let editable = Objects.editable(nodes, in: state).filter { $0 != symbol && Symbols.enclosingSymbol(of: $0, in: state) != symbol }
        let selected = Set(editable)
        let members = Objects.stackingOrder(editable.filter { !SymbolEditing.hasAncestor(in: selected, $0, state: state) }, in: state)
        guard let top = members.last else { return }
        let origin = SymbolLibraryEditing.center(of: members, in: state)
        let parents = Set(members.compactMap { Objects.parent(of: $0, in: state) })
        let parent: OpID
        let position: [UInt8]
        if parents.count == 1, let only = parents.first {
            parent = only
            position = try Arranging.keys(next: top, above: true, count: 1, in: state)[0]
        } else {
            parent = try PathEditing.ensureLayer(&builder, state: state, preferred: layer)
            position = try PathEditing.topPosition(in: parent, state: state)
        }
        for old in state.liveChildren(symbol) {
            builder.append(Ops.setDeleted(old))
        }
        var values = Wiretuner_Doc_V1_NodeProps()
        values.symbol.origin = PathEditing.proto(origin)
        builder.append(Ops.set(symbol, [SymbolFields.origin], values: values))
        let keys = try PathEditing.keys(between: state.store.children(symbol).last.flatMap { state.store.placement($0)?.position }, and: nil,
                                        count: members.count)
        for (member, key) in zip(members, keys) {
            let kind = try Objects.kind(member, in: state)
            let flattened = Objects.pasteboardTransform(of: member, in: state)
            builder.append(Ops.move(member, parent: symbol, position: key))
            if flattened != Objects.transform(of: member, in: state) {
                builder.append(Objects.setTransform(member, kind: kind, flattened))
            }
        }
        let placement = AffineTransform.translation(x: origin.x, y: origin.y).concatenating(Objects.pasteboardTransform(ofSpace: parent, in: state).inverse)
        builder.append(Ops.create(parent: parent, position: position, props: SymbolEditing.instanceProps(symbol, transform: placement)))
    }
}

/// *Remove* in the Library panel (library.adoc, "Delete symbol versus place instance"): one
/// change that, for every instance of the removed symbols this replica sees (outside their own
/// artwork), releases it or deletes it, then deletes each symbol and every node of its artwork,
/// and each removed folder with the symbols and folders in it.  "Remove symbol Star", "Remove
/// symbol Star and 12 instances", "Remove 3 symbols and 12 instances".
public struct RemoveSymbols: Command {
    public var nodes: [OpID]
    public var instances: InstanceHandling
    public let label: String

    public init(_ nodes: [OpID], instances: InstanceHandling, in state: EngineState) {
        self.nodes = nodes
        self.instances = instances
        let plan = Self.plan(nodes, in: state)
        var text = plan.symbols.count == 1
            ? "Remove symbol \(state.props(plan.symbols[0]).symbol.common.name)"
            : plan.symbols.isEmpty && plan.folders.count == 1 ? "Remove folder \(state.props(plan.folders[0]).symbolFolder.common.name)"
            : "Remove \(plan.symbols.count) symbols"
        if !plan.instances.isEmpty { text += " and \(plan.instances.count) \(plan.instances.count == 1 ? "instance" : "instances")" }
        label = text
    }

    /// The symbols (in order, folders' contents included), folders and instances a removal of
    /// `nodes` touches.
    static func plan(_ nodes: [OpID], in state: EngineState) -> (symbols: [OpID], folders: [OpID], instances: [OpID]) {
        var symbols: [OpID] = []
        var folders: [OpID] = []
        func folder(_ id: OpID) {
            folders.append(id)
            for child in state.store.children(id) {
                switch state.props(child).kind {
                case .symbol?: if state.isLive(child) { symbols.append(child) }
                case .symbolFolder?: if state.isLive(child) { folder(child) }
                default: break
                }
            }
        }
        for node in nodes where state.isLive(node) {
            switch state.props(node).kind {
            case .symbol?: symbols.append(node)
            case .symbolFolder?: folder(node)
            default: break
            }
        }
        var seen: Set<OpID> = []
        symbols = symbols.filter { seen.insert($0).inserted }
        let removed = Set(symbols)
        let index = Symbols.instanceIndex(in: state)
        let instances = symbols.flatMap { index[$0] ?? [] }.filter { instance in
            Symbols.enclosingSymbol(of: instance, in: state).map { !removed.contains($0) } ?? true
        }
        return (symbols, folders, instances)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in nodes where !state.isLive(node) || !(SymbolLibraryEditing.is(node, .symbol, state) || SymbolLibraryEditing.is(node, .symbolFolder, state)) {
            throw SymbolLibraryError.notInLibrary(node)
        }
        let plan = Self.plan(nodes, in: state)
        switch instances {
        case .release:
            try ReleaseInstances(plan.instances).execute(&builder, state: state)
        case .delete:
            for instance in Objects.editable(plan.instances, in: state) {
                builder.append(Ops.setDeleted(instance))
            }
        }
        for symbol in plan.symbols {
            builder.append(Ops.setDeleted(symbol))
            for node in Symbols.artworkNodes(of: symbol, in: state).sorted() {
                builder.append(Ops.setDeleted(node))
            }
        }
        for folder in plan.folders {
            builder.append(Ops.setDeleted(folder))
        }
    }
}

/// btn:[New folder] / *New Folder*: a folder at the top of the list or of `parent` (a folder),
/// named `name` or the first free "Folder N".  "New Folder".
public struct CreateSymbolFolder: Command {
    public var name: String?
    public var parent: OpID?
    public var label: String { "New Folder" }

    public init(name: String? = nil, in parent: OpID? = nil) {
        self.name = name
        self.parent = parent
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let container = parent ?? WellKnown.symbols
        if let parent, !(state.isLive(parent) && SymbolLibraryEditing.is(parent, .symbolFolder, state)) { throw SymbolLibraryError.notAFolder(parent) }
        var props = Wiretuner_Doc_V1_NodeProps()
        props.symbolFolder.common.name = name ?? SymbolLibraryEditing.freeFolderName(in: state)
        builder.append(Ops.create(parent: container, position: try PathEditing.topPosition(in: container, state: state), props: props))
    }
}

/// Dragging symbols and folders into a folder (or out to the top level, `folder` nil): one
/// `MoveNode` each, to the top of the destination, in their list order.  A folder cannot go into
/// itself or its own folders.  "Move to Folder" / "Move to Top Level".
public struct MoveSymbolsToFolder: Command {
    public var nodes: [OpID]
    public var folder: OpID?
    public var label: String { folder == nil ? "Move to Top Level" : "Move to Folder" }

    public init(_ nodes: [OpID], to folder: OpID?) {
        self.nodes = nodes
        self.folder = folder
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let destination = folder ?? WellKnown.symbols
        if let folder {
            guard state.isLive(folder), SymbolLibraryEditing.is(folder, .symbolFolder, state) else { throw SymbolLibraryError.notAFolder(folder) }
        }
        var ancestors: Set<OpID> = []
        var current: OpID? = destination
        while let id = current, id != WellKnown.symbols {
            ancestors.insert(id)
            current = state.store.placement(id)?.parent
        }
        var last = state.store.children(destination).last.flatMap { state.store.placement($0)?.position }
        for node in nodes {
            guard state.isLive(node), SymbolLibraryEditing.is(node, .symbol, state) || SymbolLibraryEditing.is(node, .symbolFolder, state) else {
                throw SymbolLibraryError.notInLibrary(node)
            }
            if ancestors.contains(node) { throw SymbolLibraryError.folderIntoItself(node) }
            let key = try PathEditing.keys(between: last, and: nil, count: 1)[0]
            last = key
            builder.append(Ops.move(node, parent: destination, position: key))
        }
    }
}

/// Helpers of the Library list commands.
enum SymbolLibraryEditing {
    enum Kind { case symbol, symbolFolder }

    static func `is`(_ node: OpID, _ kind: Kind, _ state: EngineState) -> Bool {
        switch (kind, state.props(node).kind) {
        case (.symbol, .symbol?), (.symbolFolder, .symbolFolder?): true
        default: false
        }
    }

    /// The centre of the objects' bounds (the origin; zero when none has bounds).
    static func center(of members: [OpID], in state: EngineState) -> Point {
        var bounds = Rect.null
        for member in members {
            if let rect = Objects.bounds(of: member, in: state) { bounds = bounds.union(rect) }
        }
        return bounds.isNull ? .zero : Point(x: bounds.midX, y: bounds.midY)
    }

    /// The first "Folder N" no live folder has.
    static func freeFolderName(in state: EngineState) -> String {
        var taken: Set<String> = []
        var pending = [WellKnown.symbols]
        while let next = pending.popLast() {
            for child in state.liveChildren(next) {
                if case .symbolFolder(let folder)? = state.props(child).kind {
                    taken.insert(folder.common.name)
                    pending.append(child)
                }
            }
        }
        var number = 1
        while taken.contains("Folder \(number)") { number += 1 }
        return "Folder \(number)"
    }
}
