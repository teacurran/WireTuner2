/// One crossing of two curves.
public struct Intersection: Hashable, Sendable {
    /// The parameter on the receiver of the intersection query.
    public var t: Double
    /// The parameter on the argument.
    public var u: Double
    /// The crossing point, evaluated on the receiver.
    public var point: Point

    @inlinable
    public init(t: Double, u: Double, point: Point) {
        self.t = t
        self.u = u
        self.point = point
    }
}

extension CubicBezier {
    /// Where the curve meets the segment, ordered by `t`.
    ///
    /// Analytic: the signed distance from the line is a cubic in `t` whose real roots in
    /// `0...1` are the crossings.  `rootTolerance` widens the parameter ranges and sets how close
    /// two roots must be (`√rootTolerance`) to count as one tangency; a curve that grazes the
    /// line within `pointTolerance` without crossing it reports the touch.  A curve lying along
    /// the line has no discrete intersections and reports none.
    public func intersections(
        with line: Line, rootTolerance: Double = 1e-9, pointTolerance: Double = 1e-6
    ) -> [Intersection] {
        let direction = line.direction
        let lengthSquared = direction.lengthSquared
        guard lengthSquared > 0 else {
            return []
        }
        let normal = direction.perpendicular / lengthSquared.squareRoot()
        let d0 = (p0 - line.start).dot(normal)
        let d1 = (p1 - line.start).dot(normal)
        let d2 = (p2 - line.start).dot(normal)
        let d3 = (p3 - line.start).dot(normal)
        let roots = Polynomial.cubicRoots(
            -d0 + 3 * d1 - 3 * d2 + d3,
            3 * d0 - 6 * d1 + 3 * d2,
            -3 * d0 + 3 * d1,
            d0,
            touchTolerance: pointTolerance)
        let mergeDistance = rootTolerance.squareRoot()
        let lineSlop = pointTolerance / lengthSquared.squareRoot()
        var results: [Intersection] = []
        for root in roots {
            guard root >= -rootTolerance, root <= 1 + rootTolerance else {
                continue
            }
            let t = min(1, max(0, root))
            let point = evaluate(t)
            let along = (point - line.start).dot(direction) / lengthSquared
            guard along >= -lineSlop, along <= 1 + lineSlop else {
                continue
            }
            if results.contains(where: { abs($0.t - t) <= mergeDistance }) {
                continue
            }
            results.append(Intersection(t: t, u: min(1, max(0, along)), point: point))
        }
        results.sort { $0.t < $1.t }
        return results
    }

    /// Where the two curves meet, ordered by `t`.
    ///
    /// Both curves are subdivided while their control hulls (grown by `pointTolerance`) overlap,
    /// until each piece is straight to within `flatness`; the chord crossing of each such pair
    /// seeds Newton iteration on `B₁(t) − B₂(u) = 0`, which converges quadratically for a
    /// crossing and, with a gradient fallback, still lands on a tangency.  Results whose curves
    /// end up further apart than `pointTolerance` are dropped.  Two candidates are the same
    /// intersection when they are within `√pointTolerance` of each other in space and within
    /// 0.01 of each other on both parameters (the spread a tangency's solutions have in double
    /// precision); a self-crossing curve met at its crossing has parameters far apart and is
    /// reported twice, once per branch.  Coincident or overlapping curves have no discrete
    /// intersections; subdivision stops after `maxCandidates` pieces so they cannot hang the
    /// caller, and what is reported for them is a sample of the overlap.
    public func intersections(
        with other: CubicBezier,
        rootTolerance: Double = 1e-9,
        pointTolerance: Double = 1e-6,
        flatness: Double = 1e-4,
        maxCandidates: Int = 64
    ) -> [Intersection] {
        var candidates: [Intersection] = []
        Self.collectCandidates(
            self, 0, 1, other, 0, 1,
            depth: 0, tolerance: pointTolerance, flatness: flatness, limit: maxCandidates, into: &candidates)
        var results: [Intersection] = []
        let mergeDistance = pointTolerance.squareRoot()
        for candidate in candidates {
            guard let refined = refineIntersection(candidate, with: other, rootTolerance: rootTolerance, pointTolerance: pointTolerance) else {
                continue
            }
            let duplicate = results.contains { existing in
                abs(existing.t - refined.t) <= 0.01
                    && abs(existing.u - refined.u) <= 0.01
                    && existing.point.distance(to: refined.point) <= mergeDistance
            }
            if !duplicate {
                results.append(refined)
            }
        }
        results.sort { $0.t < $1.t }
        return results
    }

    /// Where the curve meets the quadratic (elevated to a cubic).
    public func intersections(
        with quadratic: QuadraticBezier, rootTolerance: Double = 1e-9, pointTolerance: Double = 1e-6
    ) -> [Intersection] {
        intersections(with: quadratic.elevated(), rootTolerance: rootTolerance, pointTolerance: pointTolerance)
    }

    static let maxSubdivisionDepth = 48

    private static func collectCandidates(
        _ c1: CubicBezier, _ t0: Double, _ t1: Double,
        _ c2: CubicBezier, _ u0: Double, _ u1: Double,
        depth: Int, tolerance: Double, flatness: Double, limit: Int,
        into out: inout [Intersection]
    ) {
        if out.count >= limit {
            return
        }
        guard c1.controlBounds.intersects(c2.controlBounds, tolerance: tolerance) else {
            return
        }
        let flat1 = c1.isLinear(tolerance: flatness)
        let flat2 = c2.isLinear(tolerance: flatness)
        if (flat1 && flat2) || depth >= maxSubdivisionDepth {
            var t = (t0 + t1) / 2
            var u = (u0 + u1) / 2
            let chord1 = Line(start: c1.p0, end: c1.p3)
            let chord2 = Line(start: c2.p0, end: c2.p3)
            if let hit = chord1.intersection(with: chord2, tolerance: 1e-12) {
                t = t0 + (t1 - t0) * hit.t
                u = u0 + (u1 - u0) * hit.u
            } else if depth < maxSubdivisionDepth {
                // Flat pieces whose chords neither cross nor come within reach of each other
                // cannot meet.  Without this, a long straight segment (whose control hull is its
                // whole bounding box, and which is never split) would take a candidate from every
                // flat piece of the other curve inside that box, and the candidate limit would
                // crowd out the real crossings.
                let gap = min(
                    chord1.distance(to: chord2.start), chord1.distance(to: chord2.end),
                    chord2.distance(to: chord1.start), chord2.distance(to: chord1.end))
                if gap > tolerance + 2 * flatness {
                    return
                }
            }
            out.append(Intersection(t: t, u: u, point: c1.evaluate(localParameter(t, t0, t1))))
            return
        }
        let tm = (t0 + t1) / 2
        let um = (u0 + u1) / 2
        if flat1 {
            let (a, b) = c2.split(at: 0.5)
            collectCandidates(c1, t0, t1, a, u0, um, depth: depth + 1, tolerance: tolerance, flatness: flatness, limit: limit, into: &out)
            collectCandidates(c1, t0, t1, b, um, u1, depth: depth + 1, tolerance: tolerance, flatness: flatness, limit: limit, into: &out)
        } else if flat2 {
            let (a, b) = c1.split(at: 0.5)
            collectCandidates(a, t0, tm, c2, u0, u1, depth: depth + 1, tolerance: tolerance, flatness: flatness, limit: limit, into: &out)
            collectCandidates(b, tm, t1, c2, u0, u1, depth: depth + 1, tolerance: tolerance, flatness: flatness, limit: limit, into: &out)
        } else {
            let (a, b) = c1.split(at: 0.5)
            let (c, d) = c2.split(at: 0.5)
            collectCandidates(a, t0, tm, c, u0, um, depth: depth + 1, tolerance: tolerance, flatness: flatness, limit: limit, into: &out)
            collectCandidates(a, t0, tm, d, um, u1, depth: depth + 1, tolerance: tolerance, flatness: flatness, limit: limit, into: &out)
            collectCandidates(b, tm, t1, c, u0, um, depth: depth + 1, tolerance: tolerance, flatness: flatness, limit: limit, into: &out)
            collectCandidates(b, tm, t1, d, um, u1, depth: depth + 1, tolerance: tolerance, flatness: flatness, limit: limit, into: &out)
        }
    }

    /// Maps a parameter on a piece back to the local `0...1` of that piece (for evaluating the
    /// piece itself rather than the whole curve).
    private static func localParameter(_ t: Double, _ t0: Double, _ t1: Double) -> Double {
        t1 > t0 ? (t - t0) / (t1 - t0) : 0
    }

    /// Newton iteration on `B₁(t) − B₂(u) = 0` from a candidate; a gradient step stands in when
    /// the Jacobian is singular (tangency).  Nil when the curves do not come within
    /// `pointTolerance` of each other at the converged parameters.
    private func refineIntersection(
        _ candidate: Intersection, with other: CubicBezier, rootTolerance: Double, pointTolerance: Double
    ) -> Intersection? {
        var t = min(1, max(0, candidate.t))
        var u = min(1, max(0, candidate.u))
        for _ in 0..<40 {
            let f = evaluate(t) - other.evaluate(u)
            if f.lengthSquared <= 1e-30 {
                break
            }
            let d1 = derivative(t)
            let d2 = other.derivative(u)
            let det = -d1.cross(d2)
            var dt: Double
            var du: Double
            if abs(det) > 1e-12 * d1.length * d2.length {
                // Solve [d1, -d2]·[dt, du] = -f by Cramer's rule.
                dt = (-f.dx * -d2.dy - -d2.dx * -f.dy) / det
                du = (d1.dx * -f.dy - -f.dx * d1.dy) / det
            } else {
                // Steepest descent on |f|²/2 with the Cauchy step length.
                let gt = d1.dot(f)
                let gu = -d2.dot(f)
                let jg = d1 * gt - d2 * gu
                let denominator = jg.lengthSquared
                if denominator <= 0 {
                    break
                }
                let alpha = (gt * gt + gu * gu) / denominator
                dt = -alpha * gt
                du = -alpha * gu
            }
            let nt = min(1, max(0, t + dt))
            let nu = min(1, max(0, u + du))
            let moved = abs(nt - t) + abs(nu - u)
            t = nt
            u = nu
            if moved <= rootTolerance {
                break
            }
        }
        let p1 = evaluate(t)
        let p2 = other.evaluate(u)
        guard p1.distance(to: p2) <= pointTolerance else {
            return nil
        }
        return Intersection(t: t, u: u, point: p1)
    }
}
