// The stroke kinds beyond Basic, as display-list values (ATTR-010, ATTR-011, ATTR-012;
// docs/_includes/appearance/stroke-attributes.adoc).  They mirror `stroke.proto` with references
// resolved: a brush arrives with its symbols as display lists, a calligraphic nib as a path.  A
// Pattern stroke is a Basic stroke whose paint is `.pattern` (ATTR-014): its outline is the
// Basic stroke's, filled with the pattern.

import WTGeometry
import Foundation

/// Which kind of stroke a `StrokePaint` is.  Basic strokes use the paint's `style` and
/// arrowheads; the others carry their own settings.
public enum StrokeKind: Hashable, Sendable {
    case basic
    /// Symbols painted or sprayed along the path.  The stroke's paint and style are the cached
    /// `BasicStroke` drawn when the brush is gone or has no live symbols.
    case brush(BrushStroke)
    /// A nib swept along the path, filled with the stroke's paint.
    case calligraphic(CalligraphicNib)
    /// One of the 23 ornamental tiles repeated along the path, `style.width` wide, in the
    /// stroke's paint (Neon uses its own colours).
    case custom(CustomStroke)
}

// MARK: - Brushes

/// `BrushMode`; unspecified reads as Spray.
public enum BrushMode: Hashable, Sendable {
    case spray
    case paint
}

/// `VariationMode`.
public enum VariationMode: Hashable, Sendable {
    case fixed
    case random
    case variable
    case flare
}

/// `BrushVariation`: one choice of mode and values.
public struct BrushVariation: Hashable, Sendable {
    public var mode: VariationMode
    public var value: Double
    public var min: Double
    public var max: Double

    public init(mode: VariationMode = .fixed, value: Double, min: Double = 0, max: Double = 0) {
        self.mode = mode
        self.value = value
        self.min = min
        self.max = max
    }

    public static func fixed(_ value: Double) -> BrushVariation {
        BrushVariation(mode: .fixed, value: value)
    }

    /// The value for a copy at `fraction` (0 at the path's start, 1 at its end) given a
    /// uniform `random` draw in 0..<1: Fixed is `value`; Random is uniform between `min` and
    /// `max`; Variable changes linearly from `min` to `max`; Flare swells from `min` at both
    /// ends to `max` halfway.
    public func value(at fraction: Double, random: Double) -> Double {
        switch mode {
        case .fixed: return value
        case .random: return min + (max - min) * random
        case .variable: return min + (max - min) * fraction
        case .flare: return min + (max - min) * sin(Double.pi * Swift.min(Swift.max(fraction, 0), 1))
        }
    }
}

/// One symbol a brush paints: its artwork as display items in symbol space.
public struct BrushSymbol: Hashable, Sendable {
    public var items: [DisplayItem]

    public init(items: [DisplayItem]) {
        self.items = items
    }

    /// The artwork's geometric bounds (strokes not included): the symbol's size along and
    /// across the path.  Nil for a symbol with no geometry (skipped).
    public var bounds: Rect? {
        DisplayList.union(of: items.compactMap(\.geometricBounds))
    }
}

/// A brush node (`BrushProps`), resolved.
public struct Brush: Hashable, Sendable {
    public var mode: BrushMode
    /// Paint: 1 ... 500 copies.
    public var count: Int
    /// Painted bottom first; symbols that were deleted are simply absent.
    public var symbols: [BrushSymbol]
    public var orientOnPath: Bool
    public var foldCorners: Bool
    /// Percent of the symbol's length between copies (Spray).
    public var spacing: BrushVariation
    /// Degrees.
    public var angle: BrushVariation
    /// Percent of the symbol's height off the path.
    public var offset: BrushVariation
    /// Percent.
    public var scaling: BrushVariation

    public init(
        mode: BrushMode = .spray,
        count: Int = 1,
        symbols: [BrushSymbol],
        orientOnPath: Bool = true,
        foldCorners: Bool = false,
        spacing: BrushVariation = .fixed(100),
        angle: BrushVariation = .fixed(0),
        offset: BrushVariation = .fixed(0),
        scaling: BrushVariation = .fixed(100)
    ) {
        self.mode = mode
        self.count = count
        self.symbols = symbols
        self.orientOnPath = orientOnPath
        self.foldCorners = foldCorners
        self.spacing = spacing
        self.angle = angle
        self.offset = offset
        self.scaling = scaling
    }
}

/// A Brush stroke (`BrushStroke`).
public struct BrushStroke: Hashable, Sendable {
    /// Nil when the brush node is gone: the stroke draws its cached Basic stroke.
    public var brush: Brush?
    /// 1 ... 400.
    public var widthPercent: Double
    /// Random and Variable draws come from a PCG generator seeded with this (D-022).
    public var seed: UInt64

    public init(brush: Brush?, widthPercent: Double = 100, seed: UInt64 = 0) {
        self.brush = brush
        self.widthPercent = widthPercent
        self.seed = seed
    }

    /// The brush when it has a symbol that paints; nil means draw the cached Basic stroke.
    var liveBrush: Brush? {
        guard var brush, brush.symbols.contains(where: { $0.bounds != nil }) else {
            return nil
        }
        brush.symbols = brush.symbols.filter { $0.bounds != nil }
        return brush
    }

    /// `widthPercent` clamped to 1 ... 400, as a factor.
    var widthFactor: Double {
        min(max(widthPercent.isFinite ? widthPercent : 100, 1), 400) / 100
    }
}

// MARK: - Calligraphic strokes

/// A calligraphic nib (`CalligraphicStroke`'s width, height, angle and nib).
public struct CalligraphicNib: Hashable, Sendable {
    public var width: Double
    public var height: Double
    /// Degrees.
    public var angle: Double
    /// A custom nib: one closed contour in nib units (1 = `width` / `height` before scaling),
    /// centred on the origin.  Nil, or anything but a single closed contour, is the ellipse.
    public var shape: DisplayPath?

    public init(width: Double, height: Double, angle: Double = 0, shape: DisplayPath? = nil) {
        self.width = width
        self.height = height
        self.angle = angle
        self.shape = shape
    }
}

// MARK: - Custom strokes

/// `CustomStrokePattern`: the 23 named patterns.
public enum CustomStrokePattern: Hashable, Sendable, CaseIterable {
    case arrow, ball, braid, cartographer, checker, crepe, diamond, dot, heart, leftDiagonal
    case neon, rectangle, rightDiagonal, roman, snowflake, squiggle, star, swirl, teeth
    case threeWaves, twoWaves, wedge, zigzag
}

/// A Custom stroke (`CustomStroke`); the width is the stroke's `style.width`.
public struct CustomStroke: Hashable, Sendable {
    public var pattern: CustomStrokePattern
    /// One tile along the path; 0 reads as twice the width.
    public var length: Double
    /// The gap between tiles.
    public var spacing: Double

    public init(pattern: CustomStrokePattern, length: Double = 0, spacing: Double = 0) {
        self.pattern = pattern
        self.length = length
        self.spacing = spacing
    }
}
