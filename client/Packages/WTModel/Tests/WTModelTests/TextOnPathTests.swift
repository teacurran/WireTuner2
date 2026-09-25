import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender
import WTText

/// TYPE-041: attaching text to a path, flowing it inside and detaching, the read-time
/// normalizations, and text on a path drawn in the scene.
@Suite @MainActor struct TextOnPathTests {
    /// A text block and an open arc-like path to its right; returns both.
    static func pair(_ replica: inout Replica, closed: Bool = false) throws -> (text: OpID, path: OpID) {
        let text = try TextFixture.block(&replica, "Around", at: Point(x: 10, y: 20))
        let coordinates: [(Double, Double)] = closed ? [(100, 100), (300, 100), (300, 300), (100, 300)] : [(100, 200), (200, 100), (300, 200)]
        let path = try LayerFixture.object(CreatePath(contours: [NewContour(closed: closed, points: PathFixture.points(coordinates))]), on: &replica)
        return (text, path)
    }

    static func item(_ node: OpID, _ state: EngineState) -> DisplayItem? {
        let fonts = DocumentFontIndex(state: state)
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.textLayout = TextSceneLayout(engine: fonts.layoutEngine)
        return builder.rebuild(state).object(node)?.item
    }

    /// The origins of the glyph runs `item` draws.
    static func glyphs(_ item: DisplayItem?) -> [TextRunItem] {
        guard case .group(let group)? = item else { return [] }
        return group.children.compactMap { if case .text(let run) = $0 { run } else { nil } }
    }

    static func paths(_ item: DisplayItem?) -> Int {
        guard case .group(let group)? = item else { return 0 }
        return group.children.filter { if case .path = $0 { true } else { false } }.count
    }

    @Test func attachMovesThePathUnderTheTextAndWritesOnPath() throws {
        var a = Replica(0xA)
        let (text, path) = try Self.pair(&a)
        #expect(AttachTextToPath.pair([path, text], in: a.state)! == (text, path))
        #expect(AttachTextToPath.pair([text, path], in: a.state)! == (text, path))
        #expect(AttachTextToPath.pair([text], in: a.state) == nil && AttachTextToPath.pair([path, path], in: a.state) == nil)
        let change = try #require(try a.perform(AttachTextToPath(text: text, path: path)))
        #expect(change.label == "Attach to path")
        #expect(Objects.parent(of: path, in: a.state) == text)
        let onPath = a.state.props(text).text.onPath
        #expect(onPath.mode == .along && onPath.orientation == .rotate && onPath.top == .baseline && onPath.bottom == .baseline && !onPath.showPath)
        // The path keeps its place on the page: under the text it carries the inverse of the text's move.
        #expect(Objects.pasteboardTransform(of: path, in: a.state).isIdentity)
        #expect(Objects.transform(of: path, in: a.state) == AffineTransform.translation(x: -10, y: -20))
        let node = try #require(TextNode(text, in: a.state))
        #expect(TextLayoutReading.path(of: node, in: a.state) == path)
        let spec = try #require(TextLayoutReading.pathText(node, in: a.state))
        #expect(spec.mode == .along && spec.orientation == .rotate && spec.top == .baseline && spec.transform == .translation(x: 10, y: 20))
        #expect(spec.contour.startPoint == Point(x: 90, y: 180) && !spec.contour.isClosed)
        guard case .path = TextLayoutReading.container(node, state: a.state) else { Issue.record("a path container"); return }
        guard case .block = TextLayoutReading.container(node) else { Issue.record("a block without the state"); return }
        // Undo detaches.
        a.undo()
        #expect(Objects.parent(of: path, in: a.state) != text && !a.state.props(text).text.hasOnPath)
        try a.perform(AttachTextToPath(text: text, path: path))
        // Attaching again is refused, as are wrong kinds.
        let other = try LayerFixture.object(PathFixture.open([(0, 0), (5, 5)]), on: &a)
        #expect(throws: TextOnPathError.alreadyOnPath(text)) { try a.perform(AttachTextToPath(text: text, path: other)) }
        #expect(throws: TextOnPathError.notText(other)) { try a.perform(AttachTextToPath(text: other, path: other)) }
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil, x: 0, size: 10), on: &a)
        let second = try TextFixture.block(&a, "x")
        #expect(throws: TextOnPathError.notAPath(rect)) { try a.perform(AttachTextToPath(text: second, path: rect)) }
    }

    @Test func textOnAPathDrawsAlongIt() throws {
        var a = Replica(0xA)
        let (text, path) = try Self.pair(&a)
        let flat = Self.glyphs(Self.item(text, a.state))
        #expect(!flat.isEmpty)
        try a.perform(AttachTextToPath(text: text, path: path))
        let item = Self.item(text, a.state)
        let along = Self.glyphs(item)
        #expect(!along.isEmpty && Self.paths(item) == 0, "the path is hidden until Show path")
        // The glyphs sit on the path (from x 100 upward and to the right), not on the block's line.
        let first = try #require(along.first)
        let origin = first.transform.apply(first.origin)
        #expect(origin.x > 95 && origin.x < 140 && origin.y > 150 && origin.y < 205)
        let positions = try #require(first.glyphRun?.glyphs.map(\.position))
        #expect(positions.count == 6 && Set(positions.map(\.y)).count == 6 && positions[5].y < positions[0].y, "the glyphs climb the curve")
        // Show path draws the path under the glyphs.
        try a.perform(OpsCommand("Show path", ops: [Ops.set(text, [TextOnPathFields.onPath.child(3)], values: .with { $0.text.onPath.showPath = true })]))
        let shown = Self.item(text, a.state)
        guard case .group(let group)? = shown, case .path(let drawnPath)? = group.children.first else { Issue.record("the path first"); return }
        #expect(DisplayItem.path(drawnPath).bounds.map { abs($0.minX - 100) <= 3 } == true)
    }

    @Test func flowInsideAndTheReadTimeNormalizations() throws {
        var a = Replica(0xA)
        let (text, path) = try Self.pair(&a, closed: true)
        let change = try #require(try a.perform(AttachTextToPath(text: text, path: path, mode: .inside)))
        #expect(change.label == "Flow inside path")
        let node = try #require(TextNode(text, in: a.state))
        #expect(TextLayoutReading.pathText(node, in: a.state)?.mode == .inside)
        #expect(!Self.glyphs(Self.item(text, a.state)).isEmpty)
        // Orientation and alignments map; unspecified alignments read None.
        try a.perform(OpsCommand("Settings", ops: [Ops.set(text, [TextOnPathFields.onPath.child(2), TextOnPathFields.onPath.child(4), TextOnPathFields.onPath.child(5)],
                                                           values: .with { $0.text.onPath.orientation = .skewVertical; $0.text.onPath.top = .ascent })]))
        var spec = try #require(TextLayoutReading.pathText(TextNode(text, in: a.state)!, in: a.state))
        #expect(spec.orientation == .skewVertical && spec.top == .ascent && spec.bottom == PathText.Alignment.none)
        try a.perform(OpsCommand("Settings", ops: [Ops.set(text, [TextOnPathFields.onPath.child(2), TextOnPathFields.onPath.child(4)],
                                                           values: .with { $0.text.onPath.orientation = .vertical; $0.text.onPath.top = .descent })]))
        spec = try #require(TextLayoutReading.pathText(TextNode(text, in: a.state)!, in: a.state))
        #expect(spec.orientation == .vertical && spec.top == .descent)
        try a.perform(OpsCommand("Settings", ops: [Ops.set(text, [TextOnPathFields.onPath.child(2)], values: .with { $0.text.onPath.orientation = .skewHorizontal })]))
        #expect(TextLayoutReading.pathText(TextNode(text, in: a.state)!, in: a.state)?.orientation == .skewHorizontal)
        // A second path child (concurrent attaches): the smaller id is the path, the other draws on top.
        let extra = try LayerFixture.object(PathFixture.open([(0, 0), (50, 50)]), on: &a)
        try a.perform(OpsCommand("Move in", ops: [Ops.move(extra, parent: text, position: [0xF0])]))
        #expect(TextLayoutReading.path(of: TextNode(text, in: a.state)!, in: a.state) == min(path, extra))
        #expect(Self.paths(Self.item(text, a.state)) == 1)
        // No live path child: a plain block.
        try a.perform(OpsCommand("Delete", ops: [Ops.setDeleted(path), Ops.setDeleted(extra)]))
        let plain = try #require(TextNode(text, in: a.state))
        #expect(TextLayoutReading.path(of: plain, in: a.state) == nil && TextLayoutReading.pathText(plain, in: a.state) == nil)
        #expect(!Self.glyphs(Self.item(text, a.state)).isEmpty)
        // A path child without a renderable contour: a plain block too.
        let empty = try LayerFixture.object(CreatePath(contours: [NewContour(points: PathFixture.points([(0, 0)]))]), on: &a)
        try a.perform(OpsCommand("Move in", ops: [Ops.move(empty, parent: text, position: [0xF8])]))
        #expect(TextLayoutReading.pathText(TextNode(text, in: a.state)!, in: a.state) == nil)
    }

    @Test func attachEditDetachRoundTrips() throws {
        var a = Replica(0xA)
        let (text, path) = try Self.pair(&a)
        let before = a.state.props(path).path
        try a.perform(AttachTextToPath(text: text, path: path))
        try a.perform(InsertText(node: text, text: "!", at: .end))
        let change = try #require(try a.perform(DetachTextFromPath([path])))
        #expect(change.label == "Detach from path")
        #expect(Objects.parent(of: path, in: a.state) == Objects.parent(of: text, in: a.state))
        #expect(!a.state.props(text).text.hasOnPath && TextNode(text, in: a.state)?.string == "Around!")
        #expect(a.state.props(path).path.contours == before.contours && Objects.transform(of: path, in: a.state).isIdentity, "the path is unchanged")
        #expect(Objects.transform(of: text, in: a.state) == .translation(x: 10, y: 20))
        #expect(a.state.props(text).text.block.width == 200 && !a.state.props(text).text.block.autoWidth, "as wide as the path")
        let siblings = a.state.liveChildren(Objects.parent(of: text, in: a.state)!)
        #expect(siblings.firstIndex(of: path)! < siblings.firstIndex(of: text)!, "just below the text")
        #expect(throws: TextOnPathError.notOnPath(text)) { try a.perform(DetachTextFromPath([text])) }
        try a.perform(SetLocked([text], locked: true))
        #expect(throws: TextOnPathError.notText(text)) { try a.perform(DetachTextFromPath([text])) }
        #expect(try a.perform(DetachTextFromPath([path])) == nil, "a path not on a text names nothing")
    }

    @Test func detachRemovesTransformsAppliedWhileJoined() throws {
        var a = Replica(0xA)
        let (text, path) = try Self.pair(&a)
        try a.perform(AttachTextToPath(text: text, path: path))
        try a.perform(OpsCommand("Rotate", ops: [Objects.setTransform(text, kind: .text, AffineTransform.rotation(radians: 0.5).concatenating(.translation(x: 10, y: 20)))]))
        try a.perform(DetachTextFromPath([text]))
        #expect(Objects.transform(of: text, in: a.state) == .translation(x: 10, y: 20))
        #expect(!Objects.transform(of: path, in: a.state).isIdentity, "the path stays where it was drawn")
    }

    // MARK: Merges

    @Test func attachVersusConcurrentPathDeleteFallsBackAndRestoreBringsItBack() throws {
        var pair = Pair()
        let (text, path) = try Self.pair(&pair.a)
        pair.sync()
        try pair.a.perform(AttachTextToPath(text: text, path: path))
        try pair.b.perform(DeleteNodes([path]))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        for replica in [pair.a, pair.b] {
            let node = try #require(TextNode(text, in: replica.state))
            #expect(node.props.hasOnPath && TextLayoutReading.path(of: node, in: replica.state) == nil, "a plain block")
        }
        // Restore (undo of the delete) brings the path back under the text: the attachment reappears.
        pair.b.undo()
        pair.sync()
        for replica in [pair.a, pair.b] {
            #expect(TextLayoutReading.path(of: TextNode(text, in: replica.state)!, in: replica.state) == path)
        }
    }

    @Test func twoReplicasAttachOnePathToDifferentTexts() throws {
        var pair = Pair()
        let (text, path) = try Self.pair(&pair.a)
        let other = try TextFixture.block(&pair.a, "Other", at: Point(x: 0, y: 400))
        pair.sync()
        try pair.a.perform(AttachTextToPath(text: text, path: path))
        try pair.b.perform(AttachTextToPath(text: other, path: path))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let state = pair.a.state
        let winners = [text, other].filter { TextLayoutReading.path(of: TextNode($0, in: state)!, in: state) == path }
        #expect(winners.count == 1, "one wins")
        let loser = winners[0] == text ? other : text
        #expect(state.props(loser).text.hasOnPath && TextLayoutReading.pathText(TextNode(loser, in: state)!, in: state) == nil, "the other is a plain block")
    }
}
