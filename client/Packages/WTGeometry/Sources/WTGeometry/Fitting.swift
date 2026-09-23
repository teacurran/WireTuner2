import Foundation

// GEO-004: Schneider's curve fitting (Philip J. Schneider, "An Algorithm for Automatically
// Fitting Digitized Curves", Graphics Gems 1990) with corner detection, used by the Pencil
// group (`freeform`), the Freeform tool's refit and Simplify (`editing-paths`).

/// Fits a polyline with as few cubic segments as stay within `maxError` of every sample.
///
/// The polyline is first cut at corners: a sample where the direction turns by more than
/// `cornerAngle` (measured between the chords `cornerWindow` samples before and after it)
/// starts a new run, and the fitted curve has a corner point there.  Each run is fitted by
/// Schneider's algorithm: chord-length parametrization, a least-squares solve for the two
/// handle lengths given the end tangents, Newton–Raphson reparametrization when the fit is
/// close, and a split at the worst sample with a shared center tangent when it is not.  A run
/// of two samples is a straight segment.
///
/// Degenerate input is handled without surprises: consecutive duplicate samples are merged,
/// fewer than two distinct samples fit to nothing, and the recursion is capped at
/// `maxDepth` splits, past which a run becomes straight segments.
public struct CurveFitter: Hashable, Sendable {
    /// Maximum distance of any sample from the fitted curve.
    public var maxError: Double
    /// Turning angle (radians) at or above which a sample is a corner.  `.pi` or more disables
    /// corner detection.
    public var cornerAngle: Double
    /// How many samples each side of a sample the corner test looks, so noise between
    /// neighbouring samples does not read as a corner.
    public var cornerWindow: Int
    /// Newton–Raphson reparametrization passes per attempt (Schneider used 4).
    public var maxIterations: Int
    /// Recursion cap on splitting.
    public var maxDepth: Int

    public init(
        maxError: Double, cornerAngle: Double = .pi / 3, cornerWindow: Int = 1, maxIterations: Int = 4, maxDepth: Int = 32
    ) {
        self.maxError = maxError
        self.cornerAngle = cornerAngle
        self.cornerWindow = cornerWindow
        self.maxIterations = maxIterations
        self.maxDepth = maxDepth
    }

    /// The fitted segments, end to end.
    public func fit(_ points: [Point]) -> [CubicBezier] {
        let samples = Polyline.removingDuplicates(points)
        guard samples.count >= 2 else {
            return []
        }
        let corners = Self.corners(in: samples, angle: cornerAngle, window: cornerWindow)
        return fit(samples, corners: corners)
    }

    /// Fits each run between the given corner indices (ascending, interior) on its own, so the
    /// curve has a corner point at each.  `points` is used as given (no duplicate removal).
    public func fit(_ points: [Point], corners: [Int]) -> [CubicBezier] {
        guard points.count >= 2 else {
            return []
        }
        var result: [CubicBezier] = []
        var runStart = 0
        for corner in corners.filter({ $0 > 0 && $0 < points.count - 1 }) + [points.count - 1] where corner > runStart {
            fitRun(points, from: runStart, to: corner, into: &result)
            runStart = corner
        }
        return result
    }

    /// The fitted segments as an open (or closed) contour.
    public func fitContour(_ points: [Point], closed: Bool = false) -> Contour {
        Contour(segments: fit(points), closed: closed)
    }

    /// The segments fitted between the given corners, as a contour.
    public func fitContour(_ points: [Point], corners: [Int], closed: Bool = false) -> Contour {
        Contour(segments: fit(points, corners: corners), closed: closed)
    }

    /// Indices of the corner samples (never the first or the last sample), ascending.  Runs of
    /// adjacent corners collapse to the sharpest one.
    public static func corners(in points: [Point], angle: Double, window: Int = 1) -> [Int] {
        guard points.count >= 3, angle < .pi else {
            return []
        }
        let w = max(1, window)
        func turning(_ i: Int) -> Double {
            let before = points[i] - points[max(0, i - w)]
            let after = points[min(points.count - 1, i + w)] - points[i]
            return turningAngle(before, after)
        }
        var result: [Int] = []
        var i = 1
        while i < points.count - 1 {
            let turn = turning(i)
            guard turn >= angle else {
                i += 1
                continue
            }
            var best = i
            var bestTurn = turn
            var j = i + 1
            while j < points.count - 1 {
                let next = turning(j)
                if next < angle {
                    break
                }
                if next > bestTurn {
                    best = j
                    bestTurn = next
                }
                j += 1
            }
            result.append(best)
            i = j
        }
        return result
    }

    /// The unsigned angle between two directions, in `0...pi`; 0 when either is zero.
    static func turningAngle(_ a: Vector, _ b: Vector) -> Double {
        let la = a.length
        let lb = b.length
        guard la > 0, lb > 0 else {
            return 0
        }
        let cosine = min(1, max(-1, a.dot(b) / (la * lb)))
        return acos(cosine)
    }

    // MARK: Schneider

    private func fitRun(_ d: [Point], from first: Int, to last: Int, into out: inout [CubicBezier]) {
        let tHat1 = Self.leftTangent(d, first, last, lookahead: 2 * maxError)
        let tHat2 = Self.rightTangent(d, first, last, lookahead: 2 * maxError)
        fitCubic(d, first, last, tHat1, tHat2, depth: 0, into: &out)
    }

    private func fitCubic(
        _ d: [Point], _ first: Int, _ last: Int, _ tHat1: Vector, _ tHat2: Vector, depth: Int, into out: inout [CubicBezier]
    ) {
        let count = last - first + 1
        if count == 2 {
            let dist = d[last].distance(to: d[first]) / 3
            out.append(CubicBezier(p0: d[first], p1: d[first] + tHat1 * dist, p2: d[last] + tHat2 * dist, p3: d[last]))
            return
        }
        if depth >= maxDepth {
            // Give up on curves: straight segments never exceed the error.
            for i in first..<last {
                out.append(Line(start: d[i], end: d[i + 1]).elevated())
            }
            return
        }
        var u = Self.chordLengthParameterize(d, first, last)
        var bezier = Self.generateBezier(d, first, last, u, tHat1, tHat2)
        var (error, splitPoint) = Self.maxError(d, first, last, bezier, u)
        if error <= maxError {
            out.append(bezier)
            return
        }
        // Close enough to be worth polishing the parametrization instead of splitting.
        if error <= 4 * maxError {
            for _ in 0..<maxIterations {
                u = Self.reparameterize(d, first, last, u, bezier)
                bezier = Self.generateBezier(d, first, last, u, tHat1, tHat2)
                (error, splitPoint) = Self.maxError(d, first, last, bezier, u)
                if error <= maxError {
                    out.append(bezier)
                    return
                }
            }
        }
        let tHatCenter = Self.centerTangent(d, splitPoint, first: first, last: last, lookahead: 2 * maxError)
        fitCubic(d, first, splitPoint, tHat1, tHatCenter, depth: depth + 1, into: &out)
        fitCubic(d, splitPoint, last, -tHatCenter, tHat2, depth: depth + 1, into: &out)
    }

    /// Least-squares handle lengths along the given end tangents (Schneider's `GenerateBezier`).
    static func generateBezier(
        _ d: [Point], _ first: Int, _ last: Int, _ u: [Double], _ tHat1: Vector, _ tHat2: Vector
    ) -> CubicBezier {
        let count = last - first + 1
        var c00 = 0.0
        var c01 = 0.0
        var c11 = 0.0
        var x0 = 0.0
        var x1 = 0.0
        for i in 0..<count {
            let t = u[i]
            let mt = 1 - t
            let b0 = mt * mt * mt
            let b1 = 3 * t * mt * mt
            let b2 = 3 * t * t * mt
            let b3 = t * t * t
            let a0 = tHat1 * b1
            let a1 = tHat2 * b2
            c00 += a0.dot(a0)
            c01 += a0.dot(a1)
            c11 += a1.dot(a1)
            let blend = Point(
                x: d[first].x * (b0 + b1) + d[last].x * (b2 + b3),
                y: d[first].y * (b0 + b1) + d[last].y * (b2 + b3))
            let tmp = d[first + i] - blend
            x0 += a0.dot(tmp)
            x1 += a1.dot(tmp)
        }
        let detC0C1 = c00 * c11 - c01 * c01
        let detC0X = c00 * x1 - c01 * x0
        let detXC1 = x0 * c11 - x1 * c01
        var alphaL = detC0C1 == 0 ? 0 : detXC1 / detC0C1
        var alphaR = detC0C1 == 0 ? 0 : detC0X / detC0C1
        let segLength = d[last].distance(to: d[first])
        let epsilon = 1e-6 * segLength
        if alphaL < epsilon || alphaR < epsilon || !alphaL.isFinite || !alphaR.isFinite {
            // Wu/Barsky heuristic: handles a third of the chord.
            alphaL = segLength / 3
            alphaR = segLength / 3
        }
        return CubicBezier(p0: d[first], p1: d[first] + tHat1 * alphaL, p2: d[last] + tHat2 * alphaR, p3: d[last])
    }

    static func chordLengthParameterize(_ d: [Point], _ first: Int, _ last: Int) -> [Double] {
        var u = [Double](repeating: 0, count: last - first + 1)
        for i in (first + 1)...last {
            u[i - first] = u[i - first - 1] + d[i].distance(to: d[i - 1])
        }
        let total = u[last - first]
        if total > 0 {
            for i in 1...(last - first) {
                u[i] /= total
            }
        } else {
            for i in 0...(last - first) {
                u[i] = Double(i) / Double(last - first)
            }
        }
        return u
    }

    /// One Newton–Raphson step per sample toward the parameter of its closest curve point.
    static func reparameterize(_ d: [Point], _ first: Int, _ last: Int, _ u: [Double], _ bezier: CubicBezier) -> [Double] {
        var result = u
        for i in 0..<u.count {
            let t = u[i]
            let q = bezier.evaluate(t)
            let q1 = bezier.derivative(t)
            let q2 = bezier.secondDerivative(t)
            let offset = q - d[first + i]
            let numerator = offset.dot(q1)
            let denominator = q1.dot(q1) + offset.dot(q2)
            if denominator != 0 {
                let next = t - numerator / denominator
                if next.isFinite {
                    result[i] = min(1, max(0, next))
                }
            }
        }
        return result
    }

    /// The largest sample distance and the index where it occurs (the split point).
    static func maxError(_ d: [Point], _ first: Int, _ last: Int, _ bezier: CubicBezier, _ u: [Double]) -> (Double, Int) {
        var worst = 0.0
        var splitPoint = (last - first + 1) / 2 + first
        for i in (first + 1)..<last {
            let dist = bezier.evaluate(u[i - first]).distanceSquared(to: d[i])
            if dist > worst {
                worst = dist
                splitPoint = i
            }
        }
        return (worst.squareRoot(), splitPoint)
    }

    /// The sample index `lookahead` along the samples from `from` in direction `step` (±1),
    /// stopping at `limit`: the first sample at least that far away, or the last one before
    /// the limit.  Looking a little ahead keeps pointer jitter out of the tangent estimate.
    static func reach(_ d: [Point], from: Int, step: Int, limit: Int, lookahead: Double) -> Int {
        var i = from + step
        while i != limit && d[i].distance(to: d[from]) < lookahead {
            i += step
        }
        return i
    }

    /// The unit tangent leaving `d[first]`, toward the samples within `lookahead` of it.
    static func leftTangent(_ d: [Point], _ first: Int, _ last: Int, lookahead: Double = 0) -> Vector {
        var i = reach(d, from: first, step: 1, limit: last, lookahead: lookahead)
        while i <= last {
            let v = d[i] - d[first]
            if v.lengthSquared > 0 {
                return v.normalized
            }
            i += 1
        }
        return Vector(dx: 1, dy: 0)
    }

    /// The unit tangent arriving at `d[last]`, pointing back into the run.
    static func rightTangent(_ d: [Point], _ first: Int, _ last: Int, lookahead: Double = 0) -> Vector {
        var i = reach(d, from: last, step: -1, limit: first, lookahead: lookahead)
        while i >= first {
            let v = d[i] - d[last]
            if v.lengthSquared > 0 {
                return v.normalized
            }
            i -= 1
        }
        return Vector(dx: -1, dy: 0)
    }

    /// The tangent at an interior split, pointing toward the *left* run (Schneider's
    /// convention: `V1 = d[c-k] - d[c]`, `V2 = d[c] - d[c+k]`, averaged), with `k` reaching
    /// `lookahead` along the samples on each side.
    static func centerTangent(_ d: [Point], _ center: Int, first: Int? = nil, last: Int? = nil, lookahead: Double = 0) -> Vector {
        let before = reach(d, from: center, step: -1, limit: first ?? 0, lookahead: lookahead)
        let after = reach(d, from: center, step: 1, limit: last ?? d.count - 1, lookahead: lookahead)
        let v1 = (d[before] - d[center]).normalized
        let v2 = (d[center] - d[after]).normalized
        let sum = (v1 + v2) / 2
        if sum.lengthSquared > 1e-24 {
            return sum.normalized
        }
        // A cusp: the two chords cancel.  Any perpendicular keeps the fit symmetric.
        if v1.lengthSquared > 0 {
            return v1.perpendicular.normalized
        }
        return Vector(dx: 1, dy: 0)
    }
}
