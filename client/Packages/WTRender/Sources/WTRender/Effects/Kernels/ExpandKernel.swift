// Expand Path (FX-005): the outline a stroke of `width` would have, over GEO-003.  Both is the
// stroke outline with the effect's cap, join and miter limit; Inside is the band between a closed
// region and its inset by the width (GEO-003's negative offset), Outside the band between its
// outset and the region.  Open contours always expand on both sides.  The result is normalized
// and filled non-zero.

import WTGeometry

enum ExpandKernel {
    static func apply(_ settings: LiveEffect.ExpandPath, to shapes: [EffectShape], tolerance: Double = Offset.defaultTolerance) -> [EffectShape] {
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
                    let band: FilledPath
                    if settings.direction == .inside {
                        let inner = Offset.inset(region, by: width, join: settings.join.geometry, miterLimit: settings.effectiveMiterLimit, tolerance: tolerance)
                        band = inner.isEmpty ? Boolean.normalize(region, options: options) : Boolean.subtracting(region, inner, options: options)
                    } else {
                        let outer = Offset.inset(region, by: -width, join: settings.join.geometry, miterLimit: settings.effectiveMiterLimit, tolerance: tolerance)
                        band = Boolean.subtracting(outer, region, options: options)
                    }
                    contours += band.contours
                }
            }
            return EffectShape(contours: contours, rule: .nonZero)
        }
    }
}
