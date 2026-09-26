import CryptoKit
import Foundation
import Testing
import WTProto
@testable import WTSync

/// IMG-006's per-blob progress: every chunk of an upload and of a download is a step reported
/// through `BlobQueue.transfers()`, and `transfer(of:)` says how far a blob in flight has got.
@Suite(.timeLimit(.minutes(1))) struct BlobTransferTests {
    @Test func uploadsReportEveryChunk() async throws {
        var options = fastBlobOptions()
        options.chunkSize = 1_000
        let harness = try await BlobHarness(options: options)
        let transfers = Collector(harness.queue.transfers())
        let hash = try await harness.queue.add(fileAt: harness.file("picture", bytes: 3_500), mediaType: "image/png")
        #expect(harness.queue.transfer(of: hash) == nil, "queued, not going up yet")
        await harness.queue.setOnline(true)
        await harness.queue.start()
        try await eventually("uploaded") { harness.events.all.contains(.uploaded(hash: hash)) }
        try await eventually("steps") { transfers.all.last?.completed == 3_500 }
        let steps = transfers.all.filter { $0.hash == hash }
        #expect(steps.map(\.completed) == [0, 1_000, 2_000, 3_000, 3_500])
        #expect(steps.allSatisfy { $0.direction == .upload && $0.total == 3_500 })
        #expect(steps.first?.fraction == 0 && steps.last?.fraction == 1)
        #expect(harness.queue.transfer(of: hash) == nil, "done")
        try await harness.stop()
    }

    @Test func downloadsReportEveryChunk() async throws {
        let harness = try await BlobHarness()
        let transfers = Collector(harness.queue.transfers())
        let data = Data(repeating: 4, count: 10)
        let hash = BlobCache.hex(SHA256.hash(data: data))
        await harness.server.put(data)
        await harness.queue.setOnline(true)
        #expect(await harness.queue.blob(hash) == .pending)
        try await eventually("available") { harness.events.all.contains { if case .available(hash, _) = $0 { true } else { false } } }
        try await eventually("steps") { transfers.all.last?.completed == 10 }
        let steps = transfers.all.filter { $0.hash == hash }
        #expect(steps.map(\.completed) == [0, 4, 8, 10] && steps.allSatisfy { $0.direction == .download && $0.total == 10 })
        #expect(harness.queue.transfer(of: hash) == nil)
        try await harness.stop()
    }

    @Test func aTransferOfNothingIsAtZero() {
        #expect(BlobTransfer(hash: "h", direction: .download, completed: 5, total: 0).fraction == 0)
        #expect(BlobTransfer(hash: "h", direction: .upload, completed: 9, total: 4).fraction == 1)
    }
}
