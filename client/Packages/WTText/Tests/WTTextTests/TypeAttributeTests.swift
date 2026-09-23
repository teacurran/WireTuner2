import CoreText
import Foundation
import Testing
import WTGeometry
import WTRender
import struct WTRender.StrokeStyle
@testable import WTText

/// TYPE-021 (every character attribute in layout and render) and TYPE-047 (variation axes and
/// OpenType features through Core Text).
@Suite struct TypeAttributeTests {
    static let wideBlock = Fixture.block(width: 400, height: 400)

    func layout(_ runs: [TextRun], style: ParagraphStyle = ParagraphStyle(), in containers: [TextContainer] = [wideBlock]) -> TextLayout {
        let content = TextContent(runs: runs, paragraphs: [ParagraphStyle](repeating: style, count: runs.map(\.text).joined().filter { $0 == "\n" }.count + 1))
        return TextLayoutEngine().layout(content, in: containers)
    }

    /// The glyphs and x positions Core Text itself sets `string` in with `font`.
    static func coreTextReference(_ string: String, font: CTFont) -> (glyphs: [CGGlyph], xs: [Double]) {
        let attributed = NSAttributedString(string: string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        var glyphs: [CGGlyph] = []
        var xs: [Double] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var ids = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &ids)
            CTRunGetPositions(run, CFRange(), &positions)
            glyphs += ids
            xs += positions.map { Double($0.x) }
        }
        return (glyphs, xs)
    }

    // MARK: TYPE-021

    @Test func everyAttributeRendersAsTheCorpusShows() {
        let body = Fixture.body
        var runs: [TextRun] = []
        func add(_ text: String, _ change: (inout TextAttributes) -> Void) {
            var attributes = body
            change(&attributes)
            runs.append(TextRun(text, attributes: attributes))
        }
        add("Size 20 ", { $0.size = 20 })
        add("kern\n", { $0.kerning = 40 })
        add("Range kerning wide\n", { $0.rangeKerning = 25 })
        add("Base", { _ in })
        add("shift", { $0.baselineShift = 5 })
        add(" down\n", { $0.baselineShift = -4 })
        add("Scaled 160%", { $0.horizontalScale = 160 })
        add(" and 60%\n", { $0.horizontalScale = 60 })
        add("Small Caps Text\n", { $0.smallCaps = true; $0.size = 16 })
        add("Chancery Bold Italic\n", { $0.fontFamily = "Apple Chancery"; $0.fontStyle = "Bold Italic"; $0.size = 16 })
        add("Stroked", { $0.size = 22; $0.fill = .white; $0.stroke = StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 0.8)) })
        add(" red\n", { $0.size = 22; $0.fill = Color(red: 0.8, green: 0.1, blue: 0.1) })
        add("Fixed leading 30", { $0.leading = Leading(mode: .fixed, value: 30) })
        let layout = self.layout(runs)
        Goldens.check(layout, name: "typeAttributes", size: Size(width: 320, height: 200))
        #expect(layout.fontReport.synthesizedFaces == [FaceName(family: "Apple Chancery", style: "Bold Italic")])
    }

    @Test func kerningRangeKerningAndBaselineShiftMoveGlyphs() {
        func origins(_ attributes: TextAttributes) -> [Point] {
            layout([TextRun("AVAV", attributes: attributes)]).glyphs().map(\.origin)
        }
        let plain = origins(Fixture.body)
        var kerned = Fixture.body
        kerned.kerning = 50
        // Pair kerning adds % of an em after each character of its span, on top of the font's.
        let kernedOrigins = origins(kerned)
        #expect(approx(kernedOrigins[1].x - plain[1].x, 6, 0.01))
        #expect(approx(kernedOrigins[3].x - plain[3].x, 18, 0.01))
        var tracked = Fixture.body
        tracked.rangeKerning = 25
        tracked.kerning = 25
        #expect(approx(origins(tracked)[2].x - plain[2].x, 12, 0.01), "pair and range kerning combine")
        var raised = Fixture.body
        raised.baselineShift = 3
        let shifted = layout([TextRun("A", attributes: Fixture.body), TextRun("V", attributes: raised)])
        #expect(approx(shifted.glyphs()[1].origin.y - shifted.lineOrigins[0].y, -3, 0.001), "raised from the line's baseline")
        #expect(approx(shifted.lineOrigins[0].y - layout([TextRun("AV", attributes: Fixture.body)]).lineOrigins[0].y, 3, 0.01), "and the line's ascent grows with it")
    }

    @Test func horizontalScaleIsAGlyphTransform() throws {
        var wide = Fixture.body
        wide.horizontalScale = 200
        let plain = layout([TextRun("MM", attributes: Fixture.body)])
        let scaled = layout([TextRun("MM", attributes: wide)])
        #expect(approx(scaled.glyphs()[0].advance, 2 * plain.glyphs()[0].advance, 0.01))
        let run = try #require(scaled.displayItems(forContainer: 0).compactMap { item -> GlyphRun? in
            if case .text(let text) = item { return text.glyphRun }
            return nil
        }.first)
        #expect(run.font.horizontalScale == 2)
        // Read-time normalizations: a non-positive scale is 100, a size out of range the default.
        var odd = Fixture.body
        odd.horizontalScale = -5
        odd.size = 0
        let normalized = layout([TextRun("MM", attributes: odd)])
        #expect(approx(normalized.glyphs()[0].advance, plain.glyphs()[0].advance, 0.001))
        odd.size = 20_000
        #expect(approx(layout([TextRun("MM", attributes: odd)]).glyphs()[0].advance, plain.glyphs()[0].advance, 0.001))
    }

    @Test func leadingPerLineIsTheLargestOnTheLine() {
        var tall = Fixture.body
        tall.leading = Leading(mode: .fixed, value: 40)
        var extra = Fixture.body
        extra.leading = Leading(mode: .extra, value: 6)
        let mixed = layout([TextRun("one ", attributes: Fixture.body), TextRun("two", attributes: tall), TextRun("\nthree ", attributes: Fixture.body), TextRun("four\nfive", attributes: extra)])
        let origins = mixed.lineOrigins
        #expect(approx(origins[1].y - origins[0].y, 18, 0.001), "line 2 holds extra +6 on 12 pt and auto 14.4: 18")
        #expect(approx(origins[2].y - origins[1].y, 18, 0.001))
        let second = layout([TextRun("a ", attributes: Fixture.body), TextRun("b", attributes: tall), TextRun("\nc", attributes: tall)])
        #expect(approx(second.lineOrigins[1].y - second.lineOrigins[0].y, 40, 0.001))
        #expect(approx(Leading(mode: .percent, value: 150).distance(forSize: 10), 15))
    }

    @Test func smallCapsAreScaledCapitalsInAnyFont() throws {
        var caps = TextAttributes(fontFamily: "Helvetica", size: 20)
        let capitals = layout([TextRun("AB", attributes: caps)]).glyphs()
        caps.smallCaps = true
        let small = layout([TextRun("Ab", attributes: caps)])
        let glyphs = small.glyphs()
        #expect(glyphs.map(\.glyph) == capitals.map(\.glyph), "lowercase shaped as its capital")
        #expect(approx(glyphs[1].advance, capitals[1].advance * TextAttributes.smallCapsScale, 0.01))
        // A letter whose capital is two scalars (ß) stays as it is.
        let sharp = layout([TextRun("ß", attributes: caps)])
        #expect(sharp.glyphs().count == 1)
        #expect(TypesetParagraph.singleUppercase("ß") == nil && TypesetParagraph.singleUppercase("a") == "A")
    }

    @Test func facesTheFamilyLacksAreSynthesized() throws {
        let resolver = FontResolver.shared
        let real = resolver.resolve(TextAttributes(fontFamily: "Helvetica", fontStyle: "Bold")).font
        #expect(real.emboldening == 0 && real.report.isEmpty)
        let italic = resolver.resolve(TextAttributes(fontFamily: "Apple Chancery", fontStyle: "Italic")).font
        #expect(CTFontGetMatrix(italic.font).c == CGFloat(FontResolver.syntheticObliqueness) && italic.emboldening == 0)
        let bold = resolver.resolve(TextAttributes(fontFamily: "Apple Chancery", fontStyle: "Bold", size: 20)).font
        #expect(approx(bold.emboldening, 20 * FontResolver.syntheticEmboldening))
        // A face found by its traits is real: Helvetica has an oblique for "Italic".
        let traited = resolver.resolve(TextAttributes(fontFamily: "Helvetica", fontStyle: "Italic")).font
        #expect(traited.report.isEmpty && CTFontGetMatrix(traited.font).c == 0)
        // Synthesized glyphs carry the slant, and the bold draws a stroke in the fill colour.
        let laid = layout([TextRun("Bold", attributes: TextAttributes(fontFamily: "Apple Chancery", fontStyle: "Bold Italic", size: 20))])
        let items = laid.displayItems(forContainer: 0)
        let run = try #require(items.compactMap { item -> GlyphRun? in
            if case .text(let text) = item { return text.glyphRun }
            return nil
        }.first)
        #expect(run.font.obliqueness > 0.2)
        let decorations = try #require(items.compactMap { item -> GroupItem? in
            if case .group(let group) = item { return group }
            return nil
        }.first)
        #expect(decorations.hiddenInKeyline && decorations.children.count == 4, "the weight, glyph by glyph")
    }

    @Test func aMissingFamilyIsSubstitutedAndReported() {
        let laid = layout([TextRun("Hello", attributes: TextAttributes(fontFamily: "No Such Family", fontStyle: "Bold", axes: ["wght": 700]))])
        #expect(laid.fontReport.missingFamilies == ["No Such Family"])
        #expect(laid.fontReport.droppedAxes[FaceName(family: "No Such Family", style: "Bold")] == ["wght"])
        #expect(!laid.fontReport.isEmpty && FontReport().isEmpty)
        #expect(laid.glyphs().count == 5, "the substitute renders")
        #expect(FaceName(family: "A", style: "B").description == "A B" && FaceName(family: "A").description == "A")
    }

    @Test func inlineGraphicsFlowWithTheText() throws {
        let square = DisplayItem.fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 10, height: 20)), paint: .solid(.black)))
        var graphic = Fixture.body
        graphic.inlineGraphic = InlineGraphic(bounds: Rect(x: 0, y: 0, width: 10, height: 20), items: [square])
        graphic.baselineShift = 2
        let laid = layout([TextRun("ab", attributes: Fixture.body), TextRun("\u{FFFC}", attributes: graphic), TextRun("cd", attributes: Fixture.body)])
        let glyphs = laid.glyphs()
        #expect(glyphs.count == 4, "the graphic is not a glyph")
        let b = glyphs[1]
        let c = glyphs[2]
        #expect(approx(c.origin.x - (b.origin.x + b.advance), 10, 0.01), "it advances by its width")
        let placement = try #require(laid.inlineGraphics().first)
        #expect(placement.offset == 2 && placement.container == 0)
        let corner = placement.transform.apply(Point(x: 0, y: 20))
        #expect(approx(corner.x, b.origin.x + b.advance, 0.01) && approx(corner.y, laid.lineOrigins[0].y - 2, 0.01), "bottom-left on the shifted baseline")
        let fills = laid.displayItems(forContainer: 0).compactMap { item -> FillItem? in
            if case .fill(let fill) = item { return fill }
            return nil
        }
        #expect(fills.count == 1 && fills[0].transform == placement.transform)
        #expect(laid.lineOrigins[0].y >= 20, "the line's ascent makes room for it")
        // A missing node draws an empty box the type size tall; a bare U+FFFC takes no room.
        var missing = Fixture.body
        missing.inlineGraphic = InlineGraphic(bounds: .zero, items: nil)
        let boxed = layout([TextRun("a", attributes: Fixture.body), TextRun("\u{FFFC}", attributes: missing), TextRun("b", attributes: Fixture.body)])
        #expect(approx(boxed.glyphs()[1].origin.x - boxed.glyphs()[0].origin.x - boxed.glyphs()[0].advance, 12, 0.01))
        #expect(boxed.displayItems(forContainer: 0).contains { if case .path = $0 { return true } else { return false } })
        let bare = layout([TextRun("a\u{FFFC}b", attributes: Fixture.body)])
        let plain = layout([TextRun("ab", attributes: Fixture.body)])
        #expect(approx(bare.glyphs()[1].origin.x, plain.glyphs()[1].origin.x, 0.01))
        #expect(bare.inlineGraphics().isEmpty)
    }

    @Test func overprintReachesTheGlyphRun() throws {
        var overprinted = Fixture.body
        overprinted.overprint = true
        let item = try #require(layout([TextRun("x", attributes: overprinted)]).displayItems(forContainer: 0).first)
        guard case .text(let text) = item else {
            Issue.record("expected a text run")
            return
        }
        #expect(text.overprint)
    }

    @Test func mixedAttributesStayWithinTheBudget() {
        let engine = TextLayoutEngine()
        func content(editing index: Int?) -> TextContent {
            var runs: [TextRun] = []
            for number in 0..<600 {
                let words = (0..<60).map { "w\($0 % 7)" }.joined(separator: " ")
                var attributes = Fixture.body
                attributes.size = 10 + Double(number % 5)
                attributes.kerning = Double(number % 3)
                attributes.baselineShift = number.isMultiple(of: 7) ? 1 : 0
                attributes.horizontalScale = number.isMultiple(of: 3) ? 90 : 100
                attributes.smallCaps = number.isMultiple(of: 11)
                runs.append(TextRun((number == index ? "Edited " : "") + words + " ", attributes: attributes))
                var bold = attributes
                bold.fontStyle = "Bold"
                runs.append(TextRun(String(repeating: "strong words ", count: 12) + "\n", attributes: bold))
            }
            return TextContent(runs: runs)
        }
        let initial = content(editing: nil)
        #expect(initial.scalarCount > 200_000)
        _ = engine.layout(initial, in: IncrementalLayoutTests.chain)
        let lookups = engine.fontLookups
        let hits = engine.fontHits
        let start = Date()
        _ = engine.layout(content(editing: 100), in: IncrementalLayoutTests.chain)
        let elapsed = Date().timeIntervalSince(start)
        let relayoutLookups = engine.fontLookups - lookups
        #expect(relayoutLookups > 0 && Double(engine.fontHits - hits) / Double(relayoutLookups) > 0.99, "run fonts come from the cache on relayout")
        PerfBudget.expect(.seconds(elapsed), within: .milliseconds(100))
        print(String(format: "PERF WTText mixed attributes: relayout %.1f ms", elapsed * 1000))
    }

    // MARK: TYPE-047

    @Test func variationAxesMatchCoreText() throws {
        let text = "Variable Weight"
        let weights = [400.0, 550, 700]
        var runs: [TextRun] = []
        for weight in weights {
            let attributes = TextAttributes(fontFamily: "STIX Two Text", size: 18, axes: ["wght": weight])
            runs.append(TextRun(text + (weight == 700 ? "" : "\n"), attributes: attributes))
            // The same tuple through Core Text directly: identical glyphs at identical places.
            let base = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: "STIX Two Text"] as CFDictionary), 18, nil)
            let variation = [NSNumber(value: fourCharCode("wght")!): NSNumber(value: weight)]
            let font = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), [kCTFontVariationAttribute: variation] as CFDictionary), 18, nil)
            let reference = TypeAttributeTests.coreTextReference(text, font: font)
            let laid = layout([TextRun(text, attributes: attributes)]).glyphs()
            #expect(laid.map(\.glyph) == reference.glyphs)
            #expect(zip(laid.map(\.origin.x), reference.xs).allSatisfy { approx($0, $1, 0.001) }, "weight \(weight)")
        }
        let laid = layout(runs)
        Goldens.check(laid, name: "variableWeights", size: Size(width: 200, height: 80))
        // Out of range values clamp; tags the font lacks are dropped and reported.
        let clamped = FontResolver.shared.font(for: TextAttributes(fontFamily: "STIX Two Text", size: 18, axes: ["wght": 5000, "wdth": 50]))
        let variation = CTFontCopyVariation(clamped) as? [NSNumber: NSNumber]
        #expect(variation?[NSNumber(value: fourCharCode("wght")!)]?.doubleValue == 700)
        let report = layout([TextRun("x", attributes: TextAttributes(fontFamily: "STIX Two Text", axes: ["wdth": 50, "wght": 500]))]).fontReport
        #expect(report.droppedAxes == [FaceName(family: "STIX Two Text"): ["wdth"]])
    }

    @Test func openTypeFeaturesMatchCoreText() throws {
        let cases: [(tag: String, text: String)] = [
            ("liga", "office fly"), ("smcp", "Small caps"), ("onum", "0123456789"),
            ("tnum", "1111 0000"), ("frac", "1/2 3/4"), ("ss01", "agyq 1234"),
        ]
        var runs: [TextRun] = []
        for (index, (tag, text)) in cases.enumerated() {
            let state: FeatureState = tag == "liga" ? .off : .on
            let attributes = TextAttributes(fontFamily: "Mukta Mahee", size: 18, features: [tag: state])
            let plain = layout([TextRun(text, attributes: TextAttributes(fontFamily: "Mukta Mahee", size: 18))]).glyphs()
            let laid = layout([TextRun(text, attributes: attributes)]).glyphs()
            #expect(laid.map(\.glyph) != plain.map(\.glyph), "\(tag) changes the glyphs")
            let base = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: "Mukta Mahee"] as CFDictionary), 18, nil)
            let setting = [[kCTFontOpenTypeFeatureTag: tag, kCTFontOpenTypeFeatureValue: state == .on ? 1 : 0]]
            let font = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), [kCTFontFeatureSettingsAttribute: setting] as CFDictionary), 18, nil)
            let reference = TypeAttributeTests.coreTextReference(text, font: font)
            #expect(laid.map(\.glyph) == reference.glyphs, "\(tag)")
            #expect(zip(laid.map(\.origin.x), reference.xs).allSatisfy { approx($0, $1, 0.001) }, "\(tag)")
            runs.append(TextRun(text + (index < cases.count - 1 ? "\n" : ""), attributes: attributes))
        }
        Goldens.check(layout(runs), name: "openTypeFeatures", size: Size(width: 160, height: 170))
        // A tag the font lacks is dropped and reported; DEFAULT writes nothing.
        let report = layout([TextRun("x", attributes: TextAttributes(fontFamily: "Helvetica", features: ["ss07": .on, "liga": .default]))]).fontReport
        #expect(report.droppedFeatures == [FaceName(family: "Helvetica"): ["ss07"]])
    }

    @Test func featureTagsComeFromLayoutTablesAndAATFeatures() {
        let resolver = FontResolver.shared
        let mukta = resolver.font(for: TextAttributes(fontFamily: "Mukta Mahee"))
        #expect(resolver.featureTags(of: mukta).isSuperset(of: ["liga", "smcp", "onum", "tnum", "frac", "ss01"]))
        let baskerville = resolver.font(for: TextAttributes(fontFamily: "Baskerville"))
        #expect(resolver.featureTags(of: baskerville).contains("liga"), "AAT ligatures map to liga")
        #expect(FontResolver.aatFeatureTag(type: 35, selector: 6) == "ss03")
        #expect(FontResolver.aatFeatureTag(type: 35, selector: 7) == nil)
        #expect(FontResolver.aatFeatureTag(type: 1, selector: 4) == "dlig" && FontResolver.aatFeatureTag(type: 99, selector: 0) == nil)
        for (type, selector, tag) in [(1, 18, "clig"), (3, 3, "smcp"), (37, 1, "smcp"), (38, 1, "c2sc"), (6, 0, "tnum"), (6, 1, "pnum"), (21, 0, "onum"), (21, 1, "lnum"), (11, 2, "frac"), (8, 0, "swsh"), (36, 2, "swsh"), (36, 0, "calt")] {
            #expect(FontResolver.aatFeatureTag(type: type, selector: selector) == tag)
        }
        // Malformed tables yield nothing.
        #expect(FontResolver.layoutFeatureTags(in: []).isEmpty)
        #expect(FontResolver.layoutFeatureTags(in: [0, 1, 0, 0, 0, 10, 0, 8, 0, 2, 0x6C, 0x69]).isEmpty)
        #expect(FontResolver.layoutFeatureTags(in: [0, 1, 0, 0, 0, 10, 0, 8, 0, 1, 0x6C, 0x69, 0x67, 0x61, 0, 0]) == ["liga"])
    }

    @Test func axesOnEveryParagraphStayWithinTheBudget() {
        let engine = TextLayoutEngine()
        func content(editing index: Int?) -> TextContent {
            let paragraph = String(repeating: "Variable fonts carry a design space. ", count: 14)
            let runs = (0..<400).map { number in
                TextRun((number == index ? "Edited " : "") + paragraph + "\n", attributes: TextAttributes(fontFamily: "STIX Two Text", size: 11, axes: ["wght": 400 + Double(number % 4) * 100]))
            }
            return TextContent(runs: runs)
        }
        _ = engine.layout(content(editing: nil), in: IncrementalLayoutTests.chain)
        let lookups = engine.fontLookups
        let hits = engine.fontHits
        let start = Date()
        _ = engine.layout(content(editing: 3), in: IncrementalLayoutTests.chain)
        let elapsed = Date().timeIntervalSince(start)
        #expect(Double(engine.fontHits - hits) / Double(max(engine.fontLookups - lookups, 1)) > 0.99)
        PerfBudget.expect(.seconds(elapsed), within: .milliseconds(100))
        print(String(format: "PERF WTText axes on every paragraph: relayout %.1f ms", elapsed * 1000))
    }
}
