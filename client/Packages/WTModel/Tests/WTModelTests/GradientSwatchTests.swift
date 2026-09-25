import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// ATTR-029: gradient swatches -- keeping a ramp, applying it, and the later application winning
/// in full.
@Suite struct GradientSwatchTests {
    typealias Fill = (node: OpID, row: AppearanceRow)

    static let red = Appearances.inline(red: 1, green: 0, blue: 0)
    static let blue = Appearances.inline(red: 0, green: 0, blue: 1)
    static let green = Appearances.inline(red: 0, green: 1, blue: 0)

    static func gradient(_ fill: Fill, _ state: EngineState) -> Wiretuner_Doc_V1_GradientFill {
        GradientCommandTests.gradient(fill.node, fill.row, state)
    }

    static func ramp(_ fill: Fill, _ state: EngineState) -> [GradientRampStop] {
        GradientReading.ramp(gradient(fill, state))
    }

    /// A rectangle whose fill is a Radial, Repeat ×3 gradient red → (swatch "Grape" at 0.4) → blue.
    static func shaped(_ replica: inout Replica, x: Double = 0) throws -> (fill: Fill, grape: OpID) {
        let fill = try GradientCommandTests.filled(&replica, x: x)
        let grape = try replica.perform(AddSwatch(Color(red: 0.5, green: 0, blue: 0.5), name: "Grape"))!.createdNodes[0]
        try replica.perform(ChooseGradient([fill], type: .radial))
        try replica.perform(EditGradient.behavior([fill], .repeat))
        try replica.perform(EditGradient.count([fill], 3))
        let ends = ramp(fill, replica.state)
        try replica.perform(RecolorGradientStop(node: fill.node, row: fill.row, stop: ends[1].id, color: blue))
        try replica.perform(AddGradientStop(node: fill.node, row: fill.row, offset: 0.4, color: ColorResolver(replica.state).reference(to: grape)))
        return (fill, grape)
    }

    @Test func fillToSwatchToFillIsLossless() throws {
        var a = Replica(0xA)
        let (fill, grape) = try Self.shaped(&a)
        let change = try a.perform(AddGradientSwatch(node: fill.node, row: fill.row, in: a.state))!
        #expect(change.label == "Add gradient swatch")
        let swatch = try #require(GradientSwatches.list(in: a.state).first)
        #expect(swatch.name == "Gradient" && swatch.gradient.type == .radial && swatch.gradient.stops.count == 3)
        #expect(GradientSwatches.list(in: a.state).count == 1 && SwatchList(a.state).swatches.allSatisfy { $0.id != swatch.id })
        // Onto another object: type, behavior, count and the ramp -- the swatch reference intact.
        let other = try GradientCommandTests.filled(&a, x: 40)
        #expect(try a.perform(ApplyGradientSwatch(swatch.id, to: [other.node]))!.label == "Apply gradient")
        let applied = Self.gradient(other, a.state)
        let source = Self.gradient(fill, a.state)
        #expect(applied.type == source.type && applied.behavior == source.behavior && applied.repeatCount == source.repeatCount)
        #expect(!applied.hasAxis)
        let pairs = zip(Self.ramp(other, a.state), Self.ramp(fill, a.state))
        #expect(Self.ramp(other, a.state).count == 3 && pairs.allSatisfy { $0.offset == $1.offset && $0.color == $1.color })
        #expect(ColorResolver.swatch(of: Self.ramp(other, a.state)[1].color) == grape)
        // And back onto the fill it came from: the same gradient again.
        try a.perform(ApplyGradientSwatch(swatch.id, to: [fill.node]))
        #expect(GradientSwatches.kept(Self.gradient(fill, a.state)) == GradientSwatches.kept(source))
        #expect(GradientSwatches.fill(of: swatch) == GradientSwatches.kept(source))
    }

    @Test func namesRemovalAndRefusals() throws {
        var a = Replica(0xA)
        let (fill, _) = try Self.shaped(&a)
        try a.perform(AddGradientSwatch(node: fill.node, row: fill.row, in: a.state))
        try a.perform(AddGradientSwatch(Self.gradient(fill, a.state), name: "  ", group: "Warm"))
        try a.perform(AddGradientSwatch(Self.gradient(fill, a.state), name: "Sunset"))
        let list = GradientSwatches.list(in: a.state)
        #expect(list.map(\.name) == ["Gradient", "Gradient 2", "Sunset"] && list[1].group == "Warm")
        #expect(GradientSwatches.freeName("Gradient", in: a.state) == "Gradient 3")
        #expect(throws: GradientSwatchError.nameTaken("Sunset")) { try a.perform(AddGradientSwatch(Self.gradient(fill, a.state), name: "Sunset ")) }
        #expect(throws: GradientSwatchError.nameTaken("Sunset")) { try a.perform(RenameGradientSwatch(list[0].id, name: "Sunset")) }
        #expect(throws: GradientSwatchError.emptyName) { try a.perform(RenameGradientSwatch(list[0].id, name: " ")) }
        #expect(try a.perform(RenameGradientSwatch(list[2].id, name: "Sunset")) == nil)
        #expect(try a.perform(RenameGradientSwatch(list[2].id, name: "Dusk"))!.label == "Rename gradient")
        #expect(GradientSwatches.swatch(list[2].id, in: a.state)?.name == "Dusk")
        // Not gradients.
        let basic = try GradientCommandTests.filled(&a, x: 80)
        #expect(throws: GradientSwatchError.notAGradient) { try AddGradientSwatch(node: basic.node, row: basic.row, in: a.state) }
        var single = Wiretuner_Doc_V1_GradientFill()
        single.stops = [Wiretuner_Doc_V1_GradientStop()]
        #expect(throws: GradientSwatchError.notAGradient) { try a.perform(AddGradientSwatch(single)) }
        // Removing: objects keep their gradients; the swatch no longer applies.
        try a.perform(ApplyGradientSwatch(list[0].id, to: [basic.node]))
        let removal = try a.perform(RemoveGradientSwatches([list[0].id, list[0].id]))!
        #expect(removal.label == "Remove gradient" && RemoveGradientSwatches([list[0].id, list[1].id]).label == "Remove 2 gradients")
        #expect(GradientSwatches.list(in: a.state).count == 2 && Self.ramp(basic, a.state).count == 3)
        #expect(throws: GradientSwatchError.notAGradientSwatch(list[0].id)) { try a.perform(ApplyGradientSwatch(list[0].id, to: [basic.node])) }
        #expect(throws: GradientSwatchError.notAGradientSwatch(list[0].id)) { try a.perform(RenameGradientSwatch(list[0].id, name: "X")) }
        #expect(throws: GradientSwatchError.notAGradientSwatch(list[0].id)) { try a.perform(RemoveGradientSwatches([list[0].id])) }
        #expect(GradientSwatches.swatch(fill.node, in: a.state) == nil)
    }

    @Test func theRendererResolvesStopSwatchesLive() throws {
        var a = Replica(0xA)
        let (fill, grape) = try Self.shaped(&a)
        try a.perform(AddGradientSwatch(node: fill.node, row: fill.row, in: a.state))
        let id = GradientSwatches.list(in: a.state)[0].id
        let drawn = try #require(GradientSwatches.gradient(id, in: a.state))
        #expect(drawn.kind == .radial && drawn.behavior == .repeat && drawn.repeatCount == 3 && drawn.stops.count == 3)
        #expect(drawn.stops[1].color == Color(red: 0.5, green: 0, blue: 0.5))
        try a.perform(RedefineSwatch(grape, to: Color(red: 0, green: 0.5, blue: 0)))
        let recolored = try #require(GradientSwatches.gradient(id, in: a.state, resolver: ColorResolver(a.state)))
        #expect(recolored.stops[1].color == Color(red: 0, green: 0.5, blue: 0))
        #expect(GradientSwatches.gradient(grape, in: a.state) == nil)
    }

    // MARK: The ramp register

    @Test func stopsOfAReplacedRampAreNotRead() {
        var gradient = Wiretuner_Doc_V1_GradientFill()
        var legacy = Wiretuner_Doc_V1_GradientStop()
        legacy.id = OpID(counter: 1, replica: 1).elementID
        legacy.offset = 0.2
        var tagged = legacy
        tagged.id = OpID(counter: 2, replica: 1).elementID
        tagged.ramp = OpID(counter: 2, replica: 1).elementID
        gradient.stops = [legacy, tagged]
        // No ramp register: untagged stops (every fill written before ATTR-029) read.
        #expect(GradientReading.ramp(gradient).map(\.id) == [OpID(counter: 1, replica: 1)])
        gradient.ramp = OpID(counter: 2, replica: 1).elementID
        #expect(GradientReading.ramp(gradient).map(\.id) == [OpID(counter: 2, replica: 1)])
    }

    @Test func applyingToAnObjectWithoutAFillNamesTheRamp() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let (fill, _) = try Self.shaped(&a, x: 50)
        try a.perform(AddGradientSwatch(node: fill.node, row: fill.row, in: a.state))
        try a.perform(ApplyGradientSwatch(GradientSwatches.list(in: a.state)[0].id, to: [rect]))
        let row = try #require(AppearanceEditing.stack(rect, in: a.state).last { $0.list == .fills })
        let gradient = Self.gradient((rect, row), a.state)
        #expect(gradient.hasRamp && gradient.stops.allSatisfy { $0.ramp == gradient.ramp } && Self.ramp((rect, row), a.state).count == 3)
        // Later stop edits join the applied ramp.
        try a.perform(AddGradientStop(node: rect, row: row, offset: 0.9, color: Self.green))
        #expect(Self.ramp((rect, row), a.state).count == 4)
        try a.perform(CopyGradientStop(node: rect, row: row, stop: Self.ramp((rect, row), a.state)[0].id, offset: 0.1))
        #expect(Self.ramp((rect, row), a.state).count == 5)
    }

    // MARK: Merges

    @Test func theLaterOfTwoConcurrentApplicationsWinsInFull() throws {
        var pair = Pair()
        let (fill, _) = try Self.shaped(&pair.a)
        var sunset = Wiretuner_Doc_V1_GradientFill()
        sunset.type = .cone
        sunset.stops = [(0.0, Self.red), (0.5, Self.blue), (1.0, Self.green)].map { offset, color in
            var stop = Wiretuner_Doc_V1_GradientStop()
            stop.offset = offset
            stop.color = color
            return stop
        }
        try pair.a.perform(AddGradientSwatch(Self.gradient(fill, pair.a.state), name: "Grape ramp"))
        try pair.a.perform(AddGradientSwatch(sunset, name: "Sunset"))
        pair.sync()
        let swatches = GradientSwatches.list(in: pair.a.state)
        try pair.a.perform(ApplyGradientSwatch(swatches[0].id, to: [fill.node]))
        try pair.b.perform(ApplyGradientSwatch(swatches[1].id, to: [fill.node]))
        pair.sync()
        // Both ramps have three stops, so both changes take the same counters and replica 0xB's
        // writes are the greater OpIds: its type and ramp stand, none of 0xA's stops read.
        for replica in [pair.a, pair.b] {
            let ramp = Self.ramp(fill, replica.state)
            #expect(ramp.map(\.color) == [Self.red, Self.blue, Self.green] && Self.gradient(fill, replica.state).type == .cone)
            #expect(Self.gradient(fill, replica.state).stops.count == 6)
        }
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        // A stop added to the losing ramp goes with it; one added to the standing ramp stays.
        try pair.a.perform(ApplyGradientSwatch(swatches[0].id, to: [fill.node]))
        pair.sync()
        let applied = Self.ramp(fill, pair.a.state).count
        try pair.b.perform(ApplyGradientSwatch(swatches[1].id, to: [fill.node]))
        try pair.a.perform(AddGradientStop(node: fill.node, row: fill.row, offset: 0.7, color: Self.blue))
        #expect(Self.ramp(fill, pair.a.state).count == applied + 1)
        pair.sync()
        for replica in [pair.a, pair.b] {
            #expect(Self.ramp(fill, replica.state).map(\.color) == [Self.red, Self.blue, Self.green])
        }
        try pair.b.perform(AddGradientStop(node: fill.node, row: fill.row, offset: 0.8, color: Self.red))
        pair.sync()
        #expect(Self.ramp(fill, pair.a.state).map(\.color) == [Self.red, Self.blue, Self.red, Self.green])
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
    }

    @Test func renameAndStopRecolorOfOneSwatchBothHold() throws {
        var pair = Pair()
        let (fill, _) = try Self.shaped(&pair.a)
        try pair.a.perform(AddGradientSwatch(node: fill.node, row: fill.row, name: "Plum", in: pair.a.state))
        pair.sync()
        let id = GradientSwatches.list(in: pair.a.state)[0].id
        try pair.a.perform(RenameGradientSwatch(id, name: "Aubergine"))
        try pair.b.perform(RemoveGradientSwatches([id]))
        pair.sync()
        #expect(GradientSwatches.list(in: pair.a.state).isEmpty && GradientSwatches.list(in: pair.b.state).isEmpty)
        #expect(pair.a.state.props(id).gradientSwatch.common.name == "Aubergine")
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
    }
}
