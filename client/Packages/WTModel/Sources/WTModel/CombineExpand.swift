import WTCRDT
import WTGeometry
import WTInterchange
import WTProto
import WTRender

// FX-049: btn:[Expand] in the Combine form (live-effects.adoc, "Combine"; "Merge semantics",
// Combine).  One change: a `path` at the group's slot under its parent carrying the combined
// outline, with the group's attribute stack minus the Combine element, then `SetDeleted(true)` on
// the group.  Undo restores the group and deletes the path; a concurrent edit of a member lands
// under the deleted group (*edit vs delete*, whose *Restore* brings the live group back beside
// the path).

/// Reading a group's live Combine.
public enum CombineReading {
    /// Whether the stored effect is an object-level Combine that draws (not hidden, not attached
    /// to a fill or stroke).
    static func isLiveCombine(_ effect: Wiretuner_Doc_V1_Effect) -> Bool {
        effect.settings.kind == .combine && !effect.hidden && OpID(element: effect.attachedTo) == nil
    }

    /// Whether `node` is a live group whose stack holds a live Combine (btn:[Expand] enabled).
    public static func canExpand(_ node: OpID, in state: EngineState) -> Bool {
        state.isLive(node) && state.nodeKind(node) == .group && state.props(node).group.appearance.effects.contains(where: isLiveCombine)
    }

    /// The combined outline the group draws, in pasteboard space: the group's drawing with its
    /// own stack replaced by one black fill under the Combine, expanded to plain paths by the
    /// export flattener (the drawing WTRender derives for the live group).  Empty when the
    /// members combine to nothing.
    static func outline(of item: GroupItem) -> (contours: [VectorContour], evenOdd: Bool) {
        var bare = item
        let combine = item.appearance.effects.filter { element in
            if case .combine = element.effect, element.target == .object, !element.hidden { return true }
            return false
        }
        bare.appearance = Appearance([.fill(FillPaint(paint: .solid(.black)))], effects: combine, raster: item.appearance.raster)
        bare.opacity = 1
        var contours: [VectorContour] = []
        var evenOdd = false
        func collect(_ node: FlatNode) {
            switch node {
            case .path(let flat):
                evenOdd = evenOdd || flat.style == .fill(.evenOdd)
                contours += InlineShapes.contours(flat.path).map { stored in
                    Subtrees.transformed(VectorContour(closed: stored.closed, points: stored.points.map(VectorPoint.init)), by: flat.transform)
                }
            case .group(let group):
                group.children.forEach(collect)
            default:
                break
            }
        }
        BlendBaking.flat([.group(bare)]).forEach(collect)
        return (contours, evenOdd)
    }

    /// The group's stack as an attribute copy without its object-level Combine elements, the
    /// remaining effects' attachments renumbered to the shortened stack.
    static func stack(of group: OpID, in state: EngineState) -> [AttributePayload.Element] {
        // A live group always has a stack.
        let full = AttributePayload(copying: group, from: state)!.stack!
        var place: [UInt64: UInt64] = [:]
        var kept: [AttributePayload.Element] = []
        for (index, element) in full.enumerated() {
            if case .effect(let effect) = element, effect.settings.kind == .combine, !effect.hasAttachedTo { continue }
            kept.append(element)
            place[UInt64(index + 1)] = UInt64(kept.count)
        }
        return kept.map { element in
            guard case .effect(var effect) = element, effect.hasAttachedTo else { return element }
            if let target = place[effect.attachedTo.counter] {
                effect.attachedTo = Ops.elementID(OpID(counter: target, replica: 0))
            } else {
                effect.clearAttachedTo()
            }
            return .effect(effect)
        }
    }
}

/// btn:[Expand] in the Combine form: each selected group with a live Combine becomes a path of its
/// combined outline, in the group's parent's space (pasteboard space on a layer) with the identity
/// transform, just above the group, carrying the group's name, note and URL and its attribute stack
/// minus the Combine element; the group is deleted with its members inside.  Groups without a live
/// Combine are skipped.  Labelled "Expand Combine".
public struct ExpandCombine: Command {
    public var nodes: [OpID]

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public var label: String { "Expand Combine" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var seen: Set<OpID> = []
        let groups = nodes.filter { CombineReading.canExpand($0, in: state) && seen.insert($0).inserted }
        guard !groups.isEmpty else { return }
        var scene = DocumentDisplayListBuilder(canvas: "expand")
        let built = scene.rebuild(state)
        for group in groups {
            guard let parent = Objects.parent(of: group, in: state), let object = built.object(group), case .group(let item) = object.item else { continue }
            let (contours, evenOdd) = CombineReading.outline(of: item)
            let toParent = Objects.pasteboardTransform(ofSpace: parent, in: state).inverse
            var props = Wiretuner_Doc_V1_NodeProps()
            var common = state.props(group).group.common
            common.clearTransform()
            props.path.common = common
            props.path.evenOdd = evenOdd
            props.path.contours = contours.map { Subtrees.proto(Subtrees.transformed($0, by: toParent)) }
            let key = try Arranging.keys(next: group, above: true, count: 1, in: state)[0]
            let path = try NodeCopier.create(NodeTree(props: props), parent: parent, position: key, schema: state.schema, builder: &builder)
            try PasteAttributes.insert(CombineReading.stack(of: group, in: state), into: path, kind: .path, schema: state.schema, builder: &builder)
            builder.append(Ops.setDeleted(group))
        }
    }
}
