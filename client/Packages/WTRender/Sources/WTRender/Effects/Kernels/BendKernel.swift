// Bend (FX-004; live-effects.adoc, "Kernels"): every point moves along its radial from the
// centre by `size × (1 − d / d_max)`, where `d_max` is the distance of the farthest point.  Anchors
// and control points move by their own distance, so straight sides bulge (a cushion) or cave in (a
// star); then the two handles of every anchor that was smooth are turned back onto one line, at
// their new lengths, so smooth points stay smooth.  The Bend tool (FX-032) uses the same kernel
// with the drag distance for `size`.

import WTGeometry

enum BendKernel {
    /// `shapes` bent about `offset` from the centre of `reference`.
    static func apply(_ settings: LiveEffect.Bend, to shapes: [EffectShape], reference: Rect) -> [EffectShape] {
        let size = settings.size.isFinite ? settings.size : 0
        guard size != 0 else {
            return shapes
        }
        let center = effectCenter(reference, offset: settings.center)
        var farthest = 0.0
        for shape in shapes {
            for contour in shape.contours {
                for segment in contour.explicitSegments {
                    for point in [segment.p0, segment.p1, segment.p2, segment.p3] {
                        farthest = max(farthest, point.distance(to: center))
                    }
                }
            }
        }
        guard farthest > 0 else {
            return shapes
        }
        func displaced(_ point: Point) -> Point {
            let offset = point - center
            let distance = offset.length
            guard distance > 0 else {
                return point
            }
            return point + offset / distance * (size * (1 - distance / farthest))
        }
        return shapes.map { shape in
            EffectShape(contours: shape.contours.map { bend($0, displaced: displaced) }, rule: shape.rule)
        }
    }

    private static func bend(_ contour: Contour, displaced: (Point) -> Point) -> Contour {
        let segments = contour.explicitSegments
        guard !segments.isEmpty else {
            return contour
        }
        var result = segments.map { segment in
            CubicBezier(p0: displaced(segment.p0), p1: displaced(segment.p1), p2: displaced(segment.p2), p3: displaced(segment.p3))
        }
        // Realign the handles of anchors that were smooth (collinear, opposite handles).
        let count = segments.count
        let joints = contour.isClosed ? 0..<count : 1..<count
        for index in joints {
            let previous = (index - 1 + count) % count
            let incoming = segments[previous].p3 - segments[previous].p2
            let outgoing = segments[index].p1 - segments[index].p0
            guard incoming.length > 1e-9, outgoing.length > 1e-9,
                  abs(incoming.normalized.cross(outgoing.normalized)) < 1e-6,
                  incoming.dot(outgoing) > 0
            else {
                continue
            }
            let anchor = result[index].p0
            let newIn = result[previous].p3 - result[previous].p2
            let newOut = result[index].p1 - anchor
            let unit = (newIn.normalized + newOut.normalized).normalized
            result[previous].p2 = anchor - unit * newIn.length
            result[index].p1 = anchor + unit * newOut.length
        }
        return Contour(segments: result, closed: contour.isClosed)
    }
}
