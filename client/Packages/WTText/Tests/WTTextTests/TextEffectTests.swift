import CoreGraphics
import Foundation
import Testing
import WTGeometry
import WTRender
import struct WTRender.StrokeStyle
@testable import WTText

/// TYPE-036: the six text effects with their options, the *Display text effects* hook and
/// Keyline suppression.
@Suite struct TextEffectTests {
    static let red = Color(red: 0.85, green: 0.1, blue: 0.1)
    static let blue = Color(red: 0.1, green: 0.3, blue: 0.9)

    static func attributes(_ effect: TextEffect, size: Double = 20) -> TextAttributes {
        TextAttributes(fontFamily: "Helvetica", fontStyle: "Bold", size: size, effect: effect)
    }

    static var corpus: TextContent {
        let runs = [
            TextRun("Highlight", attributes: attributes(.highlight(TextLineEffect(position: -4, width: 16, color: Color(red: 1, green: 0.9, blue: 0.2))))),
            TextRun(" band\n", attributes: attributes(.highlight(TextLineEffect(color: Color(red: 0.7, green: 0.9, blue: 1))))),
            TextRun("Underline", attributes: attributes(.underline(TextLineEffect(position: -3, width: 1.5, color: red)))),
            TextRun(" dashed\n", attributes: attributes(.underline(TextLineEffect(position: -3, width: 2, dash: [4, 2], color: blue)))),
            TextRun("Strikethrough", attributes: attributes(.strikethrough(TextLineEffect(position: 6, color: .black, overprint: true)))),
            TextRun("\n", attributes: attributes(.strikethrough(TextLineEffect()))),
            TextRun("Inline\n", attributes: attributes(.inline(TextInlineEffect(count: 2, strokeWidth: 1, strokeColor: blue, backgroundWidth: 1.5, backgroundColor: Color(white: 0.9))), size: 24)),
            TextRun("Shadow\n", attributes: attributes(.shadow(TextShadowEffect(offsetX: 8, offsetY: 8, color: red, tint: 60)), size: 24)),
            TextRun("Zoom", attributes: attributes(.zoom(TextZoomEffect(zoomTo: 40, offsetX: 30, offsetY: -30, from: blue, to: .white)), size: 28)),
        ]
        return TextContent(runs: runs)
    }

    static let block = Fixture.block(width: 260, height: 220) { $0.inset = Inset(left: 8, top: 8) }

    @Test func everyEffectRendersAsTheCorpusShows() throws {
        let layout = TextLayoutEngine().layout(TextEffectTests.corpus, in: [TextEffectTests.block])
        Goldens.check(layout, name: "textEffects", size: Size(width: 270, height: 230))
        let items = layout.displayItems(forContainer: 0)
        let groups = items.compactMap { item -> GroupItem? in
            if case .group(let group) = item { return group }
            return nil
        }
        #expect(groups.count == 2 && groups.allSatisfy(\.hiddenInKeyline), "effects under and over the glyphs")
        let under = groups[0].children
        let over = groups[1].children
        // Highlights, the inline rings, the shadow and the zoom steps under; lines over.
        let paths = under.compactMap { item -> PathItem? in
            if case .path(let path) = item { return path }
            return nil
        }
        #expect(paths.count == under.count)
        #expect(over.count == 3, "two underlines and a strikethrough (a line is one stroke per stretch)")
        // The inline effect's rings, widest first, outline colour then background band.
        // Glyph by glyph (six inked glyphs in "Inline"), ring by ring.
        let rings = paths.filter { path in
            [.solid(TextEffectTests.blue), .solid(Color(white: 0.9))].contains(path.appearance.fills.first?.paint)
        }
        #expect(rings.count == 4 * 6)
        let layers = stride(from: 0, to: rings.count, by: 6).map { rings[$0] }
        #expect(layers.map { $0.appearance.fills[0].paint } == [.solid(TextEffectTests.blue), .solid(Color(white: 0.9)), .solid(TextEffectTests.blue), .solid(Color(white: 0.9))])
        let reaches = layers.compactMap { $0.path.controlBounds?.width }
        #expect(reaches == reaches.sorted(by: >), "rings of 1.5 pt band and 1 pt outline, widest first")
        // The shadow: tinted, offset by percent of the size.
        let shadowColor = TextDrawing.tint(TextEffectTests.red, percent: 60)
        let shadow = try #require(paths.first { $0.appearance.fills.first?.paint == .solid(shadowColor) })
        #expect(approx(shadow.transform.tx, 24 * 0.08) && approx(shadow.transform.ty, 24 * 0.08))
        // Zoom: one step per point of travel, back (white) to front (blue).
        let steps = paths.filter { $0.transform.a != 1 }
        #expect(steps.count == Int((28 * 0.3 * 2.0.squareRoot()).rounded(.up)) || steps.count > 10)
        #expect(steps.first?.appearance.fills.first?.paint == .solid(.white))
        // The dashed underline keeps its dash; the strikethrough its overprint.
        let lines = over.compactMap { item -> StrokePaint? in
            if case .path(let path) = item { return path.appearance.strokes.first }
            return nil
        }
        #expect(lines.contains { $0.style.dash == [4, 2] } && lines.contains { $0.overprint })
    }

    @Test func displayTextEffectsOffAndKeylineLeaveThemOut() throws {
        let layout = TextLayoutEngine().layout(TextEffectTests.corpus, in: [TextEffectTests.block])
        let plain = layout.displayItems(forContainer: 0, showsEffects: false)
        #expect(!plain.contains { if case .group = $0 { return true } else { return false } }, "the preference drops every effect")
        // Keyline draws the same pixels with and without the effects.
        let viewport = Viewport(size: Size(width: 270, height: 230))
        let keyline = CoreGraphicsRenderer(background: .white, viewMode: .keyline)
        let with = try #require(keyline.renderBitmap(DisplayList(canvas: "t", items: layout.displayItems(forContainer: 0)), viewport: viewport).flatMap(BitmapSurface.init(drawing:)))
        let without = try #require(keyline.renderBitmap(DisplayList(canvas: "t", items: plain), viewport: viewport).flatMap(BitmapSurface.init(drawing:)))
        var different = 0
        for y in 0..<with.height {
            for x in 0..<with.width where with.pixel(x: x, y: y) != without.pixel(x: x, y: y) {
                different += 1
            }
        }
        #expect(different == 0)
    }

    @Test func lineEffectsFollowPathsRowsAndBaselines() throws {
        let underline = TextEffectTests.attributes(.underline(TextLineEffect(position: -2, width: 1, color: .black)), size: 14)
        // On a path: one polyline through every glyph's piece.
        let arc = Contour(polygon: (0...24).map { index in
            let angle = Double.pi + Double(index) / 24 * Double.pi
            return Point(x: 100 + 80 * cos(angle), y: 100 + 80 * sin(angle))
        }, closed: false)
        let onPath = TextLayoutEngine().layout(TextContent("Along the arc", attributes: underline), in: [.path(PathText(contour: arc))])
        let pathLines = try #require(onPath.displayItems(forContainer: 0).compactMap { item -> GroupItem? in
            if case .group(let group) = item { return group }
            return nil
        }.first)
        guard case .path(let polyline) = pathLines.children.first else {
            Issue.record("a polyline")
            return
        }
        #expect(polyline.path.elements.count == 2 * onPath.glyphs().count - 1 || polyline.path.elements.count > 10)
        Goldens.check(onPath, name: "effectsOnPath", size: Size(width: 200, height: 110))
        // In a row the wrapped sub-lines each get their own line, and trailing spaces none.
        let tabs = [TabStop(.wrapping, at: 40), TabStop(.left, at: 120)]
        let content = TextContent("a\tunderlined words wrap   ", attributes: underline, style: ParagraphStyle(tabs: tabs))
        let row = TextLayoutEngine().layout(content, in: [Fixture.block(width: 200)])
        let rowGroup = try #require(row.displayItems(forContainer: 0).compactMap { item -> GroupItem? in
            if case .group(let group) = item { return group }
            return nil
        }.first)
        #expect(rowGroup.children.count >= 2, "one stretch per sub-line")
        // A vertical line's underline turns with the line.
        var vertical = TextBlock(width: 60, height: 200)
        vertical.direction = .vertical
        let turned = TextLayoutEngine().layout(TextContent("Up", attributes: underline), in: [.block(vertical)])
        guard case .group(let turnedGroup)? = turned.displayItems(forContainer: 0).last, case .path(let turnedLine) = turnedGroup.children.first,
              case .move(let a) = turnedLine.path.elements[0], case .line(let b) = turnedLine.path.elements[1] else {
            Issue.record("a turned underline")
            return
        }
        #expect(approx(a.x, b.x, 1e-9) && b.y > a.y, "down the vertical line")
    }

    @Test func effectHelpers() {
        #expect(TextDrawing.tint(Color(red: 0, green: 0.5, blue: 1), percent: 50) == Color(red: 0.5, green: 0.75, blue: 1))
        #expect(TextDrawing.tint(.black, percent: 150) == .black)
        #expect(TextDrawing.mix(.black, .white, 0.25) == Color(white: 0.25))
        #expect(TextDrawing.lineOptions(.shadow(TextShadowEffect())) == nil)
        #expect(TextDrawing.lineOptions(.underline(TextLineEffect(position: 3))) == TextLineEffect(position: 3))
        // Effects on glyphless runs (spaces) draw nothing; a zoom without offset still steps.
        let spaces = TextLayoutEngine().layout(TextContent("   ", attributes: TextEffectTests.attributes(.shadow(TextShadowEffect()))), in: [Fixture.block()])
        #expect(!spaces.displayItems(forContainer: 0).contains { if case .group = $0 { return true } else { return false } })
        for effect in [TextEffect.inline(TextInlineEffect(count: 0)), .zoom(TextZoomEffect(zoomTo: 50, offsetX: 0, offsetY: 0))] {
            let blank = TextLayoutEngine().layout(TextContent(" ", attributes: TextEffectTests.attributes(effect)), in: [Fixture.block()])
            #expect(blank.displayItems(forContainer: 0).count <= 1)
            let inked = TextLayoutEngine().layout(TextContent("x", attributes: TextEffectTests.attributes(effect)), in: [Fixture.block()])
            #expect(inked.displayItems(forContainer: 0).contains { if case .group = $0 { return true } else { return false } })
        }
        let stroked = TextLayoutEngine().layout(TextContent(" ", attributes: TextAttributes(stroke: StrokePaint(paint: .solid(.black)))), in: [Fixture.block()])
        #expect(stroked.displayItems(forContainer: 0).count <= 1)
    }

    @Test func tenThousandEffectedCharactersStayWithinTheBudget() {
        let effects: [TextEffect] = [
            .underline(TextLineEffect(position: -2, width: 1)), .highlight(TextLineEffect(color: Color(white: 0.9))),
            .shadow(TextShadowEffect()), .inline(TextInlineEffect()), .strikethrough(TextLineEffect(position: 4)),
            .zoom(TextZoomEffect(zoomTo: 80, offsetX: 5, offsetY: 5)),
        ]
        var runs: [TextRun] = []
        var count = 0
        var index = 0
        while count < 10_000 {
            // Paragraphs of about 300 characters, as body text comes.
            let text = index % 10 == 9 ? "Effected words in a paragraph.\n" : "Effected words in a paragraph. "
            runs.append(TextRun(text, attributes: TextAttributes(fontFamily: "Helvetica", size: 12, effect: effects[index % effects.count])))
            count += text.count
            index += 1
        }
        let start = Date()
        let layout = TextLayoutEngine().layout(TextContent(runs: runs), in: [.block(TextBlock(width: 500, height: 10, autoHeight: true))])
        let items = layout.displayItems(forContainer: 0)
        let elapsed = Date().timeIntervalSince(start)
        #expect(items.count > 100)
        #if !DEBUG
        #expect(elapsed < 0.1, "laying out and drawing 10,000 effected characters took \(elapsed * 1000) ms")
        #endif
        print(String(format: "PERF WTText 10,000 effected characters: layout and display items %.1f ms", elapsed * 1000))
    }
}
