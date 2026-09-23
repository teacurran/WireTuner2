import Foundation
import Testing
@testable import WTGeometry

/// GEO-005: the priority order of `moving` / `grid-guides` ("a point wins over a path, a path
/// over a guide, a guide over a smart guide, and a smart guide over the grid"), tie-breaking,
/// the pixel-to-pasteboard snap distance, and the candidate geometry.
@Suite struct SnappingTests {
    /// The query point.
    let query = Point(100, 100)

    /// A candidate of `kind` whose snap position is `distance` from the query, in direction
    /// `angle`, so different kinds can be placed at controlled distances.
    func candidate(_ kind: SnapKind, distance: Double, angle: Double = 0) -> SnapCandidate {
        let target = query + Vector(angle: angle, length: distance)
        switch kind {
        case .point:
            return .point(target)
        case .path:
            // A vertical segment through the target: nearest point is the target itself when
            // the offset is horizontal.
            let offset = Vector(angle: angle + .pi / 2, length: 20)
            return .segment(Line(target - offset, target + offset).elevated())
        case .guide:
            return .guide(.angled(through: target, direction: Vector(angle: angle + .pi / 2)))
        case .smartGuide:
            return .smartGuide(.angled(through: target, direction: Vector(angle: angle + .pi / 2)))
        case .grid:
            // A lattice with an intersection at the target and none nearer.
            return .grid(SnapGrid(origin: target, size: 1000))
        }
    }

    @Test func priorityOrderIsTheDocumented() {
        #expect(SnapKind.allCases == [.point, .path, .guide, .smartGuide, .grid])
        #expect(SnapKind.point < .path && .path < .guide && .guide < .smartGuide && .smartGuide < .grid)
    }

    /// Every non-empty subset of the five kinds, each placed within range, in both list orders
    /// and with the higher-priority kind farther away: the highest-priority kind present wins.
    @Test(arguments: 1..<32)
    func everyCombinationOfKinds(mask: Int) {
        let kinds = SnapKind.allCases.filter { mask & (1 << $0.rawValue) != 0 }
        let snapper = Snapper(snapDistance: 3, zoom: 1)
        let expected = kinds.min()!
        // Higher priority placed farther: priority must beat distance.
        var farFirst: [SnapCandidate] = []
        for kind in kinds {
            let distance = 0.5 + 2.0 * Double(SnapKind.grid.rawValue - kind.rawValue) / 4  // point at 2.5, grid at 0.5
            farFirst.append(candidate(kind, distance: distance, angle: Double(kind.rawValue)))
        }
        for list in [farFirst, farFirst.reversed()] {
            let result = snapper.resolve(query, candidates: list)
            #expect(result?.kind == expected, "kinds \(kinds)")
            if let result {
                #expect(list[result.candidateIndex] == result.candidate)
                #expect(result.candidate.kind == expected)
                #expect(approx(result.distance, result.point.distance(to: query), 1e-9) || result.secondaryIndex != nil)
            }
        }
        // Out of range, the higher-priority kinds drop out and the rest compete.
        var outOfRange: [SnapCandidate] = []
        for kind in kinds {
            outOfRange.append(candidate(kind, distance: kind == expected ? 3.5 : 1, angle: Double(kind.rawValue)))
        }
        let remaining = kinds.filter { $0 != expected }
        #expect(snapper.resolve(query, candidates: outOfRange)?.kind == remaining.min())
    }

    /// Every ordered pair of kinds: the higher-priority one wins wherever each sits in range;
    /// with the winner's toggle off, the other one takes over.
    @Test(arguments: SnapKind.allCases, SnapKind.allCases)
    func pairwise(first: SnapKind, second: SnapKind) {
        guard first != second else {
            return
        }
        let snapper = Snapper()
        let winner = min(first, second)
        let loser = max(first, second)
        for (d1, d2) in [(0.2, 2.9), (2.9, 0.2), (1.0, 1.0)] {
            let list = [candidate(first, distance: d1, angle: 0.3), candidate(second, distance: d2, angle: 2.1)]
            #expect(snapper.resolve(query, candidates: list)?.kind == winner)
            var disabled = snapper
            disabled.enabledKinds.remove(winner)
            #expect(disabled.resolve(query, candidates: list)?.kind == loser)
        }
    }

    @Test func tiesBreakByDistanceThenListOrder() {
        let snapper = Snapper()
        for kind in SnapKind.allCases {
            let near = candidate(kind, distance: 1, angle: 0.5)
            let far = candidate(kind, distance: 2, angle: 2.5)
            #expect(snapper.resolve(query, candidates: [far, near])?.candidateIndex == 1, "\(kind)")
            #expect(snapper.resolve(query, candidates: [near, far])?.candidateIndex == 0, "\(kind)")
        }
        // Equal distance, equal kind: the earlier candidate wins.
        let a = SnapCandidate.point(query + Vector(1, 0))
        let b = SnapCandidate.point(query + Vector(-1, 0))
        #expect(snapper.resolve(query, candidates: [a, b])?.candidateIndex == 0)
        #expect(snapper.resolve(query, candidates: [b, a])?.candidateIndex == 0)
    }

    @Test func snapDistanceIsInViewPixels() {
        let target = SnapCandidate.point(query + Vector(2, 0))
        #expect(Snapper(snapDistance: 3, zoom: 1).resolve(query, candidates: [target]) != nil)
        // At 200% three pixels are 1.5 pt: the point 2 pt away is out of reach.
        #expect(Snapper(snapDistance: 3, zoom: 2).resolve(query, candidates: [target]) == nil)
        // At 50% three pixels are 6 pt.
        #expect(Snapper(snapDistance: 3, zoom: 0.5).resolve(query, candidates: [SnapCandidate.point(query + Vector(5, 0))]) != nil)
        #expect(approx(Snapper(snapDistance: 3, zoom: 16).pasteboardSnapDistance, 3.0 / 16))
        #expect(Snapper(snapDistance: 3, zoom: 0).pasteboardSnapDistance == 3)
        #expect(Snapper(snapDistance: 3, zoom: .nan).pasteboardSnapDistance == 3)
        // Exactly at the snap distance counts as in range.
        #expect(Snapper(snapDistance: 2, zoom: 1).resolve(query, candidates: [target]) != nil)
    }

    @Test func nothingInRangeOrNothingEnabled() {
        let snapper = Snapper()
        #expect(snapper.resolve(query, candidates: []) == nil)
        #expect(snapper.resolve(query, candidates: [candidate(.point, distance: 10)]) == nil)
        let none = Snapper(enabledKinds: [])
        #expect(none.resolve(query, candidates: SnapKind.allCases.map { candidate($0, distance: 0.1) }) == nil)
        #expect(snapper.resolve(Point(.nan, 0), candidates: [.point(.zero)]) == nil)
        // Degenerate candidates are skipped, not snapped to.
        #expect(snapper.resolve(query, candidates: [.path(Contour(segments: [], closed: false))]) == nil)
        #expect(snapper.resolve(query, candidates: [.guide(.angled(through: query, direction: .zero))]) == nil)
    }

    @Test func candidateGeometry() {
        let square = Contour(polygon: [Point(0, 0), Point(10, 0), Point(10, 10), Point(0, 10)])
        #expect(approx(SnapCandidate.path(square).nearestPoint(to: Point(5, 1))!, Point(5, 0)))
        #expect(SnapCandidate.path(square).kind == .path)
        #expect(approx(SnapCandidate.segment(sCurve).nearestPoint(to: Point(0, -1))!, Point(0, 0), 1e-6))
        #expect(SnapCandidate.guide(.horizontal(y: 7)).nearestPoint(to: Point(3, 6)) == Point(3, 7))
        #expect(SnapCandidate.smartGuide(.vertical(x: 7)).nearestPoint(to: Point(3, 6)) == Point(7, 6))
        #expect(SnapCandidate.point(.zero).guide == nil)
        // A guide object snaps along its path but ranks as a guide: below a path, above a
        // smart guide.
        let circular = SnapCandidate.guideObject(circle(center: Point(0, 0), radius: 10))
        #expect(circular.kind == .guide && circular.guide == nil)
        #expect(approx(circular.nearestPoint(to: Point(11, 0))!, Point(10, 0), 1e-6))
        let snapper = Snapper()
        let near = Point(11, 0)
        #expect(snapper.resolve(near, candidates: [circular, .segment(Line(Point(12, -5), Point(12, 5)).elevated())])?.kind == .path)
        #expect(snapper.resolve(near, candidates: [.smartGuide(.vertical(x: 11.2)), circular])?.candidateIndex == 1)
        let diagonal = SnapGuide.angled(through: .zero, direction: Vector(1, 1))
        #expect(approx(diagonal.nearestPoint(to: Point(2, 0))!, Point(1, 1)))
        #expect(approx(SnapGuide.horizontal(y: 3).intersection(with: .vertical(x: 4))!, Point(4, 3)))
        #expect(SnapGuide.horizontal(y: 3).intersection(with: .horizontal(y: 5)) == nil)
        #expect(SnapGuide.angled(through: .zero, direction: .zero).intersection(with: .vertical(x: 1)) == nil)
        #expect(approx(diagonal.intersection(with: .vertical(x: 4))!, Point(4, 4)))
    }

    @Test func gridAbsoluteAndRelative() {
        let grid = SnapGrid(size: 10)
        #expect(grid.nearestIntersection(to: Point(13, 26)) == Point(10, 30))
        #expect(grid.nearestIntersection(to: Point(-13, -26)) == Point(-10, -30))
        let offset = SnapGrid(origin: Point(2, 3), spacing: Vector(10, 20))
        #expect(offset.nearestIntersection(to: Point(13, 26)) == Point(12, 23))
        // Relative grid: a point that started 3 pt right of a line lands 3 pt right of a line.
        let start = Point(3, 0)
        let relative = grid.relative(to: start)
        let landed = relative.nearestIntersection(to: Point(24, 1))
        #expect(landed == Point(23, 0))
        #expect(landed.x.truncatingRemainder(dividingBy: 10) == 3)
        // A zero spacing leaves that axis alone.
        #expect(SnapGrid(spacing: Vector(0, 5)).nearestIntersection(to: Point(1.3, 6)) == Point(1.3, 5))
    }

    @Test func guidesCombineAtTheirCrossing() {
        let snapper = Snapper(snapDistance: 3)
        let p = Point(50.5, 80.8)
        let candidates: [SnapCandidate] = [
            .guide(.vertical(x: 50)),
            .guide(.horizontal(y: 81)),
            .grid(SnapGrid(size: 1000)),
        ]
        let result = snapper.resolve(p, candidates: candidates)!
        #expect(result.kind == .guide)
        #expect(result.candidateIndex == 1)  // 0.2 away beats 0.5 away
        #expect(result.secondaryIndex == 0)
        #expect(result.point == Point(50, 81))
        // A smart guide crossing a ruler guide combines too.
        let mixed = snapper.resolve(p, candidates: [.guide(.vertical(x: 50)), .smartGuide(.horizontal(y: 82))])!
        #expect(mixed.kind == .guide && mixed.secondaryIndex == 1 && mixed.point == Point(50, 82))
        // Parallel guides do not combine; a disabled kind does not either.
        let parallel = snapper.resolve(p, candidates: [.guide(.vertical(x: 50)), .guide(.vertical(x: 51))])!
        #expect(parallel.secondaryIndex == nil)
        var noSmart = snapper
        noSmart.enabledKinds.remove(.smartGuide)
        #expect(noSmart.resolve(p, candidates: [.guide(.vertical(x: 50)), .smartGuide(.horizontal(y: 82))])!.secondaryIndex == nil)
        // A crossing beyond reach is not taken even when both guides are in reach.
        let slanted = snapper.resolve(Point(0, 0), candidates: [
            .guide(.horizontal(y: 1)), .guide(.angled(through: Point(0, -1), direction: Vector(1, 0.001))),
        ])!
        #expect(slanted.secondaryIndex == nil)
    }

    @Test func dragResolution() {
        let snapper = Snapper()
        let (delta, snap) = snapper.resolveDrag(of: Point(0, 0), by: Vector(9, 0), candidates: [.point(Point(10, 1))])
        #expect(delta == Vector(10, 1))
        #expect(snap?.kind == .point)
        let (free, none) = snapper.resolveDrag(of: Point(0, 0), by: Vector(50, 0), candidates: [.point(Point(10, 1))])
        #expect(free == Vector(50, 0) && none == nil)
    }

    @Test func snapperIsSendableValue() {
        let snapper = Snapper(snapDistance: 4, zoom: 2, enabledKinds: [.grid])
        let copy = snapper
        #expect(copy == snapper)
        let result = SnapResult(point: .zero, candidate: .point(.zero), candidateIndex: 0, kind: .point, distance: 0)
        #expect(result.secondaryIndex == nil)
    }
}

@Suite struct ConstraintTests {
    @Test func angleHelpers() {
        #expect(Vector.zero.angle == 0)
        #expect(approx(Vector(0, 1).angle, .pi / 2))
        #expect(approx(Vector(angle: .pi, length: 2), Vector(-2, 0), 1e-12))
        #expect(approx(Vector(1, 0).rotated(by: .pi / 2), Vector(0, 1), 1e-12))
    }

    @Test func snapsToFortyFiveDegreeMultiplesOfTheBase() {
        let c = AngleConstraint.standard
        #expect(approx(c.constrain(Vector(10, 1)), Vector(10, 0)))
        #expect(approx(c.constrain(Vector(1, 10)), Vector(0, 10)))
        let diagonal = c.constrain(Vector(10, 9))
        #expect(approx(diagonal.dx, diagonal.dy, 1e-12))
        // Projection: the constrained length is the travel along the chosen direction.
        #expect(approx(c.constrain(Vector(10, 3)).length, 10))
        #expect(c.constrain(.zero) == .zero)
        #expect(approx(c.constrain(Point(12, 1), from: Point(2, 0)), Point(12, 0)))
        #expect(c.directions.count == 8)
    }

    @Test func customBaseAngle() {
        // 30°: the isometric constraint (`transforming`, "Constrain angle").
        let iso = AngleConstraint.degrees(30)
        let v = iso.constrain(Vector(angle: 32 * .pi / 180, length: 5))
        #expect(approx(v.angle, 30 * .pi / 180, 1e-12))
        let w = iso.constrain(Vector(angle: 80 * .pi / 180, length: 5))
        #expect(approx(w.angle, 75 * .pi / 180, 1e-12))
        #expect(approx(iso.snappedAngle(-.pi), -195 * .pi / 180, 1e-12))  // (−180 − 30) / 45 rounds to −5
        #expect(approx(iso.directions[0].angle, 30 * .pi / 180, 1e-12))
        // A halfway direction goes to the larger multiple.
        #expect(approx(AngleConstraint.standard.snappedAngle(.pi / 8), .pi / 4, 1e-12))
    }

    @Test func rotationIgnoresTheBase() {
        let iso = AngleConstraint.degrees(30)
        #expect(approx(iso.snappedRotation(50 * .pi / 180), .pi / 4, 1e-12))
        #expect(approx(iso.snappedRotation(-100 * .pi / 180), -.pi / 2, 1e-12))
    }

    @Test func degenerateSteps() {
        let free = AngleConstraint(baseAngle: 0, step: 0)
        #expect(free.snappedAngle(0.3) == 0.3)
        #expect(free.snappedRotation(0.3) == 0.3)
        #expect(free.constrain(Vector(3, 1)) == Vector(3, 1))
        #expect(free.directions.isEmpty)
        #expect(AngleConstraint(step: 1).directions.isEmpty)  // 1 rad does not divide a turn
        #expect(AngleConstraint.standard.snappedAngle(.infinity) == .infinity)
        #expect(AngleConstraint.standard.constrain(Vector(.nan, 1)).dx.isNaN)
    }

    @Test func transformUtilities() {
        let center = Point(5, 5)
        #expect(approx(AffineTransform.scale(2, around: center).apply(Point(6, 5)), Point(7, 5)))
        #expect(approx(AffineTransform.scale(x: 2, y: 3, around: center).apply(Point(6, 6)), Point(7, 8)))
        #expect(approx(AffineTransform.shear(x: 1, y: 0).apply(Point(0, 2)), Point(2, 2)))
        #expect(approx(AffineTransform.skew(xAngle: .pi / 4, yAngle: 0).apply(Point(0, 2)), Point(2, 2), 1e-12))
        #expect(approx(AffineTransform.skew(xAngle: .pi / 4, yAngle: 0, around: center).apply(center), center, 1e-12))
        let mirror = AffineTransform.reflection(across: Line(Point(0, 0), Point(1, 1)))!
        #expect(approx(mirror.apply(Point(2, 0)), Point(0, 2), 1e-12))
        #expect(approx(mirror.determinant, -1, 1e-12))
        let offsetMirror = AffineTransform.reflection(across: Line(Point(0, 3), Point(1, 3)))!
        #expect(approx(offsetMirror.apply(Point(4, 5)), Point(4, 1), 1e-12))
        #expect(AffineTransform.reflection(across: Line(.zero, .zero)) == nil)
    }

    @Test func decompositionRoundTrips() {
        var rng = SeededGenerator(seed: 5)
        for _ in 0..<100 {
            let t = AffineTransform(
                a: rng.double(in: -3...3), b: rng.double(in: -3...3), c: rng.double(in: -3...3),
                d: rng.double(in: -3...3), tx: rng.double(in: -50...50), ty: rng.double(in: -50...50))
            let parts = t.decomposed()
            let back = parts.transform
            for p in [Point(0, 0), Point(1, 0), Point(0, 1), Point(3, -2)] {
                #expect(approx(back.apply(p), t.apply(p), 1e-9))
            }
        }
        let plain = AffineTransform.rotation(radians: 0.4).concatenating(.translation(x: 3, y: 4)).decomposed()
        #expect(approx(plain.rotation, 0.4, 1e-12) && approx(plain.scaleX, 1, 1e-12) && approx(plain.scaleY, 1, 1e-12))
        #expect(approx(plain.skewX, 0, 1e-12) && plain.translation == Vector(3, 4))
        let flipped = AffineTransform.scale(x: 1, y: -1).decomposed()
        #expect(flipped.scaleY < 0)
        let collapsed = AffineTransform(a: 0, b: 0, c: 1, d: 2, tx: 0, ty: 0).decomposed()
        #expect(collapsed.scaleX == 0 && collapsed.rotation == 0)
        let flat = AffineTransform(a: 1, b: 0, c: 0, d: 0, tx: 0, ty: 0).decomposed()
        #expect(flat.skewX == 0)
    }
}
