// Mapping outlines through a non-affine function (FX-038 envelopes, FX-042 perspective, the
// front face of FX-018 extrusions).  A curve's control points cannot simply be mapped, so each
// segment becomes the cubic Hermite interpolant of the mapped curve -- mapped end points, end
// derivatives through the map's Jacobian -- and is halved until that cubic is within the
// tolerance (0.1 pt) of the exact mapping at sampled parameters.  Also the helpers that turn a
// wrapper's children into plain pasteboard-space items to map.

import WTGeometry

enum CurveWarp {
    static let tolerance = 0.1
    static let maxDepth = 12

    /// `contours` through `map`, within `tolerance`.
    static func map(_ contours: [Contour], tolerance: Double = CurveWarp.tolerance, map: (Point) -> Point) -> [Contour] {
        contours.map { contour in
            var segments: [CubicBezier] = []
            for segment in contour.explicitSegments {
                warp(segment, depth: 0, tolerance: tolerance, map: map, into: &segments)
            }
            return Contour(segments: segments, closed: contour.isClosed)
        }
    }

    /// The largest distance, over sampled parameters, between `approximation` and `segment`
    /// mapped exactly.
    static func error(of approximation: CubicBezier, against segment: CubicBezier, map: (Point) -> Point) -> Double {
        [0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875].reduce(0) { worst, t in
            max(worst, approximation.evaluate(t).distance(to: map(segment.evaluate(t))))
        }
    }

    private static func warp(_ segment: CubicBezier, depth: Int, tolerance: Double, map: (Point) -> Point, into result: inout [CubicBezier]) {
        let approximation = hermite(segment, map: map)
        if depth >= maxDepth || error(of: approximation, against: segment, map: map) <= tolerance {
            result.append(approximation)
            return
        }
        let (first, second) = segment.split(at: 0.5)
        warp(first, depth: depth + 1, tolerance: tolerance, map: map, into: &result)
        warp(second, depth: depth + 1, tolerance: tolerance, map: map, into: &result)
    }

    /// The cubic through the mapped end points with the mapped end derivatives.
    static func hermite(_ segment: CubicBezier, map: (Point) -> Point) -> CubicBezier {
        let q0 = map(segment.p0)
        let q3 = map(segment.p3)
        func mappedDerivative(at point: Point, _ derivative: Vector) -> Vector {
            let length = derivative.length
            guard length > 1e-12 else {
                return .zero
            }
            let step = max(1e-4, length * 1e-4)
            let unit = derivative / length
            let forward = map(point + unit * step)
            let backward = map(point - unit * step)
            return (forward - backward) * (length / (2 * step))
        }
        let d0 = mappedDerivative(at: segment.p0, segment.derivative(0))
        let d1 = mappedDerivative(at: segment.p3, segment.derivative(1))
        return CubicBezier(p0: q0, p1: q0 + d0 / 3, p2: q3 - d1 / 3, p3: q3)
    }
}

/// Children turned into plain pasteboard-space paths for a wrapper to map: effects resolved to
/// their vector geometry (raster stages drop out), glyph runs as outlines, groups flattened, a
/// nested wrapper of the same kind read as its child, transforms baked in (stroke widths scaled).
enum WarpSource {
    static func plainPaths(_ item: DisplayItem) -> [PathItem] {
        switch item {
        case .path(let path):
            if path.hasEffects {
                return EffectPipeline.nodes(for: path).flatMap(\.plainItems).flatMap(plainPaths)
            }
            return [baked(path)]
        case .fill(let fill):
            return [baked(PathItem(path: fill.path, appearance: Appearance([.fill(FillPaint(paint: fill.paint, rule: fill.rule))]), transform: fill.transform))]
        case .stroke(let stroke):
            return [baked(PathItem(path: stroke.path, appearance: Appearance([.stroke(StrokePaint(paint: stroke.paint, style: stroke.style))]), transform: stroke.transform))]
        case .text(let text):
            guard let run = text.glyphRun else {
                return [baked(PathItem(path: DisplayPath(rect: text.bounds), appearance: Appearance([.fill(FillPaint(paint: .solid(text.color.withAlpha(multipliedBy: 0.15))))]), transform: text.transform))]
            }
            return [baked(PathItem(path: run.outline, appearance: Appearance([.fill(FillPaint(paint: .solid(text.color)))]), transform: text.transform))]
        case .image(let image):
            return [baked(PathItem(path: DisplayPath(rect: image.rect), appearance: Appearance([.fill(FillPaint(paint: .solid(Color(white: 0.75))))]), transform: image.transform))]
        case .group(let group):
            if group.isDerived {
                return EffectPipeline.derived(group).nodes.flatMap(\.plainItems).flatMap(plainPaths)
            }
            return group.children.flatMap(plainPaths)
        }
    }

    /// The item with its transform applied to the path, strokes scaled to match.
    static func baked(_ item: PathItem) -> PathItem {
        guard !item.transform.isIdentity else {
            return item
        }
        let scale = item.transform.scaleFactor
        var appearance = item.appearance
        appearance.items = appearance.items.map { element in
            guard case .stroke(var stroke) = element else { return element }
            stroke.style.width *= scale
            stroke.style.dash = stroke.style.dash.map { $0 * scale }
            stroke.style.dashPhase *= scale
            return .stroke(stroke)
        }
        return PathItem(path: item.path.applying(item.transform), appearance: appearance)
    }

    /// `items` mapped through `map` as one entry item.
    static func mapped(_ items: [PathItem], map: (Point) -> Point) -> DisplayItem? {
        let result = items.map { item in
            DisplayItem.path(PathItem(path: DisplayPath(contours: CurveWarp.map(item.path.contours, map: map)), appearance: item.appearance))
        }
        switch result.count {
        case 0: return nil
        case 1: return result[0]
        default: return .group(GroupItem(children: result))
        }
    }
}
