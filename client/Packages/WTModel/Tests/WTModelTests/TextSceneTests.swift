import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender
import WTText

/// Text nodes in the scene (creating-text, "Layout"): the `text` kind, the builder's
/// `TextSceneLayout` hook, and the kind's common props for moving and transforming.
@Suite @MainActor struct TextSceneTests {
    static func builder(_ state: EngineState, fonts: DocumentFontIndex) -> DocumentDisplayListBuilder {
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.textLayout = TextSceneLayout(engine: fonts.layoutEngine)
        builder.rebuild(state)
        return builder
    }

    @Test func theTextKindIsKnown() {
        #expect(NodeKind(rawValue: 130) == .text)
        #expect(NodeKind.allCases.contains(.text))
        #expect(NodeValues.appearanceField(.text) == nil)
        #expect(NodeValues.with(kind: .text, appearanceField: 7, Wiretuner_Doc_V1_AppearanceProps()) == Wiretuner_Doc_V1_NodeProps())
        let props = Wiretuner_Doc_V1_NodeProps.with { $0.text.common.name = "Label" }
        #expect(NodeValues.replacing(Wiretuner_Doc_V1_AppearanceProps(), of: .text, in: props) == props)
        #expect(NodeValues.common(props)?.name == "Label")
        #expect(NodeValues.common(kind: .text) { $0.locked = true }.text.common.locked)
    }

    @Test func textBlocksDrawAsSceneObjects() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "Hello", at: Point(x: 100, y: 50))
        let fonts = DocumentFontIndex(state: a.state)
        let builder = Self.builder(a.state, fonts: fonts)
        let object = try #require(builder.scene.object(node))
        #expect(object.kind == .text)
        #expect(object.transform == AffineTransform.translation(x: 100, y: 50))
        let bounds = try #require(object.bounds)
        #expect(bounds.minX >= 99 && bounds.minY >= 49 && bounds.width > 10)
        guard case .group(let group) = object.item else {
            Issue.record("a text block draws as a group of its glyph runs")
            return
        }
        #expect(group.children.contains { if case .text = $0 { true } else { false } })
        #expect(builder.scene.topLevel.contains(NodeID(node)))
    }

    @Test func withoutALayoutTextDrawsNothing() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "Hello")
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.rebuild(a.state)
        #expect(builder.scene.object(node) == nil)
    }

    @Test func typingRebuildsTheBlockAndAFontChangeRelaysItOut() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "Hi")
        let fonts = DocumentFontIndex(state: a.state)
        var builder = Self.builder(a.state, fonts: fonts)
        let before = try #require(builder.scene.object(node)?.bounds)
        let change = try #require(try a.perform(InsertText(node: node, text: " there", at: .end)))
        let (scene, summary) = builder.apply(change, state: a.state, origin: .local)
        let after = try #require(scene.object(node)?.bounds)
        #expect(after.width > before.width)
        #expect(summary.touchedNodes.contains(NodeID(node)))
        let (again, relaid) = builder.invalidate([node], state: a.state)
        #expect(again.object(node)?.bounds == after)
        #expect(relaid.touchedNodes.contains(NodeID(node)))
    }

    @Test func movingATextBlockWritesItsTransform() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "Move me", at: Point(x: 10, y: 20))
        try a.perform(MoveObjects([node], by: Vector(dx: 5, dy: -5)))
        #expect(Objects.transform(of: node, in: a.state) == AffineTransform.translation(x: 15, y: 15))
        #expect(Objects.isObject(node, in: a.state))
    }
}
