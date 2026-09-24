import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto

/// WEB-027's model half: a scrubbed poster frame becomes an asset and the poster in one change.
@Suite struct SvgAnimationPosterFrameTests {
    @Test func aFrameBecomesThePosterWithItsAssetInOneChange() throws {
        var p = try WebSvgAnimationTests.Placed()
        let png = ImportedBlob(data: Data([0x89, 0x50, 0x4E, 0x47, 1]), uti: "public.png")
        let change = try #require(try p.pair.a.perform(SetSvgAnimationPosterFrame(p.node, timeMs: 1500, png: png)))
        #expect(change.label == "Poster Frame" && change.createdNodes.count == 1)
        var info = try #require(SvgAnimationInfo(p.node, in: p.pair.a.state))
        #expect(info.posterTimeMs == 1500 && info.poster == change.createdNodes[0])
        #expect(p.pair.a.state.props(change.createdNodes[0]).asset.sha256 == png.sha256)
        // The same frame again reuses its asset.
        let again = try #require(try p.pair.a.perform(SetSvgAnimationPosterFrame(p.node, timeMs: 1500, png: png)))
        #expect(again.createdNodes.isEmpty)
        p.pair.a.undo()
        p.pair.a.undo()
        info = try #require(SvgAnimationInfo(p.node, in: p.pair.a.state))
        #expect(info.poster == p.poster && info.posterTimeMs == 0)
        #expect(throws: SvgAnimationError.notAnAnimation(p.layer)) { try p.pair.a.perform(SetSvgAnimationPosterFrame(p.layer, timeMs: 0, png: png)) }
    }
}
