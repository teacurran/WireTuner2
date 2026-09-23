// Corners (FX-046; live-effects.adoc, "Kernels"): each eligible corner -- an anchor whose
// adjoining segments are not tangent-continuous, filtered by `points` -- is cut back by the tangent
// length `t = radius / tan(θ/2)` (θ the interior angle), measured by arc length along curved
// neighbours and capped at half of either neighbour, so adjacent corners never overlap.  Round
// replaces the corner by a circular arc tangent at both cut points (one cubic per ≤ 90° of sweep,
// the kappa of `rectPath`), Inverted round by the same arc mirrored across its chord (its centre
// on the far side), Chamfer by the chord.

import Foundation
import WTGeometry

enum CornersKernel {
    static func apply(_ settings: LiveEffect.Corners, to shapes: [EffectShape]) -> [EffectShape] {
        let radius = settings.radius.isFinite ? max(settings.radius, 0) : 0
        guard radius > 0 else {
            return shapes
        }
        let selected = Set(settings.points)
        return shapes.map { shape in
            let contours = shape.contours.enumerated().map { index, contour in
                round(contour, radius: radius, style: settings.style) { anchor in
                    selected.isEmpty || selected.contains(CornerPoint(contour: index, anchor: anchor))
                }
            }
            return EffectShape(contours: contours, rule: shape.rule)
        }
    }

    /// Whether the joint between `incoming` and `outgoing` is a corner, and its turning angle.
    static func turning(_ incoming: CubicBezier, _ outgoing: CubicBezier) -> Double? {
        guard !incoming.isDegenerate, !outgoing.isDegenerate else {
            return nil
        }
        let a = incoming.tangent(1)
        let b = outgoing.tangent(0)
        let angle = atan2(a.cross(b), a.dot(b))
        let magnitude = abs(angle)
        // Tangent-continuous (a curve point or collinear) or a full reversal: not a corner.
        guard magnitude > 1e-3, magnitude < .pi - 1e-3 else {
            return nil
        }
        return magnitude
    }

    static func round(_ contour: Contour, radius: Double, style: LiveEffect.Corners.Style, isSelected: (Int) -> Bool) -> Contour {
        let segments = contour.explicitSegments
        let count = segments.count
        guard count > 0 else {
            return contour
        }
        let lengths = segments.map { $0.length() }
        // Tangent length per anchor (anchor i joins segment i − 1 and segment i).
        var cut = [Double](repeating: 0, count: count + 1)
        let anchors = contour.isClosed ? Array(0..<count) : Array(1..<count)
        for anchor in anchors where isSelected(anchor) {
            let previous = (anchor - 1 + count) % count
            guard let phi = turning(segments[previous], segments[anchor % count]) else { continue }
            let tangent = radius * tan(phi / 2)
            cut[anchor] = min(tangent, lengths[previous] / 2, lengths[anchor % count] / 2)
        }
        if contour.isClosed {
            cut[count] = cut[0]
        }
        guard cut.contains(where: { $0 > 1e-9 }) else {
            return contour
        }
        var trimmed: [CubicBezier?] = []
        for index in 0..<count {
            let segment = segments[index]
            let startCut = cut[index]
            let endCut = cut[index + 1]
            if startCut <= 1e-9 && endCut <= 1e-9 {
                trimmed.append(segment)
                continue
            }
            let t0 = startCut > 1e-9 ? segment.parameter(atLength: startCut) : 0
            let t1 = endCut > 1e-9 ? segment.parameter(atLength: lengths[index] - endCut) : 1
            trimmed.append(t1 - t0 > 1e-9 ? segment.subdivide(from: t0, to: t1) : nil)
        }
        var result: [CubicBezier] = []
        var current: Point?
        func append(_ piece: CubicBezier) {
            if let from = current, from.distance(to: piece.p0) > 1e-9 {
                result.append(Line(start: from, end: piece.p0).elevated())
            }
            result.append(piece)
            current = piece.p3
        }
        func corner(at anchor: Int) {
            guard cut[anchor] > 1e-9 else { return }
            let previous = (anchor - 1 + count) % count
            let next = anchor % count
            let a = (trimmed[previous]?.p3) ?? segments[previous].evaluate(0.5)
            let b = (trimmed[next]?.p0) ?? segments[next].evaluate(0.5)
            let dA = segments[previous].tangent(segments[previous].parameter(atLength: lengths[previous] - cut[anchor]))
            for piece in cornerPieces(from: a, direction: dA, to: b, style: style) {
                append(piece)
            }
        }
        for index in 0..<count {
            if index > 0 {
                corner(at: index)
            }
            if let piece = trimmed[index] {
                append(piece)
            }
        }
        if contour.isClosed {
            corner(at: count)
        }
        return Contour(segments: result, closed: contour.isClosed)
    }

    /// The pieces replacing a corner from cut point `a` (where the incoming side runs in
    /// `direction`) to cut point `b`.
    static func cornerPieces(from a: Point, direction: Vector, to b: Point, style: LiveEffect.Corners.Style) -> [CubicBezier] {
        let chord = b - a
        guard chord.length > 1e-9 else {
            return []
        }
        if style == .chamfer {
            return [Line(start: a, end: b).elevated()]
        }
        // The circle tangent to `direction` at `a` through `b`: the sweep is twice the angle
        // between the tangent and the chord.
        let halfSweep = atan2(direction.cross(chord), direction.dot(chord))
        let sweep = 2 * halfSweep
        let radius = chord.length / (2 * abs(sin(halfSweep)))
        guard radius.isFinite, abs(sweep) > 1e-9 else {
            return [Line(start: a, end: b).elevated()]
        }
        let toCenter = (halfSweep > 0 ? direction.perpendicular : -direction.perpendicular) * radius
        var center = a + toCenter
        var arcSweep = sweep
        if style == .invertedRound {
            // Mirror the centre across the chord; the arc then bulges the other way.
            let unit = chord.normalized
            let relative = center - a
            let along = unit * relative.dot(unit)
            center = a + (along * 2 - relative)
            arcSweep = -sweep
        }
        return arc(center: center, from: a, sweep: arcSweep)
    }

    /// A circular arc about `center` starting at `start`, sweeping `sweep` radians (positive in
    /// the coordinate system's rotation direction), one cubic per ≤ 90°.
    static func arc(center: Point, from start: Point, sweep: Double) -> [CubicBezier] {
        let pieces = max(Int((abs(sweep) / (.pi / 2) - 1e-9).rounded(.up)), 1)
        let step = sweep / Double(pieces)
        let k = 4.0 / 3.0 * tan(step / 4)
        var radial = start - center
        var result: [CubicBezier] = []
        for _ in 0..<pieces {
            let next = Vector(radial.dx * cos(step) - radial.dy * sin(step), radial.dx * sin(step) + radial.dy * cos(step))
            let p0 = center + radial
            let p3 = center + next
            result.append(CubicBezier(p0: p0, p1: p0 + radial.perpendicular * k, p2: p3 - next.perpendicular * k, p3: p3))
            radial = next
        }
        return result
    }
}
