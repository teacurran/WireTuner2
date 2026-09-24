import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// WEB-024: the placed SVG animation node model.
@Suite struct WebSvgAnimationTests {
    /// An asset node named `name` on `replica`.
    static func asset(_ replica: inout Replica, _ name: String) throws -> OpID {
        let props = AssetFields.values {
            $0.common.name = name
            $0.mediaType = "image/svg+xml"
        }
        return try replica.perform(OpsCommand("Asset", ops: [Ops.create(parent: OpID.wellKnown(9), position: [0x80], props: props)]))!.createdNodes[0]
    }

    struct Placed {
        var pair = Pair()
        var layer: OpID
        var svg: OpID
        var poster: OpID
        var node: OpID

        init() throws {
            layer = try NavigationFixture.layer(&pair.a)
            svg = try WebSvgAnimationTests.asset(&pair.a, "spin.svg")
            poster = try WebSvgAnimationTests.asset(&pair.a, "spin poster")
            let file = SvgAnimationFile(asset: svg, naturalSize: Size(width: 200, height: 100), durationMs: 2000,
                                        kinds: SvgAnimationKinds(css: true), posterTimeMs: 0, poster: poster)
            node = try pair.a.perform(CreateSvgAnimation(file, transform: .translation(x: 10, y: 20), name: "Spinner"))!.createdObjects[0]
            pair.sync()
        }
    }

    @Test func creatingPlacesOneNodeInOneChange() throws {
        let p = try Placed()
        let change = try #require(p.pair.a.sent.last)
        #expect(change.label == "Place SVG animation" && change.ops.count == 1)
        let info = try #require(SvgAnimationInfo(p.node, in: p.pair.b.state))
        #expect(info.asset == p.svg && info.poster == p.poster)
        #expect(info.naturalSize == Size(width: 200, height: 100) && info.bounds == Rect(x: 0, y: 0, width: 200, height: 100))
        #expect(info.durationMs == 2000 && info.kinds == SvgAnimationKinds(css: true) && info.web == SvgAnimationWeb())
        #expect(info.transform == .translation(x: 10, y: 20) && !info.isPlaceholder)
        #expect(p.pair.a.state.props(p.node).svgAnimation.common.name == "Spinner")
        #expect(LayerOrder(p.pair.a.state).objects(on: p.layer, in: p.pair.a.state) == [p.node])
        #expect(SvgAnimationInfo(p.layer, in: p.pair.a.state) == nil)
    }

    @Test func editingAndReplacingAreOneChangeEachWithInverses() throws {
        var p = try Placed()
        let second = try Self.asset(&p.pair.a, "later poster")
        let other = try Self.asset(&p.pair.a, "bounce.svg")
        let poster = try p.pair.a.perform(SetSvgAnimationPoster(p.node, timeMs: 1500, poster: second))!
        #expect(poster.label == "Poster Frame" && poster.ops.count == 1)
        var info = try #require(SvgAnimationInfo(p.node, in: p.pair.a.state))
        #expect(info.posterTimeMs == 1500 && info.poster == second)
        let web = try p.pair.a.perform(SetSvgAnimationWeb([p.node], autoplay: false, loop: .once, playOnHover: true))!
        #expect(web.label == "SVG Animation Playback" && web.ops.count == 1)
        info = try #require(SvgAnimationInfo(p.node, in: p.pair.a.state))
        #expect(info.web == SvgAnimationWeb(autoplay: false, loop: .once, playOnHover: true))
        #expect(try p.pair.a.perform(SetSvgAnimationWeb([p.node])) == nil)
        let replaced = SvgAnimationFile(asset: other, naturalSize: Size(width: 50, height: 60), durationMs: 0, kinds: SvgAnimationKinds(smil: true, script: true))
        let replace = try p.pair.a.perform(ReplaceSvgAnimation(p.node, with: replaced))!
        #expect(replace.label == "Replace SVG animation" && replace.ops.count == 1 && replace.ops[0].set.paths.count == 6)
        info = try #require(SvgAnimationInfo(p.node, in: p.pair.a.state))
        #expect(info.asset == other && info.naturalSize == Size(width: 50, height: 60) && info.kinds == SvgAnimationKinds(smil: true, script: true))
        #expect(info.poster == nil && info.posterTimeMs == 0)
        // Replace keeps the transform and the web settings.
        #expect(info.transform == .translation(x: 10, y: 20) && info.web.loop == .once)
        p.pair.a.undo()
        info = try #require(SvgAnimationInfo(p.node, in: p.pair.a.state))
        #expect(info.asset == p.svg && info.poster == second && info.durationMs == 2000)
        p.pair.a.undo()
        #expect(SvgAnimationInfo(p.node, in: p.pair.a.state)?.web == SvgAnimationWeb())
        p.pair.a.undo()
        info = try #require(SvgAnimationInfo(p.node, in: p.pair.a.state))
        #expect(info.poster == p.poster && info.posterTimeMs == 0)
        for loop in [SvgAnimationLoop.asFile, .loop] {
            try p.pair.a.perform(SetSvgAnimationWeb([p.node], loop: loop))
            #expect(SvgAnimationInfo(p.node, in: p.pair.a.state)?.web.loop == loop)
        }
    }

    @Test func readTimeNormalizations() throws {
        var p = try Placed()
        // A poster time beyond a finite duration reads as the last frame.
        try p.pair.a.perform(SetSvgAnimationPoster(p.node, timeMs: 9000, poster: p.poster))
        #expect(SvgAnimationInfo(p.node, in: p.pair.a.state)?.posterTimeMs == 2000)
        // A zero natural size reads as 320 × 240; an indefinite duration keeps any poster time.
        try p.pair.a.perform(ReplaceSvgAnimation(p.node, with: SvgAnimationFile(asset: p.svg, naturalSize: Size(width: 0, height: 0), posterTimeMs: 9000)))
        var info = try #require(SvgAnimationInfo(p.node, in: p.pair.a.state))
        #expect(info.naturalSize == SvgAnimationFields.fallbackSize && info.posterTimeMs == 9000)
        // A deleted asset dangles: the node reads as a placeholder.
        try p.pair.a.perform(DeleteNodes([p.svg]))
        info = try #require(SvgAnimationInfo(p.node, in: p.pair.a.state))
        #expect(info.isPlaceholder && info.asset == nil)
    }

    @Test func refusals() throws {
        var p = try Placed()
        let file = SvgAnimationFile(asset: p.layer, naturalSize: Size(width: 1, height: 1))
        #expect(throws: SvgAnimationError.notAnAsset(p.layer)) { try p.pair.a.perform(CreateSvgAnimation(file)) }
        #expect(throws: SvgAnimationError.notAnAnimation(p.layer)) { try p.pair.a.perform(SetSvgAnimationPoster(p.layer, timeMs: 0, poster: p.poster)) }
        #expect(throws: SvgAnimationError.notAnAsset(p.layer)) { try p.pair.a.perform(SetSvgAnimationPoster(p.node, timeMs: 0, poster: p.layer)) }
        #expect(throws: SvgAnimationError.notAnAnimation(p.layer)) { try p.pair.a.perform(SetSvgAnimationWeb([p.layer], autoplay: true)) }
        let bad = SvgAnimationFile(asset: p.svg, naturalSize: Size(width: -1, height: 1))
        #expect(throws: SvgAnimationError.invalidValue("naturalSize")) { try p.pair.a.perform(ReplaceSvgAnimation(p.node, with: bad)) }
        #expect(throws: LayerError.notALayer(p.svg)) {
            try p.pair.a.perform(CreateSvgAnimation(SvgAnimationFile(asset: p.svg, naturalSize: Size(width: 1, height: 1)), layer: p.svg))
        }
    }

    @Test func concurrentPosterChangesTakeBothRegistersFromTheSameWinningChange() throws {
        var p = try Placed()
        let mine = try Self.asset(&p.pair.a, "mine")
        let theirs = try Self.asset(&p.pair.b, "theirs")
        p.pair.sync()
        try p.pair.a.perform(SetSvgAnimationPoster(p.node, timeMs: 500, poster: mine))
        try p.pair.b.perform(SetSvgAnimationPoster(p.node, timeMs: 1200, poster: theirs))
        p.pair.sync()
        #expect(p.pair.a.state.stateHash == p.pair.b.state.stateHash)
        let info = try #require(SvgAnimationInfo(p.node, in: p.pair.a.state))
        #expect(info.posterTimeMs == 1200 && info.poster == theirs)
        let time = p.pair.a.state.register(p.node, SvgAnimationFields.posterTimeMs)?.op
        let poster = p.pair.a.state.register(p.node, SvgAnimationFields.poster)?.op
        #expect(time != nil && time == poster)
    }

    @Test func aConcurrentMoveSurvivesAReplace() throws {
        var p = try Placed()
        let other = try Self.asset(&p.pair.a, "other.svg")
        p.pair.sync()
        try p.pair.a.perform(ReplaceSvgAnimation(p.node, with: SvgAnimationFile(asset: other, naturalSize: Size(width: 10, height: 10))))
        let move = PathEditing.proto(.translation(x: 99, y: 1))
        try p.pair.b.perform(OpsCommand("Move", ops: [Ops.set(p.node, [SvgAnimationFields.transform], values: SvgAnimationFields.values { $0.common.transform = move })]))
        p.pair.sync()
        #expect(p.pair.a.state.stateHash == p.pair.b.state.stateHash)
        let info = try #require(SvgAnimationInfo(p.node, in: p.pair.a.state))
        #expect(info.asset == other && info.transform == .translation(x: 99, y: 1))
    }
}
