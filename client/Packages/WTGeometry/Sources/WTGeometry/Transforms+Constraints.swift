import Foundation

// GEO-005: transform utilities and the constrain-angle rule.  Snapping lives in Snapping.swift.

extension Vector {
    /// The direction of the vector in radians, measured in the coordinate system's positive
    /// rotation from +x (`atan2(dy, dx)`); 0 for the zero vector.
    @inlinable
    public var angle: Double {
        dx == 0 && dy == 0 ? 0 : atan2(dy, dx)
    }

    /// The vector of the given direction and length.
    @inlinable
    public init(angle: Double, length: Double = 1) {
        self.init(dx: cos(angle) * length, dy: sin(angle) * length)
    }

    /// This vector turned by `radians` in the positive rotation direction.
    public func rotated(by radians: Double) -> Vector {
        let s = sin(radians)
        let c = cos(radians)
        return Vector(dx: dx * c - dy * s, dy: dx * s + dy * c)
    }
}

/// The kbd:[Shift] constraint (`transforming`, "Constrain angle"; `moving`, "Dragging"): a
/// drag or a rotation snaps to the *Constrain angle* and every `step` (45° by default) from it.
///
/// The rule is the same for every tool: a direction is replaced by the nearest of
/// `baseAngle + k·step`, ties (a direction exactly halfway) going to the larger multiple.  A
/// drag vector is *projected* onto the chosen direction, so the constrained drag is as long as
/// the pointer travelled along it, not as long as the pointer travelled in total.
public struct AngleConstraint: Hashable, Sendable {
    /// The *Constrain angle* preference, in radians (default 0°).
    public var baseAngle: Double
    /// The spacing of the allowed directions, in radians (default 45°).
    public var step: Double

    public init(baseAngle: Double = 0, step: Double = .pi / 4) {
        self.baseAngle = baseAngle
        self.step = step
    }

    /// The default rule: 0° base, 45° steps.
    public static let standard = AngleConstraint()

    /// The base angle in degrees, as the preference stores it.
    public static func degrees(_ base: Double, step: Double = 45) -> AngleConstraint {
        AngleConstraint(baseAngle: base * .pi / 180, step: step * .pi / 180)
    }

    /// The allowed direction nearest `angle` (radians).  A non-positive step allows any angle.
    public func snappedAngle(_ angle: Double) -> Double {
        guard step > 0, angle.isFinite else {
            return angle
        }
        let k = ((angle - baseAngle) / step).rounded()
        return baseAngle + k * step
    }

    /// The rotation nearest `rotation` that a kbd:[Shift]-constrained rotate tool allows
    /// (`transforming`: "rotation and reflection to 45° steps from the Constrain angle").
    /// Rotations are relative, so the base angle is not applied: the result is a multiple of
    /// `step`.
    public func snappedRotation(_ rotation: Double) -> Double {
        guard step > 0, rotation.isFinite else {
            return rotation
        }
        return (rotation / step).rounded() * step
    }

    /// The drag vector projected onto its nearest allowed direction.  The zero vector and a
    /// non-positive step pass through unchanged.
    public func constrain(_ vector: Vector) -> Vector {
        guard step > 0, vector.isFinite, vector.lengthSquared > 0 else {
            return vector
        }
        let direction = Vector(angle: snappedAngle(vector.angle))
        return direction * vector.dot(direction)
    }

    /// `end` moved so that the drag from `start` lies on an allowed direction.
    public func constrain(_ end: Point, from start: Point) -> Point {
        start + constrain(end - start)
    }

    /// The unit vectors of every allowed direction in one turn, starting at the base angle;
    /// empty when the step does not divide a turn into a whole number of directions.
    public var directions: [Vector] {
        guard step > 0 else {
            return []
        }
        let count = (2 * Double.pi / step).rounded()
        guard count >= 1, count <= 3600, abs(count * step - 2 * Double.pi) <= 1e-9 else {
            return []
        }
        return (0..<Int(count)).map { Vector(angle: baseAngle + Double($0) * step) }
    }
}

extension AffineTransform {
    /// Uniform scale about `center`.
    public static func scale(_ factor: Double, around center: Point) -> AffineTransform {
        scale(x: factor, y: factor, around: center)
    }

    /// Non-uniform scale about `center`.
    public static func scale(x: Double, y: Double, around center: Point) -> AffineTransform {
        translation(Point.zero - center)
            .concatenating(scale(x: x, y: y))
            .concatenating(translation(center - Point.zero))
    }

    /// A shear: `x' = x + kx·y`, `y' = y + ky·x`.
    public static func shear(x kx: Double, y ky: Double) -> AffineTransform {
        AffineTransform(a: 1, b: ky, c: kx, d: 1, tx: 0, ty: 0)
    }

    /// A skew by angles: the shear whose factors are the tangents of `xAngle` and `yAngle`.
    public static func skew(xAngle: Double, yAngle: Double) -> AffineTransform {
        shear(x: tan(xAngle), y: tan(yAngle))
    }

    /// A skew by angles about `center`.
    public static func skew(xAngle: Double, yAngle: Double, around center: Point) -> AffineTransform {
        translation(Point.zero - center)
            .concatenating(skew(xAngle: xAngle, yAngle: yAngle))
            .concatenating(translation(center - Point.zero))
    }

    /// Reflection across the infinite line through `line`; nil for a zero-length line.
    public static func reflection(across line: Line) -> AffineTransform? {
        let d = line.direction
        guard d.lengthSquared > 0, d.isFinite else {
            return nil
        }
        let u = d.normalized
        let linear = AffineTransform(
            a: 2 * u.dx * u.dx - 1, b: 2 * u.dx * u.dy,
            c: 2 * u.dx * u.dy, d: 2 * u.dy * u.dy - 1,
            tx: 0, ty: 0)
        return translation(Point.zero - line.start)
            .concatenating(linear)
            .concatenating(translation(line.start - Point.zero))
    }

    /// The factors of a transform as the Transform panel shows them: `scale`, then `shear`,
    /// then `rotation`, then `translation` (each applied to a point in that order).
    public struct Decomposition: Hashable, Sendable {
        public var translation: Vector
        /// Radians, positive rotation direction.
        public var rotation: Double
        public var scaleX: Double
        public var scaleY: Double
        /// The horizontal skew angle in radians: `x' = x + tan(skewX)·y` before rotation.
        public var skewX: Double

        public init(translation: Vector, rotation: Double, scaleX: Double, scaleY: Double, skewX: Double) {
            self.translation = translation
            self.rotation = rotation
            self.scaleX = scaleX
            self.scaleY = scaleY
            self.skewX = skewX
        }

        /// The transform the factors compose to.
        public var transform: AffineTransform {
            AffineTransform.scale(x: scaleX, y: scaleY)
                .concatenating(.shear(x: tan(skewX), y: 0))
                .concatenating(.rotation(radians: rotation))
                .concatenating(.translation(translation))
        }
    }

    /// Factors the transform into scale, horizontal skew, rotation and translation (a QR-like
    /// split of the linear part).  A reflection shows up as a negative `scaleY`; a transform
    /// that collapses the x axis has zero `scaleX` and an undefined skew reported as 0.
    public func decomposed() -> Decomposition {
        let sx = (a * a + b * b).squareRoot()
        let rotation = sx > 0 ? atan2(b, a) : 0
        // Rotate the linear part back by -rotation: the upper-triangular remainder.
        let c1 = sx > 0 ? (a * c + b * d) / sx : 0
        let d1 = sx > 0 ? (a * d - b * c) / sx : (c * c + d * d).squareRoot()
        let skew = d1 != 0 ? atan(c1 / d1) : 0
        return Decomposition(translation: translation, rotation: rotation, scaleX: sx, scaleY: d1, skewX: skew)
    }
}
