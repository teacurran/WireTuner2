import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// COLOR-014: colour adjustments, the register walker and the adjusting commands.
@Suite struct ColorAdjustmentTests {
    static func color(_ ref: Wiretuner_Doc_V1_ColorRef, _ state: EngineState) -> Color? {
        ColorResolver(state).color(ref)
    }

    @Test func eachStepsNumericEffectInRGBAndCMYK() {
        let gray = Color(red: 0.5, green: 0.5, blue: 0.5)
        #expect(close(ColorAdjustment.lighten.apply(gray), Color(red: 0.6, green: 0.6, blue: 0.6), 1e-9))
        #expect(close(ColorAdjustment.darken.apply(gray), Color(red: 0.4, green: 0.4, blue: 0.4), 1e-9))
        // Saturation: a muted red gains 10 points of HLS saturation.
        let muted = Color(red: 0.6, green: 0.4, blue: 0.4)
        let before = ColorModels.hls(muted, in: .sRGB)
        let saturated = ColorModels.hls(ColorAdjustment.saturate.apply(muted), in: .sRGB)
        #expect(abs(saturated.saturation - before.saturation - 0.1) < 1e-9 && abs(saturated.lightness - before.lightness) < 1e-9)
        let dull = ColorModels.hls(ColorAdjustment.desaturate.apply(muted), in: .sRGB)
        #expect(abs(before.saturation - dull.saturation - 0.1) < 1e-9)
        // CMYK is adjusted through its RGB rendering and written back as CMYK: 50% black -> 40%.
        let k50 = Color(cyan: 0, magenta: 0, yellow: 0, black: 0.5)
        let lighter = ColorAdjustment.lighten.apply(k50)
        #expect(lighter.space == .cmyk && close(lighter, Color(cyan: 0, magenta: 0, yellow: 0, black: 0.4), 1e-9))
        // Limits are reached and held.
        #expect(ColorAdjustment.lighten.apply(.white) == .white && ColorAdjustment.darken.apply(.black) == .black)
        #expect(ColorAdjustment.desaturate.apply(gray) == gray)
        var near = Color(red: 0.95, green: 0.95, blue: 0.95)
        near = ColorAdjustment.lighten.apply(near)
        #expect(close(near, .white, 1e-9) && ColorAdjustment.lighten.apply(near) == near)
        // Colour Control deltas in each mode, clamped.
        #expect(close(ColorAdjustment.control(.rgb, SIMD4(0.2, -0.9, 0, 0)).apply(gray), Color(red: 0.7, green: 0, blue: 0.5), 1e-9))
        let cmyk = ColorAdjustment.control(.cmyk, SIMD4(0.1, 0, 0, 0.8)).apply(k50)
        #expect(close(cmyk, Color(cyan: 0.1, magenta: 0, yellow: 0, black: 1), 1e-9))
        let hue = ColorAdjustment.control(.hls, SIMD4(120, 0, 0, 0)).apply(Color(red: 1, green: 0, blue: 0))
        #expect(close(hue, Color(red: 0, green: 1, blue: 0), 1e-9))
        let backward = ColorAdjustment.control(.hls, SIMD4(-120, 0, 0, 0)).apply(Color(red: 1, green: 0, blue: 0))
        #expect(close(backward, Color(red: 0, green: 0, blue: 1), 1e-9))
        // Adjusting in RGB keeps a CMYK colour CMYK; Lab stays Lab.
        #expect(ColorAdjustment.control(.rgb, SIMD4(0.1, 0.1, 0.1, 0)).apply(k50).space == .cmyk)
        #expect(ColorAdjustment.control(.cmyk, SIMD4(0, 0.1, 0, 0)).apply(gray).space == .sRGB)
        #expect(ColorAdjustment.lighten.apply(Color(labL: 40, a: 10, b: 10)).space == .lab)
        #expect(ColorAdjustment.lighten.verb == "Lighten colors" && ColorAdjustment.control(.hls, .zero).verb == "Adjust colors")
        #expect(ColorAdjustment.darken.verb == "Darken colors" && ColorAdjustment.saturate.verb == "Saturate colors"
            && ColorAdjustment.desaturate.verb == "Desaturate colors")
        // Grayscale: mid-gray is a 50% Black tint.
        #expect(abs(ColorAdjustment.grayPercent(gray) - 50) < 1e-9)
    }

    @Test func adjustEveryRegisterOfTheSelectionOnce() throws {
        var a = Replica(0xA)
        try a.perform(CreateDefaultSwatches())
        let grape = try ColorFixture.add(&a, ColorFixture.grape, name: "Grape")
        let spot = try ColorFixture.add(&a, ColorFixture.plum, name: "Ink", spot: true)
        let resolver = ColorResolver(a.state)
        let one = try ColorFixture.shape(&a, fill: resolver.reference(to: grape), stroke: Appearances.inline(red: 0.5, green: 0.5, blue: 0.5))
        let two = try ColorFixture.shape(&a, fill: resolver.reference(to: spot))
        let group = try a.perform(GroupObjects([one, two]))!.createdObjects[0]
        let text = try ColorFixture.markedText(&a, fill: Appearances.inline(red: 0.5, green: 0.5, blue: 0.5))
        // A gradient stop and a removed fill (its colour is not rewritten).
        let row = ColorFixture.fillRow(one, a.state)
        try a.perform(ChooseGradient([(one, row)]))
        try a.perform(AddAppearance.fill([one], Appearances.basicFill(red: 0.2, green: 0.2, blue: 0.2)))
        let doomed = AppearanceEditing.stack(one, in: a.state).last!
        try a.perform(RemoveAppearance(node: one, row: doomed))

        let uses = ColorRegisterWalker.uses([group, text], in: a.state)
        #expect(uses.contains { if case .mark = $0.location { true } else { false } })
        #expect(!uses.contains { if case .register(let path) = $0.location { path.description.contains("\(doomed.element)") } else { false } })

        let change = try a.perform(AdjustColors([group, text], .lighten))!
        #expect(change.label == "Lighten colors of 2 objects" && AdjustColors([one], .darken).label == "Darken colors")
        // The swatch reference became an unnamed colour, the swatch itself unchanged.
        let fill = ColorFixture.fill(one, a.state)
        guard case .inline? = fill.ref else { Issue.record("still a reference"); return }
        #expect(close(SwatchList(a.state)[grape]!.value, ColorFixture.grape))
        #expect(close(Self.color(fill, a.state), ColorAdjustment.lighten.apply(ColorFixture.grape), 1e-9))
        // Spot colours are skipped.
        #expect(ColorResolver.swatch(of: ColorFixture.fill(two, a.state)) == spot)
        // The gradient stops and the text mark were lightened.
        let stops = GradientReading.ramp(AppearanceEditing.entries(one, in: a.state).first { $0.row == row }!.fill.settings.gradient)
        #expect(stops.allSatisfy { if case .inline? = $0.color.ref { true } else { false } })
        let mark = ColorUses.uses(of: text, in: a.state).compactMap { use -> Wiretuner_Doc_V1_ColorRef? in
            if case .mark = use.location { return use.ref } else { return nil }
        }
        #expect(mark.contains { close(Self.color($0, a.state), Color(red: 0.6, green: 0.6, blue: 0.6), 1e-9) })
        // Undo restores every register.
        a.undo()
        #expect(ColorResolver.swatch(of: ColorFixture.fill(one, a.state)) == grape)
        // Nothing to change: no change.
        #expect(try a.perform(AdjustColors([two], .lighten)) == nil)
    }

    @Test func grayscaleMapsToBlackTints() throws {
        var a = Replica(0xA)
        try a.perform(CreateDefaultSwatches())
        let gray = try ColorFixture.shape(&a, fill: Appearances.inline(red: 0.5, green: 0.5, blue: 0.5),
                                          stroke: Appearances.inline(red: 1, green: 1, blue: 1))
        let change = try a.perform(ConvertToGrayscale([gray]))!
        #expect(change.label == "Convert to grayscale")
        let resolver = ColorResolver(a.state)
        let fill = ColorFixture.fill(gray, a.state)
        guard case .tint(let tint)? = fill.ref else { Issue.record("not a tint"); return }
        #expect(OpID(tint.base.id) == resolver.swatch(role: .black) && abs(tint.percent - 50) < 1)
        let stroke = a.state.props(gray).path.appearance.strokes[0].settings.basic.color
        #expect(ColorResolver.swatch(of: stroke) == resolver.swatch(role: .white))
        // Converting again changes nothing.
        #expect(try a.perform(ConvertToGrayscale([gray])) == nil)
        // Without the default swatches: an unnamed CMYK black.
        let bare = ColorResolver(EngineState())
        guard case .inline(let k)? = ConvertToGrayscale.gray(40, resolver: bare).ref else { Issue.record("not inline"); return }
        #expect(abs(k.cmyk.k - 0.4) < 1e-9)
        guard case .inline(let white)? = ConvertToGrayscale.gray(0.1, resolver: bare).ref else { Issue.record("not inline"); return }
        #expect(white.cmyk.k == 0)
    }

    @Test func randomizeGivesNamedColorsNewValuesInTheirSpaces() throws {
        var a = Replica(0xA)
        try a.perform(CreateDefaultSwatches())
        let named = try ColorFixture.add(&a, ColorFixture.grape, name: "Grape")
        let unnamed = try ColorFixture.add(&a, Color(red: 0.2, green: 0.4, blue: 0.6))
        let lab = try ColorFixture.add(&a, Color(labL: 50, a: 10, b: 10), name: "Clay")
        let ok = try ColorFixture.add(&a, Color(oklabL: 0.5, a: 0, b: 0), name: "Slate")
        let tint = try ColorFixture.tint(&a, of: named, 40)
        let change = try a.perform(RandomizeSwatches(seed: 42))!
        #expect(change.label == "Randomize named colors")
        let list = SwatchList(a.state)
        #expect(list[named]!.value.space == .cmyk && !close(list[named]!.value, ColorFixture.grape) && list[named]!.name == "Grape")
        #expect(list[unnamed]!.value.space == .sRGB && list[unnamed]!.hasDefaultName, "a default name follows the new value")
        #expect(list[lab]!.value.space == .lab && list[ok]!.value.space == .oklab)
        #expect(list[tint]!.isTint && list.swatches.filter(\.isProtected).count == 3)
        let black = list.resolver.swatch(role: .black)!
        #expect(close(list[black]!.value, Color(cyan: 0, magenta: 0, yellow: 0, black: 1)))
        // Repeatable by seed.
        var b = Replica(0xB)
        b.receive(Array(a.sent.dropLast()))
        try b.perform(RandomizeSwatches(seed: 42))
        #expect(SwatchList(b.state)[named]!.value == list[named]!.value)
    }

    @Test func theWalkerVisitsEachNodeOnce() throws {
        var a = Replica(0xA)
        let shape = try ColorFixture.shape(&a, fill: Appearances.inline(red: 0.5, green: 0.5, blue: 0.5))
        let once = ColorRegisterWalker.uses([shape], in: a.state)
        #expect(ColorRegisterWalker.uses([shape, shape, OpID(counter: 999, replica: 9)], in: a.state) == once)
    }

    // MARK: Merges

    @Test func twoClientsLighteningOneObjectMakeOneStep() throws {
        var pair = Pair()
        let shape = try ColorFixture.shape(&pair.a, fill: Appearances.inline(red: 0.5, green: 0.5, blue: 0.5))
        pair.sync()
        try pair.a.perform(AdjustColors([shape], .lighten))
        try pair.b.perform(AdjustColors([shape], .lighten))
        pair.sync()
        for replica in [pair.a, pair.b] {
            #expect(close(Self.color(ColorFixture.fill(shape, replica.state), replica.state), Color(red: 0.6, green: 0.6, blue: 0.6), 1e-9))
        }
    }

    @Test func randomizeOnTwoClientsConverges() throws {
        var pair = Pair()
        try pair.a.perform(CreateDefaultSwatches())
        try ColorFixture.add(&pair.a, ColorFixture.grape, name: "Grape")
        try ColorFixture.add(&pair.a, ColorFixture.plum, name: "Plum")
        pair.sync()
        try pair.a.perform(RandomizeSwatches(seed: 1))
        try pair.b.perform(RandomizeSwatches(seed: 2))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
    }

    @Test func inlineWrittenOverASwatchReference() throws {
        // What a conformance vector would pin: the register holding a `swatch` reference takes an
        // `inline` value by one SetFields, and a concurrent re-reference by another replica with a
        // later id wins whole (ATOMIC ColorRef).
        var pair = Pair()
        try pair.a.perform(CreateDefaultSwatches())
        let grape = try ColorFixture.add(&pair.a, ColorFixture.grape, name: "Grape")
        let shape = try ColorFixture.shape(&pair.a, fill: ColorResolver(pair.a.state).reference(to: grape))
        pair.sync()
        let change = try pair.a.perform(AdjustColors([shape], .darken))!
        #expect(change.ops.count == 1 && change.ops[0].set.paths.count == 1)
        pair.sync()
        guard case .inline? = ColorFixture.fill(shape, pair.b.state).ref else { Issue.record("b still references the swatch"); return }
    }
}
