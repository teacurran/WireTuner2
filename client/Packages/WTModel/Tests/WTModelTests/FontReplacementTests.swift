import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTText

/// DOC-025: `ReplaceFont` over every text node's marks (font-substitution.adoc).
@Suite struct FontReplacementTests {
    static func family(_ name: String) -> Wiretuner_Doc_V1_TextMarkValue {
        var value = Wiretuner_Doc_V1_TextMarkValue()
        value.fontFamily = name
        return value
    }

    static func style(_ name: String) -> Wiretuner_Doc_V1_TextMarkValue {
        var value = Wiretuner_Doc_V1_TextMarkValue()
        value.fontStyle = name
        return value
    }

    static func kerning(_ amount: Double) -> Wiretuner_Doc_V1_TextMarkValue {
        var value = Wiretuner_Doc_V1_TextMarkValue()
        value.kerning = amount
        return value
    }

    @discardableResult
    static func block(_ replica: inout Replica, _ text: String, marks: [Wiretuner_Doc_V1_TextMarkValue], at x: Double = 0) throws -> OpID {
        try replica.perform(CreateTextBlock(.point(Point(x: x, y: 0)), text: text, marks: marks))!.createdObjects[0]
    }

    /// The faces of every live character of `node`, in order.
    static func faces(_ state: EngineState, _ node: OpID) -> [FaceName?] {
        guard let text = state.store.text(node, TextFields.text) else { return [] }
        return text.runs.flatMap { run in Array(repeating: ReplaceFont.face(of: run.attributes), count: run.length) }
    }

    @Test func replacesFamilyAndStyleKeepingOtherMarks() throws {
        var a = Replica(0xA)
        let node = try Self.block(&a, "Hello", marks: [Self.family("Missing Sans"), Self.style("Bold"), Self.kerning(20)])
        let other = try Self.block(&a, "Keep", marks: [Self.family("Georgia")], at: 100)
        let command = ReplaceFont(old: FaceName(family: "Missing Sans"), new: FaceName(family: "Helvetica", style: "Oblique"))
        #expect(command.label == "Replace font \(FaceName(family: "Missing Sans")) with \(FaceName(family: "Helvetica", style: "Oblique"))")
        let change = try #require(try a.perform(command))
        #expect(change.ops.count == 2)
        #expect(Self.faces(a.state, node).allSatisfy { $0 == FaceName(family: "Helvetica", style: "Oblique") })
        #expect(Self.faces(a.state, other).allSatisfy { $0 == FaceName(family: "Georgia") })
        let text = try #require(a.state.store.text(node, TextFields.text))
        let kept = text.runs.allSatisfy { run in
            run.attributes.contains { (try? Wiretuner_Doc_V1_TextMarkValue(serializedBytes: $0.value))?.kerning == 20 }
        }
        #expect(kept)
        // Undo restores the old face.
        a.undo()
        #expect(Self.faces(a.state, node).allSatisfy { $0 == FaceName(family: "Missing Sans", style: "Bold") })
        #expect(ReplaceFont([]).label == "Replace 0 fonts")
        #expect(try a.perform(ReplaceFont([])) == nil)
        #expect(ReplaceFont([.init(old: FaceName(family: "A"), new: FaceName(family: "B")), .init(old: FaceName(family: "C"), new: FaceName(family: "D"))]).label
            == "Replace 2 fonts")
    }

    @Test func matchingAndFaceReading() {
        #expect(ReplaceFont.matches(FaceName(family: "A", style: "Bold"), FaceName(family: "A")))
        #expect(ReplaceFont.matches(FaceName(family: "A", style: "Bold"), FaceName(family: "A", style: "bold")))
        #expect(!ReplaceFont.matches(FaceName(family: "A"), FaceName(family: "A", style: "Bold")))
        #expect(!ReplaceFont.matches(FaceName(family: "B"), FaceName(family: "A")))
        #expect(ReplaceFont.face(of: []) == nil)
    }

    @Test func mergeReplaceVersusReplaceLaterWinsPerSpan() throws {
        var pair = Pair()
        let node = try Self.block(&pair.a, "Shared text", marks: [Self.family("Old")])
        pair.sync()
        let a = try #require(try pair.a.perform(ReplaceFont(old: FaceName(family: "Old"), new: FaceName(family: "Georgia"))))
        let b = try #require(try pair.b.perform(ReplaceFont(old: FaceName(family: "Old"), new: FaceName(family: "Times"))))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let winner = PageFixture.later(a, b) ? "Georgia" : "Times"
        #expect(Self.faces(pair.a.state, node).allSatisfy { $0?.family == winner })
    }

    @Test func mergeReplaceVersusTypingInsideTheSpan() throws {
        var pair = Pair()
        let node = try Self.block(&pair.a, "Hello", marks: [Self.family("Old")])
        pair.sync()
        try pair.a.perform(ReplaceFont(old: FaceName(family: "Old"), new: FaceName(family: "Georgia")))
        let chars = try #require(pair.b.state.store.text(node, TextFields.text)).liveChars
        try pair.b.perform(InsertText(node: node, text: "XYZ", at: Anchor(char: chars[1], before: false)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let faces = Self.faces(pair.a.state, node)
        #expect(faces.count == 8 && faces.allSatisfy { $0?.family == "Georgia" })
    }

    @Test func undoLeavesRunsOthersChangedSince() throws {
        var pair = Pair()
        let node = try Self.block(&pair.a, "Hello", marks: [Self.family("Old")])
        pair.sync()
        try pair.a.perform(ReplaceFont(old: FaceName(family: "Old"), new: FaceName(family: "Georgia")))
        pair.sync()
        // B changes the first two characters afterwards; A's undo leaves them.
        let chars = try #require(pair.b.state.store.text(node, TextFields.text)).liveChars
        try pair.b.perform(ApplyMark(node: node, from: Anchor(char: chars[0], before: true), to: Anchor(char: chars[1], before: false),
                                     value: Self.family("Futura")))
        pair.sync()
        pair.a.undo()
        pair.sync()
        let faces = Self.faces(pair.a.state, node).map { $0?.family }
        #expect(faces.prefix(2).allSatisfy { $0 == "Futura" })
        #expect(faces.dropFirst(2).allSatisfy { $0 == "Old" })
    }

    @Test func replacesEveryRunOf200000CharactersQuickly() throws {
        var a = Replica(0xA)
        let chunk = String(repeating: "abcdefghij", count: 1_000)
        for index in 0..<20 {
            try Self.block(&a, chunk, marks: [Self.family(index.isMultiple(of: 2) ? "Old" : "Other")], at: Double(index) * 10)
        }
        let clock = ContinuousClock()
        let started = clock.now
        let change = try #require(try a.perform(ReplaceFont(old: FaceName(family: "Old"), new: FaceName(family: "Georgia"))))
        let elapsed = clock.now - started
        #expect(change.ops.count == 10)
        PerfBudget.expect(elapsed, within: .milliseconds(200), "replace font, 200,000 characters")
    }
}
