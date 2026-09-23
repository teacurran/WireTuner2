/// A place where a contour crosses or touches itself.
public struct ContourSelfIntersection: Hashable, Sendable {
    /// The first segment and its parameter; `segmentIndex == segments.count` names the closing
    /// segment of a contour whose end does not meet its start (a gap within the tolerance is
    /// not a segment).
    public var segmentIndex: Int
    public var t: Double
    /// The second segment (`>= segmentIndex`) and its parameter; the same segment for a
    /// cubic's own loop, with `u > t`.
    public var otherSegmentIndex: Int
    public var u: Double
    public var point: Point

    public init(segmentIndex: Int, t: Double, otherSegmentIndex: Int, u: Double, point: Point) {
        self.segmentIndex = segmentIndex
        self.t = t
        self.otherSegmentIndex = otherSegmentIndex
        self.u = u
        self.point = point
    }
}

extension CubicBezier {
    /// The two parameters `s < t` at which the curve passes through the same point (its loop),
    /// or nil when it has none in `0...1`.
    ///
    /// Closed form: with `B(t) = a·t³ + b·t² + c·t + d`, `B(s) = B(t)` for `s ≠ t` reduces to
    /// `a·(σ² − π) + b·σ + c = 0` in `σ = s + t` and `π = s·t`, two linear equations in `σ` and
    /// `σ² − π`; `s` and `t` are then the roots of `z² − σ·z + π`.
    public func selfIntersection(tolerance: Double = 1e-9) -> (s: Double, t: Double)? {
        let a = Vector(dx: -p0.x + 3 * p1.x - 3 * p2.x + p3.x, dy: -p0.y + 3 * p1.y - 3 * p2.y + p3.y)
        let b = Vector(dx: 3 * p0.x - 6 * p1.x + 3 * p2.x, dy: 3 * p0.y - 6 * p1.y + 3 * p2.y)
        let c = Vector(dx: 3 * (p1.x - p0.x), dy: 3 * (p1.y - p0.y))
        let denominator = a.dy * b.dx - a.dx * b.dy
        let scale = max(a.lengthSquared, b.lengthSquared, 1e-300)
        guard abs(denominator) > 1e-12 * scale else {
            return nil
        }
        let sigma = (a.dx * c.dy - a.dy * c.dx) / denominator
        let w: Double  // σ² − π
        if abs(a.dx) >= abs(a.dy) {
            w = -(b.dx * sigma + c.dx) / a.dx
        } else {
            w = -(b.dy * sigma + c.dy) / a.dy
        }
        let pi = sigma * sigma - w
        let disc = sigma * sigma - 4 * pi
        guard disc > 0, disc.isFinite else {
            return nil
        }
        let root = disc.squareRoot()
        let s = (sigma - root) / 2
        let t = (sigma + root) / 2
        guard s >= -tolerance, t <= 1 + tolerance, t - s > tolerance else {
            return nil
        }
        return (min(1, max(0, s)), min(1, max(0, t)))
    }
}

extension Contour {
    /// Every place where the (implicitly closed) contour crosses or touches itself, other than
    /// the joins between consecutive segments: crossings between two segments, each segment's
    /// own loop, and touches.  Where two segments share a stretch, the ends of the stretch are
    /// reported.  Ordered by segment, then parameter.
    public func selfIntersections(tolerance: Double = 1e-6) -> [ContourSelfIntersection] {
        var all = segments
        // A closing gap within tolerance is a rounding artifact, not a segment: the last
        // segment then joins the first directly.
        if let closing = closingSegment, closing.chordLength > tolerance {
            all.append(closing)
        }
        let n = all.count
        var result: [ContourSelfIntersection] = []
        let joinSlop = tolerance * 10
        for i in 0..<n {
            if let loop = all[i].selfIntersection() {
                result.append(ContourSelfIntersection(
                    segmentIndex: i, t: loop.s, otherSegmentIndex: i, u: loop.t, point: all[i].evaluate(loop.s)))
            }
            guard i + 1 < n else {
                continue
            }
            for j in (i + 1)..<n {
                guard all[i].controlBounds.intersects(all[j].controlBounds, tolerance: tolerance) else {
                    continue
                }
                var joins: [Point] = []
                if j == i + 1 {
                    joins.append(all[i].p3)
                }
                if i == 0 && j == n - 1 && n > 1 {
                    joins.append(all[0].p0)
                }
                let (crossings, overlap) = all[i].arrangementIntersections(with: all[j], tolerance: tolerance)
                for hit in crossings where !joins.contains(where: { $0.distance(to: hit.point) <= joinSlop }) {
                    result.append(ContourSelfIntersection(segmentIndex: i, t: hit.t, otherSegmentIndex: j, u: hit.u, point: hit.point))
                }
                if let overlap {
                    for (t, u) in [(overlap.t0, overlap.u0), (overlap.t1, overlap.u1)] {
                        let p = all[i].evaluate(t)
                        if !joins.contains(where: { $0.distance(to: p) <= joinSlop }) {
                            result.append(ContourSelfIntersection(segmentIndex: i, t: t, otherSegmentIndex: j, u: u, point: p))
                        }
                    }
                }
            }
        }
        result.sort { ($0.segmentIndex, $0.t) < ($1.segmentIndex, $1.t) }
        return result
    }

    /// Whether the contour crosses or touches itself anywhere but at its joins.
    public func isSimple(tolerance: Double = 1e-6) -> Bool {
        selfIntersections(tolerance: tolerance).isEmpty
    }

    /// The region the contour fills under `rule`, split into simple contours that neither cross
    /// nor overlap (outer contours positive, holes negative).  A figure-eight becomes its two
    /// lobes; a contour that doubles back on itself loses the doubled stretch.
    public func normalized(rule: FillRule = .nonZero) -> [Contour] {
        Boolean.normalize(FilledPath(self, fillRule: rule)).contours
    }
}
