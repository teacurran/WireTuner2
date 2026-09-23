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
        let remap = Remap(reversal: Inverse(steps: [.textInserted(node: Self.id(1), text: Fixture.text, chars: [Self.id(9)])]),
                          state: EngineState())
        #expect(remap.isEmpty)
        // Steps other than typing, and typing into a field the reversal did not touch, stay as they are.
        let steps: [Inverse.Step] = [.created(node: Self.id(8)), .textInserted(node: Self.id(1), text: Fixture.text, chars: [Self.id(5)])]
        #expect(remap.apply(to: Inverse(steps: steps)).steps == steps)
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
