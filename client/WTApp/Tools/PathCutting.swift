import Foundation
import WTCRDT
import WTGeometry
import WTModel

/// Cutting contours apart (editing-paths.adoc, "Splitting paths"; DRAW-028): where a cutting
/// line crosses a contour, the pieces between the crossings, which piece keeps the original
/// (the one holding its first drawn point -- the `start` of an open contour), and the change that
/// writes them.  Pure over path points in drawing order, so every rule is tested without a window.
enum PathCutting {
    /// A place on a contour: segment `segment` (from drawn point `segment` to the next) at `t`;
    /// `t == 0` is the point itself.
    struct Location: Hashable, Comparable, Sendable {
        var segment: Int
        var t: Double

        static func < (lhs: Location, rhs: Location) -> Bool { (lhs.segment, lhs.t) < (rhs.segment, rhs.t) }
    }

    /// One piece of a cut contour.
    struct Piece: Equatable, Sendable {
        var points: [VectorPoint]
        var closed: Bool
        /// Holds the contour's first drawn point (the piece that keeps the original node).
        var keepsStart: Bool
    }

    /// Where the polyline `cutter` crosses the contour `points` (both in one space), in contour
    /// order; touches at a segment's far end are counted once, on the next segment.
    static func crossings(_ points: [VectorPoint], closed: Bool, cutter: [Point]) -> [Location] {
        let segments = ContourPoints.segments(points, closed: closed)
        var result: Set<Location> = []
        for (index, segment) in segments.enumerated() {
            for (a, b) in zip(cutter, cutter.dropFirst()) where a.distance(to: b) > 1e-9 {
                // Hits within the cutting segment only (`Line` intersections stay on the segment).
                for hit in segment.intersections(with: Line(start: a, end: b)) {
                    if hit.t >= 1 - 1e-9 {
                        // The far end is the next segment's start (or, open, the contour's end).
                        if index + 1 < segments.count { result.insert(Location(segment: index + 1, t: 0)) } else if closed { result.insert(Location(segment: 0, t: 0)) }
                    } else {
                        result.insert(Location(segment: index, t: max(0, hit.t)))
                    }
                }
            }
        }
        // An open contour's own ends are not cuts.
        return result.filter { closed || !($0.segment == 0 && $0.t == 0) }.sorted()
    }

    /// The pieces of the contour `points` cut at `cuts`: each cut ends one piece and starts the
    /// next; a cut inside a segment adds a corner point there (the segment's halves keep its
    /// shape), a cut at a point shares it.  An open contour's first piece runs from its start, its
    /// last to its end; a closed contour's pieces run cut to cut around it (one cut opens it
    /// there).  No cuts: nil.
    static func split(_ points: [VectorPoint], closed: Bool, at cuts: [Location]) -> [Piece]? {
        let count = points.count
        let segmentCount = closed ? count : count - 1
        let cuts = Array(Set(cuts.filter { $0.segment >= 0 && $0.segment < count && ($0.t == 0 || $0.segment < segmentCount) })).sorted()
        guard !cuts.isEmpty, count >= 2 else { return nil }
        // Subdivide the segments with inner cuts: new corner points after their start point, and
        // the handles of the segment's two ends shortened to the halves.
        var adjusted = points
        var inserted: [[VectorPoint]] = Array(repeating: [], count: count)
        for index in 0..<segmentCount {
            let inner = cuts.filter { $0.segment == index && $0.t > 0 && $0.t < 1 }.map(\.t)
            guard !inner.isEmpty else { continue }
            let next = (index + 1) % count
            var curve = CubicBezier(from: points[index].anchor, outHandle: points[index].outHandle, inHandle: points[next].inHandle, to: points[next].anchor)
            var consumed = 0.0
            var run: [VectorPoint] = []
            for t in inner {
                let (left, right) = curve.split(at: (t - consumed) / (1 - consumed))
                if run.isEmpty { adjusted[index].outHandle = left.p1 - left.p0 } else { run[run.count - 1].outHandle = left.p1 - left.p0 }
                run.append(VectorPoint(anchor: left.p3, inHandle: left.p2 - left.p3, outHandle: right.p1 - right.p0, kind: .corner))
                curve = right
                consumed = t
            }
            adjusted[next].inHandle = curve.p2 - curve.p3
            inserted[index] = run
        }
        var sequence: [VectorPoint] = []
        var marks: [Int] = []
        for index in 0..<count {
            if cuts.contains(Location(segment: index, t: 0)) { marks.append(sequence.count) }
            sequence.append(adjusted[index])
            for point in inserted[index] {
                marks.append(sequence.count)
                sequence.append(point)
            }
        }
        func piece(_ indices: [Int], keepsStart: Bool) -> Piece {
            var run = indices.map { sequence[$0] }
            run[0].inHandle = .zero
            run[0].kind = .corner
            run[run.count - 1].outHandle = .zero
            run[run.count - 1].kind = .corner
            return Piece(points: run, closed: false, keepsStart: keepsStart)
        }
        var pieces: [Piece] = []
        if closed {
            for (index, mark) in marks.enumerated() {
                let end = index + 1 < marks.count ? marks[index + 1] : marks[0] + sequence.count
                let indices = (mark...end).map { $0 % sequence.count }
                // The piece holding the first point: the one starting there, else the one that
                // wraps past it.
                let keeps = marks[0] == 0 ? index == 0 : index == marks.count - 1
                pieces.append(piece(indices, keepsStart: keeps))
            }
        } else {
            var bounds = [0] + marks.filter { $0 > 0 && $0 < sequence.count - 1 } + [sequence.count - 1]
            bounds = bounds.enumerated().filter { $0.offset == 0 || $0.element != bounds[$0.offset - 1] }.map(\.element)
            for (offset, pair) in zip(bounds, bounds.dropFirst()).enumerated() {
                pieces.append(piece(Array(pair.0...pair.1), keepsStart: offset == 0))
            }
        }
        return pieces.count > 1 || closed ? pieces : nil
    }

    /// The two edges of a cut `width` wide along `cutter` (offset by half the width each side,
    /// with averaged normals at the joints).
    static func strip(_ cutter: [Point], width: Double) -> (left: [Point], right: [Point]) {
        guard width > 0, cutter.count >= 2 else { return (cutter, cutter) }
        let half = width / 2
        var left: [Point] = [], right: [Point] = []
        for index in cutter.indices {
            let before = index > 0 ? cutter[index] - cutter[index - 1] : cutter[1] - cutter[0]
            let after = index + 1 < cutter.count ? cutter[index + 1] - cutter[index] : before
            var normal = (before.lengthSquared > 0 ? before.normalized : after.normalized) + (after.lengthSquared > 0 ? after.normalized : before.normalized)
            if normal.lengthSquared < 1e-12 { normal = before.normalized }
            let perpendicular = normal.normalized.perpendicular * half
            // Extend the ends so the strip reaches past the first and last samples.
            var point = cutter[index]
            if index == 0 { point = point - after.normalized * half }
            if index == cutter.count - 1 { point = point + before.normalized * half }
            left.append(point + perpendicular)
            right.append(point - perpendicular)
        }
        return (left, right)
    }

    /// The distance from `point` to the polyline `line`.
    static func distance(_ point: Point, to line: [Point]) -> Double {
        guard let first = line.first else { return .infinity }
        guard line.count > 1 else { return point.distance(to: first) }
        return zip(line, line.dropFirst()).map { a, b -> Double in
            let direction = b - a
            guard direction.lengthSquared > 0 else { return point.distance(to: a) }
            let u = min(max((point - a).dot(direction) / direction.lengthSquared, 0), 1)
            return point.distance(to: a + direction * u)
        }.min()!
    }

    /// The Knife on one contour (pasteboard space): the pieces the cut leaves -- the strip between
    /// the two edges removed when `width` > 0, each piece closed with a straight segment when
    /// `close` -- or nil when the cut misses it.
    static func knife(_ points: [VectorPoint], closed: Bool, cutter: [Point], width: Double, close: Bool) -> [Piece]? {
        let edges = strip(cutter, width: width)
        let cuts = width > 0 ? crossings(points, closed: closed, cutter: edges.left) + crossings(points, closed: closed, cutter: edges.right)
            : crossings(points, closed: closed, cutter: cutter)
        guard var pieces = split(points, closed: closed, at: cuts) else { return nil }
        if width > 0 {
            pieces = pieces.filter { piece in
                let segments = ContourPoints.segments(piece.points, closed: false)
                let middle = segments[segments.count / 2].evaluate(0.5)
                return distance(middle, to: cutter) > width / 2 - 1e-6
            }
            if !pieces.contains(where: \.keepsStart), !pieces.isEmpty { pieces[0].keepsStart = true }
        }
        if close { pieces = pieces.map { Piece(points: $0.points, closed: $0.points.count >= 3 || closed, keepsStart: $0.keepsStart) } }
        return pieces
    }

    /// The change that writes the pieces of `node`'s cut contours (`cut`: contour id → pieces,
    /// in the path's own space): the piece keeping each contour's start stays in the contour
    /// (its surviving points keep their ids), the others become new paths above it.  Nil when no
    /// contour was cut.
    static func command(node: OpID, cut: [(contour: OpID, pieces: [Piece])], label: String) -> RewritePath? {
        var edits: [RewritePath.ContourEdit] = []
        var removed: [OpID] = []
        var others: [[NewContour]] = []
        for (contour, pieces) in cut where !pieces.isEmpty {
            if let kept = pieces.first(where: \.keepsStart) {
                edits.append(.init(contour: contour, points: kept.points, closed: kept.closed))
            } else {
                removed.append(contour)
            }
            others += pieces.filter { !$0.keepsStart }.map { [NewContour(closed: $0.closed, points: $0.points)] }
        }
        guard !edits.isEmpty || !removed.isEmpty || !others.isEmpty else { return nil }
        return RewritePath(node: node, edits: edits, removed: removed, pieces: others, label: label)
    }
}
