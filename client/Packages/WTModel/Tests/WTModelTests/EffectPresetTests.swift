import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// FX-008's and FX-014's commands: the Add Effect submenu presets, the raster effects resolution of
/// the document and of an object, and the Gradient Mask stop editing.
@Suite struct EffectPresetTests {
    static func effects(_ node: OpID, _ state: EngineState) -> [EffectEntry] {
        EffectReading.entries(node, in: state)
    }

    @Test func presetsAddTheirStyleAtTheChosenLevel() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let stroke = AppearanceEditing.stack(rect, in: a.state)[0]
        let presets: [EffectPreset] = [
            .bevel(.outerBevel), .bevel(.innerBevel), .bevel(.raisedEmboss), .bevel(.insetEmboss), .blur(.basic), .blur(.gaussian),
            .shadow(.dropShadow), .shadow(.innerShadow), .shadow(.glow), .shadow(.innerGlow), .sharpen(.basic), .sharpen(.unsharpMask),
            .transparency(.basic), .transparency(.feather), .transparency(.gradientMask),
        ]
        #expect(Set(presets.map(\.title)).count == presets.count)
        for preset in presets {
            let change = try #require(try a.perform(AddEffectPreset([rect], preset: preset)))
            #expect(change.label == "Add \(preset.title) effect")
            let top = try #require(Self.effects(rect, a.state).last)
            #expect(top.kind == preset.kind && top.attachment == .object)
            switch preset {
            case .bevel(let style): #expect(top.effect.settings.bevelEmboss.style == style)
            case .blur(let style): #expect(top.effect.settings.blur.style == style)
            case .shadow(let style): #expect(top.effect.settings.shadow.style == style)
            case .sharpen(let style): #expect(top.effect.settings.sharpen.style == style)
            case .transparency(let style): #expect(top.effect.settings.transparency.style == style)
            }
        }
        // The gradient mask starts black to white; its stops are elements of their own.
        let mask = try #require(Self.effects(rect, a.state).last)
        let ramp = MaskReading.ramp(mask.effect)
        #expect(ramp.count == 2 && MaskReading.gray(ramp[0].color, in: a.state) < 0.01 && MaskReading.gray(ramp[1].color, in: a.state) > 0.99)
        #expect(ramp.allSatisfy { $0.id != .zero })
        // Attached to a fill or stroke, and above a row; not onto an effect.
        try a.perform(AddEffectPreset([rect], preset: .blur(.basic), attachTo: [rect: stroke]))
        #expect(Self.effects(rect, a.state).first?.attachment == .element(stroke))
        try a.perform(AddEffectPreset([rect], preset: .sharpen(.basic), above: [rect: stroke]))
        let effect = AppearanceEditing.stack(rect, in: a.state).first { $0.list == .effects }!
        #expect(throws: PathEditError.unknownPoint(effect.element)) { try a.perform(AddEffectPreset([rect], preset: .blur(.basic), attachTo: [rect: effect])) }
        // A glow takes the object's top fill colour when it has one.
        var appearance = Appearances.standard
        appearance.fills = [Appearances.basicFill(red: 1, green: 0, blue: 0)]
        let red = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10), appearance: appearance), on: &a)
        try a.perform(AddEffectPreset([red], preset: .shadow(.glow)))
        #expect(Self.effects(red, a.state).last?.effect.settings.shadow.color == Appearances.basicFill(red: 1, green: 0, blue: 0).settings.basic.color)
        #expect(EffectPreset.shadow(.dropShadow).settings(seed: 1, glow: ColorResolver.inline(.white)).shadow.color == ColorResolver.inline(.black))
    }

    @Test func rasterResolutionsOfTheDocumentAndObjects() throws {
        var pair = Pair()
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &pair.a)
        pair.sync()
        #expect(ChangeRasterEffectSettings.read(pair.a.state) == (72, false))
        let change = try #require(try pair.a.perform(ChangeRasterEffectSettings(resolution: 300)))
        #expect(change.label == "Change raster effects settings")
        #expect(ChangeRasterEffectSettings.read(pair.a.state) == (300, false))
        // Resolution on one replica, Optimal CMYK on the other: both kept.
        try pair.b.perform(ChangeRasterEffectSettings(optimalCMYK: true))
        pair.sync()
        #expect(ChangeRasterEffectSettings.read(pair.a.state) == (300, true) && ChangeRasterEffectSettings.read(pair.b.state) == (300, true))
        #expect(throws: ObjectEditError.invalidValue("resolution")) { try pair.a.perform(ChangeRasterEffectSettings(resolution: 0)) }
        #expect(try pair.a.perform(ChangeRasterEffectSettings()) == nil)
        // An object's own resolution, and back to the document's.
        #expect(SetObjectRasterResolution.read(rect, in: pair.a.state) == 0)
        let own = try #require(try pair.a.perform(SetObjectRasterResolution([rect], ppi: 150)))
        #expect(own.label == "Change raster resolution" && SetObjectRasterResolution.read(rect, in: pair.a.state) == 150)
        try pair.a.perform(SetObjectRasterResolution([rect], ppi: 0))
        #expect(SetObjectRasterResolution.read(rect, in: pair.a.state) == 0)
        #expect(throws: ObjectEditError.invalidValue("ppi")) { try pair.a.perform(SetObjectRasterResolution([rect], ppi: 5000)) }
        #expect(throws: (any Error).self) { try pair.a.perform(SetObjectRasterResolution([WellKnown.layers], ppi: 10)) }
    }

    @Test func maskStopsEditAndMergeOneByOne() throws {
        var pair = Pair()
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &pair.a)
        try pair.a.perform(AddEffect([rect], kind: .transparency))
        let row = try #require(Self.effects(rect, pair.a.state).last?.row)
        // Choosing Gradient Mask seeds a ramp once.
        let chose = try #require(try pair.a.perform(ChooseGradientMask([(rect, row)])))
        #expect(chose.label == "Change transparency")
        var effect = try #require(Self.effects(rect, pair.a.state).last?.effect)
        #expect(effect.settings.transparency.style == .gradientMask && effect.settings.transparency.mask.type == .linear && MaskReading.ramp(effect).count == 2)
        try pair.a.perform(ChooseGradientMask([(rect, row)]))
        #expect(MaskReading.ramp(Self.effects(rect, pair.a.state).last!.effect).count == 2)
        pair.sync()
        // Two replicas add a stop each: both kept.
        try pair.a.perform(AddMaskStop(node: rect, row: row, offset: 0.3, gray: 0.5))
        try pair.b.perform(AddMaskStop(node: rect, row: row, offset: 0.7, gray: 0.2))
        pair.sync()
        effect = try #require(Self.effects(rect, pair.a.state).last?.effect)
        let ramp = MaskReading.ramp(effect)
        #expect(ramp.map(\.offset) == [0, 0.3, 0.7, 1] && pair.a.state.stateHash == pair.b.state.stateHash)
        // Move and regray a stop; remove one; the ramp keeps two.
        let moved = try #require(try pair.a.perform(EditMaskStop(node: rect, row: row, stop: ramp[1].id, offset: 0.4, gray: 0.25)))
        #expect(moved.label == "Change mask stop")
        let edited = MaskReading.ramp(Self.effects(rect, pair.a.state).last!.effect)
        #expect(edited[1].offset == 0.4 && abs(MaskReading.gray(edited[1].color, in: pair.a.state) - 0.25) < 0.01)
        try pair.a.perform(EditMaskStop(node: rect, row: row, stop: ramp[1].id, gray: 2))
        #expect(MaskReading.gray(MaskReading.ramp(Self.effects(rect, pair.a.state).last!.effect)[1].color, in: pair.a.state) > 0.99)
        #expect(try pair.a.perform(EditMaskStop(node: rect, row: row, stop: ramp[1].id)) == nil)
        #expect(throws: ObjectEditError.invalidValue("stop")) { try pair.a.perform(EditMaskStop(node: rect, row: row, stop: ramp[1].id, offset: .nan)) }
        #expect(throws: PathEditError.unknownPoint(OpID(counter: 9999, replica: 9))) {
            try pair.a.perform(EditMaskStop(node: rect, row: row, stop: OpID(counter: 9999, replica: 9), offset: 0.1))
        }
        try pair.a.perform(RemoveMaskStop(node: rect, row: row, stop: ramp[1].id))
        try pair.a.perform(RemoveMaskStop(node: rect, row: row, stop: ramp[2].id))
        let two = MaskReading.ramp(Self.effects(rect, pair.a.state).last!.effect)
        #expect(two.count == 2)
        #expect(throws: ObjectEditError.invalidValue("stop")) { try pair.a.perform(RemoveMaskStop(node: rect, row: row, stop: two[0].id)) }
        #expect(throws: ObjectEditError.invalidValue("stop")) { try pair.a.perform(AddMaskStop(node: rect, row: row, offset: .infinity, gray: 0)) }
        // The type.
        let typed = try #require(try pair.a.perform(SetMaskGradientType([(rect, row)], type: .radial)))
        #expect(typed.label == "Change mask type" && Self.effects(rect, pair.a.state).last?.effect.settings.transparency.mask.type == .radial)
        // Not a transparency effect.
        try pair.a.perform(AddEffect([rect], kind: .blur))
        let blur = try #require(Self.effects(rect, pair.a.state).last?.row)
        #expect(throws: ObjectEditError.invalidValue("kind")) { try pair.a.perform(SetMaskGradientType([(rect, blur)], type: .linear)) }
        #expect(MaskReading.gray(Wiretuner_Doc_V1_ColorRef(), in: pair.a.state) == 0)
    }
}
