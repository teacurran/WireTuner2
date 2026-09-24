import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// FX-024: blend commands, eligibility, the read-time normalizations and the blend in the scene.
@Suite struct BlendCommandTests {
    static func square(_ replica: inout Replica, x: Double, red: Double = 1) throws -> OpID {
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        appearance.fills = [Appearances.basicFill(red: red, green: 0, blue: 1 - red)]
        return try LayerFixture.object(CreatePath(contours: [NewContour(closed: true, points: PathFixture.points([(x, 0), (x + 10, 0), (x + 10, 10), (x, 10)]))],
                                                  appearance: appearance), on: &replica)
    }

    static func blend(of node: OpID, _ state: EngineState) -> OpID? {
        state.store.placement(node).flatMap { WrapperKind.of($0.parent, in: state) == .blend ? $0.parent : nil }
    }

    static func scene(_ state: EngineState) -> DocumentScene {
        var builder = DocumentDisplayListBuilder(canvas: "c")
        return builder.rebuild(state)
    }

    @Test func blendFromTheSelectionAndPointToPoint() throws {
        var a = Replica(0xA)
        let start = try Self.square(&a, x: 0)
        let end = try Self.square(&a, x: 100, red: 0)
        let change = try a.perform(Blend([end, start]))!
        #expect(change.label == "Blend")
        let blend = try #require(Self.blend(of: start, a.state))
        #expect(BlendReading.keyObjects(blend, in: a.state) == [start, end], "stacking order: the bottom object starts")
        let props = a.state.props(blend).blend
        #expect(props.rangeLast == 100 && props.rotateOnPath && props.steps == 0)
        let scene = Self.scene(a.state)
        guard case .group(let group)? = scene.object(blend)?.item, case .blend(let spec)? = group.live else { Issue.record("no blend"); return }
        #expect(group.children.count == 2 && spec.path == nil && spec.rangeLast == 100)

        // Point to point: the chosen points become the blend points.
        var b = Replica(0xB)
        let one = try Self.square(&b, x: 0)
        let two = try Self.square(&b, x: 50, red: 0)
        let points = [one, two].map { node -> BlendPointChoice in
            let contour = b.path(node).contours[0]
            return BlendPointChoice(contour: contour.id, point: contour.drawn[2].id)
        }
        try b.perform(Blend([one, two], points: [one: points[0], two: points[1]]))
        let other = Self.blend(of: one, b.state)!
        #expect(BlendReading.points(b.state.props(other).blend).map(\.object) == [one, two])
        guard case .group(let pointed)? = Self.scene(b.state).object(other)?.item, case .blend(let pointedSpec)? = pointed.live else { return }
        #expect(pointedSpec.blendPoints == [BlendPoint(child: 0, anchor: 2), BlendPoint(child: 1, anchor: 2)])
    }

    @Test func blendsAndExtrusionsMoveAndTransformAsObjects() throws {
        var a = Replica(0xA)
        let start = try Self.square(&a, x: 0)
        let end = try Self.square(&a, x: 100, red: 0)
        try a.perform(Blend([start, end]))
        let blend = try #require(Self.blend(of: start, a.state))
        #expect(Objects.isObject(blend, in: a.state) && Self.scene(a.state).object(blend)?.kind == .blend && WrapperKind.blend.nodeKind == .blend)
        let before = try #require(Self.scene(a.state).object(blend)?.bounds)
        try a.perform(MoveObjects([blend], by: Vector(dx: 10, dy: 5)))
        let moved = try #require(Self.scene(a.state).object(blend)?.bounds)
        #expect(abs(moved.minX - before.minX - 10) < 1e-6 && abs(moved.minY - before.minY - 5) < 1e-6)
        #expect(Objects.transform(of: blend, in: a.state).tx == 10, "the blend's own transform moves it with its key objects")
        let path = try Self.square(&a, x: 300)
        try a.perform(Extrude([path], vanishingPoint: Point(x: 0, y: 0)))
        let wrapper = try #require(a.state.store.placement(path)?.parent)
        #expect(Objects.isObject(wrapper, in: a.state))
        try a.perform(TransformObjects([wrapper], matrix: .scale(x: 2, y: 2), about: .zero, kind: .scale))
        #expect(Objects.transform(of: wrapper, in: a.state).a == 2)
    }

    @Test func eligibilityRefusesWithAReason() throws {
        var a = Replica(0xA)
        let one = try Self.square(&a, x: 0)
        #expect(throws: WrapperError.notBlendable(BlendEligibility.tooFew)) { try a.perform(Blend([one])) }
        // A lens fill blends only with a lens fill.
        let lens = try Self.square(&a, x: 40)
        try a.perform(SetAttributeKind([(lens, AppearanceEditing.stack(lens, in: a.state)[0])], fill: .lens))
        #expect(throws: WrapperError.notBlendable("A basic fill blends only with the same kind of fill.")) { try a.perform(Blend([one, lens])) }
        // Gradient and basic blend together.
        let gradient = try Self.square(&a, x: 80)
        try a.perform(ChooseGradient([(gradient, AppearanceEditing.stack(gradient, in: a.state)[0])]))
        #expect(BlendEligibility.refusal([one, gradient], in: a.state) == nil)
        // Composite with simple.
        let composite = try LayerFixture.object(CreatePath(contours: [NewContour(closed: true, points: PathFixture.points([(0, 50), (5, 50), (5, 55)])),
                                                                      NewContour(closed: true, points: PathFixture.points([(10, 50), (15, 50), (15, 55)]))]), on: &a)
        #expect(BlendEligibility.refusal([one, composite], in: a.state) == BlendEligibility.composites)
        // Groups of simple paths only; placed files, text and other kinds refused.
        let group = try a.perform(GroupObjects([composite]))!.createdObjects[0]
        #expect(BlendEligibility.refusal([one, group], in: a.state) == BlendEligibility.groupContents)
        let simple = try Self.square(&a, x: 200)
        let simpleGroup = try a.perform(GroupObjects([simple]))!.createdObjects[0]
        #expect(BlendEligibility.refusal(simpleGroup, in: a.state) == nil)
        let text = ColorFixture.created(try a.perform(OpsCommand("Text", ops: [Ops.create(parent: OpID.wellKnown(4), position: [0xF0], props: Fixture.textBlock())])))[0]
        #expect(BlendEligibility.refusal(text, in: a.state) == BlendEligibility.text)
        var placed = Wiretuner_Doc_V1_NodeProps()
        placed.placedFile = Wiretuner_Doc_V1_PlacedFileProps()
        let file = ColorFixture.created(try a.perform(OpsCommand("Place", ops: [Ops.create(parent: OpID.wellKnown(4), position: [0xF1], props: placed)])))[0]
        #expect(BlendEligibility.refusal(file, in: a.state) == BlendEligibility.bitmaps)
        let chart = try LayerFixture.object(PathFixture.closed([(0, 0), (1, 0), (1, 1)]), on: &a)
        let instance = try a.perform(ConvertToSymbol([chart]))!.createdObjects.last!
        #expect(BlendEligibility.refusal(instance, in: a.state) == BlendEligibility.unsupported)
        // Stroke kinds must match.
        let calligraphic = try Self.square(&a, x: 300)
        try a.perform(AddAppearance.stroke([calligraphic]))
        try a.perform(SetAttributeKind([(calligraphic, AppearanceEditing.stack(calligraphic, in: a.state).last!)], stroke: .calligraphic))
        let stroked = try Self.square(&a, x: 340)
        try a.perform(AddAppearance.stroke([stroked]))
        #expect(BlendEligibility.refusal([calligraphic, stroked], in: a.state) == "A calligraphic stroke blends only with the same kind of stroke.")
    }

    @Test func addPointsPropsJoinSplit() throws {
        var a = Replica(0xA)
        let one = try Self.square(&a, x: 0)
        let two = try Self.square(&a, x: 50, red: 0)
        let three = try Self.square(&a, x: 100, red: 0.5)
        try a.perform(Blend([one, two]))
        let blend = Self.blend(of: one, a.state)!
        let add = try a.perform(AddToBlend(blend, three))!
        #expect(add.label == "Add to blend" && BlendReading.keyObjects(blend, in: a.state) == [one, two, three])
        let lens = try Self.square(&a, x: 200)
        try a.perform(SetAttributeKind([(lens, AppearanceEditing.stack(lens, in: a.state)[0])], fill: .lens))
        #expect(throws: WrapperError.notBlendable("A basic fill blends only with the same kind of fill.")) { try a.perform(AddToBlend(blend, lens)) }

        // Blend points: one element per object, the last write clears the others.
        let contour = a.path(two).contours[0]
        let move = try a.perform(SetBlendPoint(blend, object: two, choice: BlendPointChoice(contour: contour.id, point: contour.drawn[1].id)))!
        #expect(move.label == "Move blend point")
        try a.perform(SetBlendPoint(blend, object: two, choice: BlendPointChoice(contour: contour.id, point: contour.drawn[3].id)))
        #expect(a.state.props(blend).blend.blendPoints.count == 1)
        #expect(throws: ObjectEditError.notAnObject(lens)) {
            try a.perform(SetBlendPoint(blend, object: lens, choice: BlendPointChoice(contour: contour.id, point: contour.drawn[1].id)))
        }

        // Props.
        let steps = try a.perform(EditBlend.steps([blend], 5))!
        #expect(steps.label == "Change steps" && a.state.props(blend).blend.steps == 5)
        #expect(throws: ObjectEditError.invalidValue("steps")) { try a.perform(EditBlend.steps([blend], 0)) }
        #expect(throws: ObjectEditError.invalidValue("range")) {
            try a.perform(EditBlend([blend], label: "Range", fields: [BlendFields.rangeFirst]) { $0.rangeFirst = 120 })
        }
        #expect(throws: ObjectEditError.invalidValue("fields")) { try a.perform(EditBlend([blend], label: "x", fields: [BlendFields.path]) { _ in }) }
        try a.perform(EditBlend([one], label: "Range", fields: [BlendFields.rangeFirst, BlendFields.type]) { $0.rangeFirst = 20; $0.type = .vertical })
        #expect(a.state.props(blend).blend.rangeFirst == 20)

        // Join to a path and split.
        let spine = try LayerFixture.object(PathFixture.open([(0, 100), (100, 150), (200, 100)]), on: &a)
        let join = try a.perform(JoinBlendToPath(blend, path: spine))!
        #expect(join.label == "Join blend to path")
        #expect(BlendReading.path(a.state.props(blend).blend, children: a.state.liveChildren(blend), in: a.state) == spine)
        #expect(BlendReading.keyObjects(blend, in: a.state) == [one, two, three])
        guard case .group(let joined)? = Self.scene(a.state).object(blend)?.item, case .blend(let spec)? = joined.live else { return }
        #expect(spec.path == 3 && spec.rotateOnPath && spec.type == .vertical && spec.steps == 5)
        #expect(spec.blendPoints == [BlendPoint(child: 1, anchor: 3)])
        #expect(throws: PathEditError.notAPath(blend)) { try a.perform(JoinBlendToPath(blend, path: blend)) }
        let split = try a.perform(SplitBlend([blend]))!
        #expect(split.label == "Split" && Self.blend(of: spine, a.state) == nil && !a.state.props(blend).blend.hasPath)
        #expect(try a.perform(SplitBlend([blend])) == nil, "nothing joined")
    }

    @Test func releaseBakesTheStepsBetweenTheKeyObjects() throws {
        var a = Replica(0xA)
        let one = try Self.square(&a, x: 0)
        let two = try Self.square(&a, x: 100, red: 0)
        let three = try Self.square(&a, x: 200, red: 0.5)
        try a.perform(Blend([one, two, three]))
        let blend = Self.blend(of: one, a.state)!
        try a.perform(EditBlend.steps([blend], 4))
        let parent = Objects.parent(of: blend, in: a.state)!
        let release = try a.perform(ReleaseBlend([blend]))!
        #expect(release.label == "Ungroup" && !a.state.isLive(blend))
        let children = a.state.liveChildren(parent)
        let groups = children.filter { a.state.nodeKind($0) == .group }
        #expect(groups.count == 2, "one group of steps per span")
        #expect(groups.allSatisfy { a.state.liveChildren($0).count == 4 })
        #expect(children.filter { [one, two, three].contains($0) } == [one, two, three])
        // Order: key, steps, key, steps, key.
        let order = children.filter { [one, two, three].contains($0) || groups.contains($0) }
        #expect(order == [one, groups[0], two, groups[1], three])
        // A step's fill is between the ends' colours.
        let fill = a.state.props(a.state.liveChildren(groups[0])[1]).path.appearance.fills.first?.settings.basic.color
        let color = fill.flatMap { ColorResolver(a.state).color($0) }
        #expect(color.map { $0.red < 1 && $0.red > 0 } == true)
        // Undo restores the live blend.
        a.undo()
        #expect(a.state.isLive(blend) && BlendReading.keyObjects(blend, in: a.state) == [one, two, three])
        #expect(groups.allSatisfy { !a.state.isLive($0) })
    }

    @Test func releaseOfAJoinedBlendKeepsThePath() throws {
        var a = Replica(0xA)
        let one = try Self.square(&a, x: 0)
        let two = try Self.square(&a, x: 100, red: 0)
        try a.perform(Blend([one, two]))
        let blend = Self.blend(of: one, a.state)!
        let spine = try LayerFixture.object(PathFixture.open([(0, 100), (200, 100)]), on: &a)
        try a.perform(JoinBlendToPath(blend, path: spine))
        try a.perform(EditBlend([blend], label: "Show path", fields: [BlendFields.showPath, BlendFields.steps]) { $0.showPath = true; $0.steps = 3 })
        try a.perform(ReleaseBlend([blend]))
        let parent = Objects.parent(of: one, in: a.state)!
        let children = a.state.liveChildren(parent)
        #expect(children.contains(spine) && children.last == spine)
        let steps = children.filter { a.state.nodeKind($0) == .group }
        #expect(steps.count == 1 && a.state.liveChildren(steps[0]).count == 3)
    }

    @Test func fewerThanTwoKeysAndStrayChildrenReadPlain() throws {
        var a = Replica(0xA)
        let one = try Self.square(&a, x: 0)
        let two = try Self.square(&a, x: 50, red: 0)
        try a.perform(Blend([one, two]))
        let blend = Self.blend(of: one, a.state)!
        try a.perform(OpsCommand("Delete", ops: [Ops.setDeleted(two)]))
        #expect(BlendReading.keyObjects(blend, in: a.state) == [one])
        // Releasing a blend with one key object just frees it.
        try a.perform(ReleaseBlend([blend]))
        #expect(Self.blend(of: one, a.state) == nil && a.state.isLive(one))
        #expect(throws: WrapperError.notAWrapper(one)) { try a.perform(ReleaseBlend([one])) }
        #expect(BlendReading.points(Wiretuner_Doc_V1_BlendProps()).isEmpty)
    }

    @Test func groupEligibilityAndThreeKeyPoints() throws {
        var a = Replica(0xA)
        let r = try LayerFixture.object(LayerFixture.rect(on: nil, x: 0), on: &a)
        let p = try Self.square(&a, x: 20)
        let shapes = try a.perform(GroupObjects([r, p]))!.createdObjects[0]
        #expect(BlendEligibility.refusal(shapes, in: a.state) == nil)
        let inner = try Self.square(&a, x: 60)
        let innerGroup = try a.perform(GroupObjects([inner]))!.createdObjects[0]
        let nested = try a.perform(GroupObjects([innerGroup]))!.createdObjects[0]
        #expect(BlendEligibility.refusal(nested, in: a.state) == BlendEligibility.groupContents)
        var clip = Wiretuner_Doc_V1_NodeProps()
        clip.group.clipPath.id = r.proto
        try a.perform(OpsCommand("clip", ops: [Ops.set(shapes, [RegisterPath([50, 4])], values: clip)]))
        #expect(BlendEligibility.refusal(shapes, in: a.state) == BlendEligibility.groupContents)
        // A three-key blend with a point on every key releases two spans.
        let keys = [try Self.square(&a, x: 100), try Self.square(&a, x: 150, red: 0), try Self.square(&a, x: 200, red: 0.5)]
        var points: [OpID: BlendPointChoice] = [:]
        for key in keys {
            let contour = a.path(key).contours[0]
            points[key] = BlendPointChoice(contour: contour.id, point: contour.drawn[2].id)
        }
        try a.perform(Blend(keys, points: points))
        let blend = Self.blend(of: keys[0], a.state)!
        try a.perform(EditBlend.steps([blend], 2))
        let parent = Objects.parent(of: blend, in: a.state)!
        try a.perform(ReleaseBlend([blend]))
        let spans = a.state.liveChildren(parent).filter { $0 != shapes && a.state.nodeKind($0) == .group && a.state.liveChildren($0).count == 2 }
        #expect(spans.count == 2)
        #expect(EffectFields.field(.unspecified, 1) == [0, 1])
    }

    // MARK: Merges

    @Test func releaseVersusKeyObjectEdit() throws {
        var pair = Pair()
        let one = try Self.square(&pair.a, x: 0)
        let two = try Self.square(&pair.a, x: 50, red: 0)
        try pair.a.perform(Blend([one, two]))
        pair.sync()
        let blend = Self.blend(of: one, pair.a.state)!
        try pair.a.perform(EditBlend.steps([blend], 2))
        try pair.a.perform(ReleaseBlend([blend]))
        try pair.b.perform(MoveObjects([two], by: Vector(dx: 0, dy: 30)))
        pair.sync()
        for replica in [pair.a, pair.b] {
            #expect(!replica.state.isLive(blend) && Self.blend(of: two, replica.state) == nil)
            #expect(Objects.transform(of: two, in: replica.state).ty == 30, "the edit survives on the freed object")
        }
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
    }

    @Test func stepsVersusEndpointMove() throws {
        var pair = Pair()
        let one = try Self.square(&pair.a, x: 0)
        let two = try Self.square(&pair.a, x: 50, red: 0)
        try pair.a.perform(Blend([one, two]))
        pair.sync()
        let blend = Self.blend(of: one, pair.a.state)!
        try pair.a.perform(EditBlend.steps([blend], 7))
        try pair.b.perform(MoveObjects([two], by: Vector(dx: 10, dy: 0)))
        pair.sync()
        for replica in [pair.a, pair.b] {
            #expect(replica.state.props(blend).blend.steps == 7 && Objects.transform(of: two, in: replica.state).tx == 10)
        }
    }

    @Test func joinVersusPathDelete() throws {
        var pair = Pair()
        let one = try Self.square(&pair.a, x: 0)
        let two = try Self.square(&pair.a, x: 50, red: 0)
        try pair.a.perform(Blend([one, two]))
        let spine = try LayerFixture.object(PathFixture.open([(0, 100), (100, 100)]), on: &pair.a)
        pair.sync()
        let blend = Self.blend(of: one, pair.a.state)!
        try pair.a.perform(JoinBlendToPath(blend, path: spine))
        try pair.b.perform(OpsCommand("Delete", ops: [Ops.setDeleted(spine)]))
        pair.sync()
        for replica in [pair.a, pair.b] {
            #expect(BlendReading.path(replica.state.props(blend).blend, children: replica.state.liveChildren(blend), in: replica.state) == nil,
                    "the blend is straight")
        }
        pair.b.undo()
        pair.sync()
        for replica in [pair.a, pair.b] {
            #expect(BlendReading.path(replica.state.props(blend).blend, children: replica.state.liveChildren(blend), in: replica.state) == spine,
                    "restoring the path joins it again")
        }
    }

    @Test func concurrentAddsOfTwoObjects() throws {
        var pair = Pair()
        let one = try Self.square(&pair.a, x: 0)
        let two = try Self.square(&pair.a, x: 50, red: 0)
        let x = try Self.square(&pair.a, x: 100, red: 0.2)
        let y = try Self.square(&pair.a, x: 150, red: 0.8)
        try pair.a.perform(Blend([one, two]))
        pair.sync()
        let blend = Self.blend(of: one, pair.a.state)!
        try pair.a.perform(AddToBlend(blend, x))
        try pair.b.perform(AddToBlend(blend, y))
        pair.sync()
        let keys = BlendReading.keyObjects(blend, in: pair.a.state)
        #expect(Set(keys) == [one, two, x, y] && keys == BlendReading.keyObjects(blend, in: pair.b.state))
    }
}
