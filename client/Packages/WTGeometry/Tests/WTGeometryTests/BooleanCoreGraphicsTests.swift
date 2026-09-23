#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
import Testing
@testable import WTGeometry

/// Cross-check against Core Graphics' own path booleans (macOS 14+).  WTGeometry does not link
/// Core Graphics; only this test does.  Both operands must share a fill rule, because
/// `CGPath.union(_:using:)` takes one rule for both.
@Suite struct BooleanCoreGraphicsTests {
    static func cgPath(_ path: FilledPath) -> CGPath {
        let result = CGMutablePath()
        for contour in path.contours where !contour.isEmpty {
            result.move(to: CGPoint(x: contour.segments[0].p0.x, y: contour.segments[0].p0.y))
            for s in contour.segments {
                result.addCurve(
                    to: CGPoint(x: s.p3.x, y: s.p3.y),
                    control1: CGPoint(x: s.p1.x, y: s.p1.y),
                    control2: CGPoint(x: s.p2.x, y: s.p2.y))
            }
            result.closeSubpath()
        }
        return result
    }

    static func cgRule(_ rule: FillRule) -> CGPathFillRule {
        rule == .nonZero ? .winding : .evenOdd
    }

    @Test(arguments: BooleanCorpus.all.filter { $0.a.fillRule == $0.b.fillRule && !$0.a.isEmpty && !$0.b.isEmpty })
    func agreesWithCoreGraphics(_ c: BooleanCase) {
        let a = Self.cgPath(c.a)
        let b = Self.cgPath(c.b)
        let rule = Self.cgRule(c.a.fillRule)
        let pairs: [(BooleanOperation, CGPath)] = [
            (.union, a.union(b, using: rule)),
            (.intersection, a.intersection(b, using: rule)),
            (.subtraction, a.subtracting(b, using: rule)),
            (.exclusiveOr, a.symmetricDifference(b, using: rule)),
        ]
        var rng = SeededGenerator(seed: 4242)
        let box = c.a.bounds.union(c.b.bounds).expanded(by: 2)
        for (operation, cg) in pairs {
            let ours = Boolean.perform(operation, c.a, c.b)
            var disagreements = 0
            var probes = 0
            for _ in 0..<60 {
                let p = Point(rng.double(in: box.minX...box.maxX), rng.double(in: box.minY...box.maxY))
                guard boundaryDistance(p, c.a) > 1e-2, boundaryDistance(p, c.b) > 1e-2 else {
                    continue
                }
                probes += 1
                if cg.contains(CGPoint(x: p.x, y: p.y), using: .winding) != ours.contains(p) {
                    disagreements += 1
                }
            }
            #expect(disagreements == 0, "\(operation): \(disagreements) of \(probes) probes disagree with Core Graphics")
        }
    }
}
#endif
