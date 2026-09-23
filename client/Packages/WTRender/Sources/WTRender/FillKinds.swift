// The fill kinds beyond Basic, as display-list values (ATTR-018, ATTR-019, ATTR-021, ATTR-027,
// ATTR-014; docs/_includes/appearance/fill-attributes.adoc and gradients.adoc).  They mirror
// `fill.proto`, `gradient.proto` and `stroke.proto`'s `PatternBitmap` with every reference
// resolved: colours are values, embedded subtrees are display items in object-local space, and
// the read-time normalizations of those pages are applied here, so WTModel only copies fields.
// WTRender does not import WTProto.

import WTGeometry

// MARK: - Gradients

/// A gradient fill (`GradientFill`).
public struct Gradient: Hashable, Sendable {
    /// `GradientType`; unspecified reads as linear.
    public enum Kind: Hashable, Sendable, CaseIterable {
        case linear
        case logarithmic
        case radial
        case rectangle
        case contour
        case cone
    }

    /// `GradientBehavior`; unspecified reads as normal.
    public enum Behavior: Hashable, Sendable, CaseIterable {
        case normal
        case `repeat`
        case reflect
        case autoSize
    }

    /// One colour stop: `offset` along the ramp, 0...1.
    public struct Stop: Hashable, Sendable {
        public var offset: Double
        public var color: Color

        public init(offset: Double, color: Color) {
            self.offset = offset
            self.color = color
        }
    }

    /// The handles in object-local coordinates (`GradientAxis`).
    public struct Axis: Hashable, Sendable {
        public var start: Point
        public var end: Point
        /// Radial and Rectangle only; nil reads as `end - start` rotated 90°.
        public var end2: Point?

        public init(start: Point, end: Point, end2: Point? = nil) {
            self.start = start
            self.end = end
            self.end2 = end2
        }
    }

    public var kind: Kind
    public var behavior: Behavior
    /// Repeat and Reflect: 1 ... 100; 0 reads 1.
    public var repeatCount: Int
    /// Nil reads as Auto size geometry regardless of `behavior`.
    public var axis: Axis?
    /// The live stops in any order; the ramp sorts them by offset.
    public var stops: [Stop]

    public init(kind: Kind = .linear, behavior: Behavior = .normal, repeatCount: Int = 1, axis: Axis? = nil, stops: [Stop]) {
        self.kind = kind
        self.behavior = behavior
        self.repeatCount = repeatCount
        self.axis = axis
        self.stops = stops
    }

    /// A two-stop gradient from `from` to `to`.
    public init(_ kind: Kind = .linear, from: Color, to: Color, behavior: Behavior = .normal, repeatCount: Int = 1, axis: Axis? = nil) {
        self.init(kind: kind, behavior: behavior, repeatCount: repeatCount, axis: axis, stops: [Stop(offset: 0, color: from), Stop(offset: 1, color: to)])
    }

    /// The ramp order: offsets clamped to 0...1, sorted by offset (ties keep their order, the
    /// element-id order WTModel supplies).
    public var sortedStops: [Stop] {
        stops.enumerated()
            .map { (index: $0.offset, stop: Stop(offset: min(max($0.element.offset.isFinite ? $0.element.offset : 0, 0), 1), color: $0.element.color)) }
            .sorted { $0.stop.offset != $1.stop.offset ? $0.stop.offset < $1.stop.offset : $0.index < $1.index }
            .map(\.stop)
    }

    /// The count Repeat and Reflect use: 1 ... 100.
    public var effectiveRepeatCount: Int {
        min(max(repeatCount, 1), 100)
    }
}

// MARK: - Pattern bitmaps

/// An 8 × 8 one-bit pattern (`PatternBitmap`): eight rows, most significant bit the left pixel,
/// 1 painted.  Shared by Pattern strokes and Pattern fills; each pixel is 0.25 pt on the page.
public struct PatternBitmap: Hashable, Sendable {
    public var rows: [UInt8]

    /// Rows beyond eight are dropped and missing rows read as clear.
    public init(rows: [UInt8]) {
        self.rows = Array((rows + Array(repeating: 0, count: 8)).prefix(8))
    }

    /// Whether pixel (`x`, `y`) is painted, (0, 0) the top-left.
    public func isPainted(x: Int, y: Int) -> Bool {
        guard (0..<8).contains(x), (0..<8).contains(y) else {
            return false
        }
        return rows[y] & (0x80 >> UInt8(x)) != 0
    }

    public var isEmpty: Bool { rows.allSatisfy { $0 == 0 } }

    /// A checkerboard of single pixels.
    public static let checker = PatternBitmap(rows: [0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55])
    /// Diagonal lines rising to the right.
    public static let diagonal = PatternBitmap(rows: [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80])
    /// Horizontal lines every other row.
    public static let horizontal = PatternBitmap(rows: [0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00])
    /// A sparse dot every fourth pixel.
    public static let dots = PatternBitmap(rows: [0x88, 0x00, 0x22, 0x00, 0x88, 0x00, 0x22, 0x00])
    /// Every pixel painted.
    public static let solid = PatternBitmap(rows: Array(repeating: 0xFF, count: 8))
}

/// A Pattern fill or stroke paint: the bitmap's painted pixels in `color`, clear ones
/// transparent.
public struct PatternPaint: Hashable, Sendable {
    /// Pattern pixels per point: each pixel is a quarter point on the page.
    public static let pixelSize = 0.25

    public var bitmap: PatternBitmap
    public var color: Color

    public init(bitmap: PatternBitmap, color: Color) {
        self.bitmap = bitmap
        self.color = color
    }
}

// MARK: - Custom and Textured fills

/// `CustomFillPattern`.
public enum CustomFillPattern: Hashable, Sendable, CaseIterable {
    case blackWhiteNoise
    case bricks
    case circles
    case hatch
    case noise
    case randomGrass
    case randomLeaves
    case squares
    case tigerTeeth
    case topNoise

    /// Opaque patterns hide what is behind the object; the others draw only their marks.
    public var isOpaque: Bool {
        switch self {
        case .blackWhiteNoise, .bricks, .noise, .tigerTeeth: return true
        case .circles, .hatch, .randomGrass, .randomLeaves, .squares, .topNoise: return false
        }
    }
}

/// A Custom fill (`CustomFill`).  Lengths are points on the page; angles degrees, clockwise
/// positive.  A zero length reads as the pattern's default.
public struct CustomFill: Hashable, Sendable {
    public var pattern: CustomFillPattern
    /// Bricks, Circles, Hatch, Squares, Tiger Teeth.
    public var color: Color
    /// Bricks mortar; Tiger Teeth background.
    public var color2: Color
    /// Bricks width; Hatch line width; Squares outline width.
    public var width: Double
    /// Bricks height.
    public var height: Double
    /// Circles.
    public var radius: Double
    /// Squares.
    public var side: Double
    /// Circles, Hatch, Squares: distance between centres or lines.
    public var spacing: Double
    public var angle: Double
    /// Hatch's second set of lines.
    public var angle2: Double
    /// Noise and Top Noise: 0 ... 100.
    public var whiteness: Double
    /// Grass and Leaves 1 ... 32,000; Tiger Teeth 1 ... 700.
    public var count: Int
    /// Grass and Leaves placement, fixed when the fill is created (D-022).
    public var seed: UInt64

    public init(
        pattern: CustomFillPattern,
        color: Color = .black,
        color2: Color = .white,
        width: Double = 0,
        height: Double = 0,
        radius: Double = 0,
        side: Double = 0,
        spacing: Double = 0,
        angle: Double = 0,
        angle2: Double = 0,
        whiteness: Double = 50,
        count: Int = 0,
        seed: UInt64 = 0
    ) {
        self.pattern = pattern
        self.color = color
        self.color2 = color2
        self.width = width
        self.height = height
        self.radius = radius
        self.side = side
        self.spacing = spacing
        self.angle = angle
        self.angle2 = angle2
        self.whiteness = whiteness
        self.count = count
        self.seed = seed
    }
}

/// `Texture`.
public enum Texture: Hashable, Sendable, CaseIterable {
    case burlap
    case denim
    case gravel
    case marble
    case mesh
    case oak
    case sand
    case stucco
}

/// A Textured fill (`TexturedFill`): a fixed texture in one colour at a fixed page size.
public struct TexturedFill: Hashable, Sendable {
    public var texture: Texture
    public var color: Color

    public init(texture: Texture, color: Color) {
        self.texture = texture
        self.color = color
    }
}

// MARK: - Tiled fills

/// A Tiled fill (`TiledFill`): the tile artwork (the embedded `Subtree`, as display items in
/// tile coordinates) repeated across the interior in object-local space.
public struct TiledFill: Hashable, Sendable {
    public var tile: [DisplayItem]
    /// Degrees.
    public var angle: Double
    /// Percent; 0 reads 100.
    public var scaleX: Double
    public var scaleY: Double
    /// Shift of the pattern in object-local points.
    public var offset: Point

    public init(tile: [DisplayItem], angle: Double = 0, scaleX: Double = 100, scaleY: Double = 100, offset: Point = .zero) {
        self.tile = tile
        self.angle = angle
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.offset = offset
    }

    /// The tile's bounds -- its artwork's geometry, strokes not included -- as one pattern
    /// cell before scaling.  Nil for a tile with no area, which renders as None.
    public var tileBounds: Rect? {
        DisplayList.union(of: tile.compactMap(\.geometricBounds)).flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
    }

    var effectiveScale: (x: Double, y: Double) {
        func read(_ value: Double) -> Double {
            value.isFinite && value > 0 ? value / 100 : 1
        }
        return (read(scaleX), read(scaleY))
    }
}

// MARK: - Lens fills

/// `LensType`.
public enum LensType: Hashable, Sendable, CaseIterable {
    case transparency
    case magnify
    case invert
    case lighten
    case darken
    case monochrome
}

/// A Lens fill (`LensFill`): the object becomes a window altering what is beneath it.
public struct LensFill: Hashable, Sendable {
    public var type: LensType
    /// Transparency and Monochrome.
    public var color: Color
    /// Transparency opacity, Lighten, Darken: 0 ... 100.
    public var amount: Double
    /// Magnify: 1 ... 20.
    public var magnification: Double
    /// Object-local; nil is the object's bounds centre.
    public var centerpoint: Point?
    /// Alter only what objects paint, leaving empty page untouched.
    public var objectsOnly: Bool
    /// When set, the captured contents (object-local display items) replace the live backdrop.
    public var snapshot: [DisplayItem]?

    public init(
        type: LensType,
        color: Color = .black,
        amount: Double = 50,
        magnification: Double = 2,
        centerpoint: Point? = nil,
        objectsOnly: Bool = false,
        snapshot: [DisplayItem]? = nil
    ) {
        self.type = type
        self.color = color
        self.amount = amount
        self.magnification = magnification
        self.centerpoint = centerpoint
        self.objectsOnly = objectsOnly
        self.snapshot = snapshot
    }

    /// `amount` clamped to 0 ... 100, as a fraction.
    var fraction: Double {
        min(max(amount.isFinite ? amount : 0, 0), 100) / 100
    }

    /// `magnification` clamped to 1 ... 20.
    var effectiveMagnification: Double {
        min(max(magnification.isFinite ? magnification : 1, 1), 20)
    }

    /// What the lens renders as where a lens cannot be drawn (past the nesting cap, inside a
    /// tile or brush symbol): a Basic fill of `color` at `amount` percent tint.
    var basicColor: Color {
        let t = fraction
        return Color(
            red: 1 - t * (1 - color.red),
            green: 1 - t * (1 - color.green),
            blue: 1 - t * (1 - color.blue),
            alpha: color.alpha
        )
    }
}
