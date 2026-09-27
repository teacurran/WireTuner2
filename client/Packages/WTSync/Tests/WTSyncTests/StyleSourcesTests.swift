import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// LIB-022's WTSync half: a style package with the asset bytes cached here, and a style library
/// file's bytes put back into a blob cache.
@Suite struct StyleSourcesTests {
    @Test func packagesCarryCachedAssetBytesAndFilesRestoreThem() throws {
        let scratch = Scratch()
        let cache = BlobCache(directory: scratch.directory.appending(path: "Blobs"))
        let bytes = Data("pixels".utf8)
        let hash = try cache.insert(bytes)
        var state = EngineState()
        var asset = Wiretuner_Doc_V1_NodeProps()
        asset.asset.sha256 = BlobCache.bytes(hex: hash)
        var style = Wiretuner_Doc_V1_NodeProps()
        style.style.common.name = "Textured"
        style.style.appearance.fills = [Appearances.basicFill(red: 0.5, green: 0.5, blue: 0.5)]
        var image = Wiretuner_Doc_V1_NodeProps()
        image.svgAnimation.asset.id = OpID(counter: 1, replica: 5).proto
        state.apply(Fixture.change(5, seq: 1, start: 1, [
            Ops.create(parent: .wellKnown(9), position: [0x80], props: asset),
            Ops.create(parent: GraphicStyleResolver.collection, position: [0x80], props: style),
        ]), serverSeq: 1)
        state.apply(Fixture.change(5, seq: 2, start: 3, [
            Ops.create(parent: OpID(counter: 2, replica: 5), position: [0x80], props: image),
        ]), serverSeq: 2)

        let all = StyleSources.package(of: state)
        #expect(all.names == ["Textured"] && all.blobs.isEmpty)
        let package = StyleSources.package(of: state, styles: [OpID(counter: 2, replica: 5)], cache: cache)
        #expect(package.names == ["Textured"])
        #expect(package.assetHashes == [hash] && package.blobs == [hash: bytes])

        let file = try StylePackage(fileData: package.fileData)
        let elsewhere = BlobCache(directory: scratch.directory.appending(path: "Elsewhere"))
        #expect(try StyleSources.storeBlobs(of: file, in: elsewhere) == [hash])
        #expect(elsewhere.contains(hash))
    }
}
