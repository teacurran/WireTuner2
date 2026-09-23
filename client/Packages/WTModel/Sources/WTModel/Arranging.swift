import WTCRDT
import WTProto

/// The four Arrange commands (OBJ-018, arranging.adoc "Merge semantics"): one `MoveNode` per
/// selected node, same parent, with a fresh position computed against the unselected neighbours,
/// consecutive so a multi-selection keeps its internal order.  Inside a clip group nothing goes
/// below the clip path.  Locked objects stay where they are.
public struct Arrange: Command {
    public enum Direction: String, Sendable, Hashable, CaseIterable {
        case bringToFront, bringForward, sendBackward, sendToBack

        public var title: String {
            switch self {
            case .bringToFront: "Bring to Front"
            case .bringForward: "Bring Forward"
            case .sendBackward: "Send Backward"
            case .sendToBack: "Send to Back"
            }
        }
    }

    public var nodes: [OpID]
    public var direction: Direction

    public init(_ nodes: [OpID], _ direction: Direction) {
        self.nodes = nodes
        self.direction = direction
    }

    public var label: String { direction.title }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var byParent: [OpID: [OpID]] = [:]
        var parents: [OpID] = []
        for node in Objects.editable(nodes, in: state) {
            guard let parent = Objects.parent(of: node, in: state), Arranging.clipPath(of: parent, in: state) != node else { continue }
            if byParent[parent] == nil { parents.append(parent) }
            byParent[parent, default: []].append(node)
        }
        for parent in parents {
            let siblings = state.liveChildren(parent)
            let selected = Set(byParent[parent]!)
            let block = siblings.filter(selected.contains)
            guard let bounds = bounds(block: block, siblings: siblings, selected: selected, parent: parent, state: state) else { continue }
            let keys = try PathEditing.keys(between: bounds.lo, and: bounds.hi, count: block.count)
            for (node, key) in zip(block, keys) {
                builder.append(Ops.move(node, parent: parent, position: key))
            }
        }
    }

    /// The positions the block goes between; nil when it cannot move that way.
    private func bounds(block: [OpID], siblings: [OpID], selected: Set<OpID>, parent: OpID, state: EngineState) -> (lo: [UInt8]?, hi: [UInt8]?)? {
        func position(_ node: OpID) -> [UInt8]? { state.store.placement(node)?.position }
        let floor = Arranging.clipPath(of: parent, in: state).flatMap(position)
        switch direction {
        case .bringToFront:
            let last = state.store.children(parent).last.flatMap(position)
            return (last, nil)
        case .sendToBack:
            let clip = Arranging.clipPath(of: parent, in: state)
            guard let first = siblings.first(where: { !selected.contains($0) && $0 != clip }), let hi = position(first) else { return nil }
            return (floor.flatMap { FractionalIndex.less($0, hi) ? $0 : nil }, hi)
        case .bringForward:
            guard let top = block.last, let index = siblings.firstIndex(of: top),
                  let next = siblings[(index + 1)...].first(where: { !selected.contains($0) }),
                  let nextIndex = siblings.firstIndex(of: next) else { return nil }
            let after = nextIndex + 1 < siblings.count ? position(siblings[nextIndex + 1]) : nil
            return (position(next), after)
        case .sendBackward:
            guard let bottom = block.first, let index = siblings.firstIndex(of: bottom),
                  let previous = siblings[..<index].last(where: { !selected.contains($0) }),
                  previous != Arranging.clipPath(of: parent, in: state),
                  let previousIndex = siblings.firstIndex(of: previous) else { return nil }
            let before = previousIndex > 0 ? position(siblings[previousIndex - 1]) : nil
            return (before, position(previous))
        }
    }
}

/// Stacking helpers.
public enum Arranging {
    /// The clip path of a clip group, when `node` is one and the path is live.
    public static func clipPath(of node: OpID, in state: EngineState) -> OpID? {
        guard state.nodeKind(node) == .group else { return nil }
        let group = state.props(node).group
        guard group.kind == .clip, group.hasClipPath else { return nil }
        let clip = OpID(group.clipPath.id)
        return state.isLive(clip) ? clip : nil
    }

    /// The live sibling directly above `node`.
    public static func siblingAfter(_ node: OpID, in state: EngineState) -> OpID? {
        guard let parent = state.store.placement(node)?.parent else { return nil }
        let siblings = state.store.children(parent)
        guard let index = siblings.firstIndex(of: node) else { return nil }
        return siblings[(index + 1)...].first(where: state.isLive)
    }

    /// The live sibling directly below `node`.
    public static func siblingBefore(_ node: OpID, in state: EngineState) -> OpID? {
        guard let parent = state.store.placement(node)?.parent else { return nil }
        let siblings = state.store.children(parent)
        guard let index = siblings.firstIndex(of: node) else { return nil }
        return siblings[..<index].last(where: state.isLive)
    }

    /// Keys for `count` nodes directly above (`above` true) or below `anchor` among its siblings.
    static func keys(next anchor: OpID, above: Bool, count: Int, in state: EngineState) throws -> [[UInt8]] {
        let position = state.store.placement(anchor)?.position
        if above {
            let hi = siblingAfter(anchor, in: state).flatMap { state.store.placement($0)?.position }
            return try PathEditing.keys(between: position, and: hi, count: count)
        }
        let lo = siblingBefore(anchor, in: state).flatMap { state.store.placement($0)?.position }
        return try PathEditing.keys(between: lo, and: position, count: count)
    }
}
