import Foundation
import WTGeometry

/// What the Info toolbar shows (toolbars.adoc, "The Info toolbar"): the pointer position and,
/// while dragging, whatever the current tool can report.  Every field is optional; the toolbar
/// draws only the ones that are set.  Pasteboard points.
struct ToolInfo: Equatable, Sendable {
    var position: Point?
    var delta: Vector?
    /// Degrees, counter-clockwise from the positive x axis of the page.
    var angle: Double?
    var center: Point?
    var radius: Double?
    var sides: Int?
    /// The kind of object under the pointer ("Path", "Text").
    var objectKind: String?

    init(
        position: Point? = nil, delta: Vector? = nil, angle: Double? = nil, center: Point? = nil, radius: Double? = nil,
        sides: Int? = nil, objectKind: String? = nil
    ) {
        self.position = position
        self.delta = delta
        self.angle = angle
        self.center = center
        self.radius = radius
        self.sides = sides
        self.objectKind = objectKind
    }

    /// `other`'s set fields over this one's.
    func merged(with other: ToolInfo) -> ToolInfo {
        ToolInfo(
            position: other.position ?? position, delta: other.delta ?? delta, angle: other.angle ?? angle,
            center: other.center ?? center, radius: other.radius ?? radius, sides: other.sides ?? sides,
            objectKind: other.objectKind ?? objectKind
        )
    }
}

/// A tool that reports readouts beyond the pointer position.
@MainActor
protocol ToolInfoPublishing: AnyObject {
    var info: ToolInfo { get }
}

/// The readouts a stubbed tool publishes before its epic lands, so the Info toolbar is complete
/// from day one: the transformation tools report the angle of the drag about the press point
/// (the centre), Polygon its number of sides, and every other tool the drag's delta.
enum ToolReadout {
    enum Kind: Equatable, Sendable {
        case transform
        case sides(Int)
        case delta
    }

    static let transformTools: Set<ToolID> = ["rotate", "scale", "skew", "reflect"]
    /// Polygon's default number of sides (polygons-stars.adoc).
    static let polygonSides = 5

    static func kind(for id: ToolID) -> Kind {
        if transformTools.contains(id) { return .transform }
        if id == "polygon" { return .sides(polygonSides) }
        return .delta
    }

    /// The readout of a drag from `start` to `current` (pasteboard points).
    static func info(for id: ToolID, start: Point, current: Point) -> ToolInfo {
        let delta = current - start
        switch kind(for: id) {
        case .transform:
            return ToolInfo(angle: atan2(-delta.dy, delta.dx) * 180 / .pi, center: start)
        case let .sides(sides):
            return ToolInfo(delta: delta, sides: sides)
        case .delta:
            return ToolInfo(delta: delta)
        }
    }
}
