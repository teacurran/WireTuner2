/// A stretch along which two curves coincide.
public struct CurveOverlap: Hashable, Sendable {
    /// The overlap on the receiver, `t0 < t1`.
    public var t0: Double
    public var t1: Double
    /// The parameters on the other curve matching `t0` and `t1`; `u0 > u1` when the curves
    /// run opposite ways.
    public var u0: Double
    public var u1: Double

    public init(t0: Double, t1: Double, u0: Double, u1: Double) {
        self.t0 = t0
        self.t1 = t1
        self.u0 = u0
        self.u1 = u1
    }

    /// Whether the two curves traverse the shared stretch in the same direction.
    public var isSameDirection: Bool { u1 >= u0 }
}

extension CubicBezier {
    /// The stretch along which this curve and `other` coincide to within `tolerance`, or nil
    /// when they merely cross, touch at a point, or stay apart.
    ///
    /// Two curves that overlap do so between points where one curve's end lies on the other,
    /// so the candidate stretch is bounded by the end points of either curve that lie within
    /// `tolerance` of the other; it is confirmed when `samples` points along it are also within
    /// tolerance.  ``intersections(with:rootTolerance:pointTolerance:flatness:maxCandidates:)``
    /// reports only a capped sample of points for coincident curves; this is the routine that
    /// tells where the coincidence begins and ends.
    public func overlap(with other: CubicBezier, tolerance: Double = 1e-6, samples: Int = 8) -> CurveOverlap? {
        guard controlBounds.intersects(other.controlBounds, tolerance: tolerance) else {
            return nil
        }
        var candidates: [(t: Double, u: Double)] = []
        for (u, q) in [(0.0, other.p0), (1.0, other.p3)] {
            let nearest = nearestPoint(to: q)
            if nearest.distance <= tolerance {
                candidates.append((nearest.t, u))
            }
        }
        for (t, p) in [(0.0, p0), (1.0, p3)] {
            let nearest = other.nearestPoint(to: p)
            if nearest.distance <= tolerance {
                candidates.append((t, nearest.t))
            }
        }
        guard candidates.count >= 2 else {
            return nil
        }
        var low = candidates[0]
        var high = candidates[0]
        for candidate in candidates {
            if candidate.t < low.t {
                low = candidate
            }
            if candidate.t > high.t {
                high = candidate
            }
        }
        // A shared point is not a shared stretch.  When the ends of the candidate stretch meet,
        // it is one only if the curve is a closed loop in between (two coincident teardrops).
        guard high.t - low.t > 1e-6 else {
            return nil
        }
        let endsMeet = evaluate(low.t).distance(to: evaluate(high.t)) <= tolerance
        let middle = (low.t + high.t) / 2
        if endsMeet && evaluate(middle).distance(to: evaluate(low.t)) <= tolerance {
            return nil
        }
        let n = max(2, samples)
        for k in 1..<n {
            let t = low.t + (high.t - low.t) * Double(k) / Double(n)
            if other.nearestPoint(to: evaluate(t)).distance > tolerance {
                return nil
            }
        }
        if endsMeet {
            // Both curves are the same loop; which end of `other` matches is ambiguous, so the
            // direction decides it.
            let at = other.nearestPoint(to: evaluate(middle))
            let same = derivative(middle).dot(other.derivative(at.t)) >= 0
            return CurveOverlap(t0: low.t, t1: high.t, u0: same ? 0 : 1, u1: same ? 1 : 0)
        }
        return CurveOverlap(t0: low.t, t1: high.t, u0: low.u, u1: high.u)
    }

    /// Where two segments meet, for building a planar arrangement: the discrete crossings from
    /// GEO-001 and, when the curves share a stretch, that stretch, with the sample points the
    /// crossing search reports inside a shared stretch removed.  `sharedEndpoint` names a point
    /// the two segments are already known to meet at (consecutive segments of one contour); a
    /// crossing there is not reported.
    func arrangementIntersections(
        with other: CubicBezier, tolerance: Double, sharedEndpoint: Point? = nil
    ) -> (crossings: [Intersection], overlap: CurveOverlap?) {
        var crossings = intersections(with: other, pointTolerance: tolerance)
        let overlap = self.overlap(with: other, tolerance: tolerance)
        if let overlap {
            let margin = 0.01
            crossings.removeAll { $0.t >= overlap.t0 - margin && $0.t <= overlap.t1 + margin }
        }
        if let shared = sharedEndpoint {
            crossings.removeAll { $0.point.distance(to: shared) <= tolerance * 4 }
        }
        return (crossings, overlap)
    }
}
