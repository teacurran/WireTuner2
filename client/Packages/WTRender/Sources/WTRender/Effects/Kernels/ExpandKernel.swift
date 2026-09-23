// Expand Path (FX-005): the outline a stroke of `width` would have, over GEO-003.  Both is the
// stroke outline with the effect's cap, join and miter limit; Inside is the band between a closed
// region and its inset by the width (GEO-003's negative offset), Outside the band between its
// outset and the region.  Open contours always expand on both sides.  The result is normalized
// and filled non-zero.  The inset and outset are `Offset.checkedInset`: where GEO-003 cannot
// compute one, the band is built from the region and its stroke outline at twice the width
// (inside: their intersection; outside: the stroke less the region) instead of an inset read as
// a collapse (the whole region) or an outset read as nothing.

import WTGeometry

enum ExpandKernel {
    /// The inset `(region, distance, join, miterLimit, tolerance)`; replaced in tests.
    typealias Inset = @Sendable (FilledPath, Double, WTGeometry.LineJoin, Double, Double) throws -> FilledPath

    static let checkedInset: Inset = { try Offset.checkedInset($0, by: $1, join: $2, miterLimit: $3, tolerance: $4) }

    static func apply(_ settings: LiveEffect.ExpandPath, to shapes: [EffectShape], tolerance: Double = Offset.defaultTolerance, inset: Inset = checkedInset) -> [EffectShape] {
        let width = settings.effectiveWidth
        return shapes.map { shape in
            guard width > 0 else {
                return EffectShape(contours: [], rule: .nonZero)
            }
            let style = WTGeometry.StrokeStyle(width: width, cap: settings.cap.geometry, join: settings.join.geometry, miterLimit: settings.effectiveMiterLimit)
            let closed = shape.contours.filter(\.isClosed)
            let open = shape.contours.filter { !$0.isClosed }
            var contours: [Contour] = []
            if settings.direction == .both {
                contours += Offset.strokeOutline(shape.contours, style: style, tolerance: tolerance).contours
            } else {
                if !open.isEmpty {
                    contours += Offset.strokeOutline(open, style: style, tolerance: tolerance).contours
                }
                if !closed.isEmpty {
                    let region = FilledPath(contours: closed, fillRule: shape.rule ?? .nonZero)
                    let options = Boolean.Options(tolerance: min(tolerance, 1e-3))
                    let join = settings.join.geometry, miterLimit = settings.effectiveMiterLimit
                    let band: FilledPath
                    do {
                        if settings.direction == .inside {
                            let inner = try inset(region, width, join, miterLimit, tolerance)
                            band = inner.isEmpty ? Boolean.normalize(region, options: options) : Boolean.subtracting(region, inner, options: options)
                        } else {
                            let outer = try inset(region, -width, join, miterLimit, tolerance)
                            band = Boolean.subtracting(outer, region, options: options)
                        }
                    } catch {
                        let stroke = Offset.strokeOutline(
                            region.contours,
                            style: WTGeometry.StrokeStyle(width: 2 * width, cap: .butt, join: join, miterLimit: miterLimit),
                            tolerance: tolerance)
                        band = settings.direction == .inside
                            ? Boolean.intersection(region, stroke, options: options)
                            : Boolean.subtracting(stroke, region, options: options)
                    }
                    contours += band.contours
                }
            }
            return EffectShape(contours: contours, rule: .nonZero)
        }
    }
}
