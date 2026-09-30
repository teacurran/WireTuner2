import Foundation
import WTGeometry

/// The eraser strip (editing-paths.adoc, "Erasing"; DRAW-029): the two edges of a strip along the
/// drag whose width follows each sample's width, and the cut of a contour by it -- what the strip
/// covers is removed, what remains becomes pieces (the one holding the contour's start keeps it).
public enum EraserStrip {
    /// The two edges of the strip along `samples` (each sample's width), with the ends extended by
    /// half a width so the strip reaches past the first and last samples.
    public static func edges(_ samples: [VariableStrokeOutline.Sample]) -> (left: [Point], right: [Point]) {
        let points = samples.map(\.point)
        guard points.count >= 2 else { return (points, points) }
        var left: [Point] = [], right: [Point] = []
        for index in points.indices {
            let before = index > 0 ? points[index] - points[index - 1] : points[1] - points[0]
            let after = index + 1 < points.count ? points[index + 1] - points[index] : before
            var normal = (before.lengthSquared > 0 ? before.normalized : after.normalized) + (after.lengthSquared > 0 ? after.normalized : before.normalized)
            if normal.lengthSquared < 1e-12 { normal = before.normalized }
            let half = samples[index].width / 2
            let perpendicular = normal.normalized.perpendicular * half
            var point = points[index]
            if index == 0 { point = point - after.normalized * half }
            if index == points.count - 1 { point = point + before.normalized * half }
            left.append(point + perpendicular)
            right.append(point - perpendicular)
        }
        return (left, right)
    }

    /// The half width of the strip nearest `point`.
    public static func halfWidth(near point: Point, samples: [VariableStrokeOutline.Sample]) -> Double {
        (samples.min { $0.point.distance(to: point) < $1.point.distance(to: point) }?.width ?? 0) / 2
    }

    /// The pieces of one contour (pasteboard space) after the strip, or nil when it misses.
    public static func erase(_ points: [VectorPoint], closed: Bool, samples: [VariableStrokeOutline.Sample]) -> [PathCutting.Piece]? {
        let path = samples.map(\.point)
        guard path.count >= 2 else { return nil }
        let (left, right) = edges(samples)
        let cuts = PathCutting.crossings(points, closed: closed, cutter: left) + PathCutting.crossings(points, closed: closed, cutter: right)
        guard var pieces = PathCutting.split(points, closed: closed, at: cuts) else { return nil }
        pieces = pieces.filter { piece in
            let segments = ContourPoints.segments(piece.points, closed: false)
            let middle = segments[segments.count / 2].evaluate(0.5)
            return PathCutting.distance(middle, to: path) > halfWidth(near: middle, samples: samples) - 1e-6
        }
        if !pieces.contains(where: \.keepsStart), !pieces.isEmpty { pieces[0].keepsStart = true }
        return pieces
    }
}
