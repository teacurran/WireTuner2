import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// Paste Contents, Cut Contents, Choose clip path and release by Ungroup (OBJ-027,
/// clipping-paths.adoc).
@Suite struct ClippingTests {
    /// A closed path P (moved 7 pt right) and two rectangles A and B to paste inside it.
    static func fixture(on a: inout Replica) throws -> (path: OpID, contents: [OpID], layer: OpID) {
        let path = try LayerFixture.object(PathFixture.closed([(0, 0), (40, 0), (40, 40), (0, 40)]), on: &a)
        try a.perform(MoveObjects([path], by: Vector(dx: 7, dy: 0)))
        let first = try LayerFixture.object(LayerFixture.rect(on: nil, x: 5), on: &a)
        let second = try LayerFixture.object(LayerFixture.rect(on: nil, x: 20), on: &a)
        return (path, [first, second], Objects.parent(of: path, in: a.state)!)
    }

    /// Cuts `nodes` and returns their payload.
    static func cut(_ nodes: [OpID], on a: inout Replica) throws -> ClipboardPayload {
        let payload = ClipboardPayload(copying: nodes, from: a.state)
        try a.perform(CutObjects(nodes))
        return payload
    }

    static func bounds(_ nodes: [OpID], in state: EngineState) -> [Rect] {
        nodes.map { Objects.bounds(of: $0, in: state)! }
    }

    @Test func pasteContentsOnAPlainPathBuildsTheClipGroup() throws {
        var a = Replica(0xA)
        let (path, contents, layer) = try Self.fixture(on: &a)
        let before = Self.bounds(contents, in: a.state)
        let pathTransform = Objects.pasteboardTransform(of: path, in: a.state)
        let payload = try Self.cut(contents, on: &a)
        #expect(PasteContents.accepts(path, in: a.state))
        let change = try #require(try a.perform(PasteContents(payload, into: path)))
        #expect(change.label == "Paste contents")
        let group = change.createdObjects[0]
        #expect(Objects.parent(of: group, in: a.state) == layer)
        #expect(a.state.liveChildren(layer) == [group])
        #expect(ClipGroups.isClipGroup(group, in: a.state))
        #expect(ClipGroups.clipPath(of: group, in: a.state) == path)
        #expect(Objects.transform(of: group, in: a.state) == .identity)
        let children = a.state.liveChildren(group)
        #expect(children.count == 3 && children[0] == path)
        let pasted = ClipGroups.contents(of: group, in: a.state)
        #expect(pasted == Array(children.dropFirst()))
        #expect(Self.bounds(pasted, in: a.state) == before)
        #expect(Objects.pasteboardTransform(of: path, in: a.state) == pathTransform)
        // Undo takes the whole paste back.
        a.undo()
        #expect(Objects.parent(of: path, in: a.state) == layer && !a.state.isLive(group))
    }

    @Test func pasteContentsOnAClipGroupAppendsOnTopOfTheContents() throws {
        var a = Replica(0xA)
        let (path, contents, _) = try Self.fixture(on: &a)
        let group = try a.perform(PasteContents(try Self.cut([contents[0]], on: &a), into: path))!.createdObjects[0]
        try a.perform(TransformObjects([group], matrix: .scale(2), about: Point(x: 0, y: 0), kind: .scale))
        let before = Self.bounds([contents[1]], in: a.state)
        let change = try #require(try a.perform(PasteContents(try Self.cut([contents[1]], on: &a), into: group)))
        let added = change.createdRoots
        #expect(a.state.liveChildren(group).count == 3)
        #expect(a.state.liveChildren(group).last == added[0])
        #expect(Self.bounds(added, in: a.state) == before)
        // Pasting with the clip path itself selected goes into its group too.
        let third = try LayerFixture.object(LayerFixture.rect(on: nil, x: 90), on: &a)
        try a.perform(PasteContents(try Self.cut([third], on: &a), into: path))
        #expect(a.state.liveChildren(group).count == 4)
        #expect(ClipGroups.target(path, in: a.state) == group)
    }

    @Test func cutContentsRestoresAPlainPathWithTheGroupMatrixBaked() throws {
        var a = Replica(0xA)
        let (path, contents, layer) = try Self.fixture(on: &a)
        let below = try LayerFixture.object(LayerFixture.rect(on: nil, x: 200), on: &a)
        try a.perform(Arrange([below], .sendToBack))
        let group = try a.perform(PasteContents(try Self.cut(contents, on: &a), into: path))!.createdObjects[0]
        try a.perform(TransformObjects([group], matrix: .rotation(radians: 0.4), about: Point(x: 3, y: 3), kind: .rotate))
        let seen = Objects.pasteboardTransform(of: path, in: a.state)
        let payload = try #require(CutContents.payload(of: group, in: a.state))
        #expect(payload.nodes.count == 2)
        #expect(CutContents.payload(of: path, in: a.state)?.nodes.count == 2)
        let change = try #require(try a.perform(CutContents(group)))
        #expect(change.label == "Cut contents")
        #expect(Objects.parent(of: path, in: a.state) == layer)
        #expect(a.state.liveChildren(layer) == [below, path])
        #expect(nearly(Objects.pasteboardTransform(of: path, in: a.state), seen))
        #expect(!a.state.isLive(group))
        #expect(ClipGroups.contents(of: group, in: a.state).isEmpty)
        #expect(CutContents.payload(of: path, in: a.state) == nil)
        #expect(try a.perform(CutContents(path)) == nil)
    }

    @Test func aDeletedClipPathUnclipsUntilAnotherIsChosen() throws {
        var a = Replica(0xA)
        let (path, contents, _) = try Self.fixture(on: &a)
        let group = try a.perform(PasteContents(try Self.cut(contents, on: &a), into: path))!.createdObjects[0]
        let pasted = ClipGroups.contents(of: group, in: a.state)
        try a.perform(DeleteObjectsForClipTest([path]))
        #expect(ClipGroups.clipPath(of: group, in: a.state) == nil)
        #expect(ClipGroups.contents(of: group, in: a.state) == pasted)
        // A rectangle content can clip; choosing it is one register write.
        let change = try #require(try a.perform(ChooseClipPath(group, path: pasted[0])))
        #expect(change.label == "Choose clip path" && change.ops.count == 1)
        #expect(ClipGroups.clipPath(of: group, in: a.state) == pasted[0])
        // Not a child, or not a clip group: refused.
        let outside = try LayerFixture.object(LayerFixture.rect(on: nil, x: 300), on: &a)
        #expect(try a.perform(ChooseClipPath(group, path: outside)) == nil)
        #expect(try a.perform(ChooseClipPath(outside, path: pasted[1])) == nil)
        // Cutting the contents of a group with no clip path deletes the group and the contents.
        try a.perform(DeleteObjectsForClipTest([pasted[0]]))
        #expect(ClipGroups.clipPath(of: group, in: a.state) == nil)
        try a.perform(CutContents(group))
        #expect(!a.state.isLive(group) && !a.state.isLive(pasted[1]))
    }

    @Test func onlyClosedShapesTakeContents() throws {
        var a = Replica(0xA)
        let open = try LayerFixture.object(PathFixture.open([(0, 0), (10, 10)]), on: &a)
        let text = try LayerFixture.object(CreateTextBlock(.point(Point(x: 0, y: 0)), text: "Hi"), on: &a)
        let ellipse = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 8, height: 8)), on: &a)
        let empty = try LayerFixture.object(CreatePath(contours: []), on: &a)
        let locked = try LayerFixture.object(PathFixture.closed([(0, 0), (4, 0), (4, 4)]), on: &a)
        let plain = try a.perform(GroupObjects([try LayerFixture.object(LayerFixture.rect(on: nil, x: 60), on: &a)]))!.createdObjects[0]
        try a.perform(SetLocked([locked], locked: true))
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil, x: 90), on: &a)
        let payload = ClipboardPayload(copying: [rect], from: a.state)
        for node in [open, text, empty, locked, plain] {
            #expect(!PasteContents.accepts(node, in: a.state))
            #expect(try a.perform(PasteContents(payload, into: node)) == nil)
        }
        #expect(PasteContents.accepts(ellipse, in: a.state))
        #expect(try a.perform(PasteContents(ClipboardPayload(nodes: []), into: ellipse)) == nil)
        #expect(!ClipGroups.canClip(OpID(counter: 999, replica: 9), in: a.state))
        #expect(ClipGroups.clipPath(of: plain, in: a.state) == nil)
        #expect(ClipGroups.target(rect, in: a.state) == nil)
    }

    @Test func ungroupReleasesAClipGroup() throws {
        var a = Replica(0xA)
        let (path, contents, layer) = try Self.fixture(on: &a)
        let group = try a.perform(PasteContents(try Self.cut(contents, on: &a), into: path))!.createdObjects[0]
        let pasted = ClipGroups.contents(of: group, in: a.state)
        try a.perform(MoveObjects([group], by: Vector(dx: 0, dy: 9)))
        let before = Self.bounds([path] + pasted, in: a.state)
        try a.perform(Ungroup([group]))
        #expect(!a.state.isLive(group))
        #expect(a.state.liveChildren(layer) == [path] + pasted)
        #expect(Self.bounds([path] + pasted, in: a.state) == before)
    }

    @Test func aClipPathNamingANonChildReadsUnclipped() throws {
        var a = Replica(0xA)
        let (path, contents, _) = try Self.fixture(on: &a)
        let group = try a.perform(GroupObjects(contents))!.createdObjects[0]
        var clip = Wiretuner_Doc_V1_NodeProps()
        clip.group.kind = .clip
        clip.group.clipPath.id = path.proto
        try a.perform(OpsCommand("clip", ops: [Ops.set(group, [RegisterPath([50, 2]), ClipGroups.clipPathField], values: clip)]))
        #expect(ClipGroups.isClipGroup(group, in: a.state))
        #expect(ClipGroups.clipPath(of: group, in: a.state) == nil)
        #expect(ClipGroups.contents(of: group, in: a.state) == contents)
    }
}

/// A plain deletion of objects (the Delete key's document half) for the clip tests.
struct DeleteObjectsForClipTest: Command {
    var nodes: [OpID]
    var label: String { "Clear" }

    init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in nodes { builder.append(Ops.setDeleted(node)) }
    }
}

/// OBJ-027's merge tests.
@Suite struct ClippingMergeTests {
    @Test func concurrentPasteContentsIntoOnePathLeavesOneGroupDangling() throws {
        var pair = Pair()
        let (path, contents, _) = try ClippingTests.fixture(on: &pair.a)
        pair.sync()
        let groupA = try pair.a.perform(PasteContents(ClipboardPayload(copying: [contents[0]], from: pair.a.state), into: path))!.createdObjects[0]
        let groupB = try pair.b.perform(PasteContents(ClipboardPayload(copying: [contents[1]], from: pair.b.state), into: path))!.createdObjects[0]
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let owner = try #require(Objects.parent(of: path, in: pair.a.state))
        #expect(owner == groupA || owner == groupB)
        let other = owner == groupA ? groupB : groupA
        #expect(ClipGroups.clipPath(of: owner, in: pair.a.state) == path)
        #expect(ClipGroups.clipPath(of: other, in: pair.a.state) == nil)
        #expect(ClipGroups.contents(of: other, in: pair.a.state).count == 1)
    }

    @Test func cutContentsVersusARemoteContentEditKeepsTheEditOnTheDeletedContent() throws {
        var pair = Pair()
        let (path, contents, _) = try ClippingTests.fixture(on: &pair.a)
        let group = try pair.a.perform(PasteContents(try ClippingTests.cut(contents, on: &pair.a), into: path))!.createdObjects[0]
        pair.sync()
        let content = ClipGroups.contents(of: group, in: pair.b.state)[0]
        try pair.b.perform(MoveObjects([content], by: Vector(dx: 3, dy: 0)))
        try pair.a.perform(CutContents(group))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(!pair.a.state.isLive(content))
        #expect(pair.a.state.register(content, CommonFields.transform(.rect))?.op.replica == 0xB)
    }

    @Test func aRemotelyDeletedClipPathReadsUnclipped() throws {
        var pair = Pair()
        let (path, contents, _) = try ClippingTests.fixture(on: &pair.a)
        let group = try pair.a.perform(PasteContents(try ClippingTests.cut(contents, on: &pair.a), into: path))!.createdObjects[0]
        pair.sync()
        try pair.b.perform(DeleteObjectsForClipTest([path]))
        try pair.a.perform(ChooseClipPath(group, path: path))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(pair.a.state.register(group, ClipGroups.clipPathField)?.op.replica == 0xA)
        #expect(ClipGroups.clipPath(of: group, in: pair.a.state) == nil)
        #expect(ClipGroups.contents(of: group, in: pair.a.state).count == 2)
    }
}
