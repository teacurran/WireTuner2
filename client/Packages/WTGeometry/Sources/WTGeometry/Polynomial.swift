import Foundation

/// Up to three real roots, in a fixed-size value so that root finding in hot paths (tight
/// bounds, winding) never touches the heap.
public struct PolynomialRoots: Hashable, Sendable, RandomAccessCollection {
    public private(set) var count: Int = 0
    private var r0: Double = 0
    private var r1: Double = 0
    private var r2: Double = 0

    public init() {}

    public static let none = PolynomialRoots()

    @inlinable
    public var startIndex: Int { 0 }

    @inlinable
    public var endIndex: Int { count }

    public subscript(position: Int) -> Double {
        precondition(position >= 0 && position < count, "root index out of range")
        switch position {
        case 0: return r0
        case 1: return r1
        default: return r2
        }
    }

    public mutating func append(_ root: Double) {
        precondition(count < 3, "a PolynomialRoots holds at most three roots")
        switch count {
        case 0: r0 = root
        case 1: r1 = root
        default: r2 = root
        }
        count += 1
    }

    /// The same roots in ascending order.
    public func sorted() -> PolynomialRoots {
        var result = self
        if result.count >= 2 && result.r1 < result.r0 {
            swap(&result.r0, &result.r1)
        }
        if result.count == 3 {
            if result.r2 < result.r1 {
                swap(&result.r1, &result.r2)
            }
            if result.r1 < result.r0 {
                swap(&result.r0, &result.r1)
            }
        }
        return result
    }
}

/// Closed-form real roots of quadratics and cubics, polished by Newton's method.
public enum Polynomial {
    /// A leading coefficient at or below this fraction of the largest coefficient is treated
    /// as zero, dropping the degree.
    static let degenerateRatio = 1e-14

    /// A discriminant within this fraction of its own scale is treated as exactly zero, which
    /// turns a pair of roots that rounding pulled apart (or made complex) back into the double
    /// root it is.
    static let discriminantSlop = 1e-12

    /// Value of `a·t³ + b·t² + c·t + d`.
    @inlinable
    public static func evaluateCubic(_ a: Double, _ b: Double, _ c: Double, _ d: Double, at t: Double) -> Double {
        ((a * t + b) * t + c) * t + d
    }

    /// Real roots of `a·t² + b·t + c`, ascending.  A double root is reported once.  The zero
    /// polynomial has no roots.
    public static func quadraticRoots(_ a: Double, _ b: Double, _ c: Double) -> PolynomialRoots {
        var roots = PolynomialRoots()
        let scale = max(abs(a), abs(b), abs(c))
        guard scale > 0, scale.isFinite else {
            return roots
        }
        if abs(a) <= degenerateRatio * scale {
            if abs(b) > degenerateRatio * scale {
                roots.append(-c / b)
            }
            return roots
        }
        let disc = b * b - 4 * a * c
        if disc <= 0 {
            if disc >= -discriminantSlop * max(b * b, abs(4 * a * c)) {
                roots.append(-b / (2 * a))
            }
            return roots
        }
        // Citardauq form: the root with the larger magnitude is computed by the stable formula
        // and the other from the product of roots, so neither suffers cancellation.
        let sq = disc.squareRoot()
        let q = -0.5 * (b + (b < 0 ? -sq : sq))
        let x0 = q / a
        let x1 = c / q
        if x0 <= x1 {
            roots.append(x0)
            roots.append(x1)
        } else {
            roots.append(x1)
            roots.append(x0)
        }
        return roots
    }

    /// Real roots of `a·t³ + b·t² + c·t + d`, ascending.
    ///
    /// A double root is reported once when the discriminant is (numerically) zero; when rounding
    /// has split it into two nearby real roots both are reported, and callers that care merge
    /// roots closer than `√tolerance` (the spread a perturbation of `tolerance` gives a double
    /// root).  When rounding has made the pair complex the polynomial has an extremum near zero
    /// instead; if `touchTolerance` is positive, an extremum whose value is within it counts as a
    /// root, so a curve that grazes a line within `touchTolerance` reports the touch.
    public static func cubicRoots(
        _ a: Double, _ b: Double, _ c: Double, _ d: Double, touchTolerance: Double = 0
    ) -> PolynomialRoots {
        let scale = max(abs(a), abs(b), abs(c), abs(d))
        guard scale > 0, scale.isFinite else {
            return .none
        }
        if abs(a) <= degenerateRatio * scale {
            return quadraticRoots(b, c, d)
        }
        let p = b / a
        let q = c / a
        let r = d / a
        let shift = p / 3
        // Depressed cubic x³ + aa·x + bb with t = x - shift.
        let aa = q - p * p / 3
        let bb = 2 * p * p * p / 27 - p * q / 3 + r
        let halfB = bb / 2
        let thirdA = aa / 3
        let disc = halfB * halfB + thirdA * thirdA * thirdA
        let discScale = max(halfB * halfB, abs(thirdA * thirdA * thirdA))
        var roots = PolynomialRoots()
        if discScale == 0 {
            roots.append(-shift)  // triple root
        } else if abs(disc) <= discriminantSlop * discScale {
            // Double root m and simple root s = -2m.
            let m = -3 * bb / (2 * aa)
            let s = 3 * bb / aa
            roots.append(min(m, s) - shift)
            roots.append(max(m, s) - shift)
        } else if disc < 0 {
            let magnitude = 2 * (-thirdA).squareRoot()
            let argument = min(1, max(-1, 3 * bb / (aa * magnitude)))
            let theta = acos(argument) / 3
            let third = 2 * Double.pi / 3
            roots.append(magnitude * cos(theta) - shift)
            roots.append(magnitude * cos(theta - third) - shift)
            roots.append(magnitude * cos(theta - 2 * third) - shift)
            roots = roots.sorted()
        } else {
            let sq = disc.squareRoot()
            roots.append(cbrt(-halfB + sq) + cbrt(-halfB - sq) - shift)
            if touchTolerance > 0 && aa < 0 {
                // The extrema of the depressed cubic sit at ±√(-aa/3); one of them grazes zero
                // when the curve touches within tolerance.
                let e = (-thirdA).squareRoot()
                let high = e - shift
                let low = -e - shift
                if abs(evaluateCubic(a, b, c, d, at: low)) <= touchTolerance {
                    roots.append(low)
                }
                if abs(evaluateCubic(a, b, c, d, at: high)) <= touchTolerance {
                    roots.append(high)
                }
                roots = roots.sorted()
            }
        }
        var polished = PolynomialRoots()
        for root in roots {
            polished.append(polish(a, b, c, d, root))
        }
        return polished
    }

    /// A few Newton steps on the original polynomial; each is kept only if it reduces |f|.
    static func polish(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ start: Double) -> Double {
        var t = start
        var f = evaluateCubic(a, b, c, d, at: t)
        for _ in 0..<3 {
            let df = (3 * a * t + 2 * b) * t + c
            if df == 0 || f == 0 {
                break
            }
            let next = t - f / df
            let fNext = evaluateCubic(a, b, c, d, at: next)
            if abs(fNext) >= abs(f) {
                break
            }
            t = next
            f = fNext
        }
        return t
    }
}
