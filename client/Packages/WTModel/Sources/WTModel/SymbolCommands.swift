import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// Why a symbol command could not build its change.
public enum SymbolError: Error, Equatable, Sendable {
    case notASymbol(OpID)
    case notAnInstance(OpID)
    /// The node is not overridable in the instance's symbol (not in its artwork, or the wrong
    /// kind for the property).
    case notOverridable(OpID)
}

/// menu:Modify[Symbol > Convert to Symbol] (library.adoc, "Creating symbols"): one change creating
/// a symbol under the well-known `symbols` node, moving the selected objects (bottom first) into it
/// with their transforms flattened into symbol space (= pasteboard space), and creating an instance
/// where they were -- in place when they share a parent, else on top of the active layer -- whose
/// transform places the symbol's origin (the selection's bounds centre) where it was.
public struct ConvertToSymbol: Command {
    public var nodes: [OpID]
    public var name: String?
    public var layer: OpID?
    public var label: String { "Convert to Symbol" }

    public init(_ nodes: [OpID], name: String? = nil, layer: OpID? = nil) {
        self.nodes = nodes
        self.name = name
        self.layer = layer
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let editable = Objects.editable(nodes, in: state)
        let selected = Set(editable)
        let members = Objects.stackingOrder(editable.filter { !SymbolEditing.hasAncestor(in: selected, $0, state: state) }, in: state)
        guard let top = members.last else { return }
        var bounds = Rect.null
        for member in members {
            if let rect = Objects.bounds(of: member, in: state) { bounds = bounds.union(rect) }
        }
        let origin = bounds.isNull ? Point.zero : Point(x: bounds.midX, y: bounds.midY)
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
        var props = Wiretuner_Doc_V1_NodeProps()
        props.symbol.common.name = name ?? SymbolEditing.defaultName(for: members, in: state)
        props.symbol.origin = PathEditing.proto(origin)
        let symbol = builder.append(Ops.create(parent: WellKnown.symbols, position: try PathEditing.topPosition(in: WellKnown.symbols, state: state), props: props))
        let keys = try PathEditing.keys(between: nil, and: nil, count: members.count)
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

/// *Place* (library.adoc, "Placing and modifying instances"): an instance of `symbol` on top of
/// the active layer with the symbol's origin at `point`.
public struct PlaceInstance: Command {
    public var symbol: OpID
    public var point: Point
    public var layer: OpID?
    public var label: String { "Place Symbol" }

    public init(_ symbol: OpID, at point: Point, layer: OpID? = nil) {
        self.symbol = symbol
        self.point = point
        self.layer = layer
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard state.isLive(symbol), state.nodeKind(symbol) == .symbol else { throw SymbolError.notASymbol(symbol) }
        guard point.isFinite else { throw ObjectEditError.invalidValue("point") }
        let parent = try PathEditing.ensureLayer(&builder, state: state, preferred: layer)
        let placement = AffineTransform.translation(x: point.x, y: point.y).concatenating(Objects.pasteboardTransform(ofSpace: parent, in: state).inverse)
        builder.append(Ops.create(parent: parent, position: try PathEditing.topPosition(in: parent, state: state),
                                  props: SymbolEditing.instanceProps(symbol, transform: placement)))
    }
}

/// *Swap*: points instances at another symbol (one ATOMIC register each).  Their overrides are
/// keyed to the old symbol's nodes, so they read as nothing until swapped back.  Any other object
/// is deleted and an instance of the symbol takes its place (LIB-009), its origin at the object's
/// bounds centre.
public struct SwapSymbol: Command {
    public var instances: [OpID]
    public var symbol: OpID
    public var label: String { "Swap Symbol" }

    public init(_ instances: [OpID], to symbol: OpID) {
        self.instances = instances
        self.symbol = symbol
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard state.isLive(symbol), state.nodeKind(symbol) == .symbol else { throw SymbolError.notASymbol(symbol) }
        var values = Wiretuner_Doc_V1_NodeProps()
        values.instance.symbol.id = symbol.proto
        for instance in Objects.editable(instances, in: state) {
            guard state.nodeKind(instance) != .instance else {
                builder.append(Ops.set(instance, [SymbolFields.instanceSymbol], values: values))
                continue
            }
            guard let parent = Objects.parent(of: instance, in: state) else { continue }
            let center = SymbolLibraryEditing.center(of: [instance], in: state)
            let placement = AffineTransform.translation(x: center.x, y: center.y).concatenating(Objects.pasteboardTransform(ofSpace: parent, in: state).inverse)
            let position = try Arranging.keys(next: instance, above: true, count: 1, in: state)[0]
            builder.append(Ops.create(parent: parent, position: position, props: SymbolEditing.instanceProps(symbol, transform: placement)))
            builder.append(Ops.setDeleted(instance))
        }
    }
}

/// menu:Modify[Symbol > Release Instance] and the Overrides section's btn:[Detach]
/// (library.adoc, "Release versus remote symbol edit"): per instance, one group in the instance's
/// place holding deep copies of the artwork as resolved -- hidden parts left out, fill and stroke
/// overrides written into the copies' basic fills and strokes, image overrides into the copies'
/// pixel sources, text blocks holding the override's text (or the master's) -- transformed by the
/// instance's placement, then the instance deleted.  An instance of a missing symbol is left alone.
public struct ReleaseInstances: Command {
    public var instances: [OpID]
    public let label: String

    public init(_ instances: [OpID], label: String = "Release Instance") {
        self.instances = instances
        self.label = label
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for instance in Objects.editable(instances, in: state) where state.nodeKind(instance) == .instance {
            guard let symbol = Symbols.symbol(of: instance, in: state), let parent = Objects.parent(of: instance, in: state) else { continue }
            let origin = state.props(symbol).symbol.origin
            let placement = AffineTransform.translation(x: -origin.x, y: -origin.y).concatenating(Objects.transform(of: instance, in: state))
            let overrides = Symbols.liveOverrides(of: instance, in: state)
            var group = Wiretuner_Doc_V1_NodeProps()
            group.group.kind = .group
            let position = try Arranging.keys(next: instance, above: true, count: 1, in: state)[0]
            let created = builder.append(Ops.create(parent: parent, position: position, props: group))
            // Text blocks carry their text as the instance shows it: a text override's, else the
            // master's (LIB-025); `NodeCopier` writes it.
            var trees = state.liveChildren(symbol).compactMap { SymbolEditing.resolved($0, state: state, overrides) }
                .map { SymbolEditing.overridingTexts($0, instance: instance, overrides: overrides, state: state) }
            let keys = try PathEditing.keys(between: nil, and: nil, count: trees.count)
            var mapping: [OpID: OpID] = [:]
            for index in trees.indices {
                trees[index].transform = trees[index].transform.concatenating(placement)
                try NodeCopier.create(trees[index], parent: created, position: keys[index], schema: state.schema, builder: &builder, mapping: &mapping)
            }
            NodeCopier.rewriteReferences(in: trees, mapping: mapping, builder: &builder)
            builder.append(Ops.setDeleted(instance))
        }
    }
}

/// An override's value (library.adoc, "Overriding parts of an instance").  Text overrides are
/// written by the Text tool's commands (TYPE-002), not here.
public enum OverrideValue: Hashable, Sendable {
    case fill(Wiretuner_Doc_V1_ColorRef)
    case stroke(Wiretuner_Doc_V1_ColorRef)
    case hidden(Bool)
    /// An `assets` node.
    case image(OpID)

    var property: Wiretuner_Doc_V1_OverrideProperty {
        switch self {
        case .fill: .fill
        case .stroke: .stroke
        case .hidden: .hidden
        case .image: .image
        }
    }
}

/// Sets one override on instances of one symbol (the Overrides section's editors): the live
/// element for `(master, property)` gets the value register; an instance without one gets a new
/// element carrying `master_node`, `property` and the value.  One change: "Override fill",
/// "Override stroke", "Hide Star" / "Show Star", "Override image".
public struct SetOverride: Command {
    public var instances: [OpID]
    public var master: OpID
    public var value: OverrideValue
    public let label: String

    public init(_ instances: [OpID], master: OpID, value: OverrideValue, in state: EngineState) {
        self.instances = instances
        self.master = master
        self.value = value
        switch value {
        case .fill: label = "Override fill"
        case .stroke: label = "Override stroke"
        case .image: label = "Override image"
        case .hidden(let hidden): label = "\(hidden ? "Hide" : "Show") \(SymbolEditing.partName(master, in: state))"
        }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let key = OverrideKey(master: master, property: value.property)
        var element = Wiretuner_Doc_V1_Override()
        switch value {
        case .fill(let color): element.fill = color
        case .stroke(let color): element.stroke = color
        case .hidden(let hidden): element.hidden = hidden
        case .image(let asset): element.image.id = asset.proto
        }
        for instance in Objects.editable(instances, in: state) {
            guard state.nodeKind(instance) == .instance else { throw SymbolError.notAnInstance(instance) }
            guard let symbol = Symbols.symbol(of: instance, in: state), Symbols.artworkNodes(of: symbol, in: state).contains(master),
                  Symbols.fits(key.property, state.props(master)) else { throw SymbolError.notOverridable(master) }
            if let existing = Symbols.liveOverrides(of: instance, in: state)[key], let id = OpID(element: existing.id) {
                var values = Wiretuner_Doc_V1_NodeProps()
                values.instance.overrides = [element]
                let path: RegisterPath
                switch value {
                case .fill: path = SymbolFields.overrideFill(id)
                case .stroke: path = SymbolFields.overrideStroke(id)
                case .hidden: path = SymbolFields.overrideHidden(id)
                case .image: path = SymbolFields.overrideImage(id)
                }
                builder.append(Ops.set(instance, [path], values: values))
            } else {
                var created = element
                created.masterNode = master.proto
                created.property = key.property
                var values = Wiretuner_Doc_V1_NodeProps()
                values.instance.overrides = [created]
                let last = state.liveElements(instance, SymbolFields.overrides).last.flatMap { state.position(instance, SymbolFields.overrides, $0) }
                let position = try PathEditing.keys(between: last, and: nil, count: 1)
                builder.append(Ops.elementInsert(instance, SymbolFields.overrides, positions: position, values: values))
            }
        }
    }
}

/// The reset arrow ("Reset override": every element for `key`, duplicates included) and
/// btn:[Reset All Overrides] ("Reset all overrides": every element), on each instance.
public struct ResetOverrides: Command {
    public var instances: [OpID]
    /// nil resets every override.
    public var key: OverrideKey?
    public var label: String { key == nil ? "Reset all overrides" : "Reset override" }

    public init(_ instances: [OpID], key: OverrideKey? = nil) {
        self.instances = instances
        self.key = key
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for instance in Objects.editable(instances, in: state) where state.nodeKind(instance) == .instance {
            let overrides = state.props(instance).instance.overrides.filter { override in
                key.map { OpID(override.masterNode) == $0.master && override.property == $0.property } ?? true
            }
            let paths = overrides.compactMap { OpID(element: $0.id) }.map(SymbolFields.override)
            if !paths.isEmpty {
                builder.append(Ops.elementDelete(instance, paths))
            }
        }
    }
}

/// Helpers shared by the symbol commands.
enum SymbolEditing {
    static func instanceProps(_ symbol: OpID, transform: AffineTransform) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.instance.symbol.id = symbol.proto
        if !transform.isIdentity { props.instance.common.transform = PathEditing.proto(transform) }
        return props
    }

    /// Whether an ancestor of `node` is in `set`.
    static func hasAncestor(in set: Set<OpID>, _ node: OpID, state: EngineState) -> Bool {
        var current = Objects.parent(of: node, in: state)
        while let id = current {
            if set.contains(id) { return true }
            current = Objects.parent(of: id, in: state)
        }
        return false
    }

    /// The object's own name for a single named object; otherwise the first free "Symbol N".
    static func defaultName(for members: [OpID], in state: EngineState) -> String {
        if members.count == 1, let name = NodeValues.common(state.props(members[0]))?.name, !name.isEmpty {
            return name
        }
        let taken = Set(Symbols.symbols(in: state).map { state.props($0).symbol.common.name })
        var number = 1
        while taken.contains("Symbol \(number)") { number += 1 }
        return "Symbol \(number)"
    }

    /// A part's name for labels: its own name, else its kind.
    static func partName(_ node: OpID, in state: EngineState) -> String {
        if let name = NodeValues.common(state.props(node))?.name, !name.isEmpty { return name }
        return state.nodeKind(node).map { "\($0)" } ?? "part"
    }

    /// The subtree of master node `node` as the instance resolves it: nil when hidden; basic fill
    /// and stroke colours and an image's source replaced by the node's overrides; its children
    /// likewise.
    static func resolved(_ node: OpID, state: EngineState, _ overrides: [OverrideKey: Wiretuner_Doc_V1_Override]) -> NodeTree? {
        if overrides[OverrideKey(master: node, property: .hidden)]?.hidden == true { return nil }
        var tree = NodeTree(props: state.props(node), children: state.liveChildren(node).compactMap { resolved($0, state: state, overrides) }, source: node,
                            texts: NodeTree.texts(of: node, in: state))
        // An image override swaps the pixel source for the asset's blob (LIB-025); a dangling one
        // reads as the master's image.
        if let image = overrides[OverrideKey(master: node, property: .image)], image.hasImage, case .image? = tree.props.kind,
           case .asset(let asset)? = state.props(OpID(image.image.id)).kind, state.isLive(OpID(image.image.id)), asset.sha256.count == 32 {
            tree.props.image.pixels.blobSha256 = asset.sha256
            if !asset.mediaType.isEmpty { tree.props.image.pixels.format = asset.mediaType }
        }
        let fill = overrides[OverrideKey(master: node, property: .fill)]?.fill
        let stroke = overrides[OverrideKey(master: node, property: .stroke)]?.stroke
        if fill != nil || stroke != nil, let kind = tree.kind, var appearance = NodeValues.appearance(tree.props) {
            if let fill {
                for index in appearance.fills.indices where [.unspecified, .basic].contains(appearance.fills[index].settings.kind) {
                    appearance.fills[index].settings.basic.color = fill
                }
            }
            if let stroke {
                for index in appearance.strokes.indices where [.unspecified, .basic].contains(appearance.strokes[index].settings.kind) {
                    appearance.strokes[index].settings.basic.color = stroke
                }
            }
            tree.props = NodeValues.replacing(appearance, of: kind, in: tree.props)
        }
        return tree
    }

    /// `tree` (resolved for `instance`) with each text block's text replaced by the instance's
    /// live text override of it, where there is one (library.adoc, "Overriding parts of an
    /// instance").
    static func overridingTexts(_ tree: NodeTree, instance: OpID, overrides: [OverrideKey: Wiretuner_Doc_V1_Override],
                                state: EngineState) -> NodeTree {
        var tree = tree
        if case .text? = tree.props.kind, let master = tree.source, let override = overrides[OverrideKey(master: master, property: .text)],
           let element = OpID(element: override.id), state.text(instance, SymbolFields.overrideText(element)) != nil {
            tree.text = CopiedText(instance, SymbolFields.overrideText(element), in: state)
        }
        tree.children = tree.children.map { overridingTexts($0, instance: instance, overrides: overrides, state: state) }
        return tree
    }
}
