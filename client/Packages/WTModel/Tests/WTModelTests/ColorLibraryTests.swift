import Foundation
import Testing
import WTCRDT
@testable import WTModel
import WTProto
import WTRender

/// Colour libraries in the document (COLOR-013's and COLOR-021's WTModel half), the `ColorRef`
/// pasteboard payload (COLOR-008's model half) and the colour settings (CMS-004).
@Suite struct ColorLibraryTests {
    static func color(_ key: String, _ value: Color, spot: Bool = false, tintOf: String = "", percent: Double = 0) -> Wiretuner_Lib_V1_LibraryColor {
        var color = Wiretuner_Lib_V1_LibraryColor()
        color.key = key
        color.name = key
        color.value = ColorValues.stored(value)
        color.spot = spot
        color.tintOf = tintOf
        color.tintPercent = percent
        return color
    }

    static var library: Wiretuner_Lib_V1_ColorLibrary {
        var library = Wiretuner_Lib_V1_ColorLibrary()
        library.name = "Brand"
        library.colors = [
            color("Light Grape", ColorFixture.grape, tintOf: "Grape", percent: 40),
            color("Grape", ColorFixture.grape, spot: true),
            color("Plum", ColorFixture.plum),
            color("Loose tint", ColorFixture.red, percent: 50),
            color("P3 Red", Color(displayP3Red: 1, green: 0, blue: 0)),
            color("Ink", Color(oklabL: 0.5, a: 0.1, b: 0.1)),
        ]
        return library
    }

    @Test func importCreatesSwatchesTintsAndOrigins() throws {
        var replica = try SwatchTests.document()
        try ColorFixture.add(&replica, ColorFixture.red, name: "Plum")
        let change = try replica.perform(ImportLibraryColors(Self.library, keys: ["Light Grape", "Plum", "Loose tint", "P3 Red", "Ink"]))!
        #expect(change.label == "Import 5 colors from \"Brand\"")
        let list = SwatchList(replica.state)
        let grape = try #require(list.named("Grape"))
        #expect(grape.isSpot && grape.library == "Brand" && grape.libraryKey == "Grape" && grape.section == "Brand")
        let light = try #require(list.named("Light Grape"))
        #expect(light.base == grape.id && light.tintPercent == 40 && light.depth == 1)
        // "Plum" clashed with a swatch already there: renamed to its mix values.
        let plum = try #require(list.swatches.first { $0.libraryKey == "Plum" })
        #expect(plum.name == ColorText.defaultName(ColorFixture.plum))
        #expect(list.named("Loose tint")?.color == ColorFixture.red.tinted(0.5))
        #expect(list.named("P3 Red")?.badge == "P3" && list.named("Ink")?.badge == "OKLab")
        #expect(ColorLibraries.present(Self.library, origin: "Brand", in: list) == ["Light Grape", "Grape", "Plum", "Loose tint", "P3 Red", "Ink"])
        // Importing again adds nothing.
        #expect(try replica.perform(ImportLibraryColors(Self.library)) == nil)
    }

    @Test func exportedLibrariesRoundTripThroughImport() throws {
        var replica = try SwatchTests.document()
        try replica.perform(ImportLibraryColors(Self.library, group: ""))
        let list = SwatchList(replica.state)
        let exported = ColorLibraries.library(named: "Out", swatches: list.swatches.map(\.id), list: list)
        #expect(exported.colors.count == 6)
        #expect(exported.colors.first { $0.key == "Light Grape" }?.tintOf == "Grape")
        var other = try SwatchTests.document()
        try other.perform(ImportLibraryColors(exported, group: ""))
        let again = ColorLibraries.library(named: "Out", swatches: SwatchList(other.state).swatches.map(\.id), list: SwatchList(other.state))
        #expect(try again.serializedBytes() as [UInt8] == exported.serializedBytes())
        // A tint exported without its base carries the base's colour and no tint_of.
        let light = list.named("Light Grape")!.id
        let alone = ColorLibraries.library(named: "Tint", swatches: [light], list: list)
        #expect(alone.colors.count == 1 && alone.colors[0].tintOf.isEmpty && ColorValues.color(alone.colors[0].value) == ColorFixture.grape)
        // A tint whose base was removed exports its cached base.
        try replica.perform(OpsCommand("Delete", ops: [Ops.setDeleted(list.named("Grape")!.id)]))
        let orphan = ColorLibraries.library(named: "Tint", swatches: [light], list: SwatchList(replica.state))
        #expect(ColorValues.color(orphan.colors[0].value) == ColorFixture.grape)
        // A colour with no name takes its key.
        var unnamed = Wiretuner_Lib_V1_ColorLibrary()
        unnamed.name = "Keys"
        unnamed.colors = [Self.color("K1", .white)]
        unnamed.colors[0].name = ""
        try replica.perform(ImportLibraryColors(unnamed))
        #expect(SwatchList(replica.state).named("K1")?.libraryKey == "K1")
        #expect(LibraryUpdate.classify(replica.state, library: unnamed, origin: "Keys").map(\.status) == [.unchanged])
    }

    @Test func updateFromLibraryClassifiesAndUpdates() throws {
        var replica = try SwatchTests.document()
        try replica.perform(ImportLibraryColors(Self.library, origin: ColorLibraries.teamOrigin("doc-1")))
        var list = SwatchList(replica.state)
        let origin = ColorLibraries.teamOrigin("doc-1")
        #expect(origin == "team:doc-1")
        #expect(LibraryUpdate.classify(replica.state, library: Self.library, origin: origin).allSatisfy { $0.status == .unchanged })
        // The library recolours Grape and Plum and drops Ink; locally, Plum is recoloured and P3 Red renamed.
        var newer = Self.library
        newer.colors[1].value = ColorValues.stored(ColorFixture.red)
        newer.colors[2].value = ColorValues.stored(.white)
        newer.colors[0].tintPercent = 60
        newer.colors.removeLast()
        try replica.perform(RedefineSwatch(list.named("Plum")!.id, to: .black))
        try replica.perform(RenameSwatch(list.named("P3 Red")!.id, to: "Hot"))
        let updates = Dictionary(uniqueKeysWithValues: LibraryUpdate.classify(replica.state, library: newer, origin: origin).map { ($0.key, $0.status) })
        #expect(updates == ["Grape": .libraryChanged, "Light Grape": .libraryChanged, "Plum": .editedLocally, "P3 Red": .editedLocally,
                            "Loose tint": .unchanged, "Ink": .removedFromLibrary])
        let change = try replica.perform(UpdateSwatchesFromLibrary(newer, origin: origin, names: true, spot: true))!
        #expect(change.label == "Update colors from \"Brand\"")
        list = SwatchList(replica.state)
        #expect(list.named("Grape")?.color == ColorFixture.red.asSpot(SpotInk(swatch: NodeID(list.named("Grape")!.id), name: "Grape")))
        #expect(list.named("Light Grape")?.tintPercent == 60)
        #expect(list.named("P3 Red") != nil && list.named("Plum")?.color == .white)
        #expect(LibraryUpdate.classify(replica.state, library: newer, origin: origin).filter { $0.status != .unchanged }.map(\.key) == ["Ink"])
        #expect(try replica.perform(UpdateSwatchesFromLibrary(newer, origin: origin, names: true, spot: true)) == nil)
        // A library colour that became a tint, and one whose name is taken, update the colour only.
        var third = newer
        third.colors[3] = Self.color("Loose tint", .white, spot: false)
        third.colors[3].name = "Grape"
        let loose = list.named("Loose tint")!.id
        try replica.perform(UpdateSwatchesFromLibrary(third, origin: origin, swatches: [loose], names: true))
        #expect(SwatchList(replica.state)[loose]?.name == "Loose tint" && SwatchList(replica.state)[loose]?.color == .white)
    }

    @Test func updatesOfOneVersionFromTwoReplicasConverge() throws {
        var pair = Pair()
        try pair.a.perform(CreateDefaultSwatches())
        try pair.a.perform(ImportLibraryColors(Self.library))
        pair.sync()
        var newer = Self.library
        newer.colors[2].value = ColorValues.stored(.white)
        try pair.a.perform(UpdateSwatchesFromLibrary(newer))
        try pair.b.perform(UpdateSwatchesFromLibrary(newer))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(SwatchList(pair.a.state).named("Plum")?.color == .white)
        // Two clients importing the same colour: two swatches and the duplicate marker.
        var library = Wiretuner_Lib_V1_ColorLibrary()
        library.name = "Other"
        library.colors = [Self.color("Teal", Color(red: 0, green: 0.5, blue: 0.5))]
        try pair.a.perform(ImportLibraryColors(library))
        try pair.b.perform(ImportLibraryColors(library))
        pair.sync()
        let list = SwatchList(pair.a.state)
        #expect(Set(list.swatches.filter { $0.plainName == "Teal" }.map(\.name)) == ["Teal", "Teal (2)"])
        // Present from both: importing again adds nothing.
        #expect(try pair.a.perform(ImportLibraryColors(library)) == nil)
    }

    @Test func pasteboardCarriesTheReferenceColourAndLibrary() throws {
        var replica = try SwatchTests.document()
        let grape = try ColorFixture.add(&replica, ColorFixture.grape, name: "Grape", spot: true)
        let tint = try ColorFixture.tint(&replica, of: grape, 50)
        let list = SwatchList(replica.state)
        let drag = ColorRefPasteboard(swatch: grape, list: list, document: "doc")
        #expect(drag.name == "Grape" && drag.spot && drag.library?.colors.map(\.key) == ["Grape", "50% Grape"])
        let decoded = try #require(ColorRefPasteboard(data: drag.data()))
        #expect(decoded.ref == drag.ref && decoded.name == "Grape" && decoded.document == "doc" && decoded.library == drag.library)
        #expect(decoded.color == ColorFixture.grape)
        #expect(ColorRefPasteboard(data: Data("nope".utf8)) == nil)
        // Same document: the reference; another document: the colour inline.
        #expect(drag.reference(in: replica.state, document: "doc") == drag.ref)
        #expect(drag.reference(in: replica.state, document: "other") == ColorResolver.inline(drag.color!))
        let none = ColorRefPasteboard(ref: ColorResolver.none, color: nil)
        #expect(none.reference(in: replica.state, document: "x") == ColorResolver.none && none.foreignColor == nil)
        let inline = ColorRefPasteboard(ref: ColorResolver.inline(ColorFixture.red), list: list, document: "doc")
        #expect(inline.reference(in: replica.state, document: "doc") == inline.ref && inline.name.isEmpty)
        let unnamedTint = ColorRefPasteboard(ref: list.resolver.tint(of: grape, percent: 20), list: list)
        #expect(unnamedTint.spot && unnamedTint.library == nil)
        #expect(ColorRefPasteboard(swatch: list.swatches[0].id, list: list).library == nil)
        #expect(ColorRefPasteboard(swatch: tint, list: list).name == "50% Grape")
        var lost = ColorRefPasteboard(ref: list.resolver.reference(to: grape), color: nil, document: "doc")
        lost.ref.swatch.id = OpID(counter: 999, replica: 3).proto
        #expect(lost.reference(in: replica.state, document: "doc") == ColorResolver.none)
        // Other applications get P3 as P3 and everything else as sRGB.
        #expect(ColorRefPasteboard(ref: ColorResolver.none, color: Color(displayP3Red: 1, green: 0, blue: 0)).foreignColor?.space == .displayP3)
        #expect(drag.foreignColor?.space == .sRGB)
        #expect(ColorRefPasteboard.typeIdentifier == "com.villagecompute.wiretuner.colorref")
    }

    // MARK: CMS-004

    @Test func newDocumentsReadTheDefaultColorSettings() {
        let settings = ColorSettings(EngineState())
        let registry = WTColor.ProfileRegistry.shared
        #expect(settings.rgbProfile == registry.sRGB && settings.cmykProfile == registry.defaultCMYK)
        #expect(settings.defaultImageRGBProfile == registry.sRGB && settings.compositeProfile == registry.defaultCMYK)
        #expect(settings.intent == .relativeColorimetric && settings.blackPointCompensation && settings.spotColorManagement)
        #expect(settings.proofTarget == .none && settings.proof == nil && !settings.pending)
        #expect(settings.colorManagement().cmykProfile == registry.defaultCMYK)
    }

    @Test func readTimeNormalizationsAndPending() {
        let registry = WTColor.ProfileRegistry.shared
        var stored = Wiretuner_Doc_V1_ColorSettings()
        // An RGB profile written as Working CMYK reads as unset.
        stored.cmykProfile = ColorSettings.stored(registry.sRGB)
        // A custom CMYK profile whose bytes have not arrived.
        let custom = WTColor.ProfileRef(name: "Press", sha256: Data(repeating: 7, count: 32), space: .cmyk)
        stored.proof.compositeProfile = ColorSettings.stored(custom)
        stored.proof.target = .composite
        stored.proof.compositeSimulatesSeparations = true
        stored.intent = .perceptual
        stored.noBlackPointCompensation = true
        stored.noSpotColorManagement = true
        var unknown = Wiretuner_Doc_V1_ProfileRef()
        unknown.bundledID = "no-such-profile"
        stored.rgbProfile = unknown
        var spaceless = Wiretuner_Doc_V1_ProfileRef()
        spaceless.name = "?"
        stored.defaultImageRgbProfile = spaceless
        let settings = ColorSettings(stored, isAvailable: { _ in false })
        #expect(settings.cmykProfile == registry.defaultCMYK && settings.rgbProfile == registry.sRGB)
        #expect(settings.defaultImageRGBProfile == registry.sRGB)
        #expect(settings.compositeProfile == custom && settings.pendingProfiles == [custom] && settings.pending)
        #expect(settings.intent == .perceptual && !settings.blackPointCompensation && !settings.spotColorManagement)
        #expect(settings.proof?.profile == custom && settings.proof?.separations == registry.defaultCMYK)
        #expect(settings.colorManagement(proofing: true).proof != nil)
        stored.proof.target = .separations
        stored.cmykProfile = ColorSettings.stored(custom)
        let separations = ColorSettings(stored, isAvailable: { _ in false })
        #expect(separations.proof?.profile == custom && separations.proof?.separations == nil)
        #expect(separations.colorManagement().cmykProfile == registry.defaultCMYK)
        #expect(ColorSettings(stored).pending == false)
        for intent in [WTColor.RenderingIntent.perceptual, .relativeColorimetric, .saturation, .absoluteColorimetric] {
            #expect(ColorSettings.intent(ColorSettings.stored(intent)) == intent)
        }
        for space in [WTColor.ProfileSpace.rgb, .cmyk, .gray, .lab] {
            let ref = WTColor.ProfileRef(name: "x", sha256: Data(count: 32), space: space)
            #expect(ColorSettings.profile(ColorSettings.stored(ref), registry: registry) == ref)
        }
    }

    @Test func changeColorSettingsWritesOnlyDifferingRegistersAndUndoesPerRegister() throws {
        var pair = Pair()
        var draftA = ColorSettings.draft(pair.a.state)
        draftA.intent = .perceptual
        let change = try pair.a.perform(ChangeColorSettings(draftA))!
        #expect(change.label == "Change Color Settings" && change.ops.count == 1 && change.ops[0].set.paths.count == 1)
        #expect(try pair.a.perform(ChangeColorSettings(draftA)) == nil)
        var draftB = ColorSettings.draft(pair.b.state)
        draftB.cmykProfile = ColorSettings.stored(WTColor.ProfileRef(name: "Press", sha256: Data(repeating: 1, count: 32), space: .cmyk))
        try pair.b.perform(ChangeColorSettings(draftB))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        var settings = ColorSettings(pair.a.state)
        #expect(settings.intent == .perceptual && settings.cmykProfile.name == "Press")
        pair.a.undo()
        pair.sync()
        settings = ColorSettings(pair.b.state)
        #expect(settings.intent == .relativeColorimetric && settings.cmykProfile.name == "Press")
    }
}
