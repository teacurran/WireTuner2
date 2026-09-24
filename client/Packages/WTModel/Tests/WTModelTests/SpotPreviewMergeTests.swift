import Foundation
import Testing
import WTCRDT
@testable import WTModel
import WTProto
import WTRender

/// CMS-014: *Color manage spot colors* is a document setting -- toggling it changes every spot chip
/// and no document value, and concurrent toggles converge with the loser retained.
@Suite struct SpotPreviewMergeTests {
    static let register = RegisterPath([2, 50, 5])

    static func toggle(_ state: EngineState, managed: Bool) -> ChangeColorSettings {
        var draft = ColorSettings.draft(state)
        draft.noSpotColorManagement = !managed
        return ChangeColorSettings(draft)
    }

    static func preview(_ state: EngineState, store: WTColor.SpotLibraryStore) -> WTColor.SpotPreview {
        let settings = ColorSettings(state)
        return store.previewColor(library: WTColor.SpotLibrary.placeholder.id, ink: "WT Dev Red", nominal: SIMD4(0, 1, 1, 0),
                                  settings: WTColor.SpotPreviewSettings(managed: settings.spotColorManagement, rgbProfile: settings.rgbProfile,
                                                                        cmykProfile: settings.cmykProfile, intent: settings.intent))
    }

    @Test func concurrentTogglesConvergeWithTheLoserRetained() throws {
        var pair = Pair()
        let store = WTColor.SpotLibraryStore()
        #expect(ChangeColorSettings.registers.contains(Self.register))
        let managed = Self.preview(pair.a.state, store: store)
        #expect(managed.color.space == .lab)
        // A turns management off, B turns it off and on again: concurrent writes of one register.
        try pair.a.perform(Self.toggle(pair.a.state, managed: false))
        try pair.b.perform(Self.toggle(pair.b.state, managed: false))
        try pair.b.perform(Self.toggle(pair.b.state, managed: true))
        let unmanaged = Self.preview(pair.a.state, store: store)
        #expect(unmanaged.color.space == .cmyk && unmanaged != managed)
        pair.sync()
        let a = ColorSettings(pair.a.state).spotColorManagement
        #expect(a == ColorSettings(pair.b.state).spotColorManagement)
        #expect(pair.a.state.store.register(WellKnown.settings, Self.register)?.value == pair.b.state.store.register(WellKnown.settings, Self.register)?.value)
        #expect(!pair.a.state.store.losingWrites(WellKnown.settings, Self.register).isEmpty, "the losing toggle is kept for the review sheet")
        // The chip follows the setting on both replicas; no document value besides the register moved.
        #expect(Self.preview(pair.a.state, store: store) == Self.preview(pair.b.state, store: store))
    }
}
