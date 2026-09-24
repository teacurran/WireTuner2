// FONT-018: TrueType outlines (`glyf`, `loca`) from finished cubic outlines: each contour is
// converted to quadratic segments within half a unit (`GlyphContours.quadratic`, the cu2qu
// tolerance), turned clockwise (TrueType's outer direction in y-up space), rounded to whole units,
// with on-curve points that are the exact midpoint of their off-curve neighbours left implied.
// Glyphs are simple (no composites, no instructions).

import WTGeometry
import WTRender

struct TrueTypeGlyphs {
    /// One point as written.
    struct Point: Hashable, Sendable {
        var x: Int
        var y: Int
        var onCurve: Bool
    }

    let glyf: [UInt8]
    let loca: [UInt8]
    let longLoca: Bool
    let records: [GlyphMetricsRecord]
    let maxPoints: Int
    let maxContours: Int

    init(_ source: FontSource) {
        var glyf = FontWriter()
        var offsets: [Int] = []
        var records: [GlyphMetricsRecord] = []
        var maxPoints = 0
        var maxContours = 0
        for glyph in source.glyphs {
            offsets.append(glyf.count)
            let contours = glyph.contours.map(Self.points).filter { !$0.isEmpty }
            let advance = min(max(Int(glyph.advanceWidth.rounded()), 0), 65_535)
            guard let box = GlyphBox(contours.flatMap { $0.map { ($0.x, $0.y) } }) else {
                records.append(GlyphMetricsRecord(advance: advance, bounds: nil))
                continue
            }
            records.append(GlyphMetricsRecord(advance: advance, bounds: box))
            maxPoints = max(maxPoints, contours.reduce(0) { $0 + $1.count })
            maxContours = max(maxContours, contours.count)
            glyf.append(Self.encode(contours, box: box))
            glyf.pad(to: 4)
        }
        offsets.append(glyf.count)
        let long = glyf.count > 0x1FFFE
        var loca = FontWriter()
        for offset in offsets {
            if long { loca.u32(offset) } else { loca.u16(offset / 2) }
        }
        self.glyf = glyf.bytes
        self.loca = loca.bytes
        longLoca = long
        self.records = records
        self.maxPoints = maxPoints
        self.maxContours = maxContours
    }

    /// A cubic contour (y up, counter-clockwise outer) as TrueType points: quadratic, clockwise,
    /// rounded, implied on-curve points dropped.
    static func points(_ contour: Contour) -> [Point] {
        let quads = GlyphContours.quadratic(contour).segments.reversed().map { QuadraticBezier($0.p2, $0.p1, $0.p0) }
        func round(_ point: WTGeometry.Point, on: Bool) -> Point {
            Point(x: Int(point.x.rounded()), y: Int(point.y.rounded()), onCurve: on)
        }
        var points: [Point] = []
        for quad in quads {
            points.append(round(quad.p0, on: true))
            if !isLine(quad) { points.append(round(quad.p1, on: false)) }
        }
        // Consecutive duplicate on-curve points collapse (the closing point repeats the start).
        var cleaned: [Point] = []
        for point in points where !(point.onCurve && cleaned.last == point) {
            cleaned.append(point)
        }
        if cleaned.count > 1, cleaned.first == cleaned.last { cleaned.removeLast() }
        return dropImplied(cleaned)
    }

    /// Whether the quadratic's control point lies on its chord (a line segment).
    static func isLine(_ quad: QuadraticBezier) -> Bool {
        let chord = Vector(dx: quad.p2.x - quad.p0.x, dy: quad.p2.y - quad.p0.y)
        let arm = Vector(dx: quad.p1.x - quad.p0.x, dy: quad.p1.y - quad.p0.y)
        let length = max((chord.dx * chord.dx + chord.dy * chord.dy).squareRoot(), 1e-12)
        return abs(chord.dx * arm.dy - chord.dy * arm.dx) / length < 1e-6
    }

    /// Drops each on-curve point that is exactly the midpoint of its off-curve neighbours.
    static func dropImplied(_ points: [Point]) -> [Point] {
        guard points.count > 2 else { return points }
        var kept: [Point] = []
        for (index, point) in points.enumerated() {
            let previous = points[(index + points.count - 1) % points.count]
            let next = points[(index + 1) % points.count]
            let implied = point.onCurve && !previous.onCurve && !next.onCurve
                && previous.x + next.x == 2 * point.x && previous.y + next.y == 2 * point.y
            if !implied { kept.append(point) }
        }
        // A contour needs one on-curve point to start from, which the rule above never removes
        // from a contour of off-curve points only; keep the data valid regardless.
        return kept.contains(where: \.onCurve) ? kept : points
    }

    /// A simple glyph: header, end points, no instructions, flags and deltas (no repeats).
    static func encode(_ contours: [[Point]], box: GlyphBox) -> [UInt8] {
        var w = FontWriter()
        w.i16(contours.count)
        w.i16(box.xMin); w.i16(box.yMin); w.i16(box.xMax); w.i16(box.yMax)
        var end = -1
        for contour in contours {
            end += contour.count
            w.u16(end)
        }
        w.u16(0)
        var flags: [UInt8] = []
        var xs = FontWriter()
        var ys = FontWriter()
        var last = (x: 0, y: 0)
        for point in contours.joined() {
            var flag: UInt8 = point.onCurve ? 0x01 : 0
            let dx = point.x - last.x, dy = point.y - last.y
            if dx == 0 {
                flag |= 0x10
            } else if abs(dx) <= 255 {
                flag |= 0x02 | (dx > 0 ? 0x10 : 0)
                xs.u8(abs(dx))
            } else {
                xs.i16(dx)
            }
            if dy == 0 {
                flag |= 0x20
            } else if abs(dy) <= 255 {
                flag |= 0x04 | (dy > 0 ? 0x20 : 0)
                ys.u8(abs(dy))
            } else {
                ys.i16(dy)
            }
            flags.append(flag)
            last = (point.x, point.y)
        }
        w.append(flags)
        w.append(xs)
        w.append(ys)
        return w.bytes
    }
}
