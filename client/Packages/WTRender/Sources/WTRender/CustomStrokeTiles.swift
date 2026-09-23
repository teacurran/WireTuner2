// Custom strokes (ATTR-012; docs/_includes/appearance/stroke-attributes.adoc, "Client"): each
// of the 23 patterns is a procedural tile -- filled polygons in tile space, u along the path
// (0 ... 1 = one `length`) and v across it (-0.5 ... 0.5 = the width) -- repeated every
// `length + spacing` along the arc-length parametrized path and bent to it: every tile vertex
// (tile edges subdivided first) is placed at the path point `u · length` along plus the smooth
// normal times `v · width`.  Neon is not tiled: it is a stack of outlines of decreasing width
// and increasing lightness in its own colours.  Everything is geometry, so it scales with width
// and zoom without rasterization.

import WTGeometry
import Foundation

enum CustomStrokeTiles {
    /// Beyond this many tiles on one contour the rest are dropped.
    static let maxTiles = 10_000

    /// Neon's layers, widest and darkest first: (fraction of the width, colour).
    static let neonLayers: [(Double, Color)] = [
        (1.0, Color(red: 0.16, green: 0.02, blue: 0.42)),
        (0.7, Color(red: 0.38, green: 0.12, blue: 0.85)),
        (0.45, Color(red: 0.68, green: 0.48, blue: 1.0)),
        (0.2, Color(red: 0.96, green: 0.92, blue: 1.0)),
    ]

    /// The regions a Custom stroke of `width` paints along `path`.
    static func regions(_ stroke: CustomStroke, width: Double, paint: Paint, path: DisplayPath, tolerance: Double) -> [PaintedRegion] {
        let width = min(max(width.isFinite ? width : 0, 0), 16_164)
        guard width > 0 else {
            return []
        }
        if stroke.pattern == .neon {
            return neonLayers.compactMap { fraction, color in
                let outline = StrokeExpansion.outline(path.contours, style: StrokeStyle(width: width * fraction, cap: .round, join: .round), width: width * fraction, tolerance: tolerance)
                return outline.isEmpty ? nil : .fill(outline, .nonZero, .solid(color))
            }
        }
        let length = stroke.length.isFinite && stroke.length > 0 ? stroke.length : 2 * width
        let spacing = stroke.spacing.isFinite ? max(stroke.spacing, 0) : 0
        let tile = polygons(for: stroke.pattern)
        var result = DisplayPath()
        for contour in path.contours {
            let arc = ArcLengthPath(contour: contour, tolerance: tolerance)
            let total = arc.length
            guard total > 0 else { continue }
            let period = length + spacing
            let count = min(Int(((total + (arc.isClosed ? 0 : spacing)) / period + 1e-9).rounded(.down)), maxTiles)
            for index in 0..<max(count, 0) {
                let start = Double(index) * period
                for polygon in tile {
                    let bent = subdivide(polygon, step: max(tolerance / length * 4, 1.0 / 32)).map { point -> Point in
                        let location = arc.location(at: start + point.x * length)
                        return location.point + location.normal * (point.y * width)
                    }
                    let area = CalligraphicSweep.signedArea(bent)
                    guard abs(area) > 1e-12 else { continue }
                    result.elements += DisplayPath(polygon: area > 0 ? bent : bent.reversed()).elements
                }
            }
        }
        return result.isEmpty ? [] : [.fill(result, .nonZero, paint)]
    }

    /// `polygon`'s edges split so no piece is longer than `step` in u, so bending follows the
    /// path.
    static func subdivide(_ polygon: [Point], step: Double) -> [Point] {
        var result: [Point] = []
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let pieces = max(Int((abs(b.x - a.x) / step).rounded(.up)), 1)
            for piece in 0..<pieces {
                let t = Double(piece) / Double(pieces)
                result.append(Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return result
    }

    // MARK: Tile shapes

    static func rect(_ u0: Double, _ v0: Double, _ u1: Double, _ v1: Double) -> [Point] {
        [Point(x: u0, y: v0), Point(x: u1, y: v0), Point(x: u1, y: v1), Point(x: u0, y: v1)]
    }

    static func ellipse(_ cu: Double, _ cv: Double, _ ru: Double, _ rv: Double, sides: Int = 24) -> [Point] {
        (0..<sides).map { index in
            let angle = 2 * Double.pi * Double(index) / Double(sides)
            return Point(x: cu + ru * cos(angle), y: cv + rv * sin(angle))
        }
    }

    /// A band of `thickness` (in v) along `points`.
    static func band(_ points: [Point], thickness: Double) -> [Point] {
        guard points.count > 1 else {
            return []
        }
        var left: [Point] = []
        var right: [Point] = []
        for index in points.indices {
            let previous = points[max(index - 1, 0)]
            let next = points[min(index + 1, points.count - 1)]
            let normal = (next - previous).normalized.perpendicular * (thickness / 2)
            left.append(points[index] + normal)
            right.append(points[index] - normal)
        }
        return left + right.reversed()
    }

    /// `cycles` sine periods across the tile at amplitude `amplitude` about `center`.
    static func wave(center: Double, amplitude: Double, cycles: Double, phase: Double = 0, thickness: Double) -> [Point] {
        let samples = 32
        let points = (0...samples).map { index -> Point in
            let u = Double(index) / Double(samples)
            return Point(x: u, y: center + amplitude * sin(2 * Double.pi * (cycles * u + phase)))
        }
        return band(points, thickness: thickness)
    }

    /// A regular star of `points` tips centred at (cu, cv).
    static func star(_ cu: Double, _ cv: Double, outer: Double, inner: Double, points tips: Int) -> [Point] {
        (0..<(2 * tips)).map { index in
            let radius = index.isMultiple(of: 2) ? outer : inner
            let angle = -Double.pi / 2 + Double.pi * Double(index) / Double(tips)
            return Point(x: cu + radius * cos(angle), y: cv + radius * sin(angle))
        }
    }

    /// The tile of each pattern (Neon is handled separately and has none).
    static func polygons(for pattern: CustomStrokePattern) -> [[Point]] {
        switch pattern {
        case .arrow:
            return [rect(0.05, -0.12, 0.6, 0.12), [Point(x: 0.55, y: -0.5), Point(x: 0.95, y: 0), Point(x: 0.55, y: 0.5)]]
        case .ball:
            return [ellipse(0.5, 0, 0.45, 0.45)]
        case .braid:
            return [
                band([Point(x: 0, y: -0.35), Point(x: 0.5, y: 0.35), Point(x: 1, y: -0.35)], thickness: 0.22),
                band([Point(x: 0, y: 0.35), Point(x: 0.5, y: -0.35), Point(x: 1, y: 0.35)], thickness: 0.22),
            ]
        case .cartographer:
            return [rect(0, -0.5, 0.5, 0.5), rect(0.5, -0.5, 1, -0.38), rect(0.5, 0.38, 1, 0.5)]
        case .checker:
            return [rect(0, -0.5, 0.5, 0), rect(0.5, 0, 1, 0.5)]
        case .crepe:
            return [
                wave(center: -0.3, amplitude: 0.08, cycles: 2, thickness: 0.12),
                wave(center: 0, amplitude: 0.08, cycles: 2, phase: 0.25, thickness: 0.12),
                wave(center: 0.3, amplitude: 0.08, cycles: 2, phase: 0.5, thickness: 0.12),
            ]
        case .diamond:
            return [[Point(x: 0.02, y: 0), Point(x: 0.5, y: -0.5), Point(x: 0.98, y: 0), Point(x: 0.5, y: 0.5)]]
        case .dot:
            return [ellipse(0.5, 0, 0.25, 0.25)]
        case .heart:
            let heart = (0..<48).map { index -> Point in
                let t = 2 * Double.pi * Double(index) / 48
                let x = 16 * pow(sin(t), 3)
                let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
                return Point(x: 0.5 + x / 36, y: -y / 36 - 0.05)
            }
            return [heart]
        case .leftDiagonal:
            return [[Point(x: 0, y: -0.5), Point(x: 0.4, y: -0.5), Point(x: 1, y: 0.5), Point(x: 0.6, y: 0.5)]]
        case .rightDiagonal:
            return [[Point(x: 0.6, y: -0.5), Point(x: 1, y: -0.5), Point(x: 0.4, y: 0.5), Point(x: 0, y: 0.5)]]
        case .rectangle:
            return [rect(0.08, -0.5, 0.92, 0.5)]
        case .roman:
            return [rect(0, -0.5, 1, -0.36), rect(0, 0.36, 1, 0.5), rect(0.18, -0.36, 0.34, 0.36), rect(0.66, -0.36, 0.82, 0.36)]
        case .snowflake:
            return (0..<3).map { arm in
                let angle = Double(arm) * Double.pi / 3
                let dx = cos(angle) * 0.45
                let dy = sin(angle) * 0.45
                return band([Point(x: 0.5 - dx, y: -dy), Point(x: 0.5 + dx, y: dy)], thickness: 0.1)
            }
        case .squiggle:
            return [wave(center: 0, amplitude: 0.3, cycles: 1, thickness: 0.2)]
        case .star:
            return [star(0.5, 0.04, outer: 0.5, inner: 0.2, points: 5)]
        case .swirl:
            let spiral = (0...40).map { index -> Point in
                let t = Double(index) / 40
                let angle = t * 3 * Double.pi
                let radius = 0.05 + 0.4 * t
                return Point(x: 0.5 + radius * cos(angle), y: radius * sin(angle))
            }
            return [band(spiral, thickness: 0.1)]
        case .teeth:
            return [[Point(x: 0, y: 0.5), Point(x: 0.5, y: -0.5), Point(x: 1, y: 0.5)]]
        case .threeWaves:
            return [-0.3, 0, 0.3].map { wave(center: $0, amplitude: 0.1, cycles: 1, thickness: 0.1) }
        case .twoWaves:
            return [-0.22, 0.22].map { wave(center: $0, amplitude: 0.14, cycles: 1, thickness: 0.14) }
        case .wedge:
            return [[Point(x: 0, y: 0), Point(x: 1, y: -0.5), Point(x: 1, y: 0.5)]]
        case .zigzag:
            return [band([Point(x: 0, y: 0.35), Point(x: 0.5, y: -0.35), Point(x: 1, y: 0.35)], thickness: 0.25)]
        case .neon:
            return []
        }
    }
}
