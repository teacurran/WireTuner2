// Transform (FX-004): scale, skew, rotate and move about a centre, composed in that fixed order
// (live-effects.adoc, "Transform"), then repeated: copy k of `copies` is the original transformed
// k times, so one copy transforms the original only and the defaults are the identity.  The
// panel's conventions are y up; the kernel works in the display list's y-down space.

import Foundation
import WTGeometry

enum TransformKernel {
    /// The transform of one step about `offset` from the centre of `reference`.
    static func matrix(_ settings: LiveEffect.Transform, reference: Rect) -> AffineTransform {
        func finite(_ value: Double, _ fallback: Double = 0) -> Double { value.isFinite ? value : fallback }
        let center = effectCenter(reference, offset: settings.center)
        let sx = settings.scaleX == 0 ? 1 : finite(settings.scaleX, 100) / 100
        let sy = settings.scaleY == 0 ? 1 : finite(settings.scaleY, 100) / 100
        // Positive horizontal skew leans the top (smaller y) right; positive vertical skew
        // raises (moves to smaller y) the right side.
        let skewH = tan(min(max(finite(settings.skewH), -89), 89) * .pi / 180)
        let skewV = tan(min(max(finite(settings.skewV), -89), 89) * .pi / 180)
        let skew = AffineTransform(a: 1, b: -skewV, c: -skewH, d: 1, tx: 0, ty: 0)
        // Counterclockwise on screen is a negative angle in y-down space.
        let rotation = AffineTransform.rotation(radians: -finite(settings.rotate) * .pi / 180)
        return AffineTransform.translation(x: -center.x, y: -center.y)
            .concatenating(.scale(x: sx, y: sy))
            .concatenating(skew)
            .concatenating(rotation)
            .concatenating(.translation(x: center.x + finite(settings.move.x), y: center.y - finite(settings.move.y)))
    }

    /// The placements of every copy: the step applied once, twice, ... `copies` times.
    static func copies(_ settings: LiveEffect.Transform, reference: Rect) -> [AffineTransform] {
        let step = matrix(settings, reference: reference)
        var result: [AffineTransform] = []
        var current = AffineTransform.identity
        for _ in 0..<settings.effectiveCopies {
            current = current.concatenating(step)
            result.append(current)
        }
        return result
    }

    static func apply(_ settings: LiveEffect.Transform, to shapes: [EffectShape], reference: Rect) -> [EffectShape] {
        copies(settings, reference: reference).flatMap { placement in
            shapes.map { $0.applying(placement) }
        }
    }
}
