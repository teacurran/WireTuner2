import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender

/// WEB-027: another file in an SVG animation's place, keeping its size and settings.
@Suite struct SvgAnimationReplaceFileTests {
    static func file(_ text: String, width: Double, height: Double, script: Bool = false) -> ImportedPlacedFile {
        ImportedPlacedFile(kind: .svgAnimation(css: false, smil: true, script: script, durationMs: 3000), blob: ImportedBlob(data: Data(text.utf8), uti: "public.svg-image"),
                           bounds: Rect(x: 0, y: 0, width: width, height: height), name: "bounce.svg")
    }

    @Test func aReplacementKeepsThePlacedSizeAndTheWebSettings() throws {
        var p = try WebSvgAnimationTests.Placed()
        try p.pair.a.perform(SetSvgAnimationWeb([p.node], autoplay: false))
        let before = try #require(SvgAnimationInfo(p.node, in: p.pair.a.state))
        let placed = before.bounds.applying(before.transform)
        let poster = ImportedPoster(blob: ImportedBlob(data: Data([9, 9, 9]), uti: "public.png"), timeMs: 500)
        let change = try #require(try p.pair.a.perform(ReplaceSvgAnimationFile(p.node, file: Self.file("<svg/>", width: 400, height: 400), poster: poster)))
        #expect(change.label == "Replace SVG animation")
        let info = try #require(SvgAnimationInfo(p.node, in: p.pair.a.state))
        #expect(info.naturalSize == Size(width: 400, height: 400) && info.durationMs == 3000 && info.kinds == SvgAnimationKinds(smil: true))
        #expect(info.posterTimeMs == 500 && info.poster != nil && info.asset != before.asset && !info.web.autoplay)
        let after = info.bounds.applying(info.transform)
        #expect(abs(after.width - placed.width) < 1e-9 && abs(after.height - placed.height) < 1e-9 && abs(after.minX - placed.minX) < 1e-9)
        // The same bytes again reuse the asset; no poster keeps none.
        let assets = p.pair.a.state.liveChildren(WellKnown.assets).count
        try p.pair.a.perform(ReplaceSvgAnimationFile(p.node, file: Self.file("<svg/>", width: 400, height: 400)))
        #expect(p.pair.a.state.liveChildren(WellKnown.assets).count == assets && SvgAnimationInfo(p.node, in: p.pair.a.state)?.poster == nil)
        // A concurrent move and a replacement both apply... the later transform write wins, whole.
        p.pair.sync()
        #expect(p.pair.a.state.stateHash == p.pair.b.state.stateHash)
        // Not an animation, or not an animated file.
        #expect(throws: SvgAnimationError.notAnAnimation(p.layer)) { try p.pair.a.perform(ReplaceSvgAnimationFile(p.layer, file: Self.file("<svg/>", width: 1, height: 1))) }
        var eps = Self.file("%!PS", width: 10, height: 10)
        eps.kind = .eps
        #expect(throws: SvgAnimationError.notAnAnimation(p.node)) { try p.pair.a.perform(ReplaceSvgAnimationFile(p.node, file: eps)) }
        #expect(throws: SvgAnimationError.notAnAnimation(p.node)) { try p.pair.a.perform(ReplaceSvgAnimationFile(p.node, file: Self.file("<svg/>", width: 0, height: 10))) }
    }
}
