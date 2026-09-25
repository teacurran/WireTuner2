import CoreGraphics
import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender
import WTText

/// Clip-group rendering, hit testing and the contents handle (OBJ-028, clipping-paths.adoc).
@Suite struct ClipRenderingTests {
    /// P: a 40 pt square at (10, 10) filled red with a 4 pt black stroke; contents: a blue square
    /// from (0, 0) to (60, 60) that sticks out of P on every side.  Returns the clip group, P and
    /// the content.
    static func fixture(on a: inout Replica) throws -> (group: OpID, clip: OpID, content: OpID) {
        var look = Wiretuner_Doc_V1_AppearanceProps()
        look.fills = [Appearances.basicFill(red: 1, green: 0, blue: 0)]
        look.strokes = [.with { stroke in
            stroke.settings.kind = .basic
            stroke.settings.basic.color = Appearances.inline(red: 0, green: 0, blue: 0)
            stroke.settings.basic.width = 4
        }]
        let clip = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 40, height: 40), transform: .translation(x: 10, y: 10),
                                                       appearance: look), on: &a)
        var blue = Wiretuner_Doc_V1_AppearanceProps()
        blue.fills = [Appearances.basicFill(red: 0, green: 0, blue: 1)]
        let content = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 60, height: 60), appearance: blue), on: &a)
        let payload = try ClippingTests.cut([content], on: &a)
        let group = try a.perform(PasteContents(payload, into: clip))!.createdObjects[0]
        let pasted = ClipGroups.contents(of: group, in: a.state)[0]
        return (group, clip, pasted)
    }

    /// The RGBA pixel at pasteboard `point` of the scene drawn at 1× over (−10, −10)…(70, 70).
    static func pixel(_ state: EngineState, _ point: Point) -> [UInt8] {
        let bytes = CombineCommandTests.pixels(state, region: Rect(x: -10, y: -10, width: 80, height: 80))
        let x = Int((point.x + 10) * 2), y = Int((point.y + 10) * 2)
        let index = (y * 160 + x) * 4
        return Array(bytes[index..<index + 4])
    }

    static func isBlue(_ p: [UInt8]) -> Bool { p[2] > 200 && p[0] < 40 && p[3] > 200 }
    static func isBlack(_ p: [UInt8]) -> Bool { p[0] < 40 && p[1] < 40 && p[2] < 40 && p[3] > 200 }
    static func isClear(_ p: [UInt8]) -> Bool { p[3] < 20 }

    @Test func fillsThenClippedContentsThenStrokes() throws {
        var a = Replica(0xA)
        let (group, clip, content) = try Self.fixture(on: &a)
        #expect(Self.isClear(Self.pixel(a.state, Point(x: 3, y: 3))), "contents outside the clip do not draw")
        #expect(Self.isBlue(Self.pixel(a.state, Point(x: 30, y: 30))), "contents draw over the clip path's fill")
        #expect(Self.isBlack(Self.pixel(a.state, Point(x: 10, y: 30))), "the stroke draws over the contents")
        #expect(Self.isBlack(Self.pixel(a.state, Point(x: 8.5, y: 30))), "unclipped: its outer half too")
        var scene = DocumentDisplayListBuilder(canvas: "test")
        let built = scene.rebuild(a.state)
        let top = try #require(built.object(group)?.itemPath)
        #expect(built.object(content)?.itemPath == top + [ClipRendering.contents, 0])
        #expect(built.object(clip)?.itemPath == top + [ClipRendering.above])
        #expect(built.object(atItemPath: top + [ClipRendering.below])?.id == clip, "the fill part stands for the clip path")
    }

    @Test func aDeletedClipPathLeavesTheContentsUnclipped() throws {
        var a = Replica(0xA)
        let (group, clip, _) = try Self.fixture(on: &a)
        try a.perform(DeleteNodes([clip]))
        #expect(ClipRendering.clipPath(of: group, in: a.state) == nil)
        #expect(Self.isBlue(Self.pixel(a.state, Point(x: 3, y: 3))))
        // A clip group whose contents are all gone draws as its clip path.
        var b = Replica(0xB)
        let (other, otherClip, content) = try Self.fixture(on: &b)
        try b.perform(DeleteNodes([content]))
        #expect(ClipRendering.clipPath(of: other, in: b.state) == nil)
        var scene = DocumentDisplayListBuilder(canvas: "test")
        let built = scene.rebuild(b.state)
        #expect(built.object(otherClip)?.itemPath == built.object(other)!.itemPath + [0])
    }

    @Test @MainActor func clippedTextAndBitmapContentsSitInsideTheClip() throws {
        var a = Replica(0xA)
        let (group, _, _) = try Self.fixture(on: &a)
        var image = Wiretuner_Doc_V1_NodeProps()
        image.image.dpiX = 72
        image.image.dpiY = 72
        let layer = try #require(Objects.parent(of: group, in: a.state))
        let bitmap = try a.perform(OpsCommand("Image", ops: [Ops.create(parent: layer, position: [0xF0], props: image)]))!.createdNodes[0]
        let text = try TextFixture.block(&a, "Clipped", at: Point(x: 12, y: 30))
        try a.perform(PasteContents(try ClippingTests.cut([bitmap], on: &a), into: group))
        try a.perform(OpsCommand("Into the clip", ops: [Ops.move(text, parent: group, position: [0xFE])]))
        var scene = DocumentDisplayListBuilder(canvas: "test")
        let fonts = DocumentFontIndex(state: a.state)
        scene.textLayout = TextSceneLayout(engine: fonts.layoutEngine)
        let built = scene.rebuild(a.state)
        guard case .group(let item)? = built.object(group)?.item, case .group(let inner) = item.children[ClipRendering.contents] else {
            Issue.record("a clip group draws three slots")
            return
        }
        #expect(inner.clip != nil && inner.transform == .translation(x: 10, y: 10))
        #expect(inner.children.count == 3)
        #expect(inner.children.contains { if case .image = $0 { true } else { false } })
        let clipped = try #require(built.object(group)?.bounds)
        #expect(clipped.minX > 1 && clipped.maxX < 59, "the contents (0...80) are cut to the clip path and its stroke")
    }

    @Test func splitSendsFillsBelowAndStrokesAndEffectsAbove() {
        let fill = AppearanceItem.fill(FillPaint(paint: .solid(.black)))
        let stroke = AppearanceItem.stroke(StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 1)))
        let shadow = EffectElement(.unsupported, target: .element(1))
        let glow = EffectElement(.unsupported, target: .element(0))
        let whole = EffectElement(.unsupported, target: .object)
        let item = DisplayItem.path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)),
                                             appearance: Appearance([fill, stroke], effects: [shadow, glow, whole])))
        let (below, above) = ClipRendering.split(item)
        guard case .path(let low)? = below, case .path(let high)? = above else {
            Issue.record("both parts draw")
            return
        }
        #expect(low.appearance.items == [fill] && low.appearance.effects.map(\.target) == [.element(0)])
        #expect(high.appearance.items == [stroke] && high.appearance.effects.map(\.target) == [.element(0), .object])
        let group = DisplayItem.group(GroupItem(children: []))
        #expect(ClipRendering.split(group).below == nil && ClipRendering.split(group).above == group)
        let bare = DisplayItem.path(PathItem(path: DisplayPath(), appearance: Appearance([fill])))
        #expect(ClipRendering.split(bare).above == nil)
    }

    @Test func contentsHitOnlyInsideTheClipAndTheStrokeHitsTheGroup() throws {
        var a = Replica(0xA)
        let (group, clip, content) = try Self.fixture(on: &a)
        var scene = DocumentDisplayListBuilder(canvas: "test")
        let built = scene.rebuild(a.state)
        let viewport = Viewport(zoom: 1, size: Size(width: 200, height: 200))
        let subselect = HitTester(displayList: built.displayList, viewport: viewport, options: HitOptions(subselect: true))
        let outside = subselect.hitTest(viewPoint: Point(x: 3, y: 3)).compactMap { built.object(atItemPath: $0.itemPath)?.id }
        #expect(!outside.contains(content), "a content outside the clip region is not selected")
        let inside = subselect.hitTest(viewPoint: Point(x: 30, y: 30)).compactMap { built.object(atItemPath: $0.itemPath)?.id }
        #expect(inside.first == content)
        let onStroke = subselect.hitTest(viewPoint: Point(x: 10, y: 30)).compactMap { built.object(atItemPath: $0.itemPath)?.id }
        #expect(onStroke.first == clip)
        let pointer = HitTester(displayList: built.displayList, viewport: viewport)
        #expect(pointer.hitTest(viewPoint: Point(x: 10, y: 30)).compactMap { built.object(atItemPath: $0.itemPath)?.id }.first == group)
        #expect(pointer.hitTest(viewPoint: Point(x: 3, y: 3)).isEmpty)
    }

    @Test func draggingTheContentsHandleMovesTheContentsInOneChange() throws {
        var a = Replica(0xA)
        let (group, clip, content) = try Self.fixture(on: &a)
        var scene = DocumentDisplayListBuilder(canvas: "test")
        let built = scene.rebuild(a.state)
        let handle = try #require(ContentsHandle.position(of: group, in: built, state: a.state))
        #expect(handle == Point(x: 30, y: 30))
        #expect(ContentsHandle.hits(Point(x: 31, y: 30), handle: handle, tolerance: 3))
        #expect(!ContentsHandle.hits(Point(x: 40, y: 30), handle: handle, tolerance: 3))
        #expect(ContentsHandle.position(of: clip, in: built, state: a.state) == nil)
        let clipBefore = Objects.transform(of: clip, in: a.state)
        let change = try #require(try a.perform(MoveContents(group, by: Vector(dx: 5, dy: -2))))
        #expect(change.label == "Move contents")
        #expect(Objects.transform(of: clip, in: a.state) == clipBefore, "P stays in place")
        #expect(Objects.transform(of: content, in: a.state) == .translation(x: 5, y: -2))
        #expect(try a.perform(MoveContents(group, by: .zero)) == nil)
        #expect(try a.perform(MoveContents(clip, by: Vector(dx: 1, dy: 1))) == nil)
        a.undo()
        #expect(Objects.transform(of: content, in: a.state) == .identity)
    }
}
