// Ragged and Sketch (FX-005), seeded per D-022.  Randomness comes from a SplitMix64 stream seeded
// with the effect's stored seed, so every replica, every print and every export draws the same
// outline.  The kernels use only integer arithmetic for the stream and +, −, ×, ÷ and square roots
// on doubles (no transcendental functions, no Float80), which IEEE 754 makes identical on Intel
// and Apple silicon; Swift does not contract a × b + c into a fused multiply-add.

import WTGeometry

/// SplitMix64 (Steele, Lea and Flood): the documented seed contract for Ragged and Sketch
/// (live-effects.adoc, "Kernels").  The Java engine never renders, but the stream is the same
/// on every platform.
struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// The stream for copy `index` of an effect seeded `seed`.
    init(seed: UInt64, copy index: Int) {
        state = seed &+ UInt64(truncatingIfNeeded: index) &* 0xD1B5_4A32_D192_ED03
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A double in −1 ..< 1 from the top 53 bits: exact in binary.
    mutating func nextSigned() -> Double {
        Double(next() >> 11) * 0x1p-52 - 1
    }

    /// A double in 0 ..< 1.
    mutating func nextUnit() -> Double {
        Double(next() >> 11) * 0x1p-53
    }
}

enum RaggedKernel {
    static func apply(_ settings: LiveEffect.Ragged, to shapes: [EffectShape]) -> [EffectShape] {
        let frequency = settings.effectiveFrequency
        let size = settings.effectiveSize
        guard frequency > 0, size > 0 else {
            return shapes
        }
        let spacing = 72 / frequency
        var result: [EffectShape] = []
        for copy in 0...settings.effectiveCopies {
            var random = SplitMix64(seed: settings.effectiveSeed, copy: copy)
            for shape in shapes {
                let contours = shape.contours.map { roughen($0, spacing: spacing, size: size, settings: settings, random: &random) }
                result.append(EffectShape(contours: contours, rule: shape.rule))
            }
        }
        return result
    }

    private static func roughen(_ contour: Contour, spacing: Double, size: Double, settings: LiveEffect.Ragged, random: inout SplitMix64) -> Contour {
        var segments: [CubicBezier] = []
        var sign = 1.0
        for segment in contour.explicitSegments {
            let length = segment.length()
            let added = Int((length / spacing).rounded(.down))
            guard added > 0, length > 0 else {
                segments.append(segment)
                continue
            }
            var points = [segment.p0]
            for index in 1...added {
                let t = segment.parameter(atLength: length * Double(index) / Double(added + 1))
                let amount: Double
                if settings.uniform {
                    amount = size * sign
                    sign = -sign
                } else {
                    amount = size * random.nextSigned()
                }
                points.append(segment.evaluate(t) + segment.normal(t) * amount)
            }
            points.append(segment.p3)
            if settings.smooth {
                segments += smoothSegments(points, startTangent: segment.tangent(0), endTangent: segment.tangent(1))
            } else {
                for index in 1..<points.count {
                    segments.append(Line(start: points[index - 1], end: points[index]).elevated())
                }
            }
        }
        return Contour(segments: segments, closed: contour.isClosed)
    }

    /// A Catmull-Rom spline through `points` whose end tangents follow the original segment's.
    static func smoothSegments(_ points: [Point], startTangent: Vector, endTangent: Vector) -> [CubicBezier] {
        let last = points.count - 1
        var tangents: [Vector] = []
        for index in 0...last {
            if index == 0 {
                tangents.append(startTangent * (points[1] - points[0]).length)
            } else if index == last {
                tangents.append(endTangent * (points[last] - points[last - 1]).length)
            } else {
                tangents.append((points[index + 1] - points[index - 1]) * 0.5)
            }
        }
        return (0..<last).map { index in
            CubicBezier(
                p0: points[index],
                p1: points[index] + tangents[index] / 3,
                p2: points[index + 1] - tangents[index + 1] / 3,
                p3: points[index + 1]
            )
        }
    }
}

enum SketchKernel {
    static func apply(_ settings: LiveEffect.Sketch, to shapes: [EffectShape]) -> [EffectShape] {
        let amount = settings.effectiveAmount
        let copies = settings.effectiveCopies
        if amount == 0 && copies == 1 && !settings.closed {
            return shapes
        }
        var result: [EffectShape] = []
        for copy in 0..<copies {
            var random = SplitMix64(seed: settings.effectiveSeed, copy: copy)
            for shape in shapes {
                let contours = shape.contours.compactMap { sketch($0, amount: amount, closed: settings.closed, random: &random) }
                result.append(EffectShape(contours: contours, rule: shape.rule))
            }
        }
        return result
    }

    /// One pencil pass: the whole contour shifted, every anchor jittered (its handles with it)
    /// and, unless closed, the ends trimmed short by up to `amount`.
    private static func sketch(_ contour: Contour, amount: Double, closed: Bool, random: inout SplitMix64) -> Contour? {
        let segments = contour.explicitSegments
        guard !segments.isEmpty else {
            return nil
        }
        let half = amount / 2
        let shift = Vector(random.nextSigned() * half, random.nextSigned() * half)
        // One jitter per anchor; a closed contour's last anchor is its first.
        let anchorCount = contour.isClosed ? segments.count : segments.count + 1
        let jitters = (0..<anchorCount).map { _ in Vector(random.nextSigned() * half, random.nextSigned() * half) + shift }
        let moved = segments.enumerated().map { index, segment -> CubicBezier in
            let start = jitters[index]
            let end = jitters[(index + 1) % anchorCount]
            return CubicBezier(p0: segment.p0 + start, p1: segment.p1 + start, p2: segment.p2 + end, p3: segment.p3 + end)
        }
        if closed {
            return Contour(segments: moved, closed: true)
        }
        let startTrim = random.nextUnit() * amount
        let endTrim = random.nextUnit() * amount
        guard startTrim > 0 || endTrim > 0 else {
            return Contour(segments: moved, closed: contour.isClosed)
        }
        let open = Contour(segments: moved, closed: false)
        let trimmed = StrokeGeometry.trimmingEnd(of: StrokeGeometry.trimmingStart(of: open, by: startTrim), by: endTrim)
        return trimmed.isEmpty ? nil : trimmed
    }
}
