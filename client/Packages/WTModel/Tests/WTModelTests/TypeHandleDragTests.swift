import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTText

/// TYPE-018: the arithmetic of the leading and kerning handle drags.
@Suite struct TypeHandleDragTests {
    static func attributes(size: Double = 12, leading: WTText.Leading? = nil, rangeKerning: Double = 0) -> TextAttributes {
        var attributes = TextLayoutReading.attributes([])
        attributes.size = size
        attributes.leading = leading
        attributes.rangeKerning = rangeKerning
        return attributes
    }

    @Test func theDraggedEdgeFollowsThePointer() {
        #expect(TypeHandleDrag.leadingDelta(distance: 12, lines: 4) == 3)
        #expect(TypeHandleDrag.leadingDelta(distance: 12, lines: 0) == 12)
        // 11 characters, 10 gaps: 12 points at 12 pt is 100% of an em shared by 10 gaps.
        #expect(TypeHandleDrag.kerningDelta(distance: 12, size: 12, characters: 11) == 10)
        #expect(TypeHandleDrag.kerningDelta(distance: 12, size: 12, characters: 1) == 100)
        #expect(TypeHandleDrag.kerningDelta(distance: 12, size: 0, characters: 5) == 0)
    }

    @Test func leadingKeepsItsModeAndShiftTakesWholeSteps() {
        let extra = TypeHandleDrag.leading(Self.attributes(leading: WTText.Leading(mode: .extra, value: 2)), delta: 1.26, coarse: false)
        #expect(extra.mode == .extra && extra.value == 3.3)
        #expect(TypeHandleDrag.leading(Self.attributes(leading: WTText.Leading(mode: .extra, value: 2)), delta: 1.26, coarse: true).value == 3)
        #expect(TypeHandleDrag.leading(Self.attributes(leading: WTText.Leading(mode: .extra, value: 0)), delta: -40, coarse: false).value == -12,
                "never below zero line height")
        let fixed = TypeHandleDrag.leading(Self.attributes(leading: WTText.Leading(mode: .fixed, value: 14)), delta: -2.04, coarse: false)
        #expect(fixed.mode == .fixed && fixed.value == 12)
        #expect(TypeHandleDrag.leading(Self.attributes(leading: WTText.Leading(mode: .fixed, value: 1)), delta: -5, coarse: false).value == 0)
        // Unset is auto, 120%: 1.2 points at 12 pt is 10%.
        let auto = TypeHandleDrag.leading(Self.attributes(), delta: 1.2, coarse: false)
        #expect(auto.mode == .percent && auto.value == 130)
        #expect(TypeHandleDrag.leading(Self.attributes(), delta: 0.04, coarse: true).value == 120)
        #expect(TypeHandleDrag.leading(Self.attributes(), delta: -100, coarse: false).value == 0)
    }

    @Test func kerningMovesByTenthsOrWholePercent() {
        #expect(TypeHandleDrag.rangeKerning(Self.attributes(rangeKerning: 5), delta: 2.34, coarse: false) == 7.3)
        #expect(TypeHandleDrag.rangeKerning(Self.attributes(rangeKerning: 5), delta: 2.34, coarse: true) == 7)
        #expect(TypeHandleDrag.rangeKerning(Self.attributes(), delta: -3.46, coarse: false) == -3.5)
    }

    @Test func theReadoutNamesTheValue() {
        var value = Wiretuner_Doc_V1_TextMarkValue()
        value.leading = .with { $0.mode = .extra; $0.value = 2 }
        #expect(TypeHandleDrag.readout(value) == "Leading +2 pt")
        value.leading = .with { $0.mode = .extra; $0.value = -1.5 }
        #expect(TypeHandleDrag.readout(value) == "Leading -1.5 pt")
        value.leading = .with { $0.mode = .fixed; $0.value = 14 }
        #expect(TypeHandleDrag.readout(value) == "Leading =14 pt")
        value.leading = .with { $0.mode = .percent; $0.value = 130 }
        #expect(TypeHandleDrag.readout(value) == "Leading 130%")
        value.rangeKerning = 5
        #expect(TypeHandleDrag.readout(value) == "Range kerning 5%")
        value.size = 3
        #expect(TypeHandleDrag.readout(value) == "")
    }

    @Test func aDragIsOneMarkOverTheWholeText() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "Hello world")
        let text = TextFixture.text(a, node)
        let value = try #require(TypeHandleDrag.mark(.leading, text: text, delta: 1.2, coarse: false))
        #expect(value.leading.value == 130)
        let command = try #require(TypeHandleDrag.command(node: node, text: text, value: value))
        #expect(command.label == "Leading")
        let change = try #require(try a.perform(command))
        #expect(change.ops.count == 1, "one mark")
        let after = TextFixture.text(a, node)
        #expect(after.runs.count == 1 && TextLayoutReading.attributes(after.values(at: 10)).leading == WTText.Leading(mode: .percent, value: 130))
        let kern = try #require(TypeHandleDrag.mark(.kerning, text: after, delta: 5, coarse: true))
        #expect(TypeHandleDrag.command(node: node, text: after, value: kern)?.label == "Kern")
        let empty = try TextFixture.block(&a, "")
        #expect(TypeHandleDrag.mark(.leading, text: TextFixture.text(a, empty), delta: 1, coarse: false) == nil)
        #expect(TypeHandleDrag.command(node: empty, text: TextFixture.text(a, empty), value: value) == nil)
    }

    @Test func twoConcurrentLeadingDragsConvergeOnOneValue() throws {
        var pair = Pair()
        let node = try TextFixture.block(&pair.a, "Shared text")
        pair.sync()
        let textA = TextFixture.text(pair.a, node)
        let textB = TextFixture.text(pair.b, node)
        let fromA = try #require(TypeHandleDrag.mark(.leading, text: textA, delta: 2.4, coarse: false))
        let fromB = try #require(TypeHandleDrag.mark(.leading, text: textB, delta: -1.2, coarse: false))
        try pair.a.perform(try #require(TypeHandleDrag.command(node: node, text: textA, value: fromA)))
        try pair.b.perform(try #require(TypeHandleDrag.command(node: node, text: textB, value: fromB)))
        pair.sync()
        let leadingA = (0..<11).map { TextLayoutReading.attributes(TextFixture.text(pair.a, node).values(at: $0)).leading }
        let leadingB = (0..<11).map { TextLayoutReading.attributes(TextFixture.text(pair.b, node).values(at: $0)).leading }
        #expect(leadingA == leadingB)
        #expect(Set(leadingA.map { $0?.value }).count == 1, "one value over the whole block")
    }
}
