import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// LIB-019's merge tests (styles.adoc, "Merge semantics"): two replicas edit concurrently, then
/// exchange their changes and converge.
@Suite struct StyleMergeTests {
    typealias F = StyleCommandFixture

    /// Two synced replicas holding a layer, a style (red fill, 1 pt stroke) and `count` objects
    /// using it.
    static func pair(objects count: Int = 2) throws -> (Pair, OpID, [OpID]) {
        var pair = Pair()
        let layer = try LayerFixture.layers(["L"], on: &pair.a)[0]
        let style = try StyleFixture.create([StyleFixture.props("Callout", fill: 0.1, stroke: 1)], on: &pair.a)[0]
        let objects = try F.objects(Array(repeating: (style, nil, false), count: count), layer: layer, on: &pair.a)
        pair.sync()
        return (pair, style, objects)
    }

    @Test func redefineVersusConcurrentOverrideKeepsTheOverride() throws {
        var (pair, style, objects) = try Self.pair()
        // A redefines the style's stroke to 4 pt (from an object overriding it); B overrides the
        // stroke of the first object with 2 pt.
        let source = try F.objects([(style, nil, false)], layer: pair.a.state.liveChildren(WellKnown.layers)[0], on: &pair.a)[0]
        try F.stroke(4, on: source, &pair.a)
        try pair.a.perform(RedefineGraphicStyle(style, from: .object(source)))
        try F.stroke(2, on: objects[0], &pair.b)
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        for replica in [pair.a, pair.b] {
            #expect(F.width(F.look(objects[0], replica.state)) == 2, "the override wins: it is on another node")
            #expect(F.width(F.look(objects[1], replica.state)) == 4, "every other object shows the redefinition")
        }
    }

    @Test func applyVersusConcurrentOverrideIsLastWriterWinsWithTheLoserRetained() throws {
        var (pair, style, objects) = try Self.pair(objects: 1)
        let object = objects[0]
        let halftone = RegisterPath([NodeKind.rect.rawValue, 1, 11])
        // The object overrides the halftone; both then act concurrently.
        var screen = Wiretuner_Doc_V1_NodeProps()
        screen.rect.common.halftone.frequency = 85
        try pair.a.perform(OpsCommand("Screen", ops: [Ops.set(object, [halftone], values: screen)]))
        pair.sync()
        // A re-applies the style (clearing the override, listed with no value); B sets a new screen.
        try pair.a.perform(ApplyGraphicStyle(style, to: [object]))
        screen.rect.common.halftone.frequency = 120
        let override = try #require(try pair.b.perform(OpsCommand("Screen", ops: [Ops.set(object, [halftone], values: screen)])))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        let register = try #require(pair.a.state.register(object, halftone))
        let losing = pair.a.state.losingWrites(object, halftone)
        // B's write carries the greater OpId (same counter, greater replica): the override wins
        // and the clear is retained as a losing write for the review sheet.
        #expect(register.op.replica == 0xB && register.op.counter == override.startCounter)
        #expect(F.look(object, pair.a.state).halftone?.frequency == 120)
        #expect(losing.contains { $0.op.replica == 0xA && $0.value == nil }, "the clear is retained")
    }

    @Test func applyWinsWhenItIsTheLaterWrite() throws {
        var (pair, style, objects) = try Self.pair(objects: 1)
        let object = objects[0]
        let halftone = RegisterPath([NodeKind.rect.rawValue, 1, 11])
        var screen = Wiretuner_Doc_V1_NodeProps()
        screen.rect.common.halftone.frequency = 85
        try pair.b.perform(OpsCommand("Screen", ops: [Ops.set(object, [halftone], values: screen)]))
        try pair.a.perform(RenameGraphicStyle(style, to: "Later"))
        try pair.a.perform(RenameGraphicStyle(style, to: "Later still"))
        try pair.a.perform(ApplyGraphicStyle(style, to: [object]))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        #expect(pair.b.state.register(object, halftone)?.isSet == false, "the clear wins")
        #expect(pair.b.state.losingWrites(object, halftone).contains { $0.op.replica == 0xB }, "the override is retained")
    }

    @Test func removeVersusConcurrentApplyKeepsTheLookThroughTheDeletedStyle() throws {
        var (pair, style, _) = try Self.pair(objects: 1)
        let layer = pair.a.state.liveChildren(WellKnown.layers)[0]
        let fresh = try F.objects([(nil, 0.9, false)], layer: layer, on: &pair.b)[0]
        pair.sync()
        try pair.a.perform(RemoveGraphicStyle(style))
        try pair.b.perform(ApplyGraphicStyle(style, to: [fresh]))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        #expect(!pair.a.state.isLive(style))
        let look = F.look(fresh, pair.a.state)
        #expect(F.red(look) == 0.1 && F.width(look) == 1, "the object resolves through the deleted style's registers")
        #expect(F.styleRef(fresh, pair.a.state) == style)
    }

    @Test func twoInPlaceRedefinesOfDifferentFieldsKeepBoth() throws {
        var (pair, style, objects) = try Self.pair(objects: 3)
        // A's source: the style's fill recoloured.  B's source: the style's fill hidden and its
        // stroke 6 pt.  Both redefine at once.
        try pair.a.perform(AddAppearance.fill([objects[1]], Appearances.basicFill(red: 0.7, green: 0, blue: 0)))
        var hidden = Appearances.basicFill(red: 0.1, green: 0, blue: 0)
        hidden.hidden = true
        try pair.b.perform(AddAppearance.fill([objects[2]], hidden))
        try F.stroke(6, on: objects[2], &pair.b)
        try pair.a.perform(RedefineGraphicStyle(style, from: .object(objects[1])))
        try pair.b.perform(RedefineGraphicStyle(style, from: .object(objects[2])))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        let fills = pair.a.state.props(style).style.appearance.fills
        #expect(fills.count == 1, "edited in place: no second fill")
        #expect(fills[0].settings.basic.color.inline.rgb.r == 0.7 && fills[0].hidden, "A's colour and B's hiding both apply")
        #expect(F.width(F.look(objects[0], pair.a.state)) == 6)
    }
}
