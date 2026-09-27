import AppKit
import Foundation
import Testing
@testable import WireTuner

/// DOC-020: menu:File[Open Recent] (ten deep, merged across Macs through the synced list), the
/// Window menu's documents, and the launch gallery switch (creating-opening.adoc).
@Suite @MainActor struct DocumentMenusTests {
    let server = FakeLibraryServer()
    let suite = TestDefaults()

    func library() -> LibraryModel {
        LibraryModel(services: server.services(), store: nil, thumbnails: ThumbnailCache(directory: nil), debounce: .milliseconds(1))
    }

    @Test func recentEntriesRoundTripAndMergeByTime() {
        let entry = RecentEntry(id: "d1", openedAt: Date(timeIntervalSince1970: 12.5), spaceID: "s", name: "Tab\tName")
        let decoded = RecentEntry(encoded: entry.encoded)
        #expect(decoded == RecentEntry(id: "d1", openedAt: Date(timeIntervalSince1970: 12.5), spaceID: "s", name: "Tab Name"))
        #expect(RecentEntry(encoded: "bad") == nil && RecentEntry(encoded: "\t1\t\tx") == nil && RecentEntry(encoded: "a\tx\t\tn") == nil)
        #expect(RecentEntry(encoded: "a\t1000\t\tn")?.spaceID == nil)
        let older = RecentEntry(id: "d1", openedAt: Date(timeIntervalSince1970: 1), spaceID: nil, name: "A")
        let other = RecentEntry(id: "d2", openedAt: Date(timeIntervalSince1970: 5), spaceID: nil, name: "B")
        #expect(DocumentMenuFeatures.merge([older, other], [entry]).map(\.id) == ["d1", "d2"])
        #expect(DocumentMenuFeatures.merge([older, other], [entry])[0].openedAt == entry.openedAt)
        #expect(DocumentMenuFeatures.decode(["x", entry.encoded]).count == 1)
    }

    @Test func openRecentListsTenSyncsAcrossMacsAndClears() async throws {
        for index in 0..<12 { server.put(LibraryDocument(id: "d\(index)", spaceID: server.accountID, name: "Doc \(index)")) }
        let library = library()
        var clock = Date(timeIntervalSince1970: 1000)
        library.now = { clock }
        await library.refresh()
        let preferences = PreferenceStore(defaults: suite.defaults)
        let menus = DocumentMenuFeatures(library: library, preferences: preferences)
        let registry = CommandRegistry()
        let rebuilds = Counter()
        menus.rebuildMenu = { rebuilds.bump() }
        var opened: [String] = []
        library.onOpen = { opened += $0.map(\.id) }
        menus.install(into: registry)
        #expect(registry.contains(DocumentMenuFeatures.ID.clearRecents) && !registry.contains(DocumentMenuFeatures.ID.recent(0)))
        #expect(registry.validate(DocumentMenuFeatures.ID.clearRecents)?.isEnabled == false)

        for index in 0..<12 {
            clock += 1
            library.open([library.cache.documents["d\(index)"]!])
        }
        #expect(menus.recentDocuments.count == DocumentMenuFeatures.menuLimit && menus.recentDocuments.first?.id == "d11")
        #expect(registry.command(DocumentMenuFeatures.ID.recent(0))?.title == "Doc 11")
        #expect(registry.command(DocumentMenuFeatures.ID.recent(0))?.menuPath == MenuPath("File", DocumentMenuFeatures.openRecent))
        #expect(preferences[PreferenceCatalog.Document.recents].count == 12, "pushed to the account")
        let before = rebuilds.count
        menus.sync()
        #expect(rebuilds.count == before, "nothing changed, no rebuild")

        // Another Mac opened d0 later and a document this Mac has not listed.
        let remote = [RecentEntry(id: "d0", openedAt: clock + 10, spaceID: server.accountID, name: "Doc 0"),
                      RecentEntry(id: "far", openedAt: clock + 5, spaceID: server.accountID, name: "Far away")]
        _ = preferences.set(remote.map(\.encoded) + preferences[PreferenceCatalog.Document.recents], for: PreferenceCatalog.Document.recents)
        #expect(menus.recentDocuments.map(\.id).prefix(2) == ["d0", "far"])
        #expect(registry.command(DocumentMenuFeatures.ID.recent(1))?.title == "Far away")

        #expect(registry.perform(DocumentMenuFeatures.ID.recent(0)))
        #expect(opened.last == "d0")
        server.offline = true
        await library.refresh()
        #expect(registry.validate(DocumentMenuFeatures.ID.recent(1))?.isEnabled == false, "not on this Mac, offline")
        menus.openRecent("unknown")

        #expect(registry.perform(DocumentMenuFeatures.ID.clearRecents))
        #expect(library.cache.recents.isEmpty && preferences[PreferenceCatalog.Document.recents].isEmpty)
        #expect(!registry.contains(DocumentMenuFeatures.ID.recent(0)))
        library.clearRecents()
        suite.remove()
    }

    @Test func theWindowMenuListsTheOpenDocumentsWithTheFrontOneChecked() {
        let library = library()
        let menus = DocumentMenuFeatures(library: library, preferences: PreferenceStore(defaults: suite.defaults))
        var windows = [DocumentMenuFeatures.WindowEntry(title: "A", isActive: false), DocumentMenuFeatures.WindowEntry(title: "B", isActive: true)]
        var activated: [Int] = []
        menus.windows = { windows }
        menus.activateWindow = { activated.append($0) }
        let registry = CommandRegistry()
        menus.install(into: registry)
        #expect(registry.command(DocumentMenuFeatures.ID.window(1))?.title == "B")
        #expect(registry.validate(DocumentMenuFeatures.ID.window(1))?.isChecked == true)
        #expect(registry.validate(DocumentMenuFeatures.ID.window(0))?.isChecked == false)
        #expect(registry.command(DocumentMenuFeatures.ID.window(0))?.menuPath?.section == DocumentMenuFeatures.windowSection)
        #expect(registry.perform(DocumentMenuFeatures.ID.window(0)))
        #expect(activated == [0])
        windows = [windows[0]]
        menus.sync()
        #expect(!registry.contains(DocumentMenuFeatures.ID.window(1)))
        windows = []
        #expect(registry.validate(DocumentMenuFeatures.ID.window(0))?.isChecked == false)
        suite.remove()
    }

    @Test func onlyATestLaunchThatAsksShowsTheGalleryAtLaunch() {
        #expect(LaunchEnvironment(arguments: [], environment: [:]).showsGalleryAtLaunch(arguments: []))
        let test = LaunchEnvironment(arguments: [LaunchEnvironment.uiTestingArgument], environment: [:])
        #expect(!test.showsGalleryAtLaunch(arguments: []))
        #expect(test.showsGalleryAtLaunch(arguments: [LaunchEnvironment.showGalleryArgument]))
    }
}
