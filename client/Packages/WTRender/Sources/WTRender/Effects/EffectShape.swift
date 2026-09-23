// The geometry vector effects work on (FX-004): an outline as WTGeometry contours plus the fill
// rule the effect imposes, if any.  A vector effect is a function from shapes to shapes; several
// shapes result from copies (Transform, Ragged, Sketch), each drawn with the same fill or
// stroke.  The kernels live here in WTRender rather than in WTGeometry (the effects pages'
// deviation note): they are specific to the effect settings, which are display-list types.

import WTGeometry

/// One outline an effect produced.
struct EffectShape: Hashable, Sendable {
    var contours: [Contour]
    /// The fill rule the effect imposes (Duet's even/odd); nil keeps the element's own.
    var rule: FillRule?

    init(contours: [Contour], rule: FillRule? = nil) {
        self.contours = contours
        self.rule = rule
    }

    /// The shape's tight bounds, or null for no geometry.
    var bounds: Rect {
        var result = Rect.null
        for contour in contours where !contour.isEmpty {
            result.formUnion(contour.bounds)
        }
        return result
    }

    func applying(_ transform: AffineTransform) -> EffectShape {
        EffectShape(contours: contours.map { $0.applying(transform) }, rule: rule)
    }

    /// As a display path.
    var path: DisplayPath { DisplayPath(contours: contours) }
}

extension Contour {
    /// The segments with a closed contour's implicit closing segment made explicit, so the
    /// contour ends where it starts.
    var explicitSegments: [CubicBezier] {
        if isClosed, let closing = closingSegment {
            return segments + [closing]
        }
        return segments
    }

    /// The contour with its closing segment explicit.
    var materialized: Contour {
        Contour(segments: explicitSegments, closed: isClosed)
    }
}

extension Array where Element == Contour {
    /// The union of the contours' tight bounds.
    var bounds: Rect {
        var result = Rect.null
        for contour in self where !contour.isEmpty {
            result.formUnion(contour.bounds)
        }
        return result
    }
}

/// Where an effect's centre sits: `offset` (points, y up as the panel shows it) from the centre
/// of `reference`, in a y-down space.
func effectCenter(_ reference: Rect, offset: Point) -> Point {
    let base = reference.isNull ? Point.zero : reference.center
    return Point(x: base.x + (offset.x.isFinite ? offset.x : 0), y: base.y - (offset.y.isFinite ? offset.y : 0))
}
