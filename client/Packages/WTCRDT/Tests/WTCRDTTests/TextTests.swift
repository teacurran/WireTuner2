import Testing
@testable import WTCRDT
import WTProto

private func id(_ counter: UInt64, _ replica: UInt64 = 1) -> OpID { OpID(counter: counter, replica: replica) }

/// The Fugue sequence and Peritext marks (CRDT-005, CRDT-006) below the engine; the vectors under
/// crdt-conformance/vectors/text and /marks cover the merge behaviour in both engines.
@Suite struct TextSequenceTests {
    static func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }

    @Test func readsOutTheLiveCharactersInOrder() {
        var text = TextSequence()
        #expect(text.isEmpty && text.count == 0 && text.liveCount == 0 && text.string.isEmpty)
        let r1 = text.insert(Self.scalars("abc"), first: id(1), left: .zero, right: .zero)
        #expect(r1 == [id(1), id(2), id(3)])
        let r2 = text.insert(Self.scalars("X"), first: id(9), left: id(99), right: .zero)
        #expect(r2.isEmpty)
        let r3 = text.insert(Self.scalars("X"), first: id(9), left: .zero, right: id(99))
        #expect(r3.isEmpty)
        let r4 = text.insert(Self.scalars("ab"), first: id(1), left: .zero, right: .zero)
        #expect(r4.isEmpty)
        let r5 = text.delete(id(2), op: id(10, 2))
        #expect(r5)
        let r6 = text.delete(id(2), op: id(10, 1))
        #expect(!r6)
        #expect(text.deletedOp(id(2)) == id(10, 2))
        let r7 = text.delete(id(2), op: id(11, 1))
        #expect(!r7)
        #expect(text.deletedOp(id(2)) == id(11, 1))
        let r8 = text.delete(id(42), op: id(12))
        #expect(!r8)
        #expect(text.string == "ac" && text.count == 3 && text.liveCount == 2 && !text.isEmpty)
        #expect(text.order == [id(1), id(2), id(3)] && text.liveChars == [id(1), id(3)])
        #expect(text.contains(id(2)) && !text.contains(id(4)))
        #expect(text.codepoint(id(3)) == 0x63 && text.codepoint(id(4)) == nil)
        #expect(text.isDeleted(id(2)) && !text.isDeleted(id(1)) && !text.isDeleted(id(4)))
        #expect(text.deletedOp(id(1)) == nil && text.deletedOp(id(4)) == nil)
        #expect(text.origins(id(2))! == (left: id(1), right: .zero))
        #expect(text.origins(id(4)) == nil)
    }

    @Test func mapsCharacterIdsToOffsetsAndBack() {
        var text = TextSequence()
        #expect(text.insertionOrigins(at: 0) == (left: .zero, right: .zero))
        text.insert(Self.scalars("abcd"), first: id(1), left: .zero, right: .zero)
        text.delete(id(2), op: id(9))
        #expect(text.offset(of: id(1)) == 0 && text.offset(of: id(2)) == 1 && text.offset(of: id(3)) == 1)
        #expect(text.offset(of: id(99)) == nil)
        #expect(text.char(at: 0) == id(1) && text.char(at: 1) == id(3) && text.char(at: 2) == id(4))
        #expect(text.char(at: 3) == nil && text.char(at: -1) == nil)
        #expect(text.successor(of: id(1)) == id(2) && text.successor(of: id(4)) == .zero && text.successor(of: id(99)) == .zero)
        #expect(text.insertionOrigins(at: 0) == (left: .zero, right: id(1)))
        #expect(text.insertionOrigins(at: 1) == (left: id(1), right: id(2)))
        #expect(text.insertionOrigins(at: 3) == (left: id(4), right: .zero))
    }

    @Test func splitsBlocksAndKeepsTheOrderAcrossThem() {
        var text = TextSequence()
        let count = TextSequence.blockLimit * 3
        text.insert(Array(repeating: 0x61, count: count), first: id(1), left: .zero, right: .zero)
        // Before the first character, in the middle, and at the end.
        text.insert([0x41], first: id(10_001, 2), left: .zero, right: id(1))
        text.insert([0x42], first: id(10_002, 2), left: id(700), right: id(701))
        text.insert([0x43], first: id(10_003, 2), left: id(UInt64(count)), right: .zero)
        for index in stride(from: 1, through: count, by: 2) {
            text.delete(id(UInt64(index)), op: id(20_000))
        }
        #expect(text.count == count + 3)
        #expect(text.char(at: 0) == id(10_001, 2))
        #expect(text.offset(of: id(10_002, 2)) == 1 + 350)
        #expect(text.char(at: text.liveCount - 1) == id(10_003, 2))
        #expect(text.successor(of: id(512)) == id(513))
        #expect(text.string.count == text.liveCount)
    }

    @Test func concurrentSiblingsGoAfterEarlierSiblingsSubtrees() {
        // Two runs typed at the same place (right children of X), the later run with the smaller id.
        var text = TextSequence()
        text.insert(Self.scalars("XY"), first: id(1, 7), left: .zero, right: .zero)
        text.insert(Self.scalars("bb"), first: id(5, 2), left: id(1, 7), right: .zero)
        text.insert(Self.scalars("aa"), first: id(5, 1), left: id(1, 7), right: .zero)
        text.insert(Self.scalars("c"), first: id(9, 3), left: id(1, 7), right: .zero)
        #expect(text.string == "XYaabbc")
        // Between X and Y three times: left children of Y, ordered by id.
        text.insert(Self.scalars("p"), first: id(20, 1), left: id(1, 7), right: id(2, 7))
        text.insert(Self.scalars("q"), first: id(21, 1), left: id(1, 7), right: id(2, 7))
        text.insert(Self.scalars("o"), first: id(3, 9), left: id(1, 7), right: id(2, 7))
        #expect(text.string == "XopqYaabbc")
    }

    @Test func rangesLongerThanTheTextAreMatchedAgainstIt() {
        var text = TextSequence()
        text.insert(Self.scalars("abc"), first: id(5), left: .zero, right: .zero)
        #expect(text.ids(from: id(4), count: 3) == [id(5), id(6)])
        #expect(text.ids(from: id(6), count: 100) == [id(6), id(7)])
        #expect(text.ids(from: id(6, 2), count: 100).isEmpty)
        #expect(text.ids(from: OpID(counter: UInt64.max - 1, replica: 1), count: .max).isEmpty)
    }

    @Test func restoresFromCharactersInAnyOrderAndDropsOrphans() {
        var original = TextSequence()
        original.insert(Self.scalars("ab"), first: id(1), left: .zero, right: .zero)
        original.insert(Self.scalars("x"), first: id(5, 2), left: id(1), right: id(2))
        original.delete(id(2), op: id(9))
        let chars = original.order.map { char in
            RestoredChar(id: char, scalar: original.codepoint(char)!, left: original.origins(char)!.left,
                         right: original.origins(char)!.right, deleted: original.deletedOp(char))
        }
        let orphan = RestoredChar(id: id(30), scalar: 0x7A, left: id(29), right: .zero, deleted: nil)
        let invalid = RestoredChar(id: id(31), scalar: 0xD800, left: id(2), right: .zero, deleted: nil)
        let restored = TextSequence.restore(chars: [invalid, orphan] + chars.reversed() + [chars[0]], marks: [])
        #expect(restored.order == original.order + [id(31)])
        #expect(restored.string == "ax\u{FFFD}")
        #expect(!restored.contains(id(30)))
    }
}

@Suite struct MarkTests {
    static func text() -> TextSequence {
        var text = TextSequence()
        text.insert("abcdef".unicodeScalars.map(\.value), first: id(1), left: .zero, right: .zero)
        return text
    }

    static let bold = MarkKey(field: 30)

    static func mark(_ counter: UInt64, _ start: Anchor, _ end: Anchor, _ value: [UInt8] = [0xF0, 0x01, 0x01]) -> TextMark {
        TextMark(id: id(counter, 2), start: start, end: end, value: value, key: MarkValue.key(value, featureField: 21))
    }

    @Test func coverageFollowsTheAnchors() {
        let index = Self.text().orderIndex()
        func covered(_ start: Anchor, _ end: Anchor) -> ClosedRange<Int>? {
            TextSequence.covered(Self.mark(9, start, end), index, count: 6)
        }
        #expect(covered(.start, .end) == 0...5)
        #expect(covered(Anchor(char: id(2), before: true), Anchor(char: id(4), before: true)) == 1...2)
        #expect(covered(Anchor(char: id(2), before: false), Anchor(char: id(4), before: false)) == 2...3)
        #expect(covered(Anchor(char: .zero, before: false), .end) == nil)
        #expect(covered(.start, Anchor(char: .zero, before: true)) == nil)
        #expect(covered(Anchor(char: id(5), before: true), Anchor(char: id(2), before: true)) == nil)
    }

    @Test func marksRecordOnceWithKnownAnchors() {
        var text = Self.text()
        let r9 = text.mark(Self.mark(9, .start, .end))
        #expect(r9)
        let r10 = text.mark(Self.mark(9, .start, .end))
        #expect(!r10)
        let unknownStart = text.mark(Self.mark(10, Anchor(char: id(99), before: true), .end))
        let unknownEnd = text.mark(Self.mark(11, .start, Anchor(char: id(99), before: true)))
        #expect(!unknownStart && !unknownEnd)
        #expect(text.sortedMarks.map(\.id) == [id(9, 2)])
        #expect(Anchor.start.description == "before 0:0" && Anchor.end.description == "after 0:0")
    }

    @Test func theGreatestMarkOfAnAttributeWinsAndClearedValuesAreLeftOut() {
        var text = Self.text()
        text.mark(Self.mark(9, .start, .end))
        text.mark(Self.mark(10, Anchor(char: id(3), before: true), Anchor(char: id(4), before: false), [0xF0, 0x01, 0x00]))
        text.mark(Self.mark(11, Anchor(char: id(6), before: true), .end, [0x08]))  // no attribute: never parses a value
        text.mark(TextMark(id: id(12, 2), start: .start, end: .end, value: [], key: nil))
        text.delete(id(1), op: id(20))
        let runs = text.runs
        #expect(runs.map(\.start) == [0, 1, 3])
        #expect(runs.map(\.length) == [1, 2, 2])
        #expect(runs[0].attributes.map(\.mark) == [id(9, 2)] && runs[1].attributes.isEmpty)
        let winners = text.winners(of: Self.bold, for: [id(2), id(3), id(99)])
        #expect(winners[id(2)]?.id == id(9, 2) && winners[id(3)]?.id == id(10, 2) && winners[id(99)] == nil)
        let attributes = text.attributes(of: [id(3), id(99)])
        #expect(attributes[id(3)] == [] && attributes[id(99)] == nil)
        #expect(TextSequence().runs.isEmpty)
    }

    @Test func markValuesNameTheirAttribute() {
        #expect(MarkValue.key([0xF0, 0x01, 0x01], featureField: 21) == MarkKey(field: 30))
        #expect(MarkValue.key([], featureField: 21) == nil)
        #expect(MarkValue.key([0x08], featureField: 21) == nil)
        let liga: [UInt8] = [0xAA, 0x01, 0x08, 0x0A, 0x04, 0x6C, 0x69, 0x67, 0x61, 0x10, 0x01]
        let key = MarkValue.key(liga, featureField: 21)!
        #expect(key == MarkKey(field: 21, tag: [0x0A, 0x04, 0x6C, 0x69, 0x67, 0x61]))
        #expect(MarkValue.key([0xAA, 0x01, 0x00], featureField: 21) == MarkKey(field: 21, tag: []))
        #expect(MarkValue.key(liga, featureField: nil) == MarkKey(field: 21))
        #expect(key.description == "21/0a046c696761" && MarkKey(field: 3).description == "3")
        #expect(MarkKey(field: 3) < MarkKey(field: 21) && MarkKey(field: 21, tag: [1]) < MarkKey(field: 21, tag: [2]))
        #expect(!MarkValue.isCleared(liga, key: key))
        #expect(MarkValue.isCleared(MarkValue.cleared(liga, key: key), key: key))
        #expect(!MarkValue.isCleared([0x08], key: key))
        #expect(MarkValue.cleared([0x19, 1, 2, 3, 4, 5, 6, 7, 8], key: MarkKey(field: 3)) == [0x19, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(MarkValue.cleared([0x1D, 1, 2, 3, 4], key: MarkKey(field: 3)) == [0x1D, 0, 0, 0, 0])
        #expect(MarkValue.cleared([0xF0, 0x01, 0x01], key: Self.bold) == [0xF0, 0x01, 0x00])
        #expect(MarkValue.cleared([0x08], key: Self.bold).isEmpty)
    }
}

/// Text through the engine: ops on the test kind's TEXT field (1000.9).
@Suite struct TextEngineTests {
    @Test func textOpsInsertDeleteAndMarkThroughTheEngine() {
        var engine = Scenario.engine(Scenario.change(7, 2, 2, Scenario.insert("h\u{e9}llo")))
        engine.apply(Scenario.change(7, 3, 7, "text_delete { \(Scenario.nodeText) \(Scenario.textPath) ranges { first { counter: 3 replica: 7 } count: 1 } }",
                                     Scenario.mark(OpID(counter: 2, replica: 7), true, nil, false, "bold: true")))
        let text = engine.text(Scenario.node, Scenario.text)!
        #expect(text.string == "hllo")
        #expect(text.runs.count == 1 && text.runs[0].attributes.count == 1)
        #expect(engine.text(Scenario.node, RegisterPath([1000, 2])) == nil)
        #expect(engine.clock.max == 8)
        #expect(engine.store.replicaState(7) == ReplicaState(seq: 3, ackedServerSeq: 0))
        #expect(engine.store.replicaState(8) == nil)
        #expect(engine.store.replicas.map(\.replica) == [7])
    }

    @Test func registerValuesAreReadThroughTheTable() {
        let engine = Scenario.engine()
        let values = try! Wiretuner_Doc_V1_NodeProps(serializedBytes: ConformanceRunner.docChange(
            try! Wiretuner_Conformance_V1_Change(textFormatString: #"ops { set { values { test { label: "x" } } } }"#)).ops[0].set.values.serializedBytes() as [UInt8])
        #expect(engine.registerValue(in: values, kind: 1000, path: Scenario.label) == [0x12, 0x01, 0x78])
        #expect(engine.registerValue(in: values, kind: 1000, path: RegisterPath([1000, 99])) == nil)
        #expect(engine.registerValue(in: Wiretuner_Doc_V1_NodeProps(), kind: 1000, path: Scenario.label) == nil)
    }
}
