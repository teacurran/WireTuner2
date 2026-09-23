import Foundation
import WTCRDT
import WTModel
import WTRender

/// Names one selected object: its node id (the `OpId` of the `CreateNode` that made it), so a
/// selection survives other objects being added, deleted or restacked (selecting.adoc, "Merge
/// semantics").
struct SelectionID: Hashable, Sendable, Comparable, CustomStringConvertible {
    let node: NodeID

    init(_ node: NodeID) { self.node = node }

    init(_ node: OpID) { self.node = NodeID(node) }

    /// The merge-engine id.
    var opID: OpID { OpID(node) }

    /// A stable order (by node id), for sets rendered in a fixed order.
    static func < (lhs: SelectionID, rhs: SelectionID) -> Bool {
        lhs.node < rhs.node
    }

    var description: String { node.description }
}

/// An anchor of a selected path: the object, its contour and the point element (a derived shape
/// point's id is synthetic, `ShapeGeometry`).
struct PointReference: Hashable, Sendable, Comparable {
    let node: NodeID
    let contour: OpID
    let point: OpID

    init(node: NodeID, contour: OpID, point: OpID) {
        self.node = node
        self.contour = contour
        self.point = point
    }

    init(node: NodeID, _ ref: PointRef) {
        self.init(node: node, contour: ref.contour, point: ref.point)
    }

    static func < (lhs: PointReference, rhs: PointReference) -> Bool {
        (lhs.node, lhs.contour, lhs.point) < (rhs.node, rhs.contour, rhs.point)
    }
}

/// A segment of a selected path: the object, its contour and the drawn point the segment starts at.
struct SegmentReference: Hashable, Sendable, Comparable {
    let node: NodeID
    let contour: OpID
    let from: OpID

    static func < (lhs: SegmentReference, rhs: SegmentReference) -> Bool {
        (lhs.node, lhs.contour, lhs.from) < (rhs.node, rhs.contour, rhs.from)
    }
}

/// What is selected *inside* one selected object (selecting.adoc, "Selecting inside groups"):
/// anchors or segments of a path, or a range of a text object's characters.
enum SubSelection: Hashable, Sendable {
    case points(Set<PointReference>)
    case segments(Set<SegmentReference>)
    /// Character offsets; the text epic replaces them with character ids.
    case textRange(Range<Int>)

    var isEmpty: Bool {
        switch self {
        case let .points(points): points.isEmpty
        case let .segments(segments): segments.isEmpty
        case let .textRange(range): range.isEmpty
        }
    }

    /// `other` added to this one: points and segments merge with their own kind; anything
    /// else replaces (a text range, or a change of kind).
    func adding(_ other: SubSelection) -> SubSelection {
        switch (self, other) {
        case let (.points(a), .points(b)): .points(a.union(b))
        case let (.segments(a), .segments(b)): .segments(a.union(b))
        default: other
        }
    }

    /// Each member of `other` toggled in this one (Shift-click on a point); a different kind
    /// replaces.
    func toggling(_ other: SubSelection) -> SubSelection {
        switch (self, other) {
        case let (.points(a), .points(b)): .points(a.symmetricDifference(b))
        case let (.segments(a), .segments(b)): .segments(a.symmetricDifference(b))
        default: other
        }
    }

    /// Only the points and segments `isLive` accepts (a point deleted by someone else leaves).
    func filtered(points isLive: (PointReference) -> Bool, segments isLiveSegment: (SegmentReference) -> Bool) -> SubSelection {
        switch self {
        case let .points(points): .points(points.filter(isLive))
        case let .segments(segments): .segments(segments.filter(isLiveSegment))
        case .textRange: self
        }
    }
}
