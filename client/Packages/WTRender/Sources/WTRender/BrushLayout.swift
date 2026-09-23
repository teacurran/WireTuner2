// Brush stroke layout (ATTR-010; docs/_includes/appearance/stroke-attributes.adoc, "Client"):
// the path is parametrized by arc length; Spray places copies at cumulative spacing, Paint
// divides the length by `count` and stretches each copy over its share; each copy is the
// symbol's display list placed by position, tangent (when oriented), scaling, offset along the
// normal and angle.  Random draws come from PCG32 seeded with the stroke's `seed`, four per
// copy position in a fixed order (spacing, angle, offset, scaling), so every replica, print and
// export lays out the same copies (D-022).

import WTGeometry
import Foundation

/// The copies of one brush stroke on one path, in the path's local space.
struct BrushLayout: Sendable {
    /// One placed copy: the symbol and symbol space → local space.
    struct Copy: Sendable {
        let symbol: Int
        let transform: AffineTransform
        let symbolBounds: Rect
    }

    /// Beyond this many copy positions a stroke stops placing more.
    static let maxPositions = 100_000

    let copies: [Copy]
    /// The copies' artwork, every copy of the first symbol below every copy of the second.
    let items: [DisplayItem]

    /// The union of the copies' placed symbol bounds; nil for no copies.
    var bounds: Rect? {
        DisplayList.union(of: copies.map { $0.symbolBounds.applying($0.transform) })
    }

    /// Each copy's symbol bounds as a closed contour in local space: what hit testing uses.
    var frames: [Contour] {
        copies.map { copy in
            let r = copy.symbolBounds
            return Contour(polygon: [
                Point(x: r.minX, y: r.minY), Point(x: r.maxX, y: r.minY),
                Point(x: r.maxX, y: r.maxY), Point(x: r.minX, y: r.maxY),
            ].map { copy.transform.apply($0) })
        }
    }

    private struct Key: Hashable, Sendable {
        let path: DisplayPath
        let stroke: BrushStroke
    }

    private static let cache = RenderCache<Key, BrushLayout>(capacity: 512)

    /// The layout of `stroke` on `path`, memoized.
    static func cached(path: DisplayPath, stroke: BrushStroke) -> BrushLayout {
        cache.value(for: Key(path: path, stroke: stroke)) {
            BrushLayout(path: path, stroke: stroke)
        }
    }

    init(path: DisplayPath, stroke: BrushStroke) {
        guard let brush = stroke.liveBrush else {
            copies = []
            items = []
            return
        }
        let symbolBounds = brush.symbols.map { $0.bounds! }
        let union = DisplayList.union(of: symbolBounds)!
        var placements: [AffineTransform] = []
        var random = PCG32(seed: stroke.seed)
        for piece in BrushLayout.pieces(of: path, foldCorners: brush.foldCorners) {
            let arc = ArcLengthPath(contour: piece, tolerance: 0.05)
            guard arc.length > 0 else { continue }
            placements += BrushLayout.place(brush, along: arc, symbol: union, widthFactor: stroke.widthFactor, random: &random, limit: BrushLayout.maxPositions - placements.count)
        }
        var copies: [Copy] = []
        var items: [DisplayItem] = []
        for (index, symbol) in brush.symbols.enumerated() {
            for placement in placements {
                copies.append(Copy(symbol: index, transform: placement, symbolBounds: symbolBounds[index]))
                items += symbol.items.map { $0.transformed(by: placement) }
            }
        }
        self.copies = copies
        self.items = items
    }

    /// The contours laid out separately: every contour, split at its corners when the brush
    /// folds there.  A closed contour's closing segment is part of it.
    static func pieces(of path: DisplayPath, foldCorners: Bool) -> [Contour] {
        guard foldCorners else {
            return path.contours
        }
        var result: [Contour] = []
        for contour in path.contours {
            var segments = contour.segments
            if contour.isClosed, let closing = contour.closingSegment, closing.chordLength > 0 {
                segments.append(closing)
            }
            var current: [CubicBezier] = []
            for segment in segments where !segment.isDegenerate {
                if let previous = current.last, isCorner(previous, segment) {
                    result.append(Contour(segments: current, closed: false))
                    current = []
                }
                current.append(segment)
            }
            if !current.isEmpty {
                result.append(Contour(segments: current, closed: false))
            }
        }
        return result
    }

    /// A corner is a turn of more than 10° between one segment's end and the next's start.
    static func isCorner(_ a: CubicBezier, _ b: CubicBezier) -> Bool {
        let incoming = a.tangent(1)
        let outgoing = b.tangent(0)
        return abs(atan2(incoming.cross(outgoing), incoming.dot(outgoing))) > Double.pi / 18
    }

    /// Placements (symbol space → local space) of copies along one piece.
    static func place(_ brush: Brush, along arc: ArcLengthPath, symbol: Rect, widthFactor: Double, random: inout PCG32, limit: Int) -> [AffineTransform] {
        let length = arc.length
        let symbolLength = max(symbol.width, 1e-3)
        let symbolHeight = max(symbol.height, 1e-3)
        let center = Point(x: symbol.midX, y: symbol.midY)
        var result: [AffineTransform] = []

        /// The copy at `distance` along, stretched `stretch` along the path.
        func placement(at distance: Double, stretch: Double?, draws: (spacing: Double, angle: Double, offset: Double, scaling: Double)) -> (AffineTransform, scale: Double) {
            let fraction = length > 0 ? distance / length : 0
            let scale = max(brush.scaling.value(at: fraction, random: draws.scaling), 0) / 100 * widthFactor
            let angle = brush.angle.value(at: fraction, random: draws.angle) * Double.pi / 180
            let offset = brush.offset.value(at: fraction, random: draws.offset) / 100 * symbolHeight * scale
            var position: Point
            var direction: Vector
            var normal: Vector
            if brush.mode == .paint && !brush.orientOnPath {
                // Unoriented Paint copies stretch straight between the end points.
                let start = arc.points[0]
                let end = arc.points[arc.points.count - 1]
                let chord = end - start
                direction = chord.length > 0 ? chord.normalized : Vector(1, 0)
                position = start + chord * fraction
                normal = direction.perpendicular
            } else {
                let location = arc.location(at: distance)
                position = location.point
                direction = location.tangent
                normal = direction.perpendicular
            }
            let rotation = (brush.orientOnPath ? atan2(direction.dy, direction.dx) : 0) + angle
            let transform = AffineTransform.translation(x: -center.x, y: -center.y)
                .concatenating(.scale(x: stretch ?? scale, y: scale))
                .concatenating(.rotation(radians: rotation))
                .concatenating(.translation(x: position.x + normal.dx * offset, y: position.y + normal.dy * offset))
            return (transform, scale)
        }

        func draw() -> (spacing: Double, angle: Double, offset: Double, scaling: Double) {
            (random.nextUnit(), random.nextUnit(), random.nextUnit(), random.nextUnit())
        }

        switch brush.mode {
        case .spray:
            var distance = 0.0
            while distance <= length + 1e-9 && result.count < limit {
                let draws = draw()
                let (transform, scale) = placement(at: distance, stretch: nil, draws: draws)
                result.append(transform)
                let fraction = distance / length
                let spacing = max(brush.spacing.value(at: fraction, random: draws.spacing), 1) / 100
                distance += max(spacing * symbolLength * scale, length * 1e-4, 1e-3)
            }
        case .paint:
            let count = min(max(brush.count, 1), 500, limit)
            let share = length / Double(count)
            for index in 0..<count {
                let draws = draw()
                let distance = (Double(index) + 0.5) * share
                result.append(placement(at: distance, stretch: share / symbolLength, draws: draws).0)
            }
        }
        return result
    }
}
