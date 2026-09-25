import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The cell ↔ pasteboard map of one grid plane, for the grid overlay and the Perspective tool
/// (perspective.adoc, "Projection", "Grid overlay").  The same homography WTRender's
/// `PlaneProjector` projects attached objects with -- its near origin and two axes, each receding
/// toward a vanishing point (s cells land at N + (A − N)·s·c / (s·c + |A − N|)) or parallel to a
/// direction -- rebuilt here because the projector is internal to WTRender; the tests hold the two
/// to the same points through an attached object's drawing.
struct PlaneMap: Equatable {
    /// Row-major 3 × 3, applied to (u, v, 1).
    let m: [Double]

    init(m: [Double]) {
        self.m = m
    }

    /// The map of `plane` on `grid` (the plane as the grid reads it).
    init(_ grid: PerspectiveGridSpec, plane: PerspectiveSpec.Plane) {
        let (origin, u, v) = Self.axes(grid, plane: PerspectiveSpec(grid: grid, plane: plane).effectivePlane)
        let cell = grid.effectiveCellSize
        func column(_ axis: Axis) -> (x: Double, y: Double, w: Double) {
            switch axis {
            case .vanishing(let point, let sign):
                let k = cell * sign / max(point.distance(to: origin), 1e-6)
                return (point.x * k, point.y * k, k)
            case .direction(let direction):
                return (direction.dx * cell, direction.dy * cell, 0)
            }
        }
        let cu = column(u), cv = column(v)
        m = [cu.x, cv.x, origin.x, cu.y, cv.y, origin.y, cu.w, cv.w, 1]
    }

    enum Axis {
        case vanishing(Point, sign: Double)
        case direction(Vector)
    }

    static func axes(_ grid: PerspectiveGridSpec, plane: PerspectiveSpec.Plane) -> (origin: Point, u: Axis, v: Axis) {
        let up = Vector(0, -1)
        let front = grid.floorFrontY
        func vertical(from origin: Point) -> Axis {
            guard grid.effectiveVanishingPoints == 3 else { return .direction(up) }
            return .vanishing(grid.verticalVP, sign: grid.verticalVP.y < origin.y ? 1 : -1)
        }
        switch plane {
        case .leftWall:
            let origin = Point(x: grid.leftWallX, y: front)
            return (origin, .vanishing(grid.leftVP, sign: -1), vertical(from: origin))
        case .rightWall:
            let origin = Point(x: grid.rightWallX, y: front)
            return (origin, .vanishing(grid.rightVP, sign: 1), vertical(from: origin))
        case .floorRight:
            let origin = Point(x: (grid.leftWallX + grid.rightWallX) / 2, y: front)
            return (origin, .vanishing(grid.rightVP, sign: 1), .vanishing(grid.leftVP, sign: 1))
        case .floorLeft:
            let origin = Point(x: (grid.leftWallX + grid.rightWallX) / 2, y: front)
            return (origin, .vanishing(grid.leftVP, sign: -1), .vanishing(grid.rightVP, sign: 1))
        case .wall:
            return (Point(x: grid.leftWallX, y: front), .direction(Vector(1, 0)), .direction(up))
        case .floor:
            return (Point(x: grid.leftWallX, y: front), .direction(Vector(1, 0)), .vanishing(grid.leftVP, sign: 1))
        }
    }

    /// The denominator at cell `point`: positive in front of the horizon.
    func weight(_ point: Point) -> Double {
        m[6] * point.x + m[7] * point.y + m[8]
    }

    /// Cell → pasteboard.
    func apply(_ point: Point) -> Point {
        let w = weight(point)
        let safe = abs(w) < 1e-12 ? (w < 0 ? -1e-12 : 1e-12) : w
        return Point(x: (m[0] * point.x + m[1] * point.y + m[2]) / safe, y: (m[3] * point.x + m[4] * point.y + m[5]) / safe)
    }

    /// Pasteboard → cell; nil for a degenerate grid.
    var inverted: PlaneMap? {
        let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
        let A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g
        let determinant = a * A + b * B + c * C
        guard abs(determinant) > 1e-15 else { return nil }
        let D = -(b * i - c * h), E = a * i - c * g, F = -(a * h - b * g)
        let G = b * f - c * e, H = -(a * f - c * d), I = a * e - b * d
        return PlaneMap(m: [A, D, G, B, E, H, C, F, I].map { $0 / determinant })
    }

    /// The cell under pasteboard point `point`; nil for a degenerate grid.
    func cell(at point: Point) -> Point? {
        inverted?.apply(point)
    }
}

/// What the grid overlay draws for one page (perspective.adoc, "Grid overlay"): the horizon, the
/// vanishing points and every unhidden plane's lines in its colour, `extent` cells each way (fewer
/// on an axis running toward the viewer, which stops short of the horizon's far side).
struct PerspectiveGridDrawing: Equatable {
    struct Plane: Equatable {
        let plane: PerspectiveSpec.Plane
        let color: Color
        /// Line segments, pasteboard space.
        let lines: [(Point, Point)]

        static func == (lhs: Plane, rhs: Plane) -> Bool {
            lhs.plane == rhs.plane && lhs.color == rhs.color && lhs.lines.map { [$0.0, $0.1] } == rhs.lines.map { [$0.0, $0.1] }
        }
    }

    static let extent = 12
    static let leftColor = Color(red: 0.85, green: 0.2, blue: 0.2)
    static let rightColor = Color(red: 0.2, green: 0.35, blue: 0.9)
    static let floorColor = Color(red: 0.15, green: 0.6, blue: 0.3)

    let page: Rect
    let spec: PerspectiveGridSpec
    let grid: OpID?
    let planes: [Plane]
    /// The vanishing points drawn, each with the grid field it is stored in.
    let vanishingPoints: [(point: Point, field: PerspectiveFields.GridField)]
    /// The hidden flags (double-click on a vanishing point or the horizon).
    let leftHidden: Bool
    let rightHidden: Bool
    let floorHidden: Bool

    static func == (lhs: PerspectiveGridDrawing, rhs: PerspectiveGridDrawing) -> Bool {
        lhs.page == rhs.page && lhs.spec == rhs.spec && lhs.grid == rhs.grid && lhs.planes == rhs.planes
            && lhs.vanishingPoints.map(\.point) == rhs.vanishingPoints.map(\.point)
    }

    /// How many cells an axis reaches before it would cross the horizon.
    static func reach(_ axis: PlaneMap.Axis, origin: Point, cell: Double) -> Double {
        guard case .vanishing(let point, let sign) = axis, sign < 0 else { return Double(extent) }
        return min(Double(extent), 0.9 * point.distance(to: origin) / cell)
    }

    /// The lines of `plane`.
    static func lines(_ spec: PerspectiveGridSpec, plane: PerspectiveSpec.Plane) -> [(Point, Point)] {
        let effective = PerspectiveSpec(grid: spec, plane: plane).effectivePlane
        let map = PlaneMap(spec, plane: effective)
        let (origin, u, v) = PlaneMap.axes(spec, plane: effective)
        let cell = spec.effectiveCellSize
        let maxU = reach(u, origin: origin, cell: cell), maxV = reach(v, origin: origin, cell: cell)
        var result: [(Point, Point)] = []
        for i in 0...Int(maxU.rounded(.down)) {
            result.append((map.apply(Point(x: Double(i), y: 0)), map.apply(Point(x: Double(i), y: maxV))))
        }
        for j in 0...Int(maxV.rounded(.down)) {
            result.append((map.apply(Point(x: 0, y: Double(j))), map.apply(Point(x: maxU, y: Double(j)))))
        }
        return result
    }

    /// The overlay of `page` (its grid, or the built-in default when it uses none).
    init(page: Page, state: EngineState) {
        let grid = PerspectiveReading.grid(of: page, in: state)
        let stored = PerspectiveReading.grids(state).first { $0.id == grid }?.stored ?? Wiretuner_Doc_V1_PerspectiveGrid()
        let spec = PerspectiveReading.spec(grid: grid, page: page.rect, in: state)
        self.page = page.rect
        self.spec = spec
        self.grid = grid
        leftHidden = stored.leftHidden
        rightHidden = stored.rightHidden
        floorHidden = stored.floorHidden
        let resolver = ColorResolver(state)
        func plane(_ plane: PerspectiveSpec.Plane, _ ref: Wiretuner_Doc_V1_ColorRef, _ fallback: Color) -> Plane {
            Plane(plane: plane, color: resolver.color(ref) ?? fallback, lines: Self.lines(spec, plane: plane))
        }
        let onePoint = spec.effectiveVanishingPoints == 1
        var planes: [Plane] = []
        if !stored.leftHidden { planes.append(plane(onePoint ? .wall : .leftWall, stored.leftColor, Self.leftColor)) }
        if !stored.rightHidden && !onePoint { planes.append(plane(.rightWall, stored.rightColor, Self.rightColor)) }
        if !stored.floorHidden { planes.append(plane(onePoint ? .floor : .floorRight, stored.floorColor, Self.floorColor)) }
        self.planes = planes
        var points: [(point: Point, field: PerspectiveFields.GridField)] = [(spec.leftVP, .leftVP)]
        if !onePoint { points.append((spec.rightVP, .rightVP)) }
        if spec.effectiveVanishingPoints == 3 { points.append((spec.verticalVP, .verticalVP)) }
        vanishingPoints = points
    }
}

/// Page coordinates (points from the page's bottom-left, y up), as grids store them.
enum PerspectivePageCoordinates {
    static func stored(_ point: Point, page: Rect) -> Wiretuner_Doc_V1_Point {
        var value = Wiretuner_Doc_V1_Point()
        value.x = point.x - page.minX
        value.y = page.maxY - point.y
        return value
    }

    static func horizon(_ y: Double, page: Rect) -> Double {
        page.maxY - y
    }
}
