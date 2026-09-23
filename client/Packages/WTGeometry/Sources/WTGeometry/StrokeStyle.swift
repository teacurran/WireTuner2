// GEO-003: the stroke attributes the outline of a Basic stroke depends on
// (`stroke-attributes`: `BasicStroke.cap`, `join`, `miter_limit`, `dash`).

/// How an open contour's ends are drawn (`LineCap`).
public enum LineCap: Hashable, Sendable, CaseIterable {
    /// Ends exactly at the path's end point.
    case butt
    /// A half-circle extends past the end point by half the width.
    case round
    /// A half-square extends past the end point by half the width.
    case square
}

/// How the corners where segments meet are drawn (`LineJoin`).
public enum LineJoin: Hashable, Sendable, CaseIterable {
    /// Corners come to a point, beveled when the point would exceed the miter limit.
    case miter
    /// Corners are rounded.
    case round
    /// Corners are cut off flat.
    case bevel
}

/// The geometry of a Basic stroke: everything ``Offset``
/// needs to turn a path into the filled region the stroke paints.
public struct StrokeStyle: Hashable, Sendable {
    /// Full width of the stroke; half of it lies on each side of the path.
    public var width: Double
    public var cap: LineCap
    public var join: LineJoin
    /// The longest a mitered corner may be, in stroke widths, before it is beveled.  Values
    /// below 1 act as 1 (the spec clamps stored values to 1...57; unset reads as 4).
    public var miterLimit: Double
    /// On, off, on, off... lengths; empty for a solid stroke.  An odd count repeats its cycle,
    /// and a pattern with no positive length (or any negative or non-finite one) is solid.
    public var dash: [Double]
    /// How far into the dash pattern the path's start point sits.
    public var dashPhase: Double

    public init(
        width: Double, cap: LineCap = .butt, join: LineJoin = .miter, miterLimit: Double = 4,
        dash: [Double] = [], dashPhase: Double = 0
    ) {
        self.width = width
        self.cap = cap
        self.join = join
        self.miterLimit = miterLimit
        self.dash = dash
        self.dashPhase = dashPhase
    }

    /// The dash pattern as the renderer reads it: an even number of lengths with a positive
    /// sum, or nil for a solid stroke (`stroke-attributes`, "Read-time normalizations").
    public var normalizedDash: [Double]? {
        guard !dash.isEmpty, dash.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return nil
        }
        let pattern = dash.count % 2 == 0 ? dash : dash + dash
        return pattern.reduce(0, +) > 0 ? pattern : nil
    }
}
