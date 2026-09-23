import Foundation
import Testing
import WTCRDT
@testable import WTModel
import WTProto

/// Edges of the undo stack's rebase (UndoRebase.swift) that whole-document tests do not reach.
@Suite struct RemapTests {
    static func id(_ counter: UInt64) -> OpID { OpID(counter: counter, replica: 7) }

    @Test func reinsertedCharactersWithoutATextMapToNothing() {
        #expect(Remap.originals(of: [Self.id(1)], in: nil).isEmpty)
        #expect(Remap.originals(of: [], in: TextSequence()).isEmpty)
        let remap = Remap(reverted: .assembled([]), reversal: .assembled([.textInserted(node: Self.id(1), text: Fixture.text, chars: [Self.id(9)])]),
                          state: EngineState())
        #expect(remap.isEmpty)
    }

    @Test func stepsOfOtherTargetsAreLeftAlone() {
        let node = Self.id(1)
        let remap = Remap(
            reverted: .assembled([.register(node: node, path: Fixture.name, prior: Register(value: [1], op: Self.id(2)), wrote: Self.id(3))]),
            reversal: .assembled([.register(node: node, path: Fixture.name, prior: Register(value: [2], op: Self.id(3)), wrote: Self.id(4))]),
            state: EngineState())
        #expect(!remap.isEmpty)
        let other = Inverse.assembled([
            .textInserted(node: node, text: Fixture.text, chars: [Self.id(5)]),
            .register(node: node, path: Fixture.name, prior: nil, wrote: Self.id(2)),
            .register(node: node, path: Fixture.note, prior: nil, wrote: Self.id(2)),
            .created(node: Self.id(8)),
        ])
        let rebased = remap.apply(to: other)
        #expect(rebased.steps[0] == other.steps[0] && rebased.steps[2] == other.steps[2] && rebased.steps[3] == other.steps[3])
        #expect(rebased.steps[1] == .register(node: node, path: Fixture.name, prior: nil, wrote: Self.id(4)))
    }

    struct Plain: Command {
        var label: String { "Plain" }
        func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
            builder.append(Ops.noop())
        }
    }

    @Test func aCommandIsItsOwnStepByDefault() async throws {
        #expect(Plain().coalescing == .none)
        let backend = MemoryBackend(core: DocumentCore(state: EngineState(), replica: 3, nextSeq: 10))
        let update = try await backend.perform(Plain(), recording: .init(limit: 5, now: Date()))
        #expect(update.change?.seq == 10 && update.replica == 3)
        #expect(await backend.core.nextSeq == 11)
    }
}
