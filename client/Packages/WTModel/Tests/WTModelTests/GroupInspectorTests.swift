import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// OBJ-017: the group inspector's *Transform as unit* toggle and *Contents* row, and the scene's
/// two stroke-generation modes; OBJ-038's check that smart guides write nothing.
@Suite struct GroupInspectorTests {
    /// Two stroked rectangles grouped and scaled 300% about the origin.
    static func scaledGroup(on a: inout Replica) throws -> (group: OpID, members: [OpID]) {
        let members = try ArrangeTests.row(2, on: &a)
        let group = try a.perform(GroupObjects(members))!.createdObjects[0]
        try a.perform(TransformObjects([group], matrix: .scale(3), about: .zero, kind: .scale))
        return (group, members)
    }

    /// The widths of the strokes the scene draws for `group`'s members.
    static func strokeWidths(of group: OpID, in scene: DocumentScene) -> [Double] {
        func widths(_ item: DisplayItem) -> [Double] {
            switch item {
            case .path(let path): return path.appearance.items.compactMap { if case .stroke(let s) = $0 { s.style.width } else { nil } }
            case .stroke(let stroke): return [stroke.style.width]
            case .group(let inner): return inner.children.flatMap(widths)
            default: return []
            }
        }
        return scene.object(group).map { widths($0.item) } ?? []
    }

    @Test func aScaledGroupStrokesAtNominalWidthUntilTransformAsUnit() throws {
        var a = Replica(0xA)
        let (group, members) = try Self.scaledGroup(on: &a)
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let before = builder.rebuild(a.state)
        let nominal = Self.strokeWidths(of: group, in: before)
        #expect(nominal.count == 2)
        // 1 pt members under a 300% matrix: stroked at 1/3 in member space, 1 pt on the page.
        #expect(nominal.allSatisfy { abs($0 - 1.0 / 3) < 1e-9 })
        #expect(!GroupInspector.transformsAsUnit(group, in: a.state))

        let change = try #require(try a.perform(SetTransformAsUnit([group], asUnit: true)))
        #expect(change.label == "Transform as unit")
        #expect(change.ops.count == 1)
        #expect(GroupInspector.transformsAsUnit(group, in: a.state))
        let (scene, summary) = builder.apply(change, state: a.state, origin: .local)
        #expect(Self.strokeWidths(of: group, in: scene).allSatisfy { abs($0 - 1) < 1e-9 })
        // One register written; only the group's tiles repaint: the summary names the group and
        // its members (drawn from it), all within the group's painted bounds.
        #expect(summary.touchedNodes == Set(([group] + members).map(NodeID.init)))
        #expect(!summary.isStructural)
        let area = try #require(scene.object(group)?.bounds)
        #expect(summary.bounds.values.compactMap(\.new?.rect).allSatisfy { area.contains($0) })
        // Already set, locked, or not a group: nothing to write.
        #expect(try a.perform(SetTransformAsUnit([group], asUnit: true)) == nil)
        #expect(try a.perform(SetTransformAsUnit([members[0]], asUnit: true)) == nil)
        #expect(SetTransformAsUnit([group, members[0]], asUnit: false).label == "Transform as unit of 2 objects")
        a.undo()
        #expect(!GroupInspector.transformsAsUnit(group, in: a.state))
    }

    @Test func contentsAreTheLiveMembersLessAClipPath() throws {
        var a = Replica(0xA)
        let n = try ArrangeTests.row(4, on: &a)
        let group = try a.perform(GroupObjects([n[0], n[1], n[2]]))!.createdObjects[0]
        try a.perform(OpsCommand("Delete", ops: [Ops.setDeleted(n[1])]))
        #expect(GroupInspector.contents(of: group, in: a.state) == [n[0], n[2]])
        var clip = Wiretuner_Doc_V1_NodeProps()
        clip.group.kind = .clip
        clip.group.clipPath.id = n[0].proto
        try a.perform(OpsCommand("clip", ops: [Ops.set(group, [RegisterPath([50, 2]), RegisterPath([50, 4])], values: clip)]))
        #expect(GroupInspector.contents(of: group, in: a.state) == [n[2]])
        #expect(GroupInspector.contents(of: n[3], in: a.state).isEmpty)
        try a.perform(OpsCommand("Delete", ops: [Ops.setDeleted(group)]))
        #expect(GroupInspector.contents(of: group, in: a.state).isEmpty)
    }

    /// OBJ-038: building the engine from the scene and querying it changes nothing -- no change
    /// in the outbox, the same state.
    @Test func smartGuidesWriteNothing() throws {
        var a = Replica(0xA)
        let n = try ArrangeTests.row(3, on: &a)
        let sent = a.sent.count
        let hash = a.state.stateHash
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(a.state)
        let engine = SmartGuideEngine(displayList: scene.displayList, viewport: Rect(x: -100, y: -100, width: 400, height: 400),
                                      excludedNodes: [NodeID(n[2])], start: .zero)
        #expect(engine.candidates.compactMap(\.node) == [NodeID(n[0]), NodeID(n[1])])
        let moving = try #require(scene.object(n[2])?.bounds)
        let match = engine.guides(moving: moving.offset(by: Vector(dx: 0.5, dy: 0)), tolerance: 1)
        #expect(!match.guides.isEmpty)
        #expect(a.sent.count == sent && a.state.stateHash == hash)
    }
}
