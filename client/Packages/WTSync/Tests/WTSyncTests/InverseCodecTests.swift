import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

@Suite struct InverseCodecTests {
    static let r: UInt64 = 3
    static func id(_ counter: UInt64) -> OpID { OpID(counter: counter, replica: r) }

    /// Inverses the engine records for every step kind.
    static func recorded() -> [Inverse] {
        var state = EngineState()
        let text = id(1), page = id(20), glyph = id(30), layer = id(40)
        let guides = RegisterPath([3, 7])
        var pageProps = Wiretuner_Doc_V1_NodeProps()
        pageProps.page = Wiretuner_Doc_V1_PageProps()
        var glyphProps = Wiretuner_Doc_V1_NodeProps()
        glyphProps.glyph = Wiretuner_Doc_V1_GlyphProps()
        var codepoints = Wiretuner_Doc_V1_NodeProps()
        codepoints.glyph.codepoints = [65]
        let codepointSet = RegisterPath([220, 3])
        state.apply(Fixture.change(r, seq: 1, start: 1, [
            Ops.create(parent: Fixture.layers, position: [0x80], props: Fixture.textBlock()),
            Ops.textInsert(text, Fixture.text, "ab\ncd"),
            mark(text, id(3), id(3), size: 12),
            Ops.set(text, [RegisterPath(segments: [.field(130), .field(2), .element(id(4)), .field(6), .field(1)])], values: alignment()),
        ]))
        state.apply(Fixture.change(r, seq: 2, start: 20, [Ops.create(parent: Fixture.layers, position: [0x81], props: pageProps)]))
        state.apply(Fixture.change(r, seq: 3, start: 30, [Ops.create(parent: Fixture.layers, position: [0x82], props: glyphProps)]))
        state.apply(Fixture.change(r, seq: 4, start: 40, [Fixture.createLayer("L", position: [0x83])]))
        var seq: UInt64 = 5
        var counter: UInt64 = 100
        func local(_ ops: [Wiretuner_Doc_V1_Op]) -> Inverse {
            let change = Fixture.change(r, seq: seq, start: counter, ops)
            seq += 1
            counter += ops.reduce(0) { $0 + EngineState.counters($1) }
            return state.applyLocal(change)
        }
        let element = guides.element(id(counter))
        return [
            local([Ops.elementInsert(page, guides, positions: [[0x80]])]),
            local([Fixture.createLayer("N", position: [0x84]), Fixture.rename(layer, "M"),
                   Ops.move(layer, parent: Fixture.layers, position: [0x90]), Ops.setDeleted(layer)]),
            local([Ops.elementMove(page, element, position: [0x90]), Ops.elementDelete(page, [element])]),
            local([Ops.setAdd(glyph, codepointSet, values: codepoints)]),
            local([Ops.setRemove(glyph, codepointSet, values: codepoints)]),
            local([Ops.textInsert(text, Fixture.text, "z", left: id(6))]),
            local([mark(text, id(2), id(6), size: 20)]),
            local([Ops.textDelete(text, Fixture.text, first: id(2), count: 5)]),
        ]
    }

    static func alignment() -> Wiretuner_Doc_V1_NodeProps {
        var char = Wiretuner_Doc_V1_TextChar()
        char.paragraph.alignment = .left
        var props = Wiretuner_Doc_V1_NodeProps()
        props.text.text.chars = [char]
        return props
    }

    static func mark(_ node: OpID, _ first: OpID, _ last: OpID, size: Double) -> Wiretuner_Doc_V1_Op {
        var mark = Wiretuner_Doc_V1_TextMark()
        mark.node = node.proto
        mark.text = Fixture.text.proto
        mark.start.char = Ops.elementID(first)
        mark.start.before = true
        mark.end.char = Ops.elementID(last)
        mark.value.size = size
        var op = Wiretuner_Doc_V1_Op()
        op.textMark = mark
        return op
    }

    static func tag(_ step: Inverse.Step) -> String {
        String(String(describing: step).prefix { $0 != "(" })
    }

    @Test func everyStepKindRoundTrips() throws {
        let inverses = Self.recorded()
        let kinds = Set(inverses.flatMap { $0.steps.map(Self.tag) })
        #expect(kinds == ["created", "register", "placement", "deleted", "elementInserted", "elementPosition", "elementDeleted",
                          "memberAdded", "memberRemoved", "textInserted", "textDeleted", "textMarked"])
        for inverse in inverses {
            #expect(try InverseCodec.decode(InverseCodec.encode(inverse)) == inverse)
        }
        #expect(try InverseCodec.decode(InverseCodec.encode(.assembled([]))).isEmpty)
    }

    @Test func priorFlagsAndMessageMembersRoundTrip() throws {
        let node = Self.id(9)
        let path = RegisterPath(segments: [.field(3), .field(7), .element(Self.id(10))])
        let inverse = Inverse.assembled([
            .deleted(node: node, prior: Stamped(true, Self.id(5)), wrote: Self.id(6)),
            .elementDeleted(node: node, element: path, prior: Stamped(false, Self.id(7)), wrote: Self.id(8)),
            .memberAdded(node: node, set: RegisterPath([1, 2]), member: [1, 2, 3], tag: Self.id(11), wasPresent: true,
                         field: .assembled(number: 4, type: "message", typeName: "wiretuner.doc.v1.NodeRef")),
            .memberRemoved(node: node, set: RegisterPath([1, 2]), member: [9], field: .assembled(number: 4, type: "uint32", typeName: nil)),
        ])
        #expect(try InverseCodec.decode(InverseCodec.encode(inverse)) == inverse)
    }

    @Test func malformedBytesAreRefused() {
        let valid = InverseCodec.encode(Self.recorded()[0])
        let cases: [[UInt8]] = [
            [],                                   // truncated
            [2, 0],                               // unknown version
            [1, 1, 99],                           // unknown step
            valid + [0],                          // trailing bytes
            Array(valid.dropLast()),              // truncated step
            [1, 5],                               // count past the end
            [1, 1, 4, 1, 1, 1, 9],                // deleted: bad presence byte
            [1, 1, 1] + Array(repeating: 0xFF, count: 11) + [1],   // varint too long
            [1, 1, 5, 1, 1, 1, 7],                // bad path segment
            [1, 1, 5, 1, 1, 0],                   // empty path
            [1, 1, 9, 1, 1, 1, 0, 1, 0, 0xFF, 0, 1, 0xFF, 0],      // member field: bad string
            [1, 1, 10, 1, 1, 1, 0, 0x80, 0x80, 0x80, 0x80, 0x10, 0],  // field number out of range
        ]
        for bytes in cases {
            #expect(throws: InverseCodec.Failure.self, "\(bytes)") { try InverseCodec.decode(bytes) }
        }
    }
}
