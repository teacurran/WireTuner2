// Blends (FX-025, FX-026, FX-029; blends.adoc, "Client").
//
// Key objects are the blend's children in blend order except its path: paths (a composite path's
// contours are its sub-paths) and groups of simple paths; anything else draws plain on top.  For
// each pair of neighbours `PathMatcher` pairs sub-paths (Stacking: by index; Positional: nearest
// centroid; Horizontal/Vertical banding: by rank of centroid y or x), rotates each closed contour
// to start at its blend point, and splits the longest arcs of the contour with fewer segments
// until both have the same count.  Step i of `steps` sits at
// `t = first + (last − first) × i / (steps + 1)`; anchors and handles interpolate linearly, and so
// do stroke widths, dashes of equal length and solid and gradient colours (in sRGB, gradients stop
// by stop over the union of their offsets; a solid colour against a gradient reads as a flat
// gradient); other paints and mismatched stacks switch at the midpoint.  Joined to a path,
// `OnPathDistributor` places each key object and step by its overall position along the path's
// arc length -- the first on the start point, the last on the end -- turned to the tangent when
// Rotate on path is on.  Steps draw between their key objects and hit as the blend.

import Foundation
import WTGeometry

/// One sub-path of a key object, in pasteboard space.
struct BlendSubpath: Hashable, Sendable {
    var contour: Contour
    var appearance: Appearance

    var centroid: Point {
        let bounds = contour.bounds
        return bounds.isNull ? .zero : bounds.center
    }
}

/// A key object's sub-paths.
struct BlendShape: Hashable, Sendable {
    var subpaths: [BlendSubpath]

    /// The key object's sub-paths, or nil when it cannot be blended.
    init?(_ item: DisplayItem, blendPoint: BlendPoint?) {
        switch item {
        case .path(let path):
            let baked = WarpSource.baked(PathItem(path: path.path, appearance: Appearance(path.appearance.items, raster: path.appearance.raster), transform: path.transform))
            subpaths = baked.path.contours.enumerated().map { index, contour in
                let start = blendPoint.flatMap { $0.contour == index ? $0.anchor : nil }
                return BlendSubpath(contour: PathMatcher.rotated(contour, toStartAt: start), appearance: baked.appearance)
            }
        case .group(let group) where group.live == nil && group.children.allSatisfy({ $0.pathItem != nil }):
            subpaths = group.children.flatMap { child -> [BlendSubpath] in
                let path = child.pathItem!
                let baked = WarpSource.baked(PathItem(path: path.path, appearance: Appearance(path.appearance.items, raster: path.appearance.raster), transform: path.transform))
                return baked.path.contours.map { BlendSubpath(contour: $0, appearance: baked.appearance) }
            }
        default:
            return nil
        }
        if subpaths.isEmpty {
            return nil
        }
    }

    init(subpaths: [BlendSubpath]) {
        self.subpaths = subpaths
    }

    var bounds: Rect {
        subpaths.map(\.contour).bounds
    }

    func applying(_ transform: AffineTransform) -> BlendShape {
        BlendShape(subpaths: subpaths.map { BlendSubpath(contour: $0.contour.applying(transform), appearance: $0.appearance) })
    }

    var item: DisplayItem {
        let items = subpaths.map { DisplayItem.path(PathItem(path: DisplayPath(contours: [$0.contour]), appearance: $0.appearance)) }
        return items.count == 1 ? items[0] : .group(GroupItem(children: items))
    }
}

enum PathMatcher {
    /// A closed contour starting at anchor `start` (open contours and nil unchanged).
    static func rotated(_ contour: Contour, toStartAt start: Int?) -> Contour {
        guard let start, contour.isClosed else {
            return contour
        }
        let segments = contour.explicitSegments
        guard segments.indices.contains(start), start > 0 else {
            return Contour(segments: segments, closed: true)
        }
        return Contour(segments: Array(segments[start...] + segments[..<start]), closed: true)
    }

    /// Pairs of sub-path indices of `a` and `b`.
    static func pairs(_ a: BlendShape, _ b: BlendShape, type: BlendSpec.BlendType, order: BlendSpec.Order) -> [(Int, Int)] {
        let countA = a.subpaths.count
        let countB = b.subpaths.count
        let count = max(countA, countB)
        switch type {
        case .horizontal, .vertical:
            func ranked(_ shape: BlendShape) -> [Int] {
                shape.subpaths.indices.sorted { lhs, rhs in
                    let p = shape.subpaths[lhs].centroid
                    let q = shape.subpaths[rhs].centroid
                    return type == .horizontal ? p.y < q.y : p.x < q.x
                }
            }
            let ra = ranked(a)
            let rb = ranked(b)
            return (0..<count).map { (ra[min($0, countA - 1)], rb[min($0, countB - 1)]) }
        case .normal:
            switch order {
            case .stacking:
                return (0..<count).map { (min($0, countA - 1), min($0, countB - 1)) }
            case .positional:
                var available = Array(b.subpaths.indices)
                var result: [(Int, Int)] = []
                for index in 0..<count {
                    let i = min(index, countA - 1)
                    if available.isEmpty {
                        available = Array(b.subpaths.indices)
                    }
                    let centroid = a.subpaths[i].centroid
                    let nearest = available.min { b.subpaths[$0].centroid.distance(to: centroid) < b.subpaths[$1].centroid.distance(to: centroid) }!
                    available.removeAll { $0 == nearest }
                    result.append((i, nearest))
                }
                return result
            }
        }
    }

    /// Two contours with the same segment count and closedness: arcs of the one with fewer
    /// segments split at their arc-length midpoints, longest first.
    static func matched(_ a: Contour, _ b: Contour) -> (Contour, Contour) {
        let closed = a.isClosed && b.isClosed
        var sa = a.explicitSegments
        var sb = b.explicitSegments
        func densify(_ segments: inout [CubicBezier], to count: Int) {
            while segments.count < count, !segments.isEmpty {
                let lengths = segments.map { $0.length() }
                let longest = lengths.indices.max { lengths[$0] < lengths[$1] }!
                let t = segments[longest].parameter(atLength: lengths[longest] / 2)
                let (first, second) = segments[longest].split(at: t)
                segments.replaceSubrange(longest...longest, with: [first, second])
            }
        }
        densify(&sa, to: sb.count)
        densify(&sb, to: sa.count)
        return (Contour(segments: sa, closed: closed), Contour(segments: sb, closed: closed))
    }
}

enum BlendInterpolator {
    /// Anchors and handles at `t`.
    static func contour(_ a: Contour, _ b: Contour, t: Double) -> Contour {
        Contour(segments: zip(a.segments, b.segments).map { p, q in
            CubicBezier(p0: Point.lerp(p.p0, q.p0, t), p1: Point.lerp(p.p1, q.p1, t), p2: Point.lerp(p.p2, q.p2, t), p3: Point.lerp(p.p3, q.p3, t))
        }, closed: a.isClosed)
    }

    static func color(_ a: Color, _ b: Color, t: Double) -> Color {
        Color(red: a.red + (b.red - a.red) * t, green: a.green + (b.green - a.green) * t, blue: a.blue + (b.blue - a.blue) * t, alpha: a.alpha + (b.alpha - a.alpha) * t)
    }

    /// Two gradients stop by stop over the union of their offsets.
    static func gradient(_ a: Gradient, _ b: Gradient, t: Double) -> Gradient {
        let rampA = GradientRamp.cached(a.sortedStops)
        let rampB = GradientRamp.cached(b.sortedStops)
        let offsets = Array(Set(a.sortedStops.map(\.offset) + b.sortedStops.map(\.offset))).sorted()
        let stops = offsets.map { offset -> Gradient.Stop in
            let ca = rampA.color(at: offset)
            let cb = rampB.color(at: offset)
            return Gradient.Stop(offset: offset, color: color(Color(red: ca.x, green: ca.y, blue: ca.z, alpha: ca.w), Color(red: cb.x, green: cb.y, blue: cb.z, alpha: cb.w), t: t))
        }
        var result = t < 0.5 ? a : b
        result.stops = stops
        if let axisA = a.axis, let axisB = b.axis {
            result.axis = Gradient.Axis(
                start: Point.lerp(axisA.start, axisB.start, t),
                end: Point.lerp(axisA.end, axisB.end, t),
                end2: axisA.end2.flatMap { e2 in axisB.end2.map { Point.lerp(e2, $0, t) } }
            )
        }
        return result
    }

    static func paint(_ a: Paint, _ b: Paint, t: Double) -> Paint {
        switch (a, b) {
        case (.solid(let p), .solid(let q)):
            return .solid(color(p, q, t: t))
        case (.gradient(let p), .gradient(let q)) where !p.stops.isEmpty && !q.stops.isEmpty:
            return .gradient(gradient(p, q, t: t))
        case (.solid(let p), .gradient(let q)) where !q.stops.isEmpty:
            return .gradient(gradient(Gradient(q.kind, from: p, to: p, axis: q.axis), q, t: t))
        case (.gradient(let p), .solid(let q)) where !p.stops.isEmpty:
            return .gradient(gradient(p, Gradient(p.kind, from: q, to: q, axis: p.axis), t: t))
        default:
            return t < 0.5 ? a : b
        }
    }

    /// Two stacks at `t`: element by element when their kinds line up, otherwise the nearer.
    static func appearance(_ a: Appearance, _ b: Appearance, t: Double) -> Appearance {
        guard a.items.count == b.items.count else {
            return t < 0.5 ? a : b
        }
        var items: [AppearanceItem] = []
        for (p, q) in zip(a.items, b.items) {
            switch (p, q) {
            case (.fill(let f), .fill(let g)):
                var fill = t < 0.5 ? f : g
                fill.paint = paint(f.paint, g.paint, t: t)
                items.append(.fill(fill))
            case (.stroke(let s), .stroke(let r)) where s.kind == .basic && r.kind == .basic:
                var stroke = t < 0.5 ? s : r
                stroke.paint = paint(s.paint, r.paint, t: t)
                stroke.style.width = s.style.width + (r.style.width - s.style.width) * t
                if s.style.dash.count == r.style.dash.count {
                    stroke.style.dash = zip(s.style.dash, r.style.dash).map { $0 + ($1 - $0) * t }
                    stroke.style.dashPhase = s.style.dashPhase + (r.style.dashPhase - s.style.dashPhase) * t
                }
                items.append(.stroke(stroke))
            default:
                return t < 0.5 ? a : b
            }
        }
        return Appearance(items, raster: a.raster)
    }

    /// A pair of neighbours' sub-paths matched once for all their steps.
    struct MatchedPair {
        var from: BlendSubpath
        var to: BlendSubpath
    }

    static func matched(_ a: BlendShape, _ b: BlendShape, pairs: [(Int, Int)]) -> [MatchedPair] {
        pairs.map { i, j in
            let (p, q) = PathMatcher.matched(a.subpaths[i].contour, b.subpaths[j].contour)
            return MatchedPair(from: BlendSubpath(contour: p, appearance: a.subpaths[i].appearance), to: BlendSubpath(contour: q, appearance: b.subpaths[j].appearance))
        }
    }

    /// The pair's shape at `t`.
    static func step(_ matched: [MatchedPair], t: Double) -> BlendShape {
        BlendShape(subpaths: matched.map { pair in
            BlendSubpath(contour: contour(pair.from.contour, pair.to.contour, t: t), appearance: appearance(pair.from.appearance, pair.to.appearance, t: t))
        })
    }

    /// The parameters of `steps` steps between `first` and `last` percent.
    static func parameters(steps: Int, first: Double, last: Double) -> [Double] {
        guard steps > 0 else { return [] }
        return (1...steps).map { first + (last - first) * Double($0) / Double(steps + 1) }
    }

    // MARK: Default steps

    /// CIE L*a*b* (D65) of an sRGB colour.
    static func lab(_ color: Color) -> SIMD3<Double> {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = linear(color.red), g = linear(color.green), b = linear(color.blue)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ v: Double) -> Double { v > 216.0 / 24389 ? cbrt(v) : (24389.0 / 27 * v + 16) / 116 }
        return SIMD3(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    static func deltaE(_ a: Color, _ b: Color) -> Double {
        let d = lab(a) - lab(b)
        return (d * d).sum().squareRoot()
    }

    /// `max(1, ceil(ΔE × 3))` capped at 100 between the end fill colours; 25 without a
    /// difference.
    static func defaultSteps(_ shapes: [BlendShape]) -> Int {
        let colors = shapes.compactMap { shape in shape.subpaths.lazy.compactMap { $0.appearance.fills.first?.paint.color }.first }
        guard let first = colors.first, let last = colors.last, colors.count >= 2 else {
            return 25
        }
        let difference = deltaE(first, last)
        guard difference > 1e-9 else {
            return 25
        }
        return min(max(Int((difference * 3).rounded(.up)), 1), 100)
    }
}

/// Arc-length placement along a path (FX-026).
struct OnPathDistributor {
    let path: ArcLengthPath
    let rotates: Bool

    init?(_ item: DisplayItem, rotates: Bool) {
        guard case .path(let spine) = item,
              let contour = spine.path.contours.first?.applying(spine.transform),
              !contour.isEmpty
        else {
            return nil
        }
        path = ArcLengthPath(contour: contour, tolerance: 0.01)
        guard path.length > 0 else {
            return nil
        }
        self.rotates = rotates
    }

    /// Moves `shape` so its centre sits at `fraction` of the path's length, turned to the
    /// tangent when rotating.
    func placement(for shape: BlendShape, at fraction: Double) -> AffineTransform {
        let bounds = shape.bounds
        let center = bounds.isNull ? Point.zero : bounds.center
        let location = path.location(at: min(max(fraction, 0), 1) * path.length)
        var result = AffineTransform.translation(x: -center.x, y: -center.y)
        if rotates {
            result = result.concatenating(.rotation(radians: atan2(location.tangent.dy, location.tangent.dx)))
        }
        return result.concatenating(.translation(x: location.point.x, y: location.point.y))
    }
}

enum BlendResolver {
    static func entries(_ spec: BlendSpec, children: [DisplayItem]) -> [DerivedGroup.Entry] {
        let pathIndex = spec.path.flatMap { index -> Int? in
            guard children.indices.contains(index), case .path = children[index] else { return nil }
            return index
        }
        var keys: [(index: Int, shape: BlendShape)] = []
        var others: [Int] = []
        for (index, child) in children.enumerated() where index != pathIndex {
            let point = spec.blendPoints.last { $0.child == index }
            if let shape = BlendShape(child, blendPoint: point) {
                keys.append((index, shape))
            } else {
                others.append(index)
            }
        }
        guard keys.count >= 2 else {
            return children.enumerated().map { DerivedGroup.Entry(item: $0.element, origin: $0.offset) }
        }
        let distributor = pathIndex.flatMap { OnPathDistributor(children[$0], rotates: spec.rotateOnPath) }
        let steps = spec.steps == 0 ? BlendInterpolator.defaultSteps(keys.map(\.shape)) : min(max(spec.steps, 1), 1000)
        var first = min(max(spec.rangeFirst.isFinite ? spec.rangeFirst : 0, 0), 100) / 100
        var last = spec.rangeLast == 0 || !spec.rangeLast.isFinite ? 1 : min(max(spec.rangeLast, 0), 100) / 100
        if first > last {
            swap(&first, &last)
        }
        let parameters = BlendInterpolator.parameters(steps: steps, first: first, last: last)
        let spans = Double(keys.count - 1)
        var entries: [DerivedGroup.Entry] = []
        if let pathIndex {
            entries.append(DerivedGroup.Entry(item: children[pathIndex], origin: pathIndex, visible: spec.showPath))
        }
        func placed(_ shape: BlendShape, at fraction: Double) -> BlendShape {
            distributor.map { shape.applying($0.placement(for: shape, at: fraction)) } ?? shape
        }
        for (position, key) in keys.enumerated() {
            if position > 0 {
                let a = keys[position - 1].shape
                let b = key.shape
                let matched = BlendInterpolator.matched(a, b, pairs: PathMatcher.pairs(a, b, type: spec.type, order: spec.order))
                for t in parameters {
                    let shape = BlendInterpolator.step(matched, t: t)
                    entries.append(DerivedGroup.Entry(item: placed(shape, at: (Double(position - 1) + t) / spans).item, origin: nil))
                }
            }
            let item = distributor == nil ? children[key.index] : placed(key.shape, at: Double(position) / spans).item
            entries.append(DerivedGroup.Entry(item: item, origin: key.index))
        }
        for index in others {
            entries.append(DerivedGroup.Entry(item: children[index], origin: index))
        }
        return entries
    }
}

extension DisplayItem {
    /// The path item, for a `.path`.
    var pathItem: PathItem? {
        if case .path(let item) = self { return item }
        return nil
    }
}
