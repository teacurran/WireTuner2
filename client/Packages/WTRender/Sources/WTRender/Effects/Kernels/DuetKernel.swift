// Duet (FX-004): the original and its clones as one compound shape.  Reflect adds one mirror image
// across the axis through the centre at `axisAngle` (counterclockwise, y up); Rotate makes a
// rosette of `copies` shapes, the original included, evenly rotated about the centre (two copies
// are a 180° pair).  A mirror image is reversed so it winds like the original and the non-zero
// fill is the union.  Joined connects the pieces end to start into one path, Closed closes each
// piece (or the joined path), Even/odd sets the result's fill rule.

import Foundation
import WTGeometry

enum DuetKernel {
    /// The mirror across the line through `center` at `degrees` (counterclockwise, y up).
    static func reflection(center: Point, degrees: Double) -> AffineTransform {
        let angle = (degrees.isFinite ? degrees : 0) * .pi / 180
        let ux = cos(angle)
        let uy = -sin(angle)  // y down
        // 2uuᵀ − I
        let mirror = AffineTransform(a: 2 * ux * ux - 1, b: 2 * ux * uy, c: 2 * ux * uy, d: 2 * uy * uy - 1, tx: 0, ty: 0)
        return AffineTransform.translation(x: -center.x, y: -center.y)
            .concatenating(mirror)
            .concatenating(.translation(x: center.x, y: center.y))
    }

    /// The placements of every piece, the original (identity) first.
    static func placements(_ settings: LiveEffect.Duet, reference: Rect) -> [AffineTransform] {
        let center = effectCenter(reference, offset: settings.center)
        switch settings.mode {
        case .reflect:
            return [.identity, reflection(center: center, degrees: settings.axisAngle)]
        case .rotate:
            let count = settings.effectiveCopies
            return (0..<count).map { index in
                // Counterclockwise on screen: negative in y-down space.
                AffineTransform.rotation(radians: -2 * .pi * Double(index) / Double(count), around: center)
            }
        }
    }

    static func apply(_ settings: LiveEffect.Duet, to shapes: [EffectShape], reference: Rect) -> [EffectShape] {
        let placements = placements(settings, reference: reference)
        return shapes.map { shape in
            var pieces: [[Contour]] = []
            for placement in placements {
                var contours = shape.contours.map { $0.applying(placement) }
                if placement.determinant < 0 {
                    // A mirror image winds the other way; reverse it (and its order, so a joined
                    // path runs back along it).
                    contours = contours.reversed().map { $0.reversed() }
                }
                pieces.append(contours)
            }
            let rule: FillRule? = settings.evenOdd ? .evenOdd : shape.rule
            if settings.joined {
                return EffectShape(contours: [join(pieces.flatMap { $0 }, closed: settings.closed)], rule: rule)
            }
            let contours = pieces.flatMap { $0 }.map { contour -> Contour in
                settings.closed ? Contour(segments: contour.segments, closed: true) : contour
            }
            return EffectShape(contours: contours, rule: rule)
        }
    }

    /// Every contour's segments end to start in one path, a straight segment bridging each gap.
    static func join(_ contours: [Contour], closed: Bool) -> Contour {
        var segments: [CubicBezier] = []
        for contour in contours {
            let pieces = contour.explicitSegments
            guard let first = pieces.first else { continue }
            if let last = segments.last, last.p3 != first.p0 {
                segments.append(Line(start: last.p3, end: first.p0).elevated())
            }
            segments += pieces
        }
        return Contour(segments: segments, closed: closed)
    }
}
