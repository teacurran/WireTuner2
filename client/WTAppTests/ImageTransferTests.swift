import AppKit
import CryptoKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// A blob server of one process: stat, upload into memory, download in 4-byte chunks.
actor MemoryBlobServer {
    var blobs: [Data: Data] = [:]

    func put(_ data: Data) { blobs[Data(SHA256.hash(data: data))] = data }
    func data(_ sha256: Data) -> Data? { blobs[sha256] }
}

struct MemoryBlobTransport: BlobTransport {
    let server: MemoryBlobServer

    func stat(_ request: Wiretuner_Blob_V1_StatRequest, token: String) async throws -> Wiretuner_Blob_V1_StatResponse {
        let data = await server.data(request.sha256)
        return .with { response in
            response.exists = data != nil
            if let data { response.blob.size = UInt64(data.count) }
        }
    }

    func upload(_ header: Wiretuner_Blob_V1_UploadHeader, chunks: AsyncThrowingStream<Data, any Error>, token: String) async throws
        -> Wiretuner_Blob_V1_UploadResponse {
        var data = Data()
        for try await chunk in chunks { data.append(chunk) }
        await server.put(data)
        return .with { $0.blob.sha256 = header.sha256 }
    }

    func download(_ request: Wiretuner_Blob_V1_DownloadRequest, token: String) -> AsyncThrowingStream<Wiretuner_Blob_V1_DownloadResponse, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let data = await server.data(request.sha256) else { continuation.finish(); return }
                continuation.yield(.with { $0.info.size = UInt64(data.count) })
                for start in stride(from: 0, to: data.count, by: 4) {
                    continuation.yield(.with { $0.chunk = data[start..<min(start + 4, data.count)] })
                }
                continuation.finish()
            }
        }
    }
}

/// IMG-006's progress: the *Uploading* badge's ring follows the blob's upload, a collaborator's
/// image is asked for and its placeholder's ring follows the download, and the pixels draw when
/// it arrives -- all on the marks layer, never in an export.
@Suite(.serialized) @MainActor struct ImageTransferTests {
    @Test func transfersDriveTheRingsAndMissingBlobsAreAskedFor() async throws {
        let world = ImageWorld()
        defer { world.close() }
        _ = try #require(await world.placeImage())
        let images = world.features.attach(world.window)
        let mark = try #require(images.marks.first)
        // Uploading at 40 %.
        let progress = TestBox<BlobTransfer?>(BlobTransfer(hash: mark.assetID, direction: .upload, completed: 40, total: 100))
        images.status.transfer = { hash in hash == mark.assetID ? progress.value : nil }
        images.status.pending = { [mark.assetID] }
        await images.contentDidChange().value
        #expect(images.badge(mark) == .uploading && abs(images.progress(mark) - 0.4) < 1e-9)
        images.draw(in: bitmap())
        // A collaborator's image this Mac lacks: asked for once, its ring at the download's progress.
        let asked = TestBox<[String]>([])
        images.status.fetch = { asked.value.append($0) }
        images.status.pending = { [] }
        images.status.isCached = { _ in false }
        progress.value = BlobTransfer(hash: mark.assetID, direction: .download, completed: 3, total: 4)
        await images.contentDidChange().value
        await images.contentDidChange().value
        #expect(asked.value == [mark.assetID] && images.fetched == [mark.assetID])
        #expect(images.badge(mark) == .remote("someone") && abs(images.progress(mark) - 0.75) < 1e-9)
        images.draw(in: bitmap())
        progress.value = nil
        #expect(images.progress(mark) == 0)
        // The queue's changes: a step redraws, an arrival decodes the pixels and asks again next time.
        let (stream, continuation) = AsyncStream.makeStream(of: BlobChange.self)
        images.status.changes = { stream }
        images.watchBlobs()
        images.watchBlobs()
        #expect(images.watch != nil)
        images.store?.forget(assetID: mark.assetID)
        continuation.yield(BlobChange(hash: mark.assetID, arrived: false))
        images.status.isCached = { _ in true }
        continuation.yield(BlobChange(hash: mark.assetID, arrived: true))
        #expect(await eventually { images.fetched.isEmpty && images.store?.state(of: mark.assetID) != .missing })
        continuation.finish()
        // The ring itself: nothing done draws only the track.
        WindowImages.ring(in: bitmap(), center: .zero, radius: 4, fraction: 0, color: CGColor(gray: 0, alpha: 1), track: CGColor(gray: 0, alpha: 0.2))
    }

    @Test func theAppStatusFollowsTheSessionsBlobQueue() async throws {
        let world = ImageWorld()
        defer { world.close() }
        let status = ImageFeatures.status(for: world.window) { world.world.files.blobs }
        // A memory document has no session: no transfers, nothing to ask, no stream.
        #expect(status.transfer("x") == nil && status.changes() == nil)
        status.fetch("x")
        // The queue's streams, merged.
        let directory = TestStores.directory()
        let store = try await LocalStore.open(documentID: "img", at: directory.appending(components: "img", "store.sqlite"))
        let server = MemoryBlobServer()
        let queue = BlobQueue(store: store, cache: BlobCache(directory: directory.appending(path: "Blobs")), transport: MemoryBlobTransport(server: server),
                              tokens: StaticTokens())
        let changes = TestBox<[BlobChange]>([])
        // Subscribed before anything moves, so no step is missed.
        let stream = ImageFeatures.changes(of: queue)
        let watcher = Task { @MainActor in
            for await change in stream { changes.value.append(change) }
        }
        let hash = try await queue.add(Data(repeating: 1, count: 10), mediaType: "image/png")
        await queue.setOnline(true)
        await queue.start()
        #expect(await eventually(.seconds(30)) { changes.value.filter { $0.hash == hash }.count >= 3 }, "two steps and the upload")
        let remote = Data(repeating: 2, count: 9)
        await server.put(remote)
        let remoteHash = SHA256.hash(data: remote).map { String(format: "%02x", $0) }.joined()
        _ = await queue.blob(remoteHash)
        #expect(await eventually(.seconds(30)) { changes.value.contains(BlobChange(hash: remoteHash, arrived: true)) })
        watcher.cancel()
        await queue.stop()
        try await store.close()
    }
}
