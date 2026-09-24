import CoreGraphics
import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
import WTRender
@testable import WTSync

/// Profile data for the tests: a custom CMYK profile (Generic CMYK with another creation date, so
/// its hash is not a bundled profile's) and a custom RGB one (Adobe RGB).
enum TestProfiles {
    static let customCMYK: Data = {
        var bytes = [UInt8](CGColorSpace(name: CGColorSpace.genericCMYK)!.copyICCData()! as Data)
        bytes[24] = 0x07   // the year's high byte: 1792
        bytes[25] = 0x00
        return Data(bytes)
    }()

    static let customRGB = CGColorSpace(name: CGColorSpace.adobeRGB1998)!.copyICCData()! as Data
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData()! as Data

    static func write(_ data: Data, named name: String, in scratch: Scratch) throws -> URL {
        let url = scratch.directory.appending(path: name)
        try data.write(to: url)
        return url
    }

    /// The draft with `cmyk` as Working CMYK.
    static func draft(cmyk: WTColor.ProfileRef, in state: EngineState = EngineState()) -> Wiretuner_Doc_V1_ColorSettings {
        var draft = ColorSettings.draft(state)
        draft.cmykProfile = ColorSettings.stored(cmyk)
        return draft
    }
}

/// CMS-008: custom profiles as blobs.
@Suite(.timeLimit(.minutes(2))) struct ProfileBlobTests {
    @Test func aProfileChosenOfflineUploadsBeforeQueuedImages() async throws {
        let harness = try await BlobHarness()
        let blobs = ProfileBlobs(cache: harness.queue.cache, registry: WTColor.ProfileRegistry())
        let image = try await harness.queue.add(fileAt: harness.file("image", bytes: 100), mediaType: "image/png")
        let url = try TestProfiles.write(TestProfiles.customCMYK, named: "press.icc", in: harness.scratch)
        let ref = try await blobs.load(fileAt: url, queue: harness.queue)
        #expect(!ref.isBundled && ref.space == .cmyk && blobs.isAvailable(ref.sha256))
        #expect(blobs.registry.colorSpace(for: ref) != nil)
        let before = try await harness.store.outboxCount()
        _ = try await harness.store.perform(ChangeColorSettings(TestProfiles.draft(cmyk: ref)), recording: Fixture.recording())
        #expect(try await harness.store.outboxCount() == before + 1)
        // A bundled profile loaded from a file is recognized and queues nothing; a file that is not
        // a profile is refused.
        let srgb = try await blobs.load(fileAt: TestProfiles.write(TestProfiles.sRGB, named: "srgb.icc", in: harness.scratch), queue: harness.queue)
        #expect(srgb.bundledID == "srgb")
        await #expect(throws: ProfileBlobs.Failure.notAProfile) {
            try await blobs.load(fileAt: harness.file("junk.icc", bytes: 400), queue: harness.queue)
        }
        #expect(try await harness.store.pendingBlobs().map(\.hash) == [ref.hexHash, image])
        // Reconnect: the profile goes first although the image is smaller.
        await harness.queue.start()
        await harness.queue.setOnline(true)
        try await eventually("uploaded") { try await harness.store.pendingBlobs().isEmpty }
        #expect(await harness.server.uploadOrder == [ref.hexHash, image])
        #expect(await harness.server.uploads.first?.header.mediaType == ProfileBlobs.mediaType)
        try await harness.stop()
    }

    @Test func twoDocumentsShareOneCachedFile() async throws {
        let scratch = Scratch()
        let cache = BlobCache(directory: scratch.directory.appending(path: "Blobs"))
        let blobs = ProfileBlobs(cache: cache, registry: WTColor.ProfileRegistry())
        let url = try TestProfiles.write(TestProfiles.customRGB, named: "adobe.icc", in: scratch)
        var refs: [WTColor.ProfileRef] = []
        var stores: [LocalStore] = []
        for document in ["D1", "D2"] {
            let store = try await LocalStore.open(documentID: document, at: scratch.url(document), options: options())
            let queue = BlobQueue(store: store, cache: cache, transport: FakeBlobTransport(server: FakeBlobServer()), tokens: FakeTokens(),
                                  options: fastBlobOptions())
            refs.append(try await blobs.load(fileAt: url, queue: queue))
            #expect(try await store.pendingBlobs().count == 1)
            stores.append(store)
        }
        #expect(refs[0] == refs[1] && refs[0].space == .rgb)
        let files = FileManager.default.enumerator(at: cache.directory, includingPropertiesForKeys: [.isRegularFileKey])!
            .compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        #expect(files.map(\.lastPathComponent) == [refs[0].hexHash])
        for store in stores {
            try await store.close()
        }
    }

    @Test func anUnavailableProfileRendersThroughTheDefaultAndFlipsWithoutAWrite() async throws {
        let harness = try await BlobHarness()
        let registry = WTColor.ProfileRegistry()
        let blobs = ProfileBlobs(cache: harness.queue.cache, registry: registry)
        blobs.install()
        let ref = try #require(WTColor.ProfileRegistry.makeRef(iccData: TestProfiles.customCMYK))
        // Another replica chose the profile; its blob is on the server, not here.
        await harness.server.put(TestProfiles.customCMYK)
        _ = try await harness.store.receive(Fixture.change(99, seq: 1, start: 1, [
            Ops.set(WellKnown.settings, ChangeColorSettings.registers, values: {
                var values = Wiretuner_Doc_V1_NodeProps()
                values.settings.color = TestProfiles.draft(cmyk: ref)
                return values
            }()),
        ]), serverSeq: 1)
        let state = await harness.store.read { $0 }
        let waiting = ColorSettings(state, registry: registry, isAvailable: blobs.isAvailable)
        #expect(waiting.pending && waiting.pendingProfiles == [ref] && waiting.cmykProfile == ref)
        #expect(waiting.colorManagement(registry: registry).cmykProfile == registry.defaultCMYK)
        #expect(registry.resolve(ref, default: registry.defaultCMYK).pending)
        let outbox = try await harness.store.outboxCount()
        let arrivals = blobs.arrivals(harness.queue.events(), watching: [ref, ref])
        #expect(await blobs.requestMissing(in: state, queue: harness.queue) == [ref])
        await harness.queue.setOnline(true)
        var iterator = arrivals.makeAsyncIterator()
        #expect(await iterator.next() == ref)
        let arrived = ColorSettings(state, registry: registry, isAvailable: blobs.isAvailable)
        #expect(!arrived.pending && arrived.colorManagement(registry: registry).cmykProfile == ref)
        #expect(!registry.resolve(ref, default: registry.defaultCMYK).pending)
        #expect(try await harness.store.outboxCount() == outbox)
        // Nothing is missing any more.
        #expect(await blobs.requestMissing(in: state, queue: harness.queue).isEmpty)
        try await harness.stop()
    }

    @Test func arrivalsListOnlyTheWatchedProfiles() async throws {
        let blobs = ProfileBlobs(cache: BlobCache(directory: Scratch().directory))
        let ref = WTColor.ProfileRef(name: "P", sha256: Data(repeating: 0xAB, count: 32), space: .rgb)
        let url = URL(fileURLWithPath: "/dev/null")
        let events = AsyncStream<BlobEvent> { continuation in
            continuation.yield(.available(hash: "00", url: url))
            continuation.yield(.uploaded(hash: ref.hexHash))
            continuation.yield(.available(hash: ref.hexHash, url: url))
            continuation.finish()
        }
        var seen: [WTColor.ProfileRef] = []
        for await profile in blobs.arrivals(events, watching: [ref]) {
            seen.append(profile)
        }
        #expect(seen == [ref])
        #expect(blobs.registry === WTColor.ProfileRegistry.shared)
    }
}
