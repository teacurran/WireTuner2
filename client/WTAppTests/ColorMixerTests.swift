import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// COLOR-008's and COLOR-023's Color Mixer, COLOR-010's Tints panel.
@Suite @MainActor struct ColorMixerTests {
    static func mixer(_ fixture: ColorPanelFixture) -> ColorMixerModel {
        ColorMixerModel(workspace: fixture.workspace, defaults: fixture.suite.defaults)
    }

    @Test func eachModeStoresItsOwnKindOfColour() async throws {
        let fixture = ColorPanelFixture()
        let mixer = Self.mixer(fixture)
        #expect(mixer.mode == .p3 && mixer.current == RenderColor(displayP3Red: 0, green: 0, blue: 0), "the default space opens the Mixer")
        mixer.select(.cmyk)
        #expect(mixer.values == [0, 0, 0, 100] && mixer.components.map(\.title) == ["C", "M", "Y", "K"])
        mixer.set(1, to: 150)
        #expect(mixer.current == RenderColor(cyan: 0, magenta: 1, yellow: 0, black: 1), "clamped to 100%")
        mixer.set(9, to: 1)
        mixer.select(.rgb)
        for (index, value) in [230.0, 57, 70].enumerated() { mixer.set(index, to: value) }
        #expect(mixer.current.space == .sRGB && mixer.fieldText == "#E63946" && mixer.gamut == "sRGB")
        mixer.select(.p3)
        mixer.set(0, to: 255)
        mixer.set(1, to: 0)
        mixer.set(2, to: 0)
        #expect(mixer.current == RenderColor(displayP3Red: 1, green: 0, blue: 0) && mixer.gamut == "P3")
        mixer.select(.oklch)
        mixer.set(0, to: 70)
        mixer.set(1, to: 0.4)
        mixer.set(2, to: 30)
        #expect(mixer.current.space == .oklab && mixer.gamut == "Out of gamut")
        mixer.select(.hls)
        mixer.set(0, to: 120)
        mixer.set(1, to: 50)
        mixer.set(2, to: 100)
        #expect(mixer.current.space == .displayP3, "HLS colours are in the default space")
        mixer.select(.grayscale)
        mixer.set(0, to: 50)
        #expect(mixer.current == RenderColor(cyan: 0, magenta: 0, yellow: 0, black: 0.5) && mixer.values == [50])
        mixer.take(RenderColor(red: 1, green: 1, blue: 1))
        mixer.select(.grayscale)
        #expect(abs(mixer.values[0]) < 1e-9, "white is 0% black")
        #expect(ColorMixerModel.Mode.allCases.map(\.title) == ["CMYK", "RGB", "P3", "OKLCH", "HLS", "Grayscale", "System"])
        #expect(ColorMixerModel.Mode.of(.lab) == .oklch && ColorMixerModel.components(.system).isEmpty)
        #expect(ColorMixerModel.values(of: .black, in: .system, defaultSpace: .sRGB).isEmpty)
        #expect(ColorMixerModel.color([], in: .system, base: .white, defaultSpace: .sRGB) == .white)
    }

    @Test func theFieldTakesEveryFormAndSwitchesTheMode() {
        let fixture = ColorPanelFixture()
        let mixer = Self.mixer(fixture)
        #expect(mixer.submit("f03") && mixer.current == RenderColor(red: 1, green: 0, blue: 0.2) && mixer.mode == .rgb)
        #expect(mixer.submit("e63946") && mixer.fieldText == "#E63946")
        #expect(mixer.submit("color(display-p3 1 0 0)") && mixer.mode == .p3 && mixer.values == [255, 0, 0])
        #expect(mixer.submit("#e63946") && mixer.mode == .rgb && mixer.current.space == .sRGB, "a hex entry in P3 stores sRGB")
        #expect(mixer.submit("lab(54 63 32)") && mixer.mode == .oklch && mixer.current.space == .lab, "Lab shows in OKLCH")
        #expect(!mixer.submit("nonsense"))
        mixer.take(RenderColor(red: 0.21, green: 0.39, blue: 0.62))
        mixer.webSafe()
        #expect(mixer.current == RenderColor(red: 0.2, green: 0.4, blue: 0.6))
    }

    @Test func applyingAddingAndLiveMixing() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let mixer = Self.mixer(fixture)
        let rect = await fixture.rect()
        fixture.select([rect])
        mixer.take(RenderColor(red: 1, green: 0, blue: 0))
        _ = await mixer.apply()?.value
        #expect(fixture.fill(rect) == ColorResolver.inline(RenderColor(red: 1, green: 0, blue: 0)))
        // Add to Swatches: Cmd-click uses the default name and the last choice.
        _ = await mixer.addToSwatches(quickly: true)?.value
        #expect(fixture.list.named("255r 0g 0b")?.isSpot == false)
        #expect(mixer.addToSwatches(quickly: false) == nil && fixture.lastSheet == ColorMixerModel.addSheet)
        mixer.finishAdding(AddSwatchSheet.Answer(name: "Signal", spot: true))
        await fixture.settle()
        #expect(fixture.list.named("Signal")?.isSpot == true && mixer.lastSpot)
        mixer.finishAdding(nil)
        _ = mixer.addToSwatchesFromButton()
        mixer.finishAdding(nil)
        // Apply as you mix: one undo step per drag.
        mixer.live = true
        mixer.select(.rgb)
        mixer.dragging(true)
        mixer.set(1, to: 128)
        await fixture.settle()
        mixer.set(1, to: 200)
        await fixture.settle()
        mixer.dragging(false)
        await fixture.settle()
        #expect(fixture.fill(rect)?.inline.rgb.g == 200.0 / 255)
        _ = await fixture.document.undo().value
        #expect(fixture.fill(rect) == ColorResolver.inline(RenderColor(red: 1, green: 0, blue: 0)), "the drag undoes as one")
        mixer.live = false
        mixer.dragging(true)
        // The state persists on this Mac.
        let again = Self.mixer(fixture)
        #expect(again.mode == .rgb && again.current == mixer.current && again.lastSpot)
    }

    @Test func loadingInspectsAColourAndTheOriginalFollowsItsSwatch() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let grape = await fixture.add(RenderColor(cyan: 0.5, magenta: 1, yellow: 0, black: 0), name: "Grape")
        let mixer = Self.mixer(fixture)
        #expect(mixer.originalNow == nil)
        mixer.restoreOriginal()
        #expect(!mixer.drop(from: fixture.pasteboard))
        fixture.put(ColorRefPasteboard(swatch: grape, list: fixture.list, document: fixture.document.id))
        #expect(mixer.drop(from: fixture.pasteboard))
        #expect(mixer.mode == .cmyk && mixer.values == [50, 100, 0, 0] && mixer.loadedSwatch == grape)
        mixer.set(0, to: 0)
        try await fixture.receive(RedefineSwatch(grape, to: RenderColor(cyan: 1, magenta: 0, yellow: 0, black: 0), autoRename: false))
        #expect(mixer.originalNow == RenderColor(cyan: 1, magenta: 0, yellow: 0, black: 0) && mixer.values[0] == 0, "the new half is untouched")
        mixer.restoreOriginal()
        #expect(mixer.values == [100, 0, 0, 0])
        #expect(mixer.dragPayload(original: true).color == mixer.originalNow && mixer.dragPayload().color == mixer.current)
        fixture.put(ColorRefPasteboard(ref: ColorResolver.none, color: nil))
        #expect(!mixer.drop(from: fixture.pasteboard))
        mixer.load(.white)
        #expect(mixer.original == .white && mixer.loadedSwatch == nil)
    }

    @Test func theSystemColorsPanelFeedsTheMixer() {
        let fixture = ColorPanelFixture()
        let mixer = Self.mixer(fixture)
        let panel = NSColorPanel.shared
        mixer.select(.system)
        #expect(mixer.colorPanel === panel && panel.isContinuous && mixer.components.isEmpty)
        let target = ColorPanelTarget(model: mixer)
        panel.color = NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)
        target.changeColor(panel)
        #expect(mixer.current.space == .displayP3 && mixer.mode == .system)
        target.changeColor(nil)
        _ = fixture.preferences.set("srgb", for: PreferenceCatalog.Colors.defaultColorSpace)
        mixer.take(systemColor: NSColor(calibratedRed: 0, green: 1, blue: 0, alpha: 1))
        #expect(mixer.current.space == .sRGB && mixer.gamut == "sRGB", "gamut-mapped into sRGB")
        panel.orderOut(nil)
    }

    @Test func theMixerRenders() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let mixer = Self.mixer(fixture)
        for mode in ColorMixerModel.Mode.allCases where mode != .system {
            mixer.select(mode)
            ColorPanelFixture.render(ColorMixerBody(model: mixer))
        }
        _ = fixture.preferences.set(false, for: PreferenceCatalog.Colors.splitColorBox)
        ColorPanelFixture.render(ColorMixerBody(model: mixer))
        ColorPanelFixture.render(AddSwatchSheet(color: .black, spot: false) { _ in })
        ColorPanelFixture.render(MixerFieldView(text: "#000000") { _ in true })
        // The body's closures.
        ColorMixerBody.selecting(.cmyk, mixer)()
        ColorMixerBody.modeBinding(mixer).wrappedValue = .rgb
        #expect(ColorMixerBody.modeBinding(mixer).wrappedValue == .rgb)
        ColorMixerBody.binding(0, mixer).wrappedValue = 255
        #expect(ColorMixerBody.binding(0, mixer).wrappedValue == 255 && ColorMixerBody.binding(9, mixer).wrappedValue == 0)
        ColorMixerBody.fieldCommit(1, mixer)(255)
        ColorMixerBody.liveBinding(mixer).wrappedValue = true
        #expect(ColorMixerBody.liveBinding(mixer).wrappedValue)
        #expect(ColorMixerBody.dragging(mixer, original: false)().registeredTypeIdentifiers.contains(ColorRefPasteboard.typeIdentifier))
        fixture.pasteboard.clearContents()
        #expect(!ColorMixerBody.dropping(mixer, pasteboard: fixture.pasteboard)([]))
        _ = ColorMixerBody.dropping(mixer)
        var answers: [AddSwatchSheet.Answer?] = []
        var name = "Mine"
        var spot = true
        AddSwatchSheet.adding(Binding(get: { name }, set: { name = $0 }), Binding(get: { spot }, set: { spot = $0 })) { answers.append($0) }()
        AddSwatchSheet.cancelling { answers.append($0) }()
        #expect(answers == [AddSwatchSheet.Answer(name: "Mine", spot: true), nil])
        var entry = "#123456"
        var submitted: [String] = []
        MixerFieldView.submitting(Binding(get: { entry }, set: { entry = $0 })) { submitted.append($0); return true }()
        MixerFieldView.syncing(Binding(get: { entry }, set: { entry = $0 }), "#FFFFFF")()
        #expect(submitted == ["#123456"] && entry == "#FFFFFF")
    }

    // MARK: Tints

    @Test func tintsAreMadeAppliedAndAddedFromANamedBase() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let grape = await fixture.add(RenderColor(red: 0.5, green: 0, blue: 0.5), name: "Grape")
        let existing = await fixture.tint(of: grape, 20)
        let tints = TintsModel(workspace: fixture.workspace)
        #expect(tints.baseChoices.map(\.name) == ["White", "Black", "Grape"], "no Registration, no tints")
        #expect(tints.baseColor == nil && tints.tint == nil && tints.reference == nil && tints.apply() == nil && tints.dragPayload == nil)
        tints.choose(base: grape)
        tints.setPercent(0)
        #expect(tints.percent == 100, "0 reads as 100%")
        tints.setPercent(40)
        #expect(tints.baseName == "Grape" && tints.tint == RenderColor(red: 0.5, green: 0, blue: 0.5).tinted(0.4))
        let rect = await fixture.rect()
        fixture.select([rect])
        _ = await tints.apply()?.value
        #expect(fixture.fill(rect)?.tint.percent == 40, "an unnamed tint of the named base")
        _ = await tints.addToSwatches()?.value
        let added = try #require(fixture.list.named("40% Grape"))
        #expect(added.base == grape && added.depth == 1)
        // A remote recolour of the base shows at once; renaming it renames the derived name.
        try await fixture.receive(RedefineSwatch(grape, to: RenderColor(red: 0, green: 0, blue: 1), autoRename: false))
        #expect(tints.baseColor == RenderColor(red: 0, green: 0, blue: 1))
        try await fixture.receive(RenameSwatch(grape, to: "Blueberry"))
        #expect(fixture.list[added.id]?.name == "40% Blueberry")
        // Option-click loading.
        tints.load(existing)
        #expect(tints.base == grape && tints.percent == 20 && tints.loadedTint == existing && !tints.baseRemoved)
        tints.load(OpID(counter: 999, replica: 9))
        tints.load(grape)
        #expect(tints.loadedTint == nil)
        #expect(tints.dragPayload?.ref.tint.percent == 20)
    }

    @Test func anUnnamedBaseIsOfferedToTheSwatchesFirst() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let grape = await fixture.add(RenderColor(red: 0.5, green: 0, blue: 0.5), name: "Grape")
        let tints = TintsModel(workspace: fixture.workspace)
        #expect(!tints.dropBase(from: fixture.pasteboard))
        fixture.put(ColorRefPasteboard(ref: ColorResolver.none, color: nil))
        #expect(!tints.dropBase(from: fixture.pasteboard))
        fixture.put(ColorRefPasteboard(swatch: grape, list: fixture.list, document: fixture.document.id))
        #expect(tints.dropBase(from: fixture.pasteboard) && tints.base == grape)
        fixture.put(NSColor(srgbRed: 0, green: 0.5, blue: 0, alpha: 1))
        #expect(tints.dropBase(from: fixture.pasteboard) && tints.base == nil && tints.unnamedBase != nil)
        #expect(tints.reference?.inline.rgb.r ?? 0 > 0, "the tinted colour, unnamed")
        #expect(tints.addToSwatches() == nil && tints.offersToAddBase)
        tints.declineAddingBase()
        #expect(!tints.offersToAddBase)
        tints.addToSwatches()
        await tints.addBaseAndTint()?.value
        await fixture.settle()
        let base = try #require(fixture.list.named("0r 128g 0b"))
        #expect(tints.base == base.id && fixture.list.tints(of: base.id).count == 1)
        #expect(TintsModel(workspace: fixture.workspace).addBaseAndTint() == nil)
        // A tint whose base was removed shows the badge.
        _ = await fixture.document.perform(RemoveSwatches([grape])).value
        let orphan = await fixture.orphanTint(of: grape)
        tints.load(orphan)
        #expect(tints.baseRemoved && tints.baseColor == RenderColor(red: 0.5, green: 0, blue: 0.5), "the cached base")
        ColorPanelFixture.render(TintsPanelBody(model: tints))
    }

    @Test func theTintsPanelRenders() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let grape = await fixture.add(RenderColor(red: 0.5, green: 0, blue: 0.5), name: "Grape")
        let tints = TintsModel(workspace: fixture.workspace)
        ColorPanelFixture.render(TintsPanelBody(model: tints))
        tints.choose(base: grape)
        ColorPanelFixture.render(TintsPanelBody(model: tints))
        fixture.put(NSColor(srgbRed: 0, green: 0.5, blue: 0, alpha: 1))
        tints.dropBase(from: fixture.pasteboard)
        tints.addToSwatches()
        _ = fixture.preferences.set(false, for: PreferenceCatalog.Colors.splitColorBox)
        ColorPanelFixture.render(TintsPanelBody(model: tints))
        TintsPanelBody.baseBinding(tints).wrappedValue = grape
        #expect(TintsPanelBody.baseBinding(tints).wrappedValue == grape)
        TintsPanelBody.percentBinding(tints).wrappedValue = 30
        #expect(TintsPanelBody.percentBinding(tints).wrappedValue == 30)
        TintsPanelBody.preset(70, tints)()
        #expect(tints.percent == 70)
        #expect(TintsPanelBody.dragging(tints)().registeredTypeIdentifiers.contains(ColorRefPasteboard.typeIdentifier))
        #expect(TintsPanelBody.dragging(TintsModel(workspace: fixture.workspace))().registeredTypeIdentifiers.isEmpty)
        fixture.pasteboard.clearContents()
        #expect(!TintsPanelBody.dropping(tints, pasteboard: fixture.pasteboard)([]))
        _ = TintsPanelBody.dropping(tints)
    }
}

// MARK: - Color Settings, team libraries, installation

/// A `ColorLibraryService` in memory.
final class FakeColorLibraries: ColorLibraryTransport, @unchecked Sendable {
    struct Offline: Error {}

    private let lock = NSLock()
    private var state = (online: true, infos: [Wiretuner_Docs_V1_ColorLibraryInfo](), colors: [String: Wiretuner_Lib_V1_ColorLibrary](), published: [String]())

    var online: Bool {
        get { lock.withLock { state.online } }
        set { lock.withLock { state.online = newValue } }
    }

    var published: [String] { lock.withLock { state.published } }

    func library(_ id: String, name: String, team: String, updated: Int64, colors: Wiretuner_Lib_V1_ColorLibrary) {
        var info = Wiretuner_Docs_V1_ColorLibraryInfo()
        info.documentID = id
        info.name = name
        info.teamID = team
        info.updatedMs = updated
        info.publishedSeq = UInt64(updated)
        lock.withLock {
            state.infos.removeAll { $0.documentID == id }
            state.infos.append(info)
            state.colors[id] = colors
        }
    }

    private func check() throws {
        guard online else { throw Offline() }
    }

    func publishColorLibrary(_ request: Wiretuner_Docs_V1_PublishColorLibraryRequest, token: String) async throws -> Wiretuner_Docs_V1_PublishColorLibraryResponse {
        try check()
        lock.withLock { state.published.append(request.documentID) }
        return Wiretuner_Docs_V1_PublishColorLibraryResponse()
    }

    func unpublishColorLibrary(_ request: Wiretuner_Docs_V1_UnpublishColorLibraryRequest, token: String) async throws -> Wiretuner_Docs_V1_UnpublishColorLibraryResponse {
        try check()
        return Wiretuner_Docs_V1_UnpublishColorLibraryResponse()
    }

    func listColorLibraries(_ request: Wiretuner_Docs_V1_ListColorLibrariesRequest, token: String) async throws -> Wiretuner_Docs_V1_ListColorLibrariesResponse {
        try check()
        var response = Wiretuner_Docs_V1_ListColorLibrariesResponse()
        response.libraries = lock.withLock { state.infos.filter { $0.teamID == request.teamID } }
        return response
    }

    func fetchColorLibrary(_ request: Wiretuner_Docs_V1_FetchColorLibraryRequest, token: String) async throws -> Wiretuner_Docs_V1_FetchColorLibraryResponse {
        try check()
        var response = Wiretuner_Docs_V1_FetchColorLibraryResponse()
        lock.withLock {
            if let info = state.infos.first(where: { $0.documentID == request.documentID }) { response.library = info }
            if let colors = state.colors[request.documentID] { response.colors = colors }
        }
        return response
    }
}

@Suite @MainActor struct ColorSettingsAndLibraryTests {
    static func library(_ name: String, _ color: RenderColor) -> Wiretuner_Lib_V1_ColorLibrary {
        var library = Wiretuner_Lib_V1_ColorLibrary()
        library.name = name
        var entry = Wiretuner_Lib_V1_LibraryColor()
        entry.key = "k1"
        entry.name = "Brand Red"
        entry.value = ColorValues.stored(color)
        library.colors = [entry]
        return library
    }

    static func client(_ fake: FakeColorLibraries) -> ColorLibraryClient {
        ColorLibraryClient(transport: fake, directory: TestEnvironment.temporaryDirectory()) { "token" }
    }

    // MARK: Color Settings

    @Test func theSheetOffersProfilesOfEachFieldsSpaceAndWritesOneChange() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let registry = WTColor.ProfileRegistry.shared
        let model = ColorSettingsModel(workspace: fixture.workspace)
        for field in ColorSettingsModel.Field.allCases {
            #expect(!field.title.isEmpty && model.choices(field).allSatisfy { choice in
                if case .profile(let ref) = choice.source { return ref.space == field.space } else { return true }
            })
        }
        #expect(model.selection(.rgb) == "bundled:srgb" && model.selection(.cmyk) == "bundled:default-cmyk")
        model.choose("bundled:display-p3", for: .rgb)
        model.choose("no such profile", for: .rgb)
        #expect(model.chosen.rgbProfile.bundledID == "display-p3" && model.touched == [.rgb])
        // Files: a CMYK profile refused for RGB, a file that is no profile, then accepted where it fits.
        let directory = TestEnvironment.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cmykFile = directory.appending(path: "press.icc")
        try #require(registry.iccData(for: registry.defaultCMYK)).write(to: cmykFile)
        let junk = directory.appending(path: "junk.icc")
        try Data("not a profile".utf8).write(to: junk)
        model.load(cmykFile, for: .rgb)
        #expect(model.refusal?.contains("is not an RGB profile") == true)
        model.load(junk, for: .cmyk)
        #expect(model.refusal == "junk.icc is not an ICC profile.")
        model.chooseFile = { _ in cmykFile }
        await model.other(.composite).value
        #expect(model.refusal == nil && model.chosen.compositeProfile.space == .cmyk)
        model.load(cmykFile, for: .rgb)
        #expect(model.refusal?.contains("RGB") == true)
        model.load(cmykFile, for: .cmyk)
        model.chooseFile = { _ in nil }
        await model.other(.rgb).value
        if let installed = model.choices(.imageRGB).first(where: { $0.group == "Installed" }) {
            model.choose(installed.id, for: .imageRGB)
        } else {
            model.choose("bundled:display-p3", for: .imageRGB)
        }
        // The other settings.
        model.intent = .perceptual
        model.blackPointCompensation = false
        model.spotColorManagement = false
        model.proofTarget = .composite
        model.compositeSimulatesSeparations = true
        model.simulatePaperWhite = true
        model.simulateBlackInk = true
        #expect(model.intent == .perceptual && !model.blackPointCompensation && !model.spotColorManagement && model.proofTarget == .composite)
        #expect(model.compositeSimulatesSeparations && model.simulatePaperWhite && model.simulateBlackInk)
        model.proofTarget = .separations
        #expect(model.proofTarget == .separations)
        model.proofTarget = .none
        ColorPanelFixture.render(ColorSettingsSheet(model: model), width: 560, height: 900)
        _ = ColorSettingsSheet.other(.rgb, model)
        ColorSettingsSheet.profileBinding(.rgb, model).wrappedValue = "bundled:srgb"
        #expect(ColorSettingsSheet.profileBinding(.rgb, model).wrappedValue == "bundled:srgb")
        _ = await model.ok()?.value
        #expect(fixture.document.undoTitle == "Undo Change Color Settings")
        let written = ColorSettings(fixture.state)
        #expect(written.intent == .perceptual && !written.blackPointCompensation && written.proofTarget == .none)
        ColorSettingsModel(workspace: fixture.workspace).cancel()
        #expect(ColorSettingsModel(workspace: ColorWorkspace(selection: ActiveSelection())).current.rgbProfile.bundledID == "srgb")
    }

    @Test func aRemoteChangeWhileTheSheetIsOpenSurvivesOK() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let model = ColorSettingsModel(workspace: fixture.workspace)
        var remote = ColorSettings.draft(fixture.state)
        remote.intent = .saturation
        try await fixture.receive(ChangeColorSettings(remote))
        #expect(model.current.intent == .saturation && model.chosen.intent == .relativeColorimetric, "the label updates; the draft stays")
        model.blackPointCompensation = false
        _ = await model.ok()?.value
        let settings = ColorSettings(fixture.state)
        #expect(settings.intent == .saturation && !settings.blackPointCompensation, "both writers' settings are kept")
    }

    @Test func settingsCopyOneAtATimeAndLeaveUntouchedMessagesUnset() {
        var a = Wiretuner_Doc_V1_ColorSettings()
        var b = Wiretuner_Doc_V1_ColorSettings()
        let registry = WTColor.ProfileRegistry.shared
        b.rgbProfile = ColorSettings.stored(registry.displayP3)
        b.cmykProfile = ColorSettings.stored(registry.defaultCMYK)
        b.defaultImageRgbProfile = ColorSettings.stored(registry.displayP3)
        b.proof.compositeProfile = ColorSettings.stored(registry.defaultCMYK)
        b.intent = .perceptual
        b.noBlackPointCompensation = true
        b.noSpotColorManagement = true
        b.proof.target = .composite
        b.proof.compositeSimulatesSeparations = true
        b.proof.simulatePaperWhite = true
        b.proof.simulateBlackInk = true
        #expect(ColorSettingsModel.differences(a, b) == Set(ColorSettingsModel.Setting.allCases))
        #expect(ColorSettingsModel.differences(a, a).isEmpty)
        for setting in ColorSettingsModel.Setting.allCases { a.copy(setting, from: b) }
        #expect(a == b)
        var untouched = Wiretuner_Doc_V1_ColorSettings()
        for setting in ColorSettingsModel.Setting.allCases { untouched.copy(setting, from: Wiretuner_Doc_V1_ColorSettings()) }
        #expect(!untouched.hasProof && !untouched.hasRgbProfile)
    }

    // MARK: Team libraries

    @Test func teamLibrariesListAddUpdateAndWorkFromTheCacheOffline() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let fake = FakeColorLibraries()
        fake.library("lib1", name: "Brand", team: "t1", updated: 10, colors: Self.library("Brand", RenderColor(red: 1, green: 0, blue: 0)))
        let model = TeamLibrariesModel(workspace: fixture.workspace, client: Self.client(fake)) { [TeamLibrariesModel.Team(id: "t1", name: "Design")] }
        await model.refresh()
        #expect(model.listings["t1"]?.libraries.count == 1 && !model.hasUpdates && !model.isOffline)
        _ = await model.add("lib1")
        let swatch = try #require(fixture.list.named("Brand Red"))
        #expect(swatch.library == ColorLibraries.teamOrigin("lib1"))
        // A newer version: the dot, then Update from Library….
        fake.library("lib1", name: "Brand", team: "t1", updated: 20, colors: Self.library("Brand", RenderColor(red: 0.9, green: 0, blue: 0)))
        await model.refresh()
        #expect(model.hasUpdates)
        ColorPanelFixture.render(TeamLibrariesSheet(model: model))
        await model.prepareUpdate("lib1")
        #expect(model.update?.rows.first?.status == .libraryChanged && model.ticked == [swatch.id])
        ColorPanelFixture.render(UpdateFromLibrarySheet(model: model))
        let tick = UpdateFromLibrarySheet.toggling(swatch.id, model)
        tick.wrappedValue = false
        #expect(!tick.wrappedValue)
        model.toggle(swatch.id)
        _ = await model.applyUpdate()?.value
        #expect(fixture.list[swatch.id]?.color == RenderColor(red: 0.9, green: 0, blue: 0))
        #expect(model.applyUpdate() == nil)
        await model.prepareUpdate("lib1")
        model.cancelUpdate()
        #expect(model.update == nil)
        #expect(["Unchanged", "Library changed", "Edited here", "Removed from library"]
                == [LibraryUpdate.Status.unchanged, .libraryChanged, .editedLocally, .removedFromLibrary].map(TeamLibrariesModel.title))
        // Offline: the cached listing, no dot; the cached library still adds; an uncached one says so.
        fake.online = false
        await model.refresh()
        #expect(model.isOffline && !model.hasUpdates)
        #expect(await model.add("lib1") == nil && model.message == nil, "already present: nothing new")
        #expect(await model.add("unknown") == nil && model.message != nil)
        await model.prepareUpdate("unknown")
        #expect(model.message == "The library is not available offline.")
        #expect(await !model.publish(to: "t1") && model.message == TeamLibrariesModel.offlineReason)
        #expect(await !model.publishVersion())
        fake.online = true
        #expect(await model.publish(to: "t1") && model.message == nil)
        #expect(await model.publishVersion() && fake.published == [fixture.document.id, fixture.document.id])
        ColorPanelFixture.render(TeamLibrariesSheet(model: model))
        model.dismiss()
        // The sheet's buttons.
        TeamLibrariesSheet.adding("lib1", model)()
        TeamLibrariesSheet.updating("lib1", model)()
        TeamLibrariesSheet.updating("unknown", model)()
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.sheets.contains { $0.identifier?.rawValue == TeamLibrariesModel.updateSheet })
    }

    @Test func withoutAClientTheLibraryActionsDoNothing() async {
        let fixture = ColorPanelFixture()
        let model = TeamLibrariesModel(workspace: fixture.workspace, client: nil)
        await model.refresh()
        await model.prepareUpdate("x")
        let added = await model.add("x")
        let published = await model.publish(to: "t")
        let version = await model.publishVersion()
        #expect(added == nil && !published && !version)
        #expect(model.teams().isEmpty)
        ColorPanelFixture.render(TeamLibrariesSheet(model: model))
        let environment = LaunchEnvironment(arguments: [], environment: [:])
        let suite = TestDefaults()
        let account = environment.makeAccountModel(infoDictionary: ["WTAPIURL": "http://localhost:9"], defaults: suite.defaults)
        #expect(environment.makeColorLibraryClient(account: account, infoDictionary: ["WTAPIURL": "http://localhost:9"], defaults: suite.defaults) != nil)
        #expect(LaunchEnvironment(arguments: [LaunchEnvironment.uiTestingArgument], environment: [:])
            .makeColorLibraryClient(account: account, infoDictionary: nil, defaults: suite.defaults) == nil)
    }

    // MARK: Installation

    @Test func theFeaturesInstallPanelsCommandsAndExtensions() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let commands = CommandRegistry()
        let panels = PanelRegistry()
        let extensions = ExtensionRegistry()
        let fake = FakeColorLibraries()
        let features = ColorFeatures(selection: ActiveSelection(), preferences: fixture.preferences, defaults: fixture.suite.defaults,
                                     libraryClient: Self.client(fake)) { [TeamLibrariesModel.Team(id: "t1", name: "Design")] }
        var presented: [String] = []
        features.workspace.presentSheet = { presented.append($0.identifier?.rawValue ?? "") }
        features.install(commands: commands, panels: panels, extensions: extensions) { [fixture.document] }
        #expect(["swatches", "colorMixer", "tints"].allSatisfy { panels.contains(PanelID(rawValue: $0)) })
        for id in ["swatches", "colorMixer", "tints"] { _ = panels.descriptor(for: PanelID(rawValue: id))?.makeView() }
        // Without a document everything is disabled.
        #expect(commands.command(ColorFeatures.ID.colorSettings)?.validation().reason == ColorFeatures.noDocument)
        #expect(features.teamLibraryValidation().reason == ColorFeatures.noDocument)
        #expect(extensions.descriptor(for: "nameAllColors")?.validate?().isEnabled == false)
        features.workspace.selection.document = fixture.document
        #expect(commands.command(ColorFeatures.ID.colorSettings)?.validation().isEnabled == true)
        #expect(features.teamLibraryValidation().isEnabled)
        await features.teamLibraries.refresh()
        fake.online = false
        await features.teamLibraries.refresh()
        #expect(features.teamLibraryValidation().reason == TeamLibrariesModel.offlineReason)
        fake.online = true
        #expect(ColorFeatures(selection: fixture.selection).teamLibraryValidation().reason == ColorFeatures.signedOut)
        // The commands and the menu open their sheets.
        for id in [ColorFeatures.ID.colorSettings, ColorFeatures.ID.makeTeamLibrary] {
            if case .perform(let run)? = commands.command(id)?.action { run() }
        }
        if case .perform(let run)? = commands.command(ColorFeatures.ID.publishLibraryVersion)?.action { run() }
        for item in features.swatchesMenu() where ["Import from Document…", "Team Libraries…", "Restore Deleted Colors…"].contains(item.title) { item.action() }
        let unused = await fixture.add(RenderColor(red: 0, green: 0, blue: 1), name: "Blue")
        let rect = await fixture.rect(fill: ColorResolver.inline(RenderColor(red: 0, green: 1, blue: 0)))
        for id in ["deleteUnusedNamedColors", "nameAllColors", "sortColorListByName"] { _ = extensions.descriptor(for: id)?.run?(nil) }
        #expect(presented == [ColorSettingsModel.sheet, MakeTeamLibrarySheet.identifier, ImportFromDocumentModel.sheet, TeamLibrariesModel.sheet,
                              RestoreDeletedModel.sheet, DeleteUnusedModel.sheet])
        await fixture.settle()
        #expect(fixture.fill(rect).map { if case .swatch? = $0.ref { true } else { false } } == true, "Name All Colors named the fill")
        _ = unused
        #expect(await features.publishVersion().value)
        #expect(await features.showTeamLibraries().value == ())
        #expect(features.swatchesMenu().contains { $0.title == "Team Libraries…" })
        // Make Team Color Library….
        let sheet = MakeTeamLibrarySheet(model: features.teamLibraries)
        ColorPanelFixture.render(sheet)
        var team = ""
        MakeTeamLibrarySheet.publishing(Binding(get: { team }, set: { team = $0 }), features.teamLibraries)()
        MakeTeamLibrarySheet.cancelling(features.teamLibraries)()
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.published.count == 3, "the menu command, the call, the sheet")
        #expect(features.extensionDescriptors(existing: ExtensionRegistry(descriptors: [])).isEmpty)
    }
}
