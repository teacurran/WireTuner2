#if canImport(CoreText)
import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import WTGeometry

/// Stroking real glyph outlines (GEO-003).  TrueType glyphs are quadratic splines, which reach
/// the stroker as cubics with nearly (not exactly) smooth joins between them; the tiny corners
/// there put the two offsets of the inner side across each other at a very shallow angle, a
/// crossing the arrangement must find or the outline loses whole edges.  Core Text supplies the
/// glyphs and Core Graphics the reference stroke; only this test target links them.
@Suite struct GlyphStrokeTests {
    struct Failure: CustomStringConvertible {
        var font: String
        var glyph: CGGlyph
        var width: Double
        var reason: String
        var description: String { "\(font) glyph \(glyph) width \(width): \(reason)" }
    }

    static func font(_ name: String, size: Double) -> CTFont {
        CTFontCreateWithName(name as CFString, size, nil)
    }

    /// The outline of `glyph`, empty for a glyph without one.
    static func contours(_ font: CTFont, _ glyph: CGGlyph) -> [Contour] {
        guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else {
            return []
        }
        return StrokeCoreGraphicsTests.contours(of: path)
    }

    static func contours(_ font: CTFont, character: Character) -> [Contour] {
        var characters = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
        return contours(font, glyphs[0])
    }

    /// What is wrong with the round-joined stroke of `source` at `width`, or nil.
    ///
    /// A round-joined stroke of closed contours is exactly the set of points within half the
    /// width of the source (the source swept by a disc), which gives an exact reference:
    ///
    /// * the outline is not empty;
    /// * every outline point is half the width from the source, within twice the tolerance (a
    ///   dropped outer edge leaves only the inner one, which is too close);
    /// * on a grid over the stroke, a point is inside the outline exactly when it is within half
    ///   the width of the source, away from the boundary;
    /// * its area is at least 0.9 × perimeter × width where the stroke does not overlap itself
    ///   (the bound is the area of a stroke that never overlaps itself; glyphs narrower than the
    ///   width, or curves tighter than half of it, overlap, and there it holds for no stroker, so
    ///   it is applied where the exact region's area reaches perimeter × width);
    /// * Core Graphics' `copy(strokingWithWidth:)` (grid-sampled with `CGPath.contains`) paints
    ///   the same area within 2%, except where it is itself wrong against the exact region,
    ///   which is counted in `coreGraphicsMisses`.
    static func check(_ source: [Contour], width: Double, tolerance: Double = 0.01, coreGraphicsMisses: inout Int) -> String? {
        let half = width / 2
        let style = StrokeStyle(width: width, cap: .butt, join: .round)
        let ours = Offset.strokeOutline(source, style: style, tolerance: tolerance)
        guard !ours.isEmpty else {
            return "empty outline"
        }
        let polyline = Polyline(source)
        var worst = 0.0
        for point in boundarySamples(ours, perSegment: 3) {
            worst = max(worst, abs(polyline.distance(to: point) - half))
        }
        if worst > 2 * tolerance {
            return "outline point \(worst) off the half width"
        }
        let cg = StrokeCoreGraphicsTests.cgPath(source).copy(
            strokingWithWidth: width, lineCap: .butt, lineJoin: .round, miterLimit: 10)
        let perimeter = source.reduce(0) { $0 + $1.length(tolerance: tolerance) }
        let box = source.reduce(Rect.null) { $0.union($1.bounds) }.expanded(by: half)
        let steps = 40
        let dx: Double = box.width / Double(steps)
        let dy: Double = box.height / Double(steps)
        let cell: Double = dx * dy
        let margin = max(2 * tolerance, 1e-3 * width)
        var exactArea = 0.0
        var theirsArea = 0.0
        var wrong = 0
        var theirsWrong = 0
        for i in 0..<steps {
            for j in 0..<steps {
                let p = Point(box.minX + (Double(i) + 0.5) * dx, box.minY + (Double(j) + 0.5) * dy)
                let d = polyline.distance(to: p)
                let exact = d <= half
                let theirs = cg.contains(CGPoint(x: p.x, y: p.y), using: .winding)
                if exact { exactArea += cell }
                if theirs { theirsArea += cell }
                guard abs(d - half) > margin else {
                    continue
                }
                if ours.contains(p) != exact {
                    wrong += 1
                }
                if theirs != exact {
                    theirsWrong += 1
                }
            }
        }
        if wrong > 0 {
            return "\(wrong) grid points misclassified against the exact region"
        }
        let area = ours.signedArea()
        if exactArea >= perimeter * width && area < 0.9 * perimeter * width {
            return "area \(area) below 0.9 × perimeter \(perimeter) × width"
        }
        if theirsWrong > 0 {
            coreGraphicsMisses += 1
        } else if abs(area - theirsArea) > max(0.02 * theirsArea, perimeter * max(dx, dy)) {
            // The grid area is off by up to a cell's reach along the boundary.
            return "area \(area) vs Core Graphics \(theirsArea) on the grid"
        }
        return nil
    }

    static func check(_ source: [Contour], width: Double, tolerance: Double = 0.01) -> String? {
        var misses = 0
        return check(source, width: width, tolerance: tolerance, coreGraphicsMisses: &misses)
    }

    static let widths = [0.5, 1, 2, 5, 10]

    /// Distance to a set of contours through a fine polyline of them (64 chords per segment,
    /// far inside the tolerance on glyph-sized segments), much cheaper than per-segment nearest
    /// point searches.
    struct Polyline {
        var pieces: [(box: Rect, starts: [Point], ends: [Point])] = []

        init(_ contours: [Contour]) {
            for contour in contours {
                for segment in allSegments(contour) {
                    // Chords at most 0.05 long: their sagitta is far inside the tolerance.
                    let count = min(64, max(2, Int((segment.controlPolygonLength / 0.05).rounded(.up))))
                    var starts: [Point] = []
                    var ends: [Point] = []
                    var previous = segment.p0
                    for k in 1...count {
                        let next = segment.evaluate(Double(k) / Double(count))
                        starts.append(previous)
                        ends.append(next)
                        previous = next
                    }
                    pieces.append((segment.controlBounds, starts, ends))
                }
            }
        }

        func distance(to point: Point) -> Double {
            var best = Double.infinity
            for piece in pieces {
                let gx = max(piece.box.minX - point.x, 0, point.x - piece.box.maxX)
                let gy = max(piece.box.minY - point.y, 0, point.y - piece.box.maxY)
                if gx * gx + gy * gy >= best {
                    continue
                }
                for index in piece.starts.indices {
                    let a = piece.starts[index]
                    let ab = piece.ends[index] - a
                    let ap = point - a
                    let lengthSquared = ab.lengthSquared
                    let t = lengthSquared > 0 ? min(1, max(0, ap.dot(ab) / lengthSquared)) : 0
                    best = min(best, (ap - ab * t).lengthSquared)
                }
            }
            return best.squareRoot()
        }
    }

    /// The glyph the defect was reported on: Helvetica Bold "t" at 2 and 5 pt lost its outer
    /// edge (24 pt) or came back empty (12 pt) at every tolerance.
    @Test(arguments: [12.0, 24], [2.0, 5])
    func helveticaBoldT(_ size: Double, _ width: Double) {
        let source = Self.contours(Self.font("Helvetica-Bold", size: size), character: "t")
        for tolerance in [0.1, 0.01, 0.001] {
            let failure = Self.check(source, width: width, tolerance: tolerance)
            #expect(failure == nil, "size \(size) width \(width) tolerance \(tolerance): \(failure ?? "")")
        }
    }

    /// Inset and outset of the same glyph region: the band they remove or add is the reported
    /// stroke, so they failed with it, returning the glyph unchanged.  Now they change the area
    /// by about perimeter × distance, and the checked call does not throw.
    @Test(arguments: [12.0, 24], [1.0, 2.5])
    func helveticaBoldTInsets(_ size: Double, _ distance: Double) throws {
        let source = Self.contours(Self.font("Helvetica-Bold", size: size), character: "t")
        let region = Boolean.normalize(FilledPath(contours: source))
        let perimeter = source.reduce(0) { $0 + $1.length(tolerance: 1e-3) }
        let outset = try Offset.checkedInset(region, by: -distance, join: .round)
        #expect(outset.signedArea() - region.signedArea() > 0.5 * perimeter * distance)
        #expect(outset == Offset.inset(region, by: -distance, join: .round))
        let inset = try Offset.checkedInset(region, by: distance / 4, join: .round)
        #expect(inset.signedArea() < region.signedArea() - 0.25 * perimeter * distance / 4)
    }

    /// Glyphs that failed during the GEO-003 glyph investigation, one or more per cause (glyph
    /// ids are those of the fonts shipped with macOS 26):
    ///
    /// * a shallow crossing of the two inner-side offsets at a nearly smooth joint, missed by the
    ///   curve intersector (Newton overshooting to the end of the parameter box): outer or inner
    ///   edge lost (Helvetica 22, Helvetica-Bold 22 and 1056);
    /// * a fold cut off at a joint, traced as a needle within the merge distance (Times-Roman 42,
    ///   91, 252, 924, Helvetica-Bold 1188) or running on into the next piece (Times-Roman 525);
    /// * an offset fitted with a back-and-forth wiggle past a short handle (Menlo 2145).
    @Test func glyphsThatFailed() {
        let cases: [(String, CGGlyph, Double)] = [
            ("Helvetica", 22, 0.5), ("Helvetica-Bold", 22, 0.5), ("Helvetica-Bold", 1056, 1), ("Helvetica-Bold", 1188, 2),
            ("Helvetica-Bold", 1166, 5), ("Helvetica", 1188, 5), ("Helvetica", 990, 1), ("Menlo", 2145, 2), ("Menlo", 540, 5),
            ("Menlo", 1440, 2), ("Times-Roman", 42, 1), ("Times-Roman", 91, 0.5), ("Times-Roman", 252, 0.5),
            ("Times-Roman", 525, 0.5), ("Times-Roman", 525, 5), ("Times-Roman", 924, 1), ("Times-Roman", 819, 0.5),
        ]
        for (name, glyph, width) in cases {
            let failure = Self.check(Self.contours(Self.font(name, size: 24), glyph), width: width)
            #expect(failure == nil, "\(name) glyph \(glyph) width \(width): \(failure ?? "")")
        }
    }

    /// Glyphs of four system fonts (two sans weights, a serif, a monospace) at each width, 24 pt.
    /// By default an even spread of 16 glyphs per font; `WT_GLYPH_SWEEP=<n>` checks a spread of
    /// `n`, and `WT_GLYPH_SWEEP=full` every glyph (slow: about a minute per hundred glyphs in a
    /// debug build).
    @Test(arguments: ["Helvetica", "Helvetica-Bold", "Times-Roman", "Menlo"])
    func glyphSweep(_ name: String) {
        let font = Self.font(name, size: 24)
        let count = CTFontGetGlyphCount(font)
        let setting = ProcessInfo.processInfo.environment["WT_GLYPH_SWEEP"]
        let spread = setting == "full" ? count : (setting.flatMap(Int.init) ?? 16)
        let stride = max(1, count / max(1, spread))
        var failures: [Failure] = []
        var checked = 0
        var coreGraphicsMisses = 0
        for index in Swift.stride(from: 0, to: count, by: stride) {
            let glyph = CGGlyph(index)
            let source = Self.contours(font, glyph)
            guard !source.isEmpty else {
                continue
            }
            checked += 1
            for width in Self.widths {
                if let reason = Self.check(source, width: width, coreGraphicsMisses: &coreGraphicsMisses) {
                    failures.append(Failure(font: name, glyph: glyph, width: width, reason: reason))
                }
            }
        }
        print("glyph sweep \(name): \(checked) glyphs × \(Self.widths.count) widths, \(failures.count) failures; Core Graphics wrong against the exact region in \(coreGraphicsMisses)")
        #expect(failures.isEmpty, "\(failures.count) failures:\n\(failures.prefix(20).map(\.description).joined(separator: "\n"))")
    }
}
#endif
