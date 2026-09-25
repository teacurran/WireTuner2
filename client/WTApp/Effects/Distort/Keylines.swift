import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// Objects' outlines for a tool's keyline preview (path-effects.adoc, "Mirror": "Keylines preview
/// every copy"; FX-035, FX-036): each path's contours as drawn, every path inside a group, and the
/// bounds rectangle of anything else (text, images, instances), all in pasteboard space.
@MainActor
enum Keylines {
    static func contours(_ nodes: [OpID], document: DocumentHandle) -> [DistortContour] {
        nodes.flatMap { contours(of: $0, document: document) }
    }

    static func contours(of node: OpID, document: DocumentHandle) -> [DistortContour] {
        let state = document.state
        if let object = document.object(for: SelectionID(node)), let path = object.path {
            return path.contours.map { DistortContour(points: PathSplitting.map($0.drawn, object.transform), closed: $0.closed) }
        }
        if state.nodeKind(node) == .group {
            let members = state.liveChildren(node).flatMap { contours(of: $0, document: document) }
            if !members.isEmpty { return members }
        }
        guard let b = Objects.bounds(of: node, in: state) else { return [] }
        let corners = [Point(x: b.minX, y: b.minY), Point(x: b.maxX, y: b.minY), Point(x: b.maxX, y: b.maxY), Point(x: b.minX, y: b.maxY)]
        return [DistortContour(points: corners.map { VectorPoint(anchor: $0) }, closed: true)]
    }

    /// Adds `contours` (pasteboard space) to `ctx`'s path in view points; the caller strokes.
    static func add(_ contours: [DistortContour], to ctx: CGContext, viewport: Viewport) {
        for contour in contours {
            let segments = contour.segments
            guard let first = segments.first else { continue }
            ctx.move(to: viewport.toView(first.p0).cgPoint)
            for segment in segments {
                ctx.addCurve(to: viewport.toView(segment.p3).cgPoint, control1: viewport.toView(segment.p1).cgPoint, control2: viewport.toView(segment.p2).cgPoint)
            }
            if contour.closed { ctx.closePath() }
        }
    }
}
