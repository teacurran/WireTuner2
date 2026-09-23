// Perspective planes (FX-042; perspective.adoc, "Projection"): the 2D homography from cell
// coordinates (u, v) on a grid plane to pasteboard space.  Each plane has a near origin N and two
// axes; an axis either recedes toward a vanishing point A -- a distance of s cells along it lands
// at N + (A − N) · s·c / (s·c + |A − N|), so the first cell at N is c long and the axis reaches A
// at infinity -- or runs parallel to a fixed direction (the verticals of two-point walls, the
// frontal plane of one-point grids).  Both kinds are columns of one projective matrix, so the map
// sends lines to lines and every receding grid line through its vanishing point.
//
// Planes (pasteboard y down, "up" is −y):
// * Two and three points.  Left wall: N = (left wall x, floor front y), u away from the left
//   vanishing point, v up (toward the vertical vanishing point on three-point grids).  Right
//   wall: N = (right wall x, floor front y), u toward the right vanishing point, v up.  Floors:
//   N = (the walls' mean x, floor front y); Floor right: u toward the right vanishing point, v
//   toward the left; Floor left: u away from the left vanishing point, v toward the right.
// * One point.  Wall: the frontal plane at N = (left wall x, floor front y), u right, v up.
//   Floor: u right, v toward the vanishing point.

import WTGeometry

/// A projective map of the plane: `m` row-major, applied to (x, y, 1).
struct Homography: Hashable, Sendable {
    var m: [Double]

    static let identity = Homography(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    func apply(_ point: Point) -> Point {
        let w = m[6] * point.x + m[7] * point.y + m[8]
        let safe = abs(w) < 1e-12 ? (w < 0 ? -1e-12 : 1e-12) : w
        return Point(x: (m[0] * point.x + m[1] * point.y + m[2]) / safe, y: (m[3] * point.x + m[4] * point.y + m[5]) / safe)
    }

    /// The denominator at `point`: positive on the side of the plane in front of the horizon.
    func weight(_ point: Point) -> Double {
        m[6] * point.x + m[7] * point.y + m[8]
    }

    var inverted: Homography? {
        let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
        let A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g
        let determinant = a * A + b * B + c * C
        guard abs(determinant) > 1e-15 else {
            return nil
        }
        let D = -(b * i - c * h), E = a * i - c * g, F = -(a * h - b * g)
        let G = b * f - c * e, H = -(a * f - c * d), I = a * e - b * d
        return Homography(m: [A, D, G, B, E, H, C, F, I].map { $0 / determinant })
    }
}

enum PlaneProjector {
    /// One axis of a plane.
    enum Axis {
        /// Toward (`sign` +1) or away from (−1) a vanishing point.
        case vanishing(Point, sign: Double)
        /// Parallel to a unit direction.
        case direction(Vector)
    }

    /// The cell → pasteboard homography of `plane` on `grid`.
    static func homography(_ grid: PerspectiveGridSpec, plane: PerspectiveSpec.Plane) -> Homography {
        let (origin, u, v) = axes(grid, plane: plane)
        let cell = grid.effectiveCellSize
        func column(_ axis: Axis) -> (x: Double, y: Double, w: Double) {
            switch axis {
            case .vanishing(let point, let sign):
                let distance = max(point.distance(to: origin), 1e-6)
                let k = cell * sign / distance
                return (point.x * k, point.y * k, k)
            case .direction(let direction):
                return (direction.dx * cell, direction.dy * cell, 0)
            }
        }
        let cu = column(u)
        let cv = column(v)
        return Homography(m: [cu.x, cv.x, origin.x, cu.y, cv.y, origin.y, cu.w, cv.w, 1])
    }

    static func axes(_ grid: PerspectiveGridSpec, plane: PerspectiveSpec.Plane) -> (origin: Point, u: Axis, v: Axis) {
        let up = Vector(0, -1)
        let front = grid.floorFrontY
        let threePoint = grid.effectiveVanishingPoints == 3
        func vertical(from origin: Point) -> Axis {
            guard threePoint else { return .direction(up) }
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
}

/// An attached object's placement: its flat bounds onto its cell rectangle, then the plane.
struct PerspectivePlacement: Hashable, Sendable {
    let homography: Homography
    let flat: Rect
    let cells: Rect
    let flipU: Bool
    let flipV: Bool

    init?(_ spec: PerspectiveSpec, flat: Rect) {
        guard !flat.isNull, flat.width > 0 || flat.height > 0 else {
            return nil
        }
        let plane = spec.effectivePlane
        let cell = spec.grid.effectiveCellSize
        homography = PlaneProjector.homography(spec.grid, plane: plane)
        self.flat = flat
        let width = spec.cellWidth > 0 && spec.cellWidth.isFinite ? spec.cellWidth : flat.width / cell
        let height = spec.cellHeight > 0 && spec.cellHeight.isFinite ? spec.cellHeight : flat.height / cell
        let position = spec.cellPosition.isFinite ? spec.cellPosition : .zero
        cells = Rect(x: position.x, y: position.y, width: width, height: height)
        let isFloor = plane == .floor || plane == .floorLeft || plane == .floorRight
        flipU = spec.flipped && !isFloor
        flipV = spec.flipped && isFloor
    }

    /// A flat point's cell coordinates (v up: the flat top is the cell rectangle's top).
    func cell(of point: Point) -> Point {
        var fu = flat.width > 0 ? (point.x - flat.minX) / flat.width : 0
        var fv = flat.height > 0 ? (flat.maxY - point.y) / flat.height : 0
        if flipU { fu = 1 - fu }
        if flipV { fv = 1 - fv }
        return Point(x: cells.minX + fu * cells.width, y: cells.minY + fv * cells.height)
    }

    func map(_ point: Point) -> Point {
        homography.apply(cell(of: point))
    }

    /// The flat point that projects to `point`, for caret placement in attached text.
    func inverse(_ point: Point) -> Point? {
        guard let back = homography.inverted else {
            return nil
        }
        let c = back.apply(point)
        var fu = cells.width > 0 ? (c.x - cells.minX) / cells.width : 0
        var fv = cells.height > 0 ? (c.y - cells.minY) / cells.height : 0
        if flipU { fu = 1 - fu }
        if flipV { fv = 1 - fv }
        return Point(x: flat.minX + fu * flat.width, y: flat.maxY - fv * flat.height)
    }
}

enum PerspectiveResolver {
    static func entries(_ spec: PerspectiveSpec, children: [DisplayItem]) -> [DerivedGroup.Entry] {
        guard let first = children.first,
              let placement = PerspectivePlacement(spec, flat: first.geometricBounds ?? .null)
        else {
            return children.enumerated().map { DerivedGroup.Entry(item: $0.element, origin: $0.offset) }
        }
        var entries: [DerivedGroup.Entry] = []
        if let projected = WarpSource.mapped(WarpSource.plainPaths(first), map: placement.map) {
            entries.append(DerivedGroup.Entry(item: projected, origin: 0))
        }
        // More than one live child: the others render flat above it.
        for (index, child) in children.enumerated().dropFirst() {
            entries.append(DerivedGroup.Entry(item: child, origin: index))
        }
        return entries
    }
}
