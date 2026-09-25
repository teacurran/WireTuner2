import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// FX-041's scene hook: a `perspective` wrapper (kind 103) drawn by `DocumentScene` as a live
/// group through `PerspectiveReading.live` and `drawOrder`.
@Suite struct PerspectiveSceneTests {
    static func scene(_ state: EngineState) -> DocumentScene {
        var builder = DocumentDisplayListBuilder(canvas: "c")
        return builder.rebuild(state)
    }

    @Test func anAttachedObjectDrawsProjected() throws {
        var a = Replica(0xA)
        let (object, wrapper) = try PerspectiveCommandTests.attached(on: &a)
        #expect(WrapperKind.of(wrapper, in: a.state) == .perspective && WrapperKind.perspective.nodeKind == .perspective)
        #expect(NodeKind(rawValue: 103) == .perspective && NodeKind.perspective.title == "Perspective Object")
        let scene = Self.scene(a.state)
        let drawn = try #require(scene.object(wrapper))
        #expect(drawn.kind == .perspective && scene.object(object)?.parent == wrapper && scene.topLevel.contains(NodeID(wrapper)))
        guard case .group(let group) = drawn.item, case .perspective(let spec)? = group.live else { Issue.record("a live perspective group"); return }
        #expect(spec == PerspectiveReading.spec(wrapper, in: a.state) && group.children.count == 1)
        // Projected, not flat: the drawing is not the square's own rectangle.
        let flat = try #require(Objects.bounds(of: object, in: a.state))
        let projected = try #require(drawn.item.bounds)
        #expect(!(abs(projected.minX - flat.minX) < 1e-6 && abs(projected.width - flat.width) < 1e-6))
        // The same drawing Release with Perspective bakes from.
        #expect(PerspectiveBaking.item(wrapper, in: a.state)?.bounds == projected)
    }

    @Test func extraChildrenDrawFlatAboveAndAnEmptyWrapperDrawsNothing() throws {
        var a = Replica(0xA)
        let (object, wrapper) = try PerspectiveCommandTests.attached(on: &a)
        let second = try LayerFixture.object(LayerFixture.rect(on: nil, x: 300, size: 10), on: &a)
        try a.perform(OpsCommand("Move in", ops: [Ops.move(second, parent: wrapper, position: [0x01])]))
        #expect(Wrappers.drawOrder(wrapper, .perspective, in: a.state) == [object, second])
        let scene = Self.scene(a.state)
        #expect(scene.object(object)?.itemPath.last == 0 && scene.object(second)?.itemPath.last == 1)
        try a.perform(OpsCommand("Delete", ops: [Ops.setDeleted(object), Ops.setDeleted(second)]))
        #expect(Self.scene(a.state).object(wrapper) == nil)
    }

    @Test func aGridEditRepaintsTheAttachedObjects() throws {
        var a = Replica(0xA)
        try a.perform(DefineGrid(name: "Street"))
        let grid = try #require(PerspectiveReading.grids(a.state).first?.id)
        let (_, wrapper) = try PerspectiveCommandTests.attached(on: &a)
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let before = try #require(builder.rebuild(a.state).object(wrapper)?.bounds)
        let change = try #require(try a.perform(EditGrid(grid, label: "Move vanishing point", fields: [.leftVP]) { $0.leftVp.x = -400 }))
        let (scene, summary) = builder.apply(change, state: a.state, origin: .local)
        #expect(summary.touchedNodes.contains(NodeID(wrapper)))
        #expect(scene.object(wrapper)?.bounds != before)
    }
}
