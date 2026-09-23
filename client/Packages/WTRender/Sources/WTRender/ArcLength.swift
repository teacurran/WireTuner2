// Arc-length parametrization of a contour and the seeded generator that brush strokes and
// random fills draw from (ATTR-010, ATTR-012, ATTR-018; D-022).

import WTGeometry
import Foundation

/// A contour flattened to a polyline with cumulative lengths, for placing things along it by
/// distance.  Closed contours include their closing segment and wrap around.
struct ArcLengthPath: Sendable {
    let points: [Point]
    /// `lengths[i]` is the distance along the polyline to `points[i]`.
    let lengths: [Double]
    let isClosed: Bool
    /// Unit normals at the vertices (the average of the adjacent segments'), so normals vary
    /// continuously along the path and bent tiles do not tear at vertices.
    private let vertexNormals: [Vector]

    init(contour: Contour, tolerance: Double) {
        var points: [Point] = []
        var segments = contour.segments
        if contour.isClosed, let closing = contour.closingSegment, closing.chordLength > 0 {
            segments.append(closing)
        }
        for segment in segments where segment.p0.isFinite && segment.p1.isFinite && segment.p2.isFinite && segment.p3.isFinite {
            if points.isEmpty {
                points.append(segment.p0)
            }
            let count = ArcLengthPath.pieceCount(segment, tolerance: tolerance)
            for index in 1...count {
                let point = segment.evaluate(Double(index) / Double(count))
                if point != points[points.count - 1] {
                    points.append(point)
                }
            }
        }
        var lengths: [Double] = []
        var total = 0.0
        for (index, point) in points.enumerated() {
            if index > 0 {
                total += point.distance(to: points[index - 1])
            }
            lengths.append(total)
        }
        self.points = points
        self.lengths = lengths
        isClosed = contour.isClosed
        vertexNormals = ArcLengthPath.normals(points, closed: contour.isClosed)
    }

    /// Wang's bound: enough straight pieces that none strays more than `tolerance`.
    static func pieceCount(_ segment: CubicBezier, tolerance: Double) -> Int {
        let a = (segment.p0 - segment.p1) + (segment.p2 - segment.p1)
        let b = (segment.p1 - segment.p2) + (segment.p3 - segment.p2)
        let deviation = max(a.length, b.length)
        let raw = (3 * deviation / (4 * max(tolerance, 1e-6))).squareRoot()
        return raw.isFinite ? min(max(Int(raw.rounded(.up)), 1), 1024) : 1
    }

    private static func normals(_ points: [Point], closed: Bool) -> [Vector] {
        guard points.count > 1 else {
            return points.map { _ in Vector(0, 1) }
        }
        let segmentNormals = (0..<(points.count - 1)).map { (points[$0 + 1] - points[$0]).normalized.perpendicular }
        return points.indices.map { index in
            var incoming = index > 0 ? segmentNormals[index - 1] : nil
            var outgoing = index < segmentNormals.count ? segmentNormals[index] : nil
            if closed && index == 0 { incoming = segmentNormals.last }
            if closed && index == points.count - 1 { outgoing = segmentNormals.first }
            let sum = (incoming ?? .zero) + (outgoing ?? .zero)
            return sum.length > 1e-9 ? sum.normalized : (outgoing ?? incoming ?? Vector(0, 1))
        }
    }

    var length: Double { lengths.last ?? 0 }

    /// Where the path is `distance` along: the point, the unit tangent of the polyline piece
    /// there, and the smoothly varying unit normal.  Beyond the ends an open path extends along
    /// its end tangents; a closed one wraps.
    func location(at distance: Double) -> (point: Point, tangent: Vector, normal: Vector) {
        guard points.count > 1, length > 0 else {
            return (points.first ?? .zero, Vector(1, 0), Vector(0, 1))
        }
        var s = distance
        if isClosed {
            s = s.truncatingRemainder(dividingBy: length)
            if s < 0 { s += length }
        }
        // The piece whose span holds s (the first or last for positions beyond the ends).
        var low = 0
        var high = lengths.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if lengths[mid] <= s { low = mid } else { high = mid }
        }
        let a = points[low]
        let b = points[high]
        let span = lengths[high] - lengths[low]
        let t = span > 0 ? (s - lengths[low]) / span : 0
        let tangent = (b - a).normalized
        let blended = vertexNormals[low] * (1 - min(max(t, 0), 1)) + vertexNormals[high] * min(max(t, 0), 1)
        let normal = blended.length > 1e-9 ? blended.normalized : tangent.perpendicular
        return (a + (b - a) * t, tangent, normal)
    }
}

/// PCG32 (O'Neill's `pcg32_random_r`, XSH RR): small, fast and the same on every Mac, so a
/// seeded stroke or fill draws the same pixels everywhere (D-022).
struct PCG32: Sendable {
    private var state: UInt64
    private let increment: UInt64

    init(seed: UInt64, sequence: UInt64 = 0xDA3E_39CB_94B9_5BDB) {
        state = 0
        increment = (sequence << 1) | 1
        _ = next()
        state &+= seed
        _ = next()
    }

    mutating func next() -> UInt32 {
        let old = state
        state = old &* 6_364_136_223_846_793_005 &+ increment
        let shifted = UInt32(truncatingIfNeeded: ((old >> 18) ^ old) >> 27)
        let rotation = UInt32(truncatingIfNeeded: old >> 59)
        return (shifted >> rotation) | (shifted << ((~rotation &+ 1) & 31))
    }

    /// A uniform draw in 0..<1.
    mutating func nextUnit() -> Double {
        Double(next()) / 4_294_967_296
    }
}

/// A stateless integer hash for page-coordinate noise: the same cell has the same value in
/// every render, tile and zoom.
enum NoiseHash {
    static func value(_ x: Int, _ y: Int, salt: UInt64 = 0) -> Double {
        var h = UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= salt &* 0x1656_67B1_9E37_79F9
        h ^= h >> 33
        h &*= 0xFF51_AFD7_ED55_8CCD
        h ^= h >> 33
        h &*= 0xC4CE_B9FE_1A85_EC53
        h ^= h >> 33
        return Double(h >> 11) / Double(1 << 53)
    }

    /// Smooth value noise: the hashed lattice interpolated with a smoothstep.
    static func smooth(_ x: Double, _ y: Double, salt: UInt64 = 0) -> Double {
        let x0 = floor(x)
        let y0 = floor(y)
        let fx = x - x0
        let fy = y - y0
        let sx = fx * fx * (3 - 2 * fx)
        let sy = fy * fy * (3 - 2 * fy)
        let ix = Int(x0)
        let iy = Int(y0)
        let a = value(ix, iy, salt: salt)
        let b = value(ix + 1, iy, salt: salt)
        let c = value(ix, iy + 1, salt: salt)
        let d = value(ix + 1, iy + 1, salt: salt)
        return (a + (b - a) * sx) * (1 - sy) + (c + (d - c) * sx) * sy
    }

    /// Four octaves of smooth noise, 0 ... 1.
    static func fractal(_ x: Double, _ y: Double, salt: UInt64 = 0) -> Double {
        var sum = 0.0
        var amplitude = 0.5
        var frequency = 1.0
        for octave in 0..<4 {
            sum += amplitude * smooth(x * frequency, y * frequency, salt: salt &+ UInt64(octave))
            amplitude /= 2
            frequency *= 2
        }
        return sum / 0.9375
    }
}
