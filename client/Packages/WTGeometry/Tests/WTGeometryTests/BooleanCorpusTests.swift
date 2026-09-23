import Foundation
import Testing
@testable import WTGeometry

/// GEO-002's reference corpus (testing.adoc: "a corpus of 200 boolean cases including
/// tangencies"; OBJ-025 runs the same cases through the commands).
@Suite struct BooleanCorpusTests {
    @Test func corpusIsLargeEnough() {
        #expect(BooleanCorpus.all.count >= 200, "\(BooleanCorpus.all.count)")
    }

    @Test(arguments: BooleanCorpus.all)
    func corpusCase(_ c: BooleanCase) {
        let union = Boolean.union(c.a, c.b)
        let intersection = Boolean.intersection(c.a, c.b)
        let difference = Boolean.subtracting(c.a, c.b)
        let exclusive = Boolean.exclusiveOr(c.a, c.b)
        let areaA = filledArea(c.a)
        let areaB = filledArea(c.b)
        let scale = max(1, areaA + areaB)
        let results: [(BooleanOperation, FilledPath)] = [
            (.union, union), (.intersection, intersection), (.subtraction, difference), (.exclusiveOr, exclusive),
        ]
        for (operation, result) in results {
            let area = result.signedArea()
            #expect(area >= -1e-9 * scale, "\(operation) area \(area)")
            // Normalized: the exact area agrees with the flattened polygon's.
            #expect(abs(flattenedArea(result, samples: 512) - area) <= 1e-5 * scale, "\(operation) flattened")
            #expect(result.fillRule == .nonZero)
            for contour in result.contours {
                #expect(contour.isClosed && contour.startPoint == contour.endPoint)
            }
        }
        // Area conservation.
        let u = union.signedArea()
        let i = intersection.signedArea()
        let tolerance = 1e-6 * scale
        #expect(abs(u + i - (areaA + areaB)) <= tolerance, "|A∪B| + |A∩B| = \(u + i), |A| + |B| = \(areaA + areaB)")
        #expect(abs(difference.signedArea() - (areaA - i)) <= tolerance, "|A−B|")
        #expect(abs(exclusive.signedArea() - (u - i)) <= tolerance, "|A⊕B|")

        // Containment probes away from every boundary.
        var rng = SeededGenerator(seed: UInt64(abs(c.name.hashValue % 100_000)) &+ 17)
        var box = c.a.bounds.union(c.b.bounds)
        if box.isNull {
            box = Rect(minX: -1, minY: -1, maxX: 1, maxY: 1)
        }
        box = box.expanded(by: 2)
        let divide = Boolean.divide([c.a, c.b])
        var checked = 0
        for _ in 0..<80 {
            let p = Point(rng.double(in: box.minX...box.maxX), rng.double(in: box.minY...box.maxY))
            guard boundaryDistance(p, c.a) > 1e-3, boundaryDistance(p, c.b) > 1e-3 else {
                continue
            }
            checked += 1
            let inA = c.a.contains(p)
            let inB = c.b.contains(p)
            for (operation, result) in results {
                #expect(result.contains(p) == operation.includes(inA, inB), "\(operation) at \(p)")
                var evenOdd = result
                evenOdd.fillRule = .evenOdd
                #expect(evenOdd.contains(p) == result.contains(p), "\(operation) not normalized at \(p)")
            }
            let covering = divide.filter { $0.path.contains(p) }
            if inA || inB {
                #expect(covering.count == 1, "divide pieces at \(p): \(covering.count)")
                let expected = [inA ? 0 : nil, inB ? 1 : nil].compactMap { $0 }
                #expect(covering.first?.operands == expected, "divide operands at \(p)")
            } else {
                #expect(covering.isEmpty, "divide piece outside at \(p)")
            }
        }
        #expect(checked > 0)
        let divided = divide.reduce(0) { $0 + $1.path.signedArea() }
        #expect(abs(divided - u) <= tolerance, "divide area \(divided) vs union \(u)")
    }
}
