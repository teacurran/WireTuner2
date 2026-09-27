import WTCRDT
import WTGeometry

/// The path point Inspect mode reads out under the pointer (inspect.adoc, "Measuring by hovering";
/// COLLAB-035's rest): the anchor of a path, rectangle, ellipse or polygon nearest `point`
/// (pasteboard) within `tolerance` points, in pasteboard space; nil when none is that close.
public enum InspectPoints {
    public static func anchor(of node: OpID, near point: Point, tolerance: Double, in state: EngineState) -> Point? {
        guard let path = Objects.localPath(node, in: state) else { return nil }
        let transform = Objects.pasteboardTransform(of: node, in: state)
        var best: (point: Point, distance: Double)?
        for contour in path.contours {
            for vertex in contour.points {
                let placed = transform.apply(vertex.anchor)
                let distance = placed.distance(to: point)
                if distance <= tolerance, distance < best?.distance ?? .infinity { best = (placed, distance) }
            }
        }
        return best?.point
    }
}
