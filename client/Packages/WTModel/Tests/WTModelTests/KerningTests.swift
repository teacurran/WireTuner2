import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// FONT-016: kerning lookup, classes, pairs with redundancy removal, cells, the commands and the
/// read-time normalizations (kerning-metrics.adoc).
@Suite struct KerningTests {
    /// A typeface with A, V, O, C, T, o and their ids.
    static func glyphs(_ a: inout Replica) throws -> [String: OpID] {
        try TypefaceFixture.typeface(&a, set: nil)
        try a.perform(AddGlyphs("AVOCTo".unicodeScalars.map { NewGlyph(scalar: $0.value) }))
        return Dictionary(uniqueKeysWithValues: GlyphIndex(a.state).glyphs.map { ($0.name, $0.id) })
    }

    @Test func pairsSetWriteAndRemove() throws {
        var a = Replica(0xA)
        let g = try Self.glyphs(&a)
        #expect(Kerning(a.state).isEmpty)
        #expect(try a.perform(SetKernPair(g["A"]!, g["V"]!, to: -80))?.label == "Kern pair")
        #expect(Kerning(a.state).value(g["A"]!, g["V"]!) == -80 && Kerning(a.state).value(g["V"]!, g["A"]!) == 0)
        try a.perform(SetKernPair(g["A"]!, g["V"]!, to: -60))
        #expect(Kerning(a.state).storedPairs.count == 1 && Kerning(a.state).value(g["A"]!, g["V"]!) == -60)
        #expect(try a.perform(SetKernPair(g["A"]!, g["V"]!, to: -60)) == nil)
        // A zero pair with no class is not inserted.
        #expect(try a.perform(SetKernPair(g["A"]!, g["O"]!, to: 0)) == nil)
        #expect(throws: FontEditError.invalidValue("kern value")) { try a.perform(SetKernPair(g["A"]!, g["V"]!, to: 40_000)) }
        #expect(throws: GlyphEditError.notAGlyph(WellKnown.settings)) { try a.perform(SetKernPair(WellKnown.settings, g["V"]!, to: 1)) }
        #expect(try a.perform(RemoveKernPairs([(g["A"]!, g["V"]!)]))?.label == "Remove kerning pair")
        #expect(Kerning(a.state).isEmpty)
        #expect(try a.perform(RemoveKernPairs([(g["A"]!, g["V"]!)])) == nil)
        #expect(RemoveKernPairs([(g["A"]!, g["V"]!), (g["V"]!, g["A"]!)]).label == "Remove 2 kerning pairs")
        a.undo()
        #expect(Kerning(a.state).value(g["A"]!, g["V"]!) == -60)
        // A pair whose glyph is removed reads as absent.
        try a.perform(RemoveGlyphs([g["V"]!]))
        #expect(Kerning(a.state).isEmpty)
    }

    @Test func classesCellsAndExceptions() throws {
        var a = Replica(0xA)
        let g = try Self.glyphs(&a)
        #expect(try a.perform(CreateKernClass("O", side: .right, members: [g["O"]!, g["C"]!]))?.label == "Create kerning class")
        try a.perform(CreateKernClass("T", side: .left, members: [g["T"]!]))
        var kerning = Kerning(a.state)
        let right = try #require(kerning.classes.first { $0.side == .right })
        let left = try #require(kerning.classes.first { $0.side == .left })
        #expect(right.members == [g["O"]!, g["C"]!] && right.name == "O" && kerning.kernClass(of: g["C"]!, side: .right)?.id == right.id)
        #expect(kerning.kernClass(of: g["C"]!, side: .left) == nil)
        #expect(try a.perform(SetClassKern(left.id, right.id, to: -50))?.label == "Kern classes")
        kerning = Kerning(a.state)
        #expect(kerning.value(g["T"]!, g["O"]!) == -50 && kerning.value(g["T"]!, g["C"]!) == -50 && kerning.classValue(g["T"]!, g["A"]!) == nil)
        try a.perform(SetClassKern(left.id, right.id, to: -55))
        #expect(Kerning(a.state).effectiveCells.map(\.value) == [-55])
        #expect(try a.perform(SetClassKern(left.id, right.id, to: -55)) == nil)
        #expect(throws: FontEditError.unknownElement(right.id)) { try a.perform(SetClassKern(right.id, left.id, to: 1)) }
        // An exception overrides the class; setting it to the class value removes it.
        try a.perform(SetKernPair(g["T"]!, g["C"]!, to: -20))
        kerning = Kerning(a.state)
        #expect(kerning.value(g["T"]!, g["C"]!) == -20 && kerning.exceptions.map(\.classValue) == [-55])
        try a.perform(SetKernPair(g["T"]!, g["C"]!, to: -55))
        #expect(Kerning(a.state).storedPairs.isEmpty && Kerning(a.state).value(g["T"]!, g["C"]!) == -55)
        #expect(try a.perform(SetKernPair(g["T"]!, g["C"]!, to: -55)) == nil)
        // A zero pair against a class is a real exception.
        try a.perform(SetKernPair(g["T"]!, g["O"]!, to: 0))
        #expect(Kerning(a.state).value(g["T"]!, g["O"]!) == 0 && Kerning(a.state).storedPairs.count == 1)
        // Cell 0 deletes it.
        try a.perform(SetClassKern(left.id, right.id, to: 0))
        #expect(Kerning(a.state).storedCells.isEmpty)
        #expect(try a.perform(SetClassKern(left.id, right.id, to: 0)) == nil)
    }

    @Test func classEditsMoveMembersAndRemoveCells() throws {
        var a = Replica(0xA)
        let g = try Self.glyphs(&a)
        try a.perform(CreateKernClass("O", side: .right, members: [g["O"]!]))
        try a.perform(CreateKernClass("round", side: .right, members: [g["C"]!]))
        try a.perform(CreateKernClass("T", side: .left, members: [g["T"]!]))
        var kerning = Kerning(a.state)
        let o = kerning.classes[0].id, round = kerning.classes[1].id, t = kerning.classes[2].id
        // Adding C to O moves it out of "round".
        #expect(try a.perform(EditKernClass(o, .addMembers([g["C"]!, g["O"]!])))?.label == "Add to kerning class")
        kerning = Kerning(a.state)
        #expect(kerning.kernClass(o)?.members == [g["O"]!, g["C"]!] && kerning.kernClass(round)?.members == [])
        #expect(try a.perform(EditKernClass(o, .addMembers([g["C"]!]))) == nil)
        #expect(try a.perform(EditKernClass(o, .rename("O2")))?.label == "Rename kerning class")
        #expect(Kerning(a.state).kernClass(o)?.name == "O2")
        #expect(throws: GlyphEditError.invalidName("a b")) { try a.perform(EditKernClass(o, .rename("a b"))) }
        #expect(throws: GlyphEditError.invalidName("")) { try a.perform(CreateKernClass("", side: .left)) }
        #expect(throws: GlyphEditError.notAGlyph(WellKnown.settings)) { try a.perform(EditKernClass(o, .addMembers([WellKnown.settings]))) }
        #expect(try a.perform(EditKernClass(o, .removeMembers([g["C"]!])))?.label == "Remove from kerning class")
        #expect(try a.perform(EditKernClass(o, .removeMembers([g["C"]!]))) == nil)
        try a.perform(SetClassKern(t, o, to: -30))
        #expect(try a.perform(EditKernClass(o, .remove))?.label == "Remove kerning class")
        kerning = Kerning(a.state)
        #expect(kerning.kernClass(o) == nil && kerning.storedCells.isEmpty)
        #expect(throws: FontEditError.unknownElement(o)) { try a.perform(EditKernClass(o, .remove)) }
        // Remove all kerning.
        try a.perform(SetKernPair(g["A"]!, g["V"]!, to: -70))
        try a.perform(SetClassKern(t, round, to: -10))
        #expect(try a.perform(RemoveAllKerning())?.label == "Remove all kerning")
        #expect(Kerning(a.state).isEmpty && !Kerning(a.state).classes.isEmpty)
        #expect(try a.perform(RemoveAllKerning()) == nil)
    }

    @Test func mergeClassesAndAutoKern() throws {
        var a = Replica(0xA)
        let g = try Self.glyphs(&a)
        try a.perform(CreateKernClass("O", side: .right, members: [g["O"]!]))
        try a.perform(CreateKernClass("O", side: .right, members: [g["C"]!, g["o"]!]))
        try a.perform(CreateKernClass("T", side: .left, members: [g["T"]!]))
        try a.perform(CreateKernClass("A", side: .left, members: [g["A"]!]))
        var kerning = Kerning(a.state)
        let older = kerning.classes[0].id, newer = kerning.classes[1].id, t = kerning.classes[2].id, left = kerning.classes[3].id
        #expect(kerning.classes.map(\.name) == ["O", "O_2", "T", "A"])
        #expect(kerning.sameNamedClasses.map { $0.map(\.id) } == [[older, newer]])
        try a.perform(SetClassKern(t, older, to: -40))
        try a.perform(SetClassKern(t, newer, to: -60))
        try a.perform(SetClassKern(left, newer, to: -25))
        #expect(try a.perform(MergeKernClasses(keeping: older, merging: newer))?.label == "Merge classes")
        kerning = Kerning(a.state)
        #expect(kerning.classes.count == 3 && kerning.kernClass(older)?.members == [g["O"]!, g["C"]!, g["o"]!])
        #expect(kerning.value(g["T"]!, g["C"]!) == -40 && kerning.value(g["A"]!, g["o"]!) == -25)
        #expect(throws: FontEditError.unknownElement(newer)) { try a.perform(MergeKernClasses(keeping: older, merging: newer)) }
        #expect(throws: FontEditError.unknownElement(newer)) { try a.perform(MergeKernClasses(keeping: newer, merging: older)) }
        #expect(throws: FontEditError.unknownElement(t)) { try a.perform(MergeKernClasses(keeping: older, merging: t)) }
        let auto = ApplyAutoKern([(g["A"]!, g["V"]!, -79.6), (g["T"]!, g["o"]!, -40), (g["A"]!, g["V"]!, -10)])
        #expect(auto.label == "Auto kern 3 cells")
        try a.perform(auto)
        kerning = Kerning(a.state)
        // T/o equals its class value: no redundant pair; A/V rounded; the repeat is ignored.
        #expect(kerning.value(g["A"]!, g["V"]!) == -80 && kerning.storedPairs.count == 1)
    }

    @Test func normalizationsOnStoredValues() throws {
        var a = Replica(0xA)
        let g = try Self.glyphs(&a)
        func ref(_ glyph: OpID) -> Wiretuner_Doc_V1_NodeRef { KerningEditing.glyphRef(glyph) }
        try a.perform(OpsCommand("Older client", ops: [
            Ops.elementInsert(WellKnown.settings, FontFields.pairs, positions: [[0x80], [0x81], [0x82]], values: FontFields.fontValues {
                var first = Wiretuner_Doc_V1_KernPair()
                first.left = ref(g["A"]!)
                first.right = ref(g["V"]!)
                first.value = -10
                var second = first
                second.value = .nan
                var dangling = first
                dangling.left = ref(OpID(counter: 999, replica: 3))
                $0.pairs = [first, second, dangling]
            }),
            Ops.elementInsert(WellKnown.settings, FontFields.classes, positions: [[0x80]], values: FontFields.fontValues {
                var unsided = Wiretuner_Doc_V1_KernClass()
                unsided.name = "X"
                $0.classes = [unsided]
            }),
        ]))
        let kerning = Kerning(a.state)
        // Duplicate pairs: the greater element id wins; its NaN reads as 0.
        #expect(kerning.storedPairs.count == 2 && kerning.effectivePairs.count == 1 && kerning.duplicatePairs.count == 1)
        #expect(kerning.value(g["A"]!, g["V"]!) == 0 && kerning.classes[0].side == .left)
        // The next set writes the winner and deletes the duplicate.
        try a.perform(SetKernPair(g["A"]!, g["V"]!, to: -30))
        #expect(Kerning(a.state).storedPairs.count == 1 && Kerning(a.state).value(g["A"]!, g["V"]!) == -30)
    }
}
