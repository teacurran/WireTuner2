import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender
import WTText

/// A text node as WTText lays it out (`TextLayoutReading`).
@Suite struct TextLayoutReadingTests {
    @Test func contentCarriesRunsParagraphsAndCharacterIDs() throws {
        var a = Replica(1)
        var paragraph = Wiretuner_Doc_V1_ParagraphProps()
        paragraph.alignment = .justified
        let node = try TextFixture.block(&a, "ab\ncd", paragraph: paragraph)
        try a.perform(ApplyMark(node: node, from: TextFixture.at(a, node, 3), to: .end, value: TextFixture.size(20)))
        let text = TextFixture.text(a, node)
        let content = TextLayoutReading.content(text)
        #expect(content.string == "ab\ncd")
        #expect(content.runs.map(\.text) == ["ab\n", "cd"])
        #expect(content.runs.map(\.attributes.size) == [12, 20])
        #expect(content.paragraphs.map(\.alignment) == [.justified, .justified])
        #expect(content.charIDs == text.chars.map { CharID(counter: $0.counter, replica: $0.replica) })
    }

    @Test func everyMarkWTTextReadsMapsToItsAttribute() {
        let fill = Wiretuner_Doc_V1_ColorRef.with { $0.inline = .with { $0.rgb = .with { $0.r = 1 } } }
        let values: [Wiretuner_Doc_V1_TextMarkValue] = [
            TextFixture.family("Menlo"), TextFixture.mark { $0.fontStyle = "Bold" }, TextFixture.size(30),
            TextFixture.mark { $0.leading = .with { $0.mode = .fixed; $0.value = 40 } }, TextFixture.mark { $0.kerning = 10 },
            TextFixture.mark { $0.rangeKerning = 5 }, TextFixture.mark { $0.baselineShift = 3 }, TextFixture.mark { $0.horizontalScale = 80 },
            TextFixture.mark { $0.fill = fill }, TextFixture.mark { $0.language = "de" }, TextFixture.mark { $0.noBreak = true },
            TextFixture.mark { $0.noHyphen = true }, TextFixture.mark { $0.overprint = true }, TextFixture.mark { $0.case = .smallCaps },
            TextFixture.mark { $0.axes.axes = [.with { $0.tag = "wght"; $0.value = 700 }, .with { $0.tag = "wght"; $0.value = 650 }] },
            TextFixture.feature("liga", .off), TextFixture.feature("smcp", .on), TextFixture.feature("onum", .default),
            TextFixture.mark { $0.link = "x" },
        ]
        let attributes = TextLayoutReading.attributes(values)
        #expect(attributes.fontFamily == "Menlo" && attributes.fontStyle == "Bold" && attributes.size == 30)
        #expect(attributes.leading == WTText.Leading(mode: .fixed, value: 40))
        #expect(attributes.kerning == 10 && attributes.rangeKerning == 5 && attributes.baselineShift == 3 && attributes.horizontalScale == 80)
        #expect(attributes.fill == ColorValues.color(fill.inline))
        #expect(attributes.language == "de" && attributes.noBreak && attributes.noHyphen && attributes.overprint && attributes.smallCaps)
        #expect(attributes.axes == ["wght": 650])
        #expect(attributes.features == ["liga": .off, "smcp": .on, "onum": .default])
        #expect(TextLayoutReading.attributes([TextFixture.mark { $0.leading = .with { $0.mode = .percent; $0.value = 150 } }]).leading
            == WTText.Leading(mode: .percent, value: 150))
        #expect(TextLayoutReading.attributes([TextFixture.mark { $0.leading = .with { $0.value = 2 } }]).leading
            == WTText.Leading(mode: .extra, value: 2))
        // A swatch reference needs a resolver; without one the fill stays the default.
        let swatch = TextFixture.mark { $0.fill = .with { $0.swatch = .with { $0.id = OpID(counter: 9, replica: 9).proto } } }
        #expect(TextLayoutReading.attributes([swatch]).fill == TextAttributes().fill)
    }

    @Test func paragraphRegistersMapToTheParagraphStyle() {
        var props = Wiretuner_Doc_V1_ParagraphProps()
        props.alignment = .center
        props.raggedWidth = 150
        props.flushZone = 40
        props.leftIndent = 1
        props.rightIndent = 2
        props.firstLineIndent = 3
        props.spaceAbove = 4
        props.spaceBelow = 5
        props.tabs = [.with { $0.kind = .decimal; $0.position = 10 }, .with { $0.kind = .right; $0.position = 20 },
                      .with { $0.kind = .center; $0.position = 30 }, .with { $0.kind = .wrapping; $0.position = 40 },
                      .with { $0.position = 50; $0.leader = "." }]
        props.hyphenation = .with { $0.enabled = true; $0.language = "fr"; $0.consecutive = 2; $0.skipCapitalized = true }
        props.hangPunctuation = true
        props.keepLines = 2
        props.keepWithNext = true
        props.wordSpacing = .with { $0.min = 70; $0.opt = 90; $0.max = 120 }
        props.letterSpacing = .with { $0.min = -1; $0.opt = 0; $0.max = 2 }
        let style = TextLayoutReading.paragraphStyle(props)
        #expect(style.alignment == .center && style.raggedWidth == 100 && style.flushZone == 40)
        #expect(style.leftIndent == 1 && style.rightIndent == 2 && style.firstLineIndent == 3 && style.spaceAbove == 4 && style.spaceBelow == 5)
        #expect(style.tabs.map(\.kind) == [.decimal, .right, .center, .wrapping, .left])
        #expect(style.tabs.last?.leader == ".")
        #expect(style.hyphenation == Hyphenation(enabled: true, language: "fr", consecutive: 2, skipCapitalized: true))
        #expect(style.hangPunctuation && style.keepLines == 2 && style.keepWithNext)
        #expect(style.wordSpacing == SpacingRange(min: 70, optimum: 90, max: 120))
        #expect(style.letterSpacing == SpacingRange(min: -1, optimum: 0, max: 2))
        let plain = TextLayoutReading.paragraphStyle(.with { $0.alignment = .right; $0.raggedWidth = 60 })
        #expect(plain.alignment == .right && plain.raggedWidth == 60 && plain.hyphenation.language == nil)
        #expect(plain.wordSpacing == .words && plain.letterSpacing == .letters)
        #expect(TextLayoutReading.paragraphStyle(.init()).raggedWidth == 100)
    }

    @Test func blockPropsMapToTheContainer() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "ab", at: Point(x: 5, y: 6))
        var block = Wiretuner_Doc_V1_TextBlockProps()
        block.width = 120
        block.height = 60
        block.inset = .with { $0.left = 1; $0.right = 2; $0.top = 3; $0.bottom = 4 }
        block.displayBorder = true
        block.columns = .with {
            $0.columns = 2; $0.columnSpacing = 6; $0.rows = 3; $0.rowSpacing = 4; $0.flow = .across
            $0.columnRules = .inset; $0.rowRules = .full
        }
        block.adjust = .with { $0.balance = true; $0.thresholdPercent = 70; $0.copyfitMinPercent = 80; $0.copyfitMaxPercent = 120 }
        block.direction = .vertical
        try a.perform(SetTextBlock(node: node, block: block, fields: [[1], [2], [3], [4], [5], [6], [7], [8], [9]]))
        guard case .block(let container) = TextLayoutReading.container(TextFixture.text(a, node)) else {
            Issue.record("block"); return
        }
        #expect(container.width == 120 && container.height == 60 && !container.autoWidth && !container.autoHeight)
        #expect(container.inset == Inset(left: 1, right: 2, top: 3, bottom: 4))
        #expect(container.columns == ColumnsRows(columns: 2, columnSpacing: 6, rows: 3, rowSpacing: 4, flow: .across, columnRules: .inset, rowRules: .full))
        #expect(container.adjust == AdjustColumns(balance: true, thresholdPercent: 70, copyfitMinPercent: 80, copyfitMaxPercent: 120))
        #expect(container.direction == .vertical && container.displayBorder)
        #expect(container.transform == AffineTransform.translation(x: 5, y: 6))
        // Unset adjustments and columns read as their defaults.
        let plain = try TextFixture.block(&a, "x")
        guard case .block(let defaults) = TextLayoutReading.container(TextFixture.text(a, plain)) else {
            Issue.record("block"); return
        }
        #expect(defaults.columns == ColumnsRows() && defaults.adjust == AdjustColumns() && defaults.direction == .horizontal)
        #expect(defaults.autoWidth && defaults.autoHeight)
    }

    @MainActor
    @Test func textBlocksLayOutAndDrawThroughTheDocumentsEngine() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "Hello\nworld", at: Point(x: 100, y: 50))
        let fonts = DocumentFontIndex(state: a.state)
        let layout = TextLayoutReading.layout(TextFixture.text(a, node), engine: fonts.layoutEngine)
        #expect(layout.lineCount == 2)
        #expect(!layout.overflows)
        guard case .group(let group)? = TextLayoutReading.item(node, in: a.state, engine: fonts.layoutEngine) else {
            Issue.record("item"); return
        }
        let runs = group.children.compactMap { item -> TextRunItem? in if case .text(let run) = item { return run } else { return nil } }
        #expect(runs.map(\.text).joined().contains("Hello"))
        #expect(runs.allSatisfy { $0.transform.tx == 100 && $0.transform.ty == 50 })
        // Not text, or nothing to draw.
        #expect(TextLayoutReading.item(WellKnown.layers, in: a.state, engine: fonts.layoutEngine) == nil)
        let empty = try TextFixture.block(&a)
        #expect(TextLayoutReading.item(empty, in: a.state, engine: fonts.layoutEngine) == nil)
    }
}
