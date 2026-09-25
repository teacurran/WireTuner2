import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender
import WTText

/// Placed SVG animations in the scene (WEB-026's poster), the text hooks of the scene, template
/// and export (TYPE-034/038), and the Show Links marks (WEB-004).
@Suite @MainActor struct SceneObjectKindsTests {
    /// An asset with a SHA-256 of `byte` repeated.
    static func asset(_ replica: inout Replica, _ name: String, byte: UInt8) throws -> OpID {
        let props = AssetFields.values {
            $0.common.name = name
            $0.sha256 = Data(repeating: byte, count: 32)
            $0.mediaType = "image/png"
        }
        return try replica.perform(OpsCommand("Asset", ops: [Ops.create(parent: WellKnown.assets, position: [byte], props: props)]))!.createdNodes[0]
    }

    @Test func aPlacedAnimationDrawsItsPosterWithTheGlyphOnScreenOnly() throws {
        var replica = Replica(3)
        _ = try NavigationFixture.layer(&replica)
        let svg = try Self.asset(&replica, "spin.svg", byte: 1)
        let poster = try Self.asset(&replica, "poster", byte: 2)
        let file = SvgAnimationFile(asset: svg, naturalSize: Size(width: 200, height: 100), durationMs: 1000, kinds: SvgAnimationKinds(css: true),
                                    posterTimeMs: 0, poster: poster)
        let node = try #require(try replica.perform(CreateSvgAnimation(file, transform: .translation(x: 10, y: 20), name: "Spinner"))).createdObjects[0]
        var builder = DocumentDisplayListBuilder(canvas: "c")
        var scene = builder.rebuild(replica.state)
        var object = try #require(scene.object(node))
        guard case .image(let image) = object.item else { Issue.record("poster"); return }
        #expect(object.kind == .svgAnimation && image.showsPlayGlyph && image.assetID == String(repeating: "02", count: 32))
        #expect(image.name == "Spinner" && object.bounds == Rect(x: 10, y: 20, width: 200, height: 100))
        #expect(Objects.bounds(of: node, in: replica.state) == object.bounds && Objects.isObject(node, in: replica.state))
        #expect(builder.dependencies.dependents(of: [NodeID(poster)]).contains(NodeID(node)))
        // Print and export never show the glyph.
        let output = builder.outputDisplayList(replica.state)
        guard case .image(let printed)? = output.items.first else { Issue.record("output poster"); return }
        #expect(!printed.showsPlayGlyph && printed.assetID == image.assetID)
        // Move and transform act on it.
        let move = try #require(try replica.perform(MoveObjects([node], by: Vector(dx: 5, dy: 5))))
        (scene, _) = builder.apply(move, state: replica.state, origin: .local)
        object = try #require(scene.object(node))
        #expect(object.bounds == Rect(x: 15, y: 25, width: 200, height: 100))
        // A new poster repaints only the animation.
        let later = try Self.asset(&replica, "later", byte: 3)
        let change = try #require(try replica.perform(SetSvgAnimationPoster(node, timeMs: 500, poster: later)))
        let summary: ChangeSummary
        (scene, summary) = builder.apply(change, state: replica.state, origin: .remote)
        guard case .image(let repostered) = try #require(scene.object(node)).item else { Issue.record("new poster"); return }
        #expect(repostered.assetID == String(repeating: "03", count: 32) && summary.touchedNodes == [NodeID(node)])
        // Without a poster the placeholder draws.
        try replica.perform(ReplaceSvgAnimation(node, with: SvgAnimationFile(asset: svg, naturalSize: Size(width: 0, height: 0), durationMs: 0, kinds: SvgAnimationKinds())))
        scene = builder.rebuild(replica.state)
        guard case .image(let bare) = try #require(scene.object(node)).item else { Issue.record("placeholder"); return }
        #expect(bare.assetID.isEmpty && bare.rect == Rect(x: 0, y: 0, width: 320, height: 240))
        #expect(ImageNodes.poster(svg, transform: .identity, in: replica.state) == nil)
    }

    @Test func textRedrawsWhenAStyleOrTheSettingsChange() throws {
        var replica = Replica(1)
        try replica.perform(DocumentTemplate())
        let node = try TextFixture.block(&replica, "Hello")
        let fonts = DocumentFontIndex(state: replica.state)
        var builder = TextSceneTests.builder(replica.state, fonts: fonts)
        let normal = try #require(TextStyleResolver(replica.state).normalText)
        #expect(builder.dependencies.dependents(of: [NodeID(normal)]).contains(NodeID(node)))
        #expect(builder.dependencies.dependents(of: [NodeID(WellKnown.settings)]).contains(NodeID(node)))
        var attrs = Wiretuner_Doc_V1_TextStyleAttrs()
        attrs.character.size = 40
        let edit = try #require(try replica.perform(EditTextStyle(normal, attrs: attrs, fields: [[2, 3]])))
        let (_, summary) = builder.apply(edit, state: replica.state, origin: .local)
        #expect(summary.touchedNodes.contains(NodeID(node)))
    }

    @Test func theTemplateAddsTheNormalTextStyleOnce() throws {
        var core = DocumentTemplate.core(replica: 7)
        let normal = try #require(TextStyleResolver(core.state).normalText)
        #expect(core.state.props(normal).style.role == .normalText)
        let again = try core.perform(DocumentTemplate(), recording: DocumentCore.Recording(limit: 1, now: Date()))
        #expect(again == nil)
    }

    @Test func exportedStoriesResolveTheDocumentsStylesAndColours() throws {
        var replica = Replica(1)
        try replica.perform(DocumentTemplate())
        let node = try TextFixture.block(&replica, "Hi")
        let text = TextFixture.text(replica, node)
        let story = ExportSnapshot.story(text, state: replica.state)
        guard case .paragraph(let paragraph)? = story.elements.first else { Issue.record("paragraph"); return }
        #expect(paragraph.text == "Hi" && story.elements.count == 1)
        // The document's styles resolve into the run, as `TextAttributeMapping` does with them.
        guard case .paragraph(let styled)? = TextAttributeMapping.story(text, styles: TextStyleResolver(replica.state)).elements.first else {
            Issue.record("styled")
            return
        }
        #expect(paragraph.runs.map(\.attributes) == styled.runs.map(\.attributes))
    }

    @Test func showLinksMarksLinkedObjectsAndTextLinesInDrawOrder() throws {
        var replica = Replica(1)
        let layer = try NavigationFixture.layer(&replica)
        let a = try NavigationFixture.rect(&replica, on: layer)
        let b = try NavigationFixture.rect(&replica, on: layer, x: 300)
        _ = try NavigationFixture.rect(&replica, on: layer, x: 600)
        try replica.perform(SetLink([b], url: "https://b.example"))
        try replica.perform(SetLink([a], url: "https://a.example"))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(replica.state)
        let lines = [NodeID(b): [ExportTextLink(url: "https://text.example", rects: [Rect(x: 300, y: 0, width: 20, height: 10)])]]
        let overlay = LinkOverlayReading.overlay(scene: scene, index: LinkIndex(replica.state), textLinks: lines)
        #expect(overlay.marks.map(\.url) == ["https://a.example", "https://b.example", "https://text.example"])
        #expect(overlay.marks[0].shape == .object(try #require(scene.object(a)?.bounds)))
        #expect(overlay.url(at: Point(x: 305, y: 5)) == "https://text.example")
        #expect(LinkOverlayReading.overlay(scene: scene, index: LinkIndex()).isEmpty)
    }
}
