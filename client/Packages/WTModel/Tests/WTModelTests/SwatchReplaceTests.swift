import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto

/// COLOR-015: *Replace…* from the colour list and from a library (editing-colors.adoc, "Replacing a
/// color", "Merge semantics").
@Suite struct SwatchReplaceTests {
    static func pair(_ setup: (inout Replica) throws -> Void = { _ in }) throws -> Pair {
        var pair = Pair()
        try pair.a.perform(CreateDefaultSwatches())
        try setup(&pair.a)
        pair.sync()
        return pair
    }

    /// A style node whose text underline colour (inside an ATOMIC message) names `ref`.
    static func styleNaming(_ ref: Wiretuner_Doc_V1_ColorRef, on replica: inout Replica) throws -> OpID {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.style.kind = .character
        props.style.text.character.effect.underline.color = ref
        props.style.text.character.effect.underline.width = 1
        return ColorFixture.created(try replica.perform(OpsCommand("Style", ops: [Ops.create(parent: .wellKnown(6), position: [0x80], props: props)])))[0]
    }

    @Test func replacingFromTheListRewritesReferencesRebasesTintsAndRemovesTheOriginal() throws {
        var a = Replica(1)
        try a.perform(CreateDefaultSwatches())
        let grape = try ColorFixture.add(&a, ColorFixture.grape, name: "Grape")
        let plum = try ColorFixture.add(&a, ColorFixture.plum, name: "Plum")
        let tint = try ColorFixture.tint(&a, of: grape, 40, name: "Pale grape")
        var list = SwatchList(a.state)
        let shape = try ColorFixture.shape(&a, fill: list.resolver.reference(to: grape), stroke: list.resolver.tint(of: grape, percent: 25))
        let text = try ColorFixture.markedText(&a, fill: list.resolver.reference(to: grape))
        let style = try Self.styleNaming(list.resolver.reference(to: grape), on: &a)
        // A fill that was removed keeps naming Grape: nobody sees it.
        let hidden = try ColorFixture.shape(&a, fill: list.resolver.reference(to: grape))
        let row = ColorFixture.fillRow(hidden, a.state)
        try a.perform(OpsCommand("Remove fill", ops: [Ops.elementDelete(hidden, [PathFields.appearance.child(1).element(row.element)])]))

        let command = ReplaceSwatch(grape, with: .swatch(plum), in: a.state)
        #expect(command.label == "Replace \"Grape\" with \"Plum\"")
        let change = try #require(try a.perform(command))
        #expect(change.label == command.label)
        list = SwatchList(a.state)
        #expect(list[grape] == nil && list[plum] != nil)
        #expect(ColorResolver.swatch(of: ColorFixture.fill(shape, a.state)) == plum)
        let stroke = a.state.props(shape).path.appearance.strokes[0].settings.basic.color
        #expect(stroke.tint.base.id == plum.proto && stroke.tint.percent == 25)
        #expect(stroke.tint.base.cached == ColorValues.cached(ColorFixture.plum))
        #expect(list[tint]?.base == plum && close(list[tint]?.color, ColorFixture.plum.tinted(0.4)))
        let marks = ColorUses.uses(of: text, in: a.state).filter { if case .mark = $0.location { return true } else { return false } }
        #expect(marks.contains { $0.swatch == plum })
        // The nested colour and the removed fill are left naming Grape.
        #expect(ColorUses.uses(of: style, in: a.state).first?.swatch == grape)
        #expect(ColorUses.uses(of: hidden, in: a.state).contains { $0.swatch == grape })
        // One undo step brings everything back.
        a.undo()
        list = SwatchList(a.state)
        #expect(list[grape] != nil && list[tint]?.base == grape && ColorResolver.swatch(of: ColorFixture.fill(shape, a.state)) == grape)
    }

    @Test func refusals() throws {
        var a = Replica(1)
        try a.perform(CreateDefaultSwatches())
        let grape = try ColorFixture.add(&a, ColorFixture.grape, name: "Grape")
        let tint = try ColorFixture.tint(&a, of: grape, 40)
        let deep = try ColorFixture.tint(&a, of: tint, 50)
        let list = SwatchList(a.state)
        let white = try #require(list.resolver.swatch(role: .white))
        let black = try #require(list.resolver.swatch(role: .black))
        #expect(throws: SwatchError.protected(white)) { try a.perform(ReplaceSwatch(white, with: .swatch(grape), in: a.state)) }
        #expect(throws: SwatchError.notASwatch(.wellKnown(99))) { try a.perform(ReplaceSwatch(grape, with: .swatch(.wellKnown(99)), in: a.state)) }
        #expect(throws: SwatchError.loop(grape)) { try a.perform(ReplaceSwatch(grape, with: .swatch(grape), in: a.state)) }
        #expect(throws: SwatchError.loop(deep)) { try a.perform(ReplaceSwatch(grape, with: .swatch(deep), in: a.state)) }
        #expect(ReplaceSwatch(.wellKnown(99), with: .swatch(.wellKnown(98)), in: a.state).label == "Replace \"color\" with \"color\"")
        // Replacing with a protected swatch is allowed: the original is the one removed.
        let index = SwatchIndex(a.state)
        try a.perform(ReplaceSwatch(grape, with: .swatch(black), in: a.state, index: index))
        #expect(SwatchList(a.state)[tint]?.base == black && SwatchList(a.state)[grape] == nil)
    }

    @Test func replacingFromALibraryEditsTheSwatchInPlace() throws {
        var a = Replica(1)
        try a.perform(CreateDefaultSwatches())
        let grape = try ColorFixture.add(&a, ColorFixture.grape, name: "Grape")
        let tint = try ColorFixture.tint(&a, of: grape, 40, name: "Pale")
        let shape = try ColorFixture.shape(&a, fill: SwatchList(a.state).resolver.reference(to: grape))
        var color = Wiretuner_Lib_V1_LibraryColor()
        color.key = "300 C"
        color.name = "PANTONE 300 C"
        color.value = ColorValues.stored(ColorFixture.red)
        color.spot = true
        let command = ReplaceSwatch(grape, with: .library(color, origin: "pantone-solid-coated"), in: a.state)
        #expect(command.label == "Replace \"Grape\" with \"PANTONE 300 C\"")
        try a.perform(command)
        let swatch = try #require(SwatchList(a.state)[grape])
        #expect(swatch.name == "PANTONE 300 C" && swatch.isSpot && swatch.library == "pantone-solid-coated" && swatch.libraryKey == "300 C")
        #expect(close(swatch.value, ColorFixture.red))
        #expect(ColorResolver.swatch(of: ColorFixture.fill(shape, a.state)) == grape)
        // A tint takes a library tint's resolved value and stops being a tint; a taken name is kept.
        var pale = Wiretuner_Lib_V1_LibraryColor()
        pale.key = "PANTONE 300 C"
        pale.value = ColorValues.stored(ColorFixture.plum)
        pale.tintPercent = 50
        let tintCommand = ReplaceSwatch(tint, with: .library(pale, origin: "x"), in: a.state)
        #expect(tintCommand.label == "Replace \"Pale\" with \"PANTONE 300 C\"")
        try a.perform(tintCommand)
        let replaced = try #require(SwatchList(a.state)[tint])
        #expect(!replaced.isTint && replaced.name == "Pale" && close(replaced.color, ColorFixture.plum.tinted(0.5)))
    }

    @Test func replaceVersusConcurrentApplyLeavesTheObjectShowingTheOldColour() throws {
        var grape = OpID.zero
        var plum = OpID.zero
        var shape = OpID.zero
        var pair = try Self.pair {
            grape = try ColorFixture.add(&$0, ColorFixture.grape, name: "Grape")
            plum = try ColorFixture.add(&$0, ColorFixture.plum, name: "Plum")
            shape = try ColorFixture.shape(&$0, fill: ColorResolver.inline(.white))
        }
        try pair.a.perform(ReplaceSwatch(grape, with: .swatch(plum), in: pair.a.state))
        let ref = SwatchList(pair.b.state).resolver.reference(to: grape)
        try pair.b.perform(SetAppearanceColor([(shape, ColorFixture.fillRow(shape, pair.b.state))], color: ref))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        for replica in [pair.a, pair.b] {
            let resolver = ColorResolver(replica.state)
            let fill = ColorFixture.fill(shape, replica.state)
            #expect(resolver.isDangling(fill) && ColorResolver.swatch(of: fill) == grape)
            #expect(close(resolver.color(fill), ColorFixture.grape, 1e-4))
        }
    }

    @Test func replaceVersusConcurrentDeleteOfTheTargetRelinksOnRestore() throws {
        var grape = OpID.zero
        var plum = OpID.zero
        var shape = OpID.zero
        var tint = OpID.zero
        var pair = try Self.pair {
            grape = try ColorFixture.add(&$0, ColorFixture.grape, name: "Grape")
            plum = try ColorFixture.add(&$0, ColorFixture.plum, name: "Plum")
            tint = try ColorFixture.tint(&$0, of: grape, 30)
            shape = try ColorFixture.shape(&$0, fill: SwatchList($0.state).resolver.reference(to: grape))
        }
        try pair.a.perform(ReplaceSwatch(grape, with: .swatch(plum), in: pair.a.state))
        try pair.b.perform(RemoveSwatches([plum]))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let resolver = ColorResolver(pair.a.state)
        let fill = ColorFixture.fill(shape, pair.a.state)
        #expect(ColorResolver.swatch(of: fill) == plum && resolver.isDangling(fill))
        #expect(close(resolver.color(fill), ColorFixture.plum, 1e-4))
        // Restore Plum: every rewritten reference is live again, with no write on the objects.
        try pair.b.perform(RestoreSwatches([plum]))
        pair.sync()
        for replica in [pair.a, pair.b] {
            #expect(!ColorResolver(replica.state).isDangling(ColorFixture.fill(shape, replica.state)))
            #expect(SwatchList(replica.state)[tint]?.base == plum)
        }
    }

    @Test func replacingASwatchUsedByTenThousandRegistersIsOneQuickChange() throws {
        var a = Replica(1)
        try a.perform(CreateDefaultSwatches())
        let grape = try ColorFixture.add(&a, ColorFixture.grape, name: "Grape")
        let plum = try ColorFixture.add(&a, ColorFixture.plum, name: "Plum")
        let count = PerfBudget.isMeasuring ? 10_000 : 1_000
        let ref = SwatchList(a.state).resolver.reference(to: grape)
        var fill = Wiretuner_Doc_V1_Fill()
        fill.settings.kind = .basic
        fill.settings.basic.color = ref
        var props = Wiretuner_Doc_V1_NodeProps()
        props.rect.appearance.fills = [fill]
        props.rect.size.width = 10
        props.rect.size.height = 10
        try a.perform(ManyShapes(props: props, count: count))
        let index = SwatchIndex(a.state)
        let command = ReplaceSwatch(grape, with: .swatch(plum), in: a.state, index: index)
        let clock = ContinuousClock()
        var change: Wiretuner_Doc_V1_Change?
        let elapsed = try clock.measure { change = try a.perform(command) }
        #expect(change?.ops.count == count + 1)
        #expect(SwatchIndex(a.state).liveDependents(of: plum, in: a.state).count == count)
        PerfBudget.expect(elapsed, within: .milliseconds(100), "replace color, \(count) registers")
        a.undo()
        #expect(SwatchIndex(a.state).liveDependents(of: grape, in: a.state).count == count)
    }
}

/// `count` copies of a shape on a new layer, in one change.
struct ManyShapes: Command {
    let props: Wiretuner_Doc_V1_NodeProps
    let count: Int
    var label: String { "Shapes" }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let layer = builder.append(Fixture.createLayer("Shapes"))
        let keys = try PathEditing.keys(between: nil, and: nil, count: count)
        for key in keys {
            try NodeCopier.create(NodeTree(props: props), parent: layer, position: key, schema: state.schema, builder: &builder)
        }
    }
}
