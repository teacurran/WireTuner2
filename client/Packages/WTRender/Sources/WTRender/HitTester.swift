// Hit testing on display-list geometry, never on pixels (REND-003; docs/spec/client.adoc, "Core
// Graphics reference renderer"; docs/_includes/objects/selecting.adoc, "Client").
//
// The pointer is mapped through the inverse view transform (rotation included); the pick
// distance stays in view pixels and is converted with the zoom only.  Fills hit by winding or
// crossing count, strokes by distance to the centreline within the widest visible stroke's half
// width plus the pick tolerance (honouring caps at open ends), points and handles by distance,
// segments by distance to the centreline.  Candidates come from an R-tree over the top-level
// items' bounds.

import WTGeometry

/// The *Pick distance* preference and the selection tool's flags.
public struct HitOptions: Hashable, Sendable {
    /// *Pick distance* is 1 to 5 view pixels.
    public static let pickDistanceRange: ClosedRange<Double> = 1...5
    public static let defaultPickDistance = 3.0

    /// Subselect (the Subselect tool, or kbd:[Option] with the Pointer): hits name the member
    /// inside groups instead of the top-level group.
    public var subselect: Bool
    /// *Contact-sensitive selection*: a marquee selects what it touches, not only what it encloses.
    public var contactSensitive: Bool
    /// How close to a path, point or handle a click must land, in view pixels; clamped to
    /// `pickDistanceRange`.
    public var pickDistanceInViewPixels: Double {
        didSet { pickDistanceInViewPixels = HitOptions.clampedPickDistance(pickDistanceInViewPixels) }
    }
    /// Whether anchors are hit as `.point`.
    public var pickPoints: Bool
    /// Whether curve control points are hit as `.handle` (they are only shown on selected paths).
    public var pickHandles: Bool

    public init(
        subselect: Bool = false,
        contactSensitive: Bool = false,
        pickDistanceInViewPixels: Double = HitOptions.defaultPickDistance,
        pickPoints: Bool = true,
        pickHandles: Bool = false
    ) {
        self.subselect = subselect
        self.contactSensitive = contactSensitive
        self.pickDistanceInViewPixels = HitOptions.clampedPickDistance(pickDistanceInViewPixels)
        self.pickPoints = pickPoints
        self.pickHandles = pickHandles
    }

    static func clampedPickDistance(_ value: Double) -> Double {
        guard value.isFinite else {
            return defaultPickDistance
        }
        return min(max(value, pickDistanceRange.lowerBound), pickDistanceRange.upperBound)
    }

    /// The pick distance in pasteboard units at `viewport`'s zoom.
    public func pasteboardTolerance(for viewport: Viewport) -> Double {
        pickDistanceInViewPixels / viewport.zoom
    }
}

/// Where on a path: contour, segment within it (the closing segment of a closed contour is
/// `segments.count`), and parameter.
public struct PathLocation: Hashable, Sendable {
    public var contour: Int
    public var segment: Int
    public var t: Double

    public init(contour: Int, segment: Int, t: Double) {
        self.contour = contour
        self.segment = segment
        self.t = t
    }
}

/// What part of an item a hit landed on.
public enum HitKind: Hashable, Sendable {
    /// Inside a visible fill.
    case fill
    /// On a visible stroke; nil location for an arrowhead.
    case stroke(PathLocation?)
    /// Within the pick distance of the path itself (an unstroked path, or a subselect click).
    case segment(PathLocation)
    /// On an anchor: the index of the element in `DisplayPath.elements` that ends there.
    case point(element: Int)
    /// On a curve control point: element index and control (1 or 2).
    case handle(element: Int, control: Int)
    /// Inside a text run's bounds.
    case text
    /// Inside an image's frame.
    case image
}

/// One hit.  Index paths address `DisplayList.items` then `GroupItem.children` downward.
public struct HitResult: Hashable, Sendable {
    /// What a click selects: the top-level item, or with `subselect` the member hit.
    public var itemPath: [Int]
    /// The primitive the hit landed on.
    public var leafPath: [Int]
    public var kind: HitKind
    /// Pasteboard distance from the pick point to what was hit (0 inside a fill or frame).
    public var distance: Double

    public init(itemPath: [Int], leafPath: [Int], kind: HitKind, distance: Double) {
        self.itemPath = itemPath
        self.leafPath = leafPath
        self.kind = kind
        self.distance = distance
    }
}

/// An anchor inside a marquee: the primitive and the element that ends at the anchor.
public struct AnchorReference: Hashable, Sendable {
    public var leafPath: [Int]
    public var element: Int

    public init(leafPath: [Int], element: Int) {
        self.leafPath = leafPath
        self.element = element
    }
}

/// What a marquee picks from one item.
public struct MarqueeHit: Hashable, Sendable {
    public var itemPath: [Int]
    /// Whether the item is selected: enclosed, or touched when contact-sensitive.
    public var selected: Bool
    /// Anchors inside the marquee, selected in either mode.
    public var anchors: [AnchorReference]

    public init(itemPath: [Int], selected: Bool, anchors: [AnchorReference]) {
        self.itemPath = itemPath
        self.selected = selected
        self.anchors = anchors
    }
}

/// Hit tests one display list through one viewport.
public struct HitTester: Sendable {
    public private(set) var displayList: DisplayList
    /// The spatial index over top-level item indices.
    public private(set) var index: RTree<Int>
    public var viewport: Viewport
    public var options: HitOptions

    public init(displayList: DisplayList, viewport: Viewport, options: HitOptions = HitOptions()) {
        self.displayList = displayList
        self.viewport = viewport
        self.options = options
        index = HitTester.makeIndex(displayList)
    }

    static func makeIndex(_ list: DisplayList) -> RTree<Int> {
        RTree(bulkLoading: list.itemBounds.enumerated().compactMap { index, bounds in
            bounds.map { (index, $0) }
        })
    }

    /// Replaces the list and rebuilds the index.
    public mutating func update(displayList newList: DisplayList) {
        displayList = newList
        index = HitTester.makeIndex(newList)
    }

    /// Replaces the list, maintaining the index incrementally for the items at
    /// `changedIndices` (REND-004 supplies them from `ChangeSummary`).  A list of a different
    /// length is rebuilt, since every later index shifted.
    public mutating func update<S: Sequence>(displayList newList: DisplayList, changedIndices: S) where S.Element == Int {
        guard newList.count == displayList.count else {
            update(displayList: newList)
            return
        }
        for changed in changedIndices where newList.itemBounds.indices.contains(changed) {
            if let bounds = newList.itemBounds[changed] {
                index.update(changed, bounds: bounds)
            } else {
                index.remove(changed)
            }
        }
        displayList = newList
    }

    // MARK: Point hits

    /// Everything under `viewPoint` (view points), top-most first: one result per top-level
    /// item, or with `subselect` one per member hit.
    public func hitTest(viewPoint: Point) -> [HitResult] {
        let point = viewport.toPasteboard(viewPoint)
        let tolerance = options.pasteboardTolerance(for: viewport)
        let probe = Rect(x: point.x - tolerance, y: point.y - tolerance, width: 2 * tolerance, height: 2 * tolerance)
        var results: [HitResult] = []
        for top in index.query(probe).sorted(by: >) {
            let hits = self.hits(displayList.items[top], path: [top], point: point, tolerance: tolerance)
            if options.subselect {
                results.append(contentsOf: hits.map {
                    HitResult(itemPath: $0.leafPath, leafPath: $0.leafPath, kind: $0.kind, distance: $0.distance)
                })
            } else if let first = hits.first {
                results.append(HitResult(itemPath: [top], leafPath: first.leafPath, kind: first.kind, distance: first.distance))
            }
        }
        return results
    }

    /// Hits within `item` (at `path`), top-most first.
    private func hits(_ item: DisplayItem, path: [Int], point: Point, tolerance: Double) -> [HitResult] {
        guard case .group(let group) = item else {
            guard let (kind, distance) = hitLeaf(item, point: point, tolerance: tolerance) else {
                return []
            }
            return [HitResult(itemPath: path, leafPath: path, kind: kind, distance: distance)]
        }
        if let clip = group.clip {
            let clipContours = clip.contours.map { $0.applying(group.transform) }
            guard HitTester.contains(clipContours, point, rule: group.clipRule) else {
                return []
            }
        }
        var result: [HitResult] = []
        for (childIndex, child) in group.children.enumerated().reversed() {
            guard let bounds = child.bounds, bounds.expanded(by: tolerance).contains(point) else {
                continue
            }
            result.append(contentsOf: hits(child, path: path + [childIndex], point: point, tolerance: tolerance))
        }
        return result
    }

    /// The pickable geometry of a path-bearing primitive.
    private struct Shape {
        let path: DisplayPath
        let transform: AffineTransform
        /// The rules of the fills that paint.
        let fillRules: [FillRule]
        /// The widest stroke that paints.
        let stroke: StrokeStyle?
        let heads: [PlacedArrowhead]
    }

    private func shape(of item: DisplayItem) -> Shape? {
        switch item {
        case .fill(let fill):
            return Shape(path: fill.path, transform: fill.transform, fillRules: fill.paint.isNone ? [] : [fill.rule], stroke: nil, heads: [])
        case .stroke(let stroke):
            return Shape(path: stroke.path, transform: stroke.transform, fillRules: [], stroke: stroke.paint.isNone ? nil : stroke.style, heads: [])
        case .path(let item):
            let appearance = item.appearance
            let heads = appearance.strokes
                .filter { !$0.paint.isNone && $0.hasArrowheads }
                .flatMap { StrokeGeometry(path: item.path, stroke: $0).heads }
            return Shape(
                path: item.path,
                transform: item.transform,
                fillRules: appearance.fills.filter { !$0.paint.isNone }.map(\.rule),
                stroke: appearance.widestStroke?.style,
                heads: heads
            )
        case .image, .text, .group:
            return nil
        }
    }

    private func hitLeaf(_ item: DisplayItem, point: Point, tolerance: Double) -> (HitKind, Double)? {
        switch item {
        case .image(let image):
            return hitFrame(image.rect, transform: image.transform, point: point, tolerance: tolerance).map { (.image, $0) }
        case .text(let text):
            return hitFrame(text.bounds, transform: text.transform, point: point, tolerance: tolerance).map { (.text, $0) }
        default:
            return shape(of: item).flatMap { hitShape($0, point: point, tolerance: tolerance) }
        }
    }

    /// Inside the transformed rectangle, or within the tolerance of its edge.
    private func hitFrame(_ rect: Rect, transform: AffineTransform, point: Point, tolerance: Double) -> Double? {
        let frame = HitTester.frameContour(rect, transform: transform)
        if frame.contains(point) {
            return 0
        }
        guard let nearest = HitTester.nearest(on: [frame], to: point, reach: tolerance) else {
            return nil
        }
        return nearest.distance
    }

    private func hitShape(_ shape: Shape, point: Point, tolerance: Double) -> (HitKind, Double)? {
        let transform = shape.transform
        if options.pickPoints || options.pickHandles {
            var best: (PathPoint, Double)?
            for candidate in shape.path.points(includeControls: options.pickHandles) {
                if candidate.control == 0 && !options.pickPoints {
                    continue
                }
                let distance = transform.apply(candidate.point).distance(to: point)
                if distance <= tolerance && (best == nil || distance < best!.1) {
                    best = (candidate, distance)
                }
            }
            if let (hit, distance) = best {
                return (hit.control == 0 ? .point(element: hit.element) : .handle(element: hit.element, control: hit.control), distance)
            }
        }
        let contours = shape.path.contours.map { $0.applying(transform) }
        let scale = transform.scaleFactor
        if let style = shape.stroke {
            let halfWidth = max(style.width, 0) * scale / 2
            // A square cap's corners reach √2 × (half width + tolerance) past an end point.
            let reach = (halfWidth + tolerance) * (style.cap == .square ? 2.0.squareRoot() : 1)
            if let nearest = HitTester.nearest(on: contours, to: point, reach: reach),
               HitTester.capAllows(nearest, contours: contours, cap: style.cap, point: point, halfWidth: halfWidth, tolerance: tolerance) {
                return (.stroke(nearest.location), nearest.distance)
            }
            for head in shape.heads {
                let headContours = head.arrowhead.shape.contours.map { $0.applying(head.transform.concatenating(transform)) }
                if head.arrowhead.filled && HitTester.contains(headContours, point, rule: .nonZero) {
                    return (.stroke(nil), 0)
                }
                let reach = (head.arrowhead.filled ? 0 : halfWidth) + tolerance
                if let nearest = HitTester.nearest(on: headContours, to: point, reach: reach) {
                    return (.stroke(nil), nearest.distance)
                }
            }
        }
        if let nearest = HitTester.nearest(on: contours, to: point, reach: tolerance) {
            return (.segment(nearest.location), nearest.distance)
        }
        for rule in shape.fillRules where HitTester.contains(contours, point, rule: rule) {
            return (.fill, 0)
        }
        return nil
    }

    // MARK: Marquee

    /// What `viewRect` (view points) picks, top-most first.  An item is selected when the
    /// marquee encloses its path geometry, or with `contactSensitive` (default: the options')
    /// when the marquee touches its outline; anchors inside the marquee are reported in either
    /// mode.  Without `subselect` a group is one item: enclosed when every member is, touched
    /// when any member is.
    public func hitTest(marquee viewRect: Rect, contactSensitive: Bool? = nil) -> [MarqueeHit] {
        let contact = contactSensitive ?? options.contactSensitive
        let toView = viewport.pasteboardToView
        var results: [MarqueeHit] = []
        for top in index.query(viewRect.applying(viewport.viewToPasteboard)).sorted(by: >) {
            let leaves = HitTester.leaves(of: displayList.items[top], path: [top])
            let tests = leaves.map { leaf in
                (leaf.path, marqueeTest(leaf.item, path: leaf.path, viewRect: viewRect, toView: toView))
            }
            if options.subselect {
                for (path, test) in tests {
                    let selected = contact ? test.touched : test.enclosed
                    if selected || !test.anchors.isEmpty {
                        results.append(MarqueeHit(itemPath: path, selected: selected, anchors: test.anchors))
                    }
                }
            } else {
                let selected = contact ? tests.contains { $0.1.touched } : !tests.isEmpty && tests.allSatisfy { $0.1.enclosed }
                let anchors = tests.flatMap { $0.1.anchors }
                if selected || !anchors.isEmpty {
                    results.append(MarqueeHit(itemPath: [top], selected: selected, anchors: anchors))
                }
            }
        }
        return results
    }

    /// Every non-group primitive under `item` that paints something, in draw order.
    static func leaves(of item: DisplayItem, path: [Int]) -> [(path: [Int], item: DisplayItem)] {
        guard case .group(let group) = item else {
            return item.bounds == nil ? [] : [(path, item)]
        }
        return group.children.enumerated().flatMap { leaves(of: $0.element, path: path + [$0.offset]) }
    }

    private struct MarqueeTest {
        var enclosed = false
        var touched = false
        var anchors: [AnchorReference] = []
    }

    private func marqueeTest(_ item: DisplayItem, path: [Int], viewRect: Rect, toView: AffineTransform) -> MarqueeTest {
        var test = MarqueeTest()
        let contours: [Contour]
        switch item {
        case .image(let image):
            contours = [HitTester.frameContour(image.rect, transform: image.transform.concatenating(toView))]
        case .text(let text):
            contours = [HitTester.frameContour(text.bounds, transform: text.transform.concatenating(toView))]
        default:
            // Leaves are never groups, so every other kind has a shape.
            let shape = shape(of: item)!
            let transform = shape.transform.concatenating(toView)
            contours = shape.path.contours.map { $0.applying(transform) }
            for anchor in shape.path.points(includeControls: false) where viewRect.contains(transform.apply(anchor.point)) {
                test.anchors.append(AnchorReference(leafPath: path, element: anchor.element))
            }
        }
        var bounds = Rect.null
        for contour in contours {
            bounds.formUnion(contour.bounds)
        }
        test.enclosed = !bounds.isNull && viewRect.contains(bounds)
        test.touched = test.enclosed || !test.anchors.isEmpty || HitTester.outline(of: contours, crosses: viewRect)
        return test
    }

    /// Whether any segment of `contours` (closing segments included) crosses an edge of `rect`
    /// or has an end point inside it.
    static func outline(of contours: [Contour], crosses rect: Rect) -> Bool {
        let corners = [
            Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY),
            Point(x: rect.maxX, y: rect.maxY), Point(x: rect.minX, y: rect.maxY),
        ]
        let edges = (0..<4).map { Line(start: corners[$0], end: corners[($0 + 1) % 4]) }
        for contour in contours {
            for segment in outlineSegments(of: contour) where segment.controlBounds.intersects(rect) {
                if rect.contains(segment.p0) || rect.contains(segment.p3) {
                    return true
                }
                for edge in edges where !segment.intersections(with: edge).isEmpty {
                    return true
                }
            }
        }
        return false
    }

    // MARK: Geometry

    /// A rectangle's outline through `transform`, as a closed contour.
    static func frameContour(_ rect: Rect, transform: AffineTransform) -> Contour {
        Contour(polygon: [
            Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY),
            Point(x: rect.maxX, y: rect.maxY), Point(x: rect.minX, y: rect.maxY),
        ].map { transform.apply($0) })
    }

    /// The segments a stroke follows: a closed contour's closing segment included.
    static func outlineSegments(of contour: Contour) -> [CubicBezier] {
        if contour.isClosed, let closing = contour.closingSegment {
            return contour.segments + [closing]
        }
        return contour.segments
    }

    /// Multi-contour containment: the winding numbers (non-zero) or crossing counts (even-odd)
    /// of every contour summed, as one path fills.
    static func contains(_ contours: [Contour], _ point: Point, rule: FillRule) -> Bool {
        switch rule {
        case .nonZero:
            return contours.reduce(0) { $0 + $1.windingNumber(at: point) } != 0
        case .evenOdd:
            return contours.reduce(0) { $0 + $1.crossingCount(at: point) } % 2 == 1
        }
    }

    struct Nearest {
        let location: PathLocation
        let point: Point
        let distance: Double
    }

    /// The closest point of any outline segment to `point`, if within `reach`.  Segments whose
    /// control hull is farther than `reach` are skipped without solving.
    static func nearest(on contours: [Contour], to point: Point, reach: Double) -> Nearest? {
        var best: Nearest?
        for (contourIndex, contour) in contours.enumerated() {
            for (segmentIndex, segment) in outlineSegments(of: contour).enumerated() {
                guard segment.controlBounds.expanded(by: reach).contains(point) else {
                    continue
                }
                let nearest = segment.isLinear()
                    ? Line(start: segment.p0, end: segment.p3).nearestPoint(to: point)
                    : segment.nearestPoint(to: point)
                if nearest.distance <= reach && (best == nil || nearest.distance < best!.distance) {
                    best = Nearest(
                        location: PathLocation(contour: contourIndex, segment: segmentIndex, t: nearest.t),
                        point: nearest.point,
                        distance: nearest.distance
                    )
                }
            }
        }
        return best
    }

    /// Whether the nearest point of the centreline makes a stroke hit.  Along the path and at
    /// round ends that is distance within half the width plus the tolerance; past an open end a
    /// butt cap paints nothing beyond the end point and a square cap paints a half-width square.
    static func capAllows(_ nearest: Nearest, contours: [Contour], cap: LineCap, point: Point, halfWidth: Double, tolerance: Double) -> Bool {
        let withinWidth = nearest.distance <= halfWidth + tolerance
        let contour = contours[nearest.location.contour]
        guard cap != .round, !contour.isClosed else {
            return withinWidth
        }
        let last = contour.segments.count - 1
        let placement: (point: Point, direction: Vector)?
        if nearest.location.segment == 0 && nearest.location.t <= 1e-9 {
            placement = StrokeGeometry.startPlacement(of: contour)
        } else if nearest.location.segment == last && nearest.location.t >= 1 - 1e-9 {
            placement = StrokeGeometry.endPlacement(of: contour)
        } else {
            return withinWidth
        }
        guard let (end, direction) = placement else {
            return withinWidth
        }
        let offset = point - end
        let along = offset.dot(direction)
        let across = abs(offset.cross(direction))
        let allowance = cap == .square ? halfWidth : 0
        return along <= allowance + tolerance && across <= halfWidth + tolerance
    }
}
