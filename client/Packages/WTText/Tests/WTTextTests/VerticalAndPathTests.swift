import Foundation
import Testing
import WTGeometry
import WTRender
@testable import WTText

/// TYPE-040 (vertical text: forms, stacking, carets and selections, horizontal-only features
/// ignored) and TYPE-042 (text on a path: every orientation and alignment on a circle and an
/// S-curve, selection along the curve, remote carets, reshaping speed).
@Suite struct VerticalAndPathTests {
    /// An S-curve from left to right.
    static let sCurve = Contour(segments: [
        CubicBezier(Point(x: 10, y: 100), Point(x: 60, y: 10), Point(x: 110, y: 10), Point(x: 150, y: 70)),
        CubicBezier(Point(x: 150, y: 70), Point(x: 190, y: 130), Point(x: 240, y: 130), Point(x: 290, y: 40)),
    ], closed: false)

    // MARK: TYPE-040

    @Test func mixedLatinAndCJKRunVertically() throws {
        var block = TextBlock(width: 90, height: 160)
        block.direction = .vertical
        let text = "縦書き「日本語」、Latin。\nかな123"
        let layout = Fixture.layout(text, attributes: TextAttributes(fontFamily: "Hiragino Mincho ProN", size: 16), in: [.block(block)])
        let scalars = Array(text.unicodeScalars)
        let glyphs = layout.glyphs()
        let upright = glyphs.filter { isUpright(scalars[$0.offset]) }
        let rotated = glyphs.filter { !isUpright(scalars[$0.offset]) }
        #expect(upright.allSatisfy { $0.transform.a == 1 && $0.transform.d == 1 }, "CJK stands upright")
        #expect(rotated.allSatisfy { approx($0.transform.b, 1) && approx($0.transform.c, -1) }, "Latin turns a quarter clockwise")
        // Vertical punctuation forms: the corner brackets and the comma take their vert glyphs.
        let plain = Fixture.layout("「、", attributes: TextAttributes(fontFamily: "Hiragino Mincho ProN", size: 16), in: [Fixture.block()]).glyphs().map(\.glyph)
        let forms = glyphs.filter { scalars[$0.offset] == "「" || scalars[$0.offset] == "、" }.map(\.glyph)
        #expect(forms.count == 2 && forms[0] != plain[0] && forms[1] != plain[1])
        // Lines stack right to left.
        let firstLine = glyphs.filter { $0.offset < 15 }
        let secondLine = glyphs.filter { $0.offset > 15 }
        #expect(firstLine.map(\.origin.x).min()! > secondLine.map(\.origin.x).max()!)
        Goldens.check(layout, name: "verticalMixed", size: Size(width: 100, height: 170))
        // Selections run down the line; carets across it.
        let quads = layout.selection(from: 1, to: 4)
        #expect(quads.count == 1)
        let xs = quads[0].corners.map(\.x)
        let ys = quads[0].corners.map(\.y)
        #expect(ys.max()! - ys.min()! > xs.max()! - xs.min()!, "tall and narrow")
        let remote = try #require(layout.selection(from: .before(layout.charID(at: 1)!), to: .after(layout.charID(at: 3)!)))
        #expect(remote == quads)
        #expect(layout.selection(from: .before(CharID(counter: 999, replica: 9)), to: .after(layout.charID(at: 3)!)) == nil)
        #expect(layout.selection(from: 4, to: 1) == quads, "either order")
    }

    @Test func columnsRowsAndTabsAreIgnoredInVerticalBlocks() {
        var block = TextBlock(width: 100, height: 100)
        block.direction = .vertical
        block.columns = ColumnsRows(columns: 3, columnHeight: 20, columnSpacing: 10, rows: 2, rowWidth: 30)
        let layout = Fixture.layout(BlockLayoutTests.numbered, in: [.block(block)])
        let plain = TextBlock(width: 100, height: 100, direction: .vertical)
        let reference = Fixture.layout(BlockLayoutTests.numbered, in: [.block(plain)])
        #expect(layout.lineRanges == reference.lineRanges && layout.sizes == reference.sizes)
        // A vertical block has no grid to rule; its border still draws.
        var bordered = TextBlock(width: 60, height: 80, direction: .vertical, appearance: Appearance([.stroke(StrokePaint(paint: .solid(.black)))]), displayBorder: true)
        bordered.columns = ColumnsRows(columns: 2, columnRules: .full)
        let strokes = Fixture.strokePaths(Fixture.layout("日日日", attributes: TextAttributes(fontFamily: "Hiragino Mincho ProN", size: 14), in: [.block(bordered)]).displayItems(forContainer: 0))
        #expect(strokes.count == 1 && strokes[0].path == DisplayPath(rect: Rect(x: 0, y: 0, width: 60, height: 80)))
    }

    // MARK: TYPE-042

    @Test func everyOrientationAndAlignmentOnACircleAndAnSCurve() {
        let orientations: [PathText.Orientation] = [.rotate, .vertical, .skewHorizontal, .skewVertical]
        let alignments: [PathText.Alignment] = [.baseline, .ascent, .descent]
        for orientation in orientations {
            for alignment in alignments {
                let name = "\(orientation)-\(alignment)"
                let circle = Fixture.layout("Top of the circle\nBottom run", in: [.path(PathText(contour: PathTextTests.circle, orientation: orientation, top: alignment, bottom: alignment))])
                #expect(!circle.overflows, "\(name)")
                let curve = Fixture.layout("Text along an S-curve path", in: [.path(PathText(contour: VerticalAndPathTests.sCurve, orientation: orientation, top: alignment))])
                #expect(!curve.overflows, "\(name)")
                // Baseline alignment puts each glyph's baseline midpoint on the path.
                if alignment == .baseline && (orientation == .rotate || orientation == .vertical) {
                    for glyph in curve.glyphs() {
                        #expect(PathTextTests.distance(from: PathTextTests.baselineMid(glyph), to: VerticalAndPathTests.sCurve) < 0.05, "\(name)")
                    }
                }
                Goldens.checkGlyphs(circle, name: "circle-\(name)")
                Goldens.checkGlyphs(curve, name: "sCurve-\(name)")
            }
        }
        // Renders for the four orientations at baseline alignment (the glyph goldens hold the rest).
        for orientation in orientations {
            let curve = Fixture.layout("Text along an S-curve path", in: [.path(PathText(contour: VerticalAndPathTests.sCurve, orientation: orientation))])
            Goldens.checkRender(curve, name: "sCurve-\(orientation)", size: Size(width: 300, height: 140))
        }
    }

    @Test func hiddenRunsAndEmptyPaths() {
        // Both runs of a closed path hidden: nothing placed, the text overflows.
        let hidden = Fixture.layout("Top\nBottom", in: [.path(PathText(contour: PathTextTests.circle, top: .none, bottom: .none))])
        #expect(hidden.lineCount == 0 && hidden.overflows)
        // The top hidden and the bottom shown: the top run's text is consumed, the bottom drawn.
        let bottomOnly = Fixture.layout("Top\nBottom", in: [.path(PathText(contour: PathTextTests.circle, top: .none, bottom: .baseline))])
        #expect(bottomOnly.glyphs().map(\.offset).allSatisfy { $0 >= 4 } && !bottomOnly.overflows)
        // An empty contour holds nothing, inside or along.
        #expect(Fixture.layout("x", in: [.path(PathText(contour: Contour(segments: [], closed: true), mode: .inside))]).lineCount == 0)
    }

    @Test func selectionsAndRemoteCaretsFollowTheCurve() throws {
        let content = TextContent("Selection on a curve", attributes: Fixture.body, replica: 7, firstCounter: 100)
        let layout = TextLayoutEngine().layout(content, in: [.path(PathText(contour: VerticalAndPathTests.sCurve))])
        let quads = layout.selection(from: 0, to: 9)
        #expect(quads.count == 9, "one box per selected glyph")
        for (quad, glyph) in zip(quads, layout.glyphs()) {
            #expect(quad.corners[3].distance(to: glyph.origin) < 3, "the box starts at its glyph")
        }
        // A remote caret keeps its character when someone inserts before it.
        let anchor = CharAnchor.before(CharID(counter: 110, replica: 7))
        let before = try #require(layout.caret(for: anchor))
        var edited = content
        edited.runs = [TextRun("New ", attributes: Fixture.body)] + edited.runs
        edited.charIDs = (0..<4).map { CharID(counter: UInt64(1 + $0), replica: 3) } + edited.charIDs
        let relaid = TextLayoutEngine().layout(edited, in: [.path(PathText(contour: VerticalAndPathTests.sCurve))])
        let after = try #require(relaid.caret(for: anchor))
        #expect(after.offset == before.offset + 4)
        #expect(after.baseline.distance(to: before.baseline) > 10, "it moved along the curve with its character")
    }

    @Test func reshapingThePathRelaysQuickly() {
        let engine = TextLayoutEngine()
        let text = String(repeating: "Five hundred characters on a curve. ", count: 14)
        #expect(text.count >= 500)
        let content = TextContent(text, attributes: TextAttributes(fontFamily: "Helvetica", size: 6))
        func spiral(_ bend: Double) -> Contour {
            Contour(segments: (0..<8).map { index in
                let x = Double(index) * 120
                return CubicBezier(Point(x: x, y: 100), Point(x: x + 40, y: 100 - bend), Point(x: x + 80, y: 100 + bend), Point(x: x + 120, y: 100))
            }, closed: false)
        }
        _ = engine.layout(content, in: [.path(PathText(contour: spiral(40)))])
        var worst = 0.0
        for step in 1...5 {
            let start = Date()
            let layout = engine.layout(content, in: [.path(PathText(contour: spiral(40 + Double(step) * 5)))])
            worst = max(worst, Date().timeIntervalSince(start))
            #expect(layout.glyphs().count > 300)
        }
        #if !DEBUG
        #expect(worst < 0.008, "re-laying 500 characters on a reshaped path took \(worst * 1000) ms")
        #endif
        print(String(format: "PERF WTText reshape a path under 500 characters: worst %.1f ms", worst * 1000))
    }
}
