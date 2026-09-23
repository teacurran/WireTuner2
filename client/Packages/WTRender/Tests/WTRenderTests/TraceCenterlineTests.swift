import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// IMG-022: centerline tracing (docs/_includes/imported/tracing.adoc).
@Suite struct TraceCenterlineTests {
    private let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    /// Points along every segment of `contours`, ends included.
    private func samples(_ contours: [Contour]) -> [Point] {
        contours.flatMap { contour in
            contour.segments.flatMap { segment in
                stride(from: 0.0, through: 1.0, by: 0.25).map { segment.evaluate($0) }
            }
        }
    }

    private func strokes(_ result: Trace.Result) -> [Trace.TracedPath] {
        result.paths.filter { $0.stroke != nil }
    }

    @Test(arguments: 1...12)
    func horizontalLinesOfKnownWidth(width: Int) throws {
        let top = 40.0
        let source = TraceFixtures.bitmap(width: 200, height: 100) { context in
            context.setFillColor(black)
            context.fill(CGRect(x: 20, y: top, width: 160, height: Double(width)))
        }
        let result = try Trace.run(source, options: Trace.Options(colors: 2, conformity: 10, mode: .centerline))
        let paths = strokes(result)
        try #require(paths.count == 1)
        let path = paths[0]
        #expect(path.fill == nil)
        let measured = try #require(path.strokeWidth)
        #expect(abs(measured - Double(width)) <= 0.5, "width \(width): measured \(measured)")
        let center = top + Double(width) / 2
        for point in samples(path.contours) where point.x > 20 + Double(width) && point.x < 180 - Double(width) {
            #expect(abs(point.y - center) <= 0.5, "width \(width): \(point)")
        }
        #expect(path.contours.allSatisfy { !$0.isClosed })
    }

    @Test func verticalAndDiagonalLines() throws {
        let source = TraceFixtures.bitmap(width: 200, height: 200) { context in
            context.setFillColor(black)
            context.fill(CGRect(x: 30, y: 20, width: 6, height: 160))
            context.setStrokeColor(black)
            context.setLineWidth(8)
            context.move(to: CGPoint(x: 80, y: 30))
            context.addLine(to: CGPoint(x: 180, y: 170))
            context.strokePath()
        }
        let paths = strokes(try Trace.run(source, options: Trace.Options(colors: 2, conformity: 8, mode: .centerline)))
        #expect(paths.count == 2)
        let vertical = try #require(paths.first { $0.contours[0].bounds.maxX < 50 })
        #expect(abs(vertical.strokeWidth! - 6) <= 0.5)
        for point in samples(vertical.contours) where point.y > 30 && point.y < 170 {
            #expect(abs(point.x - 33) <= 0.5)
        }
        let diagonal = try #require(paths.first { $0.contours[0].bounds.minX > 60 })
        #expect(abs(diagonal.strokeWidth! - 8) <= 1.5)
    }

    @Test func junctionsShareEndpoints() throws {
        let source = TraceFixtures.bitmap(width: 200, height: 200) { context in
            context.setFillColor(black)
            // A T.
            context.fill(CGRect(x: 20, y: 20, width: 160, height: 5))
            context.fill(CGRect(x: 98, y: 25, width: 5, height: 70))
            // An X.
            context.setStrokeColor(black)
            context.setLineWidth(4)
            context.move(to: CGPoint(x: 30, y: 110))
            context.addLine(to: CGPoint(x: 170, y: 190))
            context.move(to: CGPoint(x: 30, y: 190))
            context.addLine(to: CGPoint(x: 170, y: 110))
            context.strokePath()
        }
        let paths = strokes(try Trace.run(source, options: Trace.Options(colors: 2, conformity: 8, mode: .centerline)))
        #expect(paths.count == 2)
        for (path, junction, arms) in [(paths[0], Point(x: 100, y: 22), 3), (paths[1], Point(x: 100, y: 150), 4)] {
            let ends = path.contours.flatMap { [$0.startPoint!, $0.endPoint!] }.filter { $0.distance(to: junction) < 12 }
            #expect(ends.count == arms, "\(ends)")
            for end in ends {
                #expect(ends.allSatisfy { $0.distance(to: end) <= 1 })
            }
            #expect(path.contours.count == arms)
        }
    }

    @Test func classifierRoutesByWidth() throws {
        let source = TraceFixtures.bitmap(width: 200, height: 120) { context in
            context.setFillColor(black)
            context.fill(CGRect(x: 10, y: 50, width: 100, height: 3))
            context.fill(CGRect(x: 125, y: 20, width: 60, height: 30))
        }
        let result = try Trace.run(source, options: Trace.Options(colors: 2, mode: .centerlineAndOutline(openPathsBelow: 8)))
        #expect(result.paths.count == 2)
        let stroke = try #require(result.paths.first { $0.stroke != nil })
        #expect(stroke.contours[0].bounds.maxX < 112)
        let outline = try #require(result.paths.first { $0.fill != nil })
        #expect(outline.contours.count == 1)
        #expect(outline.contours[0].bounds.minX > 120)
        // With a threshold above both, both are strokes; below both, both outline.
        let allStrokes = try Trace.run(source, options: Trace.Options(colors: 2, mode: .centerlineAndOutline(openPathsBelow: 100)))
        #expect(allStrokes.paths.count == 2 && allStrokes.paths.allSatisfy { $0.stroke != nil })
        let allOutlines = try Trace.run(source, options: Trace.Options(colors: 2, mode: .centerlineAndOutline(openPathsBelow: 1)))
        #expect(allOutlines.paths.count == 1 && allOutlines.paths[0].contours.count == 2)
    }

    @Test func uniformWidthAndTransformScale() throws {
        let source = TraceFixtures.bitmap(width: 120, height: 60) { context in
            context.setFillColor(black)
            context.fill(CGRect(x: 10, y: 20, width: 100, height: 6))
        }
        let uniform = try Trace.run(source, options: Trace.Options(colors: 2, mode: .centerline, uniform: true), transform: .scale(0.25))
        #expect(uniform.paths[0].strokeWidth == 1)
        let scaled = try Trace.run(source, options: Trace.Options(colors: 2, colorModel: .cmyk, mode: .centerline), transform: .scale(0.25))
        #expect(abs(scaled.paths[0].strokeWidth! - 1.5) <= 0.125)
        #expect(scaled.paths[0].cmyk == SIMD4(0, 0, 0, 1))
    }

    @Test func ringsTraceAsClosedLoops() throws {
        let source = TraceFixtures.bitmap(width: 100, height: 100, antialias: false) { context in
            context.setStrokeColor(black)
            context.setLineWidth(3)
            context.strokeEllipse(in: CGRect(x: 20, y: 20, width: 60, height: 60))
        }
        let paths = strokes(try Trace.run(source, options: Trace.Options(colors: 2, conformity: 8, mode: .centerline)))
        #expect(paths.count == 1)
        let contour = try #require(paths.first?.contours.first)
        #expect(paths[0].contours.count == 1)
        #expect(contour.isClosed)
        for point in samples([contour]) {
            #expect(abs(point.distance(to: Point(x: 50, y: 50)) - 30) <= 1)
        }
    }

    @Test func dotsAndBlobs() throws {
        // A lone pixel thins to a point: no chain, no path.
        let dot = TraceFixtures.bitmap(width: 20, height: 20) { context in
            context.setFillColor(black)
            context.fill(CGRect(x: 9, y: 9, width: 1, height: 1))
        }
        #expect(try Trace.run(dot, options: Trace.Options(colors: 2, mode: .centerline)).paths.isEmpty)
        // A square centerlines to its medial axis: an X whose spurs are pruned, arms kept.
        let square = TraceFixtures.bitmap(width: 60, height: 60) { context in
            context.setFillColor(black)
            context.fill(CGRect(x: 10, y: 10, width: 40, height: 20))
        }
        let result = try Trace.run(square, options: Trace.Options(colors: 2, mode: .centerline))
        #expect(result.paths.count == 1)
        #expect(!result.paths[0].contours.isEmpty)
        // Two touching junction clusters produce a direct chain between them (a plus sign).
        let plus = TraceFixtures.bitmap(width: 60, height: 60) { context in
            context.setFillColor(black)
            context.fill(CGRect(x: 10, y: 29, width: 40, height: 2))
            context.fill(CGRect(x: 29, y: 10, width: 2, height: 40))
        }
        let cross = try Trace.run(plus, options: Trace.Options(colors: 2, mode: .centerline))
        #expect(cross.paths.count == 1)
        #expect(cross.paths[0].contours.count >= 4)
    }

    @Test func distanceTransformAndNeighbourGroups() {
        // A 1-D transform of a run of five foreground samples between background ones.
        let infinity = 1e20
        let transformed = Feature.distance1D([0, infinity, infinity, infinity, infinity, infinity, 0])
        #expect(transformed == [0, 1, 4, 9, 4, 1, 0])
        #expect(Feature.neighbourGroups([true, false, true, false, false, false, false, false]) == 1)  // N, E touch
        #expect(Feature.neighbourGroups([true, false, false, false, true, false, false, false]) == 2)  // N, S apart
        #expect(Feature.neighbourGroups([false, true, false, false, false, true, false, false]) == 2)  // NE, SW apart
    }
}
