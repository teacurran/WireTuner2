import AppKit
import SwiftUI
import Testing
@testable import WireTuner

/// BASIC-021, 022 and 025: the catalog's forms, choosers with bookmarks, and snap sounds.
@Suite(.serialized) @MainActor struct PreferenceWindowContentTests {
    /// One control per category, written through the form's bindings and read back from the
    /// store (the UI test of BASIC-022, without a screen).
    @Test(arguments: PreferenceCategory.allCases)
    func oneControlPerCategoryWritesTheStore(category: PreferenceCategory) throws {
        let suite = TestDefaults()
        let store = PreferenceStore(defaults: suite.defaults)
        let speaker = SnapSoundTests.Speaker()
        let bindings = PreferenceBindings(store: store, beep: { speaker.played.append("beep") }, choose: { _ in })
        let row = try #require(PreferenceForm.rows(for: category).first)
        switch row.kind {
        case .toggle:
            let binding = bindings.bool(row.key)
            binding.wrappedValue.toggle()
            #expect(store.value(for: row.key) == .bool(binding.wrappedValue))
        case let .number(range, _, _, integer):
            let binding = bindings.number(row.key, integer: integer)
            binding.wrappedValue = range.upperBound
            #expect(store.value(for: row.key).number == range.upperBound)
        case let .popup(options):
            let binding = bindings.option(row.key)
            binding.wrappedValue = options.last!.value
            #expect(store.value(for: row.key) == options.last!.value)
        case .color:
            let binding = bindings.color(row.key)
            binding.wrappedValue = Color(.sRGB, red: 1, green: 0, blue: 0)
            #expect(store.value(for: row.key) == .color(PreferenceColor(red: 1, green: 0, blue: 0, alpha: 1)))
        case .list:
            let binding = bindings.list(row.key)
            binding.wrappedValue = "PDF SVG"
            #expect(store.value(for: row.key) == .list(["PDF", "SVG"]))
        default:
            Issue.record("the first row of \(category) is \(row.kind)")
        }
        #expect(speaker.played.isEmpty)
        #expect(row.accessibilityIdentifier == "pref.\(row.key.id)")
        #expect(PreferencesWindowModel.badge(for: category) == (category.scope == .synced ? "Synced" : "This Mac"))
    }

    @Test func choosersKeepABookmarkThatResolvesAfterRelaunch() throws {
        let suite = TestDefaults()
        let store = PreferenceStore(defaults: suite.defaults)
        let key = PreferenceCatalog.Document.missingLinksFolder.erased
        let bookmarks = PreferenceBookmarks(store: store)
        #expect(bookmarks.url(for: key) == nil)
        let folder = TestEnvironment.temporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        bookmarks.choose(folder, for: key)
        #expect(store.value(for: key) == .string(folder.path))
        #expect(suite.defaults.data(forKey: PreferenceBookmarks.defaultsKey(for: key.id)) != nil)
        // A fresh store over the same defaults (a relaunch) resolves the same folder.
        let relaunched = PreferenceBookmarks(store: PreferenceStore(defaults: suite.defaults))
        #expect(relaunched.url(for: key)?.standardizedFileURL.path == folder.standardizedFileURL.path)
        // Without a bookmark the stored path is used; with an unresolvable one, nothing.
        suite.defaults.removeObject(forKey: PreferenceBookmarks.defaultsKey(for: key.id))
        #expect(relaunched.url(for: key)?.path == folder.path)
        suite.defaults.set(Data("junk".utf8), forKey: PreferenceBookmarks.defaultsKey(for: key.id))
        #expect(relaunched.url(for: key) == nil)
        bookmarks.clear(key)
        #expect(store.value(for: key) == .string(""))
        #expect(bookmarks.url(for: key) == nil)
        // A stale bookmark is renewed.
        var stale = true
        let data = try #require(PreferenceBookmarks.bookmark(for: folder))
        #expect(PreferenceBookmarks.resolve(data, stale: &stale) != nil)
    }

    @Test func eachChooserOpensTheRightPanel() {
        let suite = TestDefaults()
        let store = PreferenceStore(defaults: suite.defaults)
        #expect(PreferenceChooserKind.kind(for: PreferenceCatalog.Object.externalEditor.id) == .application)
        #expect(PreferenceChooserKind.kind(for: PreferenceCatalog.Export.previewBrowser.id) == .application)
        #expect(PreferenceChooserKind.kind(for: PreferenceCatalog.Document.missingLinksFolder.id) == .folder)
        guard case .file = PreferenceChooserKind.kind(for: PreferenceCatalog.Document.newTemplate.id) else { Issue.record("template"); return }
        let app = PreferenceBookmarks.openPanel(for: PreferenceCatalog.Object.externalEditor.erased)
        #expect(app.canChooseFiles && !app.canChooseDirectories)
        let folder = PreferenceBookmarks.openPanel(for: PreferenceCatalog.Document.missingLinksFolder.erased)
        #expect(folder.canChooseDirectories && !folder.canChooseFiles)
        let profile = PreferenceBookmarks.openPanel(for: PreferenceCatalog.Colors.monitorProfile.erased)
        #expect(profile.canChooseFiles && !profile.allowedContentTypes.isEmpty)
        let bookmarks = PreferenceBookmarks(store: store)
        let key = PreferenceCatalog.Export.previewBrowser.erased
        bookmarks.runChooser(for: key) { _ in nil }
        #expect(store.value(for: key) == .string(""))
        bookmarks.runChooser(for: key) { _ in URL(filePath: "/Applications/Safari.app") }
        #expect(store.value(for: key) == .string("/Applications/Safari.app"))
        #expect(PreferenceForm.chooserTitle("", placeholder: "System default") == "System default")
        #expect(PreferenceForm.chooserTitle("/Applications/Safari.app", placeholder: "System default").hasPrefix("Safari"))
        // The form's buttons reach the bindings.
        let speaker = SnapSoundTests.Speaker()
        let bindings = PreferenceBindings(store: store, choose: { speaker.played.append($0.id) })
        bindings.choose(key)
        #expect(speaker.played == [key.id])
        bindings.clearChoice(key)
        #expect(store.value(for: key) == .string(""))
        let defaultBindings = PreferenceBindings(store: store)
        #expect(defaultBindings.store === store)
    }

    @Test func chooserRowsRender() {
        let suite = TestDefaults()
        let store = PreferenceStore(defaults: suite.defaults)
        let row = PreferenceFormRow(key: PreferenceCatalog.Export.previewBrowser.erased)
        let view = NSHostingView(rootView: Form { PreferenceRowView(row: row, bindings: PreferenceBindings(store: store, choose: { _ in })) })
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 0)
        let sidebar = NSHostingView(rootView: PreferencesSidebar(model: PreferencesWindowModel(store: store)))
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.fittingSize.height >= 0)
    }
}

/// BASIC-025: snap sounds.
@Suite @MainActor struct SnapSoundTests {
    /// What a player played, and a clock the test moves.
    @MainActor
    final class Speaker {
        var played: [String] = []
        var now = 10.0

        func attach(to player: SnapSoundPlayer, uiSounds: Bool = true) {
            player.play = { [unowned self] in self.played.append($0) }
            player.clock = { [unowned self] in self.now }
            player.uiSoundsEnabled = { uiSounds }
        }
    }

    @Test func aSnapPlaysItsSoundAtMostOncePer100Milliseconds() {
        let suite = TestDefaults()
        let store = PreferenceStore(defaults: suite.defaults)
        let player = SnapSoundPlayer(preferences: store)
        let speaker = Speaker()
        speaker.attach(to: player)
        #expect(!player.snapped(.point), "None is the default")
        store.set("Tink", for: PreferenceCatalog.Sounds.snapPoint)
        #expect(speaker.played == ["Tink"], "choosing a sound previews it once")
        speaker.played = []
        #expect(player.snapped(.point))
        speaker.now += 0.05
        #expect(!player.snapped(.point))
        speaker.now += 0.06
        #expect(player.snapped(.point))
        #expect(speaker.played == ["Tink", "Tink"])
        store.set("Pop", for: PreferenceCatalog.Sounds.snapGuide)
        speaker.now += 1
        #expect(player.snapped(.guide))
        #expect(speaker.played.last == "Pop")
        for kind in SnapKind.allCases { #expect(SnapSoundPlayer.key(for: kind).id.hasPrefix("sounds.snap_")) }
    }

    @Test func silentWhenInterfaceSoundsAreOff() {
        let suite = TestDefaults()
        let store = PreferenceStore(defaults: suite.defaults)
        let player = SnapSoundPlayer(preferences: store)
        let speaker = Speaker()
        speaker.attach(to: player, uiSounds: false)
        store.set("Glass", for: PreferenceCatalog.Sounds.snapGrid)
        #expect(!player.snapped(.grid))
        store.set("", for: PreferenceCatalog.Sounds.snapGrid)
        store.set(4, for: PreferenceCatalog.General.pickDistance)
        #expect(speaker.played.isEmpty)
        #expect(SnapSoundPlayer.systemUISoundsEnabled(global: nil))
        #expect(!SnapSoundPlayer.systemUISoundsEnabled(global: [SnapSoundPlayer.uiSoundsKey: NSNumber(value: false)]))
        #expect(SnapSoundPlayer.systemUISoundsEnabled(global: [SnapSoundPlayer.uiSoundsKey: NSNumber(value: true)]))
    }

    @Test func theSnappingContextReportsSnapsToTheWindowsPlayer() {
        let environment = TestEnvironment()
        var document = environment.document
        let player = SnapSoundPlayer(preferences: environment.preferences)
        let speaker = Speaker()
        speaker.attach(to: player)
        document.snapSounds = player
        environment.preferences.set("Morse", for: PreferenceCatalog.Sounds.snapObject)
        speaker.played = []
        let controller = DocumentWindowController(document: .memory(title: "Snap"), environment: document)
        defer { controller.close() }
        controller.toolManager.context.snapping.didSnap(.object)
        #expect(speaker.played == ["Morse"])
        SnappingContext().didSnap(.point)
    }
}
