import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WTSync

/// LIB-013's WTSync half: reading another document's symbols from its local store (offline) or
/// from the server, and the asset bytes of a symbol library file.
@Suite(.timeLimit(.minutes(2))) struct SymbolSourcesTests {
    /// A store holding one symbol (a rectangle converted), closed; returns its URL and changes.
    static func storeWithSymbol(_ scratch: Scratch) async throws -> (URL, [Wiretuner_Doc_V1_Change]) {
        let url = scratch.url()
        let store = try await LocalStore.open(documentID: "doc", at: url, options: options())
        let recording = Fixture.recording()
        let created = try await store.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10)), recording: recording)
        let rect = try #require(created.change?.createdObjects.first)
        _ = try await store.perform(ConvertToSymbol([rect], name: "Dot"), recording: recording)
        let changes = try await store.outbox()
        try await store.close()
        return (url, changes)
    }

    @Test func aCachedDocumentIsReadFromItsStore() async throws {
        let scratch = Scratch()
        let (url, _) = try await Self.storeWithSymbol(scratch)
        let state = try await SymbolSources.cachedState(documentID: "doc", at: url, options: options())
        let package = SymbolSources.package(of: state)
        #expect(package.names == ["Dot"])
        #expect(SymbolSources.package(of: state, symbols: []).symbols.isEmpty)
    }

    @Test func aCloudDocumentIsReadAtHeadFromItsSnapshotAndTheChangesAfter() async throws {
        let scratch = Scratch()
        let (_, changes) = try await Self.storeWithSymbol(scratch)
        let server = FakeSyncServer()
        for change in changes { _ = try await server.inject(change) }
        let transport = FakeTransport(server: server)
        var expected = EngineState()
        for (index, change) in changes.enumerated() { expected.apply(change, serverSeq: UInt64(index + 1)) }
        // No snapshot: the whole log.
        let whole = try await SymbolSources.cloudState(documentID: server.documentID, transport: transport, token: "token-1")
        #expect(whole.stateHash == expected.stateHash)
        // A snapshot through the first change, then the rest.
        await server.takeSnapshot(through: 1)
        let tail = try await SymbolSources.cloudState(documentID: server.documentID, transport: transport, token: "token-1")
        #expect(tail.stateHash == expected.stateHash && SymbolSources.package(of: tail).names == ["Dot"])
        await #expect(throws: SymbolSources.Failure.gap(expected: 2, got: 3)) {
            try await SymbolSources.cloudState(documentID: server.documentID, transport: VersionStateTests.GapTransport(), token: "t")
        }
    }

    @Test func libraryFilesCarryAndRestoreAssetBytes() throws {
        let scratch = Scratch()
        let cache = BlobCache(directory: scratch.directory.appending(path: "Blobs"))
        let bytes = Data("pixels".utf8)
        let hash = try cache.insert(bytes)
        var state = EngineState()
        var asset = Wiretuner_Doc_V1_NodeProps()
        asset.asset.sha256 = BlobCache.bytes(hex: hash)
        var missing = asset
        missing.asset.sha256 = Data(repeating: 1, count: 32)
        var image = Wiretuner_Doc_V1_NodeProps()
        image.svgAnimation.asset.id = OpID(counter: 1, replica: 5).proto
        var other = image
        other.svgAnimation.asset.id = OpID(counter: 2, replica: 5).proto
        var symbol = Wiretuner_Doc_V1_NodeProps()
        symbol.symbol.common.name = "Pic"
        state.apply(Fixture.change(5, seq: 1, start: 1, [
            Ops.create(parent: .wellKnown(9), position: [0x80], props: asset),
            Ops.create(parent: .wellKnown(9), position: [0x90], props: missing),
            Ops.create(parent: .wellKnown(7), position: [0x80], props: symbol),
        ]), serverSeq: 1)
        state.apply(Fixture.change(5, seq: 2, start: 4, [
            Ops.create(parent: OpID(counter: 3, replica: 5), position: [0x80], props: image),
            Ops.create(parent: OpID(counter: 3, replica: 5), position: [0x90], props: other),
        ]), serverSeq: 2)
        let package = SymbolSources.package(of: state, cache: cache)
        #expect(package.assetHashes.count == 2 && package.blobs == [hash: bytes])
        let file = try SymbolPackage(fileData: package.fileData)
        let elsewhere = BlobCache(directory: scratch.directory.appending(path: "Elsewhere"))
        #expect(try SymbolSources.storeBlobs(of: file, in: elsewhere) == [hash])
        #expect(elsewhere.contains(hash))
        // Bytes that do not hash to their name are not claimed as that blob.
        #expect(try SymbolSources.storeBlobs(of: SymbolPackage(blobs: ["00": bytes]), in: elsewhere).isEmpty)
    }
}
