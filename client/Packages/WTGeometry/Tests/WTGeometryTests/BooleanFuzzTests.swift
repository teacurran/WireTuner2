import Foundation
import Testing
@testable import WTGeometry

/// Random polygons and curves never crash or hang, and polygon results conserve area.
@Suite struct BooleanFuzzTests {
    static let timeLimit = Duration.seconds(5)

    func randomPolygon(_ rng: inout SeededGenerator, grid: Double? = nil) -> FilledPath {
        let count = Int.random(in: 3...9, using: &rng)
        var points: [Point] = []
        for _ in 0..<count {
            var p = rng.point(in: -50...50)
            if let grid {
                p = Point((p.x / grid).rounded() * grid, (p.y / grid).rounded() * grid)
            }
            points.append(p)
        }
        return polygonPath(points, rule: Bool.random(using: &rng) ? .nonZero : .evenOdd)
    }

    func randomCurves(_ rng: inout SeededGenerator) -> FilledPath {
        var contours: [Contour] = []
        for _ in 0..<Int.random(in: 1...2, using: &rng) {
            var segments: [CubicBezier] = []
            let start = rng.point(in: -50...50)
            var cursor = start
            let n = Int.random(in: 1...5, using: &rng)
            for k in 0..<n {
                let next = k == n - 1 ? start : rng.point(in: -50...50)
                segments.append(CubicBezier(cursor, rng.point(in: -70...70), rng.point(in: -70...70), next))
                cursor = next
            }
            contours.append(Contour(segments: segments, closed: true))
        }
        return FilledPath(contours: contours, fillRule: Bool.random(using: &rng) ? .nonZero : .evenOdd)
    }

    func check(_ a: FilledPath, _ b: FilledPath, conserve: Bool, label: String) -> Bool {
        let clock = ContinuousClock()
        var results: [FilledPath] = []
        let elapsed = clock.measure {
            for operation in BooleanOperation.allCases {
                results.append(Boolean.perform(operation, a, b))
            }
        }
        #expect(elapsed < Self.timeLimit, "\(label) took \(elapsed)")
        for r in results {
            #expect(r.signedArea().isFinite, "\(label)")
            for contour in r.contours {
                #expect(contour.segments.allSatisfy { $0.p0.isFinite && $0.p3.isFinite })
            }
        }
        guard conserve else {
            return true
        }
        let areaA = filledArea(a)
        let areaB = filledArea(b)
        let u = results[0].signedArea()
        let i = results[1].signedArea()
        return abs(u + i - areaA - areaB) <= 1e-6 * max(1, areaA + areaB)
    }

    @Test func randomPolygonsConserveArea() {
        var rng = SeededGenerator(seed: 7)
        var failures = 0
        for k in 0..<150 {
            if !check(randomPolygon(&rng), randomPolygon(&rng), conserve: true, label: "polygons \(k)") {
                failures += 1
            }
        }
        #expect(failures == 0)
    }

    /// Vertices on a coarse grid: many collinear, coincident and touching edges.
    @Test func gridSnappedPolygonsConserveArea() {
        var rng = SeededGenerator(seed: 11)
        var failures = 0
        for k in 0..<150 {
            if !check(randomPolygon(&rng, grid: 25), randomPolygon(&rng, grid: 25), conserve: true, label: "grid \(k)") {
                failures += 1
            }
        }
        #expect(failures == 0)
    }

    @Test func randomCurvesNeverCrash() {
        var rng = SeededGenerator(seed: 13)
        for k in 0..<60 {
            _ = check(randomCurves(&rng), randomCurves(&rng), conserve: false, label: "curves \(k)")
            let normalized = Boolean.normalize(randomCurves(&rng))
            #expect(normalized.signedArea() >= -1e-6)
        }
    }

    @Test func pathologicalInputs() {
        let nan = FilledPath(Contour(polygon: [Point(0, 0), Point(.nan, 1), Point(4, 4)]))
        let inf = FilledPath(Contour(polygon: [Point(0, 0), Point(.infinity, 1), Point(4, 4)]))
        let huge = rectPath(-1e12, -1e12, 2e12, 2e12)
        let square = rectPath(0, 0, 10, 10)
        for (x, y) in [(nan, square), (inf, square), (huge, square), (square, huge)] {
            _ = check(x, y, conserve: false, label: "pathological")
        }
        // The same segment repeated many times in one contour.
        let repeated = FilledPath(Contour(segments: Array(repeating: sCurve, count: 20), closed: false))
        _ = check(repeated, square, conserve: false, label: "repeated")
        // Every segment degenerate.
        let dots = FilledPath(Contour(segments: Array(repeating: CubicBezier(Point(1, 1), Point(1, 1), Point(1, 1), Point(1, 1)), count: 5), closed: true))
        #expect(Boolean.union(dots, square).signedArea() == 100)
    }
}
