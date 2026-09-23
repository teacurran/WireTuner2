import WTGeometry
import CoreGraphics
import Foundation
import Testing
@testable import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

/// ATTR-011: the nib swept along the path.
@Suite struct CalligraphicStrokeTests {
    static let tolerance = 0.01

    func contains(_ region: DisplayPath, _ point: Point) -> Bool {
        region.contours.reduce(0) { $0 + $1.windingNumber(at: point) } != 0
    }

    @Test func aStraightSweepIsTheHullOfTheNibAtBothEnds() {
        let nib = CalligraphicNib(width: 20, height: 8, angle: 30)
        let a = Point(x: 0, y: 0)
        let b = Point(x: 60, y: 25)
        let region = CalligraphicSweep.region(nib, path: DisplayPath(polygon: [a, b], closed: false), tolerance: Self.tolerance)
        // The analytic hull: the ellipse at every point of the segment.  A point is inside when
        // its distance, in the ellipse's frame, to the segment's image is at most 1.
        let rotation = AffineTransform.rotation(degrees: -30)
        func ellipseDistance(_ p: Point) -> Double {
            let local = { (q: Point) -> Point in let r = rotation.apply(q); return Point(x: r.x / 10, y: r.y / 4) }
            let pa = local(a), pb = local(b), pp = local(p)
            let ab = pb - pa
            let t = min(max((pp - pa).dot(ab) / ab.lengthSquared, 0), 1)
            return pp.distance(to: pa + ab * t)
        }
        var checked = 0
        for x in stride(from: -15.0, through: 75, by: 1.3) {
            for y in stride(from: -15.0, through: 40, by: 1.1) {
                let point = Point(x: x, y: y)
                let d = ellipseDistance(point)
                guard abs(d - 1) > 0.02 else { continue }  // within tolerance of the boundary
                #expect(contains(region, point) == (d < 1), "\(point): analytic \(d)")
                checked += 1
            }
        }
        #expect(checked > 3000)
    }

    @Test func cornersAndCuspsLeaveNoGapsAndNoSpikes() {
        let nib = CalligraphicNib(width: 10, height: 10)
        let zigzag = ReferenceCorpus.zigzag(x: 0, y: 0, width: 90, height: 60)
        let region = CalligraphicSweep.region(nib, path: zigzag, tolerance: Self.tolerance)
        let arc = ArcLengthPath(contour: zigzag.contours[0], tolerance: 0.01)
        // No gaps: everything within 4.9 of the path (the nib's radius less the tolerance).
        for step in 0...200 {
            let location = arc.location(at: arc.length * Double(step) / 200)
            for offset in [-4.9, -2.0, 0, 2.0, 4.9] {
                let point = location.point + location.tangent.perpendicular * offset
                #expect(contains(region, point), "gap at \(point)")
            }
        }
        // No spikes: every vertex of the sweep lies within the nib's radius of the path.
        let flat = zigzag.contours[0]
        for contour in region.contours {
            for segment in contour.segments {
                let nearest = flat.nearestPoint(to: segment.p0)!
                #expect(nearest.distance <= 5 + 1e-6)
            }
        }
        // A cusp: a path that doubles back on itself.
        let cusp = DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 50, y: 0), Point(x: 10, y: 0)], closed: false)
        let folded = CalligraphicSweep.region(CalligraphicNib(width: 6, height: 6), path: cusp, tolerance: Self.tolerance)
        #expect(contains(folded, Point(x: 52.9, y: 0)) && !contains(folded, Point(x: 53.2, y: 0)))
    }

    @Test func customNibsSweepTheirOwnShape() {
        let triangle = DisplayPath(polygon: [Point(x: 0.5, y: 0), Point(x: -0.5, y: 0.5), Point(x: -0.5, y: -0.5)])
        let nib = CalligraphicNib(width: 10, height: 10, shape: triangle)
        let polygon = CalligraphicSweep.nibPolygon(nib, tolerance: 0.01)
        #expect(polygon.count == 3)
        let region = CalligraphicSweep.region(nib, path: DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 0, y: 40)], closed: false), tolerance: 0.01)
        #expect(contains(region, Point(x: 4.9, y: 20)))
        #expect(!contains(region, Point(x: 4.9, y: -4)), "the triangle's tip sweeps a line, not a band")
        #expect(approx(CalligraphicSweep.signedArea([Point(x: 0, y: 0), Point(x: 1, y: 0), Point(x: 0, y: 1)]), 0.5))
        #expect(CalligraphicSweep.signedArea([Point(x: 0, y: 0)]) == 0)
    }

    @Test func invalidNibsReadAsTheEllipseOrNothing() {
        let two = DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)).elements + DisplayPath(rect: Rect(x: 2, y: 0, width: 1, height: 1)).elements
        #expect(CalligraphicSweep.singleClosedContour(DisplayPath(elements: two)) == nil, "two contours read as the ellipse")
        #expect(CalligraphicSweep.singleClosedContour(DisplayPath(polygon: [.zero, Point(x: 1, y: 0)], closed: false)) == nil, "open reads as the ellipse")
        let ellipse = CalligraphicSweep.nibPolygon(CalligraphicNib(width: 10, height: 4, shape: DisplayPath(elements: two)), tolerance: 0.01)
        #expect(ellipse.count >= 8)
        #expect(CalligraphicSweep.nibPolygon(CalligraphicNib(width: 0, height: 0), tolerance: 0.01).isEmpty)
        #expect(CalligraphicSweep.region(CalligraphicNib(width: .nan, height: 0), path: StrokeOutlineTests.line, tolerance: 0.01).isEmpty)
        let rotated = CalligraphicSweep.nibPolygon(CalligraphicNib(width: 10, height: 2, angle: 90), tolerance: 0.01)
        let tallest = rotated.map { abs($0.y) }.max()!
        #expect(approx(tallest, 5, tolerance: 0.02), "a quarter turn stands the nib up")
    }
}

/// ATTR-012: the 23 procedural tiles repeated and bent along the path; Neon's layers.
@Suite struct CustomStrokeTests {
    static let straight = DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 120, y: 0)], closed: false)

    func region(_ pattern: CustomStrokePattern, path: DisplayPath = straight, width: Double = 8, length: Double = 12, spacing: Double = 3) -> [PaintedRegion] {
        CustomStrokeTiles.regions(CustomStroke(pattern: pattern, length: length, spacing: spacing), width: width, paint: .solid(.black), path: path, tolerance: 0.01)
    }

    func bounds(_ regions: [PaintedRegion]) -> Rect? {
        DisplayList.union(of: regions.compactMap { region in
            if case .fill(let path, _, _) = region { return path.controlBounds }
            return nil
        })
    }

    @Test func everyPatternPaintsOnStraightCurvedAndClosedPaths() {
        let paths = [Self.straight, AttributeCorpus.wave(in: Rect(x: 0, y: 0, width: 120, height: 40)), DisplayPath(ellipseIn: Rect(x: 0, y: 0, width: 80, height: 50))]
        for pattern in CustomStrokePattern.allCases {
            for path in paths {
                let painted = region(pattern, path: path)
                #expect(!painted.isEmpty, "\(pattern)")
            }
            #expect(CustomStrokeTiles.polygons(for: pattern).isEmpty == (pattern == .neon))
        }
    }

    @Test func tilesRepeatEveryLengthPlusSpacingWithinTheWidth() throws {
        let rectangles = region(.rectangle)
        guard case .fill(let path, let rule, let paint) = try #require(rectangles.first) else {
            Issue.record("one filled region")
            return
        }
        #expect(rule == .nonZero && paint == .solid(.black))
        #expect(path.contours.count == 8, "120 pt holds eight 12 + 3 pt tiles")
        let extent = try #require(bounds(rectangles))
        #expect(approx(extent.minY, -4, tolerance: 1e-9) && approx(extent.maxY, 4, tolerance: 1e-9))
        // Scaling the width scales the tiles across the path only.
        let wide = try #require(bounds(region(.rectangle, width: 16)))
        #expect(approx(wide.height, 16, tolerance: 1e-9) && approx(wide.width, extent.width, tolerance: 1e-9))
    }

    @Test func lengthAndSpacingNormalize() {
        #expect(region(.dot, width: 0).isEmpty)
        #expect(region(.dot, width: .nan).isEmpty)
        let defaulted = region(.rectangle, width: 5, length: 0, spacing: -3)
        if case .fill(let path, _, _) = defaulted.first {
            #expect(path.contours.count == 12, "a zero length reads as twice the width; a negative spacing as none")
        } else {
            Issue.record("expected tiles")
        }
        #expect(region(.dot, path: DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 5, y: 0)], closed: false), length: 12).isEmpty, "shorter than one tile")
        #expect(region(.dot, path: DisplayPath()).isEmpty)
    }

    @Test func neonIsAStackOfLighteningOutlines() throws {
        let layers = region(.neon)
        #expect(layers.count == 4)
        var previousWidth = Double.infinity
        var previousLightness = -1.0
        for layer in layers {
            guard case .fill(let path, _, .solid(let color)) = layer else {
                Issue.record("neon layers are solid")
                continue
            }
            let height = try #require(path.controlBounds).height
            #expect(height < previousWidth)
            let lightness = color.red + color.green + color.blue
            #expect(lightness > previousLightness)
            previousWidth = height
            previousLightness = lightness
        }
    }

    @Test func tilesBendAlongCurves() throws {
        let arc = DisplayPath(ellipseIn: Rect(x: -50, y: -50, width: 100, height: 100))
        guard case .fill(let path, _, _) = try #require(region(.rectangle, path: arc, width: 6).first) else {
            Issue.record("tiles")
            return
        }
        // Every tile vertex stays within half the width of the circle.
        for contour in path.contours {
            for segment in contour.segments {
                let radius = segment.p0.distance(to: .zero)
                #expect(abs(radius - 50) <= 3.2)
            }
        }
    }

    @Test func shapeHelpers() {
        #expect(CustomStrokeTiles.band([Point(x: 0, y: 0)], thickness: 1).isEmpty)
        #expect(CustomStrokeTiles.subdivide([Point(x: 0, y: 0), Point(x: 1, y: 0), Point(x: 1, y: 1)], step: 0.25).count == 4 + 1 + 4)
    }
}
