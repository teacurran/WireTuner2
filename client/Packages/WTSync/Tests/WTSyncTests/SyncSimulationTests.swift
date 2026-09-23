import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// SYNC-003's done-when: with packet loss and reordering, in both modes, the log holds every
/// local change exactly once and in seq order, and the client's merged state is the log's.
@Suite(.timeLimit(.minutes(3))) struct SyncSimulationTests {
    /// A deterministic generator (SplitMix64).
    struct Random {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }

        mutating func chance(_ percent: UInt64) -> Bool { next() % 100 < percent }
    }

    func run(gateway: Bool, seed: UInt64) async throws {
        let server = FakeSyncServer()
        let harness = try await Harness(server: server, options: fastOptions(gateway: gateway))
        await harness.client.start()
        var random = Random(state: seed)
        var remoteSeq: UInt64 = 0
        var local = 0
        for round in 0..<30 {
            // Faults for the next pushes: delays (reordering), lost responses, one-shot gaps.
            let next = await harness.store.nextSeq
            var delays: [UInt64: Duration] = [:]
            var lost: Set<UInt64> = []
            var gaps: [UInt64: SyncCallError] = [:]
            for seq in next..<(next + 6) {
                if random.chance(15) { delays[seq] = .milliseconds(Int64(random.next() % 40)) }
                if random.chance(5) { lost.insert(seq) }
                if random.chance(5) { gaps[seq] = SyncCallError(code: SyncCallError.aborted, reason: .seqGap, message: "raced") }
            }
            let dropNext = random.chance(10)
            await server.update { [delays, lost, gaps] server in
                server.delay.merge(delays) { $1 }
                server.loseResponse.formUnion(lost)
                server.reject.merge(gaps) { $1 }
                if dropNext { server.dropLive.insert(server.head + 2) }
            }
            try await harness.edit(Int(random.next() % 5) + 1, from: local)
            local += 6
            if random.chance(50) {
                remoteSeq += 1
                try await server.inject(remoteChange(seq: remoteSeq))
            }
            if random.chance(8) {
                await server.disconnect()
            }
            if round % 10 == 9 {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await harness.expectConverged()
        #expect(!harness.events.all.contains { if case .replicaRotated = $0 { true } else { false } })
        try await harness.waitFor(.saved)
        try await harness.stop()
    }

    @Test(arguments: [1, 2, 3] as [UInt64]) func pipelinedPushesSurviveLossAndReordering(seed: UInt64) async throws {
        try await run(gateway: false, seed: seed)
    }

    @Test(arguments: [4, 5, 6] as [UInt64]) func batchedPushesSurviveLossAndReordering(seed: UInt64) async throws {
        try await run(gateway: true, seed: seed)
    }
}
