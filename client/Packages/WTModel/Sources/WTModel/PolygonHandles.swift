import Foundation
import WTCRDT
import WTGeometry
import WTProto

/// The Pointer tool's polygon handles (DRAW-010's remainder, D-078; polygons-stars.adoc "Editing a
/// polygon or star" and "Client", Handles): a diamond at vertex 0 (a peak) and, on a star, a
/// circle at valley 0.  A drag converts the pointer into polar coordinates about the polygon's
/// local centre: the diamond writes `radius` and `rotation` (every vertex moves at once), the
/// circle `inner_radius` (turning *Automatic* off) and `valley_offset`; with kbd:[Shift] the angle
/// is kept, so only the radius changes.  Each drag event is one `SetPolygonFields` change; the
/// tool groups a drag into one undo step.  Dragging a valley past the peaks is allowed (the star
/// turns inside out).
public enum PolygonHandles {
    public enum Handle: Hashable, Sendable {
        /// The diamond at vertex 0.
        case peak
        /// The circle at valley 0 (stars only).
        case valley
    }

    /// The handle positions in the polygon's local space (centred on the origin): the peak, and
    /// the valley for a star.
    public static func localPositions(_ shape: PolygonShape) -> (peak: Point, valley: Point?) {
        let peak = Point(x: shape.radius * cos(shape.rotation), y: shape.radius * sin(shape.rotation))
        guard shape.star else { return (peak, nil) }
        let angle = valleyAngle(shape)
        return (peak, Point(x: shape.innerRadius * cos(angle), y: shape.innerRadius * sin(angle)))
    }

    /// The angle of valley 0: half a step after the first peak, plus the valley offset.
    static func valleyAngle(_ shape: PolygonShape) -> Double {
        shape.rotation + .pi / Double(shape.sides) + shape.valleyOffset
    }

    /// The live polygon `node`'s shape, when it is one.
    static func shape(_ node: OpID, in state: EngineState) -> PolygonShape? {
        guard state.isLive(node), case .polygon(let props)? = state.props(node).kind else { return nil }
        return PolygonShape(props)
    }

    /// The handles of `node` in pasteboard space, for the overlay; nil for anything but a live
    /// polygon.
    public static func positions(of node: OpID, in state: EngineState) -> (peak: Point, valley: Point?)? {
        guard let shape = shape(node, in: state) else { return nil }
        let toPasteboard = Objects.pasteboardTransform(of: node, in: state)
        let local = localPositions(shape)
        return (toPasteboard.apply(local.peak), local.valley.map(toPasteboard.apply))
    }

    /// The handle under `point` (pasteboard) within `tolerance`, the valley first (it sits inside,
    /// where a peak drag would also be plausible); nil when none.
    public static func hit(_ point: Point, on node: OpID, tolerance: Double, in state: EngineState) -> Handle? {
        guard let positions = positions(of: node, in: state) else { return nil }
        if let valley = positions.valley, valley.distance(to: point) <= tolerance { return .valley }
        return positions.peak.distance(to: point) <= tolerance ? .peak : nil
    }

    /// The fields a drag of `handle` to `point` (pasteboard) writes; with `keepAngle` (kbd:[Shift])
    /// only the radius.  Nil for anything but a live polygon, or a valley on a polygon that is not
    /// a star.
    public static func values(dragging handle: Handle, of node: OpID, to point: Point, keepAngle: Bool,
                              in state: EngineState) -> SetPolygonFields.Values? {
        guard let shape = shape(node, in: state) else { return nil }
        let local = Objects.pasteboardTransform(of: node, in: state).inverse.apply(point)
        let distance = (local.x * local.x + local.y * local.y).squareRoot()
        let angle = atan2(local.y, local.x)
        switch handle {
        case .peak:
            return SetPolygonFields.Values(radius: distance, rotation: keepAngle ? nil : angle)
        case .valley:
            guard shape.star else { return nil }
            let offset = normalized(angle - (shape.rotation + .pi / Double(shape.sides)))
            return SetPolygonFields.Values(innerRadius: distance, autoInner: false, valleyOffset: keepAngle ? nil : offset)
        }
    }

    /// The command a drag event performs.
    public static func drag(_ handle: Handle, of node: OpID, to point: Point, keepAngle: Bool, in state: EngineState) -> SetPolygonFields? {
        values(dragging: handle, of: node, to: point, keepAngle: keepAngle, in: state).map { SetPolygonFields([node], $0) }
    }

    /// `angle` folded into (-π, π].
    static func normalized(_ angle: Double) -> Double {
        var result = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if result <= -.pi { result += 2 * .pi } else if result > .pi { result -= 2 * .pi }
        return result
    }
}
