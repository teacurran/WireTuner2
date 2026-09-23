import Foundation

// GEO-004: polyline simplification and smoothing, the precision-to-tolerance mapping of the
// Pencil group (`freeform`), and cubic-path simplification (`editing-paths`, "Simplifying").

/// Operations on a sequence of sample points.
public enum Polyline {
    /// The points with consecutive samples closer than `tolerance` merged into the first of
    /// them; the last sample is always kept when it differs from the surviving one before it.
    public static func removingDuplicates(_ points: [Point], tolerance: Double = 1e-9) -> [Point] {
        var result: [Point] = []
        result.reserveCapacity(points.count)
        for point in points where point.isFinite {
            if let last = result.last, last.distance(to: point) <= tolerance {
                continue
            }
            result.append(point)
        }
        return result
    }

    /// Douglas–Peucker: the subset of `points` such that every dropped point lies within
    /// `tolerance` of the segment between its surviving neighbours.  The first and last points
    /// always survive.  Iterative, so a long polyline cannot overflow the stack.
    public static func simplify(_ points: [Point], tolerance: Double) -> [Point] {
        guard points.count > 2, tolerance >= 0 else {
            return points
        }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last - first > 1 else {
                continue
            }
            let chord = Line(start: points[first], end: points[last])
            var worst = -1.0
            var index = first
            for i in (first + 1)..<last {
                let distance: Double
                if chord.length > 0 {
                    distance = chord.distance(to: points[i])
                } else {
                    distance = points[i].distance(to: chord.start)
                }
                if distance > worst {
                    worst = distance
                    index = i
                }
            }
            if worst > tolerance {
                keep[index] = true
                stack.append((first, index))
                stack.append((index, last))
            }
        }
        var result: [Point] = []
        for (i, point) in points.enumerated() where keep[i] {
            result.append(point)
        }
        return result
    }

    /// The points smoothed with a Gaussian of standard deviation `sigma` samples (kernel radius
    /// `3·sigma`, truncated at the ends and renormalized).  The first and last points stay
    /// where they are so the stroke still starts and ends under the pointer.  A non-positive
    /// sigma returns the input.
    public static func smoothed(_ points: [Point], sigma: Double) -> [Point] {
        guard sigma > 0, sigma.isFinite, points.count > 2 else {
            return points
        }
        let radius = max(1, Int((3 * sigma).rounded(.up)))
        var weights = [Double](repeating: 0, count: radius + 1)
        for k in 0...radius {
            weights[k] = exp(-Double(k * k) / (2 * sigma * sigma))
        }
        var result = points
        for i in 1..<(points.count - 1) {
            var sumX = 0.0
            var sumY = 0.0
            var sumW = 0.0
            let low = max(0, i - radius)
            let high = min(points.count - 1, i + radius)
            for j in low...high {
                let w = weights[abs(j - i)]
                sumX += points[j].x * w
                sumY += points[j].y * w
                sumW += w
            }
            result[i] = Point(x: sumX / sumW, y: sumY / sumW)
        }
        return result
    }

    /// Total length of the polyline.
    public static func length(_ points: [Point]) -> Double {
        var total = 0.0
        for i in 1..<max(1, points.count) {
            total += points[i].distance(to: points[i - 1])
        }
        return total
    }
}

/// The *Precision* setting of the Pencil, Variable Stroke Pen and Calligraphic Pen (1…10,
/// `freeform`): "high values follow every wobble of your hand and place many points; low
/// values smooth the stroke and place few."
///
/// The mapping, so `freeform.adoc`'s behaviour is reproducible:
///
/// * fit tolerance: `12 / precision` points at 100% zoom, divided by the zoom factor so the
///   tolerance is `12 / precision` *screen* pixels at any magnification (precision 1 → 12 pt,
///   precision 10 → 1.2 pt);
/// * smoothing before the fit: a Gaussian over the samples with `sigma = (10 - precision) / 3`
///   samples (precision 10 → none, precision 1 → 3 samples);
/// * corners: detected on the raw samples, before smoothing, so smoothing cannot round them
///   away: a turn of 60° or more between the chords two samples either side is a corner at
///   every precision.  Each run between corners is smoothed and fitted on its own, with the
///   corner samples held in place.
public struct PrecisionSetting: Hashable, Sendable, Comparable {
    public static let range = 1...10

    /// The setting, clamped to ``range``.
    public var value: Int

    public init(_ value: Int) {
        self.value = min(Self.range.upperBound, max(Self.range.lowerBound, value))
    }

    /// The tolerance at 100% zoom for precision 1.
    public static let baseTolerance = 12.0

    /// The corner angle used at every precision.
    public static let cornerAngle = Double.pi / 3

    /// The corner window (samples each side) used at every precision.
    public static let cornerWindow = 2

    /// Fit tolerance in pasteboard points at `zoom` view pixels per point.
    public func tolerance(zoom: Double = 1) -> Double {
        let z = zoom > 0 && zoom.isFinite ? zoom : 1
        return Self.baseTolerance / Double(value) / z
    }

    /// Gaussian smoothing width in samples.
    public var smoothingSigma: Double {
        Double(Self.range.upperBound - value) / 3
    }

    /// The fitter for this precision.
    public func fitter(zoom: Double = 1) -> CurveFitter {
        CurveFitter(maxError: tolerance(zoom: zoom), cornerAngle: Self.cornerAngle, cornerWindow: Self.cornerWindow)
    }

    /// The whole Pencil pipeline: duplicates removed, samples smoothed, curve fitted.  Fewer
    /// than two distinct samples give an empty contour.
    public func fit(stroke samples: [Point], zoom: Double = 1) -> Contour {
        let distinct = Polyline.removingDuplicates(samples)
        let corners = CurveFitter.corners(in: distinct, angle: Self.cornerAngle, window: Self.cornerWindow)
        return fitter(zoom: zoom).fitContour(Self.smoothedRuns(distinct, corners: corners, sigma: smoothingSigma).points,
            corners: corners)
    }

    /// The samples smoothed run by run between `corners`, which stay where they are.
    static func smoothedRuns(_ points: [Point], corners: [Int], sigma: Double) -> (points: [Point], corners: [Int]) {
        var result = points
        var start = 0
        for end in corners + [points.count - 1] where end > start {
            let run = Polyline.smoothed(Array(points[start...end]), sigma: sigma)
            result.replaceSubrange(start...end, with: run)
            start = end
        }
        return (result, corners)
    }

    public static func < (lhs: PrecisionSetting, rhs: PrecisionSetting) -> Bool {
        lhs.value < rhs.value
    }
}

extension Contour {
    /// The contour refitted with fewer segments where that stays within `tolerance` of the
    /// original (menu:Modify[Alter Path > Simplify]).
    ///
    /// Junctions where the tangent turns by `cornerAngle` or more are kept as corners; between
    /// corners the segments are sampled `samplesPerSegment` times each and refitted with
    /// ``CurveFitter``, so runs of segments merge wherever one cubic serves.  A run whose refit
    /// would not save a segment is kept as it was, so the count never grows.  A tolerance of
    /// zero (Simplify at amount 0) returns the contour unchanged.
    public func simplified(tolerance: Double, cornerAngle: Double = .pi / 3, samplesPerSegment: Int = 16) -> Contour {
        guard tolerance > 0, !segments.isEmpty else {
            return self
        }
        var all = segments
        if isClosed, let closing = closingSegment, closing.chordLength > tolerance * 1e-6 {
            all.append(closing)
        }
        let n = all.count
        // Corner flags at the junction *before* each segment.
        var isCorner = [Bool](repeating: false, count: n)
        for i in 0..<n {
            if i == 0 && !isClosed {
                isCorner[i] = true  // an open contour starts at its start
                continue
            }
            let previous = i == 0 ? n - 1 : i - 1
            let turn = CurveFitter.turningAngle(all[previous].tangent(1), all[i].tangent(0))
            isCorner[i] = turn >= cornerAngle
        }
        // Start the walk at a corner so a closed contour's runs do not straddle the seam.
        let start = isCorner.firstIndex(of: true) ?? 0
        if !isCorner.contains(true) {
            isCorner[0] = true
        }
        var result: [CubicBezier] = []
        var run: [CubicBezier] = []
        let samples = max(2, samplesPerSegment)
        func flush() {
            guard !run.isEmpty else {
                return
            }
            var points: [Point] = []
            points.reserveCapacity(run.count * samples + 1)
            for segment in run {
                for j in 0..<samples {
                    points.append(segment.evaluate(Double(j) / Double(samples)))
                }
            }
            points.append(run[run.count - 1].p3)
            let fitter = CurveFitter(maxError: tolerance, cornerAngle: .pi)
            let fitted = fitter.fit(points)
            if !fitted.isEmpty && fitted.count < run.count {
                result.append(contentsOf: fitted)
            } else {
                result.append(contentsOf: run)
            }
            run.removeAll(keepingCapacity: true)
        }
        for k in 0..<n {
            let i = (start + k) % n
            if isCorner[i] {
                flush()
            }
            run.append(all[i])
        }
        flush()
        return Contour(segments: result, closed: isClosed)
    }
}
