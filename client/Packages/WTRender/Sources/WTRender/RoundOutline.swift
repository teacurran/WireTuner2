// The region a round-joined, round-capped, undashed stroke paints, built from polygons both
// renderers fill: a quad along every segment of the flattened path and, at every vertex, the
// arc on the outer side of the turn (at open ends, whole discs), all oriented positively so their
// non-zero fill is the union.  Every point added lies within half the width of the path, so the
// region never exceeds the stroke's (a Minkowski sum with a disc); on the inner side of a turn
// sharper than the adjacent segments are long it can fall short of it by a sliver, which the
// glyph drawn over an inline ring or a bold weight covers.  No boolean operations, so it cannot
// fail on awkward outlines: the text effects that ring glyphs (inline) and synthesized bold
// (TYPE-021, TYPE-036) stroke glyphs with GEO-003's `Offset.checkedStrokeOutline` and fall back to
// this region where it throws (`GlyphOutlines.FontTable.roundOutline`).

import WTGeometry
import Foundation

public enum RoundOutline {
    /// The region a round stroke `width` wide along `path` paints, flattened to `tolerance`.
    public static func region(of path: DisplayPath, width: Double, tolerance: Double) -> DisplayPath {
        guard width > 0, width.isFinite, tolerance > 0 else {
            return DisplayPath()
        }
        let half = width / 2
        // The arc step whose sagitta stays within the tolerance.
        let step = 2 * acos(max(1 - min(tolerance, half) / half, -1))
        var result = DisplayPath()
        func add(_ points: [Point]) {
            let area = CalligraphicSweep.signedArea(points)
            guard abs(area) > 1e-12 else { return }
            result.elements += DisplayPath(polygon: area > 0 ? points : points.reversed()).elements
        }
        /// The fan from `center` sweeping `from` to `to` (unit vectors) the short way.
        func fan(_ center: Point, from: Vector, to: Vector) {
            let turn = atan2(from.dx * to.dy - from.dy * to.dx, from.dx * to.dx + from.dy * to.dy)
            guard abs(turn) > 1e-9 else { return }
            let pieces = max(Int((abs(turn) / step).rounded(.up)), 1)
            let start = atan2(from.dy, from.dx)
            var points = [center]
            for index in 0...pieces {
                let angle = start + turn * Double(index) / Double(pieces)
                points.append(Point(x: center.x + half * cos(angle), y: center.y + half * sin(angle)))
            }
            add(points)
        }
        for contour in path.contours {
            let polyline = ArcLengthPath(contour: contour, tolerance: tolerance)
            // A closed polyline ends where it starts (`ArcLengthPath` adds the closing segment).
            let points = polyline.points
            guard points.count > 1 else {
                if let point = points.first {
                    fan(point, from: Vector(dx: 1, dy: 0), to: Vector(dx: -1, dy: 0))
                    fan(point, from: Vector(dx: -1, dy: 0), to: Vector(dx: 1, dy: 0))
                }
                continue
            }
            var normals: [Vector] = []
            for index in points.indices.dropFirst() {
                let normal = (points[index] - points[index - 1]).normalized.perpendicular
                normals.append(normal)
                let offset = normal * half
                add([points[index - 1] + offset, points[index] + offset, points[index] - offset, points[index - 1] - offset])
            }
            /// The arc on the outer side of the turn from `before` to `after` at `point`.
            func join(_ point: Point, _ before: Vector, _ after: Vector) {
                // Turning towards +normal opens the gap on the -normal side, and back.
                let turn = before.dx * after.dy - before.dy * after.dx
                if turn > 0 {
                    fan(point, from: before * -1, to: after * -1)
                } else {
                    fan(point, from: before, to: after)
                }
            }
            for index in normals.indices.dropFirst() {
                join(points[index], normals[index - 1], normals[index])
            }
            if polyline.isClosed {
                join(points[0], normals[normals.count - 1], normals[0])
            } else {
                // Round caps.
                fan(points[0], from: normals[0], to: normals[0] * -1)
                fan(points[0], from: normals[0] * -1, to: normals[0])
                let last = points[points.count - 1]
                fan(last, from: normals[normals.count - 1], to: normals[normals.count - 1] * -1)
                fan(last, from: normals[normals.count - 1] * -1, to: normals[normals.count - 1])
            }
        }
        return result
    }
}

extension GlyphRun {
    /// The region a round stroke `width` wide along every glyph's outline paints, in local
    /// space: the rings of the inline text effect and a synthesized bold's weight.  Glyph by
    /// glyph from a per-font cache, `tolerance` in glyph points.  (`roundOutlineItems` places the
    /// cached glyph regions as items instead, without copying them.)
    public func roundOutline(width: Double, tolerance: Double = 0.05) -> DisplayPath {
        let table = GlyphOutlines.shared.table(for: font)
        var elements: [DisplayPath.Element] = []
        for glyph in glyphs {
            let shape = table.roundOutline(glyph.glyph, width: width, tolerance: tolerance)
            guard !shape.isEmpty else {
                continue
            }
            let placement = glyph.placement
            elements.append(contentsOf: shape.elements.map { $0.applying(placement) })
        }
        return DisplayPath(elements: elements)
    }

    /// One filled path item per inked glyph: its cached `RoundOutline` region placed by the
    /// glyph's transform followed by `transform`, painted `paint`.  The regions are shared, not
    /// copied, which is what keeps a long effected text cheap to draw.
    public func roundOutlineItems(width: Double, paint: FillPaint, transform: AffineTransform, tolerance: Double = 0.05) -> [DisplayItem] {
        let table = GlyphOutlines.shared.table(for: font)
        var items: [DisplayItem] = []
        for glyph in glyphs {
            let shape = table.roundOutline(glyph.glyph, width: width, tolerance: tolerance)
            if !shape.isEmpty {
                items.append(.path(PathItem(path: shape, appearance: Appearance([.fill(paint)]), transform: glyph.placement.concatenating(transform))))
            }
        }
        return items
    }
}
