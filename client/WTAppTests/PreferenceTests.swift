import AppKit
import SwiftUI
import Testing
@testable import WireTuner

/// The rows of docs/_includes/basics/preferences.adoc, category by category, exactly as the
/// page titles them.  Adding a row to the page without a catalog key (or the reverse) fails
/// `catalogCoversEveryRowOfThePage`.
enum PreferencesPage {
    static let rows: [(PreferenceCategory, [String])] = [
        (.general, [
            "Pick distance", "Snap distance", "Smaller handles", "Show solid points", "Highlight selected paths",
            "Double-click enables transform handles", "Remember layer info", "Dragging a guide scrolls the window",
            "Pen tool preview", "Smoother editing", "Show the gallery at launch", "Flash changes by others", "Smart guides",
            "Show measurements while holding Option", "Rotate canvas with trackpad",
        ]),
        (.object, [
            "Option-drag copies paths", "Changing object changes defaults", "Show fill for new open paths", "Edit locked objects",
            "Path operations consume original paths", "Join non-touching paths", "Default line weights",
            "Auto-apply new styles to selection", "Confirm before opening an external editor", "Default image editor",
            "Auto-join paths", "Edit current layer only", "Constrain angle", "Arrow key distance", "Shift-arrow key distance",
        ]),
        (.text, [
            "New text containers auto-expand", "Show text handles when ruler is off", "Always use text editor", "Smart quotes",
            "Track tab movement with vertical line", "Dragging a text style changes", "Build text styles based on",
            "Preview fonts in menus", "Text tool reverts to Pointer", "Font substitutions",
        ]),
        (.document, [
            "Restore view when opening document", "Remember window size and location", "New document template",
            "Warn when quitting with unsynced changes", "Search for missing links", "Changing view sets the active page",
            "Using tools sets the active page", "Ask for a version name when saving", "Warn when image resolution is below",
        ]),
        (.importing, [
            "Embed images upon import", "Convert editable EPS when imported", "PDF import: Import notes", "PDF import: Import URLs",
            "DXF: Import invisible block attributes", "DXF: Convert white strokes to black", "DXF: Convert white fills to black",
            "Paste formats", "Downsample images larger than", "Embedded image profiles",
        ]),
        (.exporting, [
            "Clipboard formats", "Convert colors to", "Clipboard image resolution", "Include TIFF preview in EPS", "Include Quick Look thumbnail",
            "Bitmap export resolution", "Bitmap export anti-aliasing", "Default background", "Embed color profile",
            "Quick Export preset", "Drag export format", "Multi-page file name pattern", "Open exported file with", "Preview browser",
        ]),
        (.spelling, [
            "Find duplicate words", "Find capitalization errors", "Ignore words with numbers", "Ignore internet and file addresses",
            "Ignore words in uppercase", "Dictionary", "Check spelling while typing", "Add words to dictionary",
        ]),
        (.colors, [
            "Guide color", "Grid color", "Smart guide color", "Color Mixer and Tints panels use split color box",
            "Default color space for new colors", "Auto-rename colors", "Swatches apply color to", "Color management",
            "Color manage spot colors", "Monitor, composite and separations profiles",
        ]),
        (.panels, ["Label panel tabs with", "Show tooltips", "Panel transparency", "Clicking a layer name moves selected objects"]),
        (.redraw, ["Preview drag", "Display text effects", "Greek type below", "Image display", "Raster effect preview"]),
        (.sounds, ["Snap to point sound", "Snap to object sound", "Snap to grid sound", "Snap to guide sound"]),
        (.sync, [
            "Sync preferences with my account", "Undo levels", "Auto-merge below", "Ask when overlap exceeds",
            "Ask when overlap share exceeds", "Always ask when anything overlaps", "Suggest review after", "Keep both offset",
            "Show my cursor and selection to others", "Show others' cursors", "Show others' selections",
            "Offline snapshot interval", "Show names on collaborators' cursors", "Show Pins", "Show Resolved Pins", "Pins Follow Filter", "Inspect unit", "Inspect scale",
        ]),
        (.automation, ["Highlight data fields", "Embed sample records", "Show script console on error"]),
        (.printing, ["Warn about missing fonts before printing"]),
        (.typeface, ["Glyph cell size", "Snap to metric lines", "Font preview text", "Show generated features"]),
    ]

    /// Rows that hold more than one value, and the keys they map to.
    static let compoundRows: [String: [String]] = [
        "Smart quotes": ["text.smart_quotes", "text.smart_quotes_style"],
        "Font substitutions": ["text.font_substitutions", "text.default_substitute"],
        "Search for missing links": ["document.search_missing_links", "document.missing_links_folder"],
        "Monitor, composite and separations profiles": ["colors.monitor_profile", "colors.composite_profile", "colors.separations_profile"],
    ]

    /// Rows the page marks local: the local categories plus the "(local)" notes.
    static let localRows: Set<String> = [
        "Default image editor", "Remember window size and location", "Paste formats", "Clipboard formats", "Open exported file with",
        "Preview browser", "Smart guide color", "Color management", "Monitor, composite and separations profiles",
        "Sync preferences with my account", "Offline snapshot interval", "Inspect unit", "Inspect scale", "Highlight data fields", "Show script console on error",
    ]
}

@Suite @MainActor struct PreferenceCatalogTests {
    @Test func catalogCoversEveryRowOfThePage() {
        let pageRows = PreferencesPage.rows.flatMap(\.1)
        #expect(pageRows.count == 130, "the page's tables have 130 rows")
        // Hidden keys (the synced recents, DOC-020) are not rows of the window.
        let shown = PreferenceCatalog.all.filter { $0.control != .hidden }
        let mapped = Set(shown.map(\.pageRow))
        let unmapped = pageRows.filter { !mapped.contains($0) }
        #expect(unmapped.isEmpty, "rows without a key: \(unmapped)")
        let extra = mapped.subtracting(pageRows)
        #expect(extra.isEmpty, "keys citing rows the page does not have: \(extra)")
        for (category, rows) in PreferencesPage.rows {
            let keys = PreferenceCatalog.keys(in: category).filter { $0.control != .hidden }
            #expect(Array(NSOrderedSet(array: keys.map(\.pageRow))) as? [String] == rows, "\(category) rows in page order")
        }
        // 130 rows; four rows hold several values, adding 1 + 1 + 1 + 2 keys.
        #expect(shown.count == 135 && PreferenceCatalog.all.count == 136)
        for (row, ids) in PreferencesPage.compoundRows {
            #expect(PreferenceCatalog.all.filter { $0.pageRow == row }.map(\.id) == ids)
        }
    }

    @Test func everyKeyHasAUniqueIDADefaultACategoryAndAHelpPage() {
        let ids = PreferenceCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(PreferenceCatalog.byID.count == ids.count)
        for key in PreferenceCatalog.all {
            #expect(key.id.hasPrefix(key.category.rawValue + "."), "\(key.id) starts with its category")
            #expect(key.id == key.id.lowercased())
            #expect(key.accepts(key.defaultValue), "\(key.id)'s default is valid")
            #expect(!key.helpSlug.isEmpty)
            #expect(!key.title.isEmpty)
            #expect(key.defaultsKey == "wt." + key.id)
        }
    }

    @Test func scopesFollowThePage() {
        for key in PreferenceCatalog.all {
            let local = PreferencesPage.localRows.contains(key.pageRow) || key.category.scope == .local
            let expected: PreferenceScope = (local || key.id == "document.missing_links_folder") ? .local : .synced
            #expect(key.scope == expected, "\(key.id)")
        }
        #expect(PreferenceCategory.panels.scope == .local)
        #expect(PreferenceCategory.general.scope == .synced)
    }

    @Test func theSpecNamedIDsExist() {
        let named = [
            "general.pick_distance", "general.smart_guides", "general.option_measurements", "general.trackpad_rotate",
            "object.option_drag_copies", "text.smart_quotes_style", "document.new_template", "import.embed_images",
            "export.eps_tiff_preview", "spelling.ignore_uppercase", "colors.guide_color", "sync.undo_levels",
            "sync.auto_merge_below", "sync.ask_overlap_count", "sync.ask_overlap_share", "sync.always_ask",
            "sync.suggest_review_after_hours", "sync.keep_both_offset", "sync.share_presence", "sync.show_cursors",
            "sync.show_selections", "panels.label_style", "redraw.preview_drag", "sounds.snap_point", "sync.enabled",
            "sync.snapshot_interval_minutes", "object.external_editors", "import.paste_formats", "export.copy_formats",
            "colors.color_management", "colors.smart_guide_color", "document.remember_window",
        ]
        for id in named { #expect(PreferenceCatalog.byID[id] != nil, "\(id)") }
    }

    @Test func categoriesHaveTitlesSymbolsAndVisibility() {
        #expect(PreferenceCategory.allCases.count == 15)
        #expect(Set(PreferenceCategory.allCases.map(\.title)).count == 15)
        #expect(PreferenceCategory.allCases.allSatisfy { !$0.symbolName.isEmpty && $0.id == $0.rawValue })
        #expect(!PreferenceCategory.visible(typefaceDocumentOpen: false).contains(.typeface))
        #expect(PreferenceCategory.visible(typefaceDocumentOpen: true).last == .typeface)
        #expect(PreferenceCategory.importing.rawValue == "import")
    }

    @Test func keysValidateTypeRangeAndOptions() {
        let pick = PreferenceCatalog.General.pickDistance.erased
        #expect(pick.accepts(.int(5)))
        #expect(!pick.accepts(.int(6)))
        #expect(!pick.accepts(.double(3)))
        #expect(!PreferenceCatalog.Object.arrowDistance.erased.accepts(.double(.nan)))
        let style = PreferenceCatalog.Text.smartQuotesStyle.erased
        #expect(style.accepts(.string("german")))
        #expect(!style.accepts(.string("klingon")))
        #expect(style.control.options?.count == 6)
        #expect(style.control.range == nil)
        #expect(pick.control.range == 1...5)
        #expect(pick.control.options == nil)
        #expect(PreferenceCatalog.Colors.guideColor.erased.accepts(.color(.magenta)))
        #expect(PreferenceCatalog.Object.defaultLineWeights.defaultValue.count == 8)
        #expect(pick == PreferenceCatalog.byID["general.pick_distance"])
        #expect(Set([pick, pick]).count == 1)
    }
}

@Suite @MainActor struct PreferenceValueTests {
    @Test func convertsEveryCaseThroughPropertyLists() {
        let values: [PreferenceValue] = [.bool(true), .int(7), .double(2.5), .string("x"), .color(.cyan), .list(["a", "b"])]
        for value in values {
            #expect(PreferenceValue(propertyList: value.propertyList, like: value) == value)
        }
        #expect(PreferenceValue(propertyList: 3, like: .double(0)) == .double(3), "an int stored for a double key")
        #expect(PreferenceValue(propertyList: true, like: .int(0)) == nil)
        #expect(PreferenceValue(propertyList: 2.5, like: .int(0)) == nil)
        #expect(PreferenceValue(propertyList: 1, like: .bool(false)) == nil)
        #expect(PreferenceValue(propertyList: true, like: .double(0)) == nil)
        #expect(PreferenceValue(propertyList: 1, like: .string("")) == nil)
        #expect(PreferenceValue(propertyList: [1.0, 2.0], like: .color(.cyan)) == nil)
        #expect(PreferenceValue(propertyList: "x", like: .color(.cyan)) == nil)
        #expect(PreferenceValue(propertyList: 1, like: .list([])) == nil)
        #expect(PreferenceColor(components: [1, 2, 3]) == nil)
        #expect(PreferenceValue.string("a").number == nil)
        #expect(PreferenceValue.int(2).number == 2)
    }

    @Test func typedWrappersRoundTrip() {
        #expect(Bool(preferenceValue: .bool(true)) == true)
        #expect(Bool(preferenceValue: .int(1)) == nil)
        #expect(Int(preferenceValue: .int(4)) == 4)
        #expect(Int(preferenceValue: .bool(true)) == nil)
        #expect(Double(preferenceValue: .double(1.5)) == 1.5)
        #expect(Double(preferenceValue: .int(1)) == nil)
        #expect(String(preferenceValue: .string("s")) == "s")
        #expect(String(preferenceValue: .bool(true)) == nil)
        #expect(PreferenceColor(preferenceValue: .color(.magenta)) == .magenta)
        #expect(PreferenceColor(preferenceValue: .string("")) == nil)
        #expect([String](preferenceValue: .list(["z"])) == ["z"])
        #expect([String](preferenceValue: .string("z")) == nil)
        #expect(PreferenceColor.lightGray.preferenceValue == .color(.lightGray))
        #expect(["q"].preferenceValue == .list(["q"]))
    }

    @Test func valuesAreCodable() throws {
        let value = PreferenceValue.color(.cyan)
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(PreferenceValue.self, from: data) == value)
    }
}

/// A backend that records pushes and can deliver a remote map.
@MainActor
final class RecordingBackend: SyncedPreferenceBackend {
    private(set) var pushes: [[String: PreferenceValue]] = []
    var onRemoteMap: (@MainActor ([String: PreferenceValue]) -> Void)?
    func enqueue(_ entries: [String: PreferenceValue]) { pushes.append(entries) }
}

@Suite @MainActor struct PreferenceStoreTests {
    @Test func unsetKeysReadTheirDefaultsAndWritesRoundTrip() {
        let suite = TestDefaults()
        defer { suite.remove() }
        let store = PreferenceStore(defaults: suite.defaults)
        let pick = PreferenceCatalog.General.pickDistance
        #expect(store[pick] == 3)
        #expect(!store.isSet(pick.erased))
        #expect(store.set(5, for: pick))
        #expect(store[pick] == 5)
        #expect(suite.defaults.integer(forKey: "wt.general.pick_distance") == 5)
        #expect(PreferenceStore(defaults: suite.defaults)[pick] == 5, "persisted")
        #expect(!store.set(9, for: pick), "out of range")
        #expect(store[pick] == 5)
        #expect(store.set(5, for: pick), "same value is accepted without a change")
        let guide = PreferenceCatalog.Colors.guideColor
        #expect(store.set(PreferenceColor.magenta, for: guide))
        #expect(PreferenceStore(defaults: suite.defaults)[guide] == .magenta)
        let weights = PreferenceCatalog.Object.defaultLineWeights
        #expect(store.set(["1", "2"], for: weights))
        #expect(store[weights] == ["1", "2"])
        suite.defaults.set("garbage", forKey: "wt.general.snap_distance")
        #expect(store[PreferenceCatalog.General.snapDistance] == 3, "an unreadable value reads as the default")
        suite.defaults.set(99, forKey: "wt.general.snap_distance")
        #expect(store[PreferenceCatalog.General.snapDistance] == 3, "an out-of-range stored value reads as the default")
    }

    @Test func syncedChangesArePushedLocalOnesAreNot() {
        let suite = TestDefaults()
        defer { suite.remove() }
        let backend = RecordingBackend()
        let store = PreferenceStore(defaults: suite.defaults, backend: backend)
        store.set(false, for: PreferenceCatalog.General.smartGuides)
        store.set(PreferenceColor.cyan, for: PreferenceCatalog.Colors.smartGuideColor)
        #expect(backend.pushes == [["general.smart_guides": .bool(false)]])
        store.set(false, for: PreferenceCatalog.Sync.enabled)
        #expect(!store.syncEnabled)
        store.set(4, for: PreferenceCatalog.General.pickDistance)
        #expect(backend.pushes.count == 1, "nothing is pushed while syncing is off")
        let local = LocalPreferenceBackend()
        let other = PreferenceStore(defaults: TestDefaults().defaults, backend: local)
        other.set(2, for: PreferenceCatalog.General.pickDistance)
        #expect(local.pushCount == 1)
        #expect(PreferenceStore(defaults: suite.defaults).backend is LocalPreferenceBackend)
    }

    @Test func resetRestoresACategoryOrEverythingAndPushesDefaults() {
        let suite = TestDefaults()
        defer { suite.remove() }
        let backend = RecordingBackend()
        let store = PreferenceStore(defaults: suite.defaults, backend: backend)
        store.set(1, for: PreferenceCatalog.General.pickDistance)
        store.set(false, for: PreferenceCatalog.General.smartGuides)
        store.set(false, for: PreferenceCatalog.Panels.showTooltips)
        store.set(7, for: PreferenceCatalog.Sync.undoLevels)
        let before = backend.pushes.count

        store.reset(category: .general)
        #expect(store[PreferenceCatalog.General.pickDistance] == 3)
        #expect(store[PreferenceCatalog.General.smartGuides])
        #expect(!store.isSet(PreferenceCatalog.General.pickDistance.erased))
        #expect(!store[PreferenceCatalog.Panels.showTooltips], "other categories are untouched")
        #expect(backend.pushes.count == before + 1)
        #expect(backend.pushes.last == ["general.pick_distance": .int(3), "general.smart_guides": .bool(true)])

        store.resetAll()
        #expect(store[PreferenceCatalog.Panels.showTooltips])
        #expect(store[PreferenceCatalog.Sync.undoLevels] == 100)
        #expect(backend.pushes.last == ["sync.undo_levels": .int(100)], "local keys are reset but not pushed")
        store.resetAll()
        #expect(backend.pushes.count == before + 2, "nothing set, nothing pushed")
    }

    @Test func remoteMapsApplyWholesaleWhileSyncing() {
        let suite = TestDefaults()
        defer { suite.remove() }
        let backend = RecordingBackend()
        let store = PreferenceStore(defaults: suite.defaults, backend: backend)
        store.set(2, for: PreferenceCatalog.General.snapDistance)
        store.set(false, for: PreferenceCatalog.Panels.showTooltips)
        backend.onRemoteMap?(["general.pick_distance": .int(1), "general.smart_guides": .string("bad"), "sync.enabled": .bool(false)])
        #expect(store[PreferenceCatalog.General.pickDistance] == 1)
        #expect(store[PreferenceCatalog.General.snapDistance] == 3, "absent from the map: back to default")
        #expect(store[PreferenceCatalog.General.smartGuides], "an invalid remote value is ignored")
        #expect(!store[PreferenceCatalog.Panels.showTooltips], "local keys are not the account's")
        #expect(store.syncEnabled, "the sync switch is local")
        store.applyRemote(["general.pick_distance": .int(1)])
        #expect(store[PreferenceCatalog.General.pickDistance] == 1)
        store.set(false, for: PreferenceCatalog.Sync.enabled)
        store.applyRemote(["general.pick_distance": .int(4)])
        #expect(store[PreferenceCatalog.General.pickDistance] == 1, "ignored while syncing is off")
    }

    @Test func changesAreObservableAsAsyncStreams() async {
        let suite = TestDefaults()
        defer { suite.remove() }
        let store = PreferenceStore(defaults: suite.defaults)
        let pick = PreferenceCatalog.General.pickDistance
        var values = store.values(for: pick).makeAsyncIterator()
        var changes = store.changes().makeAsyncIterator()
        #expect(await values.next() == 3)
        store.set(false, for: PreferenceCatalog.General.smartGuides)
        store.set(4, for: pick)
        #expect(await changes.next() == PreferenceChange(id: "general.smart_guides", value: .bool(false)))
        #expect(await changes.next() == PreferenceChange(id: "general.pick_distance", value: .int(4)))
        #expect(await values.next() == 4)
        store.reset(category: .general)
        #expect(await values.next() == 3)
        #expect(store.observerCount >= 2)
        #expect(store.revision > 0)
    }

    @Test func streamsDetachWhenCancelled() async {
        let suite = TestDefaults()
        defer { suite.remove() }
        let store = PreferenceStore(defaults: suite.defaults)
        let task = Task { @MainActor in
            for await _ in store.changes() {}
        }
        for _ in 0..<50 where store.observerCount == 0 { await Task.yield() }
        #expect(store.observerCount == 1)
        task.cancel()
        for _ in 0..<50 where store.observerCount > 0 { await Task.yield() }
        #expect(store.observerCount == 0)
    }

    @Test func theSuiteIsTheAppDomain() {
        #expect(PreferenceStore.suiteName == "com.villagecompute.wiretuner")
        #expect(PreferenceStore.makeDefaults(suiteName: "WireTunerTests.suite") !== UserDefaults.standard)
        // The app's own bundle identifier is refused as a suite; the standard defaults are that domain.
        if Bundle.main.bundleIdentifier == PreferenceStore.suiteName {
            #expect(PreferenceStore.makeDefaults() === UserDefaults.standard)
        }
    }
}

@Suite @MainActor struct PreferenceFormTests {
    @Test func everyCategoryGeneratesARowPerKey() {
        var total = 0
        for category in PreferenceCategory.allCases {
            let rows = PreferenceForm.rows(for: category)
            #expect(rows.map(\.id) == PreferenceCatalog.keys(in: category).filter { $0.control != .hidden }.map(\.id))
            #expect(rows.allSatisfy { $0.accessibilityIdentifier == "pref.\($0.id)" && $0.title == $0.key.title })
            total += rows.count
        }
        #expect(total == PreferenceCatalog.all.filter { $0.control != .hidden }.count)
    }

    @Test func controlKindsFollowTheCatalog() {
        func kind(_ key: AnyPreferenceKey) -> PreferenceFormRow.Kind { PreferenceFormRow(key: key).kind }
        #expect(kind(PreferenceCatalog.General.smartGuides.erased) == .toggle)
        #expect(kind(PreferenceCatalog.General.pickDistance.erased) == .number(range: 1...5, step: 1, unit: "px", integer: true))
        #expect(kind(PreferenceCatalog.Object.arrowDistance.erased) == .number(range: 1...864, step: 1, unit: "pt", integer: false))
        #expect(kind(PreferenceCatalog.Colors.guideColor.erased) == .color)
        #expect(kind(PreferenceCatalog.Object.defaultLineWeights.erased) == .list)
        #expect(kind(PreferenceCatalog.Typeface.previewText.erased) == .text(placeholder: "Hamburgefonstiv"))
        #expect(kind(PreferenceCatalog.Document.newTemplate.erased) == .templateChooser)
        #expect(kind(PreferenceCatalog.Document.recents.erased) == .hidden)
        #expect(!PreferenceForm.rows(for: .document).contains { $0.key.id == PreferenceCatalog.Document.recents.id })
        if case let .popup(options) = kind(PreferenceCatalog.Export.bitmapResolution.erased) {
            #expect(options.map(\.title) == ["72 dpi", "144 dpi", "300 dpi"])
        } else {
            Issue.record("bitmap resolution is a pop-up")
        }
        #expect(PreferenceFormRow(key: PreferenceCatalog.Colors.smartGuideColor.erased).isLocalInSyncedCategory)
        #expect(!PreferenceFormRow(key: PreferenceCatalog.Panels.showTooltips.erased).isLocalInSyncedCategory)
    }

    @Test func conversionsBetweenControlsAndValues() {
        #expect(PreferenceForm.numberValue(2.6, integer: true) == .int(3))
        #expect(PreferenceForm.numberValue(2.6, integer: false) == .double(2.6))
        #expect(PreferenceForm.listItems("0.5 1,2\n4  8") == ["0.5", "1", "2", "4", "8"])
        #expect(PreferenceForm.listText(["a", "b"]) == "a b")
        let color = PreferenceColor(red: 0.2, green: 0.4, blue: 0.6)
        let back = PreferenceForm.preferenceColor(PreferenceForm.color(color))
        #expect(abs(back.red - 0.2) < 0.01 && abs(back.green - 0.4) < 0.01 && abs(back.blue - 0.6) < 0.01)
    }

    @Test func bindingsWriteThroughAndBeepOnRejection() {
        let suite = TestDefaults()
        defer { suite.remove() }
        let store = PreferenceStore(defaults: suite.defaults)
        let state = CommandState()
        var bindings = PreferenceBindings(store: store)
        bindings.beep = { state.count += 1 }
        let toggle = bindings.bool(PreferenceCatalog.General.smartGuides.erased)
        #expect(toggle.wrappedValue)
        toggle.wrappedValue = false
        #expect(!store[PreferenceCatalog.General.smartGuides])
        let number = bindings.number(PreferenceCatalog.General.pickDistance.erased, integer: true)
        number.wrappedValue = 4
        #expect(store[PreferenceCatalog.General.pickDistance] == 4)
        number.wrappedValue = 40
        #expect(state.count == 1, "out of range beeps")
        #expect(number.wrappedValue == 4)
        let option = bindings.option(PreferenceCatalog.Import.embeddedProfiles.erased)
        option.wrappedValue = .string("ask")
        #expect(store[PreferenceCatalog.Import.embeddedProfiles] == "ask")
        let text = bindings.string(PreferenceCatalog.Typeface.previewText.erased)
        text.wrappedValue = "Hello"
        #expect(text.wrappedValue == "Hello")
        let list = bindings.list(PreferenceCatalog.Object.defaultLineWeights.erased)
        list.wrappedValue = "1 2 3"
        #expect(list.wrappedValue == "1 2 3")
        let color = bindings.color(PreferenceCatalog.Colors.gridColor.erased)
        color.wrappedValue = Color(.sRGB, red: 1, green: 0, blue: 0)
        #expect(abs(store[PreferenceCatalog.Colors.gridColor].red - 1) < 0.01)
        _ = color.wrappedValue
        // Bindings of the wrong kind read neutral values.
        #expect(!bindings.bool(PreferenceCatalog.General.pickDistance.erased).wrappedValue)
        #expect(bindings.number(PreferenceCatalog.General.smartGuides.erased, integer: true).wrappedValue == 0)
        #expect(bindings.string(PreferenceCatalog.General.smartGuides.erased).wrappedValue == "")
        #expect(bindings.list(PreferenceCatalog.General.smartGuides.erased).wrappedValue == "")
        _ = bindings.color(PreferenceCatalog.General.smartGuides.erased).wrappedValue
    }

    @Test func everyCategoryFormRendersInAHostingView() {
        let suite = TestDefaults()
        defer { suite.remove() }
        let store = PreferenceStore(defaults: suite.defaults)
        for category in PreferenceCategory.allCases {
            let hosting = NSHostingView(rootView: PreferenceCategoryForm(category: category, store: store))
            hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 700)
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.width > 0, "\(category)")
            _ = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds).map { hosting.cacheDisplay(in: hosting.bounds, to: $0) }
        }
    }
}

@Suite @MainActor struct PreferencesWindowTests {
    @Test func theModelRestoresACategoryWithOptionOrEverythingWithout() {
        let suite = TestDefaults()
        defer { suite.remove() }
        let store = PreferenceStore(defaults: suite.defaults)
        let state = CommandState()
        let model = PreferencesWindowModel(store: store) { state.count += 1 }
        #expect(model.categories.count == 14)
        model.typefaceDocumentOpen = true
        #expect(model.categories.count == 15)
        store.set(1, for: PreferenceCatalog.General.pickDistance)
        store.set(false, for: PreferenceCatalog.Panels.showTooltips)
        model.selectedCategory = .general
        model.optionHeld = true
        #expect(model.restoreTitle == "Restore This Category")
        #expect(model.restoreMessage.contains("General"))
        model.restore()
        #expect(store[PreferenceCatalog.General.pickDistance] == 3)
        #expect(!store[PreferenceCatalog.Panels.showTooltips])
        #expect(state.count == 0)
        model.optionHeld = false
        #expect(model.restoreTitle == "Restore Defaults")
        #expect(model.restoreMessage.contains("panel layout"))
        store.set(false, for: PreferenceCatalog.Panels.showTooltips)
        #expect(!model.confirmAndRestore { _ in false }, "declined: nothing changes")
        #expect(!store[PreferenceCatalog.Panels.showTooltips])
        #expect(model.confirmAndRestore { $0.contains("panel layout") })
        #expect(store[PreferenceCatalog.Panels.showTooltips])
        #expect(state.count == 1, "Restore Defaults also resets the panel layout")
        let alert = PreferencesWindowController.confirmationAlert("Restore?")
        #expect(alert.messageText == "Restore?")
        #expect(alert.buttons.map(\.title) == ["Restore", "Cancel"])
    }

    @Test func theWindowHasASidebarAndTracksOptionAndSelection() async {
        let suite = TestDefaults()
        defer { suite.remove() }
        let model = PreferencesWindowModel(store: PreferenceStore(defaults: suite.defaults))
        let controller = PreferencesWindowController(model: model, confirm: { _ in true })
        let window = controller.window!
        #expect(window.identifier == PreferencesWindowController.identifier)
        #expect(window.title == "General")
        #expect((window.contentViewController as? NSSplitViewController)?.splitViewItems.count == 2)
        controller.show()
        #expect(window.isVisible)
        #expect(controller.isMonitoringOption)
        controller.startMonitoringOption()
        controller.flagsChanged(to: .option)
        #expect(model.optionHeld)
        controller.flagsChanged(to: [])
        #expect(!model.optionHeld)
        model.selectedCategory = .colors
        for _ in 0..<20 where window.title != "Colors" { await Task.yield() }
        #expect(window.title == "Colors")
        window.contentView?.layoutSubtreeIfNeeded()
        controller.close()
        #expect(!controller.isMonitoringOption)
        controller.stopMonitoringOption()
    }

    @Test func settingsAndSmartGuidesCommandsGoThroughTheStore() {
        let suite = TestDefaults()
        defer { suite.remove() }
        let store = PreferenceStore(defaults: suite.defaults)
        let registry = CommandRegistry()
        StandardCommands.register(into: registry)
        let state = CommandState()
        PreferenceCommands.install(into: registry, store: store) { state.count += 1 }
        #expect(registry.validate(StandardCommands.ID.settings)?.isEnabled == true)
        #expect(registry.command(StandardCommands.ID.settings)?.defaultKey == KeyEquivalent(",", .command))
        #expect(registry.perform(StandardCommands.ID.settings))
        #expect(state.count == 1)
        #expect(registry.validate(StandardCommands.ID.smartGuides)?.isChecked == true)
        #expect(registry.command(StandardCommands.ID.smartGuides)?.defaultKey == KeyEquivalent("u", .command))
        registry.perform(StandardCommands.ID.smartGuides)
        #expect(!store[PreferenceCatalog.General.smartGuides])
        #expect(registry.validate(StandardCommands.ID.smartGuides)?.isChecked == false)
        let viewMenu = MenuTreeBuilder.build(registry: registry, shortcuts: .builtInDefault(commands: registry.commands)).items(inMenu: "View")
        #expect(viewMenu?.flatMap(\.commandIDs).contains(StandardCommands.ID.smartGuides) == true, "replaced in place, still in the View menu")
    }
}
