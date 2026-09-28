import Foundation
import Testing
import WTCRDT
@testable import WTModel
import WTProto

/// TYPE-060: the Superscript and Subscript presets.
@Suite struct TextScriptTests {
    static func attributes(_ a: Replica, _ node: OpID, at offset: Int) -> (size: Double, shift: Double) {
        let text = TextFixture.text(a, node)
        let run = text.runs.first { $0.range.contains(offset) }!
        let attributes = TextLayoutReading.attributes(run.values)
        return (attributes.size, attributes.baselineShift)
    }

    @Test func superscriptScalesAndRaisesEachRunByItsOwnSize() throws {
        var a = Replica(0xA)
        let node = try TextFixture.block(&a, "E=mc2 x")
        let text = TextFixture.text(a, node)
        try a.perform(ApplyMark(node: node, from: text.anchor(at: 0), to: text.anchor(at: 2), value: TextFixture.size(20)))
        let before = Self.attributes(a, node, at: 4)
        let command = try #require(TextScript.superscript.command(node, range: 1..<5, in: a.state))
        let change = try #require(try a.perform(command))
        #expect(change.label == "Superscript")
        // "=" was 20 pt, "mc2" the default size.
        let big = Self.attributes(a, node, at: 1)
        #expect(big.size == 11.6 && big.shift == 6.6)
        let small = Self.attributes(a, node, at: 4)
        #expect(abs(small.size - before.size * 0.58) < 0.01 && abs(small.shift - before.size * 0.33) < 0.01)
        // Outside the range nothing changed.
        #expect(Self.attributes(a, node, at: 0).size == 20 && Self.attributes(a, node, at: 6).shift == 0)
    }

    @Test func subscriptLowersAndAddsToAnExistingShift() throws {
        var a = Replica(0xA)
        let node = try TextFixture.block(&a, "H2O")
        let text = TextFixture.text(a, node)
        try a.perform(ApplyMark(node: node, from: text.anchor(at: 0), to: .end, value: TextFixture.size(10)))
        try a.perform(ApplyMark(node: node, from: text.anchor(at: 1), to: text.anchor(at: 2), value: TextFixture.mark { $0.baselineShift = 1 }))
        try a.perform(try #require(TextScript.`subscript`.command(node, range: 1..<2, in: a.state)))
        let two = Self.attributes(a, node, at: 1)
        #expect(two.size == 5.8 && two.shift == -0.4)
        #expect(TextScript.`subscript`.title == "Subscript" && TextScript.allCases.count == 2)
    }

    @Test func nothingToWriteGivesNoCommand() throws {
        var a = Replica(0xA)
        let node = try TextFixture.block(&a, "abc")
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil, x: 5), on: &a)
        #expect(TextScript.superscript.command(node, range: 1..<1, in: a.state) == nil)
        #expect(TextScript.superscript.command(rect, range: 0..<1, in: a.state) == nil)
        #expect(try a.perform(ApplyTextScript(node: rect, range: 0..<1, script: .superscript)) == nil)
        // Sizes stay within the document's range.
        #expect(TextScript.superscript.values(size: 0.01, shift: 0)[0].size == 0.1)
        #expect(TextScript.superscript.values(size: 100_000, shift: 0)[0].size == 10_000)
    }
}
