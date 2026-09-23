import Testing
@testable import WTGeometry

@Suite struct CurveLineIntersectionTests {
    let axis = Line(Point(-1, 0), Point(4, 0))

    @Test func intersectionValue() {
        let i = Intersection(t: 0.25, u: 0.5, point: Point(1, 1))
        #expect(i.t == 0.25 && i.u == 0.5 && i.point == Point(1, 1))
    }

    @Test func sCurveCrossesTheAxisThreeTimes() {
        let hits = sCurve.intersections(with: axis)
        #expect(hits.count == 3)
        #expect(approx(hits[0].t, 0, 1e-9) && approx(hits[1].t, 0.5, 1e-9) && approx(hits[2].t, 1, 1e-9))
        for hit in hits {
            #expect(approx(hit.point.y, 0, 1e-9))
            #expect(approx(axis.evaluate(hit.u), hit.point, 1e-9))
        }
    }

    @Test func lineThatMissesFindsNothing() {
        #expect(sCurve.intersections(with: Line(Point(-1, 5), Point(4, 5))).isEmpty)
        // Parallel to the axis but only spanning x in 1.2...1.8: the middle crossing at x = 1.5
        // is the only one on the segment.
        let short = Line(Point(1.2, 0), Point(1.8, 0))
        let hits = sCurve.intersections(with: short)
        #expect(hits.count == 1)
        #expect(approx(hits[0].t, 0.5, 1e-9))
        #expect(approx(hits[0].u, 0.5, 1e-9))
    }

    @Test func tangencyCountsOnce() {
        // A line at the curve's maximum y touches it in one (double) root.
        let top = sCurve.bounds.maxY
        let tangent = Line(Point(-1, top), Point(4, top))
        let hits = sCurve.intersections(with: tangent)
        #expect(hits.count == 1)
        #expect(approx(hits[0].point.y, top, 1e-9))
        // Slightly above: nothing.  Slightly below: two crossings.
        #expect(sCurve.intersections(with: Line(Point(-1, top + 1e-3), Point(4, top + 1e-3))).isEmpty)
        #expect(sCurve.intersections(with: Line(Point(-1, top - 1e-3), Point(4, top - 1e-3))).count == 2)
        // Grazing within the point tolerance still reports the touch; beyond it does not.
        #expect(sCurve.intersections(with: Line(Point(-1, top + 1e-8), Point(4, top + 1e-8))).count == 1)
        #expect(sCurve.intersections(with: Line(Point(-1, top + 1e-8), Point(4, top + 1e-8)), pointTolerance: 1e-10).isEmpty)
    }

    @Test func quadraticTangency() {
        // y(t) = 3t(1 − t) is a parabola; its top is at 0.75 exactly, so the discriminant of the
        // (quadratic) distance polynomial is exactly zero.
        let parabola = CubicBezier(Point(0, 0), Point(1, 1), Point(2, 1), Point(3, 0))
        let hits = parabola.intersections(with: Line(Point(-1, 0.75), Point(4, 0.75)))
        #expect(hits.count == 1)
        #expect(approx(hits[0].t, 0.5, 1e-9))
    }

    @Test func selfIntersectingCurveAgainstLines() {
        for line in [
            Line(Point(-5, 1), Point(5, 1)),
            Line(Point(-5, 2), Point(5, 2)),
            Line(Point(0.5, -1), Point(0.5, 4)),
            Line(Point(-2, -1), Point(3, 4)),
        ] {
            let hits = loopCurve.intersections(with: line)
            #expect(hits.count == sampledCrossings(of: loopCurve, with: line), "\(line)")
            for hit in hits {
                #expect(approx(line.signedDistance(to: hit.point), 0, 1e-9))
            }
        }
    }

    @Test func lineThroughTheSelfCrossingReportsBothBranches() {
        // The loop's self-crossing is where B(t1) == B(t2); find it from two branches' nearest
        // approach by intersecting the loop with itself is not possible, so locate it by
        // symmetry of y(t) = 9t(1 − t): both branches share y, and x(t) == x(1 − t) solves
        // 12t(1−t)² − 9t²(1−t) + t³ symmetric... numerically instead.
        var best = (t: 0.0, gap: Double.infinity)
        for i in 1..<500 {
            let t = Double(i) / 1000
            let gap = loopCurve.evaluate(t).distance(to: loopCurve.evaluate(1 - t))
            if gap < best.gap {
                best = (t, gap)
            }
        }
        // Refine by bisection on x(t) − x(1 − t).
        var lo = best.t - 0.001
        var hi = best.t + 0.001
        let f = { (t: Double) in loopCurve.evaluate(t).x - loopCurve.evaluate(1 - t).x }
        for _ in 0..<80 {
            let mid = (lo + hi) / 2
            if (f(mid) < 0) == (f(lo) < 0) {
                lo = mid
            } else {
                hi = mid
            }
        }
        let crossing = loopCurve.evaluate((lo + hi) / 2)
        // The loop is symmetric about x = 0.5, so the vertical through the crossing also meets
        // the top of the loop at t = 0.5: three intersections, two of them at one point.
        let line = Line(Point(crossing.x, -1), Point(crossing.x, 4))
        let hits = loopCurve.intersections(with: line)
        #expect(hits.count == 3)
        #expect(approx(hits[0].point, crossing, 1e-6))
        #expect(approx(hits[2].point, crossing, 1e-6))
        #expect(approx(hits[1].t, 0.5, 1e-9))
        #expect(approx(hits[1].point, Point(0.5, 2.25), 1e-9))
        #expect(abs(hits[0].t - hits[2].t) > 0.1)
    }

    @Test func degenerateLineAndCollinearCurve() {
        #expect(sCurve.intersections(with: Line(Point(1, 1), Point(1, 1))).isEmpty)
        let straight = Line(Point(0, 0), Point(3, 0)).elevated()
        #expect(straight.intersections(with: axis).isEmpty)
    }

    @Test func rootToleranceAdmitsEndpointGrazes() {
        // The curve ends exactly on the line's end; rounding may put the root just past 1.
        let curve = CubicBezier(Point(0, 1), Point(1, 1), Point(2, 1), Point(3, 0))
        let line = Line(Point(0, 0), Point(3, 0))
        let hits = curve.intersections(with: line)
        #expect(hits.count == 1)
        #expect(hits[0].t == 1 && hits[0].u == 1)
        // A line that ends short of the crossing by more than the point tolerance misses.
        #expect(curve.intersections(with: Line(Point(0, 0), Point(2.9, 0))).isEmpty)
    }

    @Test func quadraticArgumentIsElevated() {
        let quad = QuadraticBezier(Point(0, 0), Point(2, 4), Point(4, 0))
        let cubic = Line(Point(0, 1), Point(4, 1)).elevated()
        let hits = cubic.intersections(with: quad)
        #expect(hits.count == 2)
        for hit in hits {
            #expect(approx(quad.evaluate(hit.u), hit.point, 1e-6))
        }
    }
}

@Suite struct CurveCurveIntersectionTests {
    @Test func mirroredSCurvesMeetThreeTimes() {
        let mirrored = CubicBezier(Point(0, 0), Point(1, -3), Point(2, 3), Point(3, 0))
        let hits = sCurve.intersections(with: mirrored)
        #expect(hits.count == 3)
        #expect(approx(hits[0].t, 0, 1e-6) && approx(hits[1].t, 0.5, 1e-6) && approx(hits[2].t, 1, 1e-6))
        for hit in hits {
            #expect(approx(sCurve.evaluate(hit.t), mirrored.evaluate(hit.u), 1e-6))
        }
    }

    @Test func archAndLineLikeCubic() {
        let arch = CubicBezier(Point(0, 0), Point(0, 4), Point(4, 4), Point(4, 0))
        let crossing = Line(Point(-1, 1.5), Point(5, 1.5)).elevated()
        let hits = arch.intersections(with: crossing)
        #expect(hits.count == 2)
        #expect(approx(hits[0].t, 1 - hits[1].t, 1e-6))
        for hit in hits {
            #expect(approx(hit.point.y, 1.5, 1e-6))
        }
        // Compare with the analytic route.
        let analytic = arch.intersections(with: Line(Point(-1, 1.5), Point(5, 1.5)))
        #expect(analytic.count == 2)
        #expect(approx(analytic[0].t, hits[0].t, 1e-6) && approx(analytic[1].t, hits[1].t, 1e-6))
    }

    @Test func disjointCurvesDoNotMeet() {
        let far = sCurve.applying(.translation(x: 0, y: 10))
        #expect(sCurve.intersections(with: far).isEmpty)
        // Hulls overlap but the curves do not.
        let near = CubicBezier(Point(0, 1), Point(1, 1), Point(2, 1), Point(3, 1))
        let hits = CubicBezier(Point(0, 0.5), Point(1, 0.5), Point(2, 1.5), Point(3, 1.5)).intersections(with: near)
        #expect(hits.count == 1)
        let miss = CubicBezier(Point(0, 0), Point(1, 0.5), Point(2, 0.5), Point(3, 0)).intersections(with: near)
        #expect(miss.isEmpty)
    }

    @Test func externallyTangentArcsMeetOnce() {
        // Two quarter circles of radius 1 whose circles touch at the origin: centers (−1, 0)
        // and (1, 0), arcs facing each other.
        let left = quarterCircle(center: Point(-1, 0), radius: 1)  // from (0, 0) toward (−1, 1)
        let right = quarterCircle(center: Point(1, 0), radius: 1).applying(.rotation(radians: .pi, around: Point(1, 0)))  // from (0, 0) toward (1, −1)
        #expect(approx(left.p0, Point(0, 0)) && approx(right.p0, Point(0, 0), 1e-12))
        let hits = left.intersections(with: right)
        #expect(hits.count == 1)
        #expect(approx(hits[0].point, Point(0, 0), 1e-6))

        // Interior tangency away from the ends: an arch and its copy shifted down so their
        // apexes touch from opposite sides.
        let arch = CubicBezier(Point(0, 0), Point(0, 4), Point(4, 4), Point(4, 0))
        let apex = arch.evaluate(0.5).y
        let upsideDown = arch.applying(.scale(x: 1, y: -1)).applying(.translation(x: 0, y: 2 * apex))
        let touch = arch.intersections(with: upsideDown)
        #expect(touch.count == 1)
        #expect(approx(touch[0].t, 0.5, 1e-3))
        #expect(approx(touch[0].point.y, apex, 1e-6))
    }

    @Test func coincidentCurvesTerminate() {
        let hits = sCurve.intersections(with: sCurve)
        #expect(hits.count <= 64)
        var overlap: [Intersection] = []
        let elapsed = ContinuousClock().measure {
            overlap = sCurve.intersections(with: sCurve.subdivide(from: 0.2, to: 0.7))
        }
        #expect(overlap.count <= 64)
        PerfBudget.expect(elapsed, within: .seconds(2))
    }

    @Test func nineIntersections() {
        // Two curves that weave through each other: each has three long strokes (one
        // coordinate 3-to-1 with heavy overshoot, the other monotone), one horizontal and one
        // vertical, with unequal extents so no end points coincide.  Every stroke of one crosses
        // every stroke of the other: 3 × 3 = 9, the maximum for two cubics.  Verified against a
        // 2000-segment polyline intersection count.
        let horizontal = CubicBezier(Point(-10, 0), Point(68, 10.0 / 3), Point(-68, 20.0 / 3), Point(10, 10))
        let vertical = CubicBezier(Point(0, -12), Point(8.0 / 3, 82), Point(16.0 / 3, -82), Point(8, 12))
        let hits = horizontal.intersections(with: vertical)
        #expect(hits.count == 9)
        for hit in hits {
            #expect(approx(horizontal.evaluate(hit.t), vertical.evaluate(hit.u), 1e-6))
        }
        // Symmetric query: the same nine crossings seen from the other curve.
        let reverse = vertical.intersections(with: horizontal)
        #expect(reverse.count == 9)
        for hit in reverse {
            #expect(hits.contains { approx($0.point, hit.point, 1e-6) })
        }
    }

    @Test func randomPairsAgreeWithSubdivisionReference() {
        var rng = SeededGenerator(seed: 11)
        for _ in 0..<40 {
            let a = rng.cubic(in: -20...20)
            let b = rng.cubic(in: -20...20)
            let hits = a.intersections(with: b)
            for hit in hits {
                #expect(approx(a.evaluate(hit.t), b.evaluate(hit.u), 1e-6))
                #expect(hit.t >= 0 && hit.t <= 1 && hit.u >= 0 && hit.u <= 1)
            }
            // Consecutive results are distinct intersections.
            for i in 1..<max(hits.count, 1) where hits.count > 1 {
                let gap = hits[i].point.distance(to: hits[i - 1].point)
                #expect(gap > 1e-3 || abs(hits[i].t - hits[i - 1].t) > 0.01 || abs(hits[i].u - hits[i - 1].u) > 0.01)
            }
        }
    }
}
