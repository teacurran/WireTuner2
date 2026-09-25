import WTCRDT
import WTGeometry
import WTProto

// WEB-015's objects attached to a path (animation.adoc, "Releasing objects to layers": releasing
// objects attached to a path detaches them).  The objects attached to a path are the characters
// of a text on a path (TYPE-041: the path is the text node's child); the release gives each
// character its own layer, laid out along the path as the text draws, and the path is detached:
// it moves out to the text's slot, just below it, keeping its place on the page, and stays there
// when the text is deleted -- as a blend's ends stay where the blend was.

extension ReleaseToLayers {
    /// Moves every `path` child of text `node` out beside it (below it), its transform re-expressed
    /// in the text's parent; nothing for a text that is not on a path.
    static func detachPaths(of node: OpID, state: EngineState, builder: inout ChangeBuilder) throws {
        guard let parent = Objects.parent(of: node, in: state) else { return }
        let paths = state.liveChildren(node).filter { state.nodeKind($0) == .path }
        guard !paths.isEmpty else { return }
        let textTransform = Objects.transform(of: node, in: state)
        let keys = try Arranging.keys(next: node, above: false, count: paths.count, in: state)
        for (path, key) in zip(paths, keys) {
            let moved = Objects.transform(of: path, in: state).concatenating(textTransform)
            if moved != Objects.transform(of: path, in: state) { builder.append(Objects.setTransform(path, kind: .path, moved)) }
            builder.append(Ops.move(path, parent: parent, position: key))
        }
    }
}
