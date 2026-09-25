import WTCRDT
import WTGeometry
import WTRender

/// What the Graphic Hose draws before anything is written (graphic-hose.adoc, "Client"): the
/// overlay preview of a stroke's placements and the sheet's *Contents* preview, as display items
/// through the same subtree renderer as tile artwork -- paths and closed shapes with their
/// attribute stacks, groups with their members.  Other kinds (text, images, instances) are left
/// out of the preview; the sprayed copies are complete.
public enum HosePreview {
    /// The stroke's placed objects in pasteboard space, in placement order (placements naming no
    /// object are skipped).
    public static func items(_ set: HoseSet, placements: [HosePlacement], in state: EngineState) -> [DisplayItem] {
        var trees: [OpID: NodeTree] = [:]
        return placements.compactMap { placement in
            guard placement.index >= 0, placement.index < set.objects.count else { return nil }
            let object = set.objects[placement.index]
            let tree = trees[object] ?? NodeTree(object, state: state)
            trees[object] = tree
            return SubtreeRendering.item(tree, parent: placement.transform)
        }
    }

    /// One object of the set centred on the origin at 100%, for the *Contents* pop-up.
    public static func items(of object: OpID, in state: EngineState) -> [DisplayItem] {
        SubtreeRendering.item(NodeTree(object, state: state), parent: .identity).map { [$0] } ?? []
    }
}
