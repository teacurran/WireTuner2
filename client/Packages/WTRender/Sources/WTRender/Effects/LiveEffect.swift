// Live effects in the display list (FX-004 ... FX-015, FX-046, FX-048;
// docs/_includes/effects/live-effects.adoc, raster-effects.adoc, transparency.adoc).  These mirror
// `effects.proto` with every reference resolved -- colours are values, `attached_to` is an index
// into the stack, `CornersEffect.points` are anchor positions -- so WTModel only copies fields.
// Stored values are kept as written; the read-time normalizations (zero defaults, clamps, seed 0)
// are applied by the `effective*` accessors the kernels read.  WTRender does not import WTProto.

import WTGeometry

/// One live effect's kind and settings (`EffectSettings`, the live case only).
public enum LiveEffect: Hashable, Sendable {
    case bend(Bend)
    case duet(Duet)
    case expandPath(ExpandPath)
    case ragged(Ragged)
    case sketch(Sketch)
    case transform(Transform)
    case corners(Corners)
    case combine(Combine)
    case bevelEmboss(BevelEmboss)
    case blur(Blur)
    case shadow(Shadow)
    case sharpen(Sharpen)
    case transparency(Transparency)
    /// `EFFECT_KIND_UNSPECIFIED` or a kind this build does not know: renders as no effect.
    case unsupported

    /// Whether the effect produces outline geometry (the vector family).
    public var isVector: Bool {
        switch self {
        case .bend, .duet, .expandPath, .ragged, .sketch, .transform, .corners, .combine: return true
        case .bevelEmboss, .blur, .shadow, .sharpen, .transparency, .unsupported: return false
        }
    }

    // MARK: Vector effects

    /// Bloat (positive size) or pinch (negative) about a centre (`BendEffect`).
    public struct Bend: Hashable, Sendable {
        /// Points.
        public var size: Double
        /// Relative to the object's bounds centre, in points, y up (as the panel shows it).
        public var center: Point

        public init(size: Double = 0, center: Point = .zero) {
            self.size = size
            self.center = center
        }
    }

    /// Mirrored or rotated clones (`DuetEffect`).
    public struct Duet: Hashable, Sendable {
        public enum Mode: Hashable, Sendable {
            case reflect
            case rotate
        }

        public var mode: Mode
        /// Relative to the object's bounds centre, points, y up.
        public var center: Point
        /// Degrees, counterclockwise from the x axis: the mirror axis for Reflect.
        public var axisAngle: Double
        /// Rotate only: how many shapes the rosette has, the original included; 0 reads 1.
        public var copies: Int
        public var joined: Bool
        public var closed: Bool
        public var evenOdd: Bool

        public init(mode: Mode = .reflect, center: Point = .zero, axisAngle: Double = 0, copies: Int = 0, joined: Bool = false, closed: Bool = false, evenOdd: Bool = false) {
            self.mode = mode
            self.center = center
            self.axisAngle = axisAngle
            self.copies = copies
            self.joined = joined
            self.closed = closed
            self.evenOdd = evenOdd
        }

        /// 1 ... 100; 0 reads 1.
        public var effectiveCopies: Int { min(max(copies, 1), 100) }
    }

    /// The outline of a stroke along the path as the object's shape (`ExpandPathEffect`).
    public struct ExpandPath: Hashable, Sendable {
        public enum Direction: Hashable, Sendable {
            case both
            case inside
            case outside
        }

        public var direction: Direction
        /// Points, 0 ... 50.
        public var width: Double
        public var cap: LineCap
        public var join: LineJoin
        /// 1 ... 57; 0 reads 4.
        public var miterLimit: Double

        public init(direction: Direction = .both, width: Double = 0, cap: LineCap = .butt, join: LineJoin = .miter, miterLimit: Double = 0) {
            self.direction = direction
            self.width = width
            self.cap = cap
            self.join = join
            self.miterLimit = miterLimit
        }

        public var effectiveWidth: Double { width.isFinite ? min(max(width, 0), 50) : 0 }
        public var effectiveMiterLimit: Double { miterLimit == 0 || !miterLimit.isFinite ? 4 : min(max(miterLimit, 1), 57) }
    }

    /// Seeded random (or uniform) displacement of added points (`RaggedEffect`).
    public struct Ragged: Hashable, Sendable {
        /// Points, the furthest an added point strays.
        public var size: Double
        /// Added points per inch of outline.
        public var frequency: Double
        /// Extra outlines, 0 ... 10.
        public var copies: Int
        /// Curve points (Smooth) rather than corner points (Rough).
        public var smooth: Bool
        /// Alternate ± size instead of random amounts.
        public var uniform: Bool
        /// 0 reads 1 (D-022).
        public var seed: UInt64

        public init(size: Double = 0, frequency: Double = 0, copies: Int = 0, smooth: Bool = false, uniform: Bool = false, seed: UInt64 = 1) {
            self.size = size
            self.frequency = frequency
            self.copies = copies
            self.smooth = smooth
            self.uniform = uniform
            self.seed = seed
        }

        public var effectiveSize: Double { size.isFinite ? max(size, 0) : 0 }
        public var effectiveFrequency: Double { frequency.isFinite ? max(frequency, 0) : 0 }
        public var effectiveCopies: Int { min(max(copies, 0), 10) }
        public var effectiveSeed: UInt64 { seed == 0 ? 1 : seed }
    }

    /// Jittered pencil copies of the outline (`SketchEffect`).
    public struct Sketch: Hashable, Sendable {
        /// Points.
        public var amount: Double
        /// 1 ... 20; 0 reads 1.
        public var copies: Int
        public var closed: Bool
        /// 0 reads 1.
        public var seed: UInt64

        public init(amount: Double = 0, copies: Int = 0, closed: Bool = false, seed: UInt64 = 1) {
            self.amount = amount
            self.copies = copies
            self.closed = closed
            self.seed = seed
        }

        public var effectiveAmount: Double { amount.isFinite ? max(amount, 0) : 0 }
        public var effectiveCopies: Int { min(max(copies, 1), 20) }
        public var effectiveSeed: UInt64 { seed == 0 ? 1 : seed }
    }

    /// Scale, skew, rotate and move about a centre, optionally repeated (`TransformEffect`).
    public struct Transform: Hashable, Sendable {
        /// Percent; 0 reads 100.
        public var scaleX: Double
        /// Percent; 0 reads 100.
        public var scaleY: Double
        /// Degrees; positive leans the top to the right.
        public var skewH: Double
        /// Degrees; positive raises the right side.
        public var skewV: Double
        /// Degrees, counterclockwise.
        public var rotate: Double
        /// Points, y up.
        public var move: Point
        /// Relative to the object's bounds centre, points, y up.
        public var center: Point
        /// 1 ... 1000; 0 reads 1.
        public var copies: Int

        public init(scaleX: Double = 0, scaleY: Double = 0, skewH: Double = 0, skewV: Double = 0, rotate: Double = 0, move: Point = .zero, center: Point = .zero, copies: Int = 0) {
            self.scaleX = scaleX
            self.scaleY = scaleY
            self.skewH = skewH
            self.skewV = skewV
            self.rotate = rotate
            self.move = move
            self.center = center
            self.copies = copies
        }

        public var effectiveCopies: Int { min(max(copies, 1), 1000) }
    }

    /// Rounded, scooped or chamfered corners (`CornersEffect`).
    public struct Corners: Hashable, Sendable {
        public enum Style: Hashable, Sendable {
            case round
            case invertedRound
            case chamfer
        }

        /// Points, at least 0; capped per corner.
        public var radius: Double
        public var style: Style
        /// The anchors treated, by contour and anchor index (WTModel resolves `points`, dropping
        /// dangling and foreign members); empty treats every eligible corner.  Members that are
        /// not corners are ignored here.
        public var points: [CornerPoint]

        public init(radius: Double = 0, style: Style = .round, points: [CornerPoint] = []) {
            self.radius = radius
            self.style = style
            self.points = points
        }
    }

    /// A live boolean over a group's members (`CombineEffect`).  Anywhere but at the object
    /// level of a group it renders as no effect.
    public struct Combine: Hashable, Sendable {
        public enum Operation: Hashable, Sendable {
            case union
            case subtract
            case intersect
            case exclude
        }

        public var operation: Operation

        public init(operation: Operation = .union) {
            self.operation = operation
        }
    }

    // MARK: Raster effects

    /// Bevels and embosses (`BevelEmbossEffect`).
    public struct BevelEmboss: Hashable, Sendable {
        public enum Style: Hashable, Sendable, CaseIterable {
            case outerBevel
            case innerBevel
            case raisedEmboss
            case insetEmboss
        }

        public enum EdgeShape: Hashable, Sendable, CaseIterable {
            case flat
            case smooth
            case sloped
            case frame1
            case frame2
            case ring
            case ruffle
        }

        public enum ButtonPreset: Hashable, Sendable, CaseIterable {
            case raised
            case highlighted
            case inset
            case inverted
        }

        public var style: Style
        /// The outer bevel's rim colour.
        public var color: Color
        /// Points.
        public var width: Double
        /// 0 ... 100.
        public var contrast: Double
        /// 0 ... 10.
        public var softness: Double
        /// Degrees: where the light comes from, counterclockwise from the right.
        public var angle: Double
        public var edgeShape: EdgeShape
        public var buttonPreset: ButtonPreset

        public init(style: Style = .innerBevel, color: Color = Color(white: 0.6), width: Double = 0, contrast: Double = 0, softness: Double = 0, angle: Double = 0, edgeShape: EdgeShape = .flat, buttonPreset: ButtonPreset = .raised) {
            self.style = style
            self.color = color
            self.width = width
            self.contrast = contrast
            self.softness = softness
            self.angle = angle
            self.edgeShape = edgeShape
            self.buttonPreset = buttonPreset
        }

        public var effectiveWidth: Double { width.isFinite ? min(max(width, 0), 1000) : 0 }
        public var effectiveContrast: Double { contrast.isFinite ? min(max(contrast, 0), 100) : 0 }
        public var effectiveSoftness: Double { softness.isFinite ? min(max(softness, 0), 10) : 0 }
    }

    /// Box or Gaussian blur (`BlurEffect`).
    public struct Blur: Hashable, Sendable {
        public enum Style: Hashable, Sendable {
            case basic
            case gaussian
        }

        public var style: Style
        /// Pixels at the raster resolution, 0 ... 250.
        public var radius: Double

        public init(style: Style = .gaussian, radius: Double = 0) {
            self.style = style
            self.radius = radius
        }

        public var effectiveRadius: Double { radius.isFinite ? min(max(radius, 0), 250) : 0 }
    }

    /// Shadows and glows (`ShadowEffect`).
    public struct Shadow: Hashable, Sendable {
        public enum Style: Hashable, Sendable, CaseIterable {
            case dropShadow
            case innerShadow
            case glow
            case innerGlow
        }

        public var style: Style
        public var color: Color
        /// Points: the distance along `angle` (shadows) or the halo width (glows).
        public var offset: Double
        /// 0 ... 100.
        public var opacity: Double
        /// 0 ... 30.
        public var softness: Double
        /// Degrees, shadows only: the direction the shadow falls, counterclockwise from the right.
        public var angle: Double

        public init(style: Style = .dropShadow, color: Color = .black, offset: Double = 0, opacity: Double = 0, softness: Double = 0, angle: Double = 0) {
            self.style = style
            self.color = color
            self.offset = offset
            self.opacity = opacity
            self.softness = softness
            self.angle = angle
        }

        public var effectiveOffset: Double { offset.isFinite ? min(max(offset, 0), 1000) : 0 }
        public var effectiveOpacity: Double { opacity.isFinite ? min(max(opacity, 0), 100) : 0 }
        public var effectiveSoftness: Double { softness.isFinite ? min(max(softness, 0), 30) : 0 }
    }

    /// Basic sharpen and Unsharp Mask (`SharpenEffect`).
    public struct Sharpen: Hashable, Sendable {
        public enum Style: Hashable, Sendable {
            case basic
            case unsharpMask
        }

        public var style: Style
        /// Percent, 0 ... 500.
        public var amount: Double
        /// Unsharp only: pixels, 0.1 ... 250; 0 reads 1.
        public var pixelRadius: Double
        /// Unsharp only: levels, 0 ... 255.
        public var threshold: Double

        public init(style: Style = .basic, amount: Double = 0, pixelRadius: Double = 0, threshold: Double = 0) {
            self.style = style
            self.amount = amount
            self.pixelRadius = pixelRadius
            self.threshold = threshold
        }

        public var effectiveAmount: Double { amount.isFinite ? min(max(amount, 0), 500) : 0 }
        public var effectivePixelRadius: Double { pixelRadius == 0 || !pixelRadius.isFinite ? 1 : min(max(pixelRadius, 0.1), 250) }
        public var effectiveThreshold: Double { threshold.isFinite ? min(max(threshold, 0), 255) : 0 }
    }

    /// Transparency (`TransparencyEffect`).
    public struct Transparency: Hashable, Sendable {
        public enum Style: Hashable, Sendable {
            case basic
            case feather
            case gradientMask
        }

        public var style: Style
        /// Basic: 0 opaque ... 100 invisible.
        public var amount: Double
        /// Feather: points.
        public var radius: Double
        /// Feather: 0 ... 100.
        public var softness: Double
        /// Gradient Mask: the gradient whose stop luminance is 1 − alpha (its live stops only).
        public var mask: Gradient?

        public init(style: Style = .basic, amount: Double = 0, radius: Double = 0, softness: Double = 0, mask: Gradient? = nil) {
            self.style = style
            self.amount = amount
            self.radius = radius
            self.softness = softness
            self.mask = mask
        }

        public var effectiveAmount: Double { amount.isFinite ? min(max(amount, 0), 100) : 0 }
        public var effectiveRadius: Double { radius.isFinite ? min(max(radius, 0), 1000) : 0 }
        public var effectiveSoftness: Double { softness.isFinite ? min(max(softness, 0), 100) : 0 }
    }
}

/// An anchor of a path by contour and position: the `k`th anchor of contour `c` in
/// `DisplayPath.contours` order (for a closed contour anchor `k` starts segment `k`; for an open
/// one anchor `k` ends segment `k − 1`).
public struct CornerPoint: Hashable, Sendable {
    public var contour: Int
    public var anchor: Int

    public init(contour: Int, anchor: Int) {
        self.contour = contour
        self.anchor = anchor
    }
}

/// Where an effect applies: the whole object, or one fill or stroke of the stack.
public enum EffectTarget: Hashable, Sendable {
    case object
    /// An index into `Appearance.items`.
    case element(Int)
}

/// One effect of an attribute stack (`Effect`), resolved.
public struct EffectElement: Hashable, Sendable {
    public var effect: LiveEffect
    public var target: EffectTarget
    /// The eye toggle: kept, never drawn.
    public var hidden: Bool

    public init(_ effect: LiveEffect, target: EffectTarget = .object, hidden: Bool = false) {
        self.effect = effect
        self.target = target
        self.hidden = hidden
    }
}

/// The raster effects resolution an object renders at: the object's own override or the
/// document's `RasterEffectSettings`, resolved by WTModel.
public struct RasterSettings: Hashable, Sendable {
    /// Pixels per inch, 1 ... 2400; 0 reads 72.
    public var resolution: Double
    /// Compute effects without colour management (`optimal_cmyk`).
    public var optimalCMYK: Bool

    public init(resolution: Double = 72, optimalCMYK: Bool = false) {
        self.resolution = resolution
        self.optimalCMYK = optimalCMYK
    }

    public var effectiveResolution: Double {
        resolution == 0 || !resolution.isFinite ? 72 : min(max(resolution, 1), 2400)
    }
}

/// The *Raster effect preview* preference (Redraw settings): how the screen renders raster
/// effects.  Print and export always use the object's resolution.
public enum RasterPreview: Hashable, Sendable, CaseIterable {
    /// The screen's pixel density at the current zoom, capped at the object's resolution.
    case screen
    /// The object's resolution, scaled.
    case document
    /// Half the screen resolution.
    case draft
    /// Raster effects are not drawn; a small badge marks the object.
    case off

    /// The resolution to render at for `deviceScale` device pixels per point.
    func resolution(for settings: RasterSettings, deviceScale: Double) -> Double {
        let document = settings.effectiveResolution
        let screen = 72 * (deviceScale.isFinite && deviceScale > 0 ? deviceScale : 1)
        switch self {
        case .screen, .off: return min(screen, document)
        case .document: return document
        case .draft: return min(screen / 2, document)
        }
    }
}
