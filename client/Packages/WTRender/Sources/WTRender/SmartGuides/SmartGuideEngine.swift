// Smart guides (OBJ-038; docs/_includes/objects/moving.adoc, "Smart guides" and "Client").
// Alignment lines computed from the objects in view for the duration of one gesture: edge and
// centre alignment with nearby objects and pages, equal spacing between neighbours in a row, and
// size matches while resizing or drawing.  Purely client state: the engine reads the canvas's
// display list and writes nothing.  It feeds WTGeometry's `Snapper` a `.smartGuide` candidate per
// snapping axis, which ranks between ruler guides and the grid (GEO-005).

import WTGeometry

/// One alignment line or hint.
public struct SmartGuide: Hashable, Sendable {
    /// Which coordinate the guide aligns.
    public enum Axis: Hashable, Sendable {
        /// A vertical line at x = `position`: x coordinates align (left, centre, right edges,
        /// horizontal spacing, widths).
        case vertical
        /// A horizontal line at y = `position`: y coordinates align.
        case horizontal
    }

    public enum Kind: Hashable, Sendable {
        /// An edge of the moving bounds on an edge of a candidate or page.
        case edge
        /// The moving centre on a candidate's or page's centre.
        case center
        /// The moving object as far from a neighbour as that neighbour is from the next.
        case spacing
        /// The width (vertical) or height (horizontal) matches a candidate's.
        case size
    }

    public var axis: Axis
    /// Edge and centre: the line's coordinate.  Spacing: the moving edge the gap ends at.  Size:
    /// the matched size.
    public var position: Double
    /// Where along the line it is drawn: the extent covering the moving bounds and every matched
    /// candidate (edge, centre), or the perpendicular band the spacing arrows sit in.  A single
    /// value for a size match.
    public var span: ClosedRange<Double>
    public var kind: Kind
    /// The candidates that take part, in candidate order (pages have no node).
    public var nodes: [NodeID]
    /// The value the overlay labels: the gap for spacing, the size for a size match.
    public var value: Double?
    /// Spacing only: every equal gap, as ranges along the axis the guide aligns.
    public var gaps: [ClosedRange<Double>]

    public init(axis: Axis, position: Double, span: ClosedRange<Double>, kind: Kind, nodes: [NodeID] = [], value: Double? = nil,
                gaps: [ClosedRange<Double>] = []) {
        self.axis = axis
        self.position = position
        self.span = span
        self.kind = kind
        self.nodes = nodes
        self.value = value
        self.gaps = gaps
    }
}

/// What a move query found: the offset that lands the moving bounds on the nearest alignment on
/// each axis (zero on an axis with nothing in reach) and every guide that holds after it.
public struct SmartGuideMatch: Hashable, Sendable {
    public var offset: Vector
    /// Whether the offset on each axis came from a guide.
    public var snapsX: Bool
    public var snapsY: Bool
    public var guides: [SmartGuide]

    public init(offset: Vector = .zero, snapsX: Bool = false, snapsY: Bool = false, guides: [SmartGuide] = []) {
        self.offset = offset
        self.snapsX = snapsX
        self.snapsY = snapsY
        self.guides = guides
    }

    /// The guides as GEO-005 snap lines for the gesture's snapping point `point` (where it is
    /// before snapping): a vertical line at `point.x + offset.dx` when x snaps and a horizontal
    /// one at `point.y + offset.dy` when y snaps, so snapping the point onto them moves the bounds
    /// onto the alignment.  They go into `SnapSources.smartGuides`, where the snapper ranks them
    /// below points, paths and ruler guides and above the grid.
    public func snapGuides(for point: Point) -> [SnapGuide] {
        var result: [SnapGuide] = []
        if snapsX { result.append(.vertical(x: point.x + offset.dx)) }
        if snapsY { result.append(.horizontal(y: point.y + offset.dy)) }
        return result
    }

    /// `snapGuides(for:)` as snap candidates.
    public func snapCandidates(for point: Point) -> [SnapCandidate] {
        snapGuides(for: point).map(SnapCandidate.smartGuide)
    }
}

/// What a resize query found: the width and height to snap to (nil on an axis with no match in
/// reach) and the size guides.
public struct SmartGuideSizeMatch: Hashable, Sendable {
    public var width: Double?
    public var height: Double?
    public var guides: [SmartGuide]

    public init(width: Double? = nil, height: Double? = nil, guides: [SmartGuide] = []) {
        self.width = width
        self.height = height
        self.guides = guides
    }
}

/// The smart-guide engine of one gesture: built when the gesture starts and rebuilt when the
/// viewport or the display list changes during it.
public struct SmartGuideEngine: Sendable {
    /// At most this many objects take part: the nearest to the gesture's start point.
    public static let candidateCap = 500

    /// One object or page the moving bounds can line up with.
    public struct Candidate: Hashable, Sendable {
        /// The object's node; nil for a page or an item built from no node.
        public var node: NodeID?
        /// Pasteboard bounds.
        public var bounds: Rect
        /// A page: its edges and centre count, but it takes no part in spacing or size matches.
        public var isPage: Bool

        public init(node: NodeID?, bounds: Rect, isPage: Bool = false) {
            self.node = node
            self.bounds = bounds
            self.isPage = isPage
        }
    }

    /// One edge or centre line of a candidate on one axis.
    struct Feature: Hashable, Sendable {
        var value: Double
        var candidate: Int
    }

    public let candidates: [Candidate]
    /// Per axis, sorted by value: candidates' edges (min and max) and centres.
    let xEdges: [Feature]
    let xCenters: [Feature]
    let yEdges: [Feature]
    let yCenters: [Feature]
    /// The objects (not pages) sorted by width and by height, for size matches.
    let widths: [Feature]
    let heights: [Feature]

    /// Two coordinates this close count as the same line once the offset is applied.
    static let epsilon = 1e-7

    /// An engine over `candidates` as given (no cap applied).
    public init(candidates: [Candidate]) {
        self.candidates = candidates.filter { !$0.bounds.isNull && $0.bounds.minX.isFinite && $0.bounds.maxX.isFinite
            && $0.bounds.minY.isFinite && $0.bounds.maxY.isFinite }
        var xEdges: [Feature] = [], xCenters: [Feature] = [], yEdges: [Feature] = [], yCenters: [Feature] = []
        var widths: [Feature] = [], heights: [Feature] = []
        for (index, candidate) in self.candidates.enumerated() {
            let r = candidate.bounds
            xEdges += [Feature(value: r.minX, candidate: index), Feature(value: r.maxX, candidate: index)]
            yEdges += [Feature(value: r.minY, candidate: index), Feature(value: r.maxY, candidate: index)]
            xCenters.append(Feature(value: r.midX, candidate: index))
            yCenters.append(Feature(value: r.midY, candidate: index))
            if !candidate.isPage {
                widths.append(Feature(value: r.width, candidate: index))
                heights.append(Feature(value: r.height, candidate: index))
            }
        }
        func sorted(_ features: [Feature]) -> [Feature] {
            features.sorted { ($0.value, $0.candidate) < ($1.value, $1.candidate) }
        }
        self.xEdges = sorted(xEdges)
        self.xCenters = sorted(xCenters)
        self.yEdges = sorted(yEdges)
        self.yCenters = sorted(yCenters)
        self.widths = sorted(widths)
        self.heights = sorted(heights)
    }

    /// The engine of a gesture on the canvas drawn by `displayList`: the top-level items whose
    /// bounds meet `viewport` (pasteboard; through `index` when given, the hit tester's R-tree),
    /// less the items at `excludedItems` and built from `excludedNodes` (the gesture's objects and
    /// anything hidden), the Guides layer's items and the items on `hiddenLayers`, capped at the
    /// `cap` nearest `start`; plus every page in `pages` that meets the viewport.
    public init(displayList: DisplayList, index: RTree<Int>? = nil, viewport: Rect, excludedItems: Set<Int> = [],
                excludedNodes: Set<NodeID> = [], hiddenLayers: Set<NodeID> = [], pages: [Rect] = [], start: Point,
                cap: Int = SmartGuideEngine.candidateCap) {
        let visible = index?.query(viewport) ?? displayList.itemBounds.indices.filter { i in
            displayList.itemBounds[i].map { $0.intersects(viewport) } ?? false
        }
        var skipped = excludedItems
        for span in displayList.layers where span.layer.isGuides || hiddenLayers.contains(span.layer.id) {
            skipped.formUnion(span.range)
        }
        var objects: [(candidate: Candidate, distance: Double, item: Int)] = []
        for item in visible where !skipped.contains(item) && displayList.itemBounds.indices.contains(item) {
            guard let bounds = displayList.itemBounds[item] else { continue }
            let node = displayList.nodeIDs.indices.contains(item) ? displayList.nodeIDs[item] : nil
            if let node, excludedNodes.contains(node) { continue }
            objects.append((Candidate(node: node, bounds: bounds), Self.distance(from: start, to: bounds), item))
        }
        objects.sort { ($0.distance, $0.item) < ($1.distance, $1.item) }
        var kept = objects.prefix(max(cap, 0)).map(\.candidate)
        kept += pages.filter { !$0.isNull && $0.intersects(viewport) }.map { Candidate(node: nil, bounds: $0, isPage: true) }
        self.init(candidates: kept)
    }

    /// The distance from `point` to `rect` (zero inside).
    static func distance(from point: Point, to rect: Rect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: Moving

    /// The guides for bounds `moving` (pasteboard) with snapping reach `tolerance` (pasteboard
    /// units: the *Snap distance* divided by the zoom).  On each axis the nearest alignment in
    /// reach -- edge on edge, centre on centre, or equal spacing -- sets the offset; every guide
    /// that holds at the offset bounds is returned.
    public func guides(moving: Rect, tolerance: Double) -> SmartGuideMatch {
        guard !moving.isNull, tolerance >= 0 else {
            return SmartGuideMatch()
        }
        let dx = bestOffset(axis: .vertical, moving: moving, tolerance: tolerance)
        let dy = bestOffset(axis: .horizontal, moving: moving, tolerance: tolerance)
        let offset = Vector(dx: dx ?? 0, dy: dy ?? 0)
        let placed = Rect(minX: moving.minX + offset.dx, minY: moving.minY + offset.dy, maxX: moving.maxX + offset.dx, maxY: moving.maxY + offset.dy)
        var guides = alignments(axis: .vertical, placed: placed)
        guides += alignments(axis: .horizontal, placed: placed)
        guides += spacings(axis: .vertical, moving: placed, tolerance: Self.epsilon).map(\.guide)
        guides += spacings(axis: .horizontal, moving: placed, tolerance: Self.epsilon).map(\.guide)
        return SmartGuideMatch(offset: offset, snapsX: dx != nil, snapsY: dy != nil, guides: guides)
    }

    /// The smallest offset on `axis` that aligns `moving` within `tolerance`, or nil.
    func bestOffset(axis: SmartGuide.Axis, moving: Rect, tolerance: Double) -> Double? {
        let (edges, centers) = axis == .vertical ? (xEdges, xCenters) : (yEdges, yCenters)
        let low = axis == .vertical ? moving.minX : moving.minY
        let high = axis == .vertical ? moving.maxX : moving.maxY
        var best: Double?
        func consider(_ delta: Double?) {
            guard let delta, abs(delta) <= tolerance else { return }
            if best == nil || abs(delta) < abs(best!) { best = delta }
        }
        consider(Self.nearest(to: low, in: edges).map { $0 - low })
        consider(Self.nearest(to: high, in: edges).map { $0 - high })
        consider(Self.nearest(to: (low + high) / 2, in: centers).map { $0 - (low + high) / 2 })
        for spacing in spacings(axis: axis, moving: moving, tolerance: tolerance) {
            consider(spacing.delta)
        }
        return best
    }

    /// The value in the sorted `features` nearest `value` (binary search), or nil when empty.
    static func nearest(to value: Double, in features: [Feature]) -> Double? {
        guard !features.isEmpty else { return nil }
        var low = 0, high = features.count
        while low < high {
            let mid = (low + high) / 2
            if features[mid].value < value { low = mid + 1 } else { high = mid }
        }
        var best: Double?
        for index in [low - 1, low] where features.indices.contains(index) {
            let candidate = features[index].value
            if best == nil || abs(candidate - value) < abs(best! - value) { best = candidate }
        }
        return best
    }

    /// The features in the sorted `features` within `epsilon` of `value`.
    static func features(at value: Double, in features: [Feature]) -> ArraySlice<Feature> {
        var low = 0, high = features.count
        while low < high {
            let mid = (low + high) / 2
            if features[mid].value < value - epsilon { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < features.count, features[end].value <= value + epsilon { end += 1 }
        return features[low..<end]
    }

    /// The edge and centre guides that hold for `placed` on `axis`.
    func alignments(axis: SmartGuide.Axis, placed: Rect) -> [SmartGuide] {
        let vertical = axis == .vertical
        let (edges, centers) = vertical ? (xEdges, xCenters) : (yEdges, yCenters)
        let low = vertical ? placed.minX : placed.minY
        let high = vertical ? placed.maxX : placed.maxY
        let movingSpan = vertical ? placed.minY...placed.maxY : placed.minX...placed.maxX
        var result: [SmartGuide] = []
        var probes = [(low, edges, SmartGuide.Kind.edge), ((low + high) / 2, centers, .center)]
        if high > low { probes.insert((high, edges, .edge), at: 1) }
        for (value, list, kind) in probes {
            let matches = Self.features(at: value, in: list)
            guard let first = matches.first else { continue }
            let indices = Array(Set(matches.map(\.candidate))).sorted()
            var span = movingSpan
            for index in indices {
                let r = candidates[index].bounds
                let extent = vertical ? r.minY...r.maxY : r.minX...r.maxX
                span = min(span.lowerBound, extent.lowerBound)...max(span.upperBound, extent.upperBound)
            }
            result.append(SmartGuide(axis: axis, position: first.value, span: span, kind: kind, nodes: indices.compactMap { candidates[$0].node }))
        }
        return result
    }

    /// The equal-spacing alignments on `axis` within `tolerance` of `moving`: after the nearest
    /// neighbour in the row on either side and that neighbour's own neighbour (the moving object
    /// continues the row), or centred between the nearest neighbours on both sides.  A row is the
    /// objects overlapping on the other axis; pages take no part.
    func spacings(axis: SmartGuide.Axis, moving: Rect, tolerance: Double) -> [(delta: Double, guide: SmartGuide)] {
        let vertical = axis == .vertical
        func low(_ r: Rect) -> Double { vertical ? r.minX : r.minY }
        func high(_ r: Rect) -> Double { vertical ? r.maxX : r.maxY }
        func across(_ r: Rect) -> ClosedRange<Double> { vertical ? r.minY...r.maxY : r.minX...r.maxX }
        func inRow(_ a: Rect, _ b: Rect) -> Bool { across(a).overlaps(across(b)) }
        /// The nearest object before (`before`) or after `r` in its row, entirely on that side.
        func neighbour(of r: Rect, before: Bool, slack: Double) -> Int? {
            var best: Int?
            for (index, candidate) in candidates.enumerated() where !candidate.isPage && candidate.bounds != r && inRow(candidate.bounds, r) {
                let b = candidate.bounds
                if before {
                    guard high(b) <= low(r) + slack, low(b) < low(r) else { continue }
                    if best == nil || high(b) > high(candidates[best!].bounds) { best = index }
                } else {
                    guard low(b) >= high(r) - slack, high(b) > high(r) else { continue }
                    if best == nil || low(b) < low(candidates[best!].bounds) { best = index }
                }
            }
            return best
        }
        func band(_ rects: [Rect]) -> ClosedRange<Double> {
            let lower = rects.map { across($0).lowerBound }.max()!
            let upper = rects.map { across($0).upperBound }.min()!
            return lower <= upper ? lower...upper : across(moving).lowerBound...across(moving).upperBound
        }
        let size = high(moving) - low(moving)
        let slack = tolerance + Self.epsilon
        var result: [(Double, SmartGuide)] = []
        let before = neighbour(of: moving, before: true, slack: slack)
        let after = neighbour(of: moving, before: false, slack: slack)
        // Continuing the row after its last two objects.
        if let near = before, let far = neighbour(of: candidates[near].bounds, before: true, slack: 0) {
            let n = candidates[near].bounds, f = candidates[far].bounds
            let gap = low(n) - high(f)
            let target = high(n) + gap
            let delta = target - low(moving)
            if gap >= 0, abs(delta) <= tolerance {
                result.append((delta, SmartGuide(axis: axis, position: target, span: band([f, n, moving]), kind: .spacing,
                                                 nodes: [candidates[far].node, candidates[near].node].compactMap { $0 }, value: gap,
                                                 gaps: [high(f)...low(n), high(n)...target])))
            }
        }
        // Continuing it before its first two.
        if let near = after, let far = neighbour(of: candidates[near].bounds, before: false, slack: 0) {
            let n = candidates[near].bounds, f = candidates[far].bounds
            let gap = low(f) - high(n)
            let target = low(n) - gap
            let delta = target - high(moving)
            if gap >= 0, abs(delta) <= tolerance {
                result.append((delta, SmartGuide(axis: axis, position: target, span: band([moving, n, f]), kind: .spacing,
                                                 nodes: [candidates[near].node, candidates[far].node].compactMap { $0 }, value: gap,
                                                 gaps: [target...low(n), high(n)...low(f)])))
            }
        }
        // Centred between two neighbours.
        if let left = before, let right = after {
            let l = candidates[left].bounds, r = candidates[right].bounds
            let gap = (low(r) - high(l) - size) / 2
            let target = high(l) + gap
            let delta = target - low(moving)
            if gap >= 0, abs(delta) <= tolerance {
                result.append((delta, SmartGuide(axis: axis, position: target, span: band([l, moving, r]), kind: .spacing,
                                                 nodes: [candidates[left].node, candidates[right].node].compactMap { $0 }, value: gap,
                                                 gaps: [high(l)...target, (target + size)...low(r)])))
            }
        }
        return result
    }

    // MARK: Resizing

    /// Size matches for an object being resized or drawn to `width` × `height`: on each axis the
    /// nearest object width (height) within `tolerance`, and a size guide naming every object of
    /// that size.
    public func sizeGuides(width: Double, height: Double, tolerance: Double) -> SmartGuideSizeMatch {
        var match = SmartGuideSizeMatch()
        for (axis, value, list) in [(SmartGuide.Axis.vertical, width, widths), (.horizontal, height, heights)] {
            guard value.isFinite, let nearest = Self.nearest(to: value, in: list), abs(nearest - value) <= tolerance else { continue }
            let indices = Array(Set(Self.features(at: nearest, in: list).map(\.candidate))).sorted()
            if axis == .vertical { match.width = nearest } else { match.height = nearest }
            match.guides.append(SmartGuide(axis: axis, position: nearest, span: nearest...nearest, kind: .size,
                                           nodes: indices.compactMap { candidates[$0].node }, value: nearest))
        }
        return match
    }
}
