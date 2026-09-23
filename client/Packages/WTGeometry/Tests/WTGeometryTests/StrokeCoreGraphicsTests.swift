#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
import Testing
@testable import WTGeometry

/// Cross-check against Core Graphics' own stroker, `CGPath.copy(strokingWithWidth:...)`: the
/// expanded outline must paint what the renderer paints (GEO-003 "Done when").  WTGeometry does
/// not link Core Graphics; only this test does.
@Suite struct StrokeCoreGraphicsTests {
    static func cgPath(_ contours: [Contour]) -> CGPath {
        let result = CGMutablePath()
        for contour in contours where !contour.isEmpty {
            result.move(to: CGPoint(x: contour.segments[0].p0.x, y: contour.segments[0].p0.y))
            for s in contour.segments {
                result.addCurve(
                    to: CGPoint(x: s.p3.x, y: s.p3.y),
                    control1: CGPoint(x: s.p1.x, y: s.p1.y),
                    control2: CGPoint(x: s.p2.x, y: s.p2.y))
            }
            if contour.isClosed {
                result.closeSubpath()
            }
        }
        return result
    }

    /// The contours of a Core Graphics path, every subpath closed (as its fill paints).
    static func contours(of path: CGPath) -> [Contour] {
        var result: [Contour] = []
        var segments: [CubicBezier] = []
        var start = Point.zero
        var current = Point.zero
        func point(_ p: CGPoint) -> Point { Point(Double(p.x), Double(p.y)) }
        func flush() {
            if !segments.isEmpty {
                result.append(Contour(segments: segments, closed: true))
            }
            segments = []
        }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                flush()
                start = point(e.points[0])
                current = start
            case .addLineToPoint:
                let p = point(e.points[0])
                segments.append(Line(start: current, end: p).elevated())
                current = p
            case .addQuadCurveToPoint:
                let q = QuadraticBezier(p0: current, p1: point(e.points[0]), p2: point(e.points[1]))
                segments.append(q.elevated())
                current = q.p2
            case .addCurveToPoint:
                let c = CubicBezier(current, point(e.points[0]), point(e.points[1]), point(e.points[2]))
                segments.append(c)
                current = c.p3
            case .closeSubpath:
                if current != start {
                    segments.append(Line(start: current, end: start).elevated())
                }
                current = start
                flush()
            @unknown default:
                break
            }
        }
        flush()
        return result
    }

    static func cgCap(_ cap: LineCap) -> CGLineCap {
        switch cap {
        case .butt: return .butt
        case .round: return .round
        case .square: return .square
        }
    }

    static func cgJoin(_ join: LineJoin) -> CGLineJoin {
        switch join {
        case .miter: return .miter
        case .round: return .round
        case .bevel: return .bevel
        }
    }

    /// Core Graphics' stroke of `source` with `style`, as a normalized region.
    static func coreGraphicsStroke(_ source: Contour, _ style: StrokeStyle) -> (path: CGPath, region: FilledPath) {
        var path = cgPath([source])
        if let dash = style.normalizedDash {
            path = path.copy(dashingWithPhase: style.dashPhase, lengths: dash.map { CGFloat($0) })
        }
        let stroked = path.copy(
            strokingWithWidth: style.width, lineCap: cgCap(style.cap), lineJoin: cgJoin(style.join),
            miterLimit: style.miterLimit)
        return (stroked, Boolean.normalize(FilledPath(contours: contours(of: stroked))))
    }

    /// Our outline and Core Graphics' agree on area and on every probe point clearly inside or
    /// outside both.
    static func check(_ source: Contour, _ style: StrokeStyle, areaTolerance: Double = 2e-3, margin: Double? = nil, label: String) {
        let ours = Offset.strokeOutline(source, style: style, tolerance: 1e-3)
        let (cgStroke, theirs) = coreGraphicsStroke(source, style)
        let a = ours.signedArea()
        let b = theirs.signedArea()
        #expect(relativeError(a, b) < areaTolerance, "\(label): area \(a) vs Core Graphics \(b)")
        var rng = SeededGenerator(seed: 5150)
        let box = source.bounds.expanded(by: style.width * 2)
        let margin = margin ?? max(0.02 * style.width, 0.02)
        var disagreements = 0
        for _ in 0..<200 {
            let p = Point(rng.double(in: box.minX...box.maxX), rng.double(in: box.minY...box.maxY))
            guard boundaryDistance(p, ours) > margin, boundaryDistance(p, theirs) > margin else {
                continue
            }
            if ours.contains(p) != cgStroke.contains(CGPoint(x: p.x, y: p.y), using: .winding) {
                disagreements += 1
            }
        }
        #expect(disagreements == 0, "\(label): \(disagreements) probes disagree with Core Graphics")
    }

    static let zigzag = Contour(polygon: [Point(0, 0), Point(40, 30), Point(80, 0), Point(90, 60), Point(20, 70)], closed: false)

    @Test(arguments: LineCap.allCases, LineJoin.allCases)
    func polylineAgrees(_ cap: LineCap, _ join: LineJoin) {
        Self.check(Self.zigzag, StrokeStyle(width: 8, cap: cap, join: join, miterLimit: 4), label: "zigzag \(cap) \(join)")
        // A limit low enough to bevel some corners and not others.
        Self.check(Self.zigzag, StrokeStyle(width: 8, cap: cap, join: join, miterLimit: 1.6), label: "zigzag limit \(cap) \(join)")
    }

    @Test(arguments: LineJoin.allCases)
    func closedShapesAgree(_ join: LineJoin) {
        Self.check(squareContour(0, 0, 100), StrokeStyle(width: 12, join: join), label: "square \(join)")
        Self.check(circle(center: Point(50, 50), radius: 40), StrokeStyle(width: 6, join: join), label: "circle \(join)")
        let star = Contour(polygon: (0..<10).map { k in
            let r = k % 2 == 0 ? 50.0 : 20
            let a = Double(k) * Double.pi / 5
            return Point(r * cos(a), r * sin(a))
        })
        Self.check(star, StrokeStyle(width: 4, join: join, miterLimit: 10), label: "star \(join)")
    }

    @Test(arguments: LineCap.allCases)
    func curvesAgree(_ cap: LineCap) {
        var rng = SeededGenerator(seed: 616)
        for k in 0..<8 {
            let source = randomContour(&rng, segments: 1 + k % 3, range: 0...100)
            let style = StrokeStyle(width: rng.double(in: 1...6), cap: cap, join: LineJoin.allCases[k % 3])
            Self.check(source, style, areaTolerance: 5e-3, label: "curve \(k) \(cap)")
        }
    }

    @Test(arguments: LineCap.allCases)
    func dashesAgree(_ cap: LineCap) {
        Self.check(Self.zigzag, StrokeStyle(width: 3, cap: cap, join: .miter, dash: [12, 6], dashPhase: 4), label: "dashed zigzag \(cap)")
        // Core Graphics measures a curve's length on a flattening, a little short of its arc
        // length, so its dashes drift along a curve (by about 0.4 pt over this circle): the
        // area agrees to half a percent, and probes near a dash end are skipped.
        Self.check(
            circle(center: .zero, radius: 30), StrokeStyle(width: 2, cap: cap, dash: [5, 3, 1, 3]),
            areaTolerance: 5e-3, margin: 0.6, label: "dashed circle \(cap)")
    }
}
#endif
