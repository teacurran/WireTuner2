import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto

/// The assembled values equal the ones the engine records, field for field (InverseAssembly.swift).
@Suite struct InverseAssemblyTests {
    static let r: UInt64 = 3

    /// Inverses recorded by the engine carrying every value type InverseAssembly builds: a mark
    /// (prior formats), a deletion of formatted text with a paragraph (deleted characters with
    /// attributes and paragraph registers) and a set member (its field encoding).
    static func recorded() -> [Inverse] {
        var state = EngineState()
        let text = OpID(counter: 1, replica: r)
        let glyph = OpID(counter: 20, replica: r)
        state.apply(Fixture.change(r, seq: 1, start: 1, [
            Ops.create(parent: Fixture.layers, position: [0x80], props: Fixture.textBlock()),
            Ops.textInsert(text, Fixture.text, "ab\ncd"),
            mark(text, OpID(counter: 3, replica: r), size: 12),
            Ops.set(text, [paragraph(OpID(counter: 4, replica: r))], values: alignment()),
        ]))
        var glyphProps = Wiretuner_Doc_V1_NodeProps()
        glyphProps.glyph = Wiretuner_Doc_V1_GlyphProps()
        state.apply(Fixture.change(r, seq: 2, start: 20, [Ops.create(parent: Fixture.layers, position: [0x81], props: glyphProps)]))
        let marked = state.applyLocal(Fixture.change(r, seq: 3, start: 30, [mark(text, OpID(counter: 2, replica: r), through: OpID(counter: 6, replica: r), size: 20)]))
        let deleted = state.applyLocal(Fixture.change(r, seq: 4, start: 40, [Ops.textDelete(text, Fixture.text, first: OpID(counter: 2, replica: r), count: 5)]))
        var codepoints = Wiretuner_Doc_V1_NodeProps()
        codepoints.glyph.codepoints = [65]
        var add = Wiretuner_Doc_V1_SetAdd()
        add.node = glyph.proto
        add.set = RegisterPath([220, 3]).proto
        add.values = codepoints
        var op = Wiretuner_Doc_V1_Op()
        op.setAdd = add
        let member = state.applyLocal(Fixture.change(r, seq: 5, start: 50, [op]))
        return [marked, deleted, member]
    }

    static func paragraph(_ newline: OpID) -> RegisterPath {
        RegisterPath(segments: [.field(130), .field(2), .element(newline), .field(6), .field(1)])
    }

    static func alignment() -> Wiretuner_Doc_V1_NodeProps {
        var char = Wiretuner_Doc_V1_TextChar()
        char.paragraph.alignment = .left
        var props = Wiretuner_Doc_V1_NodeProps()
        props.text.text.chars = [char]
        return props
    }

    static func mark(_ node: OpID, _ first: OpID, through last: OpID? = nil, size: Double) -> Wiretuner_Doc_V1_Op {
        var mark = Wiretuner_Doc_V1_TextMark()
        mark.node = node.proto
        mark.text = Fixture.text.proto
        mark.start.char = Ops.elementID(first)
        mark.start.before = true
        mark.end.char = Ops.elementID(last ?? first)
        mark.value.size = size
        var op = Wiretuner_Doc_V1_Op()
        op.textMark = mark
        return op
    }

    /// `step` rebuilt from its public fields.
    static func rebuilt(_ step: Inverse.Step) -> Inverse.Step {
        switch step {
        case .textDeleted(let node, let text, let chars):
            .textDeleted(node: node, text: text, chars: chars.map {
                .assembled(id: $0.id, scalar: $0.scalar, attributes: $0.attributes,
                           paragraph: $0.paragraph.map { .assembled(suffix: $0.suffix, value: $0.value) })
            })
        case .textMarked(let node, let text, let mark, let key, let value, let prior):
            .textMarked(node: node, text: text, mark: mark, key: key, value: value,
                        prior: prior.map { .assembled(char: $0.char, value: $0.value) })
        case .memberAdded(let node, let set, let member, let tag, let wasPresent, let field):
            .memberAdded(node: node, set: set, member: member, tag: tag, wasPresent: wasPresent,
                         field: .assembled(number: field.number, type: field.type, typeName: field.typeName))
        default:
            step
        }
    }

    @Test func assembledValuesEqualRecordedOnes() {
        let inverses = Self.recorded()
        var kinds: Set<String> = []
        for inverse in inverses {
            #expect(!inverse.isEmpty)
            #expect(Inverse.assembled(inverse.steps.map(Self.rebuilt)) == inverse)
            for step in inverse.steps {
                switch step {
                case .textDeleted(_, _, let chars):
                    kinds.insert("deleted")
                    #expect(chars.contains { !$0.paragraph.isEmpty } && chars.contains { !$0.attributes.isEmpty })
                case .textMarked(_, _, _, _, _, let prior):
                    kinds.insert("marked")
                    #expect(prior.contains { $0.value != nil } && prior.contains { $0.value == nil })
                case .memberAdded:
                    kinds.insert("member")
                default:
                    break
                }
            }
        }
        #expect(kinds == ["deleted", "marked", "member"])
    }

    @Test func aJoinedInverseUndoesBothChanges() {
        var state = EngineState()
        let node = OpID(counter: 1, replica: Self.r)
        state.apply(Fixture.change(Self.r, seq: 1, start: 1, [Fixture.createLayer("A")]))
        let one = state.applyLocal(Fixture.change(Self.r, seq: 2, start: 2, [Fixture.rename(node, "B")]))
        let two = state.applyLocal(Fixture.change(Self.r, seq: 3, start: 3, [Fixture.rename(node, "C")]))
        let undo = state.undoChange(one.followed(by: two), replica: Self.r, seq: 4, startCounter: 4)!
        state.apply(undo)
        #expect(state.register(node, Fixture.name)?.value == Fixture.nameValue("A"))
    }
}
