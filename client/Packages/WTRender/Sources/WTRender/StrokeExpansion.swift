// What one stack element paints, as geometry both renderers fill (ATTR-004, ATTR-007): a
// fill's region is the path; a Basic stroke's is its GEO-003 outline (caps, joins, miter limit
// and dashes laid out by `Offset.strokeOutline`) plus the arrowheads placed on the trimmed
// path; Custom, Calligraphic and Brush strokes expand to their tiles, sweep and copies.  Core
// Graphics and Metal fill the same polygons, so they cannot disagree about a join or a dash
// (docs/spec/client.adoc, "Strokes").

import CoreGraphics
import Foundation
import WTGeometry

/// One piece of paint in the item's local space.
enum PaintedRegion: Hashable, Sendable {
    /// `path` filled by `rule` with `paint`.
    case fill(DisplayPath, FillRule, Paint)
    /// Display items (brush copies) drawn in the item's local space.
    case items([DisplayItem])
}

enum StrokeExpansion {
    /// The GEO-003 approximation tolerance, in local units, for drawing at `scale` device pixels
    /// per local unit: a sixty-fourth of a device pixel, rounded down to a power of two so that
    /// renders at nearby scales share cached outlines.  Scales up to 4 all use the 4× tolerance,
    /// so bitmaps at 1×, 2× and 4×, tiles below 4× and PDF output (4 pixels per point) fill the
    /// same outlines and agree with each other.
    static func tolerance(forScale scale: Double) -> Double {
        guard scale.isFinite, scale > 0 else {
            return 1.0 / 256
        }
        let raw = max(1.0 / 64 / max(scale, 4), 1e-4)
        return pow(2, (log2(raw)).rounded(.down))
    }

    private struct Key: Hashable, Sendable {
        let path: DisplayPath
        let stroke: StrokePaint
        let hairlineWidth: Double
        let tolerance: Double
    }

    private static let cache = RenderCache<Key, [PaintedRegion]>(capacity: 4096)

    /// The regions `stroke` paints along `path`.  A hairline is outlined at `hairlineWidth`
    /// (one device pixel in local units); `tolerance` is in local units.
    static func regions(for stroke: StrokePaint, path: DisplayPath, hairlineWidth: Double, tolerance: Double) -> [PaintedRegion] {
        let key = Key(path: path, stroke: stroke, hairlineWidth: stroke.style.isHairline ? hairlineWidth : 0, tolerance: tolerance)
        return cache.value(for: key) {
            computeRegions(for: stroke, path: path, hairlineWidth: hairlineWidth, tolerance: tolerance)
        }
    }

    private static func computeRegions(for stroke: StrokePaint, path: DisplayPath, hairlineWidth: Double, tolerance: Double) -> [PaintedRegion] {
        switch stroke.effectiveKind {
        case .basic:
            return basicRegions(for: stroke, path: path, hairlineWidth: hairlineWidth, tolerance: tolerance)
        case .custom(let custom):
            return CustomStrokeTiles.regions(custom, width: stroke.style.width, paint: stroke.paint, path: path, tolerance: tolerance)
        case .calligraphic(let nib):
            let sweep = CalligraphicSweep.region(nib, path: path, tolerance: tolerance)
            return sweep.isEmpty ? [] : [.fill(sweep, .nonZero, stroke.paint)]
        case .brush(let brush):
            let items = BrushLayout.cached(path: path, stroke: brush).items
            return items.isEmpty ? [] : [.items(items)]
        }
    }

    /// A Basic stroke: the outline of the (trimmed) path, then each head.
    static func basicRegions(for stroke: StrokePaint, path: DisplayPath, hairlineWidth: Double, tolerance: Double) -> [PaintedRegion] {
        let width = stroke.style.isHairline ? hairlineWidth : min(stroke.style.width, 16_164)
        let geometry = StrokeGeometry(path: path, stroke: stroke)
        var result: [PaintedRegion] = []
        var bodyStyle = stroke.style
        if bodyStyle.isHairline && bodyStyle.dashInDevicePixels {
            // Device-pixel dashes: one hairline width is one device pixel in local units.
            bodyStyle.dash = bodyStyle.dash.map { $0 * hairlineWidth }
            bodyStyle.dashPhase *= hairlineWidth
        }
        let body = outline(geometry.body.contours, style: bodyStyle, width: width, tolerance: tolerance)
        if !body.isEmpty {
            result.append(.fill(body, .nonZero, stroke.paint))
        }
        for head in geometry.heads {
            let shape = head.arrowhead.shape.applying(head.transform)
            if head.arrowhead.filled {
                result.append(.fill(shape, .nonZero, stroke.paint))
            } else {
                // An open head is stroked at one unit, the stroke's width, undashed.
                var style = stroke.style
                style.dash = []
                let outlined = outline(shape.contours, style: style, width: width, tolerance: tolerance)
                if !outlined.isEmpty {
                    result.append(.fill(outlined, .nonZero, stroke.paint))
                }
            }
        }
        return result
    }

    /// GEO-003's stroke outline of `contours` at `width`, as a display path filled non-zero.
    /// Where GEO-003's boolean cleanup cannot resolve the outline (`checkedStrokeOutline`
    /// throws) its best effort can lack edges -- a letter's outline that came back without its
    /// inner side filled the whole letter -- so the outline is Core Graphics' instead
    /// (`coreGraphicsOutline`), the same polygons for both renderers.
    static func outline(_ contours: [Contour], style: StrokeStyle, width: Double, tolerance: Double,
                        stroke: ([Contour], WTGeometry.StrokeStyle, Double) throws -> FilledPath = { try Offset.checkedStrokeOutline($0, style: $1, tolerance: $2) }) -> DisplayPath {
        guard !contours.isEmpty, width > 0, width.isFinite else {
            return DisplayPath()
        }
        let geometryStyle = WTGeometry.StrokeStyle(
            width: width,
            cap: style.cap.geometry,
            join: style.join.geometry,
            miterLimit: style.miterLimit,
            dash: style.effectiveDash,
            dashPhase: style.dashPhase
        )
        do {
            return DisplayPath(contours: try stroke(contours, geometryStyle, tolerance).contours)
        } catch {
            return coreGraphicsOutline(contours, style: style, width: width)
        }
    }

    /// Core Graphics' stroke outline of `contours` (dashed first), filled non-zero.
    static func coreGraphicsOutline(_ contours: [Contour], style: StrokeStyle, width: Double) -> DisplayPath {
        var path = DisplayPath(contours: contours).cgPath
        let dash = style.effectiveDash
        if !dash.isEmpty {
            path = path.copy(dashingWithPhase: CGFloat(style.dashPhase), lengths: dash.map { CGFloat($0) })
        }
        let cap: CGLineCap = switch style.cap {
        case .butt: .butt
        case .round: .round
        case .square: .square
        }
        let join: CGLineJoin = switch style.join {
        case .miter: .miter
        case .round: .round
        case .bevel: .bevel
        }
        let miter = style.miterLimit.isFinite ? max(style.miterLimit, 1) : 4
        return DisplayPath(cgPath: path.copy(strokingWithWidth: CGFloat(width), lineCap: cap, lineJoin: join, miterLimit: CGFloat(miter)))
    }
}

extension LineCap {
    var geometry: WTGeometry.LineCap {
        switch self {
        case .butt: return .butt
        case .round: return .round
        case .square: return .square
        }
    }
}

extension LineJoin {
    var geometry: WTGeometry.LineJoin {
        switch self {
        case .miter: return .miter
        case .round: return .round
        case .bevel: return .bevel
        }
    }
}

/// The view-mode decorations' lines -- Keyline outlines, placeholder boxes and baselines, one
/// device pixel or one point wide -- as polygons both renderers fill: a quad along every
/// segment of the flattened path and an octagon at every vertex (round joins and caps), all
/// oriented positively so their non-zero fill is the union.  Cheap enough for Keyline over a
/// whole document, and it keeps Core Graphics' stroker out of both renderers: that stroker drew
/// a stray full-height column in tiles a long hairline did not cross.
enum HairlineOutline {
    private struct Key: Hashable, Sendable {
        let path: DisplayPath
        let width: Double
        let tolerance: Double
    }

    private static let cache = RenderCache<Key, DisplayPath>(capacity: 8192)

    static func region(_ path: DisplayPath, width: Double, tolerance: Double) -> DisplayPath {
        cache.value(for: Key(path: path, width: width, tolerance: tolerance)) {
            compute(path, width: width, tolerance: tolerance)
        }
    }

    private static func compute(_ path: DisplayPath, width: Double, tolerance: Double) -> DisplayPath {
        guard width > 0, width.isFinite else {
            return DisplayPath()
        }
        let half = width / 2
        var result = DisplayPath()
        func add(_ points: [Point]) {
            let area = CalligraphicSweep.signedArea(points)
            guard abs(area) > 0 else { return }
            result.elements += DisplayPath(polygon: area > 0 ? points : points.reversed()).elements
        }
        let octagon = (0..<8).map { index -> Vector in
            let angle = Double.pi / 8 + Double(index) * Double.pi / 4
            return Vector(cos(angle), sin(angle)) * (half / cos(Double.pi / 8))
        }
        for contour in path.contours {
            let points = ArcLengthPath(contour: contour, tolerance: tolerance).points
            for point in points {
                add(octagon.map { point + $0 })
            }
            for index in points.indices.dropFirst() {
                let a = points[index - 1]
                let b = points[index]
                let normal = (b - a).normalized.perpendicular * half
                add([a + normal, b + normal, b - normal, a - normal])
            }
        }
        return result
    }
}
