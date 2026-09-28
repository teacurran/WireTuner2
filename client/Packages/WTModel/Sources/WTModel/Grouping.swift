import WTCRDT
import WTGeometry
import WTProto

extension Objects {
    /// `nodes` in stacking order, bottom first: by layer (`LayerOrder`), then by sibling order down
    /// the tree.
    public static func stackingOrder(_ nodes: [OpID], in state: EngineState) -> [OpID] {
        let order = LayerOrder(state)
        func key(_ node: OpID) -> [Int] {
            var indices: [Int] = []
            var current = node
            while let parent = state.store.placement(current)?.parent {
                if order.layer(parent) != nil {
                    let layer = order.displayLayer(for: parent) ?? parent
                    let objects = order.objects(on: layer, in: state)
                    indices.insert(objects.firstIndex(of: current) ?? Int.max, at: 0)
                    indices.insert(order.index(of: layer) ?? Int.max, at: 0)
                    return indices
                }
                indices.insert(state.store.children(parent).firstIndex(of: current) ?? Int.max, at: 0)
                current = parent
            }
            return [Int.max] + indices
        }
        let keys = Dictionary(nodes.map { ($0, key($0)) }, uniquingKeysWith: { first, _ in first })
        return Array(Set(nodes)).sorted { keys[$0]!.lexicographicallyPrecedes(keys[$1]!) }
    }
}

/// menu:Modify[Group] (OBJ-016, grouping.adoc "Group"): one change creating a group (identity
/// transform) and moving the selected objects into it, bottom first, keeping their stacking
/// order.  Objects sharing one parent are grouped in place, at the topmost one's position; objects
/// from several layers or groups are collected onto the active layer (top).  With *Remember layer
/// info*, a `LayerOrigin` per member records the layer it came from.  Locked objects are left out.
public struct GroupObjects: Command {
    public var nodes: [OpID]
    public var layer: OpID?
    public var rememberLayerInfo: Bool
    public var label: String { "Group" }

    public init(_ nodes: [OpID], layer: OpID? = nil, rememberLayerInfo: Bool = false) {
        self.nodes = nodes
        self.layer = layer
        self.rememberLayerInfo = rememberLayerInfo
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let members = Objects.stackingOrder(Objects.editable(nodes, in: state), in: state)
        guard let top = members.last else { return }
        let parents = Set(members.compactMap { Objects.parent(of: $0, in: state) })
        let order = LayerOrder(state)
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
        props.group.kind = .group
        let group = builder.append(Ops.create(parent: parent, position: position, props: props))
        let keys = try PathEditing.keys(between: nil, and: nil, count: members.count)
        for (member, key) in zip(members, keys) {
            builder.append(Ops.move(member, parent: group, position: key))
        }
        guard rememberLayerInfo else { return }
        let origins = members.map { member -> Wiretuner_Doc_V1_LayerOrigin in
            var origin = Wiretuner_Doc_V1_LayerOrigin()
            origin.child.id = member.proto
            if let layer = order.layer(of: member, in: state) { origin.layer.id = layer.proto }
            return origin
        }
        var values = Wiretuner_Doc_V1_NodeProps()
        values.group.layerOrigins = origins
        let originKeys = try PathEditing.keys(between: nil, and: nil, count: origins.count)
        builder.append(Ops.elementInsert(group, RegisterPath([NodeKind.group.rawValue, 5]), positions: originKeys, values: values))
    }
}

/// menu:Modify[Ungroup] (OBJ-016, grouping.adoc "Ungroup"; DRAW-009/DRAW-012): for a group, each
/// member (bottom first) gets the group's matrix baked into its own (`C.transform` followed by
/// `G.transform`) and moves into the group's slot in its parent -- or back to the layer it came
/// from, with *Remember layer info* -- and the group is deleted.  A rectangle, ellipse or polygon
/// is converted instead: a `path` node with the same outline, attributes and transform takes its
/// place and the shape is deleted.  One change; undo restores the group or shape.
public struct Ungroup: Command {
    public var nodes: [OpID]
    public var rememberLayerInfo: Bool
    public var label: String { "Ungroup" }

    public init(_ nodes: [OpID], rememberLayerInfo: Bool = false) {
        self.nodes = nodes
        self.rememberLayerInfo = rememberLayerInfo
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in Objects.editable(nodes, in: state) {
            switch state.nodeKind(node) {
            case .group?: try ungroup(node, state: state, builder: &builder)
            case .rect?, .ellipse?, .polygon?: try convert(node, state: state, builder: &builder)
            default: continue
            }
        }
    }

    private func ungroup(_ group: OpID, state: EngineState, builder: inout ChangeBuilder) throws {
        guard let parent = Objects.parent(of: group, in: state) else { return }
        let groupTransform = Objects.transform(of: group, in: state)
        let members = state.liveChildren(group)
        let keys = try Arranging.keys(next: group, above: true, count: members.count, in: state)
        let origins = rememberLayerInfo ? Self.origins(of: group, in: state) : [:]
        let order = LayerOrder(state)
        for (member, key) in zip(members, keys) {
            guard let kind = state.nodeKind(member), kind != .layer else { continue }
            builder.append(Objects.setTransform(member, kind: kind, Objects.transform(of: member, in: state).concatenating(groupTransform)))
            if let layer = origins[member], order.isLive(layer), layer != parent {
                builder.append(Ops.move(member, parent: layer, position: try PathEditing.topPosition(in: layer, state: state)))
            } else {
                builder.append(Ops.move(member, parent: parent, position: key))
            }
        }
        builder.append(Ops.setDeleted(group))
    }

    /// The layer each member came from, as `layer_origins` records it.
    static func origins(of group: OpID, in state: EngineState) -> [OpID: OpID] {
        var result: [OpID: OpID] = [:]
        for origin in state.props(group).group.layerOrigins where origin.hasChild && origin.hasLayer {
            result[OpID(origin.child.id)] = OpID(origin.layer.id)
        }
        return result
    }

    /// A rectangle, ellipse or polygon becomes a path drawing the same (`ShapeConversion.convert`).
    private func convert(_ shape: OpID, state: EngineState, builder: inout ChangeBuilder) throws {
        try ShapeConversion.convert(shape, state: state, builder: &builder)
    }
}
