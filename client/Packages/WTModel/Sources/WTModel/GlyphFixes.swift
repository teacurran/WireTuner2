import WTCRDT
import WTGeometry
import WTProto

// Find Problems' fix buttons (glyph-editing.adoc, "Checking a glyph"; FONT-014): *Round to Units*
// moves every anchor and handle of a glyph's paths to whole font units; the component fixes remove
// the components that no longer resolve.

/// *Round to Units*: each path on the glyph's canvas (group members included) has its points'
/// anchors and handles rounded to whole units in glyph space, written as a rewrite of the
/// contours that change.  "Round to Units".
public struct RoundGlyphPoints: Command {
    public var glyph: OpID
    public var label: String { "Round to Units" }

    public init(_ glyph: OpID) {
        self.glyph = glyph
    }

    static func paths(under node: OpID, in state: EngineState) -> [OpID] {
        switch state.nodeKind(node) {
        case .group?: state.liveChildren(node).flatMap { paths(under: $0, in: state) }
        case .path?: [node]
        default: []
        }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in GlyphArtwork.objectIDs(on: glyph, in: state).flatMap({ Self.paths(under: $0, in: state) }) {
            let toGlyph = Objects.pasteboardTransform(of: node, in: state)
            guard let back = toGlyph.inverted() else { continue }
            let path = VectorPath(state.props(node).path, node: node, state: state)
            var edits: [RewritePath.ContourEdit] = []
            for contour in path.contours {
                let rounded = contour.drawn.map { point -> VectorPoint in
                    func round(_ p: Point) -> Point {
                        let placed = toGlyph.apply(p)
                        return back.apply(Point(x: placed.x.rounded(), y: placed.y.rounded()))
                    }
                    var copy = point
                    copy.anchor = round(point.anchor)
                    copy.inHandle = round(point.inControl) - copy.anchor
                    copy.outHandle = round(point.outControl) - copy.anchor
                    return copy
                }
                if rounded != contour.drawn { edits.append(.init(contour: contour.id, points: rounded, closed: contour.closed)) }
            }
            guard !edits.isEmpty else { continue }
            try RewritePath(node: node, edits: edits, label: label).execute(&builder, state: state)
        }
    }
}

/// The components of `glyph` that no longer resolve (dangling or cut from a loop).
public enum GlyphComponentFixes {
    public static func broken(_ glyph: OpID, in state: EngineState) -> [OpID] {
        GlyphIndex(state)[glyph]?.components.filter { $0.status != .resolved }.map(\.id) ?? []
    }

    /// *Remove Component* for them, nil when every component resolves.
    public static func removal(_ glyph: OpID, in state: EngineState) -> RemoveComponents? {
        let broken = broken(glyph, in: state)
        return broken.isEmpty ? nil : RemoveComponents(broken, of: glyph)
    }
}
