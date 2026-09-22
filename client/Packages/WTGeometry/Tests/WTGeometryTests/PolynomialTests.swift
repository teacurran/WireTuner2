import Testing
@testable import WTGeometry

@Suite struct PolynomialRootsTests {
    @Test func appendSubscriptAndCollection() {
        var roots = PolynomialRoots()
        #expect(roots.isEmpty)
        #expect(roots == PolynomialRoots.none)
        roots.append(3)
        roots.append(1)
        roots.append(2)
        #expect(roots.count == 3)
        #expect(roots[0] == 3 && roots[1] == 1 && roots[2] == 2)
        #expect(Array(roots) == [3, 1, 2])
        #expect(roots.startIndex == 0 && roots.endIndex == 3)
    }

    @Test func sortedCoversEveryPermutation() {
        let permutations: [[Double]] = [[1, 2, 3], [1, 3, 2], [2, 1, 3], [2, 3, 1], [3, 1, 2], [3, 2, 1]]
        for values in permutations {
            var roots = PolynomialRoots()
            for v in values {
                roots.append(v)
            }
            #expect(Array(roots.sorted()) == [1, 2, 3])
        }
        var two = PolynomialRoots()
        two.append(2)
        two.append(1)
        #expect(Array(two.sorted()) == [1, 2])
        var one = PolynomialRoots()
        one.append(5)
        #expect(Array(one.sorted()) == [5])
        #expect(PolynomialRoots.none.sorted().isEmpty)
    }
}

@Suite struct QuadraticRootsTests {
    @Test func twoRealRoots() {
        let roots = Polynomial.quadraticRoots(1, -3, 2)
        #expect(Array(roots) == [1, 2])
        // Ill-conditioned: small c relative to b, the naive formula cancels.
        let small = Polynomial.quadraticRoots(1, -1e8, 1)
        #expect(small.count == 2)
        #expect(approx(small[0], 1e-8, 1e-16))
        #expect(approx(small[1], 1e8, 1e-6))
        // Negative b exercises the other sign branch of the citardauq form.
        let negative = Polynomial.quadraticRoots(1, 1e8, 1)
        #expect(approx(negative[0], -1e8, 1e-6))
        #expect(approx(negative[1], -1e-8, 1e-16))
    }

    @Test func orderingWhenLargerRootComesSecondInFormula() {
        // a < 0 flips the order the formula produces; the result is still ascending.
        let roots = Polynomial.quadraticRoots(-1, 3, -2)
        #expect(Array(roots) == [1, 2])
    }

    @Test func doubleRootAndNearMiss() {
        #expect(Array(Polynomial.quadraticRoots(1, -2, 1)) == [1])
        // Discriminant negative only by rounding: 1e-13 relative.
        let graze = Polynomial.quadraticRoots(1, -2, 1 + 1e-14)
        #expect(graze.count == 1)
        #expect(approx(graze[0], 1))
        #expect(Polynomial.quadraticRoots(1, 0, 1).isEmpty)
    }

    @Test func degenerateDegrees() {
        #expect(Array(Polynomial.quadraticRoots(0, 2, -4)) == [2])
        #expect(Polynomial.quadraticRoots(0, 0, 1).isEmpty)
        #expect(Polynomial.quadraticRoots(0, 0, 0).isEmpty)
        #expect(Polynomial.quadraticRoots(.nan, 1, 1).isEmpty)
        #expect(Polynomial.quadraticRoots(.infinity, 1, 1).isEmpty)
        #expect(Array(Polynomial.quadraticRoots(1e-20, 2, -4)) == [2])
    }
}

@Suite struct CubicRootsTests {
    private func product(_ r1: Double, _ r2: Double, _ r3: Double) -> (Double, Double, Double, Double) {
        // (t - r1)(t - r2)(t - r3)
        (1, -(r1 + r2 + r3), r1 * r2 + r1 * r3 + r2 * r3, -r1 * r2 * r3)
    }

    @Test func threeDistinctRoots() {
        let (a, b, c, d) = product(-1, 0.5, 2)
        let roots = Polynomial.cubicRoots(a, b, c, d)
        #expect(roots.count == 3)
        #expect(approx(roots[0], -1) && approx(roots[1], 0.5) && approx(roots[2], 2))
        let scaled = Polynomial.cubicRoots(-3 * a, -3 * b, -3 * c, -3 * d)
        #expect(scaled.count == 3 && approx(scaled[2], 2))
    }

    @Test func oneRealRoot() {
        // t³ + t + 2 = (t + 1)(t² - t + 2); the quadratic factor has no real roots.
        let roots = Polynomial.cubicRoots(1, 0, 1, 2)
        #expect(roots.count == 1)
        #expect(approx(roots[0], -1))
        // Touch tolerance without a near-touch adds nothing when the cubic is monotone (aa > 0).
        #expect(Polynomial.cubicRoots(1, 0, 1, 2, touchTolerance: 1e-6).count == 1)
    }

    @Test func doubleRootIsReportedOnce() {
        let (a, b, c, d) = product(1, 1, -2)
        let roots = Polynomial.cubicRoots(a, b, c, d)
        #expect(roots.count == 2)
        #expect(approx(roots[0], -2) && approx(roots[1], 1))
    }

    @Test func tripleRoot() {
        let (a, b, c, d) = product(0.5, 0.5, 0.5)
        let roots = Polynomial.cubicRoots(a, b, c, d)
        #expect(roots.count == 1)
        #expect(approx(roots[0], 0.5, 1e-5))
    }

    @Test func nearDoubleRootMadeComplexByRoundingIsRecoveredWithTouchTolerance() {
        // (t - 1)²(t + 2) + ε: the double root at 1 becomes a pair of complex roots; the local
        // minimum at t = 1 sits ε above zero.
        let (a, b, c, d) = product(1, 1, -2)
        let epsilon = 1e-9
        let without = Polynomial.cubicRoots(a, b, c, d + epsilon)
        #expect(without.count == 1)
        let with = Polynomial.cubicRoots(a, b, c, d + epsilon, touchTolerance: 1e-6)
        #expect(with.count == 2)
        #expect(approx(with[0], -2, 1e-6) && approx(with[1], 1, 1e-4))
        // The mirrored polynomial exercises the other extremum branch.
        let mirrored = Polynomial.cubicRoots(-a, b, -c, d + epsilon, touchTolerance: 1e-6)
        #expect(mirrored.count == 2)
        #expect(approx(mirrored[0], -1, 1e-4) && approx(mirrored[1], 2, 1e-6))
    }

    @Test func degenerateDegrees() {
        #expect(Array(Polynomial.cubicRoots(0, 1, -3, 2)) == [1, 2])
        #expect(Polynomial.cubicRoots(0, 0, 0, 0).isEmpty)
        #expect(Polynomial.cubicRoots(.nan, 1, 1, 1).isEmpty)
        #expect(Array(Polynomial.cubicRoots(1e-20, 1, -3, 2)) == [1, 2])
    }

    @Test func evaluateCubic() {
        #expect(Polynomial.evaluateCubic(1, 2, 3, 4, at: 2) == 8 + 8 + 6 + 4)
    }

    @Test func polishStopsWhenExactOrNotImproving() {
        // Exact root: the loop breaks on f == 0.
        #expect(Polynomial.polish(1, 0, -1, 0, 1) == 1)
        // A start at a stationary point (df == 0) stays put.
        #expect(Polynomial.polish(1, 0, -3, 5, 1) == 1)
        // A start already at the nearest attainable precision does not get worse.
        let polished = Polynomial.polish(1, -3, 3, -1, 1.5)
        #expect(abs(Polynomial.evaluateCubic(1, -3, 3, -1, at: polished)) <= abs(Polynomial.evaluateCubic(1, -3, 3, -1, at: 1.5)))
    }
}
