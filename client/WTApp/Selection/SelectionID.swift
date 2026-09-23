import Foundation

/// Names one selected object.  Today objects are addressed by their display-list index path
/// (REND-003's hit results carry nothing else); when `WTModel` gives display items node ids
/// the `Key` gains `.node(OpId)`, `SelectionModel` and every caller keep working unchanged,
/// and `shifted(afterRemoving:)` becomes the identity (a node id does not move when its
/// neighbours are deleted).
struct SelectionID: Hashable, Sendable, Comparable, CustomStringConvertible {
    enum Key: Hashable, Sendable {
        /// `DisplayList.items` then `GroupItem.children` downward.
        case indexPath([Int])
    }

    let key: Key

    init(_ key: Key) { self.key = key }

    /// The object at `path` in the display list.
    static func item(_ path: [Int]) -> SelectionID { SelectionID(.indexPath(path)) }

    /// The display-list index path, while ids are index paths.
    var indexPath: [Int] {
        switch key {
        case let .indexPath(path): path
        }
    }

    /// The top-level display item the object is, or is inside.
    var topLevelIndex: Int? { indexPath.first }

    /// The id after the top-level items at `removed` left the list: nil when the object was
    /// one of them (or inside one), otherwise the same object at its shifted index.
    func shifted(afterRemoving removed: IndexSet) -> SelectionID? {
        guard let top = topLevelIndex else { return nil }
        guard !removed.contains(top) else { return nil }
        let shift = removed.count(in: 0..<top)
        guard shift > 0 else { return self }
        return .item([top - shift] + indexPath.dropFirst())
    }

    /// Draw order: an index path sorts before the paths below it and after the ones above.
    static func < (lhs: SelectionID, rhs: SelectionID) -> Bool {
        lhs.indexPath.lexicographicallyPrecedes(rhs.indexPath)
    }

    var description: String { indexPath.map(String.init).joined(separator: ".") }
}

/// An anchor of a selected path: the primitive (index path) and the element ending there.
struct PointReference: Hashable, Sendable, Comparable {
    let leafPath: [Int]
    let element: Int

    static func < (lhs: PointReference, rhs: PointReference) -> Bool {
        lhs.leafPath == rhs.leafPath ? lhs.element < rhs.element : lhs.leafPath.lexicographicallyPrecedes(rhs.leafPath)
    }
}

/// A segment of a selected path: primitive, contour and the segment within the contour.
struct SegmentReference: Hashable, Sendable, Comparable {
    let leafPath: [Int]
    let contour: Int
    let segment: Int

    static func < (lhs: SegmentReference, rhs: SegmentReference) -> Bool {
        lhs.leafPath == rhs.leafPath ? (lhs.contour, lhs.segment) < (rhs.contour, rhs.segment) : lhs.leafPath.lexicographicallyPrecedes(rhs.leafPath)
    }
}

/// What is selected *inside* one selected object (selecting.adoc, "Selecting inside groups"):
/// anchors or segments of a path, or a range of a text object's characters.
enum SubSelection: Hashable, Sendable {
    case points(Set<PointReference>)
    case segments(Set<SegmentReference>)
    /// Character offsets; `TXT-001` replaces them with character ids.
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

    /// The sub-selection with every reference under the top-level items at `removed` dropped
    /// and the rest shifted, as `SelectionID.shifted(afterRemoving:)` does for objects.
    func shifted(afterRemoving removed: IndexSet) -> SubSelection {
        func shift(_ path: [Int]) -> [Int]? { SelectionID.item(path).shifted(afterRemoving: removed)?.indexPath }
        switch self {
        case let .points(points):
            return .points(Set(points.compactMap { point in shift(point.leafPath).map { PointReference(leafPath: $0, element: point.element) } }))
        case let .segments(segments):
            return .segments(Set(segments.compactMap { segment in
                shift(segment.leafPath).map { SegmentReference(leafPath: $0, contour: segment.contour, segment: segment.segment) }
            }))
        case .textRange:
            return self
        }
    }
}
