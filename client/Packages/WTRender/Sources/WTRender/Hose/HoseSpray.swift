// The Graphic Hose's spray layout (DRAW-038/DRAW-039; docs/_includes/drawing/graphic-hose.adoc,
// "Client"): where each object of a stroke lands, which object it is, and its scale and rotation.
// Pure geometry: the tool feeds it the drag samples, draws a preview of each placement in the
// overlay, and on mouse-up hands the placements to WTModel's `SprayHose`, which writes them as
// concrete transforms (so every replica sees the same random choices).

import WTGeometry

/// A hose's options as the sprayer reads them (`HoseOptions` after the read normalizations).
public struct HoseSprayOptions: Hashable, Sendable {
    public enum Order: Hashable, Sendable, CaseIterable { case loop, backAndForth, random }
    public enum Spacing: Hashable, Sendable, CaseIterable { case grid, variable, random }
    public enum Scale: Hashable, Sendable, CaseIterable { case uniform, random }
    public enum Rotation: Hashable, Sendable, CaseIterable { case uniform, incremental, random }

    /// The grid size an unset or non-positive `grid_size` reads as.
    public static let defaultGridSize = 36.0

    public var order: Order
    public var spacing: Spacing
    /// Grid cell size, points (> 0).
    public var gridSize: Double
    /// Variable: tight (0) to loose (200); random: the deviation, 0 ... 200.
    public var spacingAmount: Double
    public var scale: Scale
    /// Uniform: the scale; random: the largest.  1 ... 200 percent.
    public var scalePercent: Double
    public var rotation: Rotation
    /// Uniform: the angle; incremental: the step.  Radians.
    public var angle: Double

    public init(order: Order = .loop, spacing: Spacing = .variable, gridSize: Double = defaultGridSize, spacingAmount: Double = 0,
                scale: Scale = .uniform, scalePercent: Double = 100, rotation: Rotation = .uniform, angle: Double = 0) {
        self.order = order
        self.spacing = spacing
        self.gridSize = gridSize.isFinite && gridSize > 0 ? gridSize : Self.defaultGridSize
        self.spacingAmount = spacingAmount.isFinite ? min(max(spacingAmount, 0), 200) : 0
        self.scale = scale
        self.scalePercent = scalePercent.isFinite && scalePercent != 0 ? min(max(scalePercent, 1), 200) : 100
        self.rotation = rotation
        self.angle = angle.isFinite ? angle : 0
    }
}

/// One sprayed object: which of the set's objects (an index into its first ten live children),
/// where its centre lands (pasteboard), and its scale and rotation.
public struct HosePlacement: Hashable, Sendable {
    public var index: Int
    public var center: Point
    /// The scale factor (1 is 100%).
    public var scale: Double
    /// Radians.
    public var rotation: Double

    public init(index: Int, center: Point, scale: Double, rotation: Double) {
        self.index = index
        self.center = center
        self.scale = scale
        self.rotation = rotation
    }

    /// Object space (the hose object centred on the origin) → pasteboard: scale, then rotate, then
    /// move to `center`.
    public var transform: AffineTransform {
        AffineTransform.scale(scale).concatenating(.rotation(radians: rotation)).concatenating(.translation(x: center.x, y: center.y))
    }
}

/// A small seeded generator (SplitMix64), so a stroke's random choices can be replayed in tests.
public struct HoseRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The layout of one spray stroke.
///
/// * Spacing -- *variable*: the distance between objects is `extent × (0.1 + amount / 100)`
///   times the speed factor, the drag speed over 400 pt/s clamped to 0.5 ... 3 (faster spreads
///   them out); *random*: `extent` times the speed factor times `1 + u × amount / 200` for a
///   uniform `u` in −1 ... 1 (at least 0.1 × extent); *grid*: one object per grid cell the drag
///   enters, centred in the cell, whatever the speed.  The press itself places the first object.
/// * Order -- loop `k mod n`; back and forth `0, 1, …, n−1, n−2, …, 1, 0, 1, …`; random any.
/// * Scale -- uniform `percent / 100`; random uniform in `0.01 ... percent / 100`.
/// * Rotation -- uniform `angle`; incremental `k × angle` (the first object unrotated); random
///   uniform in `0 ..< 2π`.
/// * Keys -- Left tightens and Right loosens the spacing (× 0.8, × 1.25), Up shrinks and Down
///   enlarges the objects (× 0.8, × 1.25), from the next object on; both multipliers stay in
///   0.05 ... 20.
public struct HoseSprayer: Sendable {
    public let options: HoseSprayOptions
    /// How many objects the set sprays (its first ten live children); 0 places nothing.
    public let objectCount: Int
    /// The objects' size in points at 100% (the largest side of their bounds): the unit of the
    /// variable and random spacing.
    public let extent: Double
    public private(set) var spacingMultiplier = 1.0
    public private(set) var scaleMultiplier = 1.0
    /// Every placement of the stroke so far, in order.
    public private(set) var placements: [HosePlacement] = []

    private var random: HoseRandom
    private var last: (point: Point, time: Double)?
    private var travelled = 0.0
    private var nextDistance = 0.0
    private var cells: Set<[Int]> = []

    public init(options: HoseSprayOptions, objectCount: Int, extent: Double, seed: UInt64) {
        self.options = options
        self.objectCount = min(max(objectCount, 0), 10)
        self.extent = extent.isFinite && extent > 1 ? extent : 1
        random = HoseRandom(seed: seed)
    }

    // MARK: The stroke

    /// The press: places the first object (at the press point, or the centre of its grid cell).
    @discardableResult
    public mutating func begin(at point: Point, time: Double) -> [HosePlacement] {
        last = (point, time)
        travelled = 0
        if options.spacing == .grid { return enter(point) }
        // The distance to the next object depends on the speed of the drag that reaches it.
        nextDistance = .nan
        return place(at: point)
    }

    /// A drag sample: the placements the segment from the previous sample reached.
    @discardableResult
    public mutating func drag(to point: Point, time: Double) -> [HosePlacement] {
        guard let previous = last else { return begin(at: point, time: time) }
        last = (point, time)
        let length = previous.point.distance(to: point)
        guard length > 0 else { return [] }
        var result: [HosePlacement] = []
        if options.spacing == .grid {
            let step = max(gridSize / 4, 0.5)
            let count = Int((length / step).rounded(.up))
            for i in 1...count {
                result += enter(Point.lerp(previous.point, point, Double(i) / Double(count)))
            }
            return result
        }
        let speed = length / max(time - previous.time, 0.001)
        if nextDistance.isNaN { nextDistance = distance(speed: speed) }
        var covered = 0.0
        while travelled + (length - covered) >= nextDistance {
            covered += nextDistance - travelled
            result += place(at: Point.lerp(previous.point, point, covered / length))
            travelled = 0
            nextDistance = distance(speed: speed)
        }
        travelled += length - covered
        return result
    }

    /// kbd:[Left]: tighter spacing from here on.
    public mutating func tighten() { spacingMultiplier = Self.clamp(spacingMultiplier * 0.8) }
    /// kbd:[Right]: looser spacing from here on.
    public mutating func loosen() { spacingMultiplier = Self.clamp(spacingMultiplier * 1.25) }
    /// kbd:[Up]: smaller objects from here on.
    public mutating func shrink() { scaleMultiplier = Self.clamp(scaleMultiplier * 0.8) }
    /// kbd:[Down]: larger objects from here on.
    public mutating func enlarge() { scaleMultiplier = Self.clamp(scaleMultiplier * 1.25) }

    // MARK: Pieces

    private static func clamp(_ value: Double) -> Double { min(max(value, 0.05), 20) }

    private var gridSize: Double { options.gridSize * spacingMultiplier }

    /// The speed factor: faster drags spread the objects out.
    static func speedFactor(_ speed: Double) -> Double { min(max(speed / 400, 0.5), 3) }

    /// The distance to the next object after one placed at `speed` pt/s.
    private mutating func distance(speed: Double) -> Double {
        let factor = Self.speedFactor(speed) * spacingMultiplier
        switch options.spacing {
        case .random:
            let u = Double.random(in: -1...1, using: &random)
            return extent * factor * max(0.1, 1 + u * options.spacingAmount / 200)
        default:
            return extent * factor * (0.1 + options.spacingAmount / 100)
        }
    }

    /// Grid spacing: an object in the cell of `point` unless the stroke already has one there.
    private mutating func enter(_ point: Point) -> [HosePlacement] {
        let size = gridSize
        let cell = [Int((point.x / size).rounded(.down)), Int((point.y / size).rounded(.down))]
        guard cells.insert(cell).inserted else { return [] }
        return place(at: Point(x: (Double(cell[0]) + 0.5) * size, y: (Double(cell[1]) + 0.5) * size))
    }

    /// The next object at `center`.
    private mutating func place(at center: Point) -> [HosePlacement] {
        guard objectCount > 0 else { return [] }
        let k = placements.count
        let index: Int
        switch options.order {
        case .loop:
            index = k % objectCount
        case .backAndForth:
            let period = max(2 * (objectCount - 1), 1)
            let i = k % period
            index = objectCount == 1 ? 0 : (i < objectCount ? i : period - i)
        case .random:
            index = Int.random(in: 0..<objectCount, using: &random)
        }
        let top = options.scalePercent / 100
        let scale = (options.scale == .random ? Double.random(in: 0.01...top, using: &random) : top) * scaleMultiplier
        let rotation: Double
        switch options.rotation {
        case .uniform: rotation = options.angle
        case .incremental: rotation = Double(k) * options.angle
        case .random: rotation = Double.random(in: 0..<(2 * Double.pi), using: &random)
        }
        let placement = HosePlacement(index: index, center: center, scale: scale, rotation: rotation)
        placements.append(placement)
        return [placement]
    }
}
