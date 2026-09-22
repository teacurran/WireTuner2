extension CubicBezier {
    /// 5-point Gauss–Legendre nodes and weights on `-1...1`.
    @usableFromInline
    static let gaussNodes: (Double, Double, Double) = (0, 0.538_469_310_105_683_1, 0.906_179_845_938_664_0)
    @usableFromInline
    static let gaussWeights: (Double, Double, Double) = (0.568_888_888_888_888_9, 0.478_628_670_499_366_5, 0.236_926_885_056_189_1)

    /// Speed |B′(t)|.
    @inlinable
    public func speed(_ t: Double) -> Double {
        derivative(t).length
    }

    /// Arc length of the whole curve, to within `tolerance`.
    public func length(tolerance: Double = 1e-6) -> Double {
        length(from: 0, to: 1, tolerance: tolerance)
    }

    /// Arc length between two parameters, to within `tolerance`, by adaptive Gauss–Legendre
    /// quadrature of the speed.  The result is signed: negative when `t1 < t0`.
    public func length(from t0: Double, to t1: Double, tolerance: Double = 1e-6) -> Double {
        if t0 == t1 {
            return 0
        }
        if t1 < t0 {
            return -length(from: t1, to: t0, tolerance: tolerance)
        }
        let whole = gaussLength(from: t0, to: t1)
        return adaptiveLength(from: t0, to: t1, whole: whole, tolerance: max(tolerance, 1e-15), depth: 0)
    }

    /// The parameter at which the arc length from the start equals `length`, clamped to
    /// `0...1`.  Newton iteration on the length integral with a bisection safeguard; the result
    /// is exact to within `tolerance` in length.
    public func parameter(atLength target: Double, tolerance: Double = 1e-6) -> Double {
        let total = length(tolerance: tolerance)
        if target <= 0 || total <= 0 {
            return 0
        }
        if target >= total {
            return 1
        }
        var low = 0.0
        var high = 1.0
        var t = target / total
        for _ in 0..<64 {
            let error = length(from: 0, to: t, tolerance: tolerance) - target
            if abs(error) <= tolerance {
                return t
            }
            if error > 0 {
                high = t
            } else {
                low = t
            }
            let v = speed(t)
            var next = v > 0 ? t - error / v : (low + high) / 2
            if !(next > low && next < high) {
                next = (low + high) / 2
            }
            if abs(next - t) <= 1e-15 {
                return next
            }
            t = next
        }
        return t
    }

    /// The point `length` along the curve from its start.
    public func point(atLength length: Double, tolerance: Double = 1e-6) -> Point {
        evaluate(parameter(atLength: length, tolerance: tolerance))
    }

    /// One Gauss–Legendre estimate of the arc length over `a...b`.
    @usableFromInline
    func gaussLength(from a: Double, to b: Double) -> Double {
        let half = (b - a) / 2
        let mid = (a + b) / 2
        let (n0, n1, n2) = Self.gaussNodes
        let (w0, w1, w2) = Self.gaussWeights
        var sum = w0 * speed(mid + half * n0)
        sum += w1 * (speed(mid - half * n1) + speed(mid + half * n1))
        sum += w2 * (speed(mid - half * n2) + speed(mid + half * n2))
        return sum * half
    }

    private func adaptiveLength(from a: Double, to b: Double, whole: Double, tolerance: Double, depth: Int) -> Double {
        let mid = (a + b) / 2
        let left = gaussLength(from: a, to: mid)
        let right = gaussLength(from: mid, to: b)
        let halves = left + right
        if abs(halves - whole) <= tolerance || depth >= 30 {
            return halves
        }
        return adaptiveLength(from: a, to: mid, whole: left, tolerance: tolerance / 2, depth: depth + 1)
            + adaptiveLength(from: mid, to: b, whole: right, tolerance: tolerance / 2, depth: depth + 1)
    }
}
