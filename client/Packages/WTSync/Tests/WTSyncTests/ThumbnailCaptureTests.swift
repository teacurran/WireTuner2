import CryptoKit
import Foundation
import Synchronization
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// A renderer that counts its calls and draws "png-<n>".
final class CountingRenderer: Sendable {
    private let calls = Mutex(0)
    let draws: Bool

    init(draws: Bool = true) {
        self.draws = draws
    }

    var count: Int { calls.withLock { $0 } }

    var render: ThumbnailCapture.Renderer {
        { _ in
            let n = self.calls.withLock { value in
                value += 1
                return value
            }
            return self.draws ? Data("png-\(n)".utf8) : nil
        }
    }
}

/// DOC-032: the library thumbnail capture.
@Suite(.timeLimit(.minutes(2))) struct ThumbnailCaptureTests {
    static func edit(_ store: LocalStore, _ name: String = "A") async throws {
        _ = try await store.perform(createLayer(name), recording: Fixture.recording())
    }

    static func thumbnails(_ store: LocalStore) async throws -> [LocalStore.PendingBlob] {
        try await store.pendingBlobs().filter { $0.tag == LocalStore.thumbnailTag }
    }

    @Test func closingAChangedDocumentCapturesOnceAndAnUnchangedOneNever() async throws {
        let harness = try await BlobHarness()
        let renderer = CountingRenderer()
        let capture = await ThumbnailCapture(store: harness.store, queue: harness.queue, render: renderer.render)
        #expect(await !capture.hasChanges)
        #expect(try await capture.close() == nil && renderer.count == 0)
        #expect(try await Self.thumbnails(harness.store).isEmpty)
        try await Self.edit(harness.store)
        #expect(await capture.hasChanges)
        let outbox = try await harness.store.outboxCount()
        let hash = try #require(try await capture.close())
        #expect(renderer.count == 1 && hash == BlobCache.hex(SHA256.hash(data: Data("png-1".utf8))))
        #expect(try await Self.thumbnails(harness.store).map(\.hash) == [hash])
        #expect(try await Self.thumbnails(harness.store).first?.mediaType == "image/png")
        // Capturing writes no change; closing again with nothing new captures nothing.
        #expect(try await harness.store.outboxCount() == outbox)
        #expect(try await capture.close() == nil && renderer.count == 1)
        // A remote change counts as a change too.
        _ = try await harness.store.receive(Fixture.change(99, seq: 1, start: 50, [Fixture.createLayer("R")]), serverSeq: 1)
        #expect(try await capture.captureIfChanged() != nil && renderer.count == 2)
        try await harness.stop()
    }

    @Test func manyEditsWithinTheIntervalProduceOneAndOfflineThumbnailsAreReplaced() async throws {
        let harness = try await BlobHarness()
        let image = try await harness.queue.add(Data(repeating: 1, count: 10), mediaType: "image/png")
        let renderer = CountingRenderer()
        let capture = await ThumbnailCapture(store: harness.store, queue: harness.queue, interval: .seconds(3600), render: renderer.render)
        await capture.start()
        await capture.start()   // idempotent
        for index in 0..<5 {
            try await Self.edit(harness.store, "L\(index)")
        }
        let first = try #require(try await capture.captureIfChanged())
        #expect(renderer.count == 1)
        // Offline: a later capture replaces the pending thumbnail rather than adding one.
        try await Self.edit(harness.store, "M")
        let second = try #require(try await capture.close())
        #expect(first != second && renderer.count == 2)
        #expect(try await Self.thumbnails(harness.store).map(\.hash) == [second])
        // Reconnect: the thumbnail uploads before the other blobs.
        await harness.queue.start()
        await harness.queue.setOnline(true)
        try await eventually("uploaded") { try await harness.store.pendingBlobs().isEmpty }
        #expect(await harness.server.uploadOrder == [second, image])
        #expect(await harness.server.uploads.first?.header.tag == .thumbnail)
        try await harness.stop()
    }

    @Test func theTimerCapturesAtTheInterval() async throws {
        let harness = try await BlobHarness()
        let renderer = CountingRenderer()
        let capture = await ThumbnailCapture(store: harness.store, queue: harness.queue, interval: .milliseconds(20), render: renderer.render)
        await capture.start()
        try await Self.edit(harness.store)
        try await eventually("captured") { renderer.count == 1 }
        // Three more intervals with the document unchanged since: nothing more.
        let ticks = await capture.ticks
        try await eventually("three more intervals") { await capture.ticks >= ticks + 3 }
        #expect(renderer.count == 1)
        #expect(try await capture.close() == nil)
        try await harness.stop()
    }

    @Test func aCloseDuringATimerCaptureWaitsForItAndDrawsOnce() async throws {
        let harness = try await BlobHarness()
        let gate = AsyncStream<Void>.makeStream()
        let calls = Mutex(0)
        let capture = await ThumbnailCapture(store: harness.store, queue: harness.queue, interval: .seconds(3600)) { _ in
            calls.withLock { $0 += 1 }
            for await _ in gate.stream { break }
            return Data("png".utf8)
        }
        try await Self.edit(harness.store)
        let running = Task { try await capture.captureIfChanged() }
        try await eventually("rendering") { calls.withLock { $0 } == 1 }
        let closing = Task { try await capture.close() }
        try await eventually("the close waiting") { await capture.requests == 2 }
        gate.continuation.yield()
        gate.continuation.finish()
        #expect(try await running.value != nil)
        #expect(try await closing.value == nil, "the state was captured")
        #expect(calls.withLock { $0 } == 1)
        try await harness.stop()
    }

    @Test func aRendererThatDrawsNothingQueuesNothing() async throws {
        let harness = try await BlobHarness()
        let renderer = CountingRenderer(draws: false)
        let capture = await ThumbnailCapture(store: harness.store, queue: harness.queue, render: renderer.render)
        try await Self.edit(harness.store)
        #expect(try await capture.close() == nil && renderer.count == 1)
        #expect(try await harness.store.pendingBlobs().isEmpty)
        try await harness.stop()
    }

    @Test func theDefaultRendererDrawsTheFirstPageAsAPNG() async throws {
        let harness = try await BlobHarness()
        let capture = await ThumbnailCapture(store: harness.store, queue: harness.queue)
        try await Self.edit(harness.store)
        let hash = try #require(try await capture.close())
        let data = try Data(contentsOf: harness.queue.cache.url(for: hash))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        try await harness.stop()
    }
}
