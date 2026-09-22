extension CubicBezier {
    /// The point of the curve closest to `point`.
    ///
    /// The distance is sampled at `samples + 1` parameters including both ends; every sampled
    /// local minimum (an end point counts when its neighbor is no closer) is refined by solving
    /// the stationarity condition `(B(t) − P) · B′(t) = 0` with Newton's method inside the
    /// bracket around the sample, falling back to bisection when a step leaves it, and the best
    /// refined minimum wins.  The squared distance to a cubic has at most three local minima, so
    /// no basin is missed once the samples resolve them.  On a curve with two equidistant
    /// closest points one of them is returned; which one is deterministic but unspecified.
    public func nearestPoint(
        to point: Point, samples: Int = 32, iterations: Int = 32, tolerance: Double = 1e-9
    ) -> NearestPoint {
        let n = max(2, samples)
        let step = 1 / Double(n)
        var best = NearestPoint(t: 0, point: p0, distance: p0.distance(to: point))
        var previous = Double.infinity
        var current = best.distance * best.distance
        for i in 0...n {
            let next = i < n ? evaluate(Double(i + 1) * step).distanceSquared(to: point) : Double.infinity
            if current <= previous && current <= next {
                let t = Double(i) * step
                let sample = NearestPoint(t: t, point: evaluate(t), distance: current.squareRoot())
                let refined = refineNearest(to: point, around: t, step: step, iterations: iterations, tolerance: tolerance)
                let candidate = refined.distance < sample.distance ? refined : sample
                if candidate.distance < best.distance {
                    best = candidate
                }
            }
            previous = current
            current = next
        }
        return best
    }

    /// Distance from `point` to the curve.
    public func distance(to point: Point) -> Double {
        nearestPoint(to: point).distance
    }

    private func refineNearest(
        to point: Point, around start: Double, step: Double, iterations: Int, tolerance: Double
    ) -> NearestPoint {
        var low = max(0, start - step)
        var high = min(1, start + step)
        var t = start
        for _ in 0..<iterations {
            let offset = evaluate(t) - point
            let d1 = derivative(t)
            let g = offset.dot(d1)
            if abs(g) <= tolerance {
                break
            }
            // g is the derivative of half the squared distance, increasing through a minimum.
            if g > 0 {
                high = t
            } else {
                low = t
            }
            let dg = d1.lengthSquared + offset.dot(secondDerivative(t))
            var next = dg > 0 ? t - g / dg : (low + high) / 2
            if !(next > low && next < high) {
                next = (low + high) / 2
            }
            if abs(next - t) <= tolerance {
                t = next
                break
            }
            t = next
        }
        let p = evaluate(t)
        return NearestPoint(t: t, point: p, distance: p.distance(to: point))
    }
}
