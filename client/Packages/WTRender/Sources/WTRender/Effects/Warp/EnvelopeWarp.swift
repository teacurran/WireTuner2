// Envelopes (FX-038; path-effects.adoc, "Kernels"): a bicubic Coons patch over the four edge
// curves of the envelope contour -- each edge the contour between two corners, refit as one cubic
// when it has points between them -- maps `sourceBounds` onto the patch.  Contents are mapped
// through it with `CurveWarp` (within 0.1 pt), text as its laid-out glyph outlines; the inverse
// map places carets.  A corner that names no anchor falls back to the anchor nearest that corner
// of the envelope's bounds; with fewer than four anchors the contents draw unwarped.

import WTGeometry

struct EnvelopeWarp: Hashable, Sendable {
    /// Edges, each from its first corner: top TL→TR, bottom BL→BR, left TL→BL, right TR→BR.
    let top: CubicBezier
    let bottom: CubicBezier
    let left: CubicBezier
    let right: CubicBezier
    let source: Rect

    /// The patch of `spec`, or nil when the envelope cannot warp.
    init?(_ spec: EnvelopeSpec) {
        guard let contour = spec.contour.contours.first(where: { $0.isClosed && !$0.isEmpty }),
              spec.sourceBounds.width > 0, spec.sourceBounds.height > 0
        else {
            return nil
        }
        let segments = contour.explicitSegments
        let anchors = segments.map(\.p0)
        guard anchors.count >= 4, let corners = EnvelopeWarp.corners(spec.corners, anchors: anchors) else {
            return nil
        }
        func edge(_ from: Int, _ to: Int) -> CubicBezier {
            var chain: [CubicBezier] = []
            var index = from
            repeat {
                chain.append(segments[index])
                index = (index + 1) % segments.count
            } while index != to
            return chain.count == 1 ? chain[0] : EnvelopeWarp.fit(chain)
        }
        let (tl, tr, br, bl) = (corners[0], corners[1], corners[2], corners[3])
        // Contour order may run either way round; follow it from each corner to the next.
        let inOrder = EnvelopeWarp.follows(tl, tr, br, bl, count: segments.count)
        if inOrder {
            top = edge(tl, tr)
            right = edge(tr, br)
            bottom = edge(br, bl).reversed()
            left = edge(bl, tl).reversed()
        } else {
            left = edge(tl, bl)
            bottom = edge(bl, br)
            right = edge(br, tr).reversed()
            top = edge(tr, tl).reversed()
        }
        source = spec.sourceBounds
    }

    /// Whether TL, TR, BR, BL come in that order along the contour.
    static func follows(_ a: Int, _ b: Int, _ c: Int, _ d: Int, count: Int) -> Bool {
        func distance(_ from: Int, _ to: Int) -> Int { (to - from + count) % count }
        return distance(a, b) < distance(a, c) && distance(a, c) < distance(a, d)
    }

    /// The corner anchors: valid, distinct stored indices, the rest the anchors nearest the
    /// bounds' corners; nil when four distinct corners cannot be found.
    static func corners(_ stored: [Int?], anchors: [Point]) -> [Int]? {
        let bounds = Rect(boundingPoints: anchors)
        let targets = [bounds.minPoint, Point(x: bounds.maxX, y: bounds.minY), bounds.maxPoint, Point(x: bounds.minX, y: bounds.maxY)]
        let claimed = Set(stored.compactMap { $0 }.filter { anchors.indices.contains($0) })
        var result: [Int] = []
        for corner in 0..<4 {
            if corner < stored.count, let index = stored[corner], anchors.indices.contains(index), !result.contains(index) {
                result.append(index)
                continue
            }
            let pool = anchors.indices.filter { !result.contains($0) && !claimed.contains($0) }
            guard let nearest = pool.min(by: { anchors[$0].distance(to: targets[corner]) < anchors[$1].distance(to: targets[corner]) }) else {
                return nil
            }
            result.append(nearest)
        }
        return result
    }

    /// One cubic approximating a chain of segments: the chain's end points and end tangents,
    /// handle lengths by least squares over chord-length-parametrized samples.
    static func fit(_ chain: [CubicBezier]) -> CubicBezier {
        var samples: [Point] = []
        for segment in chain {
            for index in 0..<16 {
                samples.append(segment.evaluate(Double(index) / 16))
            }
        }
        samples.append(chain[chain.count - 1].p3)
        var parameters = [0.0]
        for index in 1..<samples.count {
            parameters.append(parameters[index - 1] + samples[index].distance(to: samples[index - 1]))
        }
        let total = parameters[parameters.count - 1]
        let p0 = chain[0].p0
        let p3 = chain[chain.count - 1].p3
        let t0 = chain.first(where: { !$0.isDegenerate })?.tangent(0) ?? (p3 - p0).normalized
        let t1 = chain.last(where: { !$0.isDegenerate })?.tangent(1) ?? (p3 - p0).normalized
        guard total > 0 else {
            return CubicBezier(p0: p0, p1: p0, p2: p3, p3: p3)
        }
        // Schneider's normal equations for the two handle lengths.
        var c00 = 0.0, c01 = 0.0, c11 = 0.0, x0 = 0.0, x1 = 0.0
        for (index, point) in samples.enumerated() {
            let u = parameters[index] / total
            let b0 = (1 - u) * (1 - u) * (1 - u)
            let b1 = 3 * u * (1 - u) * (1 - u)
            let b2 = 3 * u * u * (1 - u)
            let b3 = u * u * u
            let a1 = t0 * b1
            let a2 = -t1 * b2
            c00 += a1.dot(a1)
            c01 += a1.dot(a2)
            c11 += a2.dot(a2)
            let base = Vector(p0.x * (b0 + b1) + p3.x * (b2 + b3), p0.y * (b0 + b1) + p3.y * (b2 + b3))
            let residual = point - Point(x: base.dx, y: base.dy)
            x0 += a1.dot(residual)
            x1 += a2.dot(residual)
        }
        let determinant = c00 * c11 - c01 * c01
        let chord = p0.distance(to: p3)
        var alpha1 = chord / 3
        var alpha2 = chord / 3
        if abs(determinant) > 1e-12 {
            alpha1 = (x0 * c11 - x1 * c01) / determinant
            alpha2 = (c00 * x1 - c01 * x0) / determinant
        }
        if !(alpha1 > 1e-6) || !(alpha2 > 1e-6) {
            alpha1 = chord / 3
            alpha2 = chord / 3
        }
        return CubicBezier(p0: p0, p1: p0 + t0 * alpha1, p2: p3 - t1 * alpha2, p3: p3)
    }

    /// The patch at `(u, v)` in 0 ... 1: u across (left to right), v down (top to bottom).
    func patch(u: Double, v: Double) -> Point {
        let t = top.evaluate(u)
        let b = bottom.evaluate(u)
        let l = left.evaluate(v)
        let r = right.evaluate(v)
        let tl = top.p0, tr = top.p3, bl = bottom.p0, br = bottom.p3
        let x = (1 - v) * t.x + v * b.x + (1 - u) * l.x + u * r.x
            - ((1 - u) * (1 - v) * tl.x + u * (1 - v) * tr.x + (1 - u) * v * bl.x + u * v * br.x)
        let y = (1 - v) * t.y + v * b.y + (1 - u) * l.y + u * r.y
            - ((1 - u) * (1 - v) * tl.y + u * (1 - v) * tr.y + (1 - u) * v * bl.y + u * v * br.y)
        return Point(x: x, y: y)
    }

    /// A source point mapped onto the patch.
    func map(_ point: Point) -> Point {
        patch(u: (point.x - source.minX) / source.width, v: (point.y - source.minY) / source.height)
    }

    /// The source point that maps to `point` (Newton's method from the centre), for caret
    /// placement in warped text; nil when it does not converge.
    func inverse(_ point: Point) -> Point? {
        var u = 0.5
        var v = 0.5
        for _ in 0..<50 {
            let current = patch(u: u, v: v)
            let error = point - current
            if error.length < 1e-9 {
                break
            }
            let h = 1e-6
            let du = (patch(u: u + h, v: v) - patch(u: u - h, v: v)) / (2 * h)
            let dv = (patch(u: u, v: v + h) - patch(u: u, v: v - h)) / (2 * h)
            let determinant = du.cross(dv)
            guard abs(determinant) > 1e-12 else {
                return nil
            }
            u += error.cross(dv) / determinant
            v += du.cross(error) / determinant
        }
        guard (patch(u: u, v: v) - point).length < 1e-6 else {
            return nil
        }
        return Point(x: source.minX + u * source.width, y: source.minY + v * source.height)
    }

    /// The Show Map mesh: `divisions` iso-curves each way, as open contours.
    func mesh(divisions: Int = 8) -> DisplayPath {
        var path = DisplayPath()
        let samples = 32
        for line in 0...divisions {
            let fixed = Double(line) / Double(divisions)
            for vertical in [false, true] {
                for index in 0...samples {
                    let t = Double(index) / Double(samples)
                    let point = vertical ? patch(u: fixed, v: t) : patch(u: t, v: fixed)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
        }
        return path
    }
}

enum EnvelopeResolver {
    static func entries(_ spec: EnvelopeSpec, children: [DisplayItem]) -> [DerivedGroup.Entry] {
        guard let warp = EnvelopeWarp(spec) else {
            return children.enumerated().map { DerivedGroup.Entry(item: $0.element, origin: $0.offset) }
        }
        var entries: [DerivedGroup.Entry] = []
        for (index, child) in children.enumerated() {
            if let item = WarpSource.mapped(WarpSource.plainPaths(child), map: warp.map) {
                entries.append(DerivedGroup.Entry(item: item, origin: index))
            }
        }
        if spec.showMap {
            let stroke = StrokePaint(paint: .solid(Color(red: 0.2, green: 0.45, blue: 0.9)), style: StrokeStyle(width: 0))
            entries.append(DerivedGroup.Entry(item: .path(PathItem(path: warp.mesh(), appearance: Appearance([.stroke(stroke)]))), origin: nil))
        }
        return entries
    }
}
