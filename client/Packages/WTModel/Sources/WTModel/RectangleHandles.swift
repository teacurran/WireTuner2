import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// The Pointer tool's corner-radius handles on a live rectangle (D-078; rectangles-ellipses-lines.adoc
/// "Rectangles with rounded corners"): one inside each corner on its diagonal, at the centre of the
/// corner's rounding, or a small inset in from a square corner.  Dragging one along the diagonal
/// sets the radius -- every corner with *Uniform* on, that corner alone with it off -- as one
/// `SetCornerRadius`.  A rectangle carrying a live Corners effect has none: the effect sets its
/// corners, and the Subselect tool's corner widgets adjust it.
public enum RectangleHandles {
    /// One handle, pasteboard space.
    public struct Handle: Hashable, Sendable {
        public var corner: Corner
        public var position: Point
    }

    /// The corner's point in the rectangle's local frame and the direction into the rectangle
    /// along its diagonal, per axis (+1 or -1).
    static func frame(_ corner: Corner, size: Size) -> (point: Point, x: Double, y: Double) {
        switch corner {
        case .topLeft: (Point(x: 0, y: 0), 1, 1)
        case .topRight: (Point(x: size.width, y: 0), -1, 1)
        case .bottomRight: (Point(x: size.width, y: size.height), -1, -1)
        case .bottomLeft: (Point(x: 0, y: size.height), 1, -1)
        }
    }

    static func radius(_ corner: Corner, _ radii: CornerRadii) -> Double {
        switch corner {
        case .topLeft: radii.topLeft
        case .topRight: radii.topRight
        case .bottomRight: radii.bottomRight
        case .bottomLeft: radii.bottomLeft
        }
    }

    /// The live rectangle `node` without a live Corners effect: its props and size.
    static func rectangle(_ node: OpID, in state: EngineState) -> (props: Wiretuner_Doc_V1_RectProps, size: Size)? {
        guard state.isLive(node), case .rect(let rect)? = state.props(node).kind, !EffectLowering.hasCorners(rect.appearance) else { return nil }
        return (rect, Size(width: rect.size.width, height: rect.size.height))
    }

    /// The handles of `node`, pasteboard space, `inset` (pasteboard units) in from a square corner;
    /// nil when `node` is not a live rectangle or its Corners effect sets its corners.
    public static func positions(of node: OpID, inset: Double, in state: EngineState) -> [Handle]? {
        guard let (rect, size) = rectangle(node, in: state) else { return nil }
        let radii = CornerRadii(rect.corners, size: size)
        let toPasteboard = Objects.pasteboardTransform(of: node, in: state)
        let scale = max(sqrt(abs(toPasteboard.determinant)), 1e-9)
        return Corner.allCases.map { corner in
            let (point, x, y) = frame(corner, size: size)
            let distance = max(radius(corner, radii), min(inset / scale, min(size.width, size.height) / 2))
            return Handle(corner: corner, position: toPasteboard.apply(Point(x: point.x + x * distance, y: point.y + y * distance)))
        }
    }

    /// The corner whose handle is within `tolerance` of `point` (pasteboard), the nearest first.
    public static func hit(_ point: Point, on node: OpID, inset: Double, tolerance: Double, in state: EngineState) -> Corner? {
        guard let handles = positions(of: node, inset: inset, in: state) else { return nil }
        return handles.filter { $0.position.distance(to: point) <= tolerance }.min { $0.position.distance(to: point) < $1.position.distance(to: point) }?.corner
    }

    /// The radius a drag of `corner`'s handle to `point` (pasteboard) sets: the pointer's distance
    /// along the diagonal, as the centre of the rounding, clamped to half the shorter side.
    public static func radius(dragging corner: Corner, of node: OpID, to point: Point, in state: EngineState) -> Double? {
        guard let (_, size) = rectangle(node, in: state), let inverse = Objects.pasteboardTransform(of: node, in: state).inverted() else { return nil }
        let local = inverse.apply(point)
        let (origin, x, y) = frame(corner, size: size)
        let along = ((local.x - origin.x) * x + (local.y - origin.y) * y) / 2
        return min(max(along, 0), min(size.width, size.height) / 2)
    }

    /// The change a drag of `corner`'s handle to `point` writes: every corner with *Uniform* on,
    /// that corner alone with it off.
    public static func drag(_ corner: Corner, of node: OpID, to point: Point, in state: EngineState) -> SetCornerRadius? {
        guard let (rect, _) = rectangle(node, in: state), let radius = radius(dragging: corner, of: node, to: point, in: state) else { return nil }
        return SetCornerRadius([node], radius: radius, corners: rect.corners.uniform ? Corner.allCases : [corner])
    }
}
