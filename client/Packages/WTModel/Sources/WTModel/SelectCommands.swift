import WTCRDT
import WTGeometry
import WTProto

/// What the menu:Edit[Select] commands pick (selecting.adoc, "Selection commands"; OBJ-006),
/// read from the scene the window draws, so the scoping rules are one pure function each: objects
/// on hidden layers and objects hidden on this Mac are not in the scene at all, and locked
/// objects -- or objects on locked layers -- are skipped by every command.
public enum SelectScope {
    /// menu:Edit[Select > All] (with `page`, the objects whose bounds meet the current page) and
    /// menu:Edit[Select > All in Document] (without, every page and the pasteboard): the top-level
    /// objects in draw order, locked ones and those on locked layers left out.
    public static func all(in scene: DocumentScene, page: Rect? = nil) -> [OpID] {
        scene.topLevel.compactMap { node in
            guard let object = scene.objects[node], !object.isEffectivelyLocked, let bounds = object.bounds else { return nil }
            if let page, !bounds.intersects(page) { return nil }
            return object.id
        }
    }

    /// menu:Edit[Select > Invert Selection]: everything `all(in:page:)` picks that is not in
    /// `selected`, in draw order.
    public static func inverted(_ selected: [OpID], in scene: DocumentScene, page: Rect?) -> [OpID] {
        let current = Set(selected)
        return all(in: scene, page: page).filter { !current.contains($0) }
    }

    /// menu:Edit[Select > Superselect]: each selected member replaced by its container (group,
    /// blend, composite path or clip group), each container once, in the order first reached;
    /// selected top-level objects stay.  Nil at the top -- when no selected object has a container
    /// -- which disables the command.
    public static func superselect(_ selected: [OpID], in scene: DocumentScene) -> [OpID]? {
        var result: [OpID] = []
        var climbed = false
        for node in selected {
            let target: OpID
            if let parent = scene.object(node)?.parent, scene.object(parent) != nil {
                target = parent
                climbed = true
            } else {
                target = node
            }
            if !result.contains(target) { result.append(target) }
        }
        return climbed ? result : nil
    }

    /// menu:Edit[Select > Subselect All]: the members of every selected container, bottom first,
    /// locked members left out; empty when nothing selected has members (the command is then
    /// disabled).
    public static func subselectAll(_ selected: [OpID], in scene: DocumentScene) -> [OpID] {
        selected.flatMap { container in
            members(of: container, in: scene).filter { scene.object($0)?.isEffectivelyLocked == false }
        }
    }

    /// The drawn members of `container`, in draw order (by item path).
    public static func members(of container: OpID, in scene: DocumentScene) -> [OpID] {
        scene.objects.values.filter { $0.parent == container }.sorted { $0.itemPath.lexicographicallyPrecedes($1.itemPath) }.map(\.id)
    }
}

/// menu:Edit[Clear] (kbd:[Delete]) on selected objects: one change, `Delete N objects`, setting
/// `deleted` on each (OBJ-006).  A concurrent remote edit of a cleared node lands on the deleted
/// node and is retained (crdt-model.adoc).  Locked objects are left alone, as `DeleteNodes` does.
public struct ClearObjects: Command {
    public var nodes: [OpID]

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public var label: String { nodes.count == 1 ? "Delete 1 object" : "Delete \(nodes.count) objects" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try DeleteNodes(nodes).execute(&builder, state: state)
    }
}
