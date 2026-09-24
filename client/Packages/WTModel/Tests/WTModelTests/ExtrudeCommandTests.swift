import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// FX-017: extrude commands, the read-time normalizations and the extrusion in the scene.
@Suite struct ExtrudeCommandTests {
    static func square(_ replica: inout Replica, x: Double = 0) throws -> OpID {
        var appearance = Appearances.standard
        appearance.fills = [Appearances.basicFill(red: 1, green: 0, blue: 0)]
        return try LayerFixture.object(CreatePath(contours: [NewContour(closed: true, points: PathFixture.points([(x, 0), (x + 20, 0), (x + 20, 20), (x, 20)]))],
                                                  appearance: appearance), on: &replica)
    }

    static func wrapper(of node: OpID, _ state: EngineState) -> OpID? {
        state.store.placement(node).flatMap { WrapperKind.of($0.parent, in: state) == .extrude ? $0.parent : nil }
    }

    static func scene(_ state: EngineState) -> DocumentScene {
        var builder = DocumentDisplayListBuilder(canvas: "c")
        return builder.rebuild(state)
    }

    @Test func extrudeWrapsAndDraws() throws {
        var a = Replica(0xA)
        let path = try Self.square(&a)
        let change = try a.perform(Extrude([path], length: 40, vanishingPoint: Point(x: 200, y: 200)))!
        #expect(change.label == "Extrude")
        let wrapper = try #require(Self.wrapper(of: path, a.state))
        let props = a.state.props(wrapper).extrude
        #expect(props.length == 40 && props.vanishingPoint.x == 200 && props.surface.kind == .shaded)
        #expect(ExtrudeReading.child(wrapper, in: a.state) == path && ExtrudeReading.title(wrapper, in: a.state) == "Extrusion")
        // The scene draws a live extrusion over the child; the child stays an object of its own.
        let scene = Self.scene(a.state)
        guard case .group(let group)? = scene.object(wrapper)?.item, case .extrude(let spec)? = group.live else { Issue.record("no extrusion"); return }
        #expect(spec.length == 40 && spec.surface == .shaded && group.children.count == 1)
        #expect(scene.object(path)?.parent == wrapper && scene.object(wrapper)?.kind == .extrude && WrapperKind.extrude.nodeKind == .extrude)
        // No nesting.
        #expect(throws: WrapperError.nestedExtrusion(path)) { try a.perform(Extrude([path], vanishingPoint: .zero)) }
        let other = try Self.square(&a, x: 50)
        let group2 = try a.perform(GroupObjects([other]))!.createdObjects[0]
        try a.perform(Extrude([other], vanishingPoint: .zero))
        #expect(throws: WrapperError.nestedExtrusion(group2)) { try a.perform(Extrude([group2], vanishingPoint: .zero)) }
        #expect(ExtrudeReading.isInsideExtrusion(other, in: a.state) && !ExtrudeReading.isInsideExtrusion(group2, in: a.state))
    }

    @Test func removeReleaseResetShareEditAndPaste() throws {
        var a = Replica(0xA)
        let path = try Self.square(&a)
        let other = try Self.square(&a, x: 50)
        try a.perform(Extrude([path, other], length: 30, vanishingPoint: Point(x: 100, y: 100)))
        let wrappers = [path, other].compactMap { Self.wrapper(of: $0, a.state) }
        #expect(wrappers.count == 2)

        let share = try a.perform(ShareVanishingPoints([path, other], at: Point(x: 5, y: 6)))!
        #expect(share.label == "Share vanishing points")
        #expect(wrappers.allSatisfy { a.state.props($0).extrude.vanishingPoint.y == 6 })
        let edit = try a.perform(EditExtrusion([path], label: "Rotate extrusion", fields: [ExtrudeFields.rotation, ExtrudeFields.profileKind]) {
            $0.rotation.x = 30
            $0.profile.kind = .bevel
        })!
        #expect(edit.label == "Rotate extrusion")
        #expect(throws: ObjectEditError.invalidValue("length")) {
            try a.perform(EditExtrusion([path], label: "x", fields: [ExtrudeFields.length]) { $0.length = 40000 })
        }
        var profile = Wiretuner_Doc_V1_PathProps()
        profile.contours = [Subtrees.proto(VectorContour(closed: false, points: PathFixture.points([(0, 0), (4, 3)])))]
        let paste = try a.perform(PasteExtrudeProfile([path], contour: PasteExtrudeProfile.profile(from: profile)!))!
        #expect(paste.label == "Paste profile" && a.state.props(wrappers[0]).extrude.profile.path.points.count == 2)
        guard case .group(let bevelled)? = Self.scene(a.state).object(wrappers[0])?.item, case .extrude(let spec)? = bevelled.live else { return }
        #expect(spec.profile.kind == .bevel && spec.profile.path != nil && spec.rotationX == 30)
        profile.contours[0].closed = true
        #expect(PasteExtrudeProfile.profile(from: profile) == nil)
        #expect(throws: WrapperError.invalidProfile) { try a.perform(PasteExtrudeProfile([path], contour: profile.contours[0])) }

        let reset = try a.perform(ResetExtrusion([path]))!
        #expect(reset.label == "Reset extrusion")
        let after = a.state.props(wrappers[0]).extrude
        #expect(after.rotation.x == 0 && after.profile.kind == .unspecified && !after.profile.hasPath && after.length == 30 && after.vanishingPoint.x == 5)

        // Remove: the child goes back where the extrusion was.
        let remove = try a.perform(RemoveExtrusion([wrappers[0]]))!
        #expect(remove.label == "Remove extrusion" && Self.wrapper(of: path, a.state) == nil && !a.state.isLive(wrappers[0]))
        a.undo()
        #expect(Self.wrapper(of: path, a.state) == wrappers[0])

        // Release: a group of faces replaces the extrusion; the extrusion is deleted with its child.
        let release = try a.perform(ReleaseExtrusion([other]))!
        #expect(release.label == "Release extrusion" && !a.state.isLive(wrappers[1]))
        #expect(Self.wrapper(of: other, a.state) == wrappers[1], "the child stays inside the deleted extrusion")
        let released = ColorFixture.created(release).first!
        #expect(a.state.nodeKind(released) == .group && !a.state.liveChildren(released).isEmpty)
        a.undo()
        #expect(a.state.isLive(wrappers[1]) && !a.state.isLive(released))
        #expect(throws: WrapperError.notAWrapper(released)) { try a.perform(RemoveExtrusion([released])) }
    }

    @Test func readTimeNormalizations() throws {
        var a = Replica(0xA)
        let path = try Self.square(&a)
        let second = try Self.square(&a, x: 40)
        try a.perform(Extrude([path], vanishingPoint: .zero))
        let wrapper = Self.wrapper(of: path, a.state)!
        // A second child (a concurrent move in): the smaller id is extruded, the other drawn flat.
        try a.perform(OpsCommand("Move in", ops: [Ops.move(second, parent: wrapper, position: [0x10])]))
        #expect(Wrappers.drawOrder(wrapper, .extrude, in: a.state) == [path, second])
        #expect(ExtrudeReading.child(wrapper, in: a.state) == path)
        // An empty extrusion draws nothing.
        try a.perform(OpsCommand("Delete", ops: [Ops.setDeleted(path), Ops.setDeleted(second)]))
        #expect(ExtrudeReading.title(wrapper, in: a.state) == "Empty extrusion")
        #expect(Self.scene(a.state).object(wrapper) == nil)
        // Profiles without a path read None; lights map.
        var props = Wiretuner_Doc_V1_ExtrudeProps()
        props.profile.kind = .static
        props.surface.kind = .wireframe
        props.surface.light2.direction = .bottomRight
        let spec = Wrappers.extrude(props)
        #expect(spec.profile.kind == .none && spec.surface == .wireframe && spec.light2.direction == .bottomRight && spec.light1.direction == .none)
    }

    // MARK: Merges

    @Test func removeVersusChildEdit() throws {
        var pair = Pair()
        let path = try Self.square(&pair.a)
        try pair.a.perform(Extrude([path], vanishingPoint: .zero))
        pair.sync()
        let wrapper = Self.wrapper(of: path, pair.a.state)!
        try pair.a.perform(RemoveExtrusion([path]))
        try pair.b.perform(MoveObjects([path], by: Vector(dx: 7, dy: 0)))
        pair.sync()
        for replica in [pair.a, pair.b] {
            #expect(!replica.state.isLive(wrapper) && Self.wrapper(of: path, replica.state) == nil)
            #expect(Objects.transform(of: path, in: replica.state).tx == 7, "the edit survives on the freed child")
        }
    }

    @Test func releaseVersusChildEditAndRestore() throws {
        var pair = Pair()
        let path = try Self.square(&pair.a)
        try pair.a.perform(Extrude([path], vanishingPoint: Point(x: 50, y: 50)))
        pair.sync()
        let wrapper = Self.wrapper(of: path, pair.a.state)!
        try pair.a.perform(ReleaseExtrusion([wrapper]))
        try pair.b.perform(MoveObjects([path], by: Vector(dx: 3, dy: 0)))
        pair.sync()
        #expect(!pair.b.state.isEffectivelyLive(path), "the edited child is under the deleted extrusion")
        // Restore (undo of the release) brings the live extrusion back with the edit.
        pair.a.undo()
        pair.sync()
        for replica in [pair.a, pair.b] {
            #expect(replica.state.isLive(wrapper) && Objects.transform(of: path, in: replica.state).tx == 3)
        }
    }

    @Test func concurrentExtrudesOfOnePath() throws {
        var pair = Pair()
        let path = try Self.square(&pair.a)
        pair.sync()
        try pair.a.perform(Extrude([path], vanishingPoint: .zero))
        try pair.b.perform(Extrude([path], vanishingPoint: .zero))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let wrappers = pair.a.state.liveChildren(Objects.parent(of: Self.wrapper(of: path, pair.a.state)!, in: pair.a.state)!)
            .filter { WrapperKind.of($0, in: pair.a.state) == .extrude }
        #expect(wrappers.count == 2, "two wrappers")
        let holding = wrappers.filter { ExtrudeReading.child($0, in: pair.a.state) != nil }
        #expect(holding.count == 1, "the path is in one of them; the other is empty and draws nothing")
        let scene = Self.scene(pair.a.state)
        #expect(scene.object(holding[0]) != nil && wrappers.filter { scene.object($0) != nil }.count == 1)
    }
}
