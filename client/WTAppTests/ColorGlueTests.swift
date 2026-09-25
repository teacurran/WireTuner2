import AppKit
import CoreGraphics
import SwiftUI
import Testing
import WTCRDT
import WTInterchange
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// The WTApp glue of COLOR-015 (the Replace sheet), CMS-008 (*Other…* and the missing profiles
/// through the blob cache), CMS-009 (the colour settings review row) and CMS-014 (spot chips).
@Suite(.serialized) @MainActor struct ColorGlueTests {
    static let grape = RenderColor(red: 0.5, green: 0, blue: 0.5)
    static let plum = RenderColor(red: 0.6, green: 0.1, blue: 0.4)

    // MARK: Replace

    @Test func theReplaceSheetListsOtherSwatchesAndReplacesInOneChange() async throws {
        let fixture = ColorPanelFixture()
        let features = ColorFeatures(selection: fixture.selection, preferences: fixture.preferences)
        let grape = await fixture.add(Self.grape, name: "Grape")
        let tint = await fixture.tint(of: grape, 50)
        let plum = await fixture.add(Self.plum, name: "Plum")
        let rect = await fixture.rect(fill: fixture.list.resolver.reference(to: grape))
        #expect(!features.replaceMenuItem().isEnabled, "nothing selected")
        features.swatchesPanel.select(grape, extend: false, toggle: false)
        #expect(features.replaceMenuItem().isEnabled)
        features.workspace.presentSheet = { _ in }
        features.showReplace()
        #expect(features.workspace.sheets[ReplaceSwatchModel.sheet] != nil)
        let model = ReplaceSwatchModel(workspace: fixture.workspace, swatch: grape, libraries: BundledColorLibraries.all)
        #expect(!model.candidates.contains { $0.id == grape || $0.id == tint } && model.candidates.contains { $0.id == plum })
        #expect(!model.canCommit && model.replace() == nil)
        ColorPanelFixture.render(ReplaceSwatchSheet(model: model))
        model.chosenSwatch = plum
        _ = await model.replace()?.value
        #expect(fixture.fill(rect)?.swatch.id == plum.proto && fixture.document.undoTitle == "Undo Replace \"Grape\" with \"Plum\"")
        // From a library.
        let library = ReplaceSwatchModel(workspace: fixture.workspace, swatch: plum, libraries: BundledColorLibraries.all)
        library.source = .library
        ColorPanelFixture.render(ReplaceSwatchSheet(model: library))
        #expect(library.replacement == nil)
        let first = try #require(library.libraryColors.first)
        library.chosenKey = first.key
        #expect(library.canCommit)
        _ = await library.replace()?.value
        #expect(fixture.list[plum]?.props.library == BundledColorLibraries.all[0].name)
        library.libraryIndex = 99
        #expect(library.libraryColors.isEmpty)
        library.cancel()
        // The protected defaults cannot be replaced.
        let white = fixture.list.swatches.first { $0.role == .white }
        #expect(!ReplaceSwatchModel.canReplace(white) && !ReplaceSwatchModel.canReplace(nil))
        let loose = ReplaceSwatchModel(workspace: ColorWorkspace(selection: ActiveSelection()), swatch: grape, libraries: [])
        #expect(loose.candidates.isEmpty && loose.replace() == nil)
    }

    // MARK: Profiles

    static let customRGB = CGColorSpace(name: CGColorSpace.adobeRGB1998)!.copyICCData()! as Data

    @Test func otherLoadsThroughTheBlobCacheAndMissingProfilesAreAskedFor() async throws {
        let fixture = ColorPanelFixture()
        let directory = TestEnvironment.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "adobe.icc")
        try Self.customRGB.write(to: file)
        let junk = directory.appending(path: "junk.icc")
        try Data("nope".utf8).write(to: junk)
        let registry = WTColor.ProfileRegistry()
        let profiles = ProfileBlobs(cache: BlobCache(directory: directory.appending(path: "blobs")), registry: registry)
        // No queue (an unsaved document): registered here only.
        let glue = ProfileBlobGlue(profiles: profiles) { _ in nil }
        let model = ColorSettingsModel(workspace: fixture.workspace, registry: registry)
        model.loadFile = glue.loader(for: fixture.document)
        model.chooseFile = { _ in file }
        await model.other(.rgb).value
        #expect(model.refusal == nil && model.chosen.rgbProfile.name.contains("Adobe"))
        model.chooseFile = { _ in junk }
        await model.other(.rgb).value
        #expect(model.refusal == "junk.icc is not an ICC profile.")
        #expect(model.loadChosen(file, for: .cmyk) != nil)
        // With a session's queue: cached and queued.
        let stores = TestStores.directory()
        let stored = TestStores.handle(in: stores)
        let store = try #require(await stored.openedModel()?.backend as? LocalStore)
        let queue = BlobQueue(store: store, cache: profiles.cache, transport: FakeSyncTransport(server: FakeSyncServer()), tokens: StaticTokens())
        let online = ProfileBlobGlue(profiles: profiles) { _ in queue }
        let ref = try await online.loader(for: stored)(file)
        #expect(!ref.isBundled && profiles.isAvailable(ref.sha256))
        #expect(try await store.pendingBlobs().map(\.hash).contains(ref.hexHash))
        // A document naming a profile that is not here asks for it once.
        var draft = ColorSettings.draft(fixture.state)
        var missing = ColorSettings.stored(ref)
        missing.sha256 = Data(repeating: 7, count: 32)
        draft.rgbProfile = missing
        _ = await fixture.document.perform(ChangeColorSettings(draft)).value
        let asking = ProfileBlobGlue(profiles: profiles) { _ in queue }
        #expect(asking.missing(in: fixture.document).count == 1)
        asking.watch(fixture.document)
        #expect(asking.requested[fixture.document.id]?.count == 1 && asking.missing(in: fixture.document).isEmpty)
        asking.watch(fixture.document)
        #expect(asking.requestMissing(fixture.document) == nil, "asked already")
        #expect(glue.requestMissing(fixture.document) == nil, "no queue")
        stored.close()
    }

    // MARK: Review row

    @Test func theColourSettingsRowShowsWhatChangedAndOffersBothChoices() async throws {
        let document = DocumentHandle.memory(title: "Review")
        let base = document.state
        let registry = WTColor.ProfileRegistry.shared
        let press = registry.displayP3
        var theirs = ColorSettings.draft(base)
        theirs.rgbProfile = ColorSettings.stored(press)
        var remoteCore = DocumentCore(state: base, replica: 77)
        let remote = try #require(try remoteCore.perform(ChangeColorSettings(theirs), recording: DocumentCore.Recording(limit: 1, now: Date()))?.change)
        var mine = ColorSettings.draft(base)
        mine.intent = ColorSettings.stored(WTColor.RenderingIntent.perceptual)
        var localCore = DocumentCore(state: base, replica: 42)
        let local = try #require(try localCore.perform(ChangeColorSettings(mine), recording: DocumentCore.Recording(limit: 1, now: Date()))?.change)
        var review = heldReview(WellKnown.settings)
        review.entries = [ReviewEntry(node: WellKnown.settings, kinds: [.sameRegister], authors: [77], setting: .colorSettings, actions: [.useTheirs])]
        let harness = ReviewHarness()
        harness.local = [local]
        var context = harness.context(document)
        context.baseState = { _ in base }
        let model = ReviewSheetModel(review: review, merged: document.state, local: [local], remote: [remote], context: context)
        #expect(model.rows.first?.name == "Color settings" && model.settingLines.isEmpty)
        await model.loadColorSettings()
        #expect(model.rows.first?.name == "Color settings changed by Priya")
        #expect(model.settingLines == ["Working RGB: \(registry.sRGB.name) → \(press.name)"])
        #expect(model.actions == [.useMine, .useTheirs])
        ColorPanelFixture.render(ReviewSheetView(model: model), width: 800, height: 700)
        _ = await model.perform(.useTheirs)?.value
        #expect(ColorSettings(document.state).rgbProfile == press && document.undoTitle == "Undo Use Their Color Settings")
        _ = await model.perform(.useMine)?.value
        #expect(ColorSettings(document.state).intent == .perceptual)
        // No base: nothing read.
        let plain = ReviewSheetModel(review: review, merged: document.state, local: [local], remote: [remote], context: harness.context(document))
        await plain.loadColorSettings()
        #expect(plain.settingLines.isEmpty && plain.actions == [.useTheirs])
        let entry = ReviewEntry(node: WellKnown.settings, kinds: [.sameRegister], setting: .fontMetrics)
        #expect(model.settingTitle(entry) == "Font metrics")
    }

    // MARK: Spot chips

    @Test func librarySpotsPreviewFromTheInkAndAMissingLibraryIsMarked() async throws {
        let fixture = ColorPanelFixture()
        let panel = SwatchesPanelModel(workspace: fixture.workspace)
        var library = ColorLibrary()
        library.name = "WireTuner Development Spot"
        library.colors = [
            .with { $0.key = "WT Dev Red"; $0.name = "WT Dev Red"; $0.spot = true; $0.value = ColorValues.stored(RenderColor(cyan: 0, magenta: 0.95, yellow: 0.85, black: 0.05)) },
            .with { $0.key = "Unknown Ink"; $0.name = "Unknown Ink"; $0.spot = true; $0.value = ColorValues.stored(RenderColor(cyan: 0.2, magenta: 0, yellow: 0, black: 0)) },
        ]
        _ = await fixture.document.perform(ImportLibraryColors(library, origin: "wiretuner-development")).value
        let red = try #require(fixture.list.swatches.first { $0.name == "WT Dev Red" })
        let unknown = try #require(fixture.list.swatches.first { $0.name == "Unknown Ink" })
        let tint = await fixture.tint(of: red.id, 50)
        let process = await fixture.add(Self.grape, name: "Grape")
        #expect(panel.chipColor(red).space == .lab && !panel.libraryMissing(red), "managed: the ink's Lab")
        #expect(panel.libraryMissing(unknown) && panel.chipColor(unknown).space == .cmyk)
        let tinted = try #require(fixture.list[tint])
        #expect(panel.chipColor(tinted).space == .lab && panel.chipColor(tinted).components.x > panel.chipColor(red).components.x, "lighter")
        let grape = try #require(fixture.list[process])
        #expect(panel.chipColor(grape) == Self.grape && !panel.libraryMissing(grape))
        // Unmanaged: the nominal CMYK, rendered again without a write.
        var draft = ColorSettings.draft(fixture.state)
        draft.noSpotColorManagement = true
        _ = await fixture.document.perform(ChangeColorSettings(draft)).value
        #expect(panel.chipColor(red).space == .cmyk)
        ColorPanelFixture.render(SwatchesPanelBody(model: panel))
        let away = SwatchesPanelModel(workspace: ColorWorkspace(selection: ActiveSelection()))
        #expect(away.chipColor(red) == red.color && !away.libraryMissing(red))
    }
}
